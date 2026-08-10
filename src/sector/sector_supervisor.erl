-module(sector_supervisor).
-behaviour(supervisor).

-export([start_link/1, name/1, controller/1, launcher/1, runtime_state/2, start_child/5]).
-export([init/1]).

%% Starts the supervision tree for one sector.
start_link(#{sector_id := SectorId} = Config) ->
    supervisor:start_link({local, name(SectorId)}, ?MODULE, Config).

%% Returns this sector supervisor's node-local registered name.
name(SectorId) -> list_to_atom(atom_to_list(?MODULE) ++ "_" ++ atom_to_list(SectorId)).

%% Returns the sector controller PID.
controller(SectorId) -> child_pid(name(SectorId), sector_controller).

%% Returns the sector launcher PID.
launcher(SectorId) -> child_pid(name(SectorId), iron_dome_launcher).

%% Returns launcher and hostile-city counters for checkpoint recovery.
runtime_state(Node, SectorId) ->
    Children = supervisor:which_children({name(SectorId), Node}),
    {iron_dome_launcher, LauncherPid, worker, _} =
        lists:keyfind(iron_dome_launcher, 1, Children),
    Cities = maps:from_list([{CityId, hostile_city:snapshot(Pid)}
        || {{hostile_city, CityId}, Pid, worker, _} <- Children, is_pid(Pid)]),
    #{launcher => iron_dome_launcher:snapshot(LauncherPid), hostile_cities => Cities}.

%% Starts a temporary missile or interceptor under this supervisor.
start_child(SectorId, ChildId, Module, Args, Restart) ->
    Spec = #{id => ChildId, start => {Module, start_link, Args}, restart => Restart,
        shutdown => 5000, type => worker, modules => [Module]},
    supervisor:start_child(name(SectorId), Spec).

%% Defines the permanent processes belonging to one sector.
init(#{sector_id := SectorId} = Config) ->
    Controller = sector_controller:name(SectorId),
    Snapshot = maps:get(snapshot, Config, #{}),
    Runtime = maps:get(runtime_state, Snapshot, #{}),
    ControllerSpec = child(sector_controller, sector_controller, [Config]),
    RadarSpec = child(radar, iron_dome_radar,
        [#{sector_id => SectorId, sector_controller => Controller}]),
    LauncherConfig = maps:get(launcher, Config),
    LauncherSpec = child(iron_dome_launcher, iron_dome_launcher,
        [(maps:merge(LauncherConfig, maps:get(launcher, Runtime, #{})))#{
            sector_id => SectorId, sector_controller => Controller}]),
    ComputerSpec = child(iron_dome_computer, iron_dome_computer,
        [#{sector_id => SectorId, sector_controller => Controller,
            restored_state => maps:get(computer_state, Snapshot, #{})}]),
    CitySpecs = [child({hostile_city, maps:get(id, City)}, hostile_city,
        [(maps:merge(City, maps:get(maps:get(id, City),
            maps:get(hostile_cities, Runtime, #{}), #{})))#{
                sector_id => SectorId, sector_controller => Controller}])
        || City <- maps:get(hostile_cities, Config, [])],
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10},
        [ControllerSpec, RadarSpec, LauncherSpec, ComputerSpec] ++ CitySpecs}}.

%% Creates one permanent worker specification.
child(Id, Module, Args) ->
    #{id => Id, start => {Module, start_link, Args}, restart => permanent,
        shutdown => 5000, type => worker, modules => [Module]}.

%% Finds a permanent child by ID.
child_pid(Supervisor, ChildId) ->
    case lists:keyfind(ChildId, 1, supervisor:which_children(Supervisor)) of
        {ChildId, Pid, worker, _Modules} when is_pid(Pid) -> {ok, Pid};
        _ -> {error, not_found}
    end.
