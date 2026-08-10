-module(iron_dome_radar).
-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% Starts a radar; used by sector_supervisor.
start_link(Options) -> gen_server:start_link(?MODULE, Options, []).

%% Saves the sector ID and starts the first radar scan.
init(#{sector_id := SectorId}) ->
    schedule_sample(),
    {ok, #{sector_id => SectorId}}.

%% Rejects requests because radar has no public request API.
handle_call(Request, _From, State) -> {reply, {error, {unsupported_call, Request}}, State}.

%% Ignores messages this radar does not use.
handle_cast(_Message, State) -> {noreply, State}.

%% Runs one radar scan when the timer fires.
handle_info(sample, State) ->
    %% Do not collect changing positions while movement is paused.
    case config:paused() of true -> ok; false -> sample_missiles(State) end,
    schedule_sample(),
    {noreply, State};
handle_info(_Message, State) -> {noreply, State}.

%% Reads only local airspace and broadcasts each observation to all computers.
sample_missiles(#{sector_id := SectorId}) ->
    %% Read only missiles currently stored in this radar's sector.
    Samples = sector_controller:hostile_positions(SectorId),
    lists:foreach(fun(Sample) -> broadcast_sample(Sample) end, Samples).

%% Sends one local observation to every sector computer.
broadcast_sample({MissileId, Position, FlightTimeUs}) ->
    %% Send to every computer because the intercept point may be elsewhere.
    lists:foreach(fun({SectorId, _}) ->
        case config:sector_computer(SectorId) of
            {ok, Computer} -> gen_server:cast(Computer,
                {radar_sample, MissileId, Position, FlightTimeUs});
            {error, _Reason} -> ok
        end
    end, config:sector_boundaries()).

%% Schedules the next radar sample.
schedule_sample() -> erlang:send_after(config:radar(sample_ms), self(), sample).
