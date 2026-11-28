//// Unit tests for `nexus/store/migrate`:
//// - the quote-aware SQL statement splitter (`statements`),
//// - migration filename validation and SHA-256 checksums,
//// - the pure migration planner (ordering, immutability checks, ahead-in-db),
//// - live validation of the repository's `sql/migrations/` directory.

import gleam/bit_array
import gleam/crypto
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import nexus/store/migrate.{
  type Migration, AppliedMigration, ChecksumMismatch, DuplicateVersion,
  EmptyMigration, Migration, MigrationPlan, NameMismatch,
  TransactionControlNotAllowed,
}
import simplifile

pub fn splits_top_level_semicolons_test() {
  migrate.statements("create table a (x int); create table b (y int);")
  |> should.equal(["create table a (x int)", "create table b (y int)"])
}

pub fn drops_empty_statements_test() {
  migrate.statements("") |> should.equal([])
  migrate.statements("   \n\t ") |> should.equal([])
  migrate.statements(";;;") |> should.equal([])
}

pub fn comment_only_input_test() {
  migrate.statements("-- just a comment\n-- and another\n")
  |> should.equal([])
}

pub fn semicolon_in_line_comment_test() {
  migrate.statements("select 1--a;b\nfrom t;select 2;")
  |> should.equal(["select 1\nfrom t", "select 2"])
}

pub fn semicolon_in_single_quoted_literal_test() {
  migrate.statements("insert into t values ('a;b');select 2;")
  |> should.equal(["insert into t values ('a;b')", "select 2"])
}

pub fn doubled_single_quote_is_escaped_test() {
  migrate.statements("select 'it''s;ok';select 2;")
  |> should.equal(["select 'it''s;ok'", "select 2"])
}

pub fn semicolon_in_double_quoted_identifier_test() {
  migrate.statements("select \"a;b\", \"c\"\"d;e\";select 2;")
  |> should.equal(["select \"a;b\", \"c\"\"d;e\"", "select 2"])
}

pub fn comment_markers_in_literal_are_literal_test() {
  migrate.statements("select '--';select '/*';select 2;")
  |> should.equal(["select '--'", "select '/*'", "select 2"])
}

pub fn semicolon_in_dollar_quote_test() {
  migrate.statements("do $$ begin; perform 1; end; $$;select 2;")
  |> should.equal(["do $$ begin; perform 1; end; $$", "select 2"])
}

pub fn semicolon_in_tagged_dollar_quote_test() {
  migrate.statements(
    "create function f() returns int as $fn$ begin; return 1; end; $fn$ language plpgsql;select 2;",
  )
  |> should.equal([
    "create function f() returns int as $fn$ begin; return 1; end; $fn$ language plpgsql",
    "select 2",
  ])
}

pub fn comment_markers_in_dollar_quote_are_literal_test() {
  migrate.statements("do $$ -- ; /* ; */ $$;select 2;")
  |> should.equal(["do $$ -- ; /* ; */ $$", "select 2"])
}

pub fn nested_different_dollar_tag_does_not_close_test() {
  migrate.statements("do $outer$ x $inner$ ; y $outer$;select 2;")
  |> should.equal(["do $outer$ x $inner$ ; y $outer$", "select 2"])
}

pub fn positional_parameter_is_not_a_dollar_quote_test() {
  migrate.statements("select $1;select $2;")
  |> should.equal(["select $1", "select $2"])
}

pub fn lone_dollar_is_literal_test() {
  migrate.statements("select 1 $ 2;select 3;")
  |> should.equal(["select 1 $ 2", "select 3"])
}

pub fn semicolon_in_block_comment_test() {
  migrate.statements("select/*a;b*/1;select 2;")
  |> should.equal(["select 1", "select 2"])
}

pub fn nested_block_comment_test() {
  migrate.statements("select/*a/*b;*/c;*/1;select 2;")
  |> should.equal(["select 1", "select 2"])
}

pub fn unterminated_dollar_quote_is_kept_test() {
  migrate.statements("do $$ begin; ")
  |> should.equal(["do $$ begin;"])
}

pub fn crlf_line_comment_test() {
  migrate.statements("-- header\r\ncreate table t (id int);\r\nselect 2;\r\n")
  |> should.equal(["create table t (id int)", "select 2"])
}

pub fn bare_cr_line_comment_test() {
  migrate.statements("-- header\rcreate table t (id int);\rselect 2;\r")
  |> should.equal(["create table t (id int)", "select 2"])
}

pub fn crlf_does_not_break_literals_test() {
  migrate.statements("insert into t values ('a;b');\r\nselect 2;\r\n")
  |> should.equal(["insert into t values ('a;b')", "select 2"])
}

pub fn dollar_in_unquoted_identifier_test() {
  migrate.statements("create table audit$log$ (id int); select 2;")
  |> should.equal(["create table audit$log$ (id int)", "select 2"])
}

pub fn unterminated_block_comment_keeps_marker_test() {
  migrate.statements("create table t (id int) /* unfinished")
  |> should.equal(["create table t (id int) /*"])
}

pub fn unterminated_block_comment_only_test() {
  migrate.statements("/* unfinished")
  |> should.equal(["/*"])
}

pub fn non_ascii_dollar_quote_tag_test() {
  migrate.statements("do $é$ begin; perform 1; end; $é$;select 2;")
  |> should.equal(["do $é$ begin; perform 1; end; $é$", "select 2"])
}

pub fn e_string_escaped_quote_test() {
  migrate.statements("select E'it\\'s;ok';select 2;")
  |> should.equal(["select E'it\\'s;ok'", "select 2"])
}

pub fn e_string_escaped_semicolon_test() {
  migrate.statements("select E'a\\;b';select 2;")
  |> should.equal(["select E'a\\;b'", "select 2"])
}

pub fn e_string_doubled_quote_test() {
  migrate.statements("select E'a''b;c';select 2;")
  |> should.equal(["select E'a''b;c'", "select 2"])
}

pub fn plain_literal_keeps_backslash_literal_test() {
  migrate.statements("select 'a\\b;c';select 2;")
  |> should.equal(["select 'a\\b;c'", "select 2"])
}

pub fn identifier_ending_in_e_before_literal_test() {
  migrate.statements("select name'x;y';select 2;")
  |> should.equal(["select name'x;y'", "select 2"])
}

pub fn uescape_string_test() {
  migrate.statements("select U&'d\\0061t\\'s;ok';select 2;")
  |> should.equal(["select U&'d\\0061t\\'s;ok'", "select 2"])
}

/// A `;` inside a single-quoted literal INSIDE a dollar-quoted body (a
/// column default like `';'::text`, say) must stay inside the statement —
/// quote tracking inside `$$` may not flip on the inner quotes.
pub fn semicolon_in_literal_inside_dollar_quote_test() {
  migrate.statements(
    "do $$ begin alter table t add c text default 'a;b'; end $$;select 2;",
  )
  |> should.equal([
    "do $$ begin alter table t add c text default 'a;b'; end $$",
    "select 2",
  ])
}

// ---------------------------------------------------------------------------
// Sequential migration naming, checksum, planner, and live directory checks
// ---------------------------------------------------------------------------

fn migration(version: Int, name: String, sql: String) -> Migration {
  Migration(version:, name:, sql:, checksum: migrate.checksum(sql))
}

pub fn parse_filename_accepts_numbered_snake_case_test() {
  migrate.parse_filename("0001_initial.sql") |> should.equal(Ok(1))
  migrate.parse_filename("0002_workspace_sandbox.sql") |> should.equal(Ok(2))
  migrate.parse_filename("0042_add_v2_index.sql") |> should.equal(Ok(42))
  migrate.parse_filename("10000_large_number.sql") |> should.equal(Ok(10_000))
}

pub fn parse_filename_rejects_malformed_names_test() {
  migrate.parse_filename("schema.sql") |> should.equal(Error(Nil))
  migrate.parse_filename("001_too_short.sql") |> should.equal(Error(Nil))
  migrate.parse_filename("0000_zero.sql") |> should.equal(Error(Nil))
  migrate.parse_filename("0001_.sql") |> should.equal(Error(Nil))
  migrate.parse_filename("0001____.sql") |> should.equal(Error(Nil))
  migrate.parse_filename("0001_Upper.sql") |> should.equal(Error(Nil))
  migrate.parse_filename("0001_with-dash.sql") |> should.equal(Error(Nil))
  migrate.parse_filename("0001_missing_ext") |> should.equal(Error(Nil))
  migrate.parse_filename("0001_wrong.txt") |> should.equal(Error(Nil))
}

pub fn checksum_matches_sha256_vector_test() {
  migrate.checksum("")
  |> should.equal(
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  )
}

pub fn plan_fresh_database_sorts_pending_ascending_test() {
  let m1 = migration(1, "0001_initial.sql", "CREATE TABLE a (id int);")
  let m2 = migration(2, "0002_second.sql", "ALTER TABLE a ADD COLUMN b text;")
  let m3 = migration(3, "0003_third.sql", "CREATE INDEX a_b ON a (b);")

  migrate.plan([m3, m1, m2], [])
  |> should.equal(
    Ok(
      MigrationPlan(pending: [m1, m2, m3], already_applied: 0, ahead_in_db: []),
    ),
  )
}

pub fn plan_incremental_and_up_to_date_test() {
  let m1 = migration(1, "0001_initial.sql", "CREATE TABLE a (id int);")
  let m2 = migration(2, "0002_second.sql", "ALTER TABLE a ADD COLUMN b text;")
  let applied1 = AppliedMigration(1, m1.name, m1.checksum)
  let applied2 = AppliedMigration(2, m2.name, m2.checksum)

  migrate.plan([m1, m2], [applied1])
  |> should.equal(
    Ok(MigrationPlan(pending: [m2], already_applied: 1, ahead_in_db: [])),
  )

  migrate.plan([m1, m2], [applied1, applied2])
  |> should.equal(
    Ok(MigrationPlan(pending: [], already_applied: 2, ahead_in_db: [])),
  )
}

pub fn plan_rejects_modified_applied_migration_test() {
  let original_sql = "CREATE TABLE a (id int);"
  let edited_sql = "CREATE TABLE a (id bigint);"
  let m1 = migration(1, "0001_initial.sql", edited_sql)
  let applied =
    AppliedMigration(1, "0001_initial.sql", migrate.checksum(original_sql))

  migrate.plan([m1], [applied])
  |> should.equal(
    Error(ChecksumMismatch(
      1,
      "0001_initial.sql",
      migrate.checksum(original_sql),
      migrate.checksum(edited_sql),
    )),
  )
}

pub fn plan_rejects_renamed_applied_migration_test() {
  let sql = "CREATE TABLE a (id int);"
  let m1 = migration(1, "0001_renamed.sql", sql)
  let applied = AppliedMigration(1, "0001_initial.sql", migrate.checksum(sql))

  migrate.plan([m1], [applied])
  |> should.equal(
    Error(NameMismatch(1, "0001_initial.sql", "0001_renamed.sql")),
  )
}

pub fn plan_rejects_duplicate_versions_on_disk_test() {
  let m2a = migration(2, "0002_alpha.sql", "SELECT 1;")
  let m2b = migration(2, "0002_beta.sql", "SELECT 2;")

  migrate.plan([m2b, m2a], [])
  |> should.equal(Error(DuplicateVersion(2, "0002_alpha.sql", "0002_beta.sql")))
}

pub fn plan_rejects_empty_migration_test() {
  let empty = migration(2, "0002_empty.sql", "-- just a comment\n")

  migrate.plan([empty], [])
  |> should.equal(Error(EmptyMigration("0002_empty.sql")))
}

pub fn plan_rejects_top_level_transaction_control_test() {
  let cases = [
    "BEGIN; CREATE TABLE t (id int);",
    "CREATE TABLE t (id int); COMMIT;",
    "CREATE TABLE t (id int); ROLLBACK;",
    "START TRANSACTION ISOLATION LEVEL SERIALIZABLE; SELECT 1;",
    "CREATE TABLE t (id int); END WORK;",
    "CREATE TABLE t (id int); ABORT;",
    "/* comment */ commit and chain;",
  ]
  list.each(cases, fn(sql) {
    let m = migration(2, "0002_tx.sql", sql)
    let assert Error(TransactionControlNotAllowed(name: "0002_tx.sql", ..)) =
      migrate.plan([m], [])
  })
}

pub fn plan_allows_transaction_keywords_in_do_and_function_bodies_and_ddl_test() {
  let m =
    migration(
      2,
      "0002_safe_keywords.sql",
      "DO $$ BEGIN PERFORM 1; END; $$;
       CREATE FUNCTION f() RETURNS void AS $$ BEGIN NULL; END; $$ LANGUAGE plpgsql;
       CREATE TABLE commit_log (id int, rollback_reason text, begin_at timestamptz);
       CREATE TABLE start_events (id int);",
    )
  let assert Ok(MigrationPlan(pending: [planned], already_applied: 0, ..)) =
    migrate.plan([m], [])
  should.equal(planned.version, 2)
}

pub fn plan_tolerates_db_ahead_of_older_branch_test() {
  let m1 = migration(1, "0001_initial.sql", "CREATE TABLE a (id int);")
  let applied1 = AppliedMigration(1, m1.name, m1.checksum)
  let applied2 = AppliedMigration(2, "0002_future.sql", "deadbeef")

  migrate.plan([m1], [applied1, applied2])
  |> should.equal(
    Ok(MigrationPlan(pending: [], already_applied: 1, ahead_in_db: [applied2])),
  )
}

pub fn plan_applies_out_of_order_pending_migration_test() {
  let m1 = migration(1, "0001_initial.sql", "SELECT 1;")
  let m2 = migration(2, "0002_merged_later.sql", "SELECT 2;")
  let m3 = migration(3, "0003_feature.sql", "SELECT 3;")
  let applied1 = AppliedMigration(1, m1.name, m1.checksum)
  let applied3 = AppliedMigration(3, m3.name, m3.checksum)

  migrate.plan([m1, m2, m3], [applied1, applied3])
  |> should.equal(
    Ok(MigrationPlan(pending: [m2], already_applied: 2, ahead_in_db: [])),
  )
}

/// Validates the real `sql/migrations/` directory offline: every filename
/// follows `NNNN_<snake_case>.sql`, versions are unique and strictly
/// increasing starting at `0001_initial.sql`, every file contains at least
/// one parseable SQL statement, and the fresh-DB plan succeeds.
pub fn repo_migrations_are_valid_test() {
  let assert Ok(migrations) = migrate.load_migrations(migrate.migrations_dir)
  let assert [first, ..] = migrations
  should.equal(first.version, 1)
  should.equal(first.name, "0001_initial.sql")
  should.be_true(string.length(first.checksum) == 64)
  should.be_true(migrate.statements(first.sql) != [])
  // `0001_initial.sql` is immutable (checksum-tracked): pin its SHA-256 so an
  // accidental edit fails `gleam test` offline before any database sees it.
  should.equal(
    first.checksum,
    "fa32d1bc76967941730db6b2ac3d94fd8a9d78cc6501eb43362daed918430c81",
  )
  let assert Ok(MigrationPlan(pending:, already_applied: 0, ahead_in_db: [])) =
    migrate.plan(migrations, [])
  should.equal(list.length(pending), list.length(migrations))
}

pub fn load_migrations_ignores_non_sql_entries_and_rejects_bad_sql_names_test() {
  let suffix =
    crypto.strong_random_bytes(8) |> bit_array.base16_encode |> string.lowercase
  let dir = "/tmp/nexus_migrate_load_test_" <> suffix
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  let assert Ok(Nil) = simplifile.write(dir <> "/.DS_Store", "junk")
  let assert Ok(Nil) = simplifile.write(dir <> "/README.md", "notes")
  let assert Ok(Nil) =
    simplifile.write(dir <> "/0001_init.sql", "CREATE TABLE t (id int);")

  let assert Ok([loaded]) = migrate.load_migrations(dir)
  should.equal(loaded.version, 1)
  should.equal(loaded.name, "0001_init.sql")

  let assert Ok(Nil) = simplifile.write(dir <> "/bad_name.sql", "SELECT 1;")
  let assert Error(message) = migrate.load_migrations(dir)
  should.be_true(string.contains(message, "bad_name.sql"))

  let _ = simplifile.delete(dir)
  Nil
}

fn env_lookup(
  pairs: List(#(String, String)),
) -> fn(String) -> Result(String, Nil) {
  let table = dict.from_list(pairs)
  fn(key) { dict.get(table, key) }
}

pub fn resolve_migrations_dir_defaults_and_overrides_test() {
  migrate.resolve_migrations_dir(env_lookup([]))
  |> should.equal("sql/migrations")

  migrate.resolve_migrations_dir(env_lookup([#("NEXUS_MIGRATIONS_DIR", "  ")]))
  |> should.equal("sql/migrations")

  migrate.resolve_migrations_dir(
    env_lookup([#("NEXUS_MIGRATIONS_DIR", "/nix/store/abc-nexus/share/sql")]),
  )
  |> should.equal("/nix/store/abc-nexus/share/sql")
}

pub fn pg_config_from_env_prefers_database_url_test() {
  let pool = process.new_name("migrate_test_url")
  let assert Ok(cfg) =
    migrate.pg_config_from_env(
      pool,
      env_lookup([
        #("DATABASE_URL", "postgres://alice:secret@db.internal:5432/prod"),
        #("NEXUS_PG_HOST", "ignored-host"),
      ]),
    )
  should.equal(cfg.host, "db.internal")
  should.equal(cfg.port, 5432)
  should.equal(cfg.database, "prod")
  should.equal(cfg.user, "alice")
  should.equal(cfg.password, Some("secret"))
  should.equal(cfg.pool_size, 1)
}

pub fn pg_config_from_env_falls_back_to_nexus_pg_vars_test() {
  let pool = process.new_name("migrate_test_pg")
  let assert Ok(cfg) =
    migrate.pg_config_from_env(
      pool,
      env_lookup([
        #("NEXUS_PG_HOST", "127.0.0.1"),
        #("NEXUS_PG_PORT", "5432"),
        #("NEXUS_PG_DATABASE", "nexus_prod"),
        #("NEXUS_PG_USER", "nexus_user"),
        #("NEXUS_PG_PASSWORD", "s3cr3t"),
      ]),
    )
  should.equal(cfg.host, "127.0.0.1")
  should.equal(cfg.port, 5432)
  should.equal(cfg.database, "nexus_prod")
  should.equal(cfg.user, "nexus_user")
  should.equal(cfg.password, Some("s3cr3t"))
  should.equal(cfg.pool_size, 1)

  // Defaults match config.gleam when only a subset of NEXUS_PG_* is set.
  let assert Ok(partial) =
    migrate.pg_config_from_env(pool, env_lookup([#("NEXUS_PG_PORT", "5432")]))
  should.equal(partial.host, "127.0.0.1")
  should.equal(partial.port, 5432)
  should.equal(partial.database, "nexus")
  should.equal(partial.user, "nexus")
  should.equal(partial.password, None)

  let assert Ok(host_only) =
    migrate.pg_config_from_env(
      pool,
      env_lookup([#("NEXUS_PG_HOST", "db.local")]),
    )
  should.equal(host_only.host, "db.local")
  should.equal(host_only.port, 5433)
  should.equal(host_only.database, "nexus")
  should.equal(host_only.user, "nexus")
  should.equal(host_only.password, None)
}

pub fn pg_config_from_env_errors_when_unconfigured_or_invalid_test() {
  let pool = process.new_name("migrate_test_err")
  let assert Error(msg) = migrate.pg_config_from_env(pool, env_lookup([]))
  should.be_true(string.contains(msg, "DATABASE_URL"))
  should.be_true(string.contains(msg, "NEXUS_PG_"))

  let assert Error(_) =
    migrate.pg_config_from_env(
      pool,
      env_lookup([#("DATABASE_URL", "not-a-url")]),
    )

  let assert Error(bad_port) =
    migrate.pg_config_from_env(
      pool,
      env_lookup([#("NEXUS_PG_PORT", "not-an-int")]),
    )
  should.be_true(string.contains(bad_port, "NEXUS_PG_PORT"))

  let assert Error(_) =
    migrate.pg_config_from_env(pool, env_lookup([#("NEXUS_PG_PORT", "0")]))
}
