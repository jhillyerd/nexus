%% Test-only exception rescue helper for `test/prop.gleam` so raised exceptions
%% inside property callbacks report the exact root_seed, trial, and trial_seed.
-module(prop_ffi).

-export([rescue_check/1]).

rescue_check(Fun) ->
    try
        {ok, Fun()}
    catch
        Class:Reason:Stacktrace ->
            Formatted = io_lib:format("~p:~p~n~p", [Class, Reason, Stacktrace]),
            {error, unicode:characters_to_binary(Formatted)}
    end.
