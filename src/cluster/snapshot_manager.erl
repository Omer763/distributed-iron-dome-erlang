-module(snapshot_manager).
-behaviour(gen_server).

-export([start_link/0, snapshot/1, snapshots/0, latest_checkpoint/0, paused_checkpoint/0,
    set_assignments/1, store_live_snapshot/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% Starts the snapshot manager. Used by app_sup.
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Returns the latest snapshot for one sector.
%% cluster_coordinator and node_manager use it after a node fails.
snapshot(SectorId) ->
    %% A worker asks the coordinator because the cache is not on the worker.
    case ets:whereis(snapshot_cache) of
        undefined -> gen_server:call(server(), {snapshot, SectorId});
        _Table -> lookup_snapshot(SectorId)
    end.

%% Returns the latest snapshots for all sectors.
%% graphics_server uses them to draw the simulation.
snapshots() ->
    %% On the coordinator, read the cache directly because it is faster.
    case ets:whereis(snapshot_cache) of
        undefined -> gen_server:call(server(), snapshots);
        _Table -> maps:from_list(ets:tab2list(snapshot_cache))
    end.

%% Returns the latest saved state of the whole cluster.
%% cluster_coordinator uses it after a node fails.
latest_checkpoint() -> gen_server:call(server(), latest_checkpoint).

%% Saves the whole cluster while the simulation is paused.
%% cluster_coordinator uses it before moving sectors between nodes.
paused_checkpoint() -> gen_server:call(server(), paused_checkpoint, 3000).

%% Saves which node runs each sector.
%% cluster_coordinator uses it when sectors move between nodes.
set_assignments(Assignments) ->
    gen_server:cast(server(), {assignments, Assignments}).

%% Saves one sector for the graphics screen.
%% sector_controller sends this update regularly.
store_live_snapshot(SectorId, Snapshot) ->
    gen_server:cast(server(), {live_snapshot, SectorId, Snapshot}).

%% Creates the cache and starts the save timer.
init([]) ->
    %% ETS lets graphics read often without stopping new saves.
    Table = ets:new(snapshot_cache, [named_table, protected, set, {read_concurrency, true}]),
    Interval = application:get_env(iron_dome, snapshot_interval_ms, 100),
    HistoryMs = application:get_env(iron_dome, checkpoint_history_ms, 5000),
    SectorIds = [maps:get(sector_id, Config) || Config <- application:get_env(iron_dome, sectors, [])],
    erlang:send_after(Interval, self(), capture_checkpoint),
    {ok, #{table => Table, assignments => #{}, sector_ids => SectorIds,
        interval => Interval, history_limit => max(2, HistoryMs div Interval),
        history => [], capture_in_progress => false}}.

%% Handles requests for saved states.
handle_call({snapshot, SectorId}, _From, State) ->
    Reply = lookup_snapshot(SectorId),
    {reply, Reply, State};
handle_call(snapshots, _From, #{table := Table} = State) ->
    {reply, maps:from_list(ets:tab2list(Table)), State};
handle_call(latest_checkpoint, _From, #{history := History} = State) ->
    latest_checkpoint_handler(History, State);
handle_call(paused_checkpoint, _From, #{sector_ids := SectorIds, assignments := Assignments} = State) ->
    paused_checkpoint_handler(SectorIds, Assignments, State);
handle_call(Request, _From, State) -> {reply, {error, {unsupported_call, Request}}, State}.

%% Saves sector owners and graphics updates.
handle_cast({assignments, Assignments}, State) ->
    {noreply, State#{assignments => Assignments}};
handle_cast({live_snapshot, SectorId, #{host := Host} = Snapshot},
        #{table := Table, assignments := Assignments} = State) ->
    {noreply, live_snapshot_handler(SectorId, Host, Snapshot, Table, Assignments, State)};
handle_cast(_Message, State) -> {noreply, State}.

%% Starts a timed save only when another save is not running.
handle_info(capture_checkpoint, #{capture_in_progress := false, sector_ids := SectorIds,
        assignments := Assignments, interval := Interval} = State) ->
    {noreply, capture_checkpoint_handler(SectorIds, Assignments, Interval, State)};
handle_info(capture_checkpoint, #{interval := Interval} = State) ->
    erlang:send_after(Interval, self(), capture_checkpoint),
    {noreply, State};

%% Saves the result only when all current sector owners replied.
handle_info({checkpoint, CheckpointId, SectorSnapshots}, State) ->
    checkpoint_handler(CheckpointId, SectorSnapshots, State);
handle_info(_Message, State) -> {noreply, State}.

%% Returns the newest full save, if one exists.
latest_checkpoint_handler([{CheckpointId, SectorSnapshots} | _], State) ->
    {reply, {ok, CheckpointId, SectorSnapshots}, State};
latest_checkpoint_handler([], State) ->
    {reply, {error, not_found}, State}.

%% Gets and saves the state of every sector.
paused_checkpoint_handler(SectorIds, Assignments, State) ->
    CheckpointId = checkpoint_id(),
    SectorSnapshots = request_snapshots(SectorIds, Assignments, 600),
    case store_checkpoint(CheckpointId, SectorSnapshots, State) of
        {{ok, NormalizedSnapshots}, NewState} ->
            {reply, {ok, CheckpointId, NormalizedSnapshots}, NewState};
        {{error, incomplete}, NewState} ->
            {reply, {error, {incomplete, maps:keys(SectorSnapshots)}}, NewState}
    end.

%% Saves a sector only when it came from the node running that sector.
live_snapshot_handler(SectorId, Host, Snapshot, Table, Assignments, State) ->
    case maps:get(SectorId, Assignments, undefined) of
        Host -> ets:insert(Table, {SectorId, Snapshot});
        _OtherOwner -> ok
    end,
    State.

%% Starts one save round and sets the next timer.
capture_checkpoint_handler(SectorIds, Assignments, Interval, State) ->
    Manager = self(),
    CheckpointId = checkpoint_id(),
    %% Another process collects the data so this manager stays free.
    spawn(fun() -> capture_all(Manager, CheckpointId, SectorIds, Assignments) end),
    erlang:send_after(Interval, self(), capture_checkpoint),
    State#{capture_in_progress => true}.

%% Checks and saves one result in the recovery history.
checkpoint_handler(CheckpointId, SectorSnapshots,
        State) ->
    {_Result, NewState} = store_checkpoint(CheckpointId, SectorSnapshots, State),
    {noreply, NewState#{capture_in_progress => false}}.

%% Checks and saves one full cluster state.
store_checkpoint(CheckpointId, SectorSnapshots,
        #{table := Table, assignments := Assignments, sector_ids := SectorIds,
          history := History, history_limit := Limit} = State) ->
    %% Recovery needs every sector from the node that currently runs it.
    Valid = length(SectorIds) =:= map_size(SectorSnapshots) andalso
        lists:all(fun(SectorId) ->
            Snapshot = maps:get(SectorId, SectorSnapshots),
            maps:get(host, Snapshot, undefined) =:= maps:get(SectorId, Assignments, undefined)
        end, SectorIds),
    %% Good sector updates can still update graphics when the full save fails.
    CurrentSnapshots = maps:filter(fun(SectorId, Snapshot) ->
        maps:get(host, Snapshot, undefined) =:= maps:get(SectorId, Assignments, undefined)
    end, SectorSnapshots),
    maps:foreach(fun(SectorId, Snapshot) -> ets:insert(Table, {SectorId, Snapshot}) end,
        CurrentSnapshots),
    case Valid of
        true ->
            %% A moving missile may appear in both its old and new sectors.
            NormalizedSnapshots = remove_orphan_interceptors(
                normalize_entities(SectorSnapshots)),
            %% Keep only the newest saved states that fit in history.
            Sorted = lists:sort(fun({IdA, _}, {IdB, _}) -> IdA > IdB end,
                [{CheckpointId, NormalizedSnapshots} | History]),
            NewHistory = lists:sublist(Sorted, Limit),
            [{_NewestId, NewestSnapshots} | _] = NewHistory,
            %% Use the newest save because an older save may finish later.
            maps:foreach(fun(SectorId, Snapshot) ->
                ets:insert(Table, {SectorId, Snapshot})
            end, NewestSnapshots),
            {{ok, NormalizedSnapshots}, State#{history => NewHistory}};
        false -> {{error, incomplete}, State}
    end.

%% Creates an ID that can be sorted by save time.
checkpoint_id() ->
    {erlang:monotonic_time(millisecond),
        erlang:unique_integer([monotonic, positive])}.

%% Keeps the newest copy of each missile and puts it in the right sector.
normalize_entities(SectorSnapshots) ->
    %% If a missile appears twice, keep the copy that moved further.
    Entities = maps:fold(fun(SectorId, Snapshot, Acc) ->
        maps:fold(fun(Id, Entity, Found) ->
            Candidate = {SectorId, Entity},
            maps:update_with(Id, fun(Existing) -> newest_entity(Candidate, Existing) end,
                Candidate, Found)
        end, Acc, maps:get(entities, Snapshot, #{}))
    end, #{}, SectorSnapshots),
    %% Clear the old lists, then add each missile to one sector.
    EmptySnapshots = maps:map(fun(_SectorId, Snapshot) -> Snapshot#{entities => #{}} end,
        SectorSnapshots),
    maps:fold(fun(Id, {OriginalSector, Entity}, Snapshots) ->
        Position = maps:get(position, maps:get(state, Entity, #{}), undefined),
        Destination = entity_sector(Position, OriginalSector),
        Snapshot = maps:get(Destination, Snapshots),
        SectorEntities = maps:get(entities, Snapshot),
        Snapshots#{Destination => Snapshot#{entities => SectorEntities#{Id => Entity}}}
    end, EmptySnapshots, Entities).

%% Removes interceptors when their target missile is missing.
remove_orphan_interceptors(SectorSnapshots) ->
    %% Make a list of hostile missile IDs for quick checks.
    HostileIds = maps:fold(fun(_SectorId, Snapshot, Found) ->
        maps:fold(fun
            (Id, #{type := hostile_missile}, Acc) -> Acc#{Id => true};
            (_Id, _Entity, Acc) -> Acc
        end, Found, maps:get(entities, Snapshot, #{}))
    end, #{}, SectorSnapshots),
    %% An interceptor cannot continue when its target no longer exists.
    maps:map(fun(_SectorId, Snapshot) ->
        Entities = maps:filter(fun
            (_Id, #{type := iron_dome_missile, state := EntityState}) ->
                maps:is_key(maps:get(target_id, EntityState, undefined), HostileIds);
            (_Id, _Entity) -> true
        end, maps:get(entities, Snapshot, #{})),
        Snapshot#{entities => Entities}
    end, SectorSnapshots).

%% Picks the newer copy of a missile found in two sectors.
newest_entity({_SectorA, #{type := hostile_missile, state := StateA}} = A,
        {_SectorB, #{type := hostile_missile, state := StateB}} = B) ->
    %% The hostile missile with more flight time is newer.
    case maps:get(flight_time_us, StateA, 0) >= maps:get(flight_time_us, StateB, 0) of
        true -> A;
        false -> B
    end;
newest_entity({_SectorA, #{type := iron_dome_missile, state := StateA}} = A,
        {_SectorB, #{type := iron_dome_missile, state := StateB}} = B) ->
    %% The interceptor with less time left is newer.
    case maps:get(remaining_time, StateA, 1.0e100) =< maps:get(remaining_time, StateB, 1.0e100) of
        true -> A;
        false -> B
    end;
newest_entity(A, _B) -> A.

%% Finds the missile's sector from its current X position.
entity_sector({X, _Z}, Fallback) ->
    case config:sector_at(X) of
        none -> Fallback;
        SectorId -> SectorId
    end;
entity_sector(_Position, Fallback) -> Fallback.

%% Gets all sector states at the same time and sends back the result.
capture_all(Manager, CheckpointId, SectorIds, Assignments) ->
    Manager ! {checkpoint, CheckpointId,
        request_snapshots(SectorIds, Assignments, 600)}.

%% Asks all sectors at the same time with one shared timeout.
request_snapshots(SectorIds, Assignments, Timeout) ->
    Collector = self(),
    Ref = make_ref(),
    %% Each sector gets its own process, so one slow sector does not block others.
    lists:foreach(fun(SectorId) -> spawn(fun() ->
        Collector ! {Ref, SectorId, capture_sector(SectorId, Assignments, Timeout)}
    end) end, SectorIds),
    %% The timeout is for the whole save, not for each reply.
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    collect_snapshots(Ref, length(SectorIds), #{}, Deadline).

%% Gets all saved data for one sector from its node.
capture_sector(SectorId, Assignments, Timeout) ->
    Owner = maps:get(SectorId, Assignments, undefined),
    Controller = {sector_controller:name(SectorId), Owner},
    Computer = {iron_dome_computer:name(SectorId), Owner},
    try
        %% Save missiles, radar data, launcher count, and city count.
        ComputerState = gen_server:call(Computer, snapshot, Timeout),
        SectorSnapshot = gen_server:call(Controller, snapshot, Timeout),
        RuntimeState = sector_supervisor:runtime_state(Owner, SectorId),
        SectorSnapshot#{computer_state => ComputerState, runtime_state => RuntimeState}
    catch _Class:_Reason -> unavailable
    end.

%% Collects replies until all sectors answer or time runs out.
collect_snapshots(_Ref, 0, Snapshots, _Deadline) -> Snapshots;
collect_snapshots(Ref, Remaining, Snapshots, Deadline) ->
    %% Reduce the time left after every reply.
    Timeout = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Ref, SectorId, Snapshot} when is_map(Snapshot) ->
            collect_snapshots(Ref, Remaining - 1,
                Snapshots#{SectorId => Snapshot}, Deadline);
        {Ref, _SectorId, unavailable} ->
            collect_snapshots(Ref, Remaining - 1, Snapshots, Deadline)
    after Timeout -> Snapshots
    end.

%% Reads one sector from the coordinator's cache.
lookup_snapshot(SectorId) ->
    case ets:lookup(snapshot_cache, SectorId) of
        [{SectorId, Snapshot}] -> {ok, Snapshot};
        [] -> {error, not_found}
    end.

%% Returns the snapshot manager address on the coordinator node.
server() -> {?MODULE, config:coordinator_node()}.
