%% Process-flag FFI for the codemode engine child (codemode plan phase 1).
%% gleam_erlang exposes neither `max_heap_size` nor a value-returning
%% `trap_exit` switch, so these three live here.
-module(nexus_codemode_ffi).

-export([set_max_heap_size_words/1, set_trap_exit/1, counter_next/1,
         safe_call/1, safe_format_error/1,
         task_put_pending/3, task_put_settled/2, task_get/1,
         kill_pending_tasks/0]).

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

%% ------------------------------------------------------------------
%% Task handle registry (await/all_settled redesign, ex-phase-2).
%%
%% The engine process owns every started task; the registry lives in
%% its process dictionary beside the budget counter. Entries are the
%% Gleam constructors {task_pending, Subject, Pid} / {task_settled,
%% Outcome} — this module only stores and returns the terms, never
%% inspects them (kill_pending_tasks/0 pattern-matches the pending
%% shape only).

task_put_pending(Id, Subject, Pid) ->
    erlang:put({?MODULE, task, Id}, {task_pending, Subject, Pid}),
    ok.

task_put_settled(Id, Outcome) ->
    erlang:put({?MODULE, task, Id}, {task_settled, Outcome}),
    ok.

task_get(Id) ->
    case erlang:get({?MODULE, task, Id}) of
        undefined -> {error, nil};
        Entry -> {ok, Entry}
    end.

%% Kill every still-pending task child at engine exit. Links cover the
%% abnormal engine deaths (worker kill, deadline, max-heap reaper) but a
%% NORMAL exit propagates nothing — this explicit reap is the only thing
%% guaranteeing no unawaited call outlives the script on the happy path.
%% Unlink BEFORE killing: the engine does not trap exits, so an
%% EXIT(killed) arriving through the link would take the engine down
%% right before its final report. Both calls are no-ops on an
%% already-dead child.
kill_pending_tasks() ->
    {dictionary, Dict} = erlang:process_info(self(), dictionary),
    [begin erlang:unlink(P), erlang:exit(P, kill) end
     || {{?MODULE, task, _}, {task_pending, _Subject, P}} <- Dict],
    ok.

%% Run a host-tool closure, turning a crash into an error value.
%% Task children run sibling tools in their own processes: a crashing
%% tool must settle {error, "host crashed: ..."} like any other failure
%% instead of taking the child down (and, through the link, the
%% engine). The reason text
%% is capped so a pathological stacktrace cannot balloon retained
%% output; the cut is codepoint-safe and falls back to a bare label if
%% the truncation lands inside a multi-byte sequence.
%%
%% The term is BOUNDED BEFORE FORMATTING (cubic review): pretty-printing
%% the whole reason first and truncating the result would still
%% materialise an unbounded iolist in an uncapped child. cap_term/2
%% shrinks the reason to a term whose ~p rendering is bounded (depth 3,
%% breadth 16, 100-byte binaries — a few hundred KB worst case), and
%% the whole text path is itself guarded so nothing here can crash the
%% reaper that is making the failure a value.
safe_call(Fun) ->
    try Fun() of
        {ok, _} = Ok -> {ok, Ok};
        {error, _} = Err -> {ok, Err}
    catch
        Class:Reason ->
            {error,
             try
                 trunc_bin(unicode:characters_to_binary(
                             io_lib:format("host crashed: ~p",
                                           [cap_term({Class, Reason}, 3)])), 500)
             catch
                 _:_ -> <<"host crashed">>
             end}
    end.

%% Shrink a crash term so its ~p rendering is bounded no matter how
%% pathological the reason: depth-capped recursion, breadth-capped
%% lists/tuples, byte-capped binaries, size-capped maps; anything else
%% exotic becomes a marker. The final binary is capped separately by
%% trunc_bin — this bounds the MATERIALISATION, that bounds the text.
cap_term(_T, D) when D =< 0 -> '...';
cap_term(T, _) when is_atom(T); is_number(T); is_pid(T);
                     is_reference(T); is_function(T) -> T;
cap_term(T, _) when is_binary(T) ->
    case byte_size(T) > 100 of
        true -> <<(binary_part(T, 0, 100))/binary, "...">>;
        false -> T
    end;
cap_term(T, D) when is_tuple(T) ->
    list_to_tuple(cap_list(tuple_to_list(T), 16, D));
cap_term(T, D) when is_list(T) ->
    cap_list(T, 16, D);
cap_term(T, D) when is_map(T) ->
    case maps:size(T) > 16 of
        true -> large_map_omitted;
        false -> maps:from_list(
                  [{cap_term(K, D - 1), cap_term(V, D - 1)}
                   || K := V <- T])
    end;
cap_term(_, _) -> omitted_value.

cap_list(_L, 0, _D) -> ['...'];
cap_list([H | T], N, D) -> [cap_term(H, D - 1) | cap_list(T, N - 1, D)];
cap_list([], _N, _D) -> [];
cap_list(Other, _N, D) -> [cap_term(Other, D - 1)].   %% improper tail

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
