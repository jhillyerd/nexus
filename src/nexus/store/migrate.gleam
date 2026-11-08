//// Schema migration runner: applies `sql/schema.sql` to the database in
//// `DATABASE_URL` (the same convention squirrel uses).
////
//// This runner is the only schema-apply path: the compose file has no
//// schema bind mount (its config must stay identical from every
//// checkout/worktree, so `up` never recreates the singleton db on a
//// worktree switch). Apply after boot; re-apply after schema changes
//// and for the CI service container:
////
////     DATABASE_URL=postgres://nexus@127.0.0.1:5433/nexus \
////       gleam run -m nexus/store/migrate
////   # (etc/dev-server.sh runs this on every dev boot)
////
//// The schema is written idempotently (`create table if not exists`), so
//// re-running is safe. Statements are split by a quote-aware scanner
//// (`statements`), so `;` inside string literals, double-quoted
//// identifiers, dollar-quoted bodies (`CREATE FUNCTION` / `DO`), and
//// comments do not break a statement apart.

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/string
import pog

@external(erlang, "nexus_store_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "nexus_store_ffi", "database_url")
fn database_url() -> Result(String, Nil)

// Hold the VM until the pog pool's type server is ready, so the halt's
// teardown no longer races the connection_starter's boot-time type-server
// call (intermittent pgo_pool_sup shutdown_error report); see
// nexus_store_ffi:stop_pool/1. pog.start hands back the pool's queue
// gen_server.
@external(erlang, "nexus_store_ffi", "stop_pool")
fn stop_pool(queue: process.Pid) -> Nil

pub fn main() -> Nil {
  let schema =
    or_panic(read_file("sql/schema.sql"), "cannot read sql/schema.sql")
  let url = or_panic(database_url(), "DATABASE_URL is not set")
  let config =
    or_panic(
      pog.url_config(process.new_name("nexus_migrate"), url),
      "invalid DATABASE_URL",
    )
  let started =
    or_panic(
      pog.start(pog.connection_parameter(config, "timezone", "UTC")),
      "could not connect — is the database up?",
    )
  let db = started.data
  let stmts = statements(schema)
  case stmts {
    [] -> io.println("migrate: schema file contains no statements (?)")
    _ ->
      list.each(stmts, fn(statement) {
        case
          statement
          |> pog.query
          |> pog.returning(decode.dynamic)
          |> pog.execute(db)
        {
          Ok(_) -> io.println("migrate: applied: " <> summarize(statement))
          Error(error) -> {
            io.println(
              "migrate: FAILED: "
              <> summarize(statement)
              <> " — "
              <> string.inspect(error),
            )
            panic as "migrate: statement failed"
          }
        }
      })
  }
  io.println(
    "migrate: done (" <> int.to_string(list.length(stmts)) <> " statements)",
  )
  stop_pool(started.pid)
}

fn or_panic(result: Result(a, e), message: String) -> a {
  case result {
    Ok(value) -> value
    Error(reason) -> {
      io.println("migrate: " <> message <> " — " <> string.inspect(reason))
      panic as "migrate failed"
    }
  }
}

/// Split a schema script into individual SQL statements on top-level
/// semicolons.
///
/// The scan is quote-aware: a `;` inside a single-quoted literal, a
/// double-quoted identifier, or a dollar-quoted body (`$$...$$`,
/// `$tag$...$tag$`) belongs to the statement, not the separator. This is
/// what lets `CREATE FUNCTION ... $$ ... ; ... $$`, `DO $$ ... $$`, and
/// literals containing `;` survive. `--` line comments and nestable
/// `/* ... */` block comments are stripped too, so a `;` in a comment is
/// inert.
///
/// The script is scanned by Unicode codepoint (not grapheme cluster), so
/// CRLF line endings and non-ASCII dollar-quote tags are handled correctly.
/// A `$` that continues an unquoted identifier (`audit$log$`) is not a
/// dollar-quote opener. An unterminated block comment keeps its `/*` marker
/// so PostgreSQL rejects the statement instead of silently applying a
/// truncated one.
///
/// Escaped quotes (`''` and `""`) are understood. Escape-string literals
/// (`E'...'`) and Unicode escape strings (`U&'...'`) are recognized: a
/// backslash inside them escapes the following character, so `\'` does not
/// end the literal. A backslash in an ordinary single-quoted literal stays
/// literal (PostgreSQL's default `standard_conforming_strings`).
pub fn statements(schema: String) -> List(String) {
  let chars =
    schema
    |> string.to_utf_codepoints
    |> list.map(string.utf_codepoint_to_int)
  scan_code(chars, [], []) |> list.reverse
}

// Codepoints used throughout the scanner: `"`=34, `&`=38, `$`=36, `'`=39,
// `*`=42, `-`=45, `/`=47, `;`=59, `E`=69, `U`=85, `\`=92, `e`=101,
// `u`=117, space=32, `\n`=10, `\r`=13, `_`=95.

fn scan_code(
  chars: List(Int),
  current: List(Int),
  done: List(String),
) -> List(String) {
  case chars {
    [] -> finish(current, done)
    [45, 45, ..rest] -> scan_line_comment(rest, current, done)
    [47, 42, ..rest] -> scan_block_comment(1, rest, current, done)
    [39, ..rest] ->
      case is_escape_string_prefix(current) {
        True -> scan_escape_string(rest, [39, ..current], done)
        False -> scan_single(rest, [39, ..current], done)
      }
    [34, ..rest] -> scan_double(rest, [34, ..current], done)
    [59, ..rest] -> scan_code(rest, [], finish(current, done))
    [36, ..rest] ->
      case current {
        [previous, ..] ->
          case is_ident_continue(previous) {
            True -> scan_code(rest, [36, ..current], done)
            False -> try_dollar(rest, current, done)
          }
        [] -> try_dollar(rest, current, done)
      }
    [char, ..rest] -> scan_code(rest, [char, ..current], done)
  }
}

fn scan_single(
  chars: List(Int),
  current: List(Int),
  done: List(String),
) -> List(String) {
  case chars {
    [] -> finish(current, done)
    [39, 39, ..rest] -> scan_single(rest, [39, 39, ..current], done)
    [39, ..rest] -> scan_code(rest, [39, ..current], done)
    [char, ..rest] -> scan_single(rest, [char, ..current], done)
  }
}

fn scan_double(
  chars: List(Int),
  current: List(Int),
  done: List(String),
) -> List(String) {
  case chars {
    [] -> finish(current, done)
    [34, 34, ..rest] -> scan_double(rest, [34, 34, ..current], done)
    [34, ..rest] -> scan_code(rest, [34, ..current], done)
    [char, ..rest] -> scan_double(rest, [char, ..current], done)
  }
}

/// Consume an escape-string body (`E'...'` or `U&'...'`), where a backslash
/// escapes the following character and `''` is an escaped quote.
fn scan_escape_string(
  chars: List(Int),
  current: List(Int),
  done: List(String),
) -> List(String) {
  case chars {
    [] -> finish(current, done)
    [92, escaped, ..rest] ->
      scan_escape_string(rest, [escaped, 92, ..current], done)
    [39, 39, ..rest] -> scan_escape_string(rest, [39, 39, ..current], done)
    [39, ..rest] -> scan_code(rest, [39, ..current], done)
    [char, ..rest] -> scan_escape_string(rest, [char, ..current], done)
  }
}

/// True when the text just emitted ends with an `E'` or `U&'` prefix at a
/// token boundary, i.e. the quote opens an escape string rather than a plain
/// literal. An `E`/`U` that ends an identifier (`date'...'`) does not count.
fn is_escape_string_prefix(current: List(Int)) -> Bool {
  case current {
    [38, u, ..before] ->
      case u == 85 || u == 117 {
        True -> not_after_identifier(before)
        False -> False
      }
    [e, ..before] ->
      case e == 69 || e == 101 {
        True -> not_after_identifier(before)
        False -> False
      }
    _ -> False
  }
}

fn not_after_identifier(before: List(Int)) -> Bool {
  case before {
    [previous, ..] -> !is_ident_continue(previous)
    [] -> True
  }
}

fn try_dollar(
  chars: List(Int),
  current: List(Int),
  done: List(String),
) -> List(String) {
  case parse_dollar(chars) {
    Ok(#(tag, after)) -> scan_dollar(tag, after, current, done)
    Error(_) -> scan_code(chars, [36, ..current], done)
  }
}

fn scan_dollar(
  tag: String,
  chars: List(Int),
  current: List(Int),
  done: List(String),
) -> List(String) {
  let tag_codes = to_codepoints(tag)
  let delimiter = list.append([36], list.append(tag_codes, [36]))
  let closing = list.append(tag_codes, [36])
  scan_dollar_body(closing, delimiter, chars, emit(delimiter, current), done)
}

fn scan_dollar_body(
  closing: List(Int),
  delimiter: List(Int),
  chars: List(Int),
  current: List(Int),
  done: List(String),
) -> List(String) {
  case chars {
    [] -> finish(current, done)
    [36, ..rest] ->
      case drop_prefix(rest, closing) {
        Ok(after) -> scan_code(after, emit(delimiter, current), done)
        Error(_) ->
          scan_dollar_body(closing, delimiter, rest, [36, ..current], done)
      }
    [char, ..rest] ->
      scan_dollar_body(closing, delimiter, rest, [char, ..current], done)
  }
}

fn scan_line_comment(
  chars: List(Int),
  current: List(Int),
  done: List(String),
) -> List(String) {
  case chars {
    [] -> finish(current, done)
    [10, ..rest] -> scan_code(rest, [10, ..current], done)
    [13, ..rest] -> scan_code(rest, [13, ..current], done)
    [_, ..rest] -> scan_line_comment(rest, current, done)
  }
}

fn scan_block_comment(
  depth: Int,
  chars: List(Int),
  current: List(Int),
  done: List(String),
) -> List(String) {
  case chars {
    // Unterminated: keep the opening marker so PostgreSQL errors on it
    // rather than silently applying a truncated statement.
    [] -> finish(emit([47, 42], current), done)
    [47, 42, ..rest] -> scan_block_comment(depth + 1, rest, current, done)
    [42, 47, ..rest] ->
      case depth {
        1 -> scan_code(rest, [32, ..current], done)
        _ -> scan_block_comment(depth - 1, rest, current, done)
      }
    [_, ..rest] -> scan_block_comment(depth, rest, current, done)
  }
}

/// Match a dollar-quote opener at `chars` (the text after the leading `$`)
/// and return its tag plus the text after the closing `$`.
fn parse_dollar(chars: List(Int)) -> Result(#(String, List(Int)), Nil) {
  case chars {
    [36, ..after] -> Ok(#("", after))
    _ -> parse_dollar_tag(chars, [])
  }
}

fn parse_dollar_tag(
  chars: List(Int),
  tag: List(Int),
) -> Result(#(String, List(Int)), Nil) {
  case chars {
    [] -> Error(Nil)
    [char, ..rest] ->
      case is_tag_char(char, tag) {
        True -> parse_dollar_tag(rest, [char, ..tag])
        False ->
          case char, tag {
            36, [] -> Error(Nil)
            36, _ -> Ok(#(codepoints_to_string(list.reverse(tag)), rest))
            _, _ -> Error(Nil)
          }
      }
  }
}

/// A dollar-quote tag is an empty string or an identifier: its first
/// character is a letter or `_`, later ones may also be digits. `$` itself
/// is not allowed in a tag.
fn is_tag_char(code: Int, tag: List(Int)) -> Bool {
  case tag {
    [] -> is_letter(code) || code == 95
    _ -> is_letter(code) || is_digit(code) || code == 95
  }
}

/// Letters, digits, `_`, and `$`. PostgreSQL identifiers allow letters
/// (including any non-ASCII character), digits, `_`, and `$` after the
/// first character; this is used both for dollar-quote tags and to tell a
/// `$` inside an unquoted identifier from a dollar-quote opener.
fn is_letter(code: Int) -> Bool {
  code >= 97 && code <= 122 || code >= 65 && code <= 90 || code >= 128
}

fn is_digit(code: Int) -> Bool {
  code >= 48 && code <= 57
}

fn is_ident_continue(code: Int) -> Bool {
  is_letter(code) || is_digit(code) || code == 95 || code == 36
}

fn to_codepoints(value: String) -> List(Int) {
  value |> string.to_utf_codepoints |> list.map(string.utf_codepoint_to_int)
}

/// Append `sequence` (in order) onto the reversed `current` buffer.
fn emit(sequence: List(Int), current: List(Int)) -> List(Int) {
  list.append(list.reverse(sequence), current)
}

/// Drop `prefix` from the front of `chars`, or fail if it does not match.
fn drop_prefix(chars: List(Int), prefix: List(Int)) -> Result(List(Int), Nil) {
  case prefix {
    [] -> Ok(chars)
    [expected, ..more] ->
      case chars {
        [char, ..rest] if char == expected -> drop_prefix(rest, more)
        _ -> Error(Nil)
      }
  }
}

fn codepoints_to_string(codepoints: List(Int)) -> String {
  codepoints |> list.map(codepoint) |> string.from_utf_codepoints
}

fn codepoint(value: Int) -> UtfCodepoint {
  let assert Ok(cp) = string.utf_codepoint(value)
  cp
}

/// Close the current statement: trim it, keep it if non-empty.
fn finish(current: List(Int), done: List(String)) -> List(String) {
  case string.trim(codepoints_to_string(list.reverse(current))) {
    "" -> done
    statement -> [statement, ..done]
  }
}

/// First non-empty line, truncated for the log.
fn summarize(statement: String) -> String {
  statement
  |> string.split("\n")
  |> list.filter(fn(line) { string.trim(line) != "" })
  |> list.first
  |> fn(first) {
    case first {
      Ok(line) -> string.slice(string.trim(line), 0, 72)
      Error(_) -> string.slice(statement, 0, 72)
    }
  }
}
