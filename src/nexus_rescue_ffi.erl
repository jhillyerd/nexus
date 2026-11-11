-module(nexus_rescue_ffi).

-export([rescue/1]).

%% Run a thunk, turning any crash (error, exit, throw) into an Error that
%% carries a depth- AND size-capped print of the class and reason. Depth
%% alone (`~P`) bounds nesting, not output — a huge flat term would still
%% be fully materialized into the caller's note — so `chars_limit` caps
%% the rendered characters too.
rescue(Fun) ->
    try Fun() of
        Value ->
            {ok, Value}
    catch
        Class:Reason:_Stack ->
            {error,
                unicode:characters_to_binary(
                    io_lib:write(
                        {Class, Reason},
                        [{depth, 8}, {chars_limit, 500}]
                    )
                )}
    end.
