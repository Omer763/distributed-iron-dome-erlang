-module(config).

-export([
    radar/1,
    launcher/1,
    interceptor/1,
    hostile_city/1,
    hostile_missile/1,
    tick_ms/0,
    paused/0,
    set_paused/1,
    set_tick_ms/1,
    set_spawn_ms/1,
    set_interceptor_hit_chance/1,
    set_hostile_accuracy/1,
    coordinator_node/0,
    set_assignments/1,
    sector_controller/1,
    sector_computer/1,
    sectors/0,
    sector_at/1,
    sector_boundaries/0,
    protected_cities/0
]).

%% Shared configuration API used by simulation, cluster, and graphics modules.

%% Reads one radar setting; used by iron_dome_radar.
radar(Key) -> component_value(radar, Key).

%% Reads one launcher setting; used by iron_dome_launcher.
launcher(Key) -> component_value(launcher, Key).

%% Reads one interceptor setting; used by interceptor and physics modules.
interceptor(Key) -> component_value(interceptor, Key).

%% Reads one city setting; used by hostile_city and graphics.
hostile_city(Key) -> component_value(hostile_city, Key).

%% Reads one hostile setting; used by hostile missile and computer modules.
hostile_missile(Key) -> component_value(hostile_missile, Key).

%% Reads the movement interval; used by both missile modules.
tick_ms() -> application:get_env(iron_dome, tick_ms, 50).

%% Reports simulation pause state; used by active simulation modules.
paused() -> application:get_env(iron_dome, simulation_paused, false).

%% Sets local pause state; used by cluster_coordinator and graphics.
set_paused(Value) when is_boolean(Value) ->
    application:set_env(iron_dome, simulation_paused, Value).

%% Sets the local movement interval; used by graphics.
set_tick_ms(Value) when is_integer(Value), Value > 0 ->
    application:set_env(iron_dome, tick_ms, Value).

%% Sets the local launch interval; used by graphics.
set_spawn_ms(Value) when is_integer(Value), Value >= 0 ->
    set_component_value(hostile_city, spawn_ms, Value).

%% Sets local interceptor accuracy; used by graphics.
set_interceptor_hit_chance(Value) when is_float(Value), Value >= 0.0, Value =< 1.0 ->
    set_component_value(interceptor, hit_chance, Value).

%% Sets local hostile accuracy; used by graphics.
set_hostile_accuracy(Value) when is_float(Value), Value >= 0.0, Value =< 1.0 ->
    set_component_value(hostile_missile, accuracy, Value).

%% Returns the coordinator node; used by cluster and graphics clients.
coordinator_node() ->
    case os:getenv("IRON_DOME_COORDINATOR") of
        false -> application:get_env(iron_dome, coordinator_node, node());
        Name -> list_to_atom(Name)
    end.

%% Stores sector ownership; used by cluster and snapshot managers.
set_assignments(Assignments) when is_map(Assignments) ->
    application:set_env(iron_dome, sector_assignments, Assignments).

%% Resolves a controller; used by simulation and cluster modules.
sector_controller(SectorId) -> sector_component(SectorId, sector_controller:name(SectorId)).

%% Resolves a computer; used by radar and snapshot modules.
sector_computer(SectorId) -> sector_component(SectorId, iron_dome_computer:name(SectorId)).

%% Finds a sector by X coordinate; used by missile and computer modules.
sector_at(X) ->
    %% Find the first horizontal range that contains X.
    case [SectorId || 
            {SectorId, {MinX, MaxX}} <- sector_boundaries(),
            X >= MinX, X < MaxX] of
        [SectorId | _] -> SectorId;
        [] -> none
    end.

%% Returns sector ranges; used across cluster, graphics, and simulation modules.
sector_boundaries() ->
    [{maps:get(sector_id, Config), maps:get(bounds, Config)} || Config <- sectors()].

%% Returns protected cities; used by iron_dome_computer and graphics.
protected_cities() ->
    lists:flatmap(
        fun(Config) -> maps:get(protected_cities, Config, []) end,
        sectors()
    ).

%% Reads one required value from the shared defaults map.
component_value(Component, Key) ->
    Defaults = application:get_env(iron_dome, defaults, #{}),
    maps:get(Key, maps:get(Component, Defaults)).

%% Changes one value while preserving every other simulation setting.
set_component_value(Component, Key, Value) ->
    %% Keep every old setting except the one being changed.
    Defaults = application:get_env(iron_dome, defaults, #{}),
    ComponentValues = maps:get(Component, Defaults, #{}),
    application:set_env(
        iron_dome,
        defaults,
        Defaults#{Component => ComponentValues#{Key => Value}}
    ).

%% Combines a component's node-local name with the current sector owner.
sector_component(SectorId, Name) ->
    %% Add the owner node because the process name is only local to that node.
    Assignments = application:get_env(iron_dome, sector_assignments, #{}),
    case maps:find(SectorId, Assignments) of
        {ok, Node} -> {ok, {Name, Node}};
        error -> {error, no_owner}
    end.

%% Returns all sector definitions from sys.config.
sectors() -> application:get_env(iron_dome, sectors, []).
