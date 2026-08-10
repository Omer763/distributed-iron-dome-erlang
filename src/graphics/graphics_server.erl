-module(graphics_server).
-behaviour(gen_server).

-include_lib("wx/include/wx.hrl").

-export([start_link/0, state/0, explosion/3, set_recovering/1, set_cluster/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(EXPLOSION_MS, 700).
-define(POST_BUTTON, 1005).
-define(RESET_BUTTON, 1006).

%% Starts the graphics server; used by app_sup.
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Returns display state; used by diagnostics.
state() -> gen_server:call(server(), state).

%% Adds an explosion; used by both missile modules.
explosion(SectorId, Position, Type) ->
    gen_server:cast(server(), {explosion, SectorId, node(), Position, Type}).

%% Toggles recovery display state; used by cluster_coordinator.
set_recovering(Value) when is_boolean(Value) ->
    gen_server:cast(server(), {recovering, Value}).

%% Updates displayed cluster state; used by cluster_coordinator.
set_cluster(Assignments, LiveNodes) ->
    gen_server:cast(server(), {cluster, Assignments, LiveNodes}).

%% Loads the first screen state and opens the window when enabled.
init([]) ->
    {ok, FrameMs} = application:get_env(iron_dome, graphics_sync_ms),
    %% Keep simulation data even when no window can be opened.
    BaseState = #{snapshots => current_snapshots(),
        cluster => #{assignments => #{}, live_nodes => []}, explosions => [],
        recovering => false, frame_ms => FrameMs, window => disabled},
    case graphics:graphics_enabled() of
        true ->
            case graphics:open_window() of
                {ok, Window} ->
                    erlang:send_after(FrameMs, self(), draw),
                    {ok, BaseState#{window => Window}};
                {error, Reason} ->
                    io:format("[graphics] window unavailable, running headless: ~p~n", [Reason]),
                    {ok, BaseState}
            end;
        false -> {ok, BaseState}
    end.

%% Returns the current screen state.
handle_call(state, _From, State) -> {reply, State, State};
handle_call(Request, _From, State) -> {reply, {error, {unsupported_call, Request}}, State}.

%% Updates recovery, cluster, and explosion data.
handle_cast({recovering, true}, State) ->
    {noreply, State#{recovering => true, explosions => []}};
handle_cast({recovering, false}, State) -> {noreply, State#{recovering => false}};
handle_cast({cluster, Assignments, LiveNodes}, State) ->
    {noreply, State#{cluster => #{assignments => Assignments, live_nodes => LiveNodes}}};

%% Stores explosion effects.
handle_cast({explosion, SectorId, Host, {X, Z}, Type},
        #{explosions := Explosions} = State) when is_number(X), is_number(Z) ->
    %% Ignore an effect from a node that no longer owns the sector.
    case valid_explosion(SectorId, Host, State) of
        false -> {noreply, State};
        true ->
            %% Give the effect an ID so its timer removes the right one.
            Id = erlang:unique_integer([monotonic, positive]),
            Explosion = #{id => Id, position => {float(X), float(Z)}, type => Type,
                started_at => erlang:monotonic_time(millisecond), duration_ms => ?EXPLOSION_MS},
            erlang:send_after(?EXPLOSION_MS, self(), {expire_explosion, Id}),
            {noreply, State#{explosions => [Explosion | Explosions]}}
    end;
handle_cast(_Message, State) -> {noreply, State}.

%% Draws the latest frame.
handle_info(draw, #{window := #{panel := Panel, back_buffer := Buffer}, frame_ms := FrameMs} = State) ->
    StartedAt = erlang:monotonic_time(millisecond),
    %% Read sector states once for this complete frame.
    NewState = State#{snapshots => current_snapshots()},
    graphics:draw_buffered_frame(Panel, Buffer, NewState),
    DrawTime = erlang:monotonic_time(millisecond) - StartedAt,
    %% Subtract drawing time to keep a steady frame speed.
    erlang:send_after(max(0, FrameMs - DrawTime), self(), draw),
    {noreply, NewState};

%% Resizes the window resources.
handle_info({wx, _, _, _, {wxSize, size, {Width, Height}, _}}, #{window := Window} = State)
        when Width > 0, Height > 0 ->
    {noreply, State#{window => graphics:resize_window(Window, {Width, Height})}};

%% Applies values entered in the graphics controls.
handle_info(#wx{id = ?POST_BUTTON, event = #wxCommand{type = command_button_clicked}},
        #{window := #{controls := Controls}} = State) ->
    Config = graphics:read_config_inputs(Controls),
    Nodes = lists:usort([node() | nodes()]),
    graphics:set_status_label(Controls, "SENDING...", {255, 200, 50}),
    Self = self(),
    spawn(fun() -> Self ! {config_result, graphics:apply_config_to_nodes(Config, Nodes), Config, 3} end),
    {noreply, State};
handle_info(#wx{id = ?RESET_BUTTON, event = #wxCommand{type = command_button_clicked}},
        #{window := #{controls := Controls}} = State) ->
    graphics:reset_statistics(),
    graphics:set_status_label(Controls, "RESET", {100, 255, 150}),
    erlang:send_after(3000, self(), clear_status_label),
    {noreply, State};
handle_info({config_result, [], _Config, _Retries}, #{window := #{controls := Controls}} = State) ->
    graphics:set_status_label(Controls, "SENT", {100, 255, 150}),
    erlang:send_after(3000, self(), clear_status_label),
    {noreply, State};
handle_info({config_result, Failed, Config, Retries}, #{window := #{controls := Controls}} = State)
        when Retries > 0 ->
    %% Retry only the nodes that did not accept the settings.
    graphics:set_status_label(Controls, "RETRYING...", {255, 200, 50}),
    Self = self(),
    spawn(fun() ->
        timer:sleep(800),
        Self ! {config_result, graphics:apply_config_to_nodes(Config, Failed), Config, Retries - 1}
    end),
    {noreply, State};
handle_info({config_result, Failed, _Config, 0}, #{window := #{controls := Controls}} = State) ->
    io:format("[graphics] configuration failed on nodes: ~p~n", [Failed]),
    graphics:set_status_label(Controls, "FAILED", {255, 80, 80}),
    erlang:send_after(5000, self(), clear_status_label),
    {noreply, State};
handle_info(clear_status_label, #{window := #{controls := Controls}} = State) ->
    graphics:set_status_label(Controls, "", {255, 255, 255}),
    {noreply, State};
handle_info({wx, _, _, _, {wxClose, close_window}}, State) ->
    graphics:request_safe_shutdown(),
    {noreply, State};
handle_info({expire_explosion, Id}, #{explosions := Explosions} = State) ->
    Remaining = [Explosion || #{id := ExplosionId} = Explosion <- Explosions, ExplosionId =/= Id],
    {noreply, State#{explosions => Remaining}};
handle_info(_Message, State) -> {noreply, State}.

%% Closes wx resources when the server stops.
terminate(_Reason, #{window := Window}) -> graphics:close_window(Window);
terminate(_Reason, _State) -> ok.

%% Reads snapshots without preventing independent headless startup.
current_snapshots() ->
    try snapshot_manager:snapshots()
    catch exit:_Reason -> #{}
    end.

%% Accepts effects only from the node currently assigned to the sector.
valid_explosion(_SectorId, _Host, #{recovering := true}) -> false;
valid_explosion(SectorId, Host, #{cluster := Cluster}) ->
    Assignments = maps:get(assignments, Cluster, #{}),
    maps:get(SectorId, Assignments, undefined) =:= Host.

%% Builds the explicit address of the coordinator's graphics server.
server() -> {?MODULE, config:coordinator_node()}.
