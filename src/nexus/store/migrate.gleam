//// Sequential schema migration runner: applies pending numbered SQL files
//// from `sql/migrations/` to the database in `DATABASE_URL` (the same
//// convention squirrel uses) and records each applied migration in
//// `schema_migration`.
////
//// This runner is the only schema-apply path: the compose file has no
//// schema bind mount (its config must stay identical from every
//// checkout/worktree, so `up` never recreates the singleton db on a
//// worktree switch). Apply after boot; re-apply after adding migrations
//// and for the CI service container:
////
////     DATABASE_URL=postgres://nexus@127.0.0.1:5433/nexus \
////       gleam run -m nexus/store/migrate
////   # (bin/dev-server runs this on every dev boot)
////
//// Migration files live in `sql/migrations/` and are named
//// `NNNN_<short_name>.sql` (at least 4 digits, version > 0, lowercase
//// snake_case slug, e.g. `0001_initial.sql`, `0002_workspace_sandbox.sql`).
//// Already-applied migrations are immutable: the runner verifies each
//// applied migration's filename and SHA-256 checksum against
//// `schema_migration` before applying pending files. Each pending file runs
//// inside its own PostgreSQL transaction alongside its `schema_migration`
//// insert so a failed statement rolls back cleanly.
////
//// Statements within each file are split by a quote-aware scanner
//// (`statements`), so `;` inside string literals, double-quoted
//// identifiers, dollar-quoted bodies (`CREATE FUNCTION` / `DO`), and
//// comments do not break a statement apart.

import filepath
import gleam/bit_array
import gleam/crypto
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/order
import gleam/result
import gleam/string
import pog
import simplifile

/// Directory containing sequentially numbered `.sql` migration files,
/// relative to the repository root.
pub const migrations_dir = "sql/migrations"

/// Fixed advisory-lock key ("nexus" in big-endian ASCII hex, 0x6E65787573)
/// used inside transactions so concurrent migration runners serialize cleanly.
const advisory_lock_key = 474_148_795_763

/// Timeout while waiting for another runner to release the advisory lock (30s).
const lock_wait_timeout_ms = 30_000

/// Statement timeout for DDL/backfill statements inside a migration (60s).
const statement_timeout_ms = 60_000

/// One migration file loaded from disk.
pub type Migration {
  Migration(version: Int, name: String, sql: String, checksum: String)
}

/// One migration row already recorded in `schema_migration`.
pub type AppliedMigration {
  AppliedMigration(version: Int, name: String, checksum: String)
}

/// Validation or drift error found while planning a migration run.
pub type PlanError {
  InvalidFilename(filename: String)
  DuplicateVersion(version: Int, first: String, second: String)
  EmptyMigration(name: String)
  NameMismatch(version: Int, applied: String, disk: String)
  ChecksumMismatch(version: Int, name: String, applied: String, disk: String)
}

/// Pure result of comparing disk migrations against `schema_migration`.
pub type MigrationPlan {
  MigrationPlan(
    pending: List(Migration),
    already_applied: Int,
    ahead_in_db: List(AppliedMigration),
  )
}

type TxError {
  StatementFailed(statement: String, error: pog.QueryError)
  RecordFailed(error: pog.QueryError)
  ConcurrentDrift(PlanError)
}

@external(erlang, "nexus_store_ffi", "database_url")
fn database_url() -> Result(String, Nil)

// Run main's schema work under with_pool_settled: from pog.start onward the
// VM must neither halt nor panic while the pool's boot is still in flight
// (intermittent pgo_pool_sup shutdown_error report at teardown); see
// nexus_store_ffi:with_pool_settled/2. pog.start hands back the pool's
// queue gen_server. Panics before pog.start (migration files, DATABASE_URL,
// URL parse) have no pool to race the halt with and stay unwrapped.
@external(erlang, "nexus_store_ffi", "with_pool_settled")
fn with_pool_settled(run: fn() -> Nil, queue: process.Pid) -> Nil

pub fn main() -> Nil {
  let migrations =
    or_panic(
      load_migrations(migrations_dir),
      "cannot load migrations from " <> migrations_dir,
    )
  let url = or_panic(database_url(), "DATABASE_URL is not set")
  let config =
    or_panic(
      pog.url_config(process.new_name("nexus_migrate"), url),
      "invalid DATABASE_URL",
    )
    |> pog.pool_size(1)
    |> pog.connection_parameter("timezone", "UTC")
  let started =
    or_panic(pog.start(config), "could not connect — is the database up?")
  with_pool_settled(
    fn() { apply_migrations(migrations, started.data) },
    started.pid,
  )
}

fn apply_migrations(migrations: List(Migration), db: pog.Connection) -> Nil {
  or_panic(ensure_tracking_table(db), "failed to initialize schema_migration")
  let applied =
    or_panic(fetch_applied(db), "failed to read schema_migration rows")
  let migration_plan = case plan(migrations, applied) {
    Ok(p) -> p
    Error(err) -> {
      io.println("migrate: " <> format_plan_error(err))
      panic as "migrate failed"
    }
  }
  case migration_plan.ahead_in_db {
    [] -> Nil
    ahead -> {
      let names = list.map(ahead, fn(m) { m.name }) |> string.join(", ")
      io.println(
        "migrate: note: database has migrations not in "
        <> migrations_dir
        <> " (ahead): "
        <> names,
      )
    }
  }
  case migration_plan.pending {
    [] ->
      io.println(
        "migrate: up to date ("
        <> int.to_string(migration_plan.already_applied)
        <> " applied, 0 pending)",
      )
    pending -> {
      let applied_now =
        list.fold(pending, 0, fn(applied_count, migration) {
          case apply_one(db, migration) {
            Ok(0) -> {
              io.println(
                "migrate: skipped "
                <> migration.name
                <> " (applied concurrently)",
              )
              applied_count
            }
            Ok(count) -> {
              io.println(
                "migrate: applied "
                <> migration.name
                <> " ("
                <> int.to_string(count)
                <> " statements)",
              )
              applied_count + 1
            }
            Error(pog.TransactionRolledBack(StatementFailed(stmt, err))) -> {
              io.println(
                "migrate: FAILED "
                <> migration.name
                <> " on: "
                <> summarize(stmt)
                <> " — "
                <> string.inspect(err),
              )
              panic as "migrate: statement failed"
            }
            Error(pog.TransactionRolledBack(RecordFailed(err))) -> {
              io.println(
                "migrate: FAILED recording "
                <> migration.name
                <> " — "
                <> string.inspect(err),
              )
              panic as "migrate: record failed"
            }
            Error(pog.TransactionRolledBack(ConcurrentDrift(err))) -> {
              io.println("migrate: " <> format_plan_error(err))
              panic as "migrate failed"
            }
            Error(pog.TransactionQueryError(err)) -> {
              io.println(
                "migrate: FAILED transaction for "
                <> migration.name
                <> " — "
                <> string.inspect(err),
              )
              panic as "migrate: transaction failed"
            }
          }
        })
      let total = migration_plan.already_applied + list.length(pending)
      io.println(
        "migrate: done ("
        <> int.to_string(applied_now)
        <> " applied, "
        <> int.to_string(total)
        <> " total)",
      )
    }
  }
}

fn ensure_tracking_table(
  db: pog.Connection,
) -> Result(Nil, pog.TransactionError(pog.QueryError)) {
  pog.transaction(db, fn(tx) {
    use _ <- result.try(acquire_lock(tx))
    "CREATE TABLE IF NOT EXISTS schema_migration (
      version    int PRIMARY KEY,
      name       text NOT NULL,
      checksum   text NOT NULL,
      applied_at timestamptz NOT NULL DEFAULT now()
    )"
    |> pog.query
    |> pog.returning(decode.dynamic)
    |> pog.execute(tx)
    |> result.replace(Nil)
  })
}

fn acquire_lock(tx: pog.Connection) -> Result(Nil, pog.QueryError) {
  // Wrap pg_advisory_xact_lock in a subquery returning int4 rather than
  // Postgres `void` (OID 2278), which pgo's pg_types decoder does not map.
  "SELECT 1 FROM (SELECT pg_advisory_xact_lock($1)) AS _lock"
  |> pog.query
  |> pog.timeout(lock_wait_timeout_ms)
  |> pog.parameter(pog.int(advisory_lock_key))
  |> pog.returning(decode.dynamic)
  |> pog.execute(tx)
  |> result.replace(Nil)
}

fn fetch_applied(
  db: pog.Connection,
) -> Result(List(AppliedMigration), pog.QueryError) {
  let decoder = {
    use version <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    use checksum <- decode.field(2, decode.string)
    decode.success(AppliedMigration(version:, name:, checksum:))
  }
  "SELECT version, name, checksum FROM schema_migration ORDER BY version ASC"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
  |> result.map(fn(returned) { returned.rows })
}

fn apply_one(
  db: pog.Connection,
  migration: Migration,
) -> Result(Int, pog.TransactionError(TxError)) {
  let stmts = statements(migration.sql)
  pog.transaction(db, fn(tx) {
    use _ <- result.try(acquire_lock(tx) |> result.map_error(RecordFailed))
    use existing <- result.try(
      fetch_one_applied(tx, migration.version)
      |> result.map_error(RecordFailed),
    )
    case existing {
      [AppliedMigration(version:, name:, checksum:)] ->
        case name == migration.name, checksum == migration.checksum {
          True, True -> Ok(0)
          False, _ ->
            Error(ConcurrentDrift(NameMismatch(version, name, migration.name)))
          True, False ->
            Error(
              ConcurrentDrift(ChecksumMismatch(
                version,
                migration.name,
                checksum,
                migration.checksum,
              )),
            )
        }
      _ -> {
        use _ <- result.try(execute_statements(tx, stmts))
        use _ <- result.try(
          "INSERT INTO schema_migration (version, name, checksum) VALUES ($1, $2, $3)"
          |> pog.query
          |> pog.parameter(pog.int(migration.version))
          |> pog.parameter(pog.text(migration.name))
          |> pog.parameter(pog.text(migration.checksum))
          |> pog.returning(decode.dynamic)
          |> pog.execute(tx)
          |> result.map_error(RecordFailed),
        )
        Ok(list.length(stmts))
      }
    }
  })
}

fn fetch_one_applied(
  tx: pog.Connection,
  version: Int,
) -> Result(List(AppliedMigration), pog.QueryError) {
  let decoder = {
    use v <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    use checksum <- decode.field(2, decode.string)
    decode.success(AppliedMigration(version: v, name:, checksum:))
  }
  "SELECT version, name, checksum FROM schema_migration WHERE version = $1"
  |> pog.query
  |> pog.parameter(pog.int(version))
  |> pog.returning(decoder)
  |> pog.execute(tx)
  |> result.map(fn(returned) { returned.rows })
}

fn execute_statements(
  tx: pog.Connection,
  stmts: List(String),
) -> Result(Nil, TxError) {
  list.try_each(stmts, fn(stmt) {
    stmt
    |> pog.query
    |> pog.timeout(statement_timeout_ms)
    |> pog.returning(decode.dynamic)
    |> pog.execute(tx)
    |> result.replace(Nil)
    |> result.map_error(fn(err) { StatementFailed(stmt, err) })
  })
}

/// Load and validate all migration files in `dir`, sorted by ascending
/// numeric version.
pub fn load_migrations(dir: String) -> Result(List(Migration), String) {
  use entries <- result.try(
    simplifile.read_directory(dir)
    |> result.map_error(fn(err) {
      "cannot list " <> dir <> ": " <> simplifile.describe_error(err)
    }),
  )
  let sorted_entries =
    entries
    |> list.filter(fn(entry) { string.ends_with(entry, ".sql") })
    |> list.sort(string.compare)
  use loaded <- result.try(
    list.try_map(sorted_entries, fn(entry) {
      use version <- result.try(
        parse_filename(entry)
        |> result.map_error(fn(_) { format_plan_error(InvalidFilename(entry)) }),
      )
      let full_path = filepath.join(dir, entry)
      use sql <- result.try(
        simplifile.read(full_path)
        |> result.map_error(fn(err) {
          "cannot read " <> full_path <> ": " <> simplifile.describe_error(err)
        }),
      )
      Ok(Migration(version:, name: entry, sql:, checksum: checksum(sql)))
    }),
  )
  use validated <- result.try(
    validate_disk(loaded) |> result.map_error(format_plan_error),
  )
  Ok(validated)
}

/// Validate a migration filename and extract its numeric version.
///
/// Expected format: `NNNN_<slug>.sql` where `NNNN` is at least 4 ASCII
/// digits representing an integer > 0 and `<slug>` is lowercase ASCII
/// letters, digits, and underscores containing at least one alphanumeric
/// character (e.g. `0001_initial.sql`, `0002_workspace_sandbox.sql`).
pub fn parse_filename(filename: String) -> Result(Int, Nil) {
  case string.ends_with(filename, ".sql") {
    False -> Error(Nil)
    True -> {
      let stem = string.drop_end(filename, 4)
      case string.split_once(stem, "_") {
        Error(_) -> Error(Nil)
        Ok(#(prefix, slug)) -> {
          let prefix_codes = to_codepoints(prefix)
          let slug_codes = to_codepoints(slug)
          let valid_prefix =
            list.length(prefix_codes) >= 4 && list.all(prefix_codes, is_digit)
          let valid_slug =
            slug != ""
            && list.all(slug_codes, is_slug_char)
            && list.any(slug_codes, is_slug_alnum)
          case valid_prefix && valid_slug {
            False -> Error(Nil)
            True ->
              case int.parse(prefix) {
                Ok(version) if version > 0 -> Ok(version)
                _ -> Error(Nil)
              }
          }
        }
      }
    }
  }
}

/// Lowercase SHA-256 hex digest of a migration file's UTF-8 contents
/// (matches `sha256sum`).
pub fn checksum(sql: String) -> String {
  crypto.hash(crypto.Sha256, <<sql:utf8>>)
  |> bit_array.base16_encode
  |> string.lowercase
}

/// Compare disk migrations against already-applied rows from
/// `schema_migration` and compute the pending migrations to run.
///
/// - Rejects duplicate versions and empty (comment/whitespace-only) files.
/// - Verifies that every applied migration present on disk still has the
///   same filename and SHA-256 checksum (applied migrations are immutable).
/// - Applied migrations absent from disk (e.g. an older branch running
///   against a shared dev DB) are reported in `ahead_in_db` rather than
///   blocking execution.
/// - Pending migrations whose version is lower than already-applied ones
///   (gaps from parallel branches) are applied out of order in ascending
///   version order, so migrations should tolerate running after later
///   independent migrations have already landed.
/// - Returns `pending` sorted in ascending numeric version order.
pub fn plan(
  disk: List(Migration),
  applied: List(AppliedMigration),
) -> Result(MigrationPlan, PlanError) {
  use sorted_disk <- result.try(validate_disk(disk))
  let disk_by_version =
    list.fold(sorted_disk, dict.new(), fn(acc, m) {
      dict.insert(acc, m.version, m)
    })
  let sorted_applied =
    list.sort(applied, fn(a, b) { int.compare(a.version, b.version) })
  use #(verified, ahead_rev) <- result.try(
    list.try_fold(sorted_applied, #(0, []), fn(acc, row) {
      let #(verified, ahead) = acc
      case dict.get(disk_by_version, row.version) {
        Error(Nil) -> Ok(#(verified, [row, ..ahead]))
        Ok(m) ->
          case m.name == row.name, m.checksum == row.checksum {
            True, True -> Ok(#(verified + 1, ahead))
            False, _ -> Error(NameMismatch(row.version, row.name, m.name))
            True, False ->
              Error(ChecksumMismatch(
                row.version,
                m.name,
                row.checksum,
                m.checksum,
              ))
          }
      }
    }),
  )
  let applied_by_version =
    list.fold(sorted_applied, dict.new(), fn(acc, row) {
      dict.insert(acc, row.version, row)
    })
  let pending =
    list.filter(sorted_disk, fn(m) {
      !dict.has_key(applied_by_version, m.version)
    })
  Ok(MigrationPlan(
    pending:,
    already_applied: verified,
    ahead_in_db: list.reverse(ahead_rev),
  ))
}

/// Human-readable description of a `PlanError`.
pub fn format_plan_error(error: PlanError) -> String {
  case error {
    InvalidFilename(filename) ->
      "invalid migration filename '"
      <> filename
      <> "' (expected NNNN_<snake_case>.sql, e.g. 0002_add_workspace.sql)"
    DuplicateVersion(version, first, second) ->
      "duplicate migration version "
      <> int.to_string(version)
      <> ": "
      <> first
      <> " and "
      <> second
    EmptyMigration(name) ->
      "migration '" <> name <> "' contains no SQL statements"
    NameMismatch(version, applied, disk) ->
      "migration version "
      <> int.to_string(version)
      <> " was applied as '"
      <> applied
      <> "' but disk has '"
      <> disk
      <> "' (already-applied migrations are immutable; add a new numbered migration instead)"
    ChecksumMismatch(version, name, applied, disk) ->
      "checksum mismatch for migration "
      <> int.to_string(version)
      <> " ("
      <> name
      <> "): applied "
      <> applied
      <> ", disk "
      <> disk
      <> " (already-applied migrations are immutable; add a new numbered migration instead)"
  }
}

fn validate_disk(disk: List(Migration)) -> Result(List(Migration), PlanError) {
  let sorted =
    list.sort(disk, fn(a, b) {
      case int.compare(a.version, b.version) {
        order.Eq -> string.compare(a.name, b.name)
        other -> other
      }
    })
  use _ <- result.try(
    list.try_fold(sorted, dict.new(), fn(seen, m) {
      case dict.get(seen, m.version) {
        Ok(first) -> Error(DuplicateVersion(m.version, first, m.name))
        Error(Nil) ->
          case statements(m.sql) {
            [] -> Error(EmptyMigration(m.name))
            _ -> Ok(dict.insert(seen, m.version, m.name))
          }
      }
    }),
  )
  Ok(sorted)
}

fn is_slug_alnum(code: Int) -> Bool {
  { code >= 97 && code <= 122 } || is_digit(code)
}

fn is_slug_char(code: Int) -> Bool {
  is_slug_alnum(code) || code == 95
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
