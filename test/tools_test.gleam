//// Tools registry tests: the `default_names` / `by_names` split (bots
//// plan P2 prep, #76). Pins the config-gated default selection, the
//// config-INDEPENDENT catalog resolution (a snapshot pins its tools past
//// later config gating), loud failure on unknown names, and codemode's
//// last-position sibling capture being per-toolset.

import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/string
import gleeunit/should
import nexus/config
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
  spec.run(tools.ToolCtx(cancel: process.new_subject()), arguments)
}

/// The host list is built from THIS by_names list, not the config default:
/// with SearxNG unconfigured the default toolset has no web_search, so a
/// default-sourced host list would answer `unknown tool` — the resolved
/// executor's own error proves the per-toolset capture (name-order
/// assertions alone cannot catch that regression).
pub fn codemode_hosts_come_from_the_requested_toolset_test() {
  let assert Ok(specs) = tools.by_names(plain(), ["web_search", "codemode"])
  let assert Error(result) =
    run_toolset_codemode(specs, "tools.web_search({query = 'x'})")
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
