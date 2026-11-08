%% Process-flag FFI for the codemode engine child (codemode plan phase 1).
%% gleam_erlang exposes neither `max_heap_size` nor a value-returning
%% `trap_exit` switch, so these three live here.
-module(nexus_codemode_ffi).

-export([set_max_heap_size_words/1, set_trap_exit/1, counter_next/1,
         counter_add/2, safe_call/1, safe_format_error/1]).

%% Hard memory ceiling for the CALLING process (the engine child): a VM
%% that outgrows it is killed with reason `killed`, which the worker
%% reports as `Script error: out of memory`. The call budget bounds
%% retained host results, not pure-Lua allocation — this bounds that.
%%
%% `include_shared_binaries` is the flag that actually counts refc
%% binaries — which is how Luerl stores every Lua string above heap-binary
%% size — toward the limit. Verified empirically on OTP 27, 28 and 29
%% (review finding): with `include_offheap` alone, a process holding
%% ~1 GB of live refc binaries SURVIVES a 20k-word limit on all three;
%% with `include_shared_binaries` it is killed on all three.
%% `include_offheap` is inert for binaries on 27-29 (and the OTP 28
%% parser reportedly ignores it entirely); it is kept defensively in
%% case a release starts honouring it — the accounting is additive and
%% unknown keys (none of these are, on any supported release) would
%% badarg at engine start, which tests would catch immediately.
%% NOTE: max_heap_size is checked at GC, not per allocation: a single
%% oversized allocation must transiently fit node memory and is killed
%% at the first GC after it (measured ~70 ms for a 400 MB string.rep
%% through the real path). Deployments running untrusted scripts should
%% still cap the node (cgroup / container memory limit) for that window.
set_max_heap_size_words(Words) ->
    erlang:process_flag(
      max_heap_size,
      #{size => Words, kill => true, include_offheap => true,
        include_shared_binaries => true}
     ).

%% Trap-exit switch returning the previous value so the worker can restore
%% it after the run; while trapping, the engine child's exit arrives as a
%% selectable message instead of killing the worker.
set_trap_exit(Bool) ->
    erlang:process_flag(trap_exit, Bool).

%% Bump-and-return a per-process counter (engine tool-call budget). The
%% engine is single-threaded, so the process dictionary is its natural
%% mutable cell — same pattern as nexus_loop_ffi's per-worker cells.
counter_next(Key) ->
    N = case erlang:get(Key) of
            undefined -> 0;
            V -> V
        end,
    erlang:put(Key, N + 1),
    N + 1.

%% Add N to the per-process counter in one step (call_all budgets a
%% whole batch before spawning anything) and return the new count.
counter_add(Key, N) ->
    V = case erlang:get(Key) of
            undefined -> 0;
            V0 -> V0
        end,
    erlang:put(Key, V + N),
    V + N.

%% Run a host-tool closure, turning a crash into an error value.
%% call_all's children run sibling tools in their own processes with
%% allSettled semantics: a crashing entry must report
%% {error, "host crashed: ..."} like any other failure instead of taking
%% the child down (and, through the link, the engine). The reason text
%% is capped so a pathological stacktrace cannot balloon retained
%% output; the cut is codepoint-safe and falls back to a bare label if
%% the truncation lands inside a multi-byte sequence.
safe_call(Fun) ->
    try Fun() of
        {ok, _} = Ok -> {ok, Ok};
        {error, _} = Err -> {ok, Err}
    catch
        Class:Reason ->
            {error, trunc_bin(unicode:characters_to_binary(
                               io_lib:format("host crashed: ~p",
                                             [{Class, Reason}])), 500)}
    end.

trunc_bin(Bin, Max) when byte_size(Bin) =< Max ->
    Bin;
trunc_bin(Bin, Max) ->
    <<Pre:Max/binary, _/binary>> = Bin,
    case unicode:characters_to_binary(Pre, utf8, utf8) of
        Cut when is_binary(Cut) -> <<Cut/binary, "...">>;
        _ -> <<"host crashed...">>
    end.

%% Format a glua error for the `Script error:` line. glua's own
%% formatter crashes on Lua runtime TYPE errors (badarg/badarith):
%% format_lua_value delegates to luerl_lib:format_value/1, which
%% returns IO data (e.g. [39, Value, 39]), and glua feeds it to
%% string.join, which demands binaries — so `"a" .. true` took the
%% engine down and reported "engine crashed" instead of the Lua
%% error. On a formatter crash, fall back to luerl_lib:format_error/1
%% (which handles those exceptions correctly) and, failing even that,
%% a capped raw dump of the exception term.
safe_format_error(Error) ->
    try
        glua:format_error(Error)
    catch
        _:_ ->
            Exc = case Error of
                      {lua_runtime_exception, E, _State} -> E;
                      Other -> Other
                  end,
            try
                trunc_bin(luerl_lib:format_error(Exc), 2000)
            catch
                _:_ ->
                    trunc_bin(unicode:characters_to_binary(
                               io_lib:format("lua error (unformatted): ~P",
                                             [Exc, 8])), 2000)
            end
    end.
