-module(app).

%% Starts and stops the application.
-behaviour(application).

-export([start/2, stop/1]).

%% Starts the main application processes.
start(_StartType, _StartArgs) -> app_sup:start_link().

%% Prints a message when the application stops.
stop(_State) ->
    io:format("[app] stopped: node=~p~n", [node()]),
    ok.
