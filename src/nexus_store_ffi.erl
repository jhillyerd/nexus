-module(nexus_store_ffi).

-export([read_file/1, database_url/0, stop_pool/1]).

read_file(Path) ->
    case file:read_file(unicode:characters_to_list(Path)) of
        {ok, Binary} -> {ok, Binary};
        {error, Reason} ->
            {error, unicode:characters_to_binary(
                      io_lib:format("~p", [Reason]))}
    end.

database_url() ->
    case os:getenv("DATABASE_URL") of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

%% Stop the pool started by pog.start cleanly, before the runner VM halts.
%%
%% When a short-lived runner (store/migrate, dev_seed) returns from main/0,
%% the VM halts and tears the pool tree down. On boot, pgo parks
%% connection_starter in a blocking gen_statem:call on type_server
%% ({reload, _}, infinity timeout) that only returns once the type server's
%% initial OID bootstrap finishes — and that bootstrap checkout competes with
%% the pool's own connections still handshaking, so readiness can lag. If
%% the halt lands inside that window, the supervisor's reverse-order
%% termination kills type_server first, the starter's outstanding call dies
%% with it ({shutdown, {gen_statem, call, ...}}), and pgo_pool_sup logs a
%% shutdown_error report. Harmless, but noisy — and empirically intermittent
%% (it needs the bootstrap to still be in flight at halt).
%%
%% So: wait (bounded) for the type server to answer a reload call of ours.
%% gen_statem processes events in arrival order, and the starter's call was
%% enqueued before ours, so by the time ours is answered the starter is idle
%% too — the halt then finds every tree member idle and tears it down
%% silently (already the majority path today, minus the race).
%%
%% pog.start hands back the pool's queue gen_server (pgo_pool — the ETS
%% checkout queue), not the supervisor, and neither the type server nor the
%% supervisor is registered anywhere BY PID: the type server is found by
%% proc_lib metadata — translate_initial_call names the pgo callback module
%% (a gen_statem's raw $initial_call is {gen_statem, init_it, _}, so the
%% translation is required) — and the '$ancestors' entry in the process
%% dictionary pins it to OUR pool. The pool gen_server appears in that chain
%% as its REGISTERED NAME (pog registers it under the Gleam process.Name),
%% not as a pid, so both forms are accepted; this also guards against a
%% second pool in the same VM.
%%
%% Best-effort with a deadline: if the type server never becomes ready (e.g.
%% the database died mid-run), give up and let the VM halt as before — at
%% worst the old noise report can still appear, but the runner never hangs
%% on our account. Nothing is stopped or killed here; the tree dies with the
%% VM exactly as it did before, just no longer mid-boot.
stop_pool(GenPid) ->
    case
        find_type_server(erlang:processes(), pool_marks(GenPid), undefined)
    of
        undefined -> ok;
        TypeServer -> wait_type_server(TypeServer)
    end,
    nil.

wait_type_server(TypeServer) ->
    try
        gen_statem:call(TypeServer, {reload, erlang:monotonic_time()}, 10000),
        ok
    catch
        _Class:_Reason -> ok
    end.

%% The terms under which a descendant of the pool gen_server lists it in
%% '$ancestors': its pid, or its registered name when pog's registration
%% took effect before the tree was spawned.
pool_marks(GenPid) ->
    [GenPid | case erlang:process_info(GenPid, registered_name) of
        {registered_name, Name} when is_atom(Name) -> [Name];
        _ -> []
    end].

find_type_server([Pid | Rest], Marks, Found) ->
    case our_type_server(Pid, Marks) of
        true when Found =:= undefined -> find_type_server(Rest, Marks, Pid);
        _ -> find_type_server(Rest, Marks, Found)
    end;
find_type_server([], _Marks, Found) ->
    Found.

%% A gen_statem's raw $initial_call is {gen_statem, init_it, _}, so the
%% callback module is only visible through proc_lib:translate_initial_call/1;
%% the '$ancestors' entry in the process dictionary (note the $ prefix)
%% pins the process to OUR pool.
our_type_server(Pid, Marks) ->
    case catch proc_lib:translate_initial_call(Pid) of
        {pgo_type_server, init, 1} ->
            case erlang:process_info(Pid, dictionary) of
                {dictionary, Dict} ->
                    case lists:keyfind('$ancestors', 1, Dict) of
                        {'$ancestors', Ancestors} ->
                            lists:any(
                                fun(Mark) -> lists:member(Mark, Ancestors) end,
                                Marks
                            );
                        false ->
                            false
                    end;
                undefined ->
                    false
            end;
        _ ->
            false
    end.
