-module(nexus_boot_ffi).

-export([ensure_hackney_started/0, halt/1, hackney_stream_start/5]).

%% hackney must be running before the first request; gleam does not
%% guarantee OTP application boot order for transitive rebar3 dependencies.
ensure_hackney_started() ->
    case application:ensure_all_started(hackney) of
        {ok, _Started} -> {ok, nil};
        {error, Reason} -> {error, Reason}
    end.

halt(Code) ->
    %% Flush the default :logger handler before halting so fatal boot
    %% diagnostics always reach stdout/stderr before VM exit. Retry once on
    %% a transient non-ok result; never block indefinitely on a dead handler.
    flush_default_logger(2),
    erlang:halt(Code).

flush_default_logger(0) ->
    ok;
flush_default_logger(Attempts) ->
    case (try logger_std_h:filesync(default) catch _:_ -> {error, failed} end) of
        ok ->
            ok;
        _ when Attempts > 1 ->
            timer:sleep(25),
            flush_default_logger(Attempts - 1);
        _ ->
            ok
    end.



hackney_stream_start(Method, Url, Headers, Body, RecvTimeout) ->
    case hackney:request(Method, Url, Headers, Body,
                         [async, {recv_timeout, RecvTimeout}]) of
        {ok, ClientRef} -> {ok, {async_response, ClientRef}};
        {error, {closed, PartialBody}} -> {error, {connection_closed, PartialBody}};
        {error, Error} -> {error, {other, Error}}
    end.
