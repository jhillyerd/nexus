-module(nexus_rescue_ffi).

-export([rescue/1]).

%% Run a thunk, turning any crash (error, exit, throw) into an Error that
%% carries a depth-capped print of the class and reason. Depth-capped so a
%% huge or self-referential term cannot flood the caller's note/log.
rescue(Fun) ->
    try Fun() of
        Value ->
            {ok, Value}
    catch
        Class:Reason:_Stack ->
            {error,
                unicode:characters_to_binary(
                    io_lib:format("~p:~P", [Class, Reason, 8])
                )}
    end.
