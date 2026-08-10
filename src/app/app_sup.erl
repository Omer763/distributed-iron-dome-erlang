-module(app_sup).

%% Starts the correct top-level processes for this node's role.
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

%% Starts the root supervisor.
start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% A coordinator runs cluster and graphics processes; a host runs node_manager.
init([]) ->
    Role = configured_role(),
    io:format("[app] starting: node=~p role=~p~n", [node(), Role]),
    Children =
        case Role of
            coordinator -> coordinator_children();
            host -> [host_child()]
        end,
    %% one_for_one restarts only the child process that failed.
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, Children}}.

%% Reads the optional node-role environment override.
configured_role() ->
    case os:getenv("IRON_DOME_ROLE") of
        "host" -> host;
        "coordinator" -> coordinator;
        _ -> application:get_env(iron_dome, role, coordinator)
    end.

%% Defines the three permanent processes running on the coordinator.
coordinator_children() ->
    SnapshotManager = #{
        id => snapshot_manager,
        start => {snapshot_manager, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [snapshot_manager]
    },
    Graphics = #{
        id => graphics_server,
        start => {graphics_server, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [graphics_server]
    },
    Coordinator = #{
        id => cluster_coordinator,
        start => {cluster_coordinator, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [cluster_coordinator]
    },
    [SnapshotManager, Graphics, Coordinator].

%% Defines the node manager running on each worker host.
host_child() ->
    #{
        id => node_manager,
        start => {node_manager, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [node_manager]
    }.
