//// The M3 tool registry: model-visible schemas paired with local
//// executors.
////
//// The list is built **once per process start** from the global config
//// (loaded from the environment before any session exists — the M3 plan's
//// pre-creation requirement) and handed to the session runner at boot, so
//// the tool schema sent with every request of every session is frozen for
//// the lifetime of the VM. That keeps request prefixes byte-identical
//// across a session's turns (KV-cache contract rule 4).

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

/// The default M3 toolset derived from the global config. `web_search` is
/// registered only when a SearxNG base URL is configured; `codemode` only
/// when its flag is on — with the flag off the schema list is exactly the
/// pre-codemode registry (KV-cache contract rule 4).
pub fn default(cfg: Config) -> List(ToolSpec) {
  let fetch =
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
  let siblings = case cfg.searxng_base_url {
    Some(base) -> [
      fetch,
      ToolSpec(tool: web_search.schema(), run: fn(_ctx, arguments) {
        web_search.run(base, cfg.searxng_token, cfg.http_fetch_timeout_ms)(
          arguments,
        )
      }),
    ]
    None -> [fetch]
  }
  // Codemode registers LAST, capturing the sibling list it may call.
  // The registry is still built once per boot (frozen envelope), and the
  // captured siblings are everything a script can reach — codemode
  // itself is structurally absent from them (recursion guard).
  case cfg.codemode {
    True -> list.append(siblings, [codemode_spec(siblings, cfg)])
    False -> siblings
  }
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
