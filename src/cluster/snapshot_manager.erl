-module(snapshot_manager).
-behaviour(gen_server).

-export([start_link/0, snapshot/1, snapshots/0, latest_checkpoint/0, paused_checkpoint/0,
    set_assignments/1, store_live_snapshot/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% Starts the snapshot manager locally on the coordinator node.
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Returns the latest snapshot for one sector.
snapshot(SectorId) ->
    case ets:whereis(snapshot_cache) of
        undefined -> gen_server:call(server(), {snapshot, SectorId});
        _Table -> lookup_snapshot(SectorId)
    end.

%% Returns the latest snapshots for all sectors.
snapshots() ->
    case ets:whereis(snapshot_cache) of
        undefined -> gen_server:call(server(), snapshots);
        _Table -> maps:from_list(ets:tab2list(snapshot_cache))
    end.

%% Returns the newest complete snapshot set containing every sector.
latest_checkpoint() -> gen_server:call(server(), latest_checkpoint).

%% Captures one complete checkpoint while cluster recovery has paused movement.
paused_checkpoint() -> gen_server:call(server(), paused_checkpoint, 3000).

%% Updates the sector owners whose snapshots are allowed into the cache.
set_assignments(Assignments) ->
    gen_server:cast(server(), {assignments, Assignments}).

%% Sends one sector's display snapshot to the coordinator cache.
store_live_snapshot(SectorId, Snapshot) ->
    gen_server:cast(server(), {live_snapshot, SectorId, Snapshot}).

%% Creates the coordinator's latest-snapshot ETS cache.
init([]) ->
    Table = ets:new(snapshot_cache, [named_table, protected, set, {read_concurrency, true}]),
    Interval = application:get_env(iron_dome, snapshot_interval_ms, 100),
    HistoryMs = application:get_env(iron_dome, checkpoint_history_ms, 5000),
    SectorIds = [maps:get(sector_id, Config)
        || Config <- application:get_env(iron_dome, sectors, [])],
    erlang:send_after(Interval, self(), capture_checkpoint),
    {ok, #{table => Table, assignments => #{}, sector_ids => SectorIds,
        interval => Interval, history_limit => max(2, HistoryMs div Interval),
        history => [], capture_in_progress => false}}.

%% Handles snapshot queries.
handle_call({snapshot, SectorId}, _From, State) ->
    Reply = lookup_snapshot(SectorId),
    {reply, Reply, State};
handle_call(snapshots, _From, #{table := Table} = State) ->
    {reply, maps:from_list(ets:tab2list(Table)), State};
handle_call(latest_checkpoint, _From, #{history := History} = State) ->
    Reply = case History of
        [{CheckpointId, SectorSnapshots} | _] -> {ok, CheckpointId, SectorSnapshots};
        [] -> {error, not_found}
    end,
    {reply, Reply, State};
handle_call(paused_checkpoint, _From,
        #{sector_ids := SectorIds, assignments := Assignments} = State) ->
    CheckpointId = checkpoint_id(),
    SectorSnapshots = request_snapshots(SectorIds, Assignments, 600),
    case store_checkpoint(CheckpointId, SectorSnapshots, State) of
        {{ok, NormalizedSnapshots}, NewState} ->
            {reply, {ok, CheckpointId, NormalizedSnapshots}, NewState};
        {{error, incomplete}, NewState} ->
            {reply, {error, {incomplete, maps:keys(SectorSnapshots)}}, NewState}
    end;
handle_call(Request, _From, State) -> {reply, {error, {unsupported_call, Request}}, State}.

handle_cast({assignments, Assignments}, State) ->
    {noreply, State#{assignments => Assignments}};
handle_cast({live_snapshot, SectorId, #{host := Host} = Snapshot},
        #{table := Table, assignments := Assignments} = State) ->
    case maps:get(SectorId, Assignments, undefined) of
        Host -> ets:insert(Table, {SectorId, Snapshot});
        _OtherOwner -> ok
    end,
    {noreply, State};
handle_cast(_Message, State) -> {noreply, State}.

%% Starts one parallel snapshot round without overlapping a slower round.
handle_info(capture_checkpoint, #{capture_in_progress := false, sector_ids := SectorIds,
        assignments := Assignments, interval := Interval} = State) ->
    {noreply, capture_checkpoint_handler(SectorIds, Assignments, Interval, State)};
handle_info(capture_checkpoint, #{interval := Interval} = State) ->
    erlang:send_after(Interval, self(), capture_checkpoint),
    {noreply, State};

%% Stores only complete checkpoints produced by the currently assigned owners.
handle_info({checkpoint, CheckpointId, SectorSnapshots}, State) ->
    checkpoint_handler(CheckpointId, SectorSnapshots, State);
handle_info(_Message, State) -> {noreply, State}.

%% Kicks off one parallel snapshot round and reschedules the next one.
capture_checkpoint_handler(SectorIds, Assignments, Interval, State) ->
    Manager = self(),
    CheckpointId = checkpoint_id(),
    spawn(fun() -> capture_all(Manager, CheckpointId, SectorIds, Assignments) end),
    erlang:send_after(Interval, self(), capture_checkpoint),
    State#{capture_in_progress => true}.

%% Validates, caches, and stores one checkpoint into the recovery history.
checkpoint_handler(CheckpointId, SectorSnapshots,
        State) ->
    {_Result, NewState} = store_checkpoint(CheckpointId, SectorSnapshots, State),
    {noreply, NewState#{capture_in_progress => false}}.

%% Validates, normalizes, caches, and stores one complete checkpoint.
store_checkpoint(CheckpointId, SectorSnapshots,
        #{table := Table, assignments := Assignments, sector_ids := SectorIds,
          history := History, history_limit := Limit} = State) ->
    Valid = length(SectorIds) =:= map_size(SectorSnapshots) andalso
        lists:all(fun(SectorId) ->
            Snapshot = maps:get(SectorId, SectorSnapshots),
            maps:get(host, Snapshot, undefined) =:= maps:get(SectorId, Assignments, undefined)
        end, SectorIds),
    CurrentSnapshots = maps:filter(fun(SectorId, Snapshot) ->
        maps:get(host, Snapshot, undefined) =:= maps:get(SectorId, Assignments, undefined)
    end, SectorSnapshots),
    maps:foreach(fun(SectorId, Snapshot) -> ets:insert(Table, {SectorId, Snapshot}) end,
        CurrentSnapshots),
    case Valid of
        true ->
            NormalizedSnapshots = remove_orphan_interceptors(
                normalize_entities(SectorSnapshots)),
            Sorted = lists:sort(fun({IdA, _}, {IdB, _}) -> IdA > IdB end,
                [{CheckpointId, NormalizedSnapshots} | History]),
            NewHistory = lists:sublist(Sorted, Limit),
            [{_NewestId, NewestSnapshots} | _] = NewHistory,
            maps:foreach(fun(SectorId, Snapshot) ->
                ets:insert(Table, {SectorId, Snapshot})
            end, NewestSnapshots),
            {{ok, NormalizedSnapshots}, State#{history => NewHistory}};
        false -> {{error, incomplete}, State}
    end.

%% Creates a sortable ID containing the checkpoint start time.
checkpoint_id() ->
    {erlang:monotonic_time(millisecond),
        erlang:unique_integer([monotonic, positive])}.

%% Keeps one newest copy of each entity and places it in its current sector.
normalize_entities(SectorSnapshots) ->
    Entities = maps:fold(fun(SectorId, Snapshot, Acc) ->
        maps:fold(fun(Id, Entity, Found) ->
            Candidate = {SectorId, Entity},
            maps:update_with(Id, fun(Existing) -> newest_entity(Candidate, Existing) end,
                Candidate, Found)
        end, Acc, maps:get(entities, Snapshot, #{}))
    end, #{}, SectorSnapshots),
    EmptySnapshots = maps:map(fun(_SectorId, Snapshot) -> Snapshot#{entities => #{}} end,
        SectorSnapshots),
    maps:fold(fun(Id, {OriginalSector, Entity}, Snapshots) ->
        Position = maps:get(position, maps:get(state, Entity, #{}), undefined),
        Destination = entity_sector(Position, OriginalSector),
        Snapshot = maps:get(Destination, Snapshots),
        SectorEntities = maps:get(entities, Snapshot),
        Snapshots#{Destination => Snapshot#{entities => SectorEntities#{Id => Entity}}}
    end, EmptySnapshots, Entities).

%% Drops restored interceptors whose target hostile is absent from the same checkpoint.
remove_orphan_interceptors(SectorSnapshots) ->
    HostileIds = maps:fold(fun(_SectorId, Snapshot, Found) ->
        maps:fold(fun
            (Id, #{type := hostile_missile}, Acc) -> Acc#{Id => true};
            (_Id, _Entity, Acc) -> Acc
        end, Found, maps:get(entities, Snapshot, #{}))
    end, #{}, SectorSnapshots),
    maps:map(fun(_SectorId, Snapshot) ->
        Entities = maps:filter(fun
            (_Id, #{type := iron_dome_missile, state := EntityState}) ->
                maps:is_key(maps:get(target_id, EntityState, undefined), HostileIds);
            (_Id, _Entity) -> true
        end, maps:get(entities, Snapshot, #{})),
        Snapshot#{entities => Entities}
    end, SectorSnapshots).

%% Selects the state that progressed furthest during a sector transfer.
newest_entity({_SectorA, #{type := hostile_missile, state := StateA}} = A,
        {_SectorB, #{type := hostile_missile, state := StateB}} = B) ->
    case maps:get(flight_time_us, StateA, 0) >= maps:get(flight_time_us, StateB, 0) of
        true -> A;
        false -> B
    end;
newest_entity({_SectorA, #{type := iron_dome_missile, state := StateA}} = A,
        {_SectorB, #{type := iron_dome_missile, state := StateB}} = B) ->
    case maps:get(remaining_time, StateA, 1.0e100) =< maps:get(remaining_time, StateB, 1.0e100) of
        true -> A;
        false -> B
    end;
newest_entity(A, _B) -> A.

%% Uses the current X coordinate to select the entity's single owner sector.
entity_sector({X, _Z}, Fallback) ->
    case config:sector_at(X) of
        none -> Fallback;
        SectorId -> SectorId
    end;
entity_sector(_Position, Fallback) -> Fallback.

%% Requests every sector snapshot in parallel and reports a complete result.
capture_all(Manager, CheckpointId, SectorIds, Assignments) ->
    Manager ! {checkpoint, CheckpointId,
        request_snapshots(SectorIds, Assignments, 600)}.

%% Requests sector snapshots concurrently with one shared deadline.
request_snapshots(SectorIds, Assignments, Timeout) ->
    Collector = self(),
    Ref = make_ref(),
    lists:foreach(fun(SectorId) -> spawn(fun() ->
        Collector ! {Ref, SectorId, capture_sector(SectorId, Assignments, Timeout)}
    end) end, SectorIds),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    collect_snapshots(Ref, length(SectorIds), #{}, Deadline).

%% Captures controller, computer, launcher, and city state from one owner.
capture_sector(SectorId, Assignments, Timeout) ->
    Owner = maps:get(SectorId, Assignments, undefined),
    Controller = {sector_controller:name(SectorId), Owner},
    Computer = {iron_dome_computer:name(SectorId), Owner},
    try
        ComputerState = gen_server:call(Computer, snapshot, Timeout),
        SectorSnapshot = gen_server:call(Controller, snapshot, Timeout),
        RuntimeState = sector_supervisor:runtime_state(Owner, SectorId),
        SectorSnapshot#{computer_state => ComputerState, runtime_state => RuntimeState}
    catch _Class:_Reason -> unavailable
    end.

%% Collects responses for one checkpoint without blocking later rounds forever.
collect_snapshots(_Ref, 0, Snapshots, _Deadline) -> Snapshots;
collect_snapshots(Ref, Remaining, Snapshots, Deadline) ->
    Timeout = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Ref, SectorId, Snapshot} when is_map(Snapshot) ->
            collect_snapshots(Ref, Remaining - 1,
                Snapshots#{SectorId => Snapshot}, Deadline);
        {Ref, _SectorId, unavailable} ->
            collect_snapshots(Ref, Remaining - 1, Snapshots, Deadline)
    after Timeout -> Snapshots
    end.

%% Reads one sector from the master node's ETS cache.
lookup_snapshot(SectorId) ->
    case ets:lookup(snapshot_cache, SectorId) of
        [{SectorId, Snapshot}] -> {ok, Snapshot};
        [] -> {error, not_found}
    end.

%% Builds the explicit address of the coordinator's snapshot manager.
server() -> {?MODULE, config:coordinator_node()}.
