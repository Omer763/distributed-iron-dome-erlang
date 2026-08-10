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

%% Reads one global radar setting.
radar(Key) -> component_value(radar, Key).

%% Reads one global launcher setting.
launcher(Key) -> component_value(launcher, Key).

%% Reads one global interceptor setting.
interceptor(Key) -> component_value(interceptor, Key).

%% Reads one global hostile-city setting.
hostile_city(Key) -> component_value(hostile_city, Key).

%% Reads one global hostile-missile setting.
hostile_missile(Key) -> component_value(hostile_missile, Key).

%% Reads the shared movement interval for every missile.
tick_ms() -> application:get_env(iron_dome, tick_ms, 50).

%% Returns whether this worker should freeze its simulation processes.
paused() -> application:get_env(iron_dome, simulation_paused, false).

%% Pauses or resumes simulation processes on the current Erlang node.
set_paused(Value) when is_boolean(Value) ->
    application:set_env(iron_dome, simulation_paused, Value).

%% Updates the shared missile movement interval on the current Erlang node.
set_tick_ms(Value) when is_integer(Value), Value > 0 ->
    application:set_env(iron_dome, tick_ms, Value).

%% Updates the hostile-city launch interval on the current Erlang node.
set_spawn_ms(Value) when is_integer(Value), Value >= 0 ->
    set_component_value(hostile_city, spawn_ms, Value).

%% Updates the interceptor hit chance on the current Erlang node.
set_interceptor_hit_chance(Value) when is_float(Value), Value >= 0.0, Value =< 1.0 ->
    set_component_value(interceptor, hit_chance, Value).

%% Updates the hostile-missile accuracy on the current Erlang node.
set_hostile_accuracy(Value) when is_float(Value), Value >= 0.0, Value =< 1.0 ->
    set_component_value(hostile_missile, accuracy, Value).

%% Returns the node running coordinator-only services.
coordinator_node() ->
    case os:getenv("IRON_DOME_COORDINATOR") of
        false -> application:get_env(iron_dome, coordinator_node, node());
        Name -> list_to_atom(Name)
    end.

%% Stores the current sector ownership map on this Erlang node.
set_assignments(Assignments) when is_map(Assignments) ->
    application:set_env(iron_dome, sector_assignments, Assignments).

%% Returns the controller address for the node currently owning a sector.
sector_controller(SectorId) -> sector_component(SectorId, sector_controller:name(SectorId)).

%% Returns the computer address for the node currently owning a sector.
sector_computer(SectorId) -> sector_component(SectorId, iron_dome_computer:name(SectorId)).

%% Returns the sector containing an X coordinate.
sector_at(X) ->
    case [SectorId || 
            {SectorId, {MinX, MaxX}} <- sector_boundaries(),
            X >= MinX, X < MaxX] of
        [SectorId | _] -> SectorId;
        [] -> none
    end.

%% Returns all configured sector ranges.
sector_boundaries() ->
    [{maps:get(sector_id, Config), maps:get(bounds, Config)} || Config <- sectors()].

%% Returns every configured protected city.
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
    Defaults = application:get_env(iron_dome, defaults, #{}),
    ComponentValues = maps:get(Component, Defaults, #{}),
    application:set_env(
        iron_dome,
        defaults,
        Defaults#{Component => ComponentValues#{Key => Value}}
    ).

%% Combines a component's node-local name with the current sector owner.
sector_component(SectorId, Name) ->
    Assignments = application:get_env(iron_dome, sector_assignments, #{}),
    case maps:find(SectorId, Assignments) of
        {ok, Node} -> {ok, {Name, Node}};
        error -> {error, no_owner}
    end.

%% Returns all sector definitions from sys.config.
sectors() -> application:get_env(iron_dome, sectors, []).
