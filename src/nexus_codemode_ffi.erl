%% Process-flag FFI for the codemode engine child (codemode plan phase 1).
%% gleam_erlang exposes neither `max_heap_size` nor a value-returning
%% `trap_exit` switch, so these three live here.
-module(nexus_codemode_ffi).

-export([set_max_heap_size_words/1, set_trap_exit/1, counter_next/1]).

%% Hard memory ceiling for the CALLING process (the engine child): a VM
%% that outgrows it is killed with reason `killed`, which the worker
%% reports as `Script error: out of memory`. The call budget bounds
%% retained host results, not pure-Lua allocation — this bounds that.
set_max_heap_size_words(Words) ->
    erlang:process_flag(max_heap_size, Words).

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
