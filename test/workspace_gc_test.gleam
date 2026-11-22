//// Offline unit tests for workspace tracking, guarded recursive deletion,
//// cascade tombstoning, prune tombstoning, and crash-safe boot GC
//// (`docs/plans/workspace-sandbox.md`, Phase 1).

import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/factory_supervisor
import gleam/string
import gleeunit/should
import nexus/bot
import nexus/config
import nexus/env
import nexus/log
import nexus/openai
import nexus/store
import nexus/store/persist
import nexus/thread
import nexus/thread_registry
import nexus/timing
import nexus/workspace_gc
import simplifile
import store_mock

fn fresh_root(tag: String) -> String {
  "/tmp/nexus-wsgc-" <> tag <> "-" <> int.to_string(timing.now_us())
}

fn test_config(root: String) -> config.Config {
  config.Config(
    encryption_key: "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=",
    sse_first_response_timeout_ms: 1000,
    stream_idle_timeout_ms: 1000,
    http_bind: "127.0.0.1",
    http_port: 8080,
    ui_token: None,
    system_prompt: "test system prompt",
    max_tool_iterations: 8,
    http_fetch_max_bytes: 20_000,
    http_fetch_timeout_ms: 2000,
    http_fetch_allow_private: False,
    web_fetch_max_raw_bytes: 1_048_576,
    web_fetch_max_decompressed_bytes: 8_388_608,
    web_fetch_default_chars: 12_000,
    web_fetch_max_chars: 32_000,
    web_fetch_cache_ttl_ms: 600_000,
    searxng_base_url: None,
    searxng_token: None,
    pg_host: "127.0.0.1",
    pg_port: 5433,
    pg_database: "nexus",
    pg_user: "nexus",
    pg_password: None,
    utility_enabled: False,
    utility_delay_ms: 1500,
    codemode: False,
    codemode_timeout_ms: 30_000,
    codemode_max_output_chars: 32_768,
    plugins: [],
    plugin_timeout_ms: 30_000,
    plugin_max_output_chars: 32_768,
    mcp_servers: [],
    workspace_root: Some(root),
    env_timeout_ms: 60_000,
    env_max_output_bytes: 262_144,
    node_idle_days: 0,
    log_level: log.Info,
    max_bot_hops: 4,
  )
}

fn fresh_meta(
  parent: option.Option(String),
  created_at: Int,
) -> thread.ThreadMeta {
  thread.ThreadMeta(
    title: "",
    title_source: thread.AutoTitle,
    pinned: False,
    tags: [],
    tags_manual: [],
    tags_source: thread.AutoTags,
    archived: False,
    bot_id: Some(store_mock.fixture_bot_id),
    parent_thread_id: parent,
    created_at: created_at,
  )
}

fn env_summary(
  id: String,
  root: String,
  parent: option.Option(String),
  last_active_at: Int,
  message_count: Int,
) -> store.StoredSummary {
  store.StoredSummary(
    id: id,
    provider_id: store_mock.fixture_provider_id,
    model: "alpha",
    meta: fresh_meta(parent, last_active_at),
    toolset: thread_registry.plain_entries(["bash"]),
    workspace_root: Some(root),
    workspaces: Some(store.ThreadWorkspaces(
      workspace_id: "ws-thread-" <> id,
      rel_path: "threads/" <> id,
      tmp_id: Some("ws-tmp-" <> id),
      tmp_rel_path: Some("tmp/" <> id),
    )),
    roster: Some(#(
      env.roster_attach_text("workspace", env.attached_targets()),
      last_active_at,
    )),
    last_active_at: last_active_at,
    message_count: message_count,
  )
}

// ---------------------------------------------------------------------------
// Path-safety guard (workspace_gc.safe_target_path & remove_dir)
// ---------------------------------------------------------------------------

pub fn safe_target_path_accepts_descendants_and_refuses_escapes_test() {
  // Valid structured & legacy relative paths.
  workspace_gc.safe_target_path("/srv/ws", "threads/s1")
  |> should.equal(Ok("/srv/ws/threads/s1"))
  workspace_gc.safe_target_path("/srv/ws/", "tmp/s1")
  |> should.equal(Ok("/srv/ws/tmp/s1"))
  workspace_gc.safe_target_path("/srv/ws", "s1")
  |> should.equal(Ok("/srv/ws/s1"))

  // Blank / whitespace.
  workspace_gc.safe_target_path("", "threads/s1") |> should.be_error
  workspace_gc.safe_target_path("   ", "threads/s1") |> should.be_error
  workspace_gc.safe_target_path("/srv/ws", "") |> should.be_error
  workspace_gc.safe_target_path("/srv/ws", "   ") |> should.be_error

  // Non-absolute or '/' root, or root with '..'.
  workspace_gc.safe_target_path("srv/ws", "threads/s1") |> should.be_error
  workspace_gc.safe_target_path("/", "tmp") |> should.be_error
  workspace_gc.safe_target_path("/srv/ws/../etc", "threads/s1")
  |> should.be_error

  // Absolute rel_path, '..' traversal, or root-identical '.'.
  workspace_gc.safe_target_path("/srv/ws", "/etc/passwd") |> should.be_error
  workspace_gc.safe_target_path("/srv/ws", "../escape") |> should.be_error
  workspace_gc.safe_target_path("/srv/ws", "threads/../../escape")
  |> should.be_error
  workspace_gc.safe_target_path("/srv/ws", ".") |> should.be_error
  workspace_gc.safe_target_path("/srv/ws", "./.") |> should.be_error

  // NUL bytes.
  workspace_gc.safe_target_path("/srv/ws", "threads/s1\u{0}")
  |> should.be_error
}

pub fn remove_dir_deletes_tree_and_treats_enoent_as_ok_test() {
  let root = fresh_root("rm")
  let nested = root <> "/threads/s1/sub"
  let assert Ok(Nil) = simplifile.create_directory_all(nested)
  let assert Ok(Nil) = simplifile.write(nested <> "/file.txt", "hello")

  workspace_gc.remove_dir(root, "threads/s1") |> should.equal(Ok(Nil))
  simplifile.is_directory(root <> "/threads/s1") |> should.equal(Ok(False))

  // Idempotent on absent directory (lazy creation / crash retry).
  workspace_gc.remove_dir(root, "threads/s1") |> should.equal(Ok(Nil))
  workspace_gc.remove_dir(root, "threads/never-created")
  |> should.equal(Ok(Nil))

  // Path-traversal refusal touches nothing on disk.
  let sibling = root <> "/keep.txt"
  let assert Ok(Nil) = simplifile.write(sibling, "precious")
  workspace_gc.remove_dir(root, "../" <> string.drop_start(root, 5))
  |> should.be_error
  workspace_gc.remove_dir(root, ".") |> should.be_error
  simplifile.read(sibling) |> should.equal(Ok("precious"))

  let _ = simplifile.delete(root)
  Nil
}

pub fn remove_dir_unlinks_symlink_without_deleting_external_target_test() {
  let root = fresh_root("symlink")
  let outside = fresh_root("outside")
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/threads")
  let assert Ok(Nil) = simplifile.create_directory_all(outside)
  let assert Ok(Nil) = simplifile.write(outside <> "/secret.txt", "keep")
  let assert Ok(Nil) =
    simplifile.create_symlink(outside, root <> "/threads/s-link")

  workspace_gc.remove_dir(root, "threads/s-link") |> should.equal(Ok(Nil))
  // External target directory and its contents survive untouched.
  simplifile.read(outside <> "/secret.txt") |> should.equal(Ok("keep"))

  let _ = simplifile.delete(root)
  let _ = simplifile.delete(outside)
  Nil
}

// ---------------------------------------------------------------------------
// Cascade delete tombstoning + async disk cleanup
// ---------------------------------------------------------------------------

pub fn delete_thread_tombstones_channel_subtree_and_orphaned_bot_workspace_test() {
  let root = fresh_root("cascade")
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  store_mock.ensure_fixture_bot(seam)
  let now = timing.wall_now_s()

  // Seed parent -> child -> grandchild env threads.
  let assert Ok(Nil) =
    seam.insert_thread(env_summary("s1", root, None, now, 3), "sys")
  let assert Ok(Nil) =
    seam.insert_thread(env_summary("s2", root, Some("s1"), now, 3), "sys")
  let assert Ok(Nil) =
    seam.insert_thread(env_summary("s3", root, Some("s2"), now, 3), "sys")

  // Also seed an unrelated thread whose workspace MUST survive.
  let assert Ok(Nil) =
    seam.insert_thread(env_summary("s9", root, None, now, 3), "sys")

  // Seed an orphaned bot workspace (bot_id = None) referenced only by a child
  // thread under s1 (s4), and a second orphaned bot workspace still referenced
  // by surviving thread s10.
  let assert Ok(Nil) =
    seam.insert_workspace(store.StoredWorkspace(
      id: "ws-bot-orphan",
      kind: store.BotWorkspace,
      root: root,
      rel_path: "bots/b-gone",
      thread_id: None,
      bot_id: None,
      created_at: now,
      last_used_at: None,
      deleted_at: None,
    ))
  let assert Ok(Nil) =
    seam.insert_workspace(store.StoredWorkspace(
      id: "ws-bot-shared",
      kind: store.BotWorkspace,
      root: root,
      rel_path: "bots/b-shared",
      thread_id: None,
      bot_id: None,
      created_at: now,
      last_used_at: None,
      deleted_at: None,
    ))

  // Attach s4 (under s3, bot deleted) to ws-bot-orphan, and s5 (under s2,
  // bot deleted) + s10 (unrelated root thread) to ws-bot-shared. Deleting s1
  // must tombstone ws-bot-orphan (zero remaining refs) and KEEP ws-bot-shared
  // (still referenced by s10).
  let orphan_meta = fn(parent) {
    thread.ThreadMeta(..fresh_meta(parent, now), bot_id: None)
  }
  let assert Ok(Nil) =
    seam.insert_thread(
      store.StoredSummary(
        ..env_summary("s4", root, Some("s3"), now, 3),
        meta: orphan_meta(Some("s3")),
        workspaces: Some(store.ThreadWorkspaces(
          workspace_id: "ws-bot-orphan",
          rel_path: "bots/b-gone",
          tmp_id: Some("ws-tmp-s4"),
          tmp_rel_path: Some("tmp/s4"),
        )),
      ),
      "sys",
    )
  let assert Ok(Nil) =
    seam.insert_thread(
      store.StoredSummary(
        ..env_summary("s5", root, Some("s2"), now, 3),
        meta: orphan_meta(Some("s2")),
        workspaces: Some(store.ThreadWorkspaces(
          workspace_id: "ws-bot-shared",
          rel_path: "bots/b-shared",
          tmp_id: Some("ws-tmp-s5"),
          tmp_rel_path: Some("tmp/s5"),
        )),
      ),
      "sys",
    )
  let assert Ok(Nil) =
    seam.insert_thread(
      store.StoredSummary(
        ..env_summary("s10", root, None, now, 3),
        meta: orphan_meta(None),
        workspaces: Some(store.ThreadWorkspaces(
          workspace_id: "ws-bot-shared",
          rel_path: "bots/b-shared",
          tmp_id: None,
          tmp_rel_path: None,
        )),
      ),
      "sys",
    )

  let assert Ok(tombstoned) = seam.delete_thread("s1")
  let ids = list.map(tombstoned, fn(w) { w.id })
  should.equal(ids, [
    "ws-bot-orphan",
    "ws-thread-s1",
    "ws-thread-s2",
    "ws-thread-s3",
    "ws-tmp-s1",
    "ws-tmp-s2",
    "ws-tmp-s3",
    "ws-tmp-s4",
    "ws-tmp-s5",
  ])

  // s9's workspaces and ws-bot-shared (still referenced by s10) remain live.
  let live_ids =
    store_mock.workspaces(mock)
    |> list.filter(fn(w) { option.is_none(w.deleted_at) })
    |> list.map(fn(w) { w.id })
  should.equal(live_ids, ["ws-bot-shared", "ws-thread-s9", "ws-tmp-s9"])

  // delete_workspace refuses to delete a live workspace row.
  let assert Ok(Nil) = seam.delete_workspace("ws-thread-s9")
  let after_live_del =
    store_mock.workspaces(mock)
    |> list.map(fn(w) { w.id })
  should.be_true(list.contains(after_live_del, "ws-thread-s9"))
}

// ---------------------------------------------------------------------------
// Interrupted delete recovery on boot sweep + prune_never_used tombstoning
// ---------------------------------------------------------------------------

pub fn boot_sweep_recovers_interrupted_tombstones_and_pruned_workspaces_test() {
  let root = fresh_root("boot")
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  store_mock.ensure_fixture_bot(seam)

  // 1) Simulate a workspace tombstoned before a crash (directory still on disk).
  let crashed_dir = root <> "/threads/s-crashed"
  let assert Ok(Nil) = simplifile.create_directory_all(crashed_dir)
  let assert Ok(Nil) = simplifile.write(crashed_dir <> "/data.txt", "stale")
  let assert Ok(Nil) =
    seam.insert_workspace(store.StoredWorkspace(
      id: "ws-thread-s-crashed",
      kind: store.ThreadWorkspace,
      root: root,
      rel_path: "threads/s-crashed",
      thread_id: None,
      bot_id: None,
      created_at: 1_700_000_000,
      last_used_at: None,
      deleted_at: Some(1_700_000_100),
    ))

  // 2) Seed an old never-used env thread whose directory exists on disk.
  let old_dir = root <> "/threads/s-old"
  let old_tmp = root <> "/tmp/s-old"
  let assert Ok(Nil) = simplifile.create_directory_all(old_dir)
  let assert Ok(Nil) = simplifile.create_directory_all(old_tmp)
  let assert Ok(Nil) = simplifile.write(old_dir <> "/a.txt", "old")
  let assert Ok(Nil) = simplifile.write(old_tmp <> "/b.txt", "tmp")
  let assert Ok(Nil) =
    seam.insert_thread(
      env_summary("s-old", root, None, 1_700_000_000, 2),
      "sys",
    )

  // 3) Seed a tombstoned workspace with a malicious rel_path: boot sweep must
  // refuse removal and leave the tombstone row untouched (never hard-delete).
  let assert Ok(Nil) =
    seam.insert_workspace(store.StoredWorkspace(
      id: "ws-bad",
      kind: store.ThreadWorkspace,
      root: root,
      rel_path: "../escape",
      thread_id: None,
      bot_id: None,
      created_at: 1_700_000_000,
      last_used_at: None,
      deleted_at: Some(1_700_000_200),
    ))

  // Run prune_never_used (tombstones s-old's workspaces) then boot_sweeps.
  let assert Ok(["s-old"]) = seam.prune_never_used()
  persist.boot_sweeps(test_config(root), seam)

  // All valid tombstoned directories are gone on disk...
  simplifile.is_directory(crashed_dir) |> should.equal(Ok(False))
  simplifile.is_directory(old_dir) |> should.equal(Ok(False))
  simplifile.is_directory(old_tmp) |> should.equal(Ok(False))

  // ...their rows are hard-deleted, while the refused bad tombstone stays.
  let remaining =
    store_mock.workspaces(mock)
    |> list.map(fn(w) { w.id })
  should.equal(remaining, ["ws-bad"])

  let _ = simplifile.delete(root)
  Nil
}

// ---------------------------------------------------------------------------
// Registry create (lazy disk + workspace rows) & delete (async cleanup)
// ---------------------------------------------------------------------------

pub fn registry_create_tracks_workspaces_lazily_and_delete_cleans_disk_test() {
  let root = fresh_root("reg")
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  store_mock.ensure_fixture_bot(seam)

  let factory_name =
    process.new_name("ws_gc_factory_" <> int.to_string(timing.now_us()))
  let assert Ok(_factory) =
    factory_supervisor.start(thread_registry.factory_builder_with_child(
      factory_name,
      thread_registry.thread_child,
    ))
  let resolver = fn(_id) {
    Ok(openai.Endpoint(
      base_url: "http://fixture.test/v1",
      api_key: None,
      sse_first_response_timeout_ms: 1000,
      stream_idle_timeout_ms: 1000,
    ))
  }
  let assert Ok(started) =
    thread_registry.start(
      test_config(root),
      factory_supervisor.get_by_name(factory_name),
      process.new_name("ws_gc_reg_" <> int.to_string(timing.now_us())),
      seam,
      resolver,
      process.new_name("ws_gc_bots_" <> int.to_string(timing.now_us())),
      dict.new(),
      dict.new(),
      None,
    )
  let registry = started.data

  let assert Ok(summary) =
    thread_registry.create(
      registry,
      thread_registry.NewThread(
        provider_id: store_mock.fixture_provider_id,
        model: "alpha",
        system_prompt: None,
        bot_id: store_mock.fixture_bot_id,
        toolset: Some(["bash"]),
        parent_thread_id: None,
        title: "",
      ),
    )

  // Both `thread` and `tmp` workspace rows are persisted atomically...
  let ws_rows = store_mock.workspaces(mock)
  should.equal(list.length(ws_rows), 2)
  let ws_paths = list.map(ws_rows, fn(w) { #(w.kind, w.rel_path) })
  should.equal(ws_paths, [
    #(store.ThreadWorkspace, "threads/" <> summary.id),
    #(store.TmpWorkspace, "tmp/" <> summary.id),
  ])

  // ...while disk creation stays lazy (neither directory exists yet).
  let thread_dir = root <> "/threads/" <> summary.id
  let tmp_dir = root <> "/tmp/" <> summary.id
  simplifile.is_directory(thread_dir) |> should.equal(Ok(False))
  simplifile.is_directory(tmp_dir) |> should.equal(Ok(False))

  // Simulate env tool usage creating files in both directories.
  let assert Ok(Nil) = simplifile.create_directory_all(thread_dir)
  let assert Ok(Nil) = simplifile.create_directory_all(tmp_dir)
  let assert Ok(Nil) = simplifile.write(thread_dir <> "/work.py", "print(1)")
  let assert Ok(Nil) = simplifile.write(tmp_dir <> "/scratch.txt", "tmp")

  // Deleting the thread tombstones both rows and removes both dirs async.
  thread_registry.delete_thread(registry, summary.id) |> should.be_true
  await_no_workspaces(mock, 200)
  simplifile.is_directory(thread_dir) |> should.equal(Ok(False))
  simplifile.is_directory(tmp_dir) |> should.equal(Ok(False))

  let _ = simplifile.delete(root)
  Nil
}

fn await_no_workspaces(
  mock: process.Subject(store_mock.MockMsg),
  patience: Int,
) -> Nil {
  case store_mock.workspaces(mock), patience <= 0 {
    [], _ -> Nil
    _, True -> panic as "timed out waiting for async workspace GC"
    _, False -> {
      process.sleep(10)
      await_no_workspaces(mock, patience - 1)
    }
  }
}

pub fn env_workspace_dir_uses_rel_path_when_present_test() {
  let new_env =
    env.Environment(
      workspace_root: "/srv/ws",
      thread_id: "s5",
      workspace_rel_path: Some("threads/s5"),
      roster: env.attached_targets(),
      remote: None,
    )
  env.workspace_dir(new_env) |> should.equal("/srv/ws/threads/s5")

  let legacy_env =
    env.Environment(
      workspace_root: "/srv/ws",
      thread_id: "s5",
      workspace_rel_path: Some("s5"),
      roster: env.attached_targets(),
      remote: None,
    )
  env.workspace_dir(legacy_env) |> should.equal("/srv/ws/s5")

  // Malformed rel_paths (traversal, absolute, blank, '.') fall back safely
  // to `<root>/<thread_id>` instead of escaping workspace_root.
  list.each(
    ["../etc", "threads/../../etc", "/etc/passwd", "", ".", "./."],
    fn(bad) {
      let bad_env =
        env.Environment(
          workspace_root: "/srv/ws",
          thread_id: "s5",
          workspace_rel_path: Some(bad),
          roster: env.attached_targets(),
          remote: None,
        )
      env.workspace_dir(bad_env) |> should.equal("/srv/ws/s5")
    },
  )
}

pub fn delete_bot_tombstones_unreferenced_workspace_and_preserves_referenced_test() {
  let root = fresh_root("botdel")
  let mock = store_mock.start()
  let seam = store_mock.seam(mock)
  store_mock.ensure_fixture_provider(seam)
  let now = timing.wall_now_s()

  let mk_bot = fn(id, name) {
    bot.Bot(
      id: id,
      name: name,
      description: "",
      provider_id: store_mock.fixture_provider_id,
      model: "alpha",
      system_prompt: None,
      tools: None,
      allow_inbound: True,
      created_at: now,
      updated_at: now,
    )
  }
  let assert Ok(Nil) = seam.insert_bot(mk_bot("b-free", "FreeBot"))
  let assert Ok(Nil) = seam.insert_bot(mk_bot("b-used", "UsedBot"))

  // Direct insert_workspace enforces thread_id and bot_id FKs.
  seam.insert_workspace(store.StoredWorkspace(
    id: "ws-bad-thread",
    kind: store.ThreadWorkspace,
    root: root,
    rel_path: "threads/ghost",
    thread_id: Some("ghost"),
    bot_id: None,
    created_at: now,
    last_used_at: None,
    deleted_at: None,
  ))
  |> should.be_error
  seam.insert_workspace(store.StoredWorkspace(
    id: "ws-bad-bot",
    kind: store.BotWorkspace,
    root: root,
    rel_path: "bots/ghost",
    thread_id: None,
    bot_id: Some("ghost"),
    created_at: now,
    last_used_at: None,
    deleted_at: None,
  ))
  |> should.be_error

  // Seed one unreferenced bot workspace (b-free) and one referenced by s1 (b-used).
  let assert Ok(Nil) =
    seam.insert_workspace(store.StoredWorkspace(
      id: "ws-bot-free",
      kind: store.BotWorkspace,
      root: root,
      rel_path: "bots/b-free",
      thread_id: None,
      bot_id: Some("b-free"),
      created_at: now,
      last_used_at: None,
      deleted_at: None,
    ))
  let assert Ok(Nil) =
    seam.insert_workspace(store.StoredWorkspace(
      id: "ws-bot-used",
      kind: store.BotWorkspace,
      root: root,
      rel_path: "bots/b-used",
      thread_id: None,
      bot_id: Some("b-used"),
      created_at: now,
      last_used_at: None,
      deleted_at: None,
    ))
  let assert Ok(Nil) =
    seam.insert_thread(
      store.StoredSummary(
        ..env_summary("s1", root, None, now, 3),
        meta: thread.ThreadMeta(..fresh_meta(None, now), bot_id: Some("b-used")),
        workspaces: Some(store.ThreadWorkspaces(
          workspace_id: "ws-bot-used",
          rel_path: "bots/b-used",
          tmp_id: None,
          tmp_rel_path: None,
        )),
      ),
      "sys",
    )

  // Deleting b-free tombstones ws-bot-free immediately.
  let assert Ok([tomb]) = seam.delete_bot("b-free")
  should.equal(tomb.id, "ws-bot-free")

  // Deleting b-used keeps ws-bot-used live (bot_id = None) until s1 dies.
  let assert Ok([]) = seam.delete_bot("b-used")
  let assert Ok(live_used) =
    store_mock.workspaces(mock)
    |> list.find(fn(w) { w.id == "ws-bot-used" })
  should.equal(live_used.bot_id, None)
  should.equal(live_used.deleted_at, None)

  // Now deleting s1 tombstones the orphaned ws-bot-used.
  let assert Ok([tomb2]) = seam.delete_thread("s1")
  should.equal(tomb2.id, "ws-bot-used")
}

pub fn await_workers_exit_waits_for_exiting_and_times_out_on_live_worker_test() {
  // Fast-exiting worker drains cleanly.
  let fast = process.spawn_unlinked(fn() { process.sleep(20) })
  workspace_gc.await_workers_exit([fast], 1000) |> should.be_true
  // Already-dead worker drains immediately.
  workspace_gc.await_workers_exit([fast], 100) |> should.be_true

  // Hung worker hits the deadline so caller retains tombstones.
  let stuck = process.spawn_unlinked(fn() { process.sleep(5000) })
  workspace_gc.await_workers_exit([stuck], 40) |> should.be_false
  process.kill(stuck)
}
