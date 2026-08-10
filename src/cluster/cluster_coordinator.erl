-module(cluster_coordinator).
-behaviour(gen_server).

-export([start_link/0, status/0, shutdown/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(HEARTBEAT_FAILURE_LIMIT, 2).
-define(REJOIN_PROBE_MS, 2000).

%% Starts the cluster coordinator. Used by app_sup.
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Returns the online nodes and the node running each sector.
%% graphics and the deployment scripts use this information.
status() -> gen_server:call(?MODULE, status).

%% Stops all worker nodes and then stops the coordinator.
%% graphics and the deployment scripts use it.
shutdown() -> gen_server:cast(?MODULE, shutdown).

%% Loads the nodes and sectors, then starts the cluster timers.
%% The coordinator never hosts sectors, even when all workers are offline.
init([]) ->
    net_kernel:monitor_nodes(true),
    ConfiguredNodes = configured_nodes(),
    {ok, SectorConfigs} = application:get_env(iron_dome, sectors),
    SectorOrder = [maps:get(sector_id, Config) || Config <- SectorConfigs],
    HeartbeatInterval = application:get_env(iron_dome, heartbeat_interval_ms, 100),
    HeartbeatTimeout = application:get_env(iron_dome, heartbeat_timeout_ms, 400),
    io:format("[cluster] coordinator started: node=~p configured_workers=~p~n",
        [node(), ConfiguredNodes]),
    %% Start sector setup after this function finishes.
    self() ! bootstrap,
    %% Check online nodes often and look for returning nodes every two seconds.
    erlang:send_after(HeartbeatInterval, self(), check_heartbeats),
    erlang:send_after(?REJOIN_PROBE_MS, self(), probe_absent_nodes),
    {ok, #{
        configured_nodes => ConfiguredNodes,
        sector_order => SectorOrder,
        sector_configs => maps:from_list([{maps:get(sector_id, C), C} || C <- SectorConfigs]),
        %% Matching numbers connect a sector to its normal node: sector_3 -> host3.
        %% Another node runs the sector while its normal node is offline.
        home_assignments => home_assignments(SectorOrder, ConfiguredNodes),
        assignments => #{}, live_nodes => [], heartbeat_failures => #{},
        heartbeat_interval => HeartbeatInterval, heartbeat_timeout => HeartbeatTimeout
    }}.

%% Handles requests for cluster information.
handle_call(status, _From, State) -> {reply, State, State};
handle_call(Request, _From, State) -> {reply, {error, {unsupported_call, Request}}, State}.

%% Handles the request to stop the cluster.
handle_cast(shutdown, #{live_nodes := LiveNodes} = State) ->
    io:format("[cluster] shutdown started: workers=~p~n", [LiveNodes]),
    _ = spawn(fun() -> stop_cluster(LiveNodes) end),
    {noreply, State};
handle_cast(_Message, State) -> {noreply, State}.

%% Finds online nodes and starts the sectors when the application starts.
handle_info(bootstrap, State) -> {noreply, bootstrap_handler(State)};

%% Ignore this message because heartbeat checks decide when a node has failed.
handle_info({nodedown, _Node}, State) -> {noreply, State};

%% Checks and cleans a node that came back online.
handle_info({nodeup, Node}, #{configured_nodes := Configured, live_nodes := LiveNodes} = State) ->
    {noreply, nodeup_handler(Node, Configured, LiveNodes, State)};

%% Adds a clean node back and gives sectors back to it.
handle_info({worker_rejoined, Node}, State) ->
    io:format("[cluster] node ready: ~p; starting sector recovery~n", [Node]),
    {noreply, rejoin_worker_handler(Node, State)};

%% Disconnects a returning node when its old state could not be cleared.
handle_info({worker_rejoin_failed, Node}, #{live_nodes := LiveNodes} = State) ->
    disconnect_worker(Node, LiveNodes),
    {noreply, State};

%% Pings missing nodes so the coordinator notices when they return.
handle_info(probe_absent_nodes, #{configured_nodes := Configured, live_nodes := LiveNodes} = State) ->
    lists:foreach(fun(Node) -> net_adm:ping(Node) end, Configured -- LiveNodes),
    erlang:send_after(?REJOIN_PROBE_MS, self(), probe_absent_nodes),
    {noreply, State};

%% Starts one check of all online workers.
handle_info(check_heartbeats, State) -> {noreply, start_heartbeat_handler(State)};
%% Uses the worker replies to find failed nodes.
handle_info({heartbeat_results, CheckedNodes, Results}, State) ->
    {noreply, finish_heartbeat_handler(CheckedNodes, Results, State)};
handle_info(_Message, State) -> {noreply, State}.

%% Starts cleanup when a configured node comes back online.
nodeup_handler(Node, Configured, LiveNodes, State) ->
    case lists:member(Node, Configured) andalso not lists:member(Node, LiveNodes) of
        true ->
            io:format("[cluster] node up: ~p; preparing recovery~n", [Node]),
            Coordinator = self(),
            spawn(fun() -> prepare_rejoin(Coordinator, Node) end),
            State;
        false -> State
    end.

%% Checks all workers at the same time without stopping other cluster work.
start_heartbeat_handler(#{live_nodes := LiveNodes, heartbeat_timeout := Timeout} = State) ->
    Coordinator = self(),
    spawn(fun() ->
        Results = try erpc:multicall(LiveNodes, node_manager, heartbeat, [], Timeout)
            catch Class:Reason -> lists:duplicate(length(LiveNodes), {Class, Reason})
        end,
        Coordinator ! {heartbeat_results, LiveNodes, Results}
    end),
    State.

%% Counts failed checks and starts recovery for dead nodes.
finish_heartbeat_handler(CheckedNodes, Results, #{live_nodes := CurrentNodes,
        heartbeat_failures := OldFailures, heartbeat_interval := Interval} = State) ->
    Failures = update_heartbeat_failures(CheckedNodes, Results, CurrentNodes, OldFailures),
    %% A node is dead only after several failed checks in a row.
    FailedNodes = [Node || {Node, Count} <- maps:to_list(Failures),
        Count >= ?HEARTBEAT_FAILURE_LIMIT],
    lists:foreach(fun(Node) -> disconnect_worker(Node, CurrentNodes) end, FailedNodes),
    CheckedState = State#{heartbeat_failures => maps:without(FailedNodes, Failures)},
    NewState = case FailedNodes of
        [] -> CheckedState;
        _ -> recover_failed_nodes(FailedNodes, CheckedState)
    end,
    erlang:send_after(Interval, self(), check_heartbeats),
    NewState.

%% Counts failed checks in a row and clears the count after a good reply.
update_heartbeat_failures(CheckedNodes, Results, CurrentNodes, OldFailures) ->
    lists:foldl(fun({Node, Result}, Failures) ->
        case lists:member(Node, CurrentNodes) of
            false -> Failures;
            true when Result =:= {ok, ok} ->
                maps:remove(Node, Failures);
            true ->
                Failures#{Node => maps:get(Node, Failures, 0) + 1}
        end
    end, OldFailures, lists:zip(CheckedNodes, Results)).

%% Disconnects a failed node from the coordinator and all other workers.
disconnect_worker(Node, LiveNodes) ->
    erlang:disconnect_node(Node),
    lists:foreach(fun(Survivor) ->
        rpc:cast(Survivor, erlang, disconnect_node, [Node])
    end, lists:delete(Node, LiveNodes)).

%% Finds online workers and starts each sector on one of them.
bootstrap_handler(#{configured_nodes := ConfiguredNodes, sector_order := SectorOrder,
        sector_configs := SectorConfigs, home_assignments := HomeAssignments} = State) ->
    LiveNodes = available_hosts(ConfiguredNodes),
    io:format("[cluster] startup: online_workers=~p~n", [LiveNodes]),
    Plan = plan_assignments(SectorOrder, LiveNodes, HomeAssignments),
    Assignments = start_planned_sectors(Plan, SectorOrder, SectorConfigs, #{}),
    _ = distribute_assignments(Assignments, LiveNodes),
    State#{assignments => Assignments, live_nodes => LiveNodes}.

%% Removes failed nodes and moves their sectors to online nodes.
recover_failed_nodes(FailedNodes, #{assignments := Assignments,
        sector_order := SectorOrder, sector_configs := SectorConfigs,
        live_nodes := OldLiveNodes} = State) ->
    LiveNodes = OldLiveNodes -- FailedNodes,
    %% Find only the sectors that were running on the failed nodes.
    FailedSectors = [SectorId || {SectorId, AssignedNode} <- maps:to_list(Assignments),
        lists:member(AssignedNode, FailedNodes)],
    io:format("[cluster] node down: ~p affected_sectors=~p~n", [FailedNodes, FailedSectors]),
    case FailedSectors of
        [] ->
            _ = distribute_assignments(Assignments, LiveNodes),
            State#{live_nodes => LiveNodes};
        _ ->
            rebalance({failed, FailedNodes}, LiveNodes, SectorOrder, SectorConfigs, State)
    end.

%% Pauses the simulation and moves sectors using a saved cluster state.
rebalance(Reason, LiveNodes, SectorOrder, SectorConfigs, State) ->
    Operation = erlang:unique_integer([monotonic, positive]),
    StartedAt = erlang:monotonic_time(millisecond),
    io:format("[cluster] recovery started: id=~p reason=~p workers=~p~n",
        [Operation, Reason, LiveNodes]),
    graphics_server:set_recovering(true),
    %% Stop simulation time so every restored sector starts at the same point.
    set_simulation_paused(LiveNodes, true),
    case recovery_checkpoint(Reason, SectorOrder) of
        {ok, CheckpointId, RecoverySnapshots} ->
            finish_recovery(Operation, StartedAt, CheckpointId, RecoverySnapshots,
                LiveNodes, SectorOrder, SectorConfigs, State);
        {error, SnapshotError} ->
            abort_recovery(Operation, Reason, SnapshotError, State)
    end.

%% Stops old sectors and starts them again from the saved state.
finish_recovery(Operation, StartedAt, CheckpointId, RecoverySnapshots,
        LiveNodes, SectorOrder, SectorConfigs, #{home_assignments := HomeAssignments} = State) ->
    io:format("[cluster] recovery checkpoint: id=~p checkpoint=~p age=~pms~n",
        [Operation, CheckpointId, checkpoint_age(CheckpointId)]),
    lists:foreach(fun(Node) ->
        case safe_stop_all_sectors(Node) of
            ok -> ok;
            Error -> io:format("[cluster] recovery error: id=~p action=clear node=~p reason=~p~n",
                [Operation, Node, Error])
        end
    end, LiveNodes),
    %% Make a new plan because the list of online nodes has changed.
    Plan = plan_assignments(SectorOrder, LiveNodes, HomeAssignments),
    NewAssignments = start_planned_sectors(
        Plan, SectorOrder, SectorConfigs, RecoverySnapshots),
    distribute_assignments(NewAssignments, LiveNodes),
    graphics_server:set_recovering(false),
    set_simulation_paused(LiveNodes, false),
    MissingSectors = [SectorId || SectorId <- SectorOrder, not maps:is_key(SectorId, NewAssignments)],
    io:format("[cluster] recovery complete: id=~p duration=~pms assignments=~p missing=~p~n",
        [Operation, elapsed_ms(StartedAt), NewAssignments, MissingSectors]),
    State#{assignments => NewAssignments, live_nodes => LiveNodes}.

%% Returns how many milliseconds ago the state was saved.
checkpoint_age({CheckpointTime, _Sequence}) ->
    max(0, erlang:monotonic_time(millisecond) - CheckpointTime);
checkpoint_age(_CheckpointId) -> unknown.

%% Returns how many milliseconds passed since the given time.
elapsed_ms(StartedAt) -> erlang:monotonic_time(millisecond) - StartedAt.

%% Makes a new save before adding a returning node.
recovery_checkpoint({rejoined, _Node}, _SectorOrder) ->
    %% Wait for in-progress missile updates to finish before saving.
    timer:sleep(config:tick_ms() * 2),
    try snapshot_manager:paused_checkpoint()
    catch exit:Reason -> {error, Reason}
    end;

%% Uses the latest full save after a node fails.
recovery_checkpoint({failed, _Nodes}, SectorOrder) ->
    case snapshot_manager:latest_checkpoint() of
        {ok, CheckpointId, SectorSnapshots} -> {ok, CheckpointId, SectorSnapshots};
        {error, not_found} ->
            io:format("[cluster] recovery warning: no complete checkpoint; using latest snapshots~n"),
            %% Fall back to separate sector saves when no full save exists.
            Snapshots = maps:from_list([{SectorId, latest_snapshot(SectorId)}
                || SectorId <- SectorOrder]),
            {ok, no_complete_checkpoint, Snapshots}
    end.

%% Cancels recovery when a returning node could not be added safely.
abort_recovery(Operation, {rejoined, Node}, Reason,
        #{live_nodes := ExistingNodes} = State) ->
    graphics_server:set_recovering(false),
    set_simulation_paused(ExistingNodes, false),
    disconnect_worker(Node, ExistingNodes),
    io:format("[cluster] recovery aborted: id=~p node=~p reason=~p~n",
        [Operation, Node, Reason]),
    State.

%% Pauses or resumes simulation time on all given nodes.
set_simulation_paused(Nodes, Paused) ->
    Results = [{Node, rpc:call(Node, config, set_paused, [Paused], 2000)} || Node <- Nodes],
    Failures = [{Node, Result} || {Node, Result} <- Results, Result =/= ok],
    case Failures of
        [] -> ok;
        _ -> io:format("[cluster] recovery error: action=~p failures=~p~n",
            [case Paused of true -> pause; false -> resume end, Failures])
    end.

%% Loads the project on a returning node and removes its old sectors.
prepare_rejoin(Coordinator, Node) ->
    case push_project(Node) of
        ok ->
            _ = rpc:call(Node, config, set_paused, [true], 1000),
            case safe_stop_all_sectors(Node) of
                ok ->
                    Coordinator ! {worker_rejoined, Node};
                Error ->
                    io:format("[cluster] node recovery failed: node=~p action=clean reason=~p~n",
                        [Node, Error]),
                    Coordinator ! {worker_rejoin_failed, Node}
            end;
        {error, Reason} ->
            io:format("[cluster] node recovery failed: node=~p action=deploy reason=~p~n",
                [Node, Reason]),
            Coordinator ! {worker_rejoin_failed, Node}
    end.

%% Sends the project to a returning node when remote deployment is enabled.
%% A node started locally already has the project files.
push_project(Node) ->
    case application:get_env(iron_dome, ebin_dir) of
        {ok, _EbinDir} ->
            case push_modules(Node) of
                ok -> push_app(Node);
                Error -> Error
            end;
        undefined ->
            ok
    end.

%% Sends every compiled project module to one node.
push_modules(Node) ->
    {ok, EbinDir} = application:get_env(iron_dome, ebin_dir),
    {ok, Modules} = application:get_key(iron_dome, modules),
    Failures = lists:filtermap(
        fun(Module) ->
            case push_module(Node, EbinDir, Module) of
                ok -> false;
                {error, Reason} -> {true, Reason}
            end
        end,
        Modules
    ),
    case Failures of
        [] -> ok;
        _ -> {error, {modules_failed, Failures}}
    end.

%% Reads one compiled module and loads it on another node.
push_module(Node, EbinDir, Module) ->
    Path = filename:join(EbinDir, atom_to_list(Module) ++ ".beam"),
    case file:read_file(Path) of
        {ok, Binary} ->
            case rpc:call(Node, code, load_binary, [Module, Path, Binary]) of
                {module, Module} -> ok;
                Result -> {error, {Module, Result}}
            end;
        {error, Reason} -> {error, {Module, {read_failed, Reason}}}
    end.

%% Starts the application as a worker with the coordinator's settings.
push_app(Node) ->
    {ok, AppTerms} = application:get_all_key(iron_dome),
    %% Worker nodes do not need the wx graphics application.
    HostApplications = lists:delete(wx, proplists:get_value(applications, AppTerms, [])),
    HostAppTerms = lists:keystore(applications, 1, AppTerms, {applications, HostApplications}),
    HostEnv = lists:foldl(
        fun({Key, Value}, Env) -> lists:keystore(Key, 1, Env, {Key, Value}) end,
        application:get_all_env(iron_dome),
        [
            {role, host},
            {graphics_enabled, false},
            {cluster_nodes, []},
            {coordinator_node, node()}
        ]
    ),
    Spec = {application, iron_dome, lists:keystore(env, 1, HostAppTerms, {env, HostEnv})},
    _ = rpc:call(Node, application, stop, [iron_dome]),
    _ = rpc:call(Node, application, unload, [iron_dome]),
    case rpc:call(Node, application, load, [Spec]) of
        ok ->
            case rpc:call(Node, application, ensure_all_started, [iron_dome]) of
                {ok, _Started} -> ok;
                StartError -> {error, {start_failed, StartError}}
            end;
        LoadError -> {error, {load_failed, LoadError}}
    end.

%% Adds a clean returning node and moves sectors back to it.
rejoin_worker_handler(Node, #{configured_nodes := Configured, live_nodes := LiveNodes,
        sector_order := SectorOrder, sector_configs := SectorConfigs} = State) ->
    case lists:member(Node, Configured) andalso not lists:member(Node, LiveNodes) of
        false ->
            %% Ignore a duplicate message or a node removed from the config.
            State;
        true ->
            NewLiveNodes = lists:usort([Node | LiveNodes]),
            rebalance({rejoined, Node}, NewLiveNodes, SectorOrder, SectorConfigs, State)
    end.

%% Stops every sector on a node and returns an error instead of crashing.
safe_stop_all_sectors(Node) ->
    try node_manager:stop_all_sectors(Node) catch exit:Reason -> {error, Reason} end.

%% Sends the new sector locations to every part of the cluster.
distribute_assignments(Assignments, LiveNodes) ->
    Results = [{Node, rpc:call(Node, config, set_assignments,
        [Assignments], 2000)} || Node <- LiveNodes],
    Failures = [{Node, Result} || {Node, Result} <- Results, Result =/= ok],
    case Failures of
        [] ->
            %% Publish the new locations only after every worker accepted them.
            snapshot_manager:set_assignments(Assignments),
            graphics_server:set_cluster(Assignments, LiveNodes),
            config:set_assignments(Assignments),
            ok;
        _ ->
            io:format("[cluster] routing update failed: ~p~n", [Failures]),
            {error, [Node || {Node, _Result} <- Failures]}
    end.

%% Gives sectors to their normal nodes, then balances the remaining sectors.
plan_assignments(_SectorOrder, [], _HomeAssignments) -> #{};
plan_assignments(SectorOrder, LiveNodes, HomeAssignments) ->
    HomePlan = lists:foldl(fun(SectorId, Plan) ->
        HomeNode = maps:get(SectorId, HomeAssignments, undefined),
        case lists:member(HomeNode, LiveNodes) of
            true -> Plan#{SectorId => HomeNode};
            false -> Plan
        end
    end, #{}, SectorOrder),
    Unassigned = [SectorId || SectorId <- SectorOrder,
        not maps:is_key(SectorId, HomePlan)],
    %% Always give the next sector to the node with the fewest sectors.
    {Plan, _Counts} = lists:foldl(fun(SectorId, {Assigned, Counts}) ->
        [TargetNode | _] = nodes_by_sector_count(LiveNodes, Counts),
        {Assigned#{SectorId => TargetNode},
            maps:update_with(TargetNode, fun(N) -> N + 1 end, 1, Counts)}
    end, {HomePlan, sector_counts(LiveNodes, HomePlan)}, Unassigned),
    Plan.

%% Starts every planned sector and keeps only successful assignments.
start_planned_sectors(Plan, SectorOrder, SectorConfigs, RecoverySnapshots) ->
    lists:foldl(fun(SectorId, Started) ->
        case maps:find(SectorId, Plan) of
            error -> Started;
            {ok, TargetNode} ->
                Config = maps:get(SectorId, SectorConfigs),
                RecoveryConfig = with_snapshot(
                    Config, maps:get(SectorId, RecoverySnapshots, #{})),
                start_planned_sector(SectorId, TargetNode, RecoveryConfig, Started)
        end
    end, #{}, SectorOrder).

%% Starts one sector and records its node only when startup worked.
start_planned_sector(SectorId, TargetNode, Config, Assignments) ->
    case safe_start_sector(TargetNode, Config) of
        {ok, _Pid} ->
            io:format("[cluster] sector started: sector=~p node=~p~n",
                [SectorId, TargetNode]),
            Assignments#{SectorId => TargetNode};
        {error, {already_started, Pid}} when node(Pid) =:= TargetNode ->
            Assignments#{SectorId => TargetNode};
        {error, {already_started, Pid}} ->
            io:format("[cluster] sector start failed: sector=~p stale_node=~p target_node=~p~n",
                [SectorId, node(Pid), TargetNode]),
            Assignments;
        {error, Reason} ->
            io:format("[cluster] sector start failed: sector=~p node=~p reason=~p~n",
                [SectorId, TargetNode, short_error(Reason)]),
            Assignments
    end.

%% Shows a short timeout error instead of printing the full saved state.
short_error({timeout, _Call}) -> timeout;
short_error(Reason) -> Reason.

%% Returns the configured nodes that are online and ready.
available_hosts(Nodes) ->
    [Node || Node <- Nodes, host_available(Node)].

%% Checks whether a worker node is online and its node_manager answers.
host_available(Node) ->
    case net_adm:ping(Node) of
        pong ->
            try node_manager:sectors(Node) of
                _ -> true
            catch
                exit:_ -> false
            end;
        pang ->
            false
    end.

%% Starts a sector and returns remote crashes as normal errors.
safe_start_sector(Node, Config) ->
    try node_manager:start_sector(Node, Config) catch exit:Reason -> {error, Reason} end.

%% Counts how many sectors each node runs.
sector_counts(Nodes, Assignments) ->
    lists:foldl(fun({_Id, Node}, Counts) -> maps:update_with(Node, fun(N) -> N + 1 end, 1, Counts) end,
        maps:from_list([{Node, 0} || Node <- Nodes]), maps:to_list(Assignments)).

%% Sorts nodes by sector count, then by the number in their names.
nodes_by_sector_count(Nodes, SectorCounts) ->
    lists:sort(fun(NodeA, NodeB) ->
        CountA = maps:get(NodeA, SectorCounts, 0),
        CountB = maps:get(NodeB, SectorCounts, 0),
        case CountA =:= CountB of
            true -> node_number(NodeA) =< node_number(NodeB);
            false -> CountA < CountB
        end
    end, Nodes).

%% Returns the number at the end of a node name.
%% A name without a number is placed last.
node_number(Node) ->
    case trailing_number(node_short_name(Node)) of
        {ok, Number} -> Number;
        error -> infinity
    end.

%% Gets the latest saved state for one sector.
latest_snapshot(SectorId) ->
    try snapshot_manager:snapshot(SectorId) of
        {ok, Snapshot} -> Snapshot;
        {error, not_found} -> #{}
    catch
        exit:_ -> #{}
    end.

%% Adds saved state to a sector when saved state exists.
with_snapshot(Config, Snapshot) when map_size(Snapshot) > 0 -> Config#{snapshot => Snapshot};
with_snapshot(Config, _Snapshot) -> Config.

%% Matches sector_N with hostN.
%% Sectors without a match are assigned by sector count.
home_assignments(SectorOrder, ConfiguredNodes) ->
    NodesByNumber = maps:from_list([
        {Number, Node}
     || Node <- ConfiguredNodes,
        {ok, Number} <- [trailing_number(node_short_name(Node))]
    ]),
    maps:from_list([
        {SectorId, Node}
     || SectorId <- SectorOrder,
        {ok, Number} <- [trailing_number(SectorId)],
        {ok, Node} <- [maps:find(Number, NodesByNumber)]
    ]).

%% Gets the number at the end of a name, such as 3 from sector_3.
trailing_number(Atom) ->
    case lists:reverse(atom_to_list(Atom)) of
        [Digit | _] = Reversed when Digit >= $0, Digit =< $9 ->
            Digits = lists:takewhile(fun(C) -> C >= $0 andalso C =< $9 end, Reversed),
            {ok, list_to_integer(lists:reverse(Digits))};
        _ -> error
    end.

%% Gets the part before @, such as host3 from host3@10.0.0.44.
node_short_name(Node) ->
    [ShortName | _] = string:split(atom_to_list(Node), "@"),
    list_to_atom(ShortName).

%% Reads worker nodes from CLUSTER_NODES or the application settings.
configured_nodes() ->
    case os:getenv("CLUSTER_NODES") of
        Value when Value =:= false; Value =:= "" ->
            {ok, Nodes} = application:get_env(iron_dome, cluster_nodes),
            Nodes;
        NodeText -> [list_to_atom(string:trim(Name)) || Name <- string:split(NodeText, ",", all)]
    end.

%% Stops all worker nodes and then stops the coordinator node.
stop_cluster(LiveNodes) ->
    RemoteNodes = lists:delete(node(), LiveNodes),
    lists:foreach(fun(Node) -> rpc:cast(Node, init, stop, []) end, RemoteNodes),
    timer:sleep(200),
    init:stop().
