%% The MCP stdio transport FFI (plugin-api plan Phase 2).
%%
%% Three tiny leaves over erlang's port machinery, kept out of Gleam
%% because ports have no Gleam-side API in the pinned packages:
%%
%% - open_port/3: spawn the MCP server child (`{spawn_executable, Cmd}`
%%   — a relative name is resolved through PATH) with its stdio wired
%%   to the port (use_stdio), binary mode (frames arrive as
%%   `{Port, {data, Bytes}}`), and exit_status so the external
%%   process's death arrives as `{Port, {exit_status, Code}}` instead
%%   of an exit signal (the adapter actor then degrades honestly; it
%%   is never crash-linked to an external process). Env pairs
%%   override/add to the inherited environment.
%% - send_line/2: one newline-terminated JSON-RPC frame to the child's
%%   stdin. Newline-delimited framing per the MCP stdio transport
%%   spec; a frame MUST NOT contain embedded newlines (our encoder
%%   guarantees that — gleam_json never emits raw newlines).
%% - take_lines/1: split accumulated stdin bytes into complete lines,
%%   returning {Lines, Rest} so the adapter can bound accumulation
%%   WHILE READING (the hostile-text read cap — truncation after
%%   receipt would not bound allocation).
%%
%% Every entry point is exception-guarded: a dead port (child exited)
%% must degrade to a result the adapter can turn into an honest tool
%% error, never crash its caller.
-module(nexus_mcp_ffi).

-export([open_port/3, send_line/2, take_lines/1]).

-include_lib("kernel/include/file.hrl").

open_port(Command, Args, Env) ->
    try
        Port =
            erlang:open_port({spawn_executable,
                              resolve_command(unicode:characters_to_list(Command))},
                             [use_stdio,
                              binary,
                              exit_status,
                              hide,
                              {args,
                               [unicode:characters_to_list(A) || A <- Args]},
                              {env,
                               [{unicode:characters_to_list(K),
                                 unicode:characters_to_list(V)}
                                || {K, V} <- Env]}]),
        {ok, Port}
    catch
        _:_ -> {error, <<"spawn failed">>}
    end.

%% spawn_executable does NOT search PATH for a bare name, and real-world
%% MCP configs say `npx`, `uvx`, `mcp-server-...` — resolve a slash-free
%% command against the inherited PATH like a shell would (first hit wins;
%% no hit passes the bare name through, letting open_port fail as
%% loudly as before).
resolve_command(Cmd) ->
    case lists:member($/, Cmd) of
        true ->
            Cmd;
        false ->
            Path = os:getenv("PATH", "/usr/local/bin:/usr/bin:/bin"),
            Dirs = string:split(Path, ":", all),
            Hit =
                lists:search(
                    fun(D) -> executable(filename:join(D, Cmd)) end,
                    Dirs
                ),
            case Hit of
                {value, D} -> filename:join(D, Cmd);
                false -> Cmd
            end
    end.

%% A PATH hit must be a REGULAR FILE with at least one execute bit set —
%% filelib:is_file/1 also matches directories and non-executable files,
%% and either would shadow a valid command later in the PATH.
executable(F) ->
    case file:read_file_info(F) of
        {ok, Info} ->
            Info#file_info.type =:= regular
            andalso (Info#file_info.mode band 8#111) =/= 0;
        _ ->
            false
    end.

%% port_command/2 with no options SUSPENDS the caller while the port
%% is busy — a server that stopped reading stdin would freeze the whole
%% adapter actor (no ListTools answers, no sibling calls, forever).
%% The nosuspend variant returns `false` instead of suspending, so a
%% wedged child degrades this one send into an honest error.
send_line(Port, Line) ->
    try
        case erlang:port_command(Port, [Line, $\n], [nosuspend]) of
            true -> {ok, nil};
            false -> {error, <<"server stdin is busy">>}
        end
    catch
        _:_ -> {error, <<"port dead">>}
    end.

%% Split complete newline-terminated frames off the head of the
%% buffer; the tail (no trailing newline yet) is the new buffer.
take_lines(Bin) ->
    Parts = binary:split(Bin, <<"\n">>, [global]),
    split_last(Parts, []).

split_last([Rest], Acc) ->
    {lists:reverse(Acc), Rest};
split_last([Line | More], Acc) ->
    split_last(More, [Line | Acc]);
split_last([], Acc) ->
    {lists:reverse(Acc), <<>>}.
