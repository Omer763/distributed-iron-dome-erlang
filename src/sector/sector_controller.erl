-module(sector_controller).
-behaviour(gen_server).

-export([start_link/1, name/1]).
-export([
    launcher/1,
    start_child/5,
    restore/2,
    register_entity/4,
    update_entity/3,
    remove_entity/2,
    snapshot/1,
    accept_missile/3,
    accept_interceptor/3,
    entity_pid/2,
    hostile_positions/1,
    complete_entity/3,
    report_launch/1,
    report_no_threat/1,
    reset_statistics/1
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% Starts the state controller for one sector.
start_link(#{sector_id := SectorId} = Config) ->
    Options = #{sector_id => SectorId, snapshot => maps:get(snapshot, Config, #{})},
    gen_server:start_link({local, name(SectorId)}, ?MODULE, Options, []).

%% Returns this controller's node-local registered name.
name(SectorId) -> list_to_atom(atom_to_list(?MODULE) ++ "_" ++ atom_to_list(SectorId)).

%% Returns this sector's launcher PID from its supervisor.
launcher(Pid) -> gen_server:call(Pid, launcher).

%% Starts one temporary process owned by this sector.
start_child(Pid, ChildId, Module, Args, Restart) ->
    gen_server:call(Pid, {start_child, ChildId, Module, Args, Restart}, 5000).

%% Restores the active entities found in a failover snapshot.
restore(Pid, Snapshot) -> gen_server:call(Pid, {restore, Snapshot}, 10000).

%% Registers a running entity with a stable ID.
register_entity(Pid, EntityId, Type, EntityPid) ->
    gen_server:call(Pid, {register_entity, EntityId, Type, EntityPid}).

%% Stores the latest runtime state of an entity.
update_entity(SectorId, EntityId, RuntimeState) ->
    ets:update_element(entity_table(SectorId), EntityId, {4, RuntimeState}),
    ok.

%% Removes an entity from the sector state.
remove_entity(SectorId, EntityId) ->
    ets:delete(entity_table(SectorId), EntityId),
    ok.

%% Returns a serializable sector snapshot.
snapshot(Pid) -> gen_server:call(Pid, snapshot).

%% Registers a transferred hostile missile in its destination sector.
accept_missile(Pid, MissileId, MissileState) ->
    gen_server:call(Pid, {accept_entity, hostile_missile, MissileId, MissileState}, 4000).

%% Registers a transferred interceptor in its destination sector.
accept_interceptor(Pid, InterceptorId, InterceptorState) ->
    gen_server:call(Pid, {accept_entity, iron_dome_missile, InterceptorId, InterceptorState}, 4000).

%% Returns the current process for a stable entity ID.
entity_pid(Pid, EntityId) -> gen_server:call(Pid, {entity_pid, EntityId}).

%% Returns positions of hostile missiles currently inside this sector.
hostile_positions(SectorId) -> hostile_entity_positions(entity_table(SectorId)).

%% Removes a finished entity immediately, then records its result asynchronously.
complete_entity(SectorId, EntityId, Result) ->
    ets:delete(entity_table(SectorId), EntityId),
    gen_server:cast(name(SectorId), {entity_result, Result}).

%% Records one more hostile missile launched by this sector's own city.
%% Counted once at launch and never decremented, unlike a live entity
%% count -- a missile that later transfers away must not make this drop.
report_launch(Pid) -> gen_server:cast(Pid, report_launch).

%% Records one more hostile missile the radar ruled harmless (drawn gray,
%% never counted as a hit).
report_no_threat(Pid) -> gen_server:cast(Pid, report_no_threat).

%% Clears statistics and entities that still belong to the previous settings.
reset_statistics(Pid) -> gen_server:call(Pid, reset_statistics).

%% Builds the sector data state.
init(#{sector_id := SectorId, snapshot := Snapshot}) ->
    Table = ensure_entity_table(SectorId),
    RestoredEntities = maps:get(entities, Snapshot, #{}),
    Statistics = maps:get(statistics, Snapshot, empty_statistics()),
    SnapshotMs = application:get_env(iron_dome, snapshot_interval_ms, 100),
    erlang:send_after(snapshot_delay(SectorId, SnapshotMs), self(), broadcast_snapshot),
    restore_table(Table, RestoredEntities),
    State = #{sector_id => SectorId, table => Table,
        statistics => Statistics, snapshot_ms => SnapshotMs,
        monitors => monitor_table_entities(Table)},
    {ok, State}.

%% Handles synchronous sector_controller requests.
handle_call(launcher, _From, #{sector_id := SectorId} = State) ->
    {reply, sector_supervisor:launcher(SectorId), State};
handle_call({start_child, Id, Module, Args, temporary}, _From, #{sector_id := SectorId} = State) ->
    {reply, sector_supervisor:start_child(SectorId, Id, Module, Args, temporary), State};
handle_call({start_child, _Id, _Module, _Args, Restart}, _From, State) ->
    {reply, {error, {unsupported_restart, Restart}}, State};
handle_call({restore, Snapshot}, _From, State) -> {reply, ok, restore_entities_handler(Snapshot, State)};
handle_call({register_entity, Id, Type, Pid}, _From, State) ->
    {Reply, NewState} = register_entity_handler(Id, Type, Pid, State),
    {reply, Reply, NewState};
handle_call(snapshot, _From, State) -> {reply, build_snapshot(State), State};
handle_call({entity_pid, Id}, _From, #{table := Table} = State) ->
    {reply, entity_pid_from(Id, Table), State};
handle_call(reset_statistics, _From, State) -> {reply, ok, reset_statistics_handler(State)};
handle_call({accept_entity, Type, Id, EntityState}, _From, State)
        when Type =:= hostile_missile; Type =:= iron_dome_missile ->
    {Reply, NewState} = start_entity(Id, Type, EntityState, State),
    {reply, Reply, NewState};
handle_call(Request, _From, State) -> {reply, {error, {unsupported_call, Request}}, State}.

%% Handles asynchronous statistics updates.
handle_cast({entity_result, Result}, State) -> {noreply, add_result(Result, State)};
handle_cast(report_launch, State) -> {noreply, increment_stat(hostile_missiles_fired, State)};
handle_cast(report_no_threat, State) -> {noreply, increment_stat(no_threat_count, State)};
handle_cast(_Message, State) -> {noreply, State}.

%% Handles graphics snapshot timers and monitored entity exits.
handle_info(broadcast_snapshot, State) -> {noreply, broadcast_snapshot_handler(State)};
handle_info({'DOWN', Ref, process, Pid, _Reason}, State) -> {noreply, entity_down_handler(Ref, Pid, State)};
handle_info(_Message, State) -> {noreply, State}.

%% Registers a newly started entity while preserving restored state.
register_entity_handler(Id, Type, Pid, #{table := Table} = State) when is_pid(Pid) ->
    case ets:lookup(Table, Id) of
        [{Id, _OldType, OldPid, _EntityState}] when is_pid(OldPid) ->
            {{error, {already_registered, Id}}, State};
        [{Id, _OldType, _OldPid, EntityState}] ->
            {ok, register_entity_state(Id, Type, Pid, EntityState, State)};
        [] -> {ok, register_entity_state(Id, Type, Pid, #{}, State)}
    end.

%% Stores an entity's state and monitors its process.
register_entity_state(Id, Type, Pid, EntityState, #{table := Table, monitors := Monitors} = State) ->
    Ref = erlang:monitor(process, Pid),
    true = ets:insert(Table, {Id, Type, Pid, EntityState}),
    State#{monitors => Monitors#{Ref => Id}}.

%% Returns an entity PID when it is currently live.
entity_pid_from(Id, Table) ->
    case ets:lookup(Table, Id) of
        [{Id, _Type, Pid, _EntityState}] when is_pid(Pid) -> {ok, Pid};
        _ -> {error, not_found}
    end.

%% Returns current positions for hostile missiles in this sector.
hostile_entity_positions(Table) ->
    [{Id, maps:get(position, EntityState), maps:get(flight_time_us, EntityState, 0)}
     || {Id, hostile_missile, _Pid, EntityState} <- ets:tab2list(Table),
        maps:is_key(position, EntityState)].

%% Starts and registers a transferred or restored entity.
start_entity(Id, Module, EntityState, #{sector_id := SectorId, table := Table} = State) ->
    case entity_pid_from(Id, Table) of
        {ok, Pid} -> {{ok, Pid}, State};
        {error, not_found} ->
            Options = entity_options(Id, Module, EntityState, SectorId),
            case sector_supervisor:start_child(SectorId, Id, Module, [Options], temporary) of
                {ok, Pid} -> {{ok, Pid}, register_entity_state(Id, Module, Pid, EntityState, State)};
                {error, {already_started, Pid}} -> {{ok, Pid}, State};
                Error -> {Error, State}
            end
    end.

%% Builds the startup options required by one entity type.
entity_options(Id, Module, EntityState, SectorId) ->
    Base = EntityState#{id => Id, sector_id => SectorId,
        sector_controller => name(SectorId)},
    case Module of
        iron_dome_missile -> Base#{time_to_target => maps:get(remaining_time, EntityState)};
        hostile_missile -> Base
    end.

%% Adds a completed-flight result to sector statistics.
add_result(no_stat, State) -> State;
add_result(Result, #{statistics := Statistics} = State) ->
    Key = result_counter(Result),
    State#{statistics => maps:update_with(Key, fun(N) -> N + 1 end, 1, Statistics)}.

%% Increments one statistics counter.
increment_stat(Key, #{statistics := Statistics} = State) ->
    State#{statistics => maps:update_with(Key, fun(N) -> N + 1 end, 1, Statistics)}.

%% Starts a clean statistics run without restarting cities or permanent sector processes.
reset_statistics_handler(#{table := Table, monitors := Monitors} = State) ->
    Pids = [Pid || {_Id, _Type, Pid, _EntityState} <- ets:tab2list(Table), is_pid(Pid)],
    lists:foreach(fun(Pid) -> exit(Pid, shutdown) end, Pids),
    maps:foreach(fun(Ref, _Id) -> erlang:demonitor(Ref, [flush]) end, Monitors),
    ets:delete_all_objects(Table),
    State#{statistics => empty_statistics(), monitors => #{}}.

%% Returns zeroed sector counters.
empty_statistics() -> #{hostile_missiles_fired => 0, interceptions => 0, city_hits => 0,
    hostile_impacts => 0, interceptor_misses => 0, no_threat_count => 0}.

%% Sends an independent live snapshot for graphics, not recovery history.
broadcast_snapshot_handler(#{sector_id := SectorId, snapshot_ms := SnapshotMs} = State) ->
    snapshot_manager:store_live_snapshot(SectorId, build_snapshot(State)),
    erlang:send_after(SnapshotMs, self(), broadcast_snapshot),
    State.

%% Spreads sector snapshot work evenly across the configured interval.
snapshot_delay(SectorId, SnapshotMs) ->
    SectorIds = [maps:get(sector_id, Config) || Config <- config:sectors()],
    Index = sector_index(SectorId, SectorIds, 0),
    1 + (Index * SnapshotMs div max(1, length(SectorIds))).

%% Finds a sector's stable zero-based position in the configuration.
sector_index(SectorId, [SectorId | _Rest], Index) -> Index;
sector_index(SectorId, [_Other | Rest], Index) -> sector_index(SectorId, Rest, Index + 1);
sector_index(_SectorId, [], _Index) -> 0.

%% Removes an entity after its monitored process terminates.
entity_down_handler(Ref, Pid, #{monitors := Monitors} = State) ->
    case maps:take(Ref, Monitors) of
        {Id, Remaining} -> remove_entity_state(Id, Pid, State#{monitors => Remaining});
        error -> State
    end.

%% Recreates every active entity from a failover snapshot.
restore_entities_handler(Snapshot, State) ->
    maps:fold(fun(Id, Entity, Acc) -> restore_entity(Id, Entity, Acc) end,
        State, maps:get(entities, Snapshot, #{})).

%% Restores one valid hostile missile or interceptor.
restore_entity(EntityId, #{type := Module, state := EntityState}, State)
        when Module =:= hostile_missile; Module =:= iron_dome_missile ->
    case valid_entity_state(Module, EntityState) of
        true -> element(2, start_entity(EntityId, Module, EntityState, State));
        false -> State
    end;
restore_entity(_EntityId, _Entity, State) -> State.

%% Checks whether a snapshot contains the fields needed to restart its entity.
valid_entity_state(hostile_missile, _EntityState) -> true;
valid_entity_state(iron_dome_missile, EntityState) ->
    lists:all(fun(Key) -> maps:is_key(Key, EntityState) end,
        [position, velocity, target_id, target_position, remaining_time]).

%% Removes live data; the following DOWN message removes its monitor.
remove_entity_state(EntityId, #{table := Table} = State) ->
    ets:delete(Table, EntityId),
    State.

%% Removes an entity only when the DOWN message belongs to its current PID.
remove_entity_state(EntityId, Pid, #{table := Table} = State) ->
    case ets:lookup(Table, EntityId) of
        [{EntityId, _Type, Pid, _EntityState}] -> remove_entity_state(EntityId, State);
        _ -> State
    end.

%% Builds a serializable snapshot without node-local PIDs.
build_snapshot(#{sector_id := SectorId, table := Table, statistics := Statistics}) ->
    Serializable = maps:from_list([{Id, #{type => Type, state => EntityState}}
        || {Id, Type, _Pid, EntityState} <- ets:tab2list(Table)]),
    #{sector_id => SectorId, host => node(), entities => Serializable, statistics => Statistics}.

%% Creates or reuses this sector's node-local live entity table.
ensure_entity_table(SectorId) ->
    Table = entity_table(SectorId),
    case ets:whereis(Table) of
        undefined -> ets:new(Table, [named_table, public, set, heir_option(),
            {read_concurrency, true}, {write_concurrency, true}]);
        _Tid -> Table
    end.

%% Gives every configured sector a stable node-local ETS table name.
entity_table(SectorId) -> list_to_atom(atom_to_list(SectorId) ++ "_entities").

%% Loads snapshot entries only when starting with an empty table.
restore_table(Table, Entities) ->
    case ets:first(Table) of
        '$end_of_table' -> maps:foreach(fun(Id, Entity) ->
            ets:insert(Table, {Id, maps:get(type, Entity), undefined,
                maps:get(state, Entity, #{})})
        end, Entities);
        _Existing -> ok
    end.

%% Keeps the table alive if only the controller process is restarted.
heir_option() ->
    case get('$ancestors') of
        [Supervisor | _] when is_pid(Supervisor) -> {heir, Supervisor, none};
        _ -> {heir, none}
    end.

%% Rebuilds process monitors when a controller restarts around a live table.
monitor_table_entities(Table) ->
    lists:foldl(fun
        ({Id, _Type, Pid, _EntityState}, Monitors) when is_pid(Pid) ->
            Monitors#{erlang:monitor(process, Pid) => Id};
        (_Entity, Monitors) -> Monitors
    end, #{}, ets:tab2list(Table)).

%% Maps a completed-flight result to its statistics counter.
result_counter({intercepted, _}) -> interceptions;
result_counter({city_hit, _}) -> city_hits;
result_counter({ground_impact, _}) -> hostile_impacts;
result_counter(impacted) -> hostile_impacts;
result_counter(left_environment) -> hostile_impacts;
result_counter(missed) -> interceptor_misses;
result_counter({_, _}) -> interceptor_misses;
result_counter(_) -> interceptor_misses.
