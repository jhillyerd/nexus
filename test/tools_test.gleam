//// Tools registry tests: the `default_names` / `by_names` split (bots
//// plan P2 prep, #76). Pins the config-gated default selection, the
//// config-INDEPENDENT catalog resolution (a snapshot pins its tools past
//// later config gating), loud failure on unknown names, and codemode's
//// last-position sibling capture being per-toolset.

import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option
import gleam/string
import gleeunit/should
import nexus/config
import nexus/delivery
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
  tools.default_names(enabled)
  |> should.equal(["http_fetch", "codemode"])
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
    tools.ToolCtx(cancel: process.new_subject(), delivery: option.None),
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
      tools.ToolCtx(cancel: process.new_subject(), delivery: option.None),
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

// ---- fixtures -------------------------------------------------------------

/// A ToolCtx whose delivery closures are the given fakes.
fn with_fake_delivery(
  sender_name sender_name: Result(String, Nil),
  deliver deliver: fn(delivery.Request) -> Result(delivery.Reply, String),
  next next: fn(tools.ToolCtx) -> a,
) -> a {
  let ctx =
    tools.ToolCtx(
      cancel: process.new_subject(),
      delivery: option.Some(
        delivery.Delivery(
          thread_id: "s9",
          bot_id: "b1",
          depth: 2,
          deliver: deliver,
          sender_name: fn() { sender_name },
        ),
      ),
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
