-module(physics).

-export([
    ballistic_launch_velocity/3,
    aim_position/1,
    projectile_step/3,
    reached_ground/1,
    velocity_to_arrive/3,
    rebuild_ballistic_path/1,
    linear_step/3,
    distance/2,
    timestamp/0,
    elapsed_seconds/1
]).

-define(GRAVITY, 10.0).

%% Returns a node-local timestamp for measuring one process's movement.
timestamp() -> erlang:monotonic_time(microsecond).

%% Returns elapsed seconds and a new timestamp for the next movement.
elapsed_seconds(Previous) ->
    Current = timestamp(),
    {(Current - Previous) / 1000000.0, Current}.

%% Calculates a valid ballistic launch velocity toward a ground target.
ballistic_launch_velocity({X, _Z}, {TargetX, _TargetZ}, {MinSpeed, MaxSpeed}) ->
    Distance = abs(float(TargetX) - float(X)),
    RandomSpeed = random_between(MinSpeed, MaxSpeed),
    Speed = max(RandomSpeed, math:sqrt(?GRAVITY * Distance) + 1.0),
    SinTwoTheta = min(1.0, ?GRAVITY * Distance / (Speed * Speed)),
    LowAngle = math:asin(SinTwoTheta) / 2.0,
    HighAngle = math:pi() / 2.0 - LowAngle,
    Angle = launch_angle(LowAngle, HighAngle),
    Direction =
        case TargetX >= X of
            true -> 1.0;
            false -> -1.0
        end,
    {Direction * Speed * math:cos(Angle), Speed * math:sin(Angle)}.

%% Uses the high trajectory when the low one is below the configured minimum.
launch_angle(LowAngle, HighAngle) ->
    MinAngle = config:hostile_missile(min_launch_angle) * math:pi() / 180.0,
    case LowAngle < MinAngle orelse rand:uniform(2) =:= 2 of
        true -> HighAngle;
        false -> LowAngle
    end.

%% Applies the configured hostile-missile accuracy to a target position.
aim_position({TargetX, TargetZ} = TargetPosition) ->
    Accuracy = config:hostile_missile(accuracy),
    case Accuracy >= 1.0 of
        true -> TargetPosition;
        false ->
            Radius = config:hostile_missile(city_hit_radius),
            Sigma = Radius / (math:sqrt(2.0) * inverse_erf(Accuracy)),
            {TargetX + Sigma * standard_normal(), TargetZ}
    end.

%% Generates a standard normal value with the Box-Muller formula.
standard_normal() ->
    math:sqrt(-2.0 * math:log(rand:uniform())) * math:cos(2.0 * math:pi() * rand:uniform()).

%% Approximates inverse erf so P(abs(error) =< city radius) equals accuracy.
inverse_erf(X) ->
    A = 0.147,
    Log = math:log(1.0 - X * X),
    Part = 2.0 / (math:pi() * A) + Log / 2.0,
    math:sqrt(math:sqrt(Part * Part - Log / A) - Part).

%% Advances a projectile by one time step under constant gravity.
projectile_step({X, Z}, {Vx, Vz}, Dt) ->
    EndZ = Z + Vz * Dt - 0.5 * ?GRAVITY * Dt * Dt,
    HitsGround = EndZ =< 0.0 andalso (Z > 0.0 orelse Vz < 0.0),
    Step = case HitsGround of
        true -> min(Dt, (Vz + math:sqrt(Vz * Vz + 2.0 * ?GRAVITY * Z)) / ?GRAVITY);
        false -> Dt
    end,
    NewX = X + Vx * Step,
    NewZ = case HitsGround of
        true -> 0.0;
        false -> max(0.0, Z + Vz * Step - 0.5 * ?GRAVITY * Step * Step)
    end,
    NewVz = Vz - ?GRAVITY * Step,
    {{NewX, NewZ}, {Vx, NewVz}}.

%% Returns true when a projectile has reached ground level.
reached_ground({_X, Z}) ->
    Z =< 0.0.

%% Calculates constant velocity needed to reach a point at a given time.
velocity_to_arrive({StartX, StartZ}, {TargetX, TargetZ}, TimeSeconds) when TimeSeconds > 0.0 ->
    {(TargetX - StartX) / TimeSeconds, (TargetZ - StartZ) / TimeSeconds}.

%% Rebuilds the ballistic path from three timed radar observations.
rebuild_ballistic_path([{T0, {X0, Z0}}, {T1, {X1, Z1}}, {T2, {X2, Z2}}])
        when T0 < T1, T1 < T2 ->
    Times = [(T0 - T2) / 1000000.0, (T1 - T2) / 1000000.0, 0.0],
    Vx = line_slope(Times, [X0, X1, X2]),
    CorrectedZ = [Z + 0.5 * ?GRAVITY * T * T
        || {Z, T} <- lists:zip([Z0, Z1, Z2], Times)],
    Vz = line_slope(Times, CorrectedZ),
    predict_trajectory({X2, Z2}, Vx, Vz);
rebuild_ballistic_path(_Samples) ->
    {error, requires_three_ordered_points}.

%% Returns the least-squares slope through three timed values.
line_slope(Times, Values) ->
    MeanT = lists:sum(Times) / length(Times),
    MeanV = lists:sum(Values) / length(Values),
    Numerator = lists:sum([(T - MeanT) * (V - MeanV)
        || {T, V} <- lists:zip(Times, Values)]),
    Denominator = lists:sum([math:pow(T - MeanT, 2) || T <- Times]),
    Numerator / Denominator.

%% Predicts where a ballistic path reaches Vz = 0 (its apex) and where it
%% eventually reaches the ground, from current position and velocity.
predict_trajectory(_CurrentPosition, _Vx, Vz) when Vz =< 0.0 ->
    {error, passed_apogee};
predict_trajectory({CurrentX, CurrentZ}, Vx, Vz) ->
    TimeToApogee = Vz / ?GRAVITY,
    Apogee = {
        CurrentX + Vx * TimeToApogee,
        CurrentZ + Vz * TimeToApogee - 0.5 * ?GRAVITY * TimeToApogee * TimeToApogee
    },
    %% Positive root of 0 = CurrentZ + Vz*t - 0.5*g*t^2.
    TimeToImpact = (Vz + math:sqrt(Vz * Vz + 2.0 * ?GRAVITY * CurrentZ)) / ?GRAVITY,
    Impact = {CurrentX + Vx * TimeToImpact, 0.0},
    {ok, #{
        apogee => Apogee,
        time_to_apogee => TimeToApogee,
        impact => Impact,
        time_to_impact => TimeToImpact
    }}.

%% Advances an object at constant velocity.
linear_step({X, Z}, {Vx, Vz}, DeltaSeconds) ->
    {X + Vx * DeltaSeconds, Z + Vz * DeltaSeconds}.

%% Calculates straight-line distance between two points.
distance({X1, Z1}, {X2, Z2}) ->
    math:sqrt(math:pow(X2 - X1, 2) + math:pow(Z2 - Z1, 2)).

%% Returns a random floating-point value inside a range.
random_between(Min, Max) ->
    float(Min) + rand:uniform() * (float(Max) - float(Min)).
