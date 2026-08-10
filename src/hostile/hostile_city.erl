-module(hostile_city).
-behaviour(gen_server).

-export([start_link/1, snapshot/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% Starts a hostile city; used by sector_supervisor.
start_link(Options) -> gen_server:start_link(?MODULE, Options, []).

%% Returns recovery state; used by sector_supervisor.
snapshot(Pid) -> gen_server:call(Pid, snapshot).

%% Creates the city state and starts its first launch timer.
init(#{id := CityId, x := X, sector_id := SectorId,
        sector_controller := SectorController} = Options) ->
    SpawnMs = config:hostile_city(spawn_ms),
    %% Give each city a different first launch time.
    schedule_launch(rand:uniform(SpawnMs + 1) - 1),
    {ok, #{
        id => CityId, x => float(X),
        sector_id => SectorId, sector_controller => SectorController,
        next_missile => maps:get(next_missile, Options, 1)
    }}.

%% Returns saved city state when requested.
handle_call(snapshot, _From, #{next_missile := NextMissile} = State) ->
    {reply, #{next_missile => NextMissile}, State};
handle_call(get_state, _From, State) -> {reply, State, State};
handle_call(Request, _From, State) -> {reply, {error, {unsupported_call, Request}}, State}.

%% Ignores messages this city does not use.
handle_cast(_Message, State) -> {noreply, State}.

%% Launches a missile when the timer fires.
handle_info(launch, State) ->
    schedule_launch(config:hostile_city(spawn_ms)),
    case config:paused() of
        true -> {noreply, State};
        false -> {noreply, launch_missile_handler(State)}
    end;
handle_info(_Message, State) -> {noreply, State}.

%% Asks the sector controller to start one temporary hostile missile.
launch_missile_handler(#{
        id := CityId, x := X,
        sector_id := SectorId, sector_controller := SectorController,
        next_missile := Number
    } = State) ->
    %% Pick a protected city and calculate a flight toward it.
    {TargetId, TargetX} = random_target(config:protected_cities()),
    StartPosition = {X, 0.0},
    TargetPosition = {TargetX, 0.0},
    {Vx, Vz} = physics:ballistic_launch_velocity(
        StartPosition,
        physics:aim_position(TargetPosition),
        config:hostile_missile(speed_range)
    ),
    MissileId = {hostile_missile, {origin, SectorId}, CityId, Number},
    %% Keep the data needed to move or restore the missile.
    Options = #{
        id => MissileId, position => StartPosition, velocity => {Vx, Vz},
        target_id => TargetId, target_position => TargetPosition,
        sector_id => SectorId, sector_controller => SectorController
    },
    case sector_controller:start_child(SectorController, MissileId, hostile_missile,
            [Options], temporary) of
        {ok, MissilePid} ->
            %% Register the missile before its first movement update.
            ok = sector_controller:register_entity(
                SectorController, MissileId, hostile_missile, MissilePid),
            sector_controller:report_launch(SectorController),
            sector_controller:update_entity(SectorId, MissileId,
                #{position => StartPosition, velocity => {Vx, Vz}}),
            State#{next_missile => Number + 1};
        {error, _Reason} -> State
    end.

%% Schedules the next automatic launch.
schedule_launch(SpawnMs) -> erlang:send_after(SpawnMs, self(), launch).

%% Chooses one protected city as the missile target.
random_target(Cities) ->
    City = lists:nth(rand:uniform(length(Cities)), Cities),
    {maps:get(id, City), float(maps:get(x, City))}.
