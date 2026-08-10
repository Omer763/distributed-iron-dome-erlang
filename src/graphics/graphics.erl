-module(graphics).

-include_lib("wx/include/wx.hrl").

-export([
    open_window/0,
    resize_window/2,
    close_window/1,
    draw_buffered_frame/3,
    graphics_enabled/0,
    request_safe_shutdown/0,
    read_config_inputs/1,
    apply_config_to_nodes/2,
    reset_statistics/0,
    set_status_label/3
]).

-define(WIDTH, 1200).
-define(HEIGHT, 700).
-define(CONTROL_BAR_HEIGHT, 120).
-define(TICK_INPUT, 1001).
-define(SPAWN_INPUT, 1002).
-define(INTERCEPTOR_INPUT, 1003).
-define(ENEMY_INPUT, 1004).
-define(POST_BUTTON, 1005).
-define(RESET_BUTTON, 1006).
-define(RESOURCE_CACHE, graphics_resource_cache).

%% Creates the wx window, without ever crashing the coordinator's
%% supervisor tree if no display is available (missing DISPLAY, no wx
%% library, etc.). Sector hosting and cluster management must keep
%% working even when nothing can be drawn on screen.
open_window() ->
    try
        put(?RESOURCE_CACHE, #{}),
        Wx = wx:new(),
        Frame = wxFrame:new(wx:null(), -1, "Distributed Iron Dome", [{size, {?WIDTH, ?HEIGHT}}]),
        Panel = wxPanel:new(Frame, [{size, {?WIDTH, ?HEIGHT}}]),
        wxPanel:setBackgroundColour(Panel, {25, 55, 30}),
        BackBuffer = wxBitmap:new(?WIDTH, ?HEIGHT),
        Controls = create_controls(Panel, {?WIDTH, ?HEIGHT}),
        wxFrame:connect(Frame, close_window),
        wxPanel:connect(Panel, size),
        wxPanel:connect(Panel, command_button_clicked),
        wxFrame:show(Frame),
        wxFrame:raise(Frame),
        {ok, #{
            wx => Wx,
            frame => Frame,
            panel => Panel,
            back_buffer => BackBuffer,
            controls => Controls,
            size => {?WIDTH, ?HEIGHT}
        }}
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

%% Recreates the back buffer and repositions controls after a resize.
resize_window(Window, {Width, Height}) ->
    wxBitmap:destroy(maps:get(back_buffer, Window)),
    position_controls(maps:get(controls, Window), {Width, Height}),
    Window#{back_buffer => wxBitmap:new(Width, Height), size => {Width, Height}}.

%% Destroys the resources belonging to an open graphics window.
close_window(#{frame := Frame, back_buffer := BackBuffer}) ->
    destroy_cached_resources(),
    wxBitmap:destroy(BackBuffer),
    wxFrame:destroy(Frame),
    wx:destroy(),
    ok;
close_window(disabled) -> ok.

%% Draws the complete environment.
draw_frame(DC, GraphicsState) ->
    Background = cached_brush({10, 14, 28}),
    wxDC:setBackground(DC, Background),
    wxDC:clear(DC),
    SectorConfigs = config:sectors(),
    {Width, Height} = maps:get(size, maps:get(window, GraphicsState)),
    GroundY = max(160, Height - ?CONTROL_BAR_HEIGHT),
    Layout = {Width, Height, GroundY},
    Transform = world_transform(SectorConfigs, Width),
    Metrics = frame_metrics(GraphicsState),
    draw_stars(DC, Width, GroundY),
    draw_ground(DC, Layout),
    draw_global_statistics(DC, Metrics, Width),
    draw_sectors(DC, SectorConfigs, GraphicsState, Metrics, Transform, Layout),
    draw_entities(DC, GraphicsState, Transform, Layout),
    draw_explosions(DC, GraphicsState, Transform, Layout),
    draw_global_percentages(DC, Metrics, Width).

%% Draws a complete frame off-screen and copies it to the panel at once.
draw_buffered_frame(Panel, BackBuffer, GraphicsState) ->
    {Width, Height} = maps:get(size, maps:get(window, GraphicsState)),
    DrawHeight = max(1, Height - ?CONTROL_BAR_HEIGHT),
    MemoryDC = wxMemoryDC:new(BackBuffer),
    DrawFont = cached_draw_font(),
    wxDC:setFont(MemoryDC, DrawFont),
    draw_frame(MemoryDC, GraphicsState),
    PanelDC = wxClientDC:new(Panel),
    wxDC:blit(PanelDC, {0, 0}, {Width, DrawHeight}, MemoryDC, {0, 0}),
    wxClientDC:destroy(PanelDC),
    wxMemoryDC:destroy(MemoryDC).

%% Reads the optional headless environment override.
graphics_enabled() ->
    case os:getenv("GRAPHICS_ENABLED") of
        "false" -> false;
        "0" -> false;
        _ -> application:get_env(iron_dome, graphics_enabled, true)
    end.

%% Requests an orderly shutdown when the window is closed.
request_safe_shutdown() ->
    case whereis(cluster_coordinator) of
        undefined -> init:stop();
        _CoordinatorPid -> cluster_coordinator:shutdown()
    end.

%% Creates live controls for movement, hostile launch timing, and the
%% interceptor/enemy-missile hit percentages: a fixed label, an editable
%% number box, and a fixed unit, so the box only ever holds the number
%% itself.
create_controls(Panel, Size) ->
    TickMs = config:tick_ms(),
    SpawnMs = config:hostile_city(spawn_ms),
    HitChancePercent = round(config:interceptor(hit_chance) * 100),
    AccuracyPercent = round(config:hostile_missile(accuracy) * 100),
    PostButton = wxButton:new(Panel, ?POST_BUTTON, [{label, "APPLY"}]),
    ResetButton = wxButton:new(Panel, ?RESET_BUTTON, [{label, "Reset"}]),
    ButtonFont = wxFont:new(14, ?wxFONTFAMILY_DEFAULT, ?wxFONTSTYLE_NORMAL, ?wxFONTWEIGHT_BOLD),
    wxButton:setFont(PostButton, ButtonFont),
    wxButton:setFont(ResetButton, ButtonFont),
    StatusLabel = wxStaticText:new(Panel, ?wxID_ANY, ""),
    wxStaticText:setFont(StatusLabel, ButtonFont),
    wxFont:destroy(ButtonFont),
    Controls = #{
            tick_label => label(Panel, "Tick:"),
            tick_input => number_input(Panel, ?TICK_INPUT, TickMs),
            tick_unit => label(Panel, "ms"),
            spawn_label => label(Panel, "Launch Interval:"),
            spawn_input => number_input(Panel, ?SPAWN_INPUT, SpawnMs),
            spawn_unit => label(Panel, "ms"),
            interceptor_label => label(Panel, "Interceptor Hit Chance:"),
            interceptor_input => number_input(Panel, ?INTERCEPTOR_INPUT, HitChancePercent),
            interceptor_unit => label(Panel, "%"),
            enemy_label => label(Panel, "Hostile Accuracy:"),
            enemy_input => number_input(Panel, ?ENEMY_INPUT, AccuracyPercent),
            enemy_unit => label(Panel, "%"),
            post_button => PostButton,
            reset_button => ResetButton,
            status_label => StatusLabel
        },
    position_controls(Controls, Size),
    Controls.

%% Creates one white control label at font size 14.
label(Panel, Text) ->
    Label = wxStaticText:new(Panel, ?wxID_ANY, Text),
    wxStaticText:setForegroundColour(Label, {255, 255, 255}),
    Font = wxFont:new(12, ?wxFONTFAMILY_DEFAULT, ?wxFONTSTYLE_NORMAL, ?wxFONTWEIGHT_NORMAL),
    wxStaticText:setFont(Label, Font),
    wxFont:destroy(Font),
    Label.

%% Creates one editable numeric input box at font size 14.
number_input(Panel, Id, InitialValue) ->
    Input = wxTextCtrl:new(Panel, Id, [{value, integer_to_list(InitialValue)}]),
    Font = wxFont:new(14, ?wxFONTFAMILY_DEFAULT, ?wxFONTSTYLE_NORMAL, ?wxFONTWEIGHT_NORMAL),
    wxTextCtrl:setFont(Input, Font),
    wxFont:destroy(Font),
    Input.

%% Keeps the controls visible along the bottom when the window is
%% resized, all four label/input/unit groups and the APPLY button in
%% a single row.
position_controls(#{
        tick_label := TickLabel, tick_input := TickInput, tick_unit := TickUnit,
        spawn_label := SpawnLabel, spawn_input := SpawnInput, spawn_unit := SpawnUnit,
        interceptor_label := InterceptorLabel, interceptor_input := InterceptorInput,
        interceptor_unit := InterceptorUnit,
        enemy_label := EnemyLabel, enemy_input := EnemyInput, enemy_unit := EnemyUnit,
        post_button := PostButton, reset_button := ResetButton, status_label := StatusLabel
    }, {Width, Height}) ->
    Top = max(0, Height - ?CONTROL_BAR_HEIGHT + 5),
    InputY = Top + 27,
    ButtonSpace = 140,
    GroupWidth = max(150, (Width - ButtonSpace - 20) div 4),
    TickX = 10,
    SpawnX = TickX + GroupWidth,
    InterceptorX = SpawnX + GroupWidth,
    EnemyX = InterceptorX + GroupWidth,
    place_control(TickLabel, TickInput, TickUnit, TickX, Top, InputY, GroupWidth),
    place_control(SpawnLabel, SpawnInput, SpawnUnit, SpawnX, Top, InputY, GroupWidth),
    place_control(InterceptorLabel, InterceptorInput, InterceptorUnit,
        InterceptorX, Top, InputY, GroupWidth),
    place_control(EnemyLabel, EnemyInput, EnemyUnit, EnemyX, Top, InputY, GroupWidth),
    ButtonX = Width - 125,
    wxWindow:move(PostButton, {ButtonX, Top}),
    wxWindow:setSize(PostButton, {110, 34}),
    wxWindow:move(ResetButton, {ButtonX, Top + 39}),
    wxWindow:setSize(ResetButton, {110, 34}),
    wxWindow:move(StatusLabel, {ButtonX, Top + 78}),
    wxWindow:setSize(StatusLabel, {110, 24}).

%% Places one control as a label above its input and unit.
place_control(Label, Input, Unit, X, LabelY, InputY, GroupWidth) ->
    place_label(Label, X, LabelY, GroupWidth - 10),
    place_input(Input, X, InputY, 80),
    place_label(Unit, X + 86, InputY + 5, 25).

%% Positions and sizes one static label.
place_label(Widget, X, Y, Width) ->
    wxWindow:move(Widget, {X, Y}),
    wxWindow:setSize(Widget, {Width, 28}).

%% Positions and sizes one numeric input box.
place_input(Widget, X, Y, Width) ->
    wxWindow:move(Widget, {X, Y}),
    wxWindow:setSize(Widget, {Width, 30}).

%% Reads and validates all four inputs; returns only parseable {Fun, Val} pairs.
read_config_inputs(#{
        tick_input := TickInput, spawn_input := SpawnInput,
        interceptor_input := InterceptorInput, enemy_input := EnemyInput
    }) ->
    TickEntry = case parse_integer(wxTextCtrl:getValue(TickInput)) of
        {ok, Tick} when Tick > 0 -> [{set_tick_ms, Tick}];
        _ -> []
    end,
    SpawnEntry = case parse_integer(wxTextCtrl:getValue(SpawnInput)) of
        {ok, Spawn} when Spawn >= 0 -> [{set_spawn_ms, Spawn}];
        _ -> []
    end,
    InterceptorEntry = case parse_percent(wxTextCtrl:getValue(InterceptorInput)) of
        {ok, IP} -> [{set_interceptor_hit_chance, IP / 100.0}];
        error -> []
    end,
    EnemyEntry = case parse_percent(wxTextCtrl:getValue(EnemyInput)) of
        {ok, EP} -> [{set_hostile_accuracy, EP / 100.0}];
        error -> []
    end,
    TickEntry ++ SpawnEntry ++ InterceptorEntry ++ EnemyEntry.

%% Applies all config entries to each node via rpc:call; returns nodes that failed.
apply_config_to_nodes(Config, Nodes) ->
    [Node || Node <- Nodes, not apply_config_to_node(Config, Node)].

%% Starts fresh statistics in every sector while leaving cities running.
reset_statistics() ->
    lists:foreach(fun({SectorId, _Bounds}) ->
        case config:sector_controller(SectorId) of
            {ok, Controller} -> sector_controller:reset_statistics(Controller);
            {error, _Reason} -> ok
        end
    end, config:sector_boundaries()).

%% Applies every entry to one node; true only if all of them succeeded.
apply_config_to_node(Config, Node) ->
    lists:all(
        fun({Fun, Val}) ->
            case rpc:call(Node, config, Fun, [Val], 2000) of
                {badrpc, _} -> false;
                _ -> true
            end
        end,
        Config
    ).

%% Updates the status label text and color.
set_status_label(#{status_label := Label}, Text, Color) ->
    wxStaticText:setLabel(Label, Text),
    wxStaticText:setForegroundColour(Label, Color).

%% Parses a text box's contents as a plain integer, rejecting anything
%% with stray characters so a bad keystroke can't reach the simulation.
parse_integer(Text) ->
    case string:to_integer(string:trim(Text)) of
        {Value, []} -> {ok, Value};
        _ -> error
    end.

%% Parses a text box's contents as a whole-number percentage (0-100).
parse_percent(Text) ->
    case parse_integer(Text) of
        {ok, Value} when Value >= 0, Value =< 100 -> {ok, Value};
        _ -> error
    end.

%% Calculates world-to-screen horizontal transformation data.
world_transform([], _Width) ->
    {0.0, 1.0};
world_transform(SectorConfigs, Width) ->
    Bounds = [maps:get(bounds, Config) || Config <- SectorConfigs],
    MinX = lists:min([Min || {Min, _Max} <- Bounds]),
    MaxX = lists:max([Max || {_Min, Max} <- Bounds]),
    Scale = (Width - 40) / max(1.0, MaxX - MinX),
    {float(MinX), Scale}.

%% Draws a fixed starfield across the sky.
draw_stars(DC, Width, GroundY) ->
    Pen = cached_pen({160, 160, 200}, 1),
    wxDC:setPen(DC, Pen),
    lists:foreach(
        fun({X, Y}) -> wxDC:drawPoint(DC, {X, Y}) end,
        cached_stars(Width, GroundY)
    ).

%% Returns 220 star positions confined to the sky, regenerated only when
%% the window is resized. Cached in the process dictionary so the same
%% stars stay put from frame to frame instead of twinkling randomly.
cached_stars(Width, GroundY) ->
    case get(stars) of
        {{Width, GroundY}, Points} ->
            Points;
        _ ->
            rand:seed(exsss, {42, 17, 99}),
            SkyHeight = max(1, GroundY - 20),
            Points =
                [
                    {rand:uniform(max(1, Width)), rand:uniform(SkyHeight)}
                 || _ <- lists:seq(1, 220)
                ],
            put(stars, {{Width, GroundY}, Points}),
            Points
    end.

%% Draws the ground strip.
draw_ground(DC, {Width, Height, GroundY}) ->
    fill_rectangle(DC, 0, GroundY, Width, Height - GroundY, {25, 55, 30}),
    draw_line(DC, {0, GroundY}, {Width, GroundY}, {80, 150, 80}, 2).

%% Draws sector boundaries, cities, launchers, and labels.
draw_sectors(DC, SectorConfigs, GraphicsState, Metrics, Transform,
        {Width, _Height, GroundY} = Layout) ->
    Assignments = maps:get(assignments, maps:get(cluster, GraphicsState, #{}), #{}),
    lists:foreach(
        fun(Config) ->
            SectorId = maps:get(sector_id, Config),
            {MinX, MaxX} = maps:get(bounds, Config),
            ScreenMin = screen_x(MinX, Transform),
            ScreenMax = screen_x(MaxX, Transform),
            draw_line(DC, {ScreenMin, 66}, {ScreenMin, GroundY}, {70, 80, 120}, 1),
            Owner = maps:get(SectorId, Assignments, none),
            draw_sector_panel(DC, ScreenMin, ScreenMax - ScreenMin, SectorId, Owner, Metrics),
            draw_static_objects(DC, Config, Transform, Layout),
            case ScreenMax >= Width - 20 of
                true -> draw_line(DC, {ScreenMax, 66}, {ScreenMax, GroundY}, {70, 80, 120}, 1);
                false -> ok
            end
        end,
        SectorConfigs
    ).

%% Draws configured cities and launcher for one sector.
draw_static_objects(DC, Config, Transform, {_Width, _Height, GroundY}) ->
    {_MinX, Scale} = Transform,
    CityRadiusPixels = max(2, round(config:hostile_missile(city_hit_radius) * Scale)),
    lists:foreach(
        fun(City) ->
            X = maps:get(x, City),
            draw_city(DC, screen_x(X, Transform), GroundY, CityRadiusPixels, {170, 50, 50})
        end,
        maps:get(hostile_cities, Config, [])
    ),
    lists:foreach(
        fun(City) ->
            X = maps:get(x, City),
            ScreenX = screen_x(X, Transform),
            draw_city(DC, ScreenX, GroundY, CityRadiusPixels, {40, 170, 80})
        end,
        maps:get(protected_cities, Config, [])
    ),
    case maps:find(launcher, Config) of
        {ok, Launcher} ->
            X = maps:get(x, Launcher),
            draw_launcher(DC, screen_x(X, Transform), GroundY);
        error ->
            ok
    end.

%% Draws every active missile from sector snapshots.
draw_entities(DC, GraphicsState, Transform, Layout) ->
    Snapshots = maps:get(snapshots, GraphicsState, #{}),
    maps:foreach(
        fun(_SectorId, Snapshot) ->
            Entities = maps:get(entities, Snapshot, #{}),
            maps:foreach(
                fun(_EntityId, Entity) ->
                    draw_entity(DC, Entity, Transform, Layout)
                end,
                Entities
            )
        end,
        Snapshots
    ).

%% Draws one hostile or interceptor entity.
draw_entity(DC, #{type := Type, state := EntityState}, Transform, {_Width, Height, GroundY}) ->
    case maps:find(position, EntityState) of
        {ok, {X, Z}} when Z > 0.5 ->
            ScreenX = screen_x(X, Transform),
            VerticalScale = max(0.25, Height / ?HEIGHT),
            ScreenY = GroundY - round(Z * VerticalScale),
            Color = entity_color(Type, EntityState),
            fill_circle(DC, ScreenX, ScreenY, 5, Color);
        _GroundOrMissingPosition ->
            ok
    end.

%% Picks an entity's color. A hostile missile the radar has ruled
%% harmless (predicted not to reach any protected city) is drawn gray
%% instead of red.
entity_color(hostile_missile, EntityState) ->
    case maps:get(threat, EntityState, true) of
        false -> {140, 140, 140};
        true -> {240, 70, 45}
    end;
entity_color(iron_dome_missile, _EntityState) ->
    {70, 220, 255};
entity_color(_Type, _EntityState) ->
    {220, 220, 220}.

%% Draws older explosions first so a new effect at the same position stays visible.
draw_explosions(DC, GraphicsState, Transform, {_Width, Height, GroundY}) ->
    Now = erlang:monotonic_time(millisecond),
    lists:foreach(
        fun(#{position := {X, Z}, type := Type,
                started_at := StartedAt, duration_ms := DurationMs}) ->
            Progress = min(1.0, max(0.0, (Now - StartedAt) / DurationMs)),
            ScreenX = screen_x(X, Transform),
            VerticalScale = max(0.25, Height / ?HEIGHT),
            ScreenY = explosion_screen_y(Z, GroundY, VerticalScale),
            draw_explosion(DC, ScreenX, ScreenY, Progress, Type)
        end,
        ordered_explosions(maps:get(explosions, GraphicsState, []))
    ).

%% Draws the newest effect last when several explosions share a position.
ordered_explosions(Explosions) ->
    lists:sort(fun(A, B) -> maps:get(started_at, A) < maps:get(started_at, B) end, Explosions).

%% Keeps ground explosions visible above the ground/control boundary.
explosion_screen_y(Z, GroundY, _VerticalScale) when Z =< 0.5 -> GroundY - 5;
explosion_screen_y(Z, GroundY, VerticalScale) -> GroundY - round(Z * VerticalScale).

%% Draws one expanding multi-color explosion.
draw_explosion(DC, X, Y, Progress, Type) ->
    Radius = 5 + round(Progress * 28),
    {OuterColor, MiddleColor} = explosion_colors(Type),
    fill_circle(DC, X, Y, Radius, OuterColor),
    fill_circle(DC, X, Y, max(3, round(Radius * 0.62)), MiddleColor),
    fill_circle(DC, X, Y, max(2, round((1.0 - Progress) * 9)), {255, 250, 210}).

%% Selects explosion colors for each termination type.
explosion_colors(interception) ->
    {{40, 220, 90}, {160, 255, 180}};
explosion_colors(city_impact) ->
    {{220, 30, 30}, {255, 110, 90}};
explosion_colors(ground_impact) ->
    {{140, 140, 140}, {195, 195, 195}};
explosion_colors(interceptor_miss) ->
    {{35, 120, 220}, {100, 225, 255}};
explosion_colors(_OtherType) ->
    {{230, 100, 35}, {255, 210, 60}}.

%% Draws a city whose horizontal radius matches city_hit_radius.
draw_city(DC, X, GroundY, Radius, Color) ->
    BodyHeight = Radius * 7 div 3,
    TowerWidth = Radius,
    TowerHeight = Radius * 4 div 3,
    fill_rectangle(DC, X - Radius, GroundY - BodyHeight, Radius * 2, BodyHeight, Color),
    fill_rectangle(DC, X - TowerWidth div 2, GroundY - BodyHeight - TowerHeight,
        TowerWidth, TowerHeight, Color).

%% Draws a simple launcher symbol.
draw_launcher(DC, X, GroundY) ->
    fill_rectangle(DC, X - 14, GroundY - 14, 28, 14, {70, 110, 200}),
    draw_line(DC, {X, GroundY - 14}, {X + 14, GroundY - 34}, {150, 210, 255}, 4).

%% Converts a world X coordinate to screen X.
screen_x(X, {MinX, Scale}) ->
    20 + round((X - MinX) * Scale).

%% Converts a node atom into display text. A sector with no owner means
%% no worker node was available to run it -- the coordinator itself is
%% never a fallback, since it is an external display/control machine.
owner_text(none) ->
    "NO NODE AVAILABLE";
owner_text(Node) ->
    atom_to_list(Node).

%% Builds the title displayed above a sector.
sector_title(SectorId) ->
    string:uppercase(atom_to_list(SectorId)).

%% Draws statistics covering the complete distributed simulation.
draw_global_statistics(DC, Metrics, _Width) ->
    HostileCount = maps:get(hostile_count, Metrics),
    InterceptorCount = maps:get(interceptor_count, Metrics),
    {ProtectedCities, HostileCities} = city_counts(config:sectors()),
    Totals = maps:get(totals, Metrics),
    LineOne = format_text(
        "ONLINE HOSTS: ~B | CITIES: ~B (~B PROTECTED, ~B HOSTILE)",
        [maps:get(online_hosts, Metrics), ProtectedCities + HostileCities,
            ProtectedCities, HostileCities]),
    LineTwo = format_text(
        "GLOBAL | HOSTILES LAUNCHED: ~B | HOSTILES IN AIR: ~B | INTERCEPTORS IN AIR: ~B",
        [maps:get(fired, Totals), HostileCount, InterceptorCount]),
    LineThree = format_text(
        "HOSTILE HITS: ~B | HOSTILE MISSES: ~B | INTERCEPTOR HITS: ~B | INTERCEPTOR MISSES: ~B",
        [maps:get(hostile_hits, Totals), maps:get(hostile_misses, Totals),
            maps:get(interceptor_hits, Totals), maps:get(interceptor_misses, Totals)]),
    draw_text(DC, LineOne, 12, 10, {245, 220, 100}),
    draw_text(DC, LineTwo, 12, 34, {210, 220, 235}),
    draw_text(DC, LineThree, 12, 58, {210, 220, 235}).

%% Draws hostile outcomes and completed interceptor-attempt percentages.
%% Drawn last so it always appears on top of the sky and panel backgrounds.
draw_global_percentages(DC, Metrics, Width) ->
    Totals = maps:get(totals, Metrics),
    Fired = maps:get(fired, Totals),
    HostileHits = maps:get(hostile_hits, Totals),
    HostileMisses = maps:get(hostile_misses, Totals),
    InterceptorHits = maps:get(interceptor_hits, Totals),
    InterceptorMisses = maps:get(interceptor_misses, Totals),
    InterceptorAttempts = InterceptorHits + InterceptorMisses,
    Left = max(8, Width - 270),
    fill_rectangle(DC, Left - 8, 4, 270, 86, {10, 14, 28}),
    percentage_cell(DC, Left, 8, 254, "HOSTILE HITS", safe_pct(HostileHits, Fired), {255, 80, 80}),
    percentage_cell(DC, Left, 28, 254, "HOSTILE MISSES", safe_pct(HostileMisses, Fired), {140, 140, 140}),
    percentage_cell(DC, Left, 48, 254, "INTERCEPTOR HITS",
        safe_pct(InterceptorHits, InterceptorAttempts), {80, 220, 255}),
    percentage_cell(DC, Left, 68, 254, "INTERCEPTOR MISSES",
        safe_pct(InterceptorMisses, InterceptorAttempts), {100, 170, 255}).

%% Keeps a percentage value aligned to the right side of its own cell.
percentage_cell(DC, X, Y, Width, Label, Percentage, Color) ->
    draw_text(DC, Label ++ " :", X, Y, Color),
    draw_right_aligned(DC, integer_to_list(Percentage) ++ "%", X + Width, Y, Color).

safe_pct(_Num, 0) -> 0;
safe_pct(Num, Denom) -> round(100 * Num / Denom).

%% Draws one sector's clearly named missile and interceptor statistics.
draw_sector_panel(DC, ScreenMin, SectorWidth, SectorId, Owner, Metrics) ->
    PanelX = ScreenMin + 8,
    PanelTop = 102,
    PanelWidth = max(80, SectorWidth - 16),
    fill_bordered_rectangle(DC, PanelX, PanelTop, PanelWidth, 264, {10, 10, 40}, {70, 70, 140}),
    draw_line(DC, {PanelX + 4, PanelTop + 28}, {PanelX + PanelWidth - 4, PanelTop + 28},
        {70, 70, 140}, 1),
    draw_text(DC, sector_title(SectorId), PanelX + 12, PanelTop + 8, owner_color(Owner)),
    Stats = sector_panel_stats(SectorId, Metrics),
    stat_row(DC, PanelX, PanelWidth, PanelTop + 36, "HOSTILES LAUNCHED", {200, 200, 200},
        integer_to_list(maps:get(fired, Stats))),
    %% The only row that truly moves in both directions from tick to tick:
    %% it rises with every new launch and falls with every interception,
    %% impact, or miss. Everything below it only ever counts upward.
    stat_row(DC, PanelX, PanelWidth, PanelTop + 58, "HOSTILES IN AIR", {255, 230, 120},
        integer_to_list(maps:get(hostile_air, Stats))),
    stat_row(DC, PanelX, PanelWidth, PanelTop + 80, "INTERCEPTORS IN AIR", {70, 220, 255},
        integer_to_list(maps:get(interceptor_air, Stats))),
    stat_row(DC, PanelX, PanelWidth, PanelTop + 102, "INTERCEPTOR HITS", {80, 220, 255},
        integer_to_list(maps:get(interceptor_hits, Stats))),
    stat_row(DC, PanelX, PanelWidth, PanelTop + 124, "HOSTILE HITS", {255, 80, 80},
        integer_to_list(maps:get(hostile_hits, Stats))),
    stat_row(DC, PanelX, PanelWidth, PanelTop + 146, "HOSTILE MISSES", {140, 140, 140},
        integer_to_list(maps:get(hostile_misses, Stats))),
    stat_row(DC, PanelX, PanelWidth, PanelTop + 168, "INTERCEPTOR MISSES", {100, 170, 255},
        integer_to_list(maps:get(interceptor_misses, Stats))),
    draw_text(DC, "HOST NODE :", PanelX + 12, PanelTop + 190, owner_color(Owner)),
    draw_text(DC, owner_text(Owner), PanelX + 12, PanelTop + 212, owner_color(Owner)).

%% Draws a label on the left and its value against the panel's right edge.
stat_row(DC, PanelX, PanelWidth, Y, Label, Color, ValueText) ->
    draw_text(DC, Label ++ " :", PanelX + 12, Y, Color),
    draw_right_aligned(DC, ValueText, PanelX + PanelWidth - 12, Y, Color).

%% Builds one sector's counters from the metrics calculated once per frame.
sector_panel_stats(SectorId, Metrics) ->
    Statistics = maps:get(SectorId, maps:get(sector_statistics, Metrics), #{}),
    #{
        hostile_air => maps:get(SectorId, maps:get(hostile_air, Metrics), 0),
        interceptor_air => maps:get(SectorId, maps:get(interceptor_air, Metrics), 0),
        fired => maps:get(hostile_missiles_fired, Statistics, 0),
        interceptor_hits => maps:get(interceptions, Statistics, 0),
        hostile_hits => maps:get(city_hits, Statistics, 0),
        hostile_misses => maps:get(no_threat_count, Statistics, 0),
        interceptor_misses => maps:get(interceptor_misses, Statistics, 0)
    }.

%% Counts configured protected and hostile cities.
city_counts(SectorConfigs) ->
    lists:foldl(fun(Config, {Protected, Hostile}) ->
        {Protected + length(maps:get(protected_cities, Config, [])),
            Hostile + length(maps:get(hostile_cities, Config, []))}
    end, {0, 0}, SectorConfigs).

%% Calculates all entity counts and statistics in one snapshot traversal.
frame_metrics(GraphicsState) ->
    Cluster = maps:get(cluster, GraphicsState, #{}),
    Initial = #{hostile_count => 0, interceptor_count => 0,
        hostile_air => #{}, interceptor_air => #{}, sector_statistics => #{},
        online_hosts => length(maps:get(live_nodes, Cluster, [])),
        totals => #{fired => 0, interceptor_hits => 0, hostile_hits => 0,
            hostile_misses => 0, interceptor_misses => 0}},
    maps:fold(
        fun(SectorId, Snapshot, Metrics) ->
            Statistics = maps:get(statistics, Snapshot, #{}),
            Totals = add_statistics(Statistics, maps:get(totals, Metrics)),
            SectorStats = (maps:get(sector_statistics, Metrics))#{SectorId => Statistics},
            maps:fold(fun count_entity/3,
                Metrics#{totals => Totals, sector_statistics => SectorStats},
                maps:get(entities, Snapshot, #{}))
        end,
        Initial,
        maps:get(snapshots, GraphicsState, #{})
    ).

%% Adds one entity to its type and origin-sector counters.
count_entity({hostile_missile, {origin, Origin}, _City, _Number},
        #{type := hostile_missile}, Metrics) ->
    Air = increment_count(Origin, maps:get(hostile_air, Metrics)),
    Metrics#{hostile_count => maps:get(hostile_count, Metrics) + 1, hostile_air => Air};
count_entity({iron_dome_missile, {origin, Origin}, _Launcher, _Number, _Index},
        #{type := iron_dome_missile}, Metrics) ->
    Air = increment_count(Origin, maps:get(interceptor_air, Metrics)),
    Metrics#{interceptor_count => maps:get(interceptor_count, Metrics) + 1,
        interceptor_air => Air};
count_entity(_Id, #{type := hostile_missile}, Metrics) ->
    Metrics#{hostile_count => maps:get(hostile_count, Metrics) + 1};
count_entity(_Id, #{type := iron_dome_missile}, Metrics) ->
    Metrics#{interceptor_count => maps:get(interceptor_count, Metrics) + 1};
count_entity(_Id, _Entity, Metrics) -> Metrics.

%% Adds one sector's monotonic statistics to the global totals.
add_statistics(Statistics, Totals) ->
    Totals#{
        fired => maps:get(fired, Totals) + maps:get(hostile_missiles_fired, Statistics, 0),
        interceptor_hits => maps:get(interceptor_hits, Totals) + maps:get(interceptions, Statistics, 0),
        hostile_hits => maps:get(hostile_hits, Totals) + maps:get(city_hits, Statistics, 0),
        hostile_misses => maps:get(hostile_misses, Totals) + maps:get(no_threat_count, Statistics, 0),
        interceptor_misses => maps:get(interceptor_misses, Totals) + maps:get(interceptor_misses, Statistics, 0)
    }.

increment_count(Key, Counts) -> maps:update_with(Key, fun(N) -> N + 1 end, 1, Counts).

%% Formats an IO list as a flat wx-compatible string.
format_text(Format, Values) ->
    lists:flatten(io_lib:format(Format, Values)).

%% Selects a title color based on sector availability.
owner_color(none) ->
    {255, 100, 100};
owner_color(_Node) ->
    {100, 255, 150}.

%% Draws one colored line.
draw_line(DC, Start, Finish, Color, Width) ->
    Pen = cached_pen(Color, Width),
    wxDC:setPen(DC, Pen),
    wxDC:drawLine(DC, Start, Finish).

%% Draws a filled rectangle.
fill_rectangle(DC, X, Y, Width, Height, Color) ->
    Brush = cached_brush(Color),
    Pen = cached_pen(Color, 1),
    wxDC:setBrush(DC, Brush),
    wxDC:setPen(DC, Pen),
    wxDC:drawRectangle(DC, {X, Y}, {Width, Height}).

%% Draws a filled rectangle with a distinct border color.
fill_bordered_rectangle(DC, X, Y, Width, Height, FillColor, BorderColor) ->
    Brush = cached_brush(FillColor),
    Pen = cached_pen(BorderColor, 1),
    wxDC:setBrush(DC, Brush),
    wxDC:setPen(DC, Pen),
    wxDC:drawRectangle(DC, {X, Y}, {Width, Height}).

%% Draws a filled circle.
fill_circle(DC, X, Y, Radius, Color) ->
    Brush = cached_brush(Color),
    Pen = cached_pen(Color, 1),
    wxDC:setBrush(DC, Brush),
    wxDC:setPen(DC, Pen),
    wxDC:drawCircle(DC, {X, Y}, Radius).

%% Reuses the small set of pens, brushes, and fonts needed every frame.
cached_pen(Color, Width) -> cached_resource({pen, Color, Width},
    fun() -> {pen, wxPen:new(Color, [{width, Width}])} end).

cached_brush(Color) -> cached_resource({brush, Color},
    fun() -> {brush, wxBrush:new(Color)} end).

cached_draw_font() -> cached_resource(draw_font, fun() ->
    {font, wxFont:new(13, ?wxFONTFAMILY_DEFAULT, ?wxFONTSTYLE_NORMAL, ?wxFONTWEIGHT_NORMAL)}
end).

cached_resource(Key, Create) ->
    Cache = case get(?RESOURCE_CACHE) of undefined -> #{}; Value -> Value end,
    case maps:find(Key, Cache) of
        {ok, {_Type, Resource}} -> Resource;
        error ->
            {Type, Resource} = Create(),
            put(?RESOURCE_CACHE, Cache#{Key => {Type, Resource}}),
            Resource
    end.

%% Releases cached native wx objects before wx itself is stopped.
destroy_cached_resources() ->
    Cache = case erase(?RESOURCE_CACHE) of undefined -> #{}; Value -> Value end,
    maps:foreach(fun
        (_Key, {pen, Resource}) -> wxPen:destroy(Resource);
        (_Key, {brush, Resource}) -> wxBrush:destroy(Resource);
        (_Key, {font, Resource}) -> wxFont:destroy(Resource)
    end, Cache).

%% Draws colored text.
draw_text(DC, Text, X, Y, Color) ->
    wxDC:setTextForeground(DC, Color),
    wxDC:drawText(DC, Text, {X, Y}).

%% Draws text ending at RightX instead of starting at a fixed column.
draw_right_aligned(DC, Text, RightX, Y, Color) ->
    {TextWidth, _TextHeight} = wxDC:getTextExtent(DC, Text),
    draw_text(DC, Text, RightX - TextWidth, Y, Color).
