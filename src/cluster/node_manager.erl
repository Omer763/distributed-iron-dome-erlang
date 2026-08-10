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

%% Starts the local node manager; used by app_sup.
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Starts a remote sector; used by cluster_coordinator.
start_sector(Node, Config) -> gen_server:call({?MODULE, Node}, {start_sector, Config}, 10000).

%% Stops a worker's sectors; used by cluster_coordinator.
stop_all_sectors(Node) -> gen_server:call({?MODULE, Node}, stop_all_sectors, 15000).

%% Lists a worker's sectors; used by cluster_coordinator.
sectors(Node) -> gen_server:call({?MODULE, Node}, sectors).

%% Confirms worker health; called remotely by cluster_coordinator.
heartbeat() -> ok.

%% Creates an empty worker with no sectors.
init([]) ->
    %% Catch sector exits so a failed sector can be started again.
    process_flag(trap_exit, true),
    {ok, #{sectors => #{}}}.

%% Sends each request to the matching helper.
handle_call({start_sector, #{sector_id := _} = Config}, _From, State) -> start_sector_handler(Config, State);
handle_call(stop_all_sectors, _From, State) -> stop_all_sectors_handler(State);
handle_call(sectors, _From, #{sectors := Sectors} = State) -> {reply, sector_summary(Sectors), State};
handle_call(Request, _From, State) -> {reply, {error, {unsupported_call, Request}}, State}.

%% Ignores messages that this module does not use.
handle_cast(_Message, State) -> {noreply, State}.

%% Restarts a sector when its main process stops.
handle_info({'EXIT', SupervisorPid, Reason}, State) -> {noreply, restart_sector_handler(SupervisorPid, Reason, State)};
handle_info(_Message, State) -> {noreply, State}.

%% Starts one sector unless it is already running on this node.
start_sector_handler(#{sector_id := SectorId} = Config, #{sectors := Sectors} = State) ->
    %% Do not start a second copy on the same node.
    case find_sector_pid(SectorId, Sectors) of
        {ok, Pid} -> {reply, {error, {already_started, Pid}}, State};
        {error, not_found} ->
            case start_sector_process(Config) of
                {ok, SupervisorPid, ControllerPid} ->
                    %% Save the PID so a later exit can be matched to this sector.
                    {reply, {ok, ControllerPid}, State#{sectors => Sectors#{SectorId => sector_record(SupervisorPid, Config)}}};
                Error -> {reply, Error, State}
            end
    end.

%% Stops every sector on this node.
stop_all_sectors_handler(#{sectors := Sectors} = State) ->
    %% Stop all sector trees before clearing the local sector list.
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
            %% Start empty, then restore missiles and counters from the save.
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
    %% Find the sector that belonged to the stopped process.
    case sector_id_by_pid(SupervisorPid, Sectors) of
        %% Ignore old exit messages from sectors stopped by cluster recovery.
        error -> State;
        {ok, SectorId} ->
            #{config := Config} = maps:get(SectorId, Sectors),
            Snapshot = latest_snapshot(SectorId, maps:get(snapshot, Config, #{})),
            %% Start from the newest save instead of starting from zero.
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

%% Stops all sectors at the same time so shutdown stays fast.
stop_sector_processes(SectorPids) ->
    Monitors = [{Pid, erlang:monitor(process, Pid)} || Pid <- SectorPids],
    %% Unlink first so planned shutdowns do not look like sector failures.
    lists:foreach(fun({Pid, _Ref}) -> unlink(Pid), exit(Pid, shutdown) end, Monitors),
    wait_for_sectors(Monitors, erlang:monotonic_time(millisecond) + 5000).

%% Waits five seconds, then force-stops sectors that are still running.
wait_for_sectors([], _Deadline) -> graceful;
wait_for_sectors(Monitors, Deadline) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {'DOWN', Ref, process, _Pid, _Reason} -> 
            wait_for_sectors([{Pid, MonitorRef} || {Pid, MonitorRef} <- Monitors, MonitorRef =/= Ref], Deadline)
    after Remaining ->
        force_stop_sectors(Monitors)
    end.

%% Kills sectors that ignored normal shutdown and checks that they stopped.
force_stop_sectors(Monitors) ->
    Pids = [Pid || {Pid, _Ref} <- Monitors],
    %% Use kill only after normal shutdown had five seconds to finish.
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
