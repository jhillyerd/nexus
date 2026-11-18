%% Test-only helpers for the http_fetch deadline regression test. Offline:
%% loopback only, no external network (gleam test stays network-free).
-module(net_test_ffi).

-export([start_silent_listener/1, now_ms/0]).

%% A plain TCP listener that accepts and then never sends a byte. To an
%% https:// client this is exactly the stalled-TLS-handshake wedge: the
%% TCP connect completes, no ServerHello ever arrives, and (pre-fix,
%% hackney 1.25) ssl:connect(Sock, Opts) waits with no timeout at all.
start_silent_listener(Port) ->
    case gen_tcp:listen(Port, [binary, {packet, raw}, {active, false},
                               {reuseaddr, true}, {ip, {127, 0, 0, 1}}]) of
        {ok, Listener} ->
            spawn(fun() -> accept_loop(Listener) end),
            {ok, nil};
        {error, Reason} ->
            {error, unicode:characters_to_binary(io_lib:format("~tp", [Reason]))}
    end.

accept_loop(Listener) ->
    case gen_tcp:accept(Listener) of
        {ok, _Sock} -> accept_loop(Listener);
        % The listener closes when the test node winds down; exit quietly.
        {error, closed} -> ok;
        {error, _} -> accept_loop(Listener)
    end.

%% Monotonic wall measurement for the elapsed-time assertions.
now_ms() ->
    erlang:monotonic_time(millisecond).
