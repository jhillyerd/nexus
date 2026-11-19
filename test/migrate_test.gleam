//// Unit tests for the schema-script statement splitter in
//// `nexus/store/migrate`. The splitter must only split on top-level `;`,
//// ignoring semicolons inside quotes and comments — the trap for future
//// `DO $$ ... $$` blocks, `CREATE FUNCTION` bodies, and literals.

import gleam/bit_array
import gleam/list
import gleam/string
import gleeunit/should
import nexus/store/migrate

/// Same test-only file read the M3 golden prefix test uses (fixtures
/// and repo files are read relative to the repo root, where `gleam
/// test` runs).
@external(erlang, "nexus_loop_test_ffi", "read_file")
fn read_file(path: String) -> BitArray

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

/// The squashed schema shape (pre-deploy squash): `sql/schema.sql` is
/// the ENTIRE schema — plain idempotent CREATEs, no ALTER/DO migration
/// shims (nothing is deployed anywhere, so a shape change is an edit to
/// the CREATEs, not a new shim). The REAL file runs through the
/// splitter — not a pasted copy, which could drift from the schema
/// without failing this test. Every statement must LEAD with `create`
/// (trimmed, lowercased — catches any `DO $$` block, tagged or not, and
/// any `ALTER`, however spelled or wrapped), and the
/// tags provenance columns (`tags_manual`, `tags_source`, utility-tags
/// plan §3.4) must live INLINE in the `thread` CREATE TABLE — a
/// reintroduced DO-block shim fails here. The splitter's dollar-quote
/// handling (an inner `;` inside `$$` bodies) stays covered
/// synthetically by `semicolon_in_literal_inside_dollar_quote_test`.
pub fn schema_is_the_entire_schema_test() {
  let assert Ok(schema) = read_file("sql/schema.sql") |> bit_array.to_string
  let statements = migrate.statements(schema)
  // 21 = 18 (the node_grant era) + per-thread node names: the
  // node_thread_name index replacing node_name, plus the deployed-db
  // column migration (the DROP INDEX + the DO block), plus the bot
  // name CI re-index (#127): the DROP of the plain (name) index before
  // the functional lower(name) UNIQUE replaces it.
  should.equal(list.length(statements), 21)
  // The non-CREATE statements: the manifest swap (plugin-api Phase 2)
  // — a DO block that backfills the old plain-name column into
  // thread_toolset entries before dropping it, lossless for existing
  // rows, skipped entirely on a database already migrated — and the
  // node scoping pair: the old global index's DROP and the DO block
  // that adds node.thread_id (no backfillable thread: pre-scoping rows
  // die, re-pair mints fresh). (The environments Phase 1 column landed
  // as a CREATE-only edit, per the squash-migrations-into-the-base-
  // CREATEs policy, cecd906 — the bot-channels plan's
  // parent_thread_id + thread_channel index did too.)
  let non_create =
    list.filter(statements, fn(stmt) {
      !string.starts_with(string.trim(string.lowercase(stmt)), "create")
    })
  should.equal(list.length(non_create), 4)
  let assert [swap] =
    list.filter(non_create, fn(stmt) {
      string.contains(string.lowercase(stmt), "drop column toolset")
    })
  should.be_true(string.contains(string.lowercase(swap), "do $$"))
  should.be_true(string.contains(
    string.lowercase(swap),
    "information_schema.columns",
  ))
  let assert [_drop_node_name] =
    list.filter(non_create, fn(stmt) {
      string.contains(string.lowercase(stmt), "drop index if exists node_name")
    })
  // The bot-name CI re-index (#127): drop the plain (name) index, then
  // the functional lower(name) UNIQUE replaces it — and match the
  // DEFINITION, so a regression to a plain (name) index fails here.
  let assert [_drop_bot_name] =
    list.filter(non_create, fn(stmt) {
      string.contains(string.lowercase(stmt), "drop index if exists bot_name")
    })
  let assert [bot_name_index] =
    list.filter(statements, fn(stmt) {
      string.contains(string.lowercase(stmt), "index if not exists bot_name")
    })
  let bot_index_lower = string.lowercase(bot_name_index)
  should.be_true(string.contains(bot_index_lower, "unique"))
  should.be_true(string.contains(bot_index_lower, "on bot (lower(name))"))
  // And the DROP precedes the CREATE — the schema depends on the order:
  // swapped, the plain (name) CREATE would claim the bot_name slot and
  // the DROP would then delete it, landing on NO unique index at all.
  let indexed = list.index_map(statements, fn(stmt, i) { #(i, stmt) })
  let assert Ok(#(drop_at, _)) =
    indexed
    |> list.find(fn(p) {
      string.contains(string.lowercase(p.1), "drop index if exists bot_name")
    })
  let assert Ok(#(create_at, _)) =
    indexed
    |> list.find(fn(p) {
      string.contains(string.lowercase(p.1), "index if not exists bot_name")
    })
  should.be_true(drop_at < create_at)
  let assert [node_scoping] =
    list.filter(non_create, fn(stmt) {
      let lower = string.lowercase(stmt)
      string.contains(lower, "do $$")
      && string.contains(lower, "table_name = 'node'")
      && string.contains(lower, "set not null")
    })
  should.be_true(string.contains(
    string.lowercase(node_scoping),
    "on delete cascade",
  ))
  // The scoped index replaced the global one — match the DEFINITION,
  // not just the name, so a regression to node(name) fails here.
  let assert [node_index] =
    list.filter(statements, fn(stmt) {
      string.contains(string.lowercase(stmt), "node_thread_name")
    })
  let index_lower = string.lowercase(node_index)
  should.be_true(string.contains(index_lower, "unique"))
  should.be_true(string.contains(index_lower, "on node (thread_id, name)"))
  let assert [thread_create] =
    list.filter(statements, fn(stmt) { string.contains(stmt, "tags_manual") })
  should.be_true(string.contains(thread_create, "tags_source"))
  should.be_true(string.contains(
    string.lowercase(thread_create),
    "create table",
  ))
}

/// …and the one trap that shape adds beyond the existing `$$` coverage:
/// a `;` inside a single-quoted literal INSIDE a dollar-quoted body (a
/// future column default like `';'::text`, say) must stay inside the
/// statement — quote tracking inside `$$` may not flip on the inner
/// quotes.
pub fn semicolon_in_literal_inside_dollar_quote_test() {
  migrate.statements(
    "do $$ begin alter table t add c text default 'a;b'; end $$;select 2;",
  )
  |> should.equal([
    "do $$ begin alter table t add c text default 'a;b'; end $$",
    "select 2",
  ])
}
