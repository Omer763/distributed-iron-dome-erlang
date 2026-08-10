-module(node_manager).
-behaviour(gen_server).

-export([start_link/0]).
-export([
    start_sector/2,
    stop_all_sectors/1,
    sectors/1,
    heartbeat/0
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% Starts the node manager registered on the local Erlang node.
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Starts a sector on a selected connected node.
start_sector(Node, Config) -> gen_server:call({?MODULE, Node}, {start_sector, Config}, 10000).

%% Stops every sector on a worker before recovery or isolation.
stop_all_sectors(Node) -> gen_server:call({?MODULE, Node}, stop_all_sectors, 15000).

%% Lists sectors hosted on a selected connected node.
sectors(Node) -> gen_server:call({?MODULE, Node}, sectors).

%% Replies locally so the coordinator can check that this worker responds.
heartbeat() -> ok.

%% Creates an empty host and traps linked sector exits.
init([]) ->
    %% Sector supervisors are linked to this process. Trapping exits lets us
    %% receive an EXIT message and restart a failed sector locally.
    process_flag(trap_exit, true),
    {ok, #{sectors => #{}}}.

%% Starts, stops, and queries sectors.
handle_call({start_sector, #{sector_id := _} = Config}, _From, State) -> start_sector_handler(Config, State);
handle_call(stop_all_sectors, _From, State) -> stop_all_sectors_handler(State);
handle_call(sectors, _From, #{sectors := Sectors} = State) -> {reply, sector_summary(Sectors), State};
handle_call(Request, _From, State) -> {reply, {error, {unsupported_call, Request}}, State}.

%% Ignores unsupported asynchronous messages.
handle_cast(_Message, State) -> {noreply, State}.

%% Restarts a sector when its supervisor terminates unexpectedly.
handle_info({'EXIT', SupervisorPid, Reason}, State) -> {noreply, restart_sector_handler(SupervisorPid, Reason, State)};
handle_info(_Message, State) -> {noreply, State}.

%% Starts one sector unless it is already running on this node.
start_sector_handler(#{sector_id := SectorId} = Config, #{sectors := Sectors} = State) ->
    case find_sector_pid(SectorId, Sectors) of
        {ok, Pid} -> {reply, {error, {already_started, Pid}}, State};
        {error, not_found} ->
            case start_sector_process(Config) of
                {ok, SupervisorPid, ControllerPid} ->
                    %% Keep the supervisor PID so its EXIT message can later
                    %% be matched to the correct sector.
                    {reply, {ok, ControllerPid}, State#{sectors => Sectors#{SectorId => sector_record(SupervisorPid, Config)}}};
                Error -> {reply, Error, State}
            end
    end.

%% Stops every sector on this node.
stop_all_sectors_handler(#{sectors := Sectors} = State) ->
    SectorPids = [Pid || #{supervisor := Pid} <- maps:values(Sectors)],
    StopResult = stop_sector_processes(SectorPids),
    case StopResult of
        graceful -> {reply, ok, State#{sectors => #{}}};
        {forced, Pids} ->
            io:format("[sector] forced shutdown: node=~p supervisors=~p~n", [node(), Pids]),
            {reply, ok, State#{sectors => #{}}};
        {error, _Reason} = Error -> {reply, Error, State}
    end.

%% Returns public information for every hosted sector.
sector_summary(Sectors) ->
    maps:map(
        fun(SectorId, #{started_at := StartedAt}) ->
            {ok, ControllerPid} = sector_supervisor:controller(SectorId),
            #{pid => ControllerPid, node => node(ControllerPid), started_at => StartedAt}
        end,
        Sectors).

%% Finds the controller PID for one hosted sector.
find_sector_pid(SectorId, Sectors) ->
    case maps:find(SectorId, Sectors) of
        {ok, _Sector} -> sector_supervisor:controller(SectorId);
        _ -> {error, not_found}
    end.

%% Starts a sector supervisor and restores the controller snapshot.
start_sector_process(Config) ->
    case sector_supervisor:start_link(Config) of
        {ok, SupervisorPid} ->
            SectorId = maps:get(sector_id, Config),
            {ok, ControllerPid} = sector_supervisor:controller(SectorId),
            %% A new sector starts empty, then receives its saved entities
            %% and statistics from the supplied snapshot.
            ok = sector_controller:restore(ControllerPid, maps:get(snapshot, Config, #{})),
            {ok, SupervisorPid, ControllerPid};
        Error -> Error
    end.

%% Builds the node manager's record for one running sector.
sector_record(SupervisorPid, Config) ->
    #{supervisor => SupervisorPid, config => Config,
        started_at => erlang:monotonic_time(millisecond)}.

%% Recreates a failed sector locally using its latest available snapshot.
restart_sector_handler(SupervisorPid, Reason, #{sectors := Sectors} = State) ->
    case sector_id_by_pid(SupervisorPid, Sectors) of
        %% EXIT messages from supervisors intentionally unlinked during a
        %% cluster operation may arrive late and no longer match a sector.
        error -> State;
        {ok, SectorId} ->
            #{config := Config} = maps:get(SectorId, Sectors),
            Snapshot = latest_snapshot(SectorId, maps:get(snapshot, Config, #{})),
            RecoveryConfig = Config#{snapshot => Snapshot},
            io:format("[sector] supervisor failed: sector=~p node=~p reason=~p; restarting~n",
                [SectorId, node(), Reason]),
            case start_sector_process(RecoveryConfig) of
                {ok, NewSupervisorPid, _NewControllerPid} ->
                    io:format("[sector] recovered: sector=~p node=~p~n", [SectorId, node()]),
                    State#{sectors => Sectors#{SectorId =>
                        sector_record(NewSupervisorPid, RecoveryConfig)}};
                {error, RestartReason} ->
                    io:format("[sector] recovery failed: sector=~p node=~p reason=~p~n",
                        [SectorId, node(), RestartReason]),
                    State#{sectors => maps:remove(SectorId, Sectors)}
            end
    end.

%% Gets the stored snapshot, falling back to the sector's previous one.
latest_snapshot(SectorId, Fallback) ->
    try snapshot_manager:snapshot(SectorId) of
        {ok, Snapshot} -> Snapshot;
        {error, not_found} -> Fallback
    catch
        exit:_Reason -> Fallback
    end.

%% Stops all sector supervisors concurrently so recovery is not delayed per sector.
stop_sector_processes(SectorPids) ->
    Monitors = [{Pid, erlang:monitor(process, Pid)} || Pid <- SectorPids],
    %% These exits are intentional. Remove the links to prevent the normal
    %% restart handler from treating shutdown as a sector failure.
    lists:foreach(fun({Pid, _Ref}) -> unlink(Pid), exit(Pid, shutdown) end, Monitors),
    wait_for_sectors(Monitors, erlang:monotonic_time(millisecond) + 5000).

%% Waits for concurrent shutdowns and force-stops anything left after five seconds.
wait_for_sectors([], _Deadline) -> graceful;
wait_for_sectors(Monitors, Deadline) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {'DOWN', Ref, process, _Pid, _Reason} -> 
            wait_for_sectors([{Pid, MonitorRef} || {Pid, MonitorRef} <- Monitors, MonitorRef =/= Ref], Deadline)
    after Remaining ->
        force_stop_sectors(Monitors)
    end.

%% Force-stops timed-out supervisors and verifies their termination.
force_stop_sectors(Monitors) ->
    Pids = [Pid || {Pid, _Ref} <- Monitors],
    %% kill is used only after the graceful five-second deadline expires.
    lists:foreach(fun({Pid, _Ref}) -> exit(Pid, kill) end, Monitors),
    case wait_for_forced_stops(Monitors, erlang:monotonic_time(millisecond) + 2000) of
        [] -> {forced, Pids};
        Remaining ->
            lists:foreach(fun({_Pid, Ref}) -> erlang:demonitor(Ref, [flush]) end, Remaining),
            {error, {sectors_still_running, [Pid || {Pid, _Ref} <- Remaining]}}
    end.

%% Waits for DOWN confirmations after forced shutdown.
wait_for_forced_stops([], _Deadline) -> [];
wait_for_forced_stops(Monitors, Deadline) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {'DOWN', Ref, process, _Pid, _Reason} ->
            wait_for_forced_stops([{Pid, MonitorRef} || {Pid, MonitorRef} <- Monitors, MonitorRef =/= Ref], Deadline)
    after Remaining -> 
        Monitors
    end.

%% Finds a sector ID from its supervisor PID.
sector_id_by_pid(SupervisorPid, Sectors) ->
    case [SectorId || {SectorId, #{supervisor := Pid}} <- maps:to_list(Sectors), Pid =:= SupervisorPid] of
        [SectorId] -> {ok, SectorId};
        [] -> error
    end.
