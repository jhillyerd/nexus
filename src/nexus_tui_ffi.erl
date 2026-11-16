%% The node TUI's stdin line reader (environments plan Phase 2b-5).
%%
%% io:get_line on the group leader is the BEAM's REPL primitive: on a
%% TTY the terminal driver handles character erase and line editing,
%% and on a pipe (the e2e suite drives the TUI with piped stdin) it
%% reads lines verbatim. Returns {error, nil} on EOF so the Gleam side
%% can model end-of-input as a Result and leave cleanly.
-module(nexus_tui_ffi).
-export([get_line/1]).

get_line(Prompt) ->
    case io:get_line(Prompt) of
        eof -> {error, nil};
        % A dead group leader (e.g. stdout gone mid-run) yields
        % {error, Reason}; map ANY error to the Gleam-side EOF shape so
        % stdin_loop leaves cleanly instead of type-lying about a
        % tuple being a String.
        {error, _} -> {error, nil};
        % io:get_line returns a CHARLIST (codepoint list) on a TTY and
        % a binary on pipes — normalize both to a Gleam String (UTF-8
        % binary); passing a charlist through typed as String crashed
        % string.trim/JSON encoding on interactive input (cubic PR
        % review).
        Line -> {ok, unicode:characters_to_binary(Line)}
    end.
