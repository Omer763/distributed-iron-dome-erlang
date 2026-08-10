-module(hostile_missile).
-behaviour(gen_statem).

-export([start_link/1, intercept/2, position/1, mark_no_threat/1]).
-export([callback_mode/0, init/1, flying/3]).

%% Starts a hostile missile; used by sector_supervisor and sector_controller.
start_link(Options) -> gen_statem:start_link(?MODULE, Options, []).

%% Destroys the target missile; used by iron_dome_missile.
intercept(Pid, InterceptorId) -> gen_statem:call(Pid, {intercepted, InterceptorId}, 1000).

%% Returns portable flight state; used by radar and interceptor modules.
position(Pid) -> gen_statem:call(Pid, position).

%% Marks a harmless missile; used by iron_dome_computer.
mark_no_threat(Pid) -> gen_statem:cast(Pid, mark_no_threat).

%% Uses flying/3 to handle missile events.
callback_mode() -> state_functions.

%% Creates the missile state and starts its movement timer.
init(#{id := Id, position := {X, Z}, velocity := {Vx, Vz}, sector_id := SectorId,
        sector_controller := SectorController} = Options) ->
    %% A restored missile may already have flight time and target data.
    State = #{
        id => Id,
        position => {float(X), float(Z)},
        last_tick => physics:timestamp(),
        flight_time_us => maps:get(flight_time_us, Options, 0),
        velocity => {float(Vx), float(Vz)},
        target_id => maps:get(target_id, Options, unknown_target),
        target_position => maps:get(target_position, Options, undefined),
        threat => maps:get(threat, Options, true),
        sector_id => SectorId,
        sector_controller => SectorController
    },
    {ok, flying, State, [{state_timeout, config:tick_ms(), move}]}.

%% Moves, answers position checks, and handles interception.
flying(state_timeout, move, State) ->
    %% Reset the clock while paused so paused time is not added to movement.
    case config:paused() of
        true -> {keep_state, State#{last_tick => physics:timestamp()},
            [{state_timeout, config:tick_ms(), move}]};
        false -> next_step(advance(State))
    end;
flying({call, From}, position, #{position := Position, flight_time_us := FlightTimeUs} = State) ->
    {keep_state, State, [{reply, From, {Position, FlightTimeUs}}]};
flying({call, From}, {intercepted, InterceptorId}, State) ->
    terminate({intercepted, InterceptorId}, State, [{reply, From, {ok, destroyed}}]);
flying(cast, mark_no_threat, State) ->
    {keep_state, State#{threat => false}};
flying(_EventType, _Event, State) -> {keep_state, State}.

%% Applies one discrete ballistic movement step.
advance(#{position := {X, Z}, velocity := {Vx, Vz}, last_tick := LastTick,
        flight_time_us := FlightTimeUs} = State) ->
    {Dt, Now} = physics:elapsed_seconds(LastTick),
    %% Get the new position and falling speed for this time step.
    {{NewX, NewZ}, {NewVx, NewVz}} = physics:projectile_step({X, Z}, {Vx, Vz}, Dt),
    State#{
        position => {NewX, NewZ},
        last_tick => Now,
        flight_time_us => FlightTimeUs + round(Dt * 1000000),
        velocity => {NewVx, NewVz}
    }.

%% Terminates, transfers, or schedules the missile's next movement.
next_step(#{id := Id, position := {X, _Z} = Position, sector_id := SectorId} = State) ->
    %% Ground impact ends the flight before sector movement is checked.
    case physics:reached_ground(Position) of
        true -> terminate(impacted, State);
        false ->
            case config:sector_at(X) of
                DestinationSector when DestinationSector =/= none, DestinationSector =/= SectorId ->
                    %% Move the missile state to the sector that now contains it.
                    transfer(State, DestinationSector);
                none ->
                    terminate(left_environment, State);
                SectorId ->
                    sector_controller:update_entity(SectorId, Id, public_state(State)),
                    {keep_state, State, [{state_timeout, config:tick_ms(), move}]}
            end
    end.

%% Starts the missile remotely before stopping its local process.
%% Direct registration avoids blocking the busy source controller.
transfer(#{sector_id := SectorId, id := Id} = State, DestinationSector) ->
    %% Start the new copy before removing the old copy.
    case config:sector_controller(DestinationSector) of
        {ok, Destination} ->
            case safe_accept_missile(Destination, Id, public_state(State)) of
                {ok, _NewMissilePid} ->
                    sector_controller:remove_entity(SectorId, Id),
                    {stop, normal, State};
                {error, _Reason} -> keep_flying(State)
            end;
        {error, _Reason} -> keep_flying(State)
    end.

%% Keeps a missile in its current sector until routing becomes available.
keep_flying(#{sector_id := SectorId, id := Id} = State) ->
    sector_controller:update_entity(SectorId, Id, public_state(State)),
    {keep_state, State, [{state_timeout, config:tick_ms(), move}]}.

%% Tries the new sector without crashing when that node is offline.
safe_accept_missile(Destination, Id, MissileState) ->
    try sector_controller:accept_missile(Destination, Id, MissileState) of
        Result -> Result
    catch
        exit:Reason -> {error, {destination_unavailable, Reason}}
    end.

%% Removes the missile and terminates its process.
terminate(Result, State) -> terminate(Result, State, []).

%% Converts ground contact into a verified city hit or another impact.
terminate(impacted, #{target_id := TargetId, target_position := TargetPosition} = State, Actions) ->
    %% Ground contact counts as a city hit only inside the city's radius.
    Result =
        case TargetPosition of
            undefined -> {ground_impact, unknown_target};
            _ ->
                Radius = config:hostile_missile(city_hit_radius),
                case physics:distance(maps:get(position, State), TargetPosition) =< Radius of
                    true -> {city_hit, TargetId};
                    false -> {ground_impact, TargetId}
                end
        end,
    terminate(Result, State, Actions);

%% Saves the result and stops the missile.
%% A harmless missile does not change the statistics.
terminate(Result, #{sector_id := SectorId, id := Id, threat := Threat} = State, Actions) ->
    StatisticResult =
        case Threat of
            false -> no_stat;
            true -> Result
        end,
    ok = sector_controller:complete_entity(SectorId, Id, StatisticResult),
    emit_explosion(SectorId, Result, maps:get(position, State)),
    notify_termination(Id, config:sector_boundaries()),
    {stop_and_reply, normal, Actions, State}.

%% Returns the data needed to move or restore the missile.
%% flight_time_us keeps the flight clock from starting again at zero.
public_state(#{position := Position, velocity := Velocity, flight_time_us := FlightTimeUs,
        target_id := TargetId, target_position := TargetPosition, threat := Threat}) ->
    #{position => Position, velocity => Velocity, flight_time_us => FlightTimeUs,
        target_id => TargetId, target_position => TargetPosition, threat => Threat}.

%% Tells every computer to remove a completed missile and its claim.
notify_termination(MissileId, SectorBoundaries) ->
    lists:foreach(
        fun({SectorId, _Bounds}) ->
            case config:sector_computer(SectorId) of
                {ok, Computer} -> gen_server:cast(Computer, {missile_terminated, MissileId});
                {error, _Reason} -> ok
            end
        end,
        SectorBoundaries
    ).

%% Emits a visual effect matching the hostile missile result.
emit_explosion(SectorId, {intercepted, _InterceptorId}, Position) ->
    graphics_server:explosion(SectorId, Position, interception);
emit_explosion(SectorId, {city_hit, _TargetId}, Position) ->
    graphics_server:explosion(SectorId, Position, city_impact);
emit_explosion(SectorId, {ground_impact, _TargetId}, Position) ->
    graphics_server:explosion(SectorId, Position, ground_impact);
emit_explosion(_SectorId, left_environment, _Position) -> ok;
emit_explosion(_SectorId, _OtherResult, _Position) -> ok.
