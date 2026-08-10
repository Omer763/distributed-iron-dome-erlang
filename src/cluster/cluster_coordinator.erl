-module(cluster_coordinator).
-behaviour(gen_server).

-export([start_link/0, status/0, shutdown/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(HEARTBEAT_FAILURE_LIMIT, 2).
-define(REJOIN_PROBE_MS, 2000).

%% Starts the cluster coordinator on the coordinator node.
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Returns live nodes and current sector assignments.
status() -> gen_server:call(?MODULE, status).

%% Gracefully stops all worker nodes and the coordinator node.
shutdown() -> gen_server:cast(?MODULE, shutdown).

%% Loads cluster configuration and schedules initial allocation. The
%% coordinator itself is never a candidate: it runs on an external
%% display/control machine outside the pool of worker nodes, so an empty
%% (or fully offline) configured_nodes list means zero sectors get
%% assigned -- not a fallback to running locally.
init([]) ->
    net_kernel:monitor_nodes(true),
    ConfiguredNodes = configured_nodes(),
    {ok, SectorConfigs} = application:get_env(iron_dome, sectors),
    SectorOrder = [maps:get(sector_id, Config) || Config <- SectorConfigs],
    HeartbeatInterval = application:get_env(iron_dome, heartbeat_interval_ms, 100),
    HeartbeatTimeout = application:get_env(iron_dome, heartbeat_timeout_ms, 400),
    io:format("[cluster] coordinator started: node=~p configured_workers=~p~n",
        [node(), ConfiguredNodes]),
    self() ! bootstrap,
    erlang:send_after(HeartbeatInterval, self(), check_heartbeats),
    erlang:send_after(?REJOIN_PROBE_MS, self(), probe_absent_nodes),
    {ok, #{
        configured_nodes => ConfiguredNodes,
        sector_order => SectorOrder,
        sector_configs => maps:from_list([{maps:get(sector_id, C), C} || C <- SectorConfigs]),
        %% Each sector is permanently "home" to whichever configured node's
        %% name ends in the same number (sector_3 -> host3), fixed by that
        %% number, not by whichever node happens to be live at any given
        %% moment. A live node always keeps its own home sector; only a
        %% sector whose home node is currently down gets handed out by
        %% load. This one rule is what decides both who takes over when a
        %% node falls (the least loaded live node claims the orphaned
        %% sector) and what a rejoining node gets back (its own sector,
        %% reclaimed from whoever was covering it).
        home_assignments => home_assignments(SectorOrder, ConfiguredNodes),
        assignments => #{}, live_nodes => [], heartbeat_failures => #{},
        heartbeat_interval => HeartbeatInterval, heartbeat_timeout => HeartbeatTimeout
    }}.

%% Handles coordinator status requests.
handle_call(status, _From, State) -> {reply, State, State};
handle_call(Request, _From, State) -> {reply, {error, {unsupported_call, Request}}, State}.

%% Starts an orderly shutdown without blocking the coordinator.
handle_cast(shutdown, #{live_nodes := LiveNodes} = State) ->
    io:format("[cluster] shutdown started: workers=~p~n", [LiveNodes]),
    _ = spawn(fun() -> stop_cluster(LiveNodes) end),
    {noreply, State};
handle_cast(_Message, State) -> {noreply, State}.

%% Allocates configured sectors across the available hosts at startup.
handle_info(bootstrap, State) -> {noreply, bootstrap_handler(State)};

%% Heartbeat confirmation owns recovery, so native disconnect notices stay quiet.
handle_info({nodedown, _Node}, State) -> {noreply, State};

%% Welcomes back a configured worker that reconnects after being marked
%% down (crash-restart or a healed network partition). Its own view of
%% what it was hosting may be stale -- it never got the message that
%% recovery moved on without it -- so it is cleaned before it is trusted
%% with anything again, never folded into the pool just because a
%% connection exists.
handle_info({nodeup, Node}, #{configured_nodes := Configured, live_nodes := LiveNodes} = State) ->
    case lists:member(Node, Configured) andalso not lists:member(Node, LiveNodes) of
        true ->
            io:format("[cluster] node up: ~p; preparing recovery~n", [Node]),
            Coordinator = self(),
            spawn(fun() -> prepare_rejoin(Coordinator, Node) end),
            {noreply, State};
        false -> {noreply, State}
    end;

%% A reconnected worker was confirmed clean; rebalance it back into the pool.
handle_info({worker_rejoined, Node}, State) ->
    io:format("[cluster] node ready: ~p; starting sector recovery~n", [Node]),
    {noreply, rejoin_worker_handler(Node, State)};

%% A reconnected worker could not be verified clean; keep it excluded
%% rather than risk trusting stale state.
handle_info({worker_rejoin_failed, Node}, #{live_nodes := LiveNodes} = State) ->
    disconnect_worker(Node, LiveNodes),
    {noreply, State};

%% Actively tries to reconnect to every configured node that is not
%% currently live. Erlang connections are lazy -- nothing reconnects
%% just because a node with a known name is reachable again, so a
%% worker that comes back as a genuinely fresh process (a real
%% crash-restart, not just a healed network blip where the connection
%% recovers on its own) would otherwise sit there forever, connectable
%% but never actually contacted. A successful ping here is what makes
%% net_kernel:monitor_nodes report nodeup at all, which is what starts
%% the rejoin in the first place.
handle_info(probe_absent_nodes, #{configured_nodes := Configured, live_nodes := LiveNodes} = State) ->
    lists:foreach(fun(Node) -> net_adm:ping(Node) end, Configured -- LiveNodes),
    erlang:send_after(?REJOIN_PROBE_MS, self(), probe_absent_nodes),
    {noreply, State};

handle_info(check_heartbeats, State) -> {noreply, start_heartbeat_handler(State)};
handle_info({heartbeat_results, CheckedNodes, Results}, State) ->
    {noreply, finish_heartbeat_handler(CheckedNodes, Results, State)};
handle_info(_Message, State) -> {noreply, State}.

%% Checks all workers concurrently without blocking the coordinator.
start_heartbeat_handler(#{live_nodes := LiveNodes, heartbeat_timeout := Timeout} = State) ->
    Coordinator = self(),
    spawn(fun() ->
        Results = try erpc:multicall(LiveNodes, node_manager, heartbeat, [], Timeout)
            catch Class:Reason -> lists:duplicate(length(LiveNodes), {Class, Reason})
        end,
        Coordinator ! {heartbeat_results, LiveNodes, Results}
    end),
    State.

%% Recovers every failure returned by one complete heartbeat round.
finish_heartbeat_handler(CheckedNodes, Results, #{live_nodes := CurrentNodes,
        heartbeat_failures := OldFailures, heartbeat_interval := Interval} = State) ->
    Failures = update_heartbeat_failures(CheckedNodes, Results, CurrentNodes, OldFailures),
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

%% Counts consecutive misses and clears the count after a successful reply.
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

%% Removes every surviving connection to the failed worker before restore.
disconnect_worker(Node, LiveNodes) ->
    erlang:disconnect_node(Node),
    lists:foreach(fun(Survivor) ->
        rpc:cast(Survivor, erlang, disconnect_node, [Node])
    end, lists:delete(Node, LiveNodes)).

%% Performs the initial sector allocation.
bootstrap_handler(#{configured_nodes := ConfiguredNodes, sector_order := SectorOrder,
        sector_configs := SectorConfigs, home_assignments := HomeAssignments} = State) ->
    LiveNodes = available_hosts(ConfiguredNodes),
    io:format("[cluster] startup: online_workers=~p~n", [LiveNodes]),
    Plan = plan_assignments(SectorOrder, LiveNodes, HomeAssignments),
    Assignments = start_planned_sectors(Plan, SectorOrder, SectorConfigs, #{}),
    _ = distribute_assignments(Assignments, LiveNodes),
    State#{assignments => Assignments, live_nodes => LiveNodes}.

%% Removes all failed workers and performs one recovery for the batch.
recover_failed_nodes(FailedNodes, #{assignments := Assignments,
        sector_order := SectorOrder, sector_configs := SectorConfigs,
        live_nodes := OldLiveNodes} = State) ->
    LiveNodes = OldLiveNodes -- FailedNodes,
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

%% Restores and redistributes every sector from one complete checkpoint
%% across whichever nodes are live now. Shared by both directions of a
%% membership change: a node disappearing (Reason = {failed, Nodes}) and
%% a previously-lost node reconnecting and rejoining (Reason =
%% {rejoined, Node}) -- both need the same pause/checkpoint/redistribute
%% cycle to stay consistent, only the reason differs.
rebalance(Reason, LiveNodes, SectorOrder, SectorConfigs, State) ->
    Operation = erlang:unique_integer([monotonic, positive]),
    StartedAt = erlang:monotonic_time(millisecond),
    io:format("[cluster] recovery started: id=~p reason=~p workers=~p~n",
        [Operation, Reason, LiveNodes]),
    graphics_server:set_recovering(true),
    set_simulation_paused(LiveNodes, true),
    case recovery_checkpoint(Reason, SectorOrder) of
        {ok, CheckpointId, RecoverySnapshots} ->
            finish_recovery(Operation, StartedAt, CheckpointId, RecoverySnapshots,
                LiveNodes, SectorOrder, SectorConfigs, State);
        {error, SnapshotError} ->
            abort_recovery(Operation, Reason, SnapshotError, State)
    end.

%% Recreates all sectors from the selected checkpoint.
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

%% Returns the checkpoint age when its ID contains a monotonic timestamp.
checkpoint_age({CheckpointTime, _Sequence}) ->
    max(0, erlang:monotonic_time(millisecond) - CheckpointTime);
checkpoint_age(_CheckpointId) -> unknown.

%% Returns milliseconds elapsed since a monotonic timestamp.
elapsed_ms(StartedAt) -> erlang:monotonic_time(millisecond) - StartedAt.

%% Captures a current paused checkpoint when adding a worker.
recovery_checkpoint({rejoined, _Node}, _SectorOrder) ->
    timer:sleep(config:tick_ms() * 2),
    try snapshot_manager:paused_checkpoint()
    catch exit:Reason -> {error, Reason}
    end;

%% Selects a historical checkpoint when a failed worker cannot be queried.
recovery_checkpoint({failed, _Nodes}, SectorOrder) ->
    case snapshot_manager:latest_checkpoint() of
        {ok, CheckpointId, SectorSnapshots} -> {ok, CheckpointId, SectorSnapshots};
        {error, not_found} ->
            io:format("[cluster] recovery warning: no complete checkpoint; using latest snapshots~n"),
            Snapshots = maps:from_list([{SectorId, latest_snapshot(SectorId)}
                || SectorId <- SectorOrder]),
            {ok, no_complete_checkpoint, Snapshots}
    end.

%% Cancels an unsafe rejoin and resumes the workers that were already trusted.
abort_recovery(Operation, {rejoined, Node}, Reason,
        #{live_nodes := ExistingNodes} = State) ->
    graphics_server:set_recovering(false),
    set_simulation_paused(ExistingNodes, false),
    disconnect_worker(Node, ExistingNodes),
    io:format("[cluster] recovery aborted: id=~p node=~p reason=~p~n",
        [Operation, Node, Reason]),
    State.

%% Pauses or resumes simulation time and reports workers that did not acknowledge.
set_simulation_paused(Nodes, Paused) ->
    Results = [{Node, rpc:call(Node, config, set_paused, [Paused], 2000)} || Node <- Nodes],
    Failures = [{Node, Result} || {Node, Result} <- Results, Result =/= ok],
    case Failures of
        [] -> ok;
        _ -> io:format("[cluster] recovery error: action=~p failures=~p~n",
            [case Paused of true -> pause; false -> resume end, Failures])
    end.

%% Pushes this project's own code and application to a reconnecting
%% node, then stops whatever it still thinks it is hosting, before it
%% can be trusted with anything again. A node that reconnects after a
%% healed network partition (its process never died) already has
%% everything loaded and this is a harmless no-op; a node that was
%% genuinely killed and restarted comes back as a bare, empty VM that
%% does not even have node_manager to call yet, so pushing code first is
%% what makes rejoin work without a manual redeploy either way. Runs off
%% the coordinator's own process since this can take a while; the result
%% comes back as a message so the actual rejoin (a state change) happens
%% on the coordinator itself, not in this spawned process.
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

%% Sends every module this coordinator is itself running to the target
%% node, then loads and starts the application there in the host role,
%% using this coordinator's own live environment as the source of truth
%% -- no project checkout, compiler, or manual redeploy needed on the
%% worker machine, the same way the initial deployment works. Only
%% relevant to a node deployed remotely by deploy.escript, which records
%% where its own compiled code lives in ebin_dir; a node started the
%% traditional way (start_cluster.sh, restart_host.sh) already booted
%% with its own -pa and -config and is already running the application
%% by the time it reconnects, so there is nothing to push -- treating a
%% missing ebin_dir as a failure would permanently exclude every such
%% node the moment it ever reconnects.
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

%% Sends every module this application declares to the target node,
%% read straight from this coordinator's own compiled build on disk --
%% deploy.escript records that directory in ebin_dir precisely so this
%% works, since a module's in-memory code is not reliably retrievable
%% this way: code:get_object_code/1 re-reads from whatever path
%% code:which/1 reports, which is only the bare filename deploy.escript
%% originally loaded it with (no real directory), not the actual bytes
%% already sitting in memory.
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

%% Reads one module's compiled beam file from disk and loads it directly
%% into the target node's code server.
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

%% Loads and starts the host-role application on the target node, using
%% every setting this coordinator is itself currently running with. Does
%% not depend on wx being available on the worker machine, same as the
%% initial deployment.
push_app(Node) ->
    {ok, AppTerms} = application:get_all_key(iron_dome),
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

%% Adds a confirmed-clean worker back into the pool and rebalances every
%% sector across the enlarged set, so the recovered node actually starts
%% carrying its share again instead of sitting idle until a full restart.
rejoin_worker_handler(Node, #{configured_nodes := Configured, live_nodes := LiveNodes,
        sector_order := SectorOrder, sector_configs := SectorConfigs} = State) ->
    case lists:member(Node, Configured) andalso not lists:member(Node, LiveNodes) of
        false ->
            %% Already rejoined by an earlier nodeup, or no longer configured.
            State;
        true ->
            NewLiveNodes = lists:usort([Node | LiveNodes]),
            rebalance({rejoined, Node}, NewLiveNodes, SectorOrder, SectorConfigs, State)
    end.

%% Stops stale sectors without crashing the coordinator if cleanup fails.
safe_stop_all_sectors(Node) ->
    try node_manager:stop_all_sectors(Node) catch exit:Reason -> {error, Reason} end.

%% Copies explicit sector routing to the coordinator and every live worker.
distribute_assignments(Assignments, LiveNodes) ->
    Results = [{Node, rpc:call(Node, config, set_assignments,
        [Assignments], 2000)} || Node <- LiveNodes],
    Failures = [{Node, Result} || {Node, Result} <- Results, Result =/= ok],
    case Failures of
        [] ->
            snapshot_manager:set_assignments(Assignments),
            graphics_server:set_cluster(Assignments, LiveNodes),
            config:set_assignments(Assignments),
            ok;
        _ ->
            io:format("[cluster] routing update failed: ~p~n", [Failures]),
            {error, [Node || {Node, _Result} <- Failures]}
    end.

%% Reserves every available home sector before distributing orphaned sectors by load.
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
    {Plan, _Counts} = lists:foldl(fun(SectorId, {Assigned, Counts}) ->
        [TargetNode | _] = nodes_by_sector_count(LiveNodes, Counts),
        {Assigned#{SectorId => TargetNode},
            maps:update_with(TargetNode, fun(N) -> N + 1 end, 1, Counts)}
    end, {HomePlan, sector_counts(LiveNodes, HomePlan)}, Unassigned),
    Plan.

%% Starts the planned sectors and publishes only assignments that actually started.
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

%% Starts one planned sector and records a truthful assignment result.
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

%% Keeps timeout logs readable instead of printing an entire recovery snapshot.
short_error({timeout, _Call}) -> timeout;
short_error(Reason) -> Reason.

%% Returns configured nodes whose node managers answer.
available_hosts(Nodes) ->
    [Node || Node <- Nodes, host_available(Node)].

%% Checks whether a node has a reachable node manager. The coordinator's
%% own node never runs node_manager, so this is always a remote check.
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

%% Starts a sector while converting remote exits into errors.
safe_start_sector(Node, Config) ->
    try node_manager:start_sector(Node, Config) catch exit:Reason -> {error, Reason} end.

%% Counts assignments already hosted by each node.
sector_counts(Nodes, Assignments) ->
    lists:foldl(fun({_Id, Node}, Counts) -> maps:update_with(Node, fun(N) -> N + 1 end, 1, Counts) end,
        maps:from_list([{Node, 0} || Node <- Nodes]), maps:to_list(Assignments)).

%% Sorts nodes from the fewest assigned sectors to the most, tied nodes
%% broken by lowest index -- the number in the node's own name (host3 ->
%% 3), not its position in whatever order it happened to be typed into
%% CLUSTER_NODES or deploy.escript's arguments. Using list position
%% would have exactly the same problem home_assignments/2 was fixed for:
%% it silently scrambles the moment nodes are listed in any order other
%% than exactly 1,2,3,4. A node whose name has no trailing number sorts
%% last among ties.
nodes_by_sector_count(Nodes, SectorCounts) ->
    lists:sort(fun(NodeA, NodeB) ->
        CountA = maps:get(NodeA, SectorCounts, 0),
        CountB = maps:get(NodeB, SectorCounts, 0),
        case CountA =:= CountB of
            true -> node_number(NodeA) =< node_number(NodeB);
            false -> CountA < CountB
        end
    end, Nodes).

%% Returns the trailing number in a node's own name, or infinity when it
%% has none, so such a node still sorts (last, not first) rather than
%% crashing the comparison.
node_number(Node) ->
    case trailing_number(node_short_name(Node)) of
        {ok, Number} -> Number;
        error -> infinity
    end.

%% Retrieves the latest stored snapshot for failover.
latest_snapshot(SectorId) ->
    try snapshot_manager:snapshot(SectorId) of
        {ok, Snapshot} -> Snapshot;
        {error, not_found} -> #{}
    catch
        exit:_ -> #{}
    end.

%% Adds a non-empty snapshot to a sector configuration.
with_snapshot(Config, Snapshot) when map_size(Snapshot) > 0 -> Config#{snapshot => Snapshot};
with_snapshot(Config, _Snapshot) -> Config.

%% Matches sector_N to whichever configured node's own name ends in the
%% same N (hostN, regardless of what comes before the number or after
%% the '@') -- not by matching list position, which silently scrambles
%% the pairing the moment nodes are listed in any order other than
%% exactly 1,2,3,4 (CLUSTER_NODES and deploy.escript's arguments are
%% both just typed in by hand, in whatever order). A sector or node
%% whose name has no trailing number, or no match on the other side,
%% gets no home and is always allocated by load.
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

%% Extracts the trailing digits from an atom's name, e.g. sector_3 -> 3,
%% host12 -> 12. Returns error when the name does not end in a digit.
trailing_number(Atom) ->
    case lists:reverse(atom_to_list(Atom)) of
        [Digit | _] = Reversed when Digit >= $0, Digit =< $9 ->
            Digits = lists:takewhile(fun(C) -> C >= $0 andalso C =< $9 end, Reversed),
            {ok, list_to_integer(lists:reverse(Digits))};
        _ -> error
    end.

%% Returns the short name part of a node, e.g. host3 from
%% 'host3@10.0.0.44'.
node_short_name(Node) ->
    [ShortName | _] = string:split(atom_to_list(Node), "@"),
    list_to_atom(ShortName).

%% Reads cluster nodes from environment or application configuration.
configured_nodes() ->
    case os:getenv("CLUSTER_NODES") of
        Value when Value =:= false; Value =:= "" ->
            {ok, Nodes} = application:get_env(iron_dome, cluster_nodes),
            Nodes;
        NodeText -> [list_to_atom(string:trim(Name)) || Name <- string:split(NodeText, ",", all)]
    end.

%% Stops remote OTP nodes first and then stops the local VM.
stop_cluster(LiveNodes) ->
    RemoteNodes = lists:delete(node(), LiveNodes),
    lists:foreach(fun(Node) -> rpc:cast(Node, init, stop, []) end, RemoteNodes),
    timer:sleep(200),
    init:stop().
