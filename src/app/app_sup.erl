-module(app_sup).

%% Starts the correct top-level processes for this node's role.
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

%% Starts the root supervisor; used by app.
start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% Chooses which processes run on this node.
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
    %% This service keeps the saved state used by graphics and recovery.
    SnapshotManager = #{
        id => snapshot_manager,
        start => {snapshot_manager, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [snapshot_manager]
    },
    %% Graphics starts after snapshot storage is ready.
    Graphics = #{
        id => graphics_server,
        start => {graphics_server, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [graphics_server]
    },
    %% The coordinator starts last and can now use both services.
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
