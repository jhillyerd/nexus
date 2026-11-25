%% Erlang FFI helpers shared by the live sandbox escape probe runner
%% (`src/nexus/env/verify.gleam`) and `test/env_test.gleam`.
%%
%% Kept out of `nexus_env_ffi.erl` so test/verification-only helpers (mutating
%% the BEAM's own environment for secret-scrub canaries, binding a loopback
%% positive-control socket, and running cleanup blocks on failure) never
%% inflate the production sandbox runtime.
-module(nexus_env_verify_ffi).

-export([put_env/2, unset_env/1, get_env/1, listen_loopback/0, close_socket/1,
         with_cleanup/2]).

put_env(Name, Value) ->
    os:putenv(unicode:characters_to_list(Name),
              unicode:characters_to_list(Value)),
    nil.

unset_env(Name) ->
    os:unsetenv(unicode:characters_to_list(Name)),
    nil.

get_env(Name) ->
    case os:getenv(unicode:characters_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

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

%% Run `Fun()` and guarantee `Cleanup()` executes even when `Fun()` raises,
%% returning `Fun()`'s result. On the raise path a `Cleanup()` exception is
%% swallowed and the original exception re-raised; on the success path a
%% `Cleanup()` exception propagates and `Fun()`'s result is lost.
with_cleanup(Fun, Cleanup) ->
    try Fun() of
        Res ->
            _ = Cleanup(),
            Res
    catch
        Class:Reason:Stack ->
            _ = try Cleanup() catch _:_ -> ok end,
            erlang:raise(Class, Reason, Stack)
    end.
