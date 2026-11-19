//// Tools registry tests: the `default_names` / `by_names` split (bots
//// plan P2 prep, #76). Pins the config-gated default selection, the
//// config-INDEPENDENT catalog resolution (a snapshot pins its tools past
//// later config gating), loud failure on unknown names, and codemode's
//// last-position sibling capture being per-toolset.

import gleam/dict
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/string
import gleeunit/should
import nexus/config
import nexus/delivery
import nexus/tool_provider
import nexus/tools

/// A config from env overrides; only `NEXUS_ENCRYPTION_KEY` is required,
/// everything else keeps its default (no SearxNG, codemode off).
fn cfg(overrides: List(#(String, String))) -> config.Config {
  let assert Ok(cfg) =
    config.from_env(fn(name) {
      case list.key_find(overrides, name) {
        Ok(value) -> Ok(value)
        Error(_) ->
          case name {
            "NEXUS_ENCRYPTION_KEY" ->
              Ok("MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=")
            _ -> Error(Nil)
          }
      }
    })
  cfg
}

fn plain() -> config.Config {
  cfg([])
}

fn names(specs: List(tools.ToolSpec)) -> List(String) {
  list.map(specs, tools.tool_name)
}

// ---- default_names: the config-gated selection ---------------------------

pub fn default_names_minimal_test() {
  tools.default_names(plain()) |> should.equal(["http_fetch"])
}

pub fn default_names_searxng_gate_test() {
  let configured = cfg([#("NEXUS_SEARXNG_BASE_URL", "http://127.0.0.1:8888")])
  tools.default_names(configured)
  |> should.equal(["http_fetch", "web_search"])
}

pub fn default_names_codemode_gate_test() {
  let enabled = cfg([#("NEXUS_CODEMODE", "true")])
  // Sorted catalog order; codemode's SCHEMA still registers last in
  // `by_names_with` wherever the name sits.
  tools.default_names(enabled)
  |> should.equal(["codemode", "http_fetch"])
}

/// The env tools join the default exactly when a workspace root exists
/// to freeze (the same usability gate a create applies to explicit env
/// names), and stay out otherwise — the amended environments-plan rule.
pub fn default_names_env_gate_test() {
  let rooted = cfg([#("NEXUS_WORKSPACE_ROOT", "/srv/workspaces")])
  tools.default_names(rooted)
  |> should.equal([
    "bash",
    "http_fetch",
    "list_dir",
    "read_file",
    "write_file",
  ])
}

/// Everything usable on: the full catalog minus `bot_message` (the
/// registry injects it into bot threads itself), in sorted catalog
/// order — a future compiled tool joins the default automatically
/// unless it needs its own gate line in `default_names`.
pub fn default_names_everything_usable_test() {
  let everything =
    cfg([
      #("NEXUS_CODEMODE", "true"),
      #("NEXUS_SEARXNG_BASE_URL", "http://127.0.0.1:8888"),
      #("NEXUS_WORKSPACE_ROOT", "/srv/workspaces"),
    ])
  tools.default_names(everything)
  |> should.equal([
    "bash",
    "codemode",
    "http_fetch",
    "list_dir",
    "read_file",
    "web_search",
    "write_file",
  ])
  // And the m3 golden's exact envelope is untouched by the widening:
  // the smoke shape (SearxNG on, no codemode, no root) resolves to the
  // same two names, same order, the fixture was captured with.
  let smoke = cfg([#("NEXUS_SEARXNG_BASE_URL", "https://searx.example")])
  tools.default_names(smoke) |> should.equal(["http_fetch", "web_search"])
}

// ---- default: the boot-frozen registry -----------------------------------

pub fn default_resolves_its_own_names_test() {
  let config = plain()
  // `default` is exactly `default_names` through `by_names` — the split
  // changed the shape, not the boot-frozen list (m3_prefix_test's golden
  // depends on it byte-for-byte).
  let assert Ok(specs) = tools.by_names(config, tools.default_names(config))
  tools.default(config) |> names |> should.equal(names(specs))
  tools.default(config) |> names |> should.equal(["http_fetch"])
}

// ---- by_names: the config-independent catalog ----------------------------

pub fn by_names_unknown_name_fails_loudly_test() {
  // A snapshot naming a tool that no longer exists in the compiled code
  // must never be silently dropped (no-silent-fallback philosophy).
  tools.by_names(plain(), ["http_fetch", "phased_out"])
  |> should.equal(Error("unknown tool name: phased_out"))
}

pub fn by_names_dedupes_test() {
  // A toolset is a set: one name, one schema.
  let assert Ok(specs) = tools.by_names(plain(), ["http_fetch", "http_fetch"])
  names(specs) |> should.equal(["http_fetch"])
}

pub fn by_names_empty_test() {
  // The no-tools envelope is omission (bots plan P2): an empty name list
  // resolves to an empty spec list, nothing more.
  tools.by_names(plain(), []) |> should.equal(Ok([]))
}

pub fn by_names_codemode_lands_last_wherever_named_test() {
  // Codemode always registers LAST, capturing every other tool in the
  // list as its hosts — its position in the name list is irrelevant to
  // the built envelope.
  let assert Ok(specs) = tools.by_names(plain(), ["codemode", "http_fetch"])
  names(specs) |> should.equal(["http_fetch", "codemode"])
}

pub fn by_names_ignores_config_gates_test() {
  // The freeze overrides the gate: a snapshot that pinned web_search or
  // codemode keeps resolving them even after the config gates flip off
  // (disabling codemode globally cannot brick threads that pinned it).
  let assert Ok(specs) =
    tools.by_names(plain(), ["web_search", "codemode", "http_fetch"])
  // Specs build in the snapshot's GIVEN order; only codemode itself is
  // canonicalized to last.
  names(specs) |> should.equal(["web_search", "http_fetch", "codemode"])
}

// ---- the pinnable catalog (issue #121) -------------------------------

/// `catalog_names` is the ONE list: every name `is_compiled_name`
/// accepts, in sorted display order, and nothing else — a future
/// compiled tool cannot drift the registration guard away from the
/// picker's checkbox list.
pub fn catalog_names_match_is_compiled_name_test() {
  let names = tools.catalog_names()
  // The plain M3 four plus the four environment tools, at least.
  should.be_true(list.length(names) >= 8)
  list.each(names, fn(name) { tools.is_compiled_name(name) |> should.be_true })
  should.equal(names, list.sort(list.unique(names), string.compare))
  // Qualified names are never compiled names (the reserved separator).
  tools.is_compiled_name("nexus_example__echo") |> should.be_false
  tools.is_compiled_name("nope") |> should.be_false
}

/// tools.catalog (issue #121): compiled + plugin names enumerate
/// without any ask; a mounted server contributes its QUALIFIED tool
/// names through the live ListTools ask; a dead server degrades into
/// `unavailable` (display honesty — its names still pass the save-side
/// gate while mounted).
pub fn catalog_enumerates_compiled_plugin_and_foreign_test() {
  let server =
    start_fake_mcp([
      tool_provider.ToolDef("echo", "echoes", "{}"),
      tool_provider.ToolDef("ping", "pings", "{}"),
    ])
  let dead = process.new_name("nexus_tools_test_dead")
  // Any spec value serves — the enumeration reads the provider table's
  // KEYS, never its specs.
  let assert Ok([spec, ..]) = tools.by_names(plain(), ["http_fetch"])
  let catalog =
    tools.catalog(
      dict.from_list([#("nexus_example__echo", spec)]),
      dict.from_list([
        #("mcpsrv", tools.ForeignServer(name: server, timeout_ms: 1000)),
        #("dead", tools.ForeignServer(name: dead, timeout_ms: 1000)),
      ]),
      // Standard collect budget: every asker self-bounds inside the
      // freeze budget, so the real deadline only guards a wedged asker.
      tools.freeze_ask_ms + 2000,
    )
  catalog.names
  |> should.equal([
    "bash",
    "bot_message",
    "codemode",
    "http_fetch",
    "list_bots",
    "list_dir",
    "mcpsrv__echo",
    "mcpsrv__ping",
    "nexus_example__echo",
    "read_file",
    "web_search",
    "write_file",
  ])
  catalog.unavailable |> should.equal(["dead"])
}

/// The deadline-expiry path: a server whose asker never replies in
/// time joins `unavailable` BY NAME — the picker omits its tools AND
/// says so. A tiny collect deadline keeps the test fast; the asker's
/// eventual reply lands on the (caller-owned, undrained) subject and
/// is dropped.
pub fn catalog_deadline_reports_silent_server_test() {
  let silent = start_silent_mcp()
  let catalog =
    tools.catalog(
      dict.new(),
      dict.from_list([
        #("slow", tools.ForeignServer(name: silent, timeout_ms: 1000)),
      ]),
      50,
    )
  catalog.names |> should.equal(tools.catalog_names())
  catalog.unavailable |> should.equal(["slow"])
}

/// A minimal MCP-shaped fake: a named actor answering ListTools with a
/// fixed catalog (tool_provider_test's fake, reduced to the arm the
/// catalog enumeration exercises).
/// Same shape, but answers NOTHING — the ListTools ask runs out its
/// own clock inside the asker (which the real deadline outpaces here).
fn start_silent_mcp() -> process.Name(tool_provider.Msg) {
  let name = process.new_name("nexus_tools_test_silent")
  let assert Ok(_started) =
    actor.new(Nil)
    |> actor.on_message(fn(state, _msg) { actor.continue(state) })
    |> actor.named(name)
    |> actor.start
  name
}

fn start_fake_mcp(
  defs: List(tool_provider.ToolDef),
) -> process.Name(tool_provider.Msg) {
  let name = process.new_name("nexus_tools_test_mcp")
  let assert Ok(_started) =
    actor.new(defs)
    |> actor.on_message(fn(defs, msg) {
      case msg {
        tool_provider.ListTools(reply) -> {
          process.send(reply, Ok(defs))
          actor.continue(defs)
        }
        _ -> actor.continue(defs)
      }
    })
    |> actor.named(name)
    |> actor.start
  name
}

// ---- codemode's host list is the TOOLSET, not the global default ------

/// Run the registered codemode spec of a per-toolset list — the registry
/// bridge under test (mirrors codemode_test's `run_registered`).
fn run_toolset_codemode(
  specs: List(tools.ToolSpec),
  code: String,
) -> Result(String, String) {
  let assert Ok(spec) =
    list.find(specs, fn(spec) { tools.tool_name(spec) == "codemode" })
  let arguments = json.object([#("code", json.string(code))]) |> json.to_string
  spec.run(
    tools.ToolCtx(
      cancel: process.new_subject(),
      delivery: option.None,
      environment: option.None,
    ),
    arguments,
  )
}

/// The host list is built from THIS by_names list, not the config default:
/// with SearxNG unconfigured the default toolset has no web_search, so a
/// default-sourced host list would answer `unknown tool` — the resolved
/// executor's own error proves the per-toolset capture (name-order
/// assertions alone cannot catch that regression).
pub fn codemode_hosts_come_from_the_requested_toolset_test() {
  let assert Ok(specs) = tools.by_names(plain(), ["web_search", "codemode"])
  let assert Error(result) =
    run_toolset_codemode(specs, "await(tools.web_search({query = 'x'}))")
  should.be_true(string.contains(result, "Script failed ("))
  // The configured executor RAN (its guard fired) — not `unknown tool`.
  should.be_true(string.contains(
    result,
    "web_search: SearxNG is not configured",
  ))
}

/// The sibling boundary is the toolset itself: a codemode-only toolset
/// captures zero hosts, so a host call reaches the unknown-tool path —
/// the script still runs (pure Lua executes; only the host call fails).
pub fn codemode_only_toolset_has_no_sibling_hosts_test() {
  let assert Ok(specs) = tools.by_names(plain(), ["codemode"])
  let assert Error(result) =
    run_toolset_codemode(specs, "tools.http_fetch({url = 'https://x'})")
  should.be_true(string.contains(result, "Script failed ("))
  should.be_true(string.contains(result, "unknown tool: http_fetch"))
}

// ---- bot_message: the delivery tool (bots plan P3c, #97) ------------------

/// The catalog carries bot_message, but the HUMAN default toolset never
/// selects it: a plain thread has no bot identity to send from.
pub fn bot_message_in_catalog_not_in_default_test() {
  let assert Ok(specs) = tools.by_names(plain(), ["bot_message"])
  names(specs) |> should.equal(["bot_message"])
  tools.default_names(plain())
  |> list.contains("bot_message")
  |> should.be_false
}

/// Without a delivery context the executor errors honestly — reachable
/// only through a hand-built toolset naming the tool on a plain thread
/// (snapshots persist what they were created with).
pub fn bot_message_without_delivery_ctx_errors_test() {
  let assert Ok([spec]) = tools.by_names(plain(), ["bot_message"])
  let assert Error(reason) =
    spec.run(
      tools.ToolCtx(
        cancel: process.new_subject(),
        delivery: option.None,
        environment: option.None,
      ),
      "{\"to\":\"x\",\"text\":\"y\"}",
    )
  should.equal(
    reason,
    "bot_message: this thread has no bot identity to send from",
  )
}

/// The happy path through FAKE delivery closures: the sender's current
/// display name is asked at send time, the request carries the ctx's
/// identity + depth, and the receipt names the target and thread.
pub fn bot_message_receipt_test() {
  use ctx <- with_fake_delivery(
    sender_name: Ok("alpha"),
    deliver: fn(request: delivery.Request) {
      // The request shape: sender identity + this turn's hop depth.
      should.equal(request.from_bot_id, "b1")
      should.equal(request.from_bot_name, "alpha")
      should.equal(request.from_thread_id, "s9")
      should.equal(request.depth, 2)
      should.equal(request.to, "beta")
      should.equal(request.text, "hello")
      Ok(delivery.Delivered("s12"))
    },
  )
  let assert Ok([spec]) = tools.by_names(plain(), ["bot_message"])
  let assert Ok(content) = spec.run(ctx, "{\"to\":\"beta\",\"text\":\"hello\"}")
  should.be_true(string.contains(content, "delivered to beta in thread s12"))
}

/// Guard refusals and a busy target render as FAILED tool results (tool
/// errors are not loop errors) — the sender model sees them and adapts.
pub fn bot_message_refused_and_busy_render_as_errors_test() {
  let assert Ok([spec]) = tools.by_names(plain(), ["bot_message"])
  use ctx <- with_fake_delivery(
    sender_name: Ok("alpha"),
    deliver: fn(_request: delivery.Request) {
      Ok(delivery.Refused("unknown target"))
    },
  )
  let assert Error(reason) = spec.run(ctx, "{\"to\":\"x\",\"text\":\"y\"}")
  should.equal(reason, "bot_message refused: unknown target")

  use ctx <- with_fake_delivery(
    sender_name: Ok("alpha"),
    deliver: fn(_request: delivery.Request) { Ok(delivery.Busy) },
  )
  let assert Error(reason) = spec.run(ctx, "{\"to\":\"x\",\"text\":\"y\"}")
  should.be_true(string.contains(reason, "is mid-turn"))

  // The delivery ASK itself failing (timeout) is honest unknown-outcome
  // content: a blind retry could duplicate the message.
  use ctx <- with_fake_delivery(
    sender_name: Ok("alpha"),
    deliver: fn(_request: delivery.Request) { option.None |> fail_ask },
  )
  let assert Error(reason) = spec.run(ctx, "{\"to\":\"x\",\"text\":\"y\"}")
  should.be_true(string.contains(reason, "outcome unknown"))
  should.be_true(string.contains(reason, "may still have been delivered"))
}

/// A deleted sender bot is an honest tool error from the ask-at-send
/// name lookup; malformed arguments never reach the delivery ask.
pub fn bot_message_sender_gone_and_bad_args_test() {
  let assert Ok([spec]) = tools.by_names(plain(), ["bot_message"])
  use ctx <- with_fake_delivery(
    sender_name: option.None |> fail_name,
    deliver: fn(_request: delivery.Request) { panic as "must not be asked" },
  )
  let assert Error(reason) = spec.run(ctx, "{\"to\":\"x\",\"text\":\"y\"}")
  should.equal(
    reason,
    "bot_message: the sender bot is unavailable (deleted, or the registry"
      <> " ask timed out)",
  )

  use ctx <- with_fake_delivery(
    sender_name: Ok("alpha"),
    deliver: fn(_request: delivery.Request) { panic as "must not be asked" },
  )
  // Missing text.
  let assert Error(reason) = spec.run(ctx, "{\"to\":\"x\"}")
  should.be_true(string.contains(reason, "invalid bot_message arguments"))
  // Empty text.
  let assert Error(reason) = spec.run(ctx, "{\"to\":\"x\",\"text\":\"   \"}")
  should.be_true(string.contains(reason, "non-empty"))
}

// ---- list_bots: the discovery tool (#127) ---------------------------------

/// The catalog carries list_bots, but the HUMAN default toolset never
/// selects it — the registry injects it into bot-default threads itself,
/// exactly like `bot_message`.
pub fn list_bots_in_catalog_not_in_default_test() {
  should.be_true(tools.is_compiled_name("list_bots"))
  let assert Ok([spec]) = tools.by_names(plain(), ["list_bots"])
  should.equal(tools.tool_name(spec), "list_bots")
  tools.default_names(plain())
  |> list.contains("list_bots")
  |> should.be_false
}

/// Without a delivery context the executor errors honestly — same
/// reachable-only-through-a-hand-built-toolset shape as `bot_message`.
pub fn list_bots_without_delivery_ctx_errors_test() {
  let assert Ok([spec]) = tools.by_names(plain(), ["list_bots"])
  let assert Error(reason) =
    spec.run(
      tools.ToolCtx(
        cancel: process.new_subject(),
        delivery: option.None,
        environment: option.None,
      ),
      "{}",
    )
  should.equal(reason, "list_bots: this thread has no bot identity to list for")
}

/// The receipt names every bot with its exact display name, marks the
/// sender, and carries the inbound gate in the delivery guard's own
/// vocabulary. A failed registry ask is an honest tool error; an empty
/// registry says so plainly.
pub fn list_bots_receipt_test() {
  let assert Ok([spec]) = tools.by_names(plain(), ["list_bots"])

  let roster = [
    delivery.BotListing(name: "alpha", bot_id: "b1", allow_inbound: True),
    delivery.BotListing(name: "Beta", bot_id: "b2", allow_inbound: False),
  ]
  use ctx <- with_fake_delivery_list_bots(
    sender_name: Ok("alpha"),
    deliver: fn(_request: delivery.Request) { panic as "must not be asked" },
    list_bots: fn() { Ok(roster) },
  )
  let assert Ok(content) = spec.run(ctx, "{}")
  should.be_true(string.contains(content, "- alpha (you): accepts bot messages"))
  should.be_true(string.contains(
    content,
    "- Beta: does NOT accept bot messages",
  ))

  // The ask failing (registry down or timed out) — honest retryable
  // error, never a fabricated empty roster.
  use ctx <- with_fake_delivery_list_bots(
    sender_name: Ok("alpha"),
    deliver: fn(_request: delivery.Request) { panic as "must not be asked" },
    list_bots: fn() { Error(Nil) },
  )
  let assert Error(reason) = spec.run(ctx, "{}")
  should.be_true(string.contains(reason, "registry is unavailable"))

  // An empty registry: nobody to message, not a tool failure.
  use ctx <- with_fake_delivery_list_bots(
    sender_name: Ok("alpha"),
    deliver: fn(_request: delivery.Request) { panic as "must not be asked" },
    list_bots: fn() { Ok([]) },
  )
  let assert Ok(content) = spec.run(ctx, "{}")
  should.be_true(string.contains(content, "no bots exist yet"))
}

// ---- fixtures -------------------------------------------------------------

/// A ToolCtx whose delivery closures are the given fakes.
fn with_fake_delivery(
  sender_name sender_name: Result(String, Nil),
  deliver deliver: fn(delivery.Request) -> Result(delivery.Reply, String),
  next next: fn(tools.ToolCtx) -> a,
) -> a {
  with_fake_delivery_list_bots(
    sender_name: sender_name,
    deliver: deliver,
    list_bots: fn() { Error(Nil) },
    next: next,
  )
}

/// The same rig with a fake bot roster (the `list_bots` tool's ask).
fn with_fake_delivery_list_bots(
  sender_name sender_name: Result(String, Nil),
  deliver deliver: fn(delivery.Request) -> Result(delivery.Reply, String),
  list_bots list_bots: fn() -> Result(List(delivery.BotListing), Nil),
  next next: fn(tools.ToolCtx) -> a,
) -> a {
  let ctx =
    tools.ToolCtx(
      cancel: process.new_subject(),
      environment: option.None,
      delivery: option.Some(delivery.Delivery(
        thread_id: "s9",
        bot_id: "b1",
        depth: 2,
        deliver: deliver,
        sender_name: fn() { sender_name },
        list_bots: list_bots,
      )),
    )
  next(ctx)
}

fn fail_ask(
  _: option.Option(delivery.Reply),
) -> Result(delivery.Reply, String) {
  Error("delivery ask timed out")
}

fn fail_name(_: option.Option(String)) -> Result(String, Nil) {
  Error(Nil)
}

// ---------------------------------------------------------------------------
// Environments plan Phase 1
// ---------------------------------------------------------------------------

// The four env tools are compiled names, but NEVER in the default set —
// a config flip must not change the default envelope.
pub fn env_names_never_in_default_test() {
  let names = tools.default_names(cfg([#("NEXUS_CODEMODE", "true")]))
  should.be_false(list.contains(names, "bash"))
  should.be_false(list.contains(names, "read_file"))
  should.be_false(list.contains(names, "write_file"))
  should.be_false(list.contains(names, "list_dir"))
  should.be_true(tools.is_compiled_name("bash"))
  should.be_true(tools.is_compiled_name("read_file"))
  should.be_true(tools.is_compiled_name("write_file"))
  should.be_true(tools.is_compiled_name("list_dir"))
}

// Env names resolve through the catalog like any compiled name —
// config-INDEPENDENT (a snapshot pins past the gate; the create-time
// refusal is the registry's, not the catalog's).
pub fn by_names_resolves_env_tools_test() {
  let assert Ok(specs) =
    tools.by_names(plain(), ["bash", "read_file", "write_file", "list_dir"])
  should.equal(list.map(specs, tools.tool_name), [
    "bash",
    "read_file",
    "write_file",
    "list_dir",
  ])
}

// Without a handle in the ctx, an env tool errors honestly (the
// bot_message-on-a-plain-thread rule) — never a crash.
pub fn env_tool_without_handle_errors_test() {
  let assert Ok(specs) = tools.by_names(plain(), ["bash"])
  let assert [spec] = specs
  let assert Error("this thread has no environment attached") =
    spec.run(
      tools.ToolCtx(
        cancel: process.new_subject(),
        delivery: option.None,
        environment: option.None,
      ),
      "{\"target\":\"workspace\",\"command\":\"echo hi\"}",
    )
}
