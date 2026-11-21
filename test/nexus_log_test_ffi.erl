-module(nexus_log_test_ffi).

-export([
    format_nexus_event/5,
    format_string_event/3,
    format_io_event/3,
    format_report_event/3,
    format_large_fallback_event/1,
    capture_with_level/2,
    log/2
]).

format_nexus_event(TimeUs, Level, Component, Msg, Fields) ->
    Event = #{
        level => Level,
        msg => {report, #{
            nexus_log => true,
            component => Component,
            msg => Msg,
            fields => Fields
        }},
        meta => #{time => TimeUs}
    },
    unicode:characters_to_binary(nexus_log_ffi:format(Event, #{})).

format_string_event(TimeUs, Level, Text) ->
    Event = #{
        level => Level,
        msg => {string, Text},
        meta => #{time => TimeUs}
    },
    unicode:characters_to_binary(nexus_log_ffi:format(Event, #{})).

format_io_event(TimeUs, Level, Arg) ->
    Event = #{
        level => Level,
        msg => {"hello ~s\nline2", [Arg]},
        meta => #{time => TimeUs, domain => [otp, sasl]}
    },
    unicode:characters_to_binary(nexus_log_ffi:format(Event, #{})).

format_report_event(TimeUs, Level, Reason) ->
    Event = #{
        level => Level,
        msg => {report, #{reason => Reason}},
        meta => #{
            time => TimeUs,
            domain => [otp],
            report_cb => fun(#{reason := R}, _Cfg) ->
                io_lib:format("crash reason: ~s\nstack", [R])
            end
        }
    },
    unicode:characters_to_binary(nexus_log_ffi:format(Event, #{})).

format_large_fallback_event(TimeUs) ->
    Big = #{payload => lists:duplicate(20000, $x)},
    Event = #{
        level => error,
        msg => {report, Big},
        meta => #{time => TimeUs, domain => [otp]}
    },
    unicode:characters_to_binary(nexus_log_ffi:format(Event, #{})).

%% Temporarily attach a capturing :logger handler using nexus_log_ffi as its
%% formatter, run Fun() under the requested primary level, and restore the
%% original primary level before returning the formatted lines. Filters to
%% `component=test` so unrelated concurrent OTP logs on the node cannot make
%% the test flaky.
capture_with_level(Level, Fun) ->
    #{level := PrevLevel} = logger:get_primary_config(),
    Self = self(),
    Id = list_to_atom("nexus_log_test_" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = logger:add_handler(Id, ?MODULE, #{
        level => all,
        formatter => {nexus_log_ffi, #{}},
        config => #{owner => Self}
    }),
    try
        nexus_log_ffi:set_level(Level),
        Fun(),
        [L || L <- drain([]), binary:match(L, <<"component=test ">>) =/= nomatch]
    after
        _ = logger:remove_handler(Id),
        _ = logger:set_primary_config(level, PrevLevel)
    end.

log(LogEvent, #{formatter := {FMod, FConfig}, config := #{owner := Owner}}) ->
    Line = unicode:characters_to_binary(FMod:format(LogEvent, FConfig)),
    Owner ! {captured_log, Line},
    ok.

drain(Acc) ->
    receive
        {captured_log, Line} -> drain([Line | Acc])
    after 0 ->
        lists:reverse(Acc)
    end.
