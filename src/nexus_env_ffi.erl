%% The environment workspace FFI (environments plan Phase 1).
%%
%% Leaves over erlang's port and file machinery, kept out of Gleam
%% because ports have no Gleam-side API in the pinned packages
%% (nexus/mcp set the pattern; this FFI adds cwd and kill-tree):
%%
%% - resolve/1: PATH resolution for a bare command name (spawn_executable
%%   does NOT search PATH). First regular-file execute-bit hit wins.
%% - is_executable/1: true when a path resolves (following symlinks) to a
%%   regular file with at least one execute bit set.
%% - inherited_path/0: the BEAM's inherited PATH (or ?DEFAULT_PATH), so
%%   Gleam-side spawn planning stays pure and testable.
%% - open_port/5: spawn a child with its stdio wired to the port
%%   (use_stdio, binary, exit_status, hide, stderr_to_stdout) with a
%%   working directory ({cd, Dir}) and a SCRUBBED environment
%%   ({env, sandbox_env/2}; see below).
%% - port_os_pid/1: query the spawned child's host OS PID while the port
%%   is open (used for PID-namespace backends like `bwrap --unshare-pid`
%%   where the first-line stdout marker is an in-namespace PID and killing
%%   the host `bwrap` process lets `--die-with-parent` reap the namespace).
%% - cgroup_create/2, cgroup_cleanup/1: best-effort Linux cgroup v2
%%   transient sub-cgroup (`memory.max`, `memory.swap.max`, `pids.max`)
%%   under a systemd-delegated subtree (`Delegate=cpu memory pids`), with
%%   `cgroup.kill` + `rmdir` cleanup; returns `{error, nil}` on any host
%%   without writable delegation so the caller falls back to `prlimit`.
%% - kill_tree/2: best-effort kill of the child AND its process group.
%%   The workspace bash prints its own pid (== its process-group id when
%%   launched under setsid) as the first stdout line; the caller parses
%%   it and hands it back here. A group kill with no pgid degrades to
%%   port_close (kills the direct child only — grandchildren orphan;
%%   the documented non-setsid fallback).
%% - to_text_lossy/1: command output is ARBITRARY BYTES; a tool result
%%   is a String. Try strict UTF-8 first; on invalid sequences decode
%%   latin-1 (every byte becomes a codepoint) so no byte is silently
%%   dropped and the model still sees the shape of the output.
%% - read_capped/2: file read capped WHILE READING (the http_fetch
%%   max-bytes rule: post-hoc truncation does not bound allocation).
%%   Returns the bytes plus whether the file was cut short.
%%
%% Every entry point is exception-guarded: a dead port or an unreadable
%% path degrades to a result the caller turns into an honest tool
%% error, never a crash of the per-turn worker.
-module(nexus_env_ffi).

-define(DEFAULT_PATH, "/usr/local/bin:/usr/bin:/bin").

-export([resolve/1, is_executable/1, inherited_path/0, open_port/5,
         port_os_pid/1, cgroup_create/2, cgroup_cleanup/1, kill_tree/2,
         to_text_lossy/1, read_capped/2, split_line/1, kill_group_marker/1,
         kill_pid_marker/1]).

-include_lib("kernel/include/file.hrl").

%% PATH resolution (the nexus_mcp_ffi rule): a slash-free name is
%% resolved against the inherited PATH; a slash-ful name passes
%% through. A hit must be a REGULAR FILE with an execute bit.
resolve(Name) ->
    Cmd = unicode:characters_to_list(Name),
    try
        case lists:member($/, Cmd) of
            true ->
                {ok, Name};
            false ->
                Path = os:getenv("PATH", ?DEFAULT_PATH),
                Dirs = string:split(Path, ":", all),
                Hit =
                    lists:search(
                        fun(D) -> executable(filename:join(D, Cmd)) end,
                        Dirs
                    ),
                case Hit of
                    {value, D} -> {ok, unicode:characters_to_binary(filename:join(D, Cmd))};
                    false -> {error, nil}
                end
        end
    catch
        _:_ -> {error, nil}
    end.

is_executable(Path) ->
    try
        executable(unicode:characters_to_list(Path))
    catch
        _:_ -> false
    end.

inherited_path() ->
    unicode:characters_to_binary(os:getenv("PATH", ?DEFAULT_PATH)).

executable(F) ->
    case file:read_file_info(F) of
        {ok, Info} ->
            Info#file_info.type =:= regular
            andalso (Info#file_info.mode band 8#111) =/= 0;
        _ ->
            false
    end.

%% Spawn a child with cwd confinement and an ALLOWLIST environment.
%% {cd, Dir} fails the spawn when the directory does not exist — the
%% caller creates the workspace lazily first, so a failure here is an
%% honest spawn error. {env, …} is the scrub (jhillyerd/nexus#126): a
%% plain port would inherit the BEAM's whole environment, and one
%% `env` inside a workspace bash would print DATABASE_URL, NEXUS_PG_*,
%% API keys — every secret the server holds — straight into the
%% transcript. Note {env, …} MERGES into the inherited environment
%% (verified against OTP 27: a canary planted via os:putenv rides
%% straight through the tuple form; the old replace-all string-list
%% form is removed), so sandbox_env/2 must explicitly UNSET everything
%% not allowed, not just set the allowed.
open_port(Command, Args, Cwd, AllowEnv, PassthroughNames) ->
    try
        Port =
            erlang:open_port({spawn_executable,
                              unicode:characters_to_list(Command)},
                             [use_stdio,
                              binary,
                              exit_status,
                              hide,
                              stderr_to_stdout,
                              {args,
                               [unicode:characters_to_list(A) || A <- Args]},
                              {cd, unicode:characters_to_list(Cwd)},
                              {env, sandbox_env(AllowEnv, PassthroughNames)}]),
        {ok, Port}
    catch
        _:_ -> {error, <<"spawn failed">>}
    end.

%% Query the spawned child's host OS PID while the port is still live.
port_os_pid(Port) ->
    try
        case erlang:port_info(Port, os_pid) of
            {os_pid, Pid} when is_integer(Pid) -> {ok, Pid};
            _ -> {error, nil}
        end
    catch
        _:_ -> {error, nil}
    end.

%% The workspace-child allowlist — the child's environment is EXACTLY
%% PassthroughNames (when set in the host env) overridden by AllowEnv,
%% with every other inherited variable explicitly unset via {Name, false}.
sandbox_env(AllowEnv, PassthroughNames) ->
    Pass =
        pass_through([unicode:characters_to_list(N) || N <- PassthroughNames]),
    Explicit =
        [{unicode:characters_to_list(K), unicode:characters_to_list(V)}
         || {K, V} <- AllowEnv],
    Allow = maps:from_list(Pass ++ Explicit),
    Unset =
        [{Name, false}
         || Name <- inherited_env_names(),
            not maps:is_key(Name, Allow)],
    maps:to_list(Allow) ++ Unset.

%% Create a transient Linux cgroup v2 sub-cgroup enforcing `memory.max`
%% (plus best-effort `memory.swap.max = 0`) and `pids.max` beneath a
%% systemd-delegated subtree (`Delegate=cpu memory pids`).
%%
%% Under cgroup v2's "no internal processes" rule, a cgroup with live
%% processes cannot enable controllers in `cgroup.subtree_control`. When
%% the BEAM starts directly in a delegated cgroup (e.g.
%% `/sys/fs/cgroup/system.slice/nexus.service`), this lazily creates a
%% sibling `beam/` leaf, moves the BEAM PID into `beam/cgroup.procs`, and
%% enables `+memory +pids` in `cgroup.subtree_control`. One-time preparation
%% (and a once-per-boot sweep of any stale `ws-*` children left by a prior
%% crashed BEAM) is serialized via `global:trans/2` and cached in
%% `persistent_term` so steady-state calls take no lock. Any failure
%% (non-Linux, missing delegation, read-only cgroupfs, sibling processes
%% preventing subtree_control) rolls back cleanly and returns `{error, nil}`
%% so the caller falls back to `prlimit --as`.
cgroup_create(MaxMemoryMb, MaxPids) ->
    try
        case find_cgroup_parent() of
            {ok, Parent} ->
                Id = integer_to_list(erlang:unique_integer([positive, monotonic])),
                CgDir = filename:join(Parent, "ws-" ++ os:getpid() ++ "-" ++ Id),
                case file:make_dir(CgDir) of
                    ok ->
                        MemBytes = integer_to_list(MaxMemoryMb * 1024 * 1024) ++ "\n",
                        PidsVal = integer_to_list(MaxPids) ++ "\n",
                        MemRes = file:write_file(filename:join(CgDir, "memory.max"), MemBytes),
                        _ = file:write_file(filename:join(CgDir, "memory.swap.max"), "0\n"),
                        PidRes = file:write_file(filename:join(CgDir, "pids.max"), PidsVal),
                        case {MemRes, PidRes} of
                            {ok, ok} ->
                                {ok, unicode:characters_to_binary(CgDir)};
                            _ ->
                                %% cgroupfs control files are kernel-virtual and
                                %% never unlinked; rmdir removes an empty cgroup.
                                _ = file:del_dir(CgDir),
                                {error, nil}
                        end;
                    _ ->
                        {error, nil}
                end;
            {error, nil} ->
                {error, nil}
        end
    catch
        _:_ -> {error, nil}
    end.

find_cgroup_parent() ->
    case persistent_term:get(nexus_env_cgroup_parent, undefined) of
        {ok, Parent} ->
            case filelib:is_dir(Parent) of
                true -> {ok, Parent};
                false -> prepare_cgroup_parent_serialized()
            end;
        unavailable ->
            {error, nil};
        undefined ->
            prepare_cgroup_parent_serialized()
    end.

prepare_cgroup_parent_serialized() ->
    %% Requester id MUST be per-process (`self()`), not `node()`, so concurrent
    %% first-time callers on the same BEAM node are mutually excluded.
    global:trans(
      {nexus_env_cgroup_prepare, self()},
      fun() ->
          case persistent_term:get(nexus_env_cgroup_parent, undefined) of
              {ok, Cached} ->
                  case filelib:is_dir(Cached) of
                      true -> {ok, Cached};
                      false -> prepare_and_cache_parent()
                  end;
              unavailable ->
                  {error, nil};
              undefined ->
                  prepare_and_cache_parent()
          end
      end).

prepare_and_cache_parent() ->
    case find_cgroup_parent_uncached() of
        {ok, Parent} ->
            sweep_empty_ws_cgroups(Parent),
            persistent_term:put(nexus_env_cgroup_parent, {ok, Parent}),
            {ok, Parent};
        {error, nil} ->
            %% Cgroup delegation is fixed at service start; cache unavailability
            %% so non-delegated hosts take no lock or filesystem probes on
            %% subsequent bash calls.
            persistent_term:put(nexus_env_cgroup_parent, unavailable),
            {error, nil}
    end.

find_cgroup_parent_uncached() ->
    case read_self_cgroup_v2() of
        {ok, SelfDir} ->
            case filename:basename(SelfDir) of
                "beam" ->
                    Parent = filename:dirname(SelfDir),
                    case Parent =/= "/sys/fs/cgroup"
                         andalso has_mem_and_pids(filename:join(Parent, "cgroup.subtree_control")) of
                        true -> {ok, Parent};
                        false -> {error, nil}
                    end;
                _ ->
                    case has_mem_and_pids(filename:join(SelfDir, "cgroup.controllers")) of
                        true -> prepare_delegated_parent(SelfDir);
                        false -> {error, nil}
                    end
            end;
        {error, nil} ->
            {error, nil}
    end.

%% Best-effort once-per-boot cleanup of empty stale `ws-*` cgroup directories
%% left by a prior crashed BEAM. Deliberately uses `file:del_dir/1` ONLY (never
%% `cgroup.kill`): in Linux cgroupfs, `rmdir` succeeds strictly on empty
%% cgroups and returns `ebusy` for any live sibling owned by another instance.
sweep_empty_ws_cgroups(Parent) ->
    case file:list_dir(Parent) of
        {ok, Entries} ->
            lists:foreach(
              fun(Entry) ->
                  case lists:prefix("ws-", Entry) of
                      true ->
                          CgDir = filename:join(Parent, Entry),
                          case filelib:is_dir(CgDir) of
                              true -> _ = file:del_dir(CgDir);
                              false -> ok
                          end;
                      false -> ok
                  end
              end,
              Entries);
        _ ->
            ok
    end.

read_self_cgroup_v2() ->
    case file:read_file("/proc/self/cgroup") of
        {ok, Bin} ->
            Lines = binary:split(Bin, <<"\n">>, [global]),
            case find_v2_line(Lines) of
                {ok, Rel} when Rel =/= "", Rel =/= "/" ->
                    {ok, "/sys/fs/cgroup" ++ Rel};
                _ ->
                    {error, nil}
            end;
        _ ->
            {error, nil}
    end.

find_v2_line([]) ->
    {error, nil};
find_v2_line([<<"0::", Rest/binary>> | _]) ->
    Trimmed = string:trim(unicode:characters_to_list(Rest)),
    {ok, Trimmed};
find_v2_line([_ | T]) ->
    find_v2_line(T).

has_mem_and_pids(Path) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            Tokens = string:lexemes(unicode:characters_to_list(Bin), " \t\r\n"),
            lists:member("memory", Tokens) andalso lists:member("pids", Tokens);
        _ ->
            false
    end.

prepare_delegated_parent(SelfDir) ->
    BeamDir = filename:join(SelfDir, "beam"),
    Created =
        case file:make_dir(BeamDir) of
            ok -> created;
            {error, eexist} -> existed;
            _ -> failed
        end,
    case Created of
        failed ->
            {error, nil};
        _ ->
            PidLine = os:getpid() ++ "\n",
            case file:write_file(filename:join(BeamDir, "cgroup.procs"), PidLine) of
                ok ->
                    SubtreePath = filename:join(SelfDir, "cgroup.subtree_control"),
                    _ = file:write_file(SubtreePath, "+memory +pids\n"),
                    case has_mem_and_pids(SubtreePath) of
                        true ->
                            {ok, SelfDir};
                        false ->
                            %% Roll back our move if enabling controllers failed
                            %% (e.g. another process shares SelfDir), deleting
                            %% `beam/` only if the rollback write succeeded.
                            case file:write_file(filename:join(SelfDir, "cgroup.procs"), PidLine) of
                                ok when Created =:= created ->
                                    _ = file:del_dir(BeamDir);
                                _ ->
                                    ok
                            end,
                            {error, nil}
                    end;
                _ ->
                    case Created of
                        created -> _ = file:del_dir(BeamDir);
                        existed -> ok
                    end,
                    {error, nil}
            end
    end.

%% Best-effort kill + removal of a transient sandbox cgroup. Writing "1"
%% to `cgroup.kill` (Linux 5.14+) atomically SIGKILLs every task still in
%% the cgroup before removing the directory.
cgroup_cleanup(CgDirBin) ->
    try
        CgDir = unicode:characters_to_list(CgDirBin),
        _ = file:write_file(filename:join(CgDir, "cgroup.kill"), "1\n"),
        remove_cgroup_dir(CgDir, 10)
    catch
        _:_ -> nil
    end.

remove_cgroup_dir(_CgDir, 0) ->
    nil;
remove_cgroup_dir(CgDir, Attempts) ->
    case file:del_dir(CgDir) of
        ok -> nil;
        {error, enoent} -> nil;
        {error, ebusy} ->
            timer:sleep(10),
            remove_cgroup_dir(CgDir, Attempts - 1);
        _ -> nil
    end.

%% The inherited environment's variable names (os:getenv/0 answers
%% "NAME=VALUE" strings; a leading-= split is the whole parse).
inherited_env_names() ->
    [case string:split(Entry, "=", leading) of
         [Name, _Value] -> Name;
         [Name] -> Name
     end
     || Entry <- os:getenv()].

%% {Name, Value} pairs for each listed variable that is actually set —
%% passthrough helpers, unset names contribute nothing.
pass_through(Names) ->
    lists:filtermap(
      fun(Name) ->
          case os:getenv(Name) of
              false -> false;
              Value -> {true, {Name, Value}}
          end
      end,
      Names).

%% Kill the child's whole process group when the pgid is known (the
%% first-line marker under setsid: the child IS the group leader), then
%% close the port (reaps the direct child regardless). The group kill
%% spawns the PATH-RESOLVED kill BINARY (never a shell builtin —
%% dash's builtin rejects `-- -N`-style negative operands, which is
%% how the first cut of this function silently killed nothing) in a
%% detached helper process: os:cmd blocks until the kill returns, and
%% the per-turn worker must answer a cancel promptly. Exceptions are
%% swallowed: a group already gone is a successful kill.
kill_tree(Port, Pgid) ->
    _ = case Pgid of
            {ok, N} ->
                erlang:spawn(fun() ->
                    try
                        case resolve("kill") of
                            {ok, Kill} ->
                                %% `--` is REQUIRED: procps-ng 4.x
                                %% parses a bare "-<pgid>" as another
                                %% signal spec and exits 0 having killed
                                %% nothing (verified against 4.0.4); the
                                %% binary — unlike dash's builtin —
                                %% accepts the end-of-options guard.
                                K =
                                    erlang:open_port(
                                      {spawn_executable,
                                       unicode:characters_to_list(Kill)},
                                      [{args, kill_args(N)},
                                       hide, exit_status, use_stdio]),
                                %% WAIT for the kill to act: the helper is
                                %% this port's connected process, and a
                                %% dying connected process closes (and so
                                %% kills) its ports — returning early
                                %% raced /usr/bin/kill to its own death,
                                %% silently killing nothing.
                                receive
                                    {K, {exit_status, _}} -> nil
                                after 5000 -> nil
                                end;
                            {error, nil} -> nil
                        end
                    catch
                        _:_ -> nil
                    end
                end);
            {error, nil} -> nil
        end,
    try erlang:port_close(Port) catch _:_ -> nil end,
    nil.

%% {pid, N} signals ONE process (the wrapperless fallback's direct
%% child); {pgid, N} signals the whole group (the setsid path). Both
%% carry the `--` guard (procps-ng 4.x parses a bare "-N" as another
%% signal spec and silently kills nothing).
kill_args({pid, N}) -> ["-9", "--", integer_to_list(N)];
kill_args({pgid, N}) -> ["-9", "--", "-" ++ integer_to_list(N)].

%% Gleam-side marker constructors for the two kill shapes.
kill_pid_marker(N) -> {pid, N}.
kill_group_marker(N) -> {pgid, N}.

%% Arbitrary command bytes -> String. Strict UTF-8 first; anything
%% invalid falls back to latin-1 decoding (no byte dropped, mojibake
%% visible — the model can still read the shape of the output).
to_text_lossy(Bin) ->
    case unicode:characters_to_binary(Bin, utf8) of
        Text when is_binary(Text) -> Text;
        _ ->
            unicode:characters_to_binary(unicode:characters_to_list(Bin, latin1), utf8)
    end.

%% Read at most MaxBytes, reporting truncation. Chunked reads bound
%% accumulation at MaxBytes + one chunk. Reason texts are stable
%% strings the tool layer surfaces verbatim.
read_capped(Path, MaxBytes) ->
    try
        case file:open(unicode:characters_to_list(Path), [read, binary, read_ahead]) of
            {error, Reason} -> {error, reason_text(Reason)};
            {ok, Device} ->
                try
                    read_loop(Device, MaxBytes, <<>>, 65536)
                after
                    file:close(Device)
                end
        end
    catch
        _:_ -> {error, <<"read failed">>}
    end.

read_loop(Device, Max, Acc, Chunk) ->
    %% Read up to one byte PAST Max: truncation is claimed only when a
    %% byte was actually cut, so a file of exactly Max bytes reports
    %% truncated=false (the eager >= Max head clause this replaces
    %% claimed truncation it never observed).
    case file:read(Device, min(Chunk, Max - byte_size(Acc) + 1)) of
        {ok, Data} ->
            New = <<Acc/binary, Data/binary>>,
            case byte_size(New) > Max of
                true -> {ok, {cut(New, Max), true}};
                false -> read_loop(Device, Max, New, Chunk)
            end;
        eof ->
            {ok, {Acc, false}};
        {error, Reason} -> {error, reason_text(Reason)}
    end.

%% Keep at most Max bytes of the accumulator.
cut(Bin, Max) when byte_size(Bin) > Max ->
    binary:part(Bin, 0, Max);
cut(Bin, _Max) ->
    Bin.

reason_text(enoent) -> <<"file not found">>;
reason_text(eacces) -> <<"permission denied">>;
reason_text(eisdir) -> <<"is a directory">>;
reason_text(Reason) -> unicode:characters_to_binary(io_lib:format("~p", [Reason])).
%% Split a byte buffer at the first newline: {ok, {Line, Rest}} or
%% {error, nil} when no newline has arrived yet (the marker-line parse
%% for the bash kill-tree pgid).
split_line(Bin) ->
    case binary:split(Bin, <<"\n">>) of
        [Line, Rest] -> {ok, {Line, Rest}};
        [_] -> {error, nil}
    end.
