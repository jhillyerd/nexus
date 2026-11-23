%% Test-only environment canaries for the workspace scrub test
%% (env_test.gleam, jhillyerd/nexus#126).
%%
%% os:putenv/unsetenv take LISTS on this OTP — a Gleam String is a
%% binary and badargs straight through an @external — so this module
%% is the conversion seam. os:putenv mutates the EMULATOR's real
%% environment, which is exactly what a plain (unscrubbed) port would
%% pass to the child: the canary proves the allowlist drops it.
-module(nexus_env_test_ffi).

-export([put_env/2, unset_env/1, get_env/1, listen_loopback/0, close_socket/1]).

put_env(Name, Value) ->
    os:putenv(unicode:characters_to_list(Name),
              unicode:characters_to_list(Value)),
    nil.

unset_env(Name) ->
    os:unsetenv(unicode:characters_to_list(Name)),
    nil.

%% The original value of a name (for save/restore around a stomping
%% plant), {error, nil} when absent — the shape Gleam's Result wants.
get_env(Name) ->
    case os:getenv(unicode:characters_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

%% Bind an ephemeral TCP listener on 127.0.0.1 so live sandbox network
%% isolation tests have a real positive control (unsandboxed host connects
%% with rc=0; sandboxed bash must fail).
listen_loopback() ->
    case gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}, {active, false}, {reuseaddr, true}]) of
        {ok, Socket} ->
            case inet:port(Socket) of
                {ok, Port} -> {ok, {Socket, Port}};
                {error, _} ->
                    gen_tcp:close(Socket),
                    {error, nil}
            end;
        {error, _} ->
            {error, nil}
    end.

close_socket(Socket) ->
    _ = gen_tcp:close(Socket),
    nil.
