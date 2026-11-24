//// Live-Postgres differential contract runner (`docs/plans/verification.md`,
//// Phase 1).
////
//// Invoked explicitly (never from offline `gleam test`):
////
////     DATABASE_URL=postgres://nexus@127.0.0.1:5433/nexus \
////       gleam run -m nexus/store/verify
////
//// Runs every case from `nexus/store/contract` plus Postgres-specific checks
//// (non-UTC connection `TimeZone = 'Asia/Tokyo'` epoch invariance and
//// `persist` actor restart mid-conversation after multi-call turns) against
//// the real `nexus/store/persist` actor and all 48 generated SQL queries.
////
//// Isolation guarantee: creates a dedicated temporary schema
//// (`nexus_verify_<us>`), pins `search_path` to it, applies `sql/migrations/`
//// inside that schema, truncates only that schema's tables between cases, and
//// drops the schema on exit — so running locally against a dev database
//// never touches rows in `public`.

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import nexus/bot
import nexus/node
import nexus/store
import nexus/store/contract
import nexus/store/migrate
import nexus/store/persist
import nexus/thread
import nexus/timing
import nexus/tools
import nexus/transcript
import pog

@external(erlang, "nexus_store_ffi", "database_url")
fn database_url() -> Result(String, Nil)

@external(erlang, "nexus_store_ffi", "with_pool_settled")
fn with_pool_settled(run: fn() -> Nil, queue: process.Pid) -> Nil

@external(erlang, "nexus_store_ffi", "stop_verify_actor")
fn stop_verify_actor(
  actor_pid: process.Pid,
  pool_name: process.Name(pog.Message),
) -> Nil

@external(erlang, "nexus_store_ffi", "with_cleanup")
fn with_cleanup(run: fn() -> a, cleanup: fn() -> Nil) -> a

pub fn main() -> Nil {
  let url = or_panic(database_url(), "DATABASE_URL is not set")
  let schema =
    "nexus_verify_" <> int.to_string(int.absolute_value(timing.now_us()))

  // Admin pool (default search_path): creates and drops the isolated schema.
  let admin_pool_name = process.new_name("nexus_verify_admin")
  let admin_cfg =
    or_panic(pog.url_config(admin_pool_name, url), "invalid DATABASE_URL")
    |> pog.pool_size(1)
    |> pog.connection_parameter("timezone", "UTC")
  let admin =
    or_panic(
      pog.start(admin_cfg),
      "could not connect to Postgres — is the database up?",
    )

  with_pool_settled(
    fn() {
      or_panic(
        exec_ddl(admin.data, "CREATE SCHEMA " <> schema),
        "failed to create isolated verify schema " <> schema,
      )
      let outcome =
        with_cleanup(fn() { run_suite_in_schema(url, schema) }, fn() {
          case
            exec_ddl(
              admin.data,
              "DROP SCHEMA IF EXISTS " <> schema <> " CASCADE",
            )
          {
            Ok(Nil) -> Nil
            Error(err) ->
              io.println(
                "store/verify: WARNING failed to drop schema "
                <> schema
                <> " — "
                <> string.inspect(err),
              )
          }
        })
      case outcome {
        Ok(count) ->
          io.println(
            "store/verify: "
            <> int.to_string(count)
            <> " passed, 0 failed (schema "
            <> schema
            <> " cleaned up)",
          )
        Error(failures) -> {
          io.println(
            "store/verify: FAILED ("
            <> int.to_string(list.length(failures))
            <> " failures)",
          )
          list.each(failures, fn(msg) { io.println("  FAIL: " <> msg) })
          panic as "store/verify failed"
        }
      }
    },
    admin.pid,
  )
}

fn run_suite_in_schema(
  url: String,
  schema: String,
) -> Result(Int, List(String)) {
  // Migrate the isolated schema using the real production migration runner.
  let schema_pool_name = process.new_name("nexus_verify_schema")
  let schema_cfg =
    or_panic(pog.url_config(schema_pool_name, url), "invalid DATABASE_URL")
    |> pog.pool_size(1)
    |> pog.connection_parameter("timezone", "UTC")
    |> pog.connection_parameter("search_path", schema)
  let schema_pool =
    or_panic(pog.start(schema_cfg), "could not connect schema pool")

  let mut_result = {
    migrate.apply_to_db(schema_pool_name, schema_pool.data)

    // Run every shared differential contract case against a fresh persist actor.
    let shared_results =
      list.map(contract.cases(), fn(c) {
        or_panic(
          truncate_all(schema_pool.data, schema),
          "truncate failed before " <> c.name,
        )
        let res = run_with_persist(url, schema, "UTC", c.run)
        report_case(c.name, res)
      })

    // Postgres-specific check 1: non-UTC connection TimeZone invariance.
    or_panic(
      truncate_all(schema_pool.data, schema),
      "truncate failed before postgres_non_utc_timezone_invariance",
    )
    let tz_res =
      run_with_persist(
        url,
        schema,
        "Asia/Tokyo",
        check_non_utc_timezone_invariance,
      )
      |> report_case("postgres_non_utc_timezone_invariance", _)

    // Postgres-specific check 2: persist actor restart mid-conversation after
    // a multi-call turn (re-derives watermark from DB and preserves seq).
    or_panic(
      truncate_all(schema_pool.data, schema),
      "truncate failed before postgres_persist_restart_multi_call",
    )
    let restart_res =
      check_persist_restart_multi_call(url, schema)
      |> report_case("postgres_persist_restart_multi_call", _)

    let all = list.append(shared_results, [tz_res, restart_res])
    let failures =
      list.filter_map(all, fn(item) {
        case item {
          Ok(_) -> Error(Nil)
          Error(msg) -> Ok(msg)
        }
      })
    case failures {
      [] -> Ok(list.length(all))
      _ -> Error(failures)
    }
  }

  // Wait for the schema pool's type server to settle before dropping schema.
  with_pool_settled(fn() { Nil }, schema_pool.pid)
  mut_result
}

fn report_case(name: String, res: Result(Nil, String)) -> Result(Nil, String) {
  case res {
    Ok(Nil) -> {
      io.println("  PASS: " <> name)
      Ok(Nil)
    }
    Error(reason) -> {
      io.println("  FAIL: " <> name <> " — " <> reason)
      Error(name <> ": " <> reason)
    }
  }
}

fn run_with_persist(
  url: String,
  schema: String,
  timezone: String,
  body: fn(store.Store) -> Result(Nil, String),
) -> Result(Nil, String) {
  let pool_name = process.new_name("nexus_verify_persist_pool")
  let actor_name = process.new_name("nexus_verify_persist_actor")
  let pg_cfg =
    or_panic(pog.url_config(pool_name, url), "invalid DATABASE_URL")
    |> pog.pool_size(2)
    |> pog.connection_parameter("timezone", timezone)
    |> pog.connection_parameter("search_path", schema)
  let started =
    or_panic(
      persist.start_with_pg_config(pg_cfg, actor_name, schema),
      "could not start persist actor",
    )
  let seam = persist.seam(started.data)
  let outcome = body(seam)
  stop_verify_actor(started.pid, pool_name)
  outcome
}

/// Truncate every migrated application table in `schema` (discovered
/// dynamically from `pg_tables` and schema-qualified so future migrations
/// cannot escape truncation and `public` can never be touched).
fn truncate_all(
  db: pog.Connection,
  schema: String,
) -> Result(Nil, pog.QueryError) {
  let table_decoder = {
    use name <- decode.field(0, decode.string)
    decode.success(name)
  }
  use returned <- result.try(
    "SELECT tablename FROM pg_tables WHERE schemaname = $1 AND tablename <> 'schema_migration' ORDER BY tablename"
    |> pog.query
    |> pog.parameter(pog.text(schema))
    |> pog.returning(table_decoder)
    |> pog.execute(db),
  )
  case returned.rows {
    [] -> Ok(Nil)
    tables -> {
      let qualified =
        tables
        |> list.map(fn(t) { schema <> "." <> t })
        |> string.join(", ")
      exec_ddl(db, "TRUNCATE " <> qualified <> " CASCADE")
    }
  }
}

fn exec_ddl(db: pog.Connection, sql: String) -> Result(Nil, pog.QueryError) {
  sql
  |> pog.query
  |> pog.returning(decode.dynamic)
  |> pog.execute(db)
  |> result.replace(Nil)
}

// ---------------------------------------------------------------------------
// Postgres-specific invariant checks
// ---------------------------------------------------------------------------

/// Verify that `timestamptz` epoch round-trips AND server-side `now()` writes
/// (`bump_activity`, `touch_node`, `touch_node_grant`, `update_provider`,
/// `update_bot`) are completely invariant when the Postgres connection runs in
/// `Asia/Tokyo` (+9h / 32,400s offset) — regression guard for the Phase 2
/// naive-timestamp +9h drift hazard documented in `AGENTS.md`.
fn check_non_utc_timezone_invariance(s: store.Store) -> Result(Nil, String) {
  let fixed_epoch = 1_700_000_000
  let now = timing.wall_now_s()

  let p =
    store.StoredProvider(
      id: "p-tz",
      name: "tokyo-test",
      base_url: "http://tz.test/v1",
      api_key_encrypted: None,
      key_version: 1,
      dialect: "openai",
      enabled: True,
      created_at: fixed_epoch,
      updated_at: fixed_epoch,
    )
  use _ <- result.try(s.insert_provider(p))
  use got_p <- result.try(s.get_provider("p-tz"))
  use _ <- result.try(check_eq(
    "provider created_at",
    got_p.created_at,
    fixed_epoch,
  ))

  let b =
    bot.Bot(
      id: "b-tz",
      name: "TokyoBot",
      description: "",
      provider_id: "p-tz",
      model: "alias-1",
      system_prompt: None,
      tools: None,
      allow_inbound: True,
      created_at: fixed_epoch,
      updated_at: fixed_epoch,
    )
  use _ <- result.try(s.insert_bot(b))
  use got_b <- result.try(s.get_bot("b-tz"))
  use _ <- result.try(check_eq("bot created_at", got_b.created_at, fixed_epoch))

  let summary =
    store.StoredSummary(
      id: "t-tz",
      provider_id: "p-tz",
      model: "alias-1",
      meta: thread.ThreadMeta(
        title: "",
        title_source: thread.AutoTitle,
        pinned: False,
        tags: [],
        tags_manual: [],
        tags_source: thread.AutoTags,
        archived: False,
        bot_id: Some("b-tz"),
        parent_thread_id: None,
        created_at: fixed_epoch,
      ),
      toolset: [
        tools.ToolsetEntry(
          name: "web_search",
          description: "",
          schema_json: None,
        ),
      ],
      workspace_root: None,
      workspaces: None,
      roster: None,
      last_active_at: fixed_epoch,
      message_count: 1,
    )
  use _ <- result.try(s.insert_thread(summary, "sys"))
  use got_t <- result.try(s.get_thread("t-tz"))
  use _ <- result.try(check_eq(
    "thread created_at",
    got_t.summary.meta.created_at,
    fixed_epoch,
  ))
  use _ <- result.try(check_eq(
    "thread last_active_at",
    got_t.summary.last_active_at,
    fixed_epoch,
  ))

  // Commit a stamped turn -> verifies both explicit to_timestamp($n) and
  // server-side now() in bump_activity stay within 120s of wall_now_s (never +32400s).
  let tr =
    transcript.new("alias-1", "sys")
    |> transcript.append_user("konnichiwa")
    |> transcript.stamp(fixed_epoch + 42)
    |> transcript.append_assistant("hello")
    |> transcript.stamp(fixed_epoch + 43)
  s.commit("t-tz", tr)
  use rows <- result.try(s.load_messages("t-tz"))
  use _ <- result.try(
    check_eq("stamped rows", rows, [
      store.UserRow("konnichiwa", None, 0, Some(fixed_epoch + 42)),
      store.AssistantRow("hello", None, Some(fixed_epoch + 43)),
    ]),
  )
  use bumped <- result.try(s.get_thread("t-tz"))
  use _ <- result.try(check_near_now(
    "bump_activity last_active_at",
    bumped.summary.last_active_at,
    now,
  ))

  // Touch a node and a grant under Asia/Tokyo and verify server-side now().
  let n =
    node.Node(
      id: "n-tz",
      thread_id: "t-tz",
      name: "box",
      token_hash: "h",
      created_at: fixed_epoch,
      last_seen_at: None,
    )
  use _ <- result.try(s.insert_node(n))
  use _ <- result.try(s.touch_node("n-tz"))
  use got_n <- result.try(s.get_thread_node("t-tz", "box"))
  case got_n.last_seen_at {
    Some(ts) -> check_near_now("touch_node last_seen_at", ts, now)
    None -> Error("touch_node last_seen_at was None")
  }
}

/// Verify that restarting the `persist` actor mid-conversation (losing its
/// in-memory `persisted` watermark cache) after a multi-call turn still
/// computes the exact next `seq` on the following turn without colliding or
/// dropping rows.
fn check_persist_restart_multi_call(
  url: String,
  schema: String,
) -> Result(Nil, String) {
  let tr1 =
    transcript.new("alias-1", "sys")
    |> transcript.append_user("first")
    |> transcript.stamp(1_700_000_010)
    |> transcript.append_assistant_tool_calls(
      text: Some("calling"),
      calls: [
        #("c1", "web_search", "{\"q\":\"a\"}"),
        #("c2", "web_search", "{\"q\":\"b\"}"),
      ],
      reasoning: Some("thinking"),
    )
    |> transcript.stamp(1_700_000_011)
    |> transcript.append_tool_result("c1", "r1", True)
    |> transcript.append_tool_result("c2", "r2", True)
    |> transcript.append_assistant("done 1")
    |> transcript.stamp(1_700_000_012)

  // Actor 1: seed thread + commit multi-call Turn 1.
  use _ <- result.try(
    run_with_persist(url, schema, "UTC", fn(s) {
      use _ <- result.try(
        s.insert_provider(store.StoredProvider(
          id: "p1",
          name: "p1",
          base_url: "http://p1.test/v1",
          api_key_encrypted: None,
          key_version: 1,
          dialect: "openai",
          enabled: True,
          created_at: 1_700_000_000,
          updated_at: 1_700_000_000,
        )),
      )
      use _ <- result.try(s.insert_thread(
        store.StoredSummary(
          id: "t-restart",
          provider_id: "p1",
          model: "alias-1",
          meta: thread.ThreadMeta(
            title: "",
            title_source: thread.AutoTitle,
            pinned: False,
            tags: [],
            tags_manual: [],
            tags_source: thread.AutoTags,
            archived: False,
            bot_id: None,
            parent_thread_id: None,
            created_at: 1_700_000_000,
          ),
          toolset: [
            tools.ToolsetEntry(
              name: "web_search",
              description: "",
              schema_json: None,
            ),
          ],
          workspace_root: None,
          workspaces: None,
          roster: None,
          last_active_at: 1_700_000_000,
          message_count: 1,
        ),
        "sys",
      ))
      s.commit("t-restart", tr1)
      use rows <- result.try(s.load_messages("t-restart"))
      check_eq("actor 1 persisted 6 rows", list.length(rows), 6)
    }),
  )

  // Actor 2 (fresh empty in-memory persisted cache): commit Turn 2 directly
  // without calling load_messages first, forcing ensure_persisted to re-derive
  // from Postgres `thread.message_count`.
  let tr2 =
    tr1
    |> transcript.append_user("second")
    |> transcript.stamp(1_700_000_020)
    |> transcript.append_assistant("done 2")
    |> transcript.stamp(1_700_000_021)

  run_with_persist(url, schema, "UTC", fn(s) {
    s.commit("t-restart", tr2)
    use rows <- result.try(s.load_messages("t-restart"))
    use _ <- result.try(check_eq("actor 2 has all 8 rows", list.length(rows), 8))
    let hydrated = store.transcript_from_rows("alias-1", "sys", rows)
    check_eq(
      "hydrated request body byte-identical across persist restart",
      transcript.request_body(hydrated, transcript.default_options()),
      transcript.request_body(tr2, transcript.default_options()),
    )
  })
}

fn check_eq(label: String, actual: a, expected: a) -> Result(Nil, String) {
  case actual == expected {
    True -> Ok(Nil)
    False ->
      Error(
        label
        <> ": expected "
        <> string.inspect(expected)
        <> ", got "
        <> string.inspect(actual),
      )
  }
}

fn check_near_now(label: String, actual: Int, now: Int) -> Result(Nil, String) {
  let diff = int.absolute_value(actual - now)
  case diff <= 120 {
    True -> Ok(Nil)
    False ->
      Error(
        label
        <> ": drifted "
        <> int.to_string(diff)
        <> "s from wall clock (actual="
        <> int.to_string(actual)
        <> ", now="
        <> int.to_string(now)
        <> ")",
      )
  }
}

fn or_panic(result: Result(a, e), context: String) -> a {
  case result {
    Ok(value) -> value
    Error(err) -> {
      io.println("store/verify: " <> context <> " — " <> string.inspect(err))
      panic as "store/verify failed"
    }
  }
}
