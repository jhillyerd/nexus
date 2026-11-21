import gleam/list
import gleam/string
import gleeunit/should
import nexus/log

@external(erlang, "nexus_log_test_ffi", "format_nexus_event")
fn format_nexus_event(
  time_us: Int,
  level: log.Level,
  component: String,
  msg: String,
  fields: List(log.Field),
) -> String

@external(erlang, "nexus_log_test_ffi", "format_string_event")
fn format_string_event(time_us: Int, level: log.Level, text: String) -> String

@external(erlang, "nexus_log_test_ffi", "format_io_event")
fn format_io_event(time_us: Int, level: log.Level, arg: String) -> String

@external(erlang, "nexus_log_test_ffi", "format_report_event")
fn format_report_event(time_us: Int, level: log.Level, reason: String) -> String

@external(erlang, "nexus_log_test_ffi", "format_large_fallback_event")
fn format_large_fallback_event(time_us: Int) -> String

@external(erlang, "nexus_log_test_ffi", "format_large_report_cb_event")
fn format_large_report_cb_event(time_us: Int) -> String

@external(erlang, "nexus_log_test_ffi", "capture_with_level")
fn capture_with_level(level: log.Level, run: fn() -> Nil) -> List(String)

// 2026-11-21T21:18:02.123Z in microseconds.
const fixed_time_us = 1_795_295_882_123_456

pub fn parse_level_test() {
  log.parse_level("debug") |> should.equal(Ok(log.Debug))
  log.parse_level("info") |> should.equal(Ok(log.Info))
  log.parse_level("warn") |> should.equal(Ok(log.Warn))
  log.parse_level("warning") |> should.equal(Ok(log.Warn))
  log.parse_level("error") |> should.equal(Ok(log.Error))
  log.parse_level("  WARN ") |> should.equal(Ok(log.Warn))
  log.parse_level("DeBuG") |> should.equal(Ok(log.Debug))
  should.be_error(log.parse_level(""))
  should.be_error(log.parse_level("trace"))
  should.be_error(log.parse_level("verbose"))
}

pub fn level_to_string_test() {
  log.level_to_string(log.Debug) |> should.equal("debug")
  log.level_to_string(log.Info) |> should.equal("info")
  log.level_to_string(log.Warn) |> should.equal("warn")
  log.level_to_string(log.Error) |> should.equal("error")
}

pub fn format_value_bare_tokens_test() {
  log.format_value("info") |> should.equal("info")
  log.format_value("127.0.0.1") |> should.equal("127.0.0.1")
  log.format_value("8080") |> should.equal("8080")
  log.format_value("foo-bar_baz.1") |> should.equal("foo-bar_baz.1")
  log.format_value("café") |> should.equal("café")
}

pub fn format_value_quoting_and_escaping_test() {
  log.format_value("") |> should.equal("\"\"")
  log.format_value("hello world") |> should.equal("\"hello world\"")
  log.format_value("a=b") |> should.equal("\"a=b\"")
  log.format_value("say \"hi\"") |> should.equal("\"say \\\"hi\\\"\"")
  log.format_value("a\\b") |> should.equal("\"a\\\\b\"")
  log.format_value("line1\nline2\r\tend")
  |> should.equal("\"line1\\nline2\\r\\tend\"")
  log.format_value("\u{0000}\u{001b}\u{007f}")
  |> should.equal("\"\\u0000\\u001b\\u007f\"")
  log.format_value("a\u{0085}b\u{2028}c\u{2029}d")
  |> should.equal("\"a\\u0085b\\u2028c\\u2029d\"")
}

pub fn sanitize_key_test() {
  log.sanitize_key("thread_id") |> should.equal("thread_id")
  log.sanitize_key("http.status-code") |> should.equal("http.status-code")
  log.sanitize_key("bad key=1\"x") |> should.equal("bad_key_1_x")
  log.sanitize_key("") |> should.equal("field")
}

pub fn format_line_header_and_typed_fields_test() {
  let line =
    log.format_line("2026-11-21T21:18:02.123Z", "info", "boot", "listening", [
      log.str("bind", "127.0.0.1"),
      log.int("port", 8080),
      log.bool("auth", True),
      log.float("ratio", 0.5),
    ])
  line
  |> should.equal(
    "time=2026-11-21T21:18:02.123Z level=info component=boot msg=listening"
    <> " bind=127.0.0.1 port=8080 auth=true ratio=0.5",
  )
}

pub fn format_line_prefixes_reserved_field_keys_test() {
  let line =
    log.format_line("2026-11-21T21:18:02.123Z", "warn", "store", "oops", [
      log.str("time", "t"),
      log.str("level", "l"),
      log.str("component", "c"),
      log.str("msg", "m"),
    ])
  line
  |> should.equal(
    "time=2026-11-21T21:18:02.123Z level=warn component=store msg=oops"
    <> " field_time=t field_level=l field_component=c field_msg=m",
  )
}

pub fn format_line_dedupes_colliding_field_keys_test() {
  let line =
    log.format_line("2026-11-21T21:18:02.123Z", "info", "store", "dedupe", [
      log.str("a b", "1"),
      log.str("a/b", "2"),
      log.str("a_b", "3"),
      log.str("time", "t1"),
      log.str("field_time", "t2"),
    ])
  line
  |> should.equal(
    "time=2026-11-21T21:18:02.123Z level=info component=store msg=dedupe"
    <> " a_b=1 a_b_2=2 a_b_3=3 field_time=t1 field_time_2=t2",
  )
}

pub fn format_value_caps_oversized_values_preserving_logfmt_test() {
  let huge_bare = string.repeat("a", 5000)
  let formatted_bare = log.format_value(huge_bare)
  string.length(formatted_bare) |> should.equal(log.max_value_chars + 3)
  should.be_true(string.ends_with(formatted_bare, "..."))

  // Oversized string with quotes/spaces stays validly quoted & escaped.
  let huge_quoted = "hello \"" <> string.repeat("b", 5000) <> "\""
  let formatted_quoted = log.format_value(huge_quoted)
  should.be_true(string.starts_with(formatted_quoted, "\"hello \\\""))
  should.be_true(string.ends_with(formatted_quoted, "...\""))
}

pub fn format_line_is_strictly_single_line_test() {
  let line =
    log.format_line("2026-11-21T21:18:02.123Z", "error", "mcp", "line1\nline2", [
      log.str("reason", "bad\r\nframe"),
    ])
  should.be_false(string.contains(line, "\n"))
  should.be_false(string.contains(line, "\r"))
  should.be_true(string.contains(line, "msg=\"line1\\nline2\""))
  should.be_true(string.contains(line, "reason=\"bad\\r\\nframe\""))
}

pub fn erl_formatter_handles_nexus_and_otp_events_test() {
  let nexus_line =
    format_nexus_event(fixed_time_us, log.Info, "store", "boot sweep", [
      log.int("deleted", 3),
    ])
  nexus_line
  |> should.equal(
    "time=2026-11-21T21:18:02.123Z level=info component=store"
    <> " msg=\"boot sweep\" deleted=3\n",
  )

  // External string log (e.g. mist / glisten / stratus via lpil/logging).
  let str_line = format_string_event(fixed_time_us, log.Error, "socket closed")
  str_line
  |> should.equal(
    "time=2026-11-21T21:18:02.123Z level=error component=beam"
    <> " msg=\"socket closed\"\n",
  )

  // Format-args log from an OTP library with domain [otp, sasl].
  let io_line = format_io_event(fixed_time_us, log.Info, "world")
  io_line
  |> should.equal(
    "time=2026-11-21T21:18:02.123Z level=info component=otp"
    <> " msg=\"hello world\\nline2\"\n",
  )

  // Structured OTP report with report_cb flattens to single-line logfmt.
  let report_line = format_report_event(fixed_time_us, log.Error, "killed")
  report_line
  |> should.equal(
    "time=2026-11-21T21:18:02.123Z level=error component=otp"
    <> " msg=\"crash reason: killed\\nstack\"\n",
  )

  // Oversized fallback reports are bounded during formatting.
  let large_line = format_large_fallback_event(fixed_time_us)
  should.be_true(string.byte_size(large_line) < 5000)
  should.be_true(string.starts_with(
    large_line,
    "time=2026-11-21T21:18:02.123Z level=error component=otp msg=",
  ))

  // An arity-2 report_cb that ignores chars_limit is still capped.
  let large_cb_line = format_large_report_cb_event(fixed_time_us)
  should.be_true(string.byte_size(large_cb_line) < 4250)
  should.be_true(string.ends_with(large_cb_line, "...\n"))
}

pub fn logger_pipeline_respects_level_filter_test() {
  let lines =
    capture_with_level(log.Warn, fn() {
      log.debug("test", "hidden debug", [])
      log.info("test", "hidden info", [])
      log.warn("test", "visible warn", [log.int("n", 1)])
      log.error("test", "visible error", [log.str("why", "disk full")])
    })
  list.length(lines) |> should.equal(2)
  let assert [first, second] = lines
  should.be_true(string.contains(
    first,
    "level=warn component=test msg=\"visible warn\" n=1\n",
  ))
  should.be_true(string.contains(
    second,
    "level=error component=test msg=\"visible error\" why=\"disk full\"\n",
  ))
}
