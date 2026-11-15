%% The environment workspace FFI (environments plan Phase 1).
%%
%% Leaves over erlang's port and file machinery, kept out of Gleam
%% because ports have no Gleam-side API in the pinned packages
%% (nexus/mcp set the pattern; this FFI adds cwd and kill-tree):
%%
%% - resolve/1: PATH resolution for a bare command name (spawn_executable
%%   does NOT search PATH). First regular-file execute-bit hit wins.
%% - open_port/3: spawn a child with its stdio wired to the port
%%   (use_stdio, binary, exit_status, hide, stderr_to_stdout) with a
%%   working directory ({cd, Dir}) — the workspace's cwd default.
%% - kill_tree/1: best-effort kill of the child AND its process group.
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

-export([resolve/1, open_port/3, kill_tree/2, to_text_lossy/1, read_capped/2,
         split_line/1]).

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
                Path = os:getenv("PATH", "/usr/local/bin:/usr/bin:/bin"),
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

executable(F) ->
    case file:read_file_info(F) of
        {ok, Info} ->
            Info#file_info.type =:= regular
            andalso (Info#file_info.mode band 8#111) =/= 0;
        _ ->
            false
    end.

%% Spawn a child with cwd confinement. {cd, Dir} fails the spawn when
%% the directory does not exist — the caller creates the workspace
%% lazily first, so a failure here is an honest spawn error.
open_port(Command, Args, Cwd) ->
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
                              {cd, unicode:characters_to_list(Cwd)}]),
        {ok, Port}
    catch
        _:_ -> {error, <<"spawn failed">>}
    end.

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
                                      [{args, ["-9", "--", "-" ++ integer_to_list(N)]},
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
