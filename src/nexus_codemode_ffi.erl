%% Process-flag FFI for the codemode engine child (codemode plan phase 1).
%% gleam_erlang exposes neither `max_heap_size` nor a value-returning
%% `trap_exit` switch, so these three live here.
-module(nexus_codemode_ffi).

-export([set_max_heap_size_words/1, set_trap_exit/1, counter_next/1]).

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
