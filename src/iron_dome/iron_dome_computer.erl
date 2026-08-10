-module(iron_dome_computer).
-behaviour(gen_server).

-export([start_link/1, name/1, snapshot/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(CLEANUP_MS, 1000).
-define(TRACK_TIMEOUT_US, 2000000).

%% Starts one globally discoverable computer for a sector.
start_link(#{sector_id := SectorId} = Options) ->
    gen_server:start_link({local, name(SectorId)}, ?MODULE, Options, []).

%% Returns this computer's node-local registered name.
name(SectorId) -> list_to_atom(atom_to_list(?MODULE) ++ "_" ++ atom_to_list(SectorId)).

%% Returns the tracking state required for checkpoint recovery.
snapshot(Pid) -> gen_server:call(Pid, snapshot).

%% Builds the computer state and starts track cleanup.
init(#{sector_id := SectorId, sector_controller := Controller} = Options) ->
    schedule_cleanup(),
    Restored = maps:get(restored_state, Options, #{}),
    Now = erlang:monotonic_time(microsecond),
    Samples = maps:map(fun(_Id, Track) -> Track#{last_seen => Now} end,
        maps:get(samples, Restored, #{})),
    {ok, #{sector_id => SectorId, sector_controller => Controller,
        samples => Samples, classified => maps:get(classified, Restored, #{})}}.

%% Returns portable tracking state or rejects unsupported requests.
handle_call(snapshot, _From, #{samples := Samples, classified := Classified} = State) ->
    PortableSamples = maps:map(fun(_Id, Track) -> maps:remove(last_seen, Track) end, Samples),
    {reply, #{samples => PortableSamples, classified => Classified}, State};
handle_call(Request, _From, State) -> {reply, {error, {unsupported_call, Request}}, State}.

%% Routes radar observations and missile termination messages.
handle_cast({radar_sample, Id, Position, FlightTimeUs}, State) ->
    {noreply, record_sample_handler(Id, Position, FlightTimeUs, State)};
handle_cast({missile_terminated, Id}, State) -> {noreply, remove_tracks([Id], State)};
handle_cast(_Message, State) -> {noreply, State}.

%% Periodically removes tracks no radar can still see.
handle_info(cleanup_tracks, State) ->
    schedule_cleanup(),
    case config:paused() of
        true -> {noreply, State};
        false -> {noreply, remove_stale_tracks(State)}
    end;
handle_info(_Message, State) -> {noreply, State}.

%% Stores newer radar observations until the missile is classified once.
record_sample_handler(Id, Position, FlightTimeUs, #{samples := Samples} = State) ->
    OldTrack = maps:get(Id, Samples, #{measurements => [], sampled_at => FlightTimeUs - 1}),
    case FlightTimeUs > maps:get(sampled_at, OldTrack) of
        false -> State;
        true ->
            Measurements = keep_three(maps:get(measurements, OldTrack) ++ [{FlightTimeUs, Position}]),
            Track = #{measurements => Measurements, sampled_at => FlightTimeUs,
                last_seen => erlang:monotonic_time(microsecond)},
            NewState = State#{samples => Samples#{Id => Track}},
            case length(Measurements) of
                3 -> process_track(Id, Measurements, NewState);
                _ -> NewState
            end
    end.

%% Classifies a track only once.
process_track(Id, Measurements, #{classified := Classified} = State) ->
    case maps:get(Id, Classified, unknown) of
        unknown -> classify_track(Id, Measurements, State);
        threat -> State;
        no_threat -> State
    end.

%% Reconstructs a new track and decides whether it threatens a protected city.
classify_track(Id, Measurements, #{classified := Classified} = State) ->
    case physics:rebuild_ballistic_path(Measurements) of
        {ok, Path} ->
            case threatens_protected_city(Path) of
                true ->
                    case apogee_intercept(Path) of
                        {ok, Position, Time} ->
                            update_engagement(Id, Position, Time,
                                State#{classified => Classified#{Id => threat}});
                        {error, _Reason} -> State
                    end;
                false ->
                    mark_no_threat_if_owner(Id, State),
                    State#{classified => Classified#{Id => no_threat}}
            end;
        {error, _Reason} -> State
    end.

%% Lets only the computer owning the intercept point start the engagement.
update_engagement(Id, Position, Time, #{sector_id := OwnSector} = State) ->
    case config:sector_at(element(1, Position)) of
        OwnSector -> fire_intercept(Id, Position, Time, State);
        _OtherSector -> State
    end.

%% Fires this sector's current launcher when the intercept is still possible.
fire_intercept(Id, Position, Time, #{sector_controller := Controller} = State) when Time > 0.0 ->
    case sector_controller:launcher(Controller) of
        {ok, Launcher} ->
            _ = iron_dome_launcher:fire(Launcher, Id, Position, Time);
        {error, _Reason} -> ok
    end,
    State;
fire_intercept(_Id, _Position, _Time, State) -> State.

%% Lets only the missile's origin computer record a harmless launch.
mark_no_threat_if_owner({hostile_missile, {origin, SectorId}, _City, _Number} = Id,
        #{sector_id := SectorId, sector_controller := Controller}) ->
    sector_controller:report_no_threat(Controller),
    case find_missile_pid(Id, config:sector_boundaries()) of
        {ok, Pid} -> hostile_missile:mark_no_threat(Pid);
        error -> ok
    end;
mark_no_threat_if_owner(_Id, _State) -> ok.

%% Searches sector controllers until the missile's current process is found.
find_missile_pid(_Id, []) -> error;
find_missile_pid(Id, [{SectorId, _Bounds} | Rest]) ->
    case config:sector_controller(SectorId) of
        {ok, Controller} ->
            try sector_controller:entity_pid(Controller, Id) of
                {ok, Pid} -> {ok, Pid};
                _ -> find_missile_pid(Id, Rest)
            catch exit:_Reason -> find_missile_pid(Id, Rest)
            end;
        {error, _Reason} -> find_missile_pid(Id, Rest)
    end.

%% Returns the future apogee selected as the interception point.
apogee_intercept(#{apogee := Position, time_to_apogee := Time}) when Time > 0.0 ->
    {ok, Position, Time};
apogee_intercept(_Path) -> {error, no_apogee_ahead}.

%% Checks whether the predicted impact lies inside a protected city.
threatens_protected_city(#{impact := Impact}) ->
    Radius = config:hostile_missile(city_hit_radius),
    Cities = [{float(maps:get(x, City)), 0.0} || City <- config:protected_cities()],
    lists:any(fun(City) -> physics:distance(Impact, City) =< Radius end, Cities).

%% Keeps only the three newest radar observations.
keep_three([_Oldest | Newest]) when length(Newest) =:= 3 -> Newest;
keep_three(Measurements) -> Measurements.

%% Removes tracks that have received no radar update for two seconds.
remove_stale_tracks(#{samples := Samples} = State) ->
    Cutoff = erlang:monotonic_time(microsecond) - ?TRACK_TIMEOUT_US,
    Stale = [Id || {Id, #{last_seen := LastSeen}} <- maps:to_list(Samples), LastSeen < Cutoff],
    remove_tracks(Stale, State).

%% Removes IDs from every tracking map.
remove_tracks(Ids, #{samples := Samples, classified := Classified} = State) ->
    Remove = fun(Map) -> lists:foldl(fun maps:remove/2, Map, Ids) end,
    State#{samples => Remove(Samples), classified => Remove(Classified)}.

%% Schedules the next stale-track cleanup.
schedule_cleanup() -> erlang:send_after(?CLEANUP_MS, self(), cleanup_tracks).
