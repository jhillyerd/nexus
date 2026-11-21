//// Structured `logfmt` logging over Erlang's built-in `:logger`.
////
//// Every server log line is single-line `logfmt`, human-readable in a
//// terminal or container log and directly parseable by Grafana Loki's
//// `| logfmt` stage:
////
////     time=2026-11-21T21:18:02.123Z level=info component=boot msg=listening bind=127.0.0.1 port=8080
////
//// Calling `configure(level)` at boot installs `nexus_log_ffi` as the
//// formatter on Erlang `:logger`'s `default` handler and sets the primary
//// log level. Because `mist`, `glisten`, `stratus`, and OTP supervisors all
//// log through `:logger`, their output and crash reports share the same
//// level filter and single-line `logfmt` format.
////
//// Leaf module: imports only `gleam_stdlib` so any module (including
//// `nexus/config`) can import it without dependency cycles.
////
//// Security invariant: never pass secrets (`NEXUS_ENCRYPTION_KEY`, provider
//// API keys, `NEXUS_UI_TOKEN`, `NEXUS_SEARXNG_TOKEN`, `NEXUS_PG_PASSWORD`,
//// node tokens, pairing codes) as messages or field values.

import gleam
import gleam/float
import gleam/int
import gleam/list
import gleam/string

/// Log severity levels exposed by nexus (configured via `NEXUS_LOG_LEVEL`).
pub type Level {
  Debug
  Info
  Warn
  Error
}

/// One structured `key=value` field attached to a log event.
pub type Field {
  Field(key: String, value: String)
}

/// String field.
pub fn str(key: String, value: String) -> Field {
  Field(key: key, value: value)
}

/// Integer field.
pub fn int(key: String, value: Int) -> Field {
  Field(key: key, value: int.to_string(value))
}

/// Float field.
pub fn float(key: String, value: Float) -> Field {
  Field(key: key, value: float.to_string(value))
}

/// Boolean field (`true` / `false`).
pub fn bool(key: String, value: Bool) -> Field {
  Field(key: key, value: case value {
    True -> "true"
    False -> "false"
  })
}

/// Parse a `NEXUS_LOG_LEVEL` value (case-insensitive, whitespace-trimmed).
pub fn parse_level(raw: String) -> Result(Level, String) {
  case string.lowercase(string.trim(raw)) {
    "debug" -> Ok(Debug)
    "info" -> Ok(Info)
    "warn" | "warning" -> Ok(Warn)
    "error" -> Ok(Error)
    _ -> gleam.Error("must be one of: debug, info, warn, error")
  }
}

/// Canonical lowercase logfmt representation of a `Level`.
pub fn level_to_string(level: Level) -> String {
  case level {
    Debug -> "debug"
    Info -> "info"
    Warn -> "warn"
    Error -> "error"
  }
}

/// Configure Erlang `:logger`'s `default` handler with the `logfmt`
/// formatter and set the primary log level. Call once at server boot.
@external(erlang, "nexus_log_ffi", "configure")
pub fn configure(level: Level) -> Nil

/// Update Erlang `:logger`'s primary log level.
@external(erlang, "nexus_log_ffi", "set_level")
pub fn set_level(level: Level) -> Nil

/// Emit a structured log event at `level`.
@external(erlang, "nexus_log_ffi", "emit")
pub fn log(
  level: Level,
  component: String,
  msg: String,
  fields: List(Field),
) -> Nil

/// Emit a `debug`-level structured log event.
pub fn debug(component: String, msg: String, fields: List(Field)) -> Nil {
  log(Debug, component, msg, fields)
}

/// Emit an `info`-level structured log event.
pub fn info(component: String, msg: String, fields: List(Field)) -> Nil {
  log(Info, component, msg, fields)
}

/// Emit a `warn`-level structured log event.
pub fn warn(component: String, msg: String, fields: List(Field)) -> Nil {
  log(Warn, component, msg, fields)
}

/// Emit an `error`-level structured log event.
pub fn error(component: String, msg: String, fields: List(Field)) -> Nil {
  log(Error, component, msg, fields)
}

// ---------------------------------------------------------------------------
// Pure logfmt formatting (shared with `nexus_log_ffi.erl` and unit tests)
// ---------------------------------------------------------------------------

/// Format a complete single-line `logfmt` entry (without trailing newline).
pub fn format_line(
  timestamp: String,
  level: String,
  component: String,
  msg: String,
  fields: List(Field),
) -> String {
  "time="
  <> format_value(timestamp)
  <> " level="
  <> format_value(level)
  <> " "
  <> format_body(component, msg, fields)
}

/// Format `component=... msg=...` and any extra fields (also used by the
/// OTP `report_cb` fallback when `configure` has not been called). Duplicate
/// sanitized keys (including collisions with reserved prefixes like
/// `field_time`) are disambiguated with `_2`, `_3`, … so downstream logfmt
/// parsers preserve every value.
pub fn format_body(
  component: String,
  msg: String,
  fields: List(Field),
) -> String {
  let head =
    "component=" <> format_value(component) <> " msg=" <> format_value(msg)
  case fields {
    [] -> head
    _ -> {
      let #(pairs, _seen) =
        list.fold(fields, #([], []), fn(acc, field) {
          let #(pairs, seen) = acc
          let key = unique_key(safe_field_key(field.key), seen)
          let pair = key <> "=" <> format_value(field.value)
          #([pair, ..pairs], [key, ..seen])
        })
      head <> " " <> string.join(list.reverse(pairs), " ")
    }
  }
}

/// Sanitize a logfmt key to `[a-zA-Z0-9_.-]+`, falling back to `"field"`.
pub fn sanitize_key(key: String) -> String {
  let cleaned =
    key
    |> string.to_utf_codepoints
    |> list.map(fn(cp) {
      let n = string.utf_codepoint_to_int(cp)
      case is_key_char(n) {
        True -> string.from_utf_codepoints([cp])
        False -> "_"
      }
    })
    |> string.concat
  case cleaned {
    "" -> "field"
    _ -> cleaned
  }
}

/// Maximum number of Unicode codepoints kept per `msg` or field value before
/// truncating with `"..."` (bounded prior to quoting/escaping so logfmt output
/// always stays valid and single-line).
pub const max_value_chars = 4096

/// Encode one logfmt value. Bare when safe; double-quoted with standard
/// escapes when empty or containing whitespace, quotes, `=`, `\`, or control /
/// line-separator characters. Values longer than `max_value_chars` codepoints
/// are truncated with `"..."` before escaping. Output is strictly single-line.
pub fn format_value(value: String) -> String {
  case value {
    "" -> "\"\""
    _ -> {
      let #(bounded, cps) = bound_codepoints(value)
      case list.any(cps, needs_quoting) {
        False -> bounded
        True -> "\"" <> string.concat(list.map(cps, escape_codepoint)) <> "\""
      }
    }
  }
}

fn bound_codepoints(value: String) -> #(String, List(UtfCodepoint)) {
  // Fast path: every UTF-8 codepoint is >= 1 byte, so <= max_value_chars bytes
  // guarantees <= max_value_chars codepoints with no truncation needed.
  case string.byte_size(value) <= max_value_chars {
    True -> #(value, string.to_utf_codepoints(value))
    False -> {
      let cps = string.to_utf_codepoints(value)
      case take_if_over(cps, max_value_chars, []) {
        Ok(kept) -> {
          let truncated = string.from_utf_codepoints(kept) <> "..."
          #(truncated, string.to_utf_codepoints(truncated))
        }
        gleam.Error(Nil) -> #(value, cps)
      }
    }
  }
}

fn take_if_over(
  cps: List(UtfCodepoint),
  remaining: Int,
  acc: List(UtfCodepoint),
) -> Result(List(UtfCodepoint), Nil) {
  case remaining, cps {
    0, [] -> gleam.Error(Nil)
    0, [_, ..] -> Ok(list.reverse(acc))
    _, [] -> gleam.Error(Nil)
    _, [head, ..tail] -> take_if_over(tail, remaining - 1, [head, ..acc])
  }
}

fn safe_field_key(key: String) -> String {
  let clean = sanitize_key(key)
  case clean {
    "time" | "level" | "component" | "msg" -> "field_" <> clean
    _ -> clean
  }
}

fn unique_key(base: String, seen: List(String)) -> String {
  case list.contains(seen, base) {
    False -> base
    True -> unique_key_suffix(base, 2, seen)
  }
}

fn unique_key_suffix(base: String, n: Int, seen: List(String)) -> String {
  let candidate = base <> "_" <> int.to_string(n)
  case list.contains(seen, candidate) {
    False -> candidate
    True -> unique_key_suffix(base, n + 1, seen)
  }
}

fn is_key_char(n: Int) -> Bool {
  { n >= 0x30 && n <= 0x39 }
  || { n >= 0x41 && n <= 0x5A }
  || { n >= 0x61 && n <= 0x7A }
  || n == 0x5F
  || n == 0x2D
  || n == 0x2E
}

fn is_control_or_line_sep(n: Int) -> Bool {
  n < 0x20
  || n == 0x7F
  || { n >= 0x80 && n <= 0x9F }
  || n == 0x2028
  || n == 0x2029
}

fn needs_quoting(cp: UtfCodepoint) -> Bool {
  let n = string.utf_codepoint_to_int(cp)
  n == 0x20 || n == 0x22 || n == 0x3D || n == 0x5C || is_control_or_line_sep(n)
}

fn escape_codepoint(cp: UtfCodepoint) -> String {
  let n = string.utf_codepoint_to_int(cp)
  case n {
    0x22 -> "\\\""
    0x5C -> "\\\\"
    0x0A -> "\\n"
    0x0D -> "\\r"
    0x09 -> "\\t"
    _ ->
      case is_control_or_line_sep(n) {
        True -> hex_u4(n)
        False -> string.from_utf_codepoints([cp])
      }
  }
}

fn hex_u4(n: Int) -> String {
  let hex = string.lowercase(int.to_base16(n))
  case string.length(hex) {
    1 -> "\\u000" <> hex
    2 -> "\\u00" <> hex
    3 -> "\\u0" <> hex
    _ -> "\\u" <> hex
  }
}
