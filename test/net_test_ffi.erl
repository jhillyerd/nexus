%% Test-only helpers for the http_fetch deadline regression test. Offline:
%% loopback only, no external network (gleam test stays network-free).
-module(net_test_ffi).

-export([start_silent_listener/1, now_ms/0, gzip/1, gzip_corrupt/0,
         gzip_cut/0, incompressible/1, zlib_wrap/1, deflate_raw/1,
         ensure_listener/2]).

%% Idempotent mist-listener start for the offline loopback test services.
%% gleeunit runs every test in a fresh process, so the `let _ = mist.start`
%% idempotency pattern only works ONCE per module: a second mist.start on
%% the already-bound port fails the glisten supervision cascade loudly
%% enough to abort the whole eunit run. Memoize per port in
%% persistent_term instead. Returns true when THIS call started the
%% listener (so the caller can sleep before first use), false when it was
%% already up. A start error leaves the memo unset so the next caller
%% retries (loud, not silently swallowed).
ensure_listener(Port, StartThunk) ->
    Key = {nexus_test_listener_started, Port},
    case persistent_term:get(Key, false) of
        true ->
            false;
        false ->
            case StartThunk() of
                {ok, _} ->
                    persistent_term:put(Key, true),
                    true;
                {error, Reason} ->
                    %% A failed start must surface ITS reason: returning
                    %% false would read as "already up", and every later
                    %% test in the module would fail with a misleading
                    %% connection-refused instead of the real diagnosis.
                    error({listener_start_failed, Port, Reason})
            end
    end.

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

%% Compression helpers for the bounded-inflate tests: the three wire formats
%% a `Content-Encoding: gzip | deflate` origin can send. gzip/1 is RFC 1952
%% (what `zlib:gzip/1` emits), zlib_wrap/1 is RFC 1950 (the correct `deflate`
%% coding), deflate_raw/1 is RFC 1951 (what broken servers send as `deflate`).
gzip(Bin) ->
    zlib:gzip(Bin).

%% A wire-cap-truncated gzip stream: the first 20 bytes of a 40-byte gzip
%% of "0123456789abcdefghij" — inflates (deterministically, verified by
%% probe) to just "012345678" with no decode error, like a body cut
%% mid-stream. The stream ends WITHOUT its terminator, so `inflate_bounded`
%% must flag it truncated via the inflateEnd verdict.
gzip_cut() ->
    <<(zlib:gzip(<<"0123456789abcdefghij">>)):20/binary>>.

%% A plausible-looking gzip prefix (valid header, then garbage) — the
%% corrupt-stream case `inflate_bounded` must answer as a decode error.
gzip_corrupt() ->
    Gz = zlib:gzip(binary:copy(<<"hello world ">>, 1000)),
    <<Gz:20/binary, "garbage garbage garbage">>.

%% Deterministic pseudo-random bytes (a plain LCG — stable across OTP
%% versions, unlike rand): effectively incompressible, so gzip(N) is ~N
%% bytes and > 8 KiB of input / > 16 KiB of output — enough to exercise
%% `safeInflate`'s multi-chunk drain path in both directions.
incompressible(N) ->
    lcg(N, 16#2A7F9E31, <<>>).

lcg(0, _X, Acc) ->
    Acc;
lcg(N, X, Acc) ->
    X2 = (X * 1103515245 + 12345) band 16#FFFFFFFF,
    lcg(N - 1, X2, <<Acc/binary, (X2 bsr 16):8>>).

zlib_wrap(Bin) ->
    zlib:compress(Bin).

deflate_raw(Bin) ->
    Z = zlib:open(),
    try
        ok = zlib:deflateInit(Z, default, deflated, -15, 8, default),
        iolist_to_binary(zlib:deflate(Z, Bin, finish))
    after
        catch zlib:close(Z)
    end.
