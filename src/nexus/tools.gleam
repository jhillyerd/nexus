//// The M3 tool registry: model-visible schemas paired with local
//// executors.
////
//// The default list is built **once per process start** from the global
//// config (loaded from the environment before any thread exists — the
//// M3 plan's pre-creation requirement) and handed to the thread runner
//// at boot, so the tool schema sent with every request of the default
//// toolset is frozen for the lifetime of the VM. That keeps request
//// prefixes byte-identical across a thread's turns (KV-cache contract
//// rule 4). The bots plan P2 (#76) splits selection from execution:
//// `default_names` picks the config-gated default set, `by_names`
//// resolves ANY set of compiled-in names — per-toolset, with no config
//// gating — so a thread can carry a toolset snapshot other than the
//// default one.

import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import glopenai/chat.{type ChatCompletionTool}
import glopenai/shared.{FunctionObject}
import nexus/codemode
import nexus/config.{type Config}
import nexus/http_fetch
import nexus/web_search

/// Per-turn context handed to every executor alongside the raw arguments.
/// `cancel` is the turn's cancel subject (owned by the per-turn worker):
/// a `Stop` during tool execution delivers `Nil` to it. Interruptible
/// executors (codemode) select on it so a script dies mid-run; every
/// other tool simply ignores it, exactly as before the seam existed.
pub type ToolCtx {
  ToolCtx(cancel: Subject(Nil))
}

/// One tool: its wire schema plus the executor. `run` receives the
/// per-turn context and the raw arguments JSON string, and returns the
/// tool-result content (already sanitised and truncated) or an error
/// string.
pub type ToolSpec {
  ToolSpec(
    tool: ChatCompletionTool,
    run: fn(ToolCtx, String) -> Result(String, String),
  )
}

/// The default M3 toolset's NAMES, derived from the global config — the
/// selection half of the `default(cfg)` split (bots plan P2 prep, #76).
/// `web_search` is selected only when a SearxNG base URL is configured;
/// `codemode` only when its flag is on — with the flag off the list is
/// exactly the pre-codemode registry (KV-cache contract rule 4). The
/// order here is the wire order of the resolved schemas.
pub fn default_names(cfg: Config) -> List(String) {
  let names = case cfg.searxng_base_url {
    Some(_) -> ["http_fetch", "web_search"]
    None -> ["http_fetch"]
  }
  case cfg.codemode {
    True -> list.append(names, ["codemode"])
    False -> names
  }
}

/// Resolve tool NAMES into specs against the compiled-in catalog — the
/// execution half of the split. Selection is config-INDEPENDENT (bots
/// plan P2: a snapshot pins its tools past later config gating — the
/// freeze overrides the gate), so every name in the compiled catalog
/// builds regardless of today's flags; the config only fills executor
/// constants (limits, timeouts, endpoints). An unknown name fails
/// loudly: a snapshot naming a tool that no longer exists in the code
/// must never be silently dropped.
pub fn by_names(
  cfg: Config,
  names: List(String),
) -> Result(List(ToolSpec), String) {
  // A toolset is a set: duplicates would send one schema twice and make
  // the name tuple → envelope mapping order-dependent.
  let names = list.unique(names)
  let built =
    list.try_map(names, fn(name) {
      case name {
        "http_fetch" -> Ok([fetch_spec(cfg)])
        "web_search" -> Ok([web_search_spec(cfg)])
        // Codemode is built last below, over the full sibling list.
        "codemode" -> Ok([])
        other -> Error(other)
      }
    })
  case built {
    Error(unknown) -> Error("unknown tool name: " <> unknown)
    Ok(groups) -> {
      let specs = list.flatten(groups)
      // Codemode registers LAST wherever its name sat in the list,
      // capturing the sibling list it may call. With per-toolset
      // resolution those siblings are exactly the thread's toolset minus
      // codemode — everything a script can reach — and codemode itself is
      // structurally absent from them (recursion guard).
      case list.contains(names, "codemode") {
        True -> Ok(list.append(specs, [codemode_spec(specs, cfg)]))
        False -> Ok(specs)
      }
    }
  }
}

/// The default M3 toolset: the config-gated default names resolved
/// through the catalog. The default names are all compiled-in, so the
/// unwrap cannot fail — a failure would be a programmer error and crashes
/// loudly at boot (the no-silent-fallback philosophy).
pub fn default(cfg: Config) -> List(ToolSpec) {
  let assert Ok(specs) = by_names(cfg, default_names(cfg))
  specs
}

fn fetch_spec(cfg: Config) -> ToolSpec {
  ToolSpec(
    tool: http_fetch.schema(),
    // ctx-ignoring adapter: http_fetch itself stays a pure fn(String).
    run: fn(_ctx, arguments) {
      http_fetch.run(
        cfg.http_fetch_max_bytes,
        cfg.http_fetch_timeout_ms,
        cfg.http_fetch_allow_private,
      )(arguments)
    },
  )
}

fn web_search_spec(cfg: Config) -> ToolSpec {
  ToolSpec(tool: web_search.schema(), run: fn(_ctx, arguments) {
    // A snapshot can pin web_search past losing the SearxNG config
    // (the freeze overrides the gate); the call then fails loudly at
    // run time — the executor error renders as tool content.
    case cfg.searxng_base_url {
      Some(base) -> {
        web_search.run(base, cfg.searxng_token, cfg.http_fetch_timeout_ms)(
          arguments,
        )
      }
      None -> Error("web_search: SearxNG is not configured")
    }
  })
}

/// The codemode spec over the already-built sibling list. codemode.gleam
/// is a leaf module (no import of this one — Gleam forbids the cycle), so
/// the bridge lives here: hosts are the siblings, and each host call
/// reuses this turn's ToolCtx.
fn codemode_spec(siblings: List(ToolSpec), cfg: Config) -> ToolSpec {
  ToolSpec(tool: codemode.schema(), run: fn(ctx, arguments) {
    let hosts =
      list.map(siblings, fn(spec) {
        codemode.HostTool(name: tool_name(spec), call: fn(args) {
          spec.run(ctx, args)
        })
      })
    codemode.run(
      hosts,
      cfg.codemode_timeout_ms,
      cfg.codemode_max_output_chars,
      ctx.cancel,
      arguments,
    )
  })
}

/// The wire schemas, in registry order — this exact list goes into every
/// request.
pub fn schemas(specs: List(ToolSpec)) -> List(ChatCompletionTool) {
  list.map(specs, fn(spec: ToolSpec) { spec.tool })
}

/// Execute a call by tool name. Unknown tools and failing executors both
/// produce an error rendered as tool content by the agent loop.
pub fn execute(
  specs: List(ToolSpec),
  ctx: ToolCtx,
  name: String,
  arguments: String,
) -> Result(String, String) {
  case list.find(specs, fn(spec: ToolSpec) { tool_name(spec) == name }) {
    Error(_) -> Error("unknown tool: " <> name)
    Ok(spec) -> spec.run(ctx, arguments)
  }
}

pub fn tool_name(spec: ToolSpec) -> String {
  let chat.FunctionTool(function: function) = spec.tool
  function.name
}

/// Build a function schema from raw JSON parameter-schema text.
pub fn function_tool(
  name name: String,
  description description: String,
  parameters_json parameters_json: String,
) -> ChatCompletionTool {
  let parameters = case json.parse(parameters_json, decode.dynamic) {
    Ok(dynamic) -> Some(dynamic)
    Error(_) -> None
  }
  chat.FunctionTool(function: FunctionObject(
    name: name,
    description: Some(description),
    parameters: parameters,
    strict: None,
  ))
}
