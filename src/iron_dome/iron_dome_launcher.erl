-module(iron_dome_launcher).
-behaviour(gen_server).

-export([start_link/1, fire/4, snapshot/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% Starts one permanent Iron Dome launcher.
start_link(Options) -> gen_server:start_link(?MODULE, Options, []).

%% Launches interceptors toward a position at a requested time.
fire(Pid, TargetId, TargetPosition, TimeToTarget) ->
    gen_server:call(Pid, {fire, TargetId, TargetPosition, TimeToTarget}, 5000).

%% Returns the interceptor counter required for checkpoint recovery.
snapshot(Pid) -> gen_server:call(Pid, snapshot).

%% Builds the launcher runtime state. There is no cooldown to track.
init(#{id := Id, x := X, sector_id := SectorId,
        sector_controller := SectorController} = Options) ->
    {ok, #{
        id => Id, x => float(X),
        sector_id => SectorId, sector_controller => SectorController,
        next_interceptor => maps:get(next_interceptor, Options, 1)
    }}.

handle_call(snapshot, _From, #{next_interceptor := NextInterceptor} = State) ->
    {reply, #{next_interceptor => NextInterceptor}, State};
%% Rejects invalid interception times.
handle_call({fire, _TargetId, _Position, Time}, _From, State)
        when not is_number(Time); Time =< 0 ->
    {reply, {error, invalid_time_to_target}, State};
%% Launches the configured number of interceptors immediately.
handle_call({fire, TargetId, Position, Time}, _From, State) ->
    {Reply, NewState} = launch_interceptors(TargetId, Position, Time, State),
    {reply, Reply, NewState};
handle_call(Request, _From, State) -> {reply, {error, {unsupported_call, Request}}, State}.

%% Ignores unsupported asynchronous messages.
handle_cast(_Message, State) -> {noreply, State}.

%% Ignores unsupported process messages.
handle_info(_Message, State) -> {noreply, State}.

%% Prepares one shared engagement and starts all interceptors.
launch_interceptors(TargetId, Position, Time, #{x := X} = State) ->
    StartPosition = {X, 0.0},
    Engagement = #{
        target_id => TargetId,
        target_position => Position,
        time_to_target => Time,
        start_position => StartPosition,
        velocity => physics:velocity_to_arrive(StartPosition, Position, Time)
    },
    Count = config:launcher(interceptors_per_engagement),
    launch_interceptors(1, Count, Engagement, [], State).

%% Returns all successfully started interceptors.
launch_interceptors(Index, Count, _Engagement, Started, State) when Index > Count ->
    {{ok, lists:reverse(Started)}, State};

%% Starts one interceptor and continues the engagement.
launch_interceptors(Index, Count, Engagement, Started,
        #{id := LauncherId, sector_id := SectorId, sector_controller := SectorController,
            next_interceptor := Number} = State) ->
    InterceptorId = {iron_dome_missile, {origin, SectorId}, LauncherId, Number, Index},
    Options = Engagement#{
        id => InterceptorId,
        position => maps:get(start_position, Engagement),
        sector_id => SectorId,
        sector_controller => SectorController
    },
    case sector_controller:start_child(SectorController, InterceptorId, iron_dome_missile,
            [Options], temporary) of
        {ok, InterceptorPid} ->
            ok = sector_controller:register_entity(
                SectorController, InterceptorId, iron_dome_missile, InterceptorPid),
            sector_controller:update_entity(SectorId, InterceptorId, #{
                position => maps:get(position, Options),
                velocity => maps:get(velocity, Options),
                target_id => maps:get(target_id, Options),
                target_position => maps:get(target_position, Options),
                remaining_time => maps:get(time_to_target, Options)
            }),
            NewState = State#{next_interceptor => Number + 1},
            launch_interceptors(Index + 1, Count, Engagement, [InterceptorPid | Started], NewState);
        {error, Reason} ->
            {{error, {launch_failed, Reason, lists:reverse(Started)}}, State}
    end.
