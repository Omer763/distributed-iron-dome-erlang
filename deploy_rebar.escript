#!/usr/bin/env escript
%%! -setcookie iron_dome_cookie -kernel inet_dist_listen_min 9100 inet_dist_listen_max 9100 prevent_overlapping_partitions false -net_ticktime 60

main([LocalIp | HostNames]) when HostNames =/= [] ->
    Root = filename:dirname(filename:absname(escript:script_name())),
    {ok, _} = net_kernel:start([list_to_atom("deployer@" ++ LocalIp), longnames]),
    Ebin = compile(Root),
    Beams = [beam(File) || File <- filelib:wildcard(filename:join(Ebin, "*.beam"))],
    App = consult(filename:join(Ebin, "iron_dome.app")),
    {iron_dome, Config} = lists:keyfind(iron_dome, 1, consult(filename:join(Root, "sys.config"))),
    Hosts = [list_to_atom(Name) || Name <- HostNames],
    lists:foreach(fun check_worker/1, Hosts),
    Coordinator = node(),
    Shared = shared_config(Config),
    lists:foreach(fun(Node) -> deploy(Node, Beams, App,
        [{role, host}, {coordinator_node, Coordinator}, {graphics_enabled, false} | Shared]) end, Hosts),
    deploy(Coordinator, Beams, App, [{role, coordinator}, {coordinator_node, Coordinator},
        {graphics_enabled, true}, {cluster_nodes, Hosts}, {ebin_dir, Ebin} | Shared]),
    io:format("Deployment complete.~n"),
    receive stop -> ok end;
main(_) -> io:format("Usage: deploy_rebar.escript <local-ip> <host1@ip> [host2@ip ...]~n").

compile(Root) ->
    Rebar = case os:find_executable("rebar3") of
        false -> fail("rebar3 was not found in PATH.~n", []);
        Path -> Path
    end,
    Port = open_port({spawn_executable, Rebar}, [binary, exit_status, use_stdio, stderr_to_stdout, {cd, Root}, {args, ["compile"]}]),
    ok = wait_for_compile(Port),
    Ebin = filename:join([Root, "_build", "default", "lib", "iron_dome", "ebin"]),
    case filelib:wildcard(filename:join(Ebin, "*.beam")) of
        [] -> fail("rebar3 produced no BEAM files in ~s.~n", [Ebin]);
        _ -> Ebin
    end.

wait_for_compile(Port) ->
    receive
        {Port, {data, Output}} -> io:put_chars(Output), wait_for_compile(Port);
        {Port, {exit_status, 0}} -> ok;
        {Port, {exit_status, Status}} -> fail("rebar3 compile failed with status ~p.~n", [Status])
    end.

check_worker(Node) ->
    case net_adm:ping(Node) of
        pang -> fail("Cannot reach ~p; check its name, IP, cookie, and firewall.~n", [Node]);
        pong -> 
            case rpc:call(Node, application, get_env, [kernel, prevent_overlapping_partitions]) of
                {ok, false} -> ok;
                _ -> fail("Restart ~p with -kernel prevent_overlapping_partitions false.~n", [Node])
            end
    end.

shared_config(Config) ->
    Keys = [{snapshot_interval_ms, 100}, {checkpoint_history_ms, 5000},
        {graphics_sync_ms, 33}, {tick_ms, 50}, {heartbeat_interval_ms, 100},
        {heartbeat_timeout_ms, 400}, {defaults, #{}}, {sectors, []}],
    [{Key, proplists:get_value(Key, Config, Default)} || {Key, Default} <- Keys].

deploy(Node, Beams, App, Env) ->
    io:format("Deploying to ~p... ", [Node]),
    rpc:call(Node, application, stop, [iron_dome]),
    rpc:call(Node, application, unload, [iron_dome]),
    lists:foreach(fun({Module, Binary}) ->
        case rpc:call(Node, code, load_binary, [Module, atom_to_list(Module) ++ ".beam", Binary]) of
            {module, Module} -> ok;
            Error -> fail("Could not load ~p on ~p: ~p~n", [Module, Node, Error])
        end
    end, Beams),
    Spec = {application, iron_dome, application_terms(App, Env)},
    case rpc:call(Node, application, load, [Spec]) of
        ok -> ok;
        Error -> fail("Could not load application on ~p: ~p~n", [Node, Error])
    end,
    case rpc:call(Node, application, ensure_all_started, [iron_dome]) of
        {ok, _} -> io:format("started.~n");
        Error2 -> fail("Could not start application on ~p: ~p~n", [Node, Error2])
    end.

application_terms(App, Env) ->
    Apps = proplists:get_value(applications, App, []),
    NodeApps = case proplists:get_value(role, Env) of host -> lists:delete(wx, Apps); coordinator -> Apps end,
    BaseEnv = proplists:get_value(env, App, []),
    Merged = lists:foldl(fun({K, V}, Acc) -> lists:keystore(K, 1, Acc, {K, V}) end, BaseEnv, Env),
    lists:keystore(env, 1, lists:keystore(applications, 1, App,
        {applications, NodeApps}), {env, Merged}).

consult(File) ->
    case file:consult(File) of
        {ok, [{application, iron_dome, Terms}]} -> Terms;
        {ok, [Term]} -> Term;
        Error -> fail("Could not read ~s: ~p~n", [File, Error])
    end.

beam(File) ->
    {ok, Binary} = file:read_file(File),
    {list_to_atom(filename:basename(File, ".beam")), Binary}.

fail(Format, Values) -> io:format(Format, Values), halt(1).
