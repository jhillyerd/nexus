-module(nexus_log_ffi).

-export([
    configure/1,
    set_level/1,
    emit/4,
    format/2,
    check_config/1,
    report_cb/2
]).

configure(Level) ->
    ok = logger:set_primary_config(level, erl_level(Level)),
    %% sync_mode_qlen => 0 keeps default handler writes synchronous so fatal
    %% boot logs cannot race ahead of erlang:halt/1 and vanish.
    ok = logger:update_handler_config(default, #{
        level => all,
        formatter => {?MODULE, #{}},
        config => #{sync_mode_qlen => 0}
    }),
    nil.

set_level(Level) ->
    ok = logger:set_primary_config(level, erl_level(Level)),
    nil.

emit(Level, Component, Msg, Fields) ->
    logger:log(
        erl_level(Level),
        #{
            nexus_log => true,
            component => Component,
            msg => Msg,
            fields => Fields
        },
        #{report_cb => fun ?MODULE:report_cb/2}
    ),
    nil.

check_config(_Config) ->
    ok.

%% Fallback OTP report_cb when a log fires before configure/1 (e.g. during
%% `gleam test`), so OTP's default formatter prints a readable one-liner
%% instead of a raw Erlang map dump.
report_cb(#{nexus_log := true, component := Component, msg := Msg, fields := Fields}, _Config) ->
    nexus@log:format_body(Component, Msg, Fields);
report_cb(Other, _Config) ->
    fallback_term(Other).

%% Erlang :logger formatter callback. Converts both nexus/log reports and
%% external OTP / mist / glisten / stratus logs into single-line logfmt.
format(#{level := Level, msg := Msg, meta := Meta}, _Config) ->
    TimeUs = maps:get(time, Meta, erlang:system_time(microsecond)),
    TsBin = to_binary(
        calendar:system_time_to_rfc3339(
            TimeUs div 1000,
            [{unit, millisecond}, {offset, "Z"}]
        )
    ),
    LevelBin = level_to_bin(Level),
    {Component, MsgBin, Fields} = extract(Msg, Meta),
    Line = nexus@log:format_line(TsBin, LevelBin, Component, MsgBin, Fields),
    [Line, $\n].

extract({report, #{nexus_log := true, component := Component, msg := Text, fields := Fields}}, _Meta) ->
    {Component, Text, Fields};
extract({string, Chardata}, Meta) ->
    {external_component(Meta), to_binary(Chardata), []};
extract({Format, Args}, Meta) when is_list(Format); is_binary(Format) ->
    {external_component(Meta), format_io(Format, Args), []};
extract({report, Report}, Meta) ->
    {external_component(Meta), format_report(Report, Meta), []};
extract(Other, Meta) ->
    {external_component(Meta), fallback_term(Other), []}.

external_component(Meta) ->
    case maps:get(domain, Meta, []) of
        [otp | _] -> <<"otp">>;
        [First | _] when is_atom(First) -> atom_to_binary(First, utf8);
        _ -> <<"beam">>
    end.

format_report(Report, Meta) ->
    case maps:get(report_cb, Meta, undefined) of
        Fun when is_function(Fun, 2) ->
            try
                to_binary(Fun(Report, #{depth => 20, chars_limit => 4096, single_line => true}))
            catch
                _:_ -> fallback_term(Report)
            end;
        Fun when is_function(Fun, 1) ->
            try
                {Format, Args} = Fun(Report),
                format_io(Format, Args)
            catch
                _:_ -> fallback_term(Report)
            end;
        _ ->
            fallback_term(Report)
    end.

format_io(Format, Args) ->
    try
        to_binary(io_lib:format(Format, Args, [{chars_limit, 4096}]))
    catch
        _:_ -> fallback_term({Format, Args})
    end.

fallback_term(Term) ->
    to_binary(io_lib:format("~0P", [Term, 20], [{chars_limit, 4096}])).

to_binary(Data) when is_binary(Data) ->
    Data;
to_binary(Data) ->
    case unicode:characters_to_binary(Data) of
        Bin when is_binary(Bin) -> Bin;
        {incomplete, Bin, _} -> Bin;
        {error, Bin, _} -> Bin
    end.

erl_level(debug) -> debug;
erl_level(info) -> info;
erl_level(warn) -> warning;
erl_level(error) -> error.

level_to_bin(debug) -> <<"debug">>;
level_to_bin(info) -> <<"info">>;
level_to_bin(notice) -> <<"notice">>;
level_to_bin(warning) -> <<"warn">>;
level_to_bin(error) -> <<"error">>;
level_to_bin(critical) -> <<"critical">>;
level_to_bin(alert) -> <<"alert">>;
level_to_bin(emergency) -> <<"emergency">>;
level_to_bin(Other) when is_atom(Other) -> atom_to_binary(Other, utf8).
