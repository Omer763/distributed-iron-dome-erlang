-module(app).

%% Implements the OTP application start and stop callbacks.
-behaviour(application).

-export([start/2, stop/1]).

%% OTP calls this function to start the application process tree.
start(_StartType, _StartArgs) -> app_sup:start_link().

%% OTP calls this function after the application process tree stops.
stop(_State) ->
    io:format("[app] stopped: node=~p~n", [node()]),
    ok.
