-module(iron_dome_missile).
-behaviour(gen_statem).

-export([start_link/1]).
-export([callback_mode/0, init/1, guiding/3]).

%% Starts one temporary interceptor.
start_link(Options) -> gen_statem:start_link(?MODULE, Options, []).

%% Uses one callback function for the interceptor's single state.
callback_mode() -> state_functions.

%% Builds the interceptor state and immediately starts guidance.
init(#{id := Id, position := {X, Z}, target_id := TargetId,
        target_position := TargetPosition, time_to_target := Time,
        sector_id := SectorId, sector_controller := Controller}) ->
    Position = {float(X), float(Z)},
    Velocity = physics:velocity_to_arrive(Position, TargetPosition, Time),
    State = #{id => Id, position => Position, velocity => Velocity,
        target_id => TargetId, target_position => TargetPosition,
        remaining_time => float(Time), last_tick => physics:timestamp(),
        sector_id => SectorId, sector_controller => Controller},
    {ok, guiding, State, [{state_timeout, 0, move}]}.

%% Moves toward the fixed predicted interception point unless recovery paused the simulation.
guiding(state_timeout, move, State) ->
    case config:paused() of
        true -> {keep_state, State#{last_tick => physics:timestamp()},
            [{state_timeout, config:tick_ms(), move}]};
        false -> move_handler(State)
    end;
guiding(_EventType, _Event, State) -> {keep_state, State}.

%% Advances one movement tick and detonates at the programmed time.
move_handler(#{position := Position, velocity := Velocity, remaining_time := Remaining,
        last_tick := LastTick} = State) ->
    {Elapsed, Now} = physics:elapsed_seconds(LastTick),
    Step = min(Elapsed, Remaining),
    NewState = State#{position => physics:linear_step(Position, Velocity, Step),
        remaining_time => max(0.0, Remaining - Step), last_tick => Now},
    case maps:get(remaining_time, NewState) =< 0.0 of
        true -> detonate(NewState);
        false ->
            update_controller(NewState),
            next_step(NewState)
    end.

%% Checks the assigned target at the programmed detonation point.
detonate(#{position := Position, target_id := TargetId, id := InterceptorId} = State) ->
    Result = case find_hostile(TargetId, State) of
        {ok, TargetPid} -> hit_target(Position, TargetPid, TargetId, InterceptorId);
        error -> {missed, target_not_found}
    end,
    finish(Result, State).

%% Destroys the assigned hostile when it is inside the blast radius.
hit_target(Position, TargetPid, TargetId, InterceptorId) ->
    case hostile_position(TargetPid) of
        {ok, TargetPosition} ->
            Distance = physics:distance(Position, TargetPosition),
            case Distance =< hit_radius() of
                false -> {missed, {outside_radius, Distance}};
                true ->
                    case rand:uniform() =< config:interceptor(hit_chance) of
                        false -> {missed, hit_chance};
                        true ->
                            case destroy_hostile(TargetPid, InterceptorId) of
                                ok -> {hit, [TargetId]};
                                not_destroyed -> {missed, target_already_gone}
                            end
                    end
            end;
        unavailable -> {missed, target_unavailable}
    end.

%% Searches every sector for the assigned hostile missile.
find_hostile(Id, #{sector_controller := Local, sector_id := LocalSector}) ->
    Remotes = [Controller || {SectorId, _Bounds} <- config:sector_boundaries(),
        SectorId =/= LocalSector, {ok, Controller} <- [config:sector_controller(SectorId)]],
    find_entity(Id, [Local | Remotes]).

%% Returns the first live process matching an entity ID.
find_entity(_Id, []) -> error;
find_entity(Id, [Controller | Rest]) ->
    try sector_controller:entity_pid(Controller, Id) of
        {ok, Pid} -> {ok, Pid};
        _ -> find_entity(Id, Rest)
    catch exit:_Reason -> find_entity(Id, Rest)
    end.

%% Reads a hostile position while tolerating concurrent termination.
hostile_position(Pid) ->
    try hostile_missile:position(Pid) of
        {Position, _SampledAt} -> {ok, Position}
    catch exit:_Reason -> unavailable
    end.

%% Destroys a hostile while tolerating a race with another interceptor.
destroy_hostile(Pid, InterceptorId) ->
    try hostile_missile:intercept(Pid, InterceptorId) of
        {ok, destroyed} -> ok;
        _ -> not_destroyed
    catch exit:_Reason -> not_destroyed
    end.

%% Continues locally or transfers when the interceptor enters another sector.
next_step(#{position := {X, _Z}, sector_id := SectorId} = State) ->
    case config:sector_at(X) of
        SectorId -> schedule(State);
        none -> schedule(State);
        Destination -> transfer(Destination, State)
    end.

%% Starts the interceptor in its destination sector before stopping locally.
transfer(DestinationSector, #{sector_id := SectorId, id := Id} = State) ->
    case config:sector_controller(DestinationSector) of
        {ok, Destination} ->
            try sector_controller:accept_interceptor(Destination, Id, entity_state(State)) of
                {ok, _NewPid} ->
                    sector_controller:remove_entity(SectorId, Id),
                    {stop, normal, State};
                {error, _Reason} -> schedule(State)
            catch exit:_Reason -> schedule(State)
            end;
        {error, _Reason} -> schedule(State)
    end.

%% Schedules the next movement tick.
schedule(State) ->
    {keep_state, State, [{state_timeout, config:tick_ms(), move}]}.

%% Pushes the latest serializable state to the sector controller.
update_controller(#{sector_id := SectorId, id := Id} = State) ->
    sector_controller:update_entity(SectorId, Id, entity_state(State)).

%% Builds the state used by snapshots, transfer, and recovery.
entity_state(#{position := Position, velocity := Velocity, target_id := TargetId,
        target_position := TargetPosition, remaining_time := Remaining}) ->
    #{position => Position, velocity => Velocity, target_id => TargetId,
        target_position => TargetPosition, remaining_time => Remaining}.

%% Records the result, removes the entity, and terminates normally.
finish(Result, #{sector_id := SectorId, id := Id, position := Position} = State) ->
    Statistic = case Result of {missed, _} -> missed; _ -> no_stat end,
    ok = sector_controller:complete_entity(SectorId, Id, Statistic),
    case Result of
        {missed, _} -> graphics_server:explosion(SectorId, Position, interceptor_miss);
        _ -> ok
    end,
    {stop, normal, State}.

%% Reads the shared interceptor collision radius.
hit_radius() -> config:interceptor(hit_radius).
