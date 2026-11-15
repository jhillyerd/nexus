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
//// default one. The plugin-api plan (Phase 1) widens the catalog to
//// compiled ∪ providers: `by_names_with` also resolves the boot-built
//// provider table (`ProviderTable`, built by `nexus/plugin` from each
//// provider actor's `ListTools`), so a plugin's qualified tools
//// (`<provider>__<tool>`) behave exactly like compiled names —
//// resolvable offline, snapshot-pinnable, loudly refused when stale —
//// while never entering the DEFAULT set (config gates a provider's
//// availability, never default membership; the default envelope
//// cannot change under config drift).

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import glopenai/chat.{type ChatCompletionTool}
import glopenai/shared.{FunctionObject}
import nexus/codemode
import nexus/config.{type Config}
import nexus/delivery.{type Delivery}
import nexus/http_fetch
import nexus/tool_provider
import nexus/web_search

/// Per-turn context handed to every executor alongside the raw arguments.
/// `cancel` is the turn's cancel subject (owned by the per-turn worker):
/// a `Stop` during tool execution delivers `Nil` to it. Interruptible
/// executors (codemode) select on it so a script dies mid-run; every
/// other tool simply ignores it, exactly as before the seam existed.
/// `delivery` is the bot-to-bot delivery identity (bots plan P3c, #97):
/// `Some` only on threads created from a bot, injected by the registry's
/// per-thread runner wrapper — the `bot_message` executor's only source
/// of identity (a plain thread has no bot to send from).
pub type ToolCtx {
  ToolCtx(cancel: Subject(Nil), delivery: Option(Delivery))
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

/// The boot-built provider half of the catalog (plugin-api plan):
/// qualified wire name (`<provider>__<tool>`) → spec, with the
/// executor addressing its provider actor BY NAME. Built once at boot
/// from each provider's `ListTools` and handed to the surfaces that
/// resolve names (`thread_registry`, the bot registry's validation
/// closure) — the same resolution path as compiled names, so plugin
/// tools are snapshot-pinnable by bots and refuse loudly when stale.
/// An empty table is exactly the pre-plugin catalog.
pub type ProviderTable =
  Dict(String, ToolSpec)

/// One configured MCP server's mount (plugin-api plan Phase 2): the
/// minted registered name of its adapter actor — threaded as a VALUE
/// from boot, never re-derived — plus the server's resolved per-call
/// deadline. MCP tools resolve through this map, never the provider
/// table: their schemas freeze at create-time into the thread
/// manifest, so a spec is built from FROZEN text, not from a boot
/// snapshot (`foreign_spec`).
pub type ForeignServer {
  ForeignServer(name: process.Name(tool_provider.Msg), timeout_ms: Int)
}

/// One entry of a thread's persisted toolset manifest — the ordered
/// snapshot replacing the plain name list (plugin-api plan Phase 2).
/// `None` schema: a plain in-process name (compiled or plugin — its
/// schema lives in code). `Some(schema_json)`: a FOREIGN entry — an
/// MCP tool whose schema was validated and canonicalized at create,
/// frozen byte-stable; hydration replays this text and never contacts
/// the server. The list order IS the envelope order.
/// One entry of a thread's persisted toolset manifest — the ordered
/// snapshot replacing the plain name list (plugin-api plan Phase 2).
/// `schema_json = None`: a plain in-process name (compiled or plugin —
/// its schema and description live in code, and `description` is
/// unused). `Some(schema_json)`: a FOREIGN entry — an MCP tool whose
/// schema AND description were validated and canonicalized at create,
/// frozen byte-stable (both ride the request envelope, so both must
/// survive restarts identical); hydration replays this text and never
/// contacts the server. The list order IS the envelope order.
pub type ToolsetEntry {
  ToolsetEntry(name: String, description: String, schema_json: Option(String))
}

/// The create-time freeze's `ListTools` ask budget (plugin-api plan
/// Phase 2). STRICTLY SMALLER than the registry create wrapper's
/// 5-second `actor.call` budget (the HTTP/UI caller's clock): the
/// registry actor blocks on this ask, and a freeze that outlived its
/// caller would let a thread materialize after the caller had already
/// seen a timeout — a zombie create. A healthy server answers in
/// milliseconds; the boot ask (no caller, no budget) stays at 10 s.
pub const freeze_ask_ms = 4000

/// The complete compiled-in tool name set. Plugin-api plan: `__` is
/// the reserved provider separator, so a compiled name containing it
/// would admit a colliding qualified name — `is_compiled_name` is the
/// registration-time guard's lookup, and every future compiled tool
/// must keep its name `__`-free.
pub fn is_compiled_name(name: String) -> Bool {
  case name {
    "http_fetch" | "web_search" | "bot_message" | "codemode" -> True
    _ -> False
  }
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
  by_names_with(cfg, dict.new(), names)
}

/// The full catalog resolution (plugin-api plan Phase 1): compiled ∪
/// providers. A name is looked up in the compiled set first, then in
/// the boot-built provider table — disjoint by construction (qualified
/// names contain `__`, compiled names never do), so the order is
/// cosmetic. Everything else is `by_names`'s contract unchanged:
/// unique names in list order, an unknown name fails loudly, codemode
/// registers LAST over the full sibling list — provider tools included,
/// so a script can call them like any sibling.
pub fn by_names_with(
  cfg: Config,
  providers: ProviderTable,
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
        "bot_message" -> Ok([bot_message_spec()])
        // Codemode is built last below, over the full sibling list.
        "codemode" -> Ok([])
        other ->
          case dict.get(providers, other) {
            Ok(spec) -> Ok([spec])
            Error(Nil) -> Error(other)
          }
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

/// The full ENTRY resolution (plugin-api plan Phase 2): compiled ∪
/// providers ∪ foreign. `by_names_with`'s contract, extended one rung:
/// a `ToolsetEntry` with no schema resolves like a plain name (compiled
/// dispatch, then the provider table); a FOREIGN entry builds its spec
/// from the FROZEN canonical schema text — hydration's path, which
/// never contacts the server — with the executor addressing the
/// server's adapter actor by name. Unknown names fail loudly exactly
/// as before; a foreign entry naming an unmounted server fails loudly
/// too (hydration must never silently narrow). Codemode registers LAST
/// over the assembled spec list, foreign tools included, so a script
/// can call them like any sibling.
pub fn by_entries_with(
  cfg cfg: Config,
  providers providers: ProviderTable,
  foreign foreign: Dict(String, ForeignServer),
  entries entries: List(ToolsetEntry),
) -> Result(List(ToolSpec), String) {
  // A toolset is a set: duplicates would send one schema twice and
  // make the entry tuple → envelope mapping order-dependent.
  let names = list.map(entries, fn(entry) { entry.name })
  case list.length(names) == list.length(list.unique(names)) {
    False -> Error("duplicate tool name in toolset")
    True -> {
      let built =
        list.try_map(entries, fn(entry) {
          // A schema on a plain (compiled/plugin) name is a corrupt
          // manifest row: refused loudly, never silently ignored (the
          // check runs outside the dispatch, whose guards cannot call
          // functions).
          let plain_with_schema = case entry.schema_json {
            None -> False
            Some(_) ->
              tools_is_compiled_name(entry.name)
              || dict.has_key(providers, entry.name)
          }
          case plain_with_schema {
            True ->
              Error(Reason("corrupt manifest entry '" <> entry.name <> "'"))
            False -> dispatch_entry(cfg, providers, foreign, entry)
          }
        })
      case built {
        Error(UnknownName(name)) -> Error("unknown tool name: " <> name)
        Error(Reason(text)) -> Error(text)
        Ok(groups) -> {
          let specs = list.flatten(groups)
          // Codemode registers LAST wherever its name sat in the
          // entries — capturing the sibling list it may call, foreign
          // tools included, itself structurally absent from them.
          case list.contains(names, "codemode") {
            True -> Ok(list.append(specs, [codemode_spec(specs, cfg)]))
            False -> Ok(specs)
          }
        }
      }
    }
  }
}

/// One entry's dispatch (the corruption pre-check in `by_entries_with`
/// has already filtered schema-on-plain-name rows).
fn dispatch_entry(
  cfg: Config,
  providers: ProviderTable,
  foreign: Dict(String, ForeignServer),
  entry: ToolsetEntry,
) -> Result(List(ToolSpec), ResolutionError) {
  case entry {
    ToolsetEntry("http_fetch", _, _) -> Ok([fetch_spec(cfg)])
    ToolsetEntry("web_search", _, _) -> Ok([web_search_spec(cfg)])
    ToolsetEntry("bot_message", _, _) -> Ok([bot_message_spec()])
    // Codemode is built last below, over the full sibling list.
    ToolsetEntry("codemode", _, _) -> Ok([])
    ToolsetEntry(name, _, None) ->
      case dict.get(providers, name) {
        Ok(spec) -> Ok([spec])
        Error(Nil) -> Error(UnknownName(name))
      }
    ToolsetEntry(name, description, Some(schema_json)) ->
      case tool_provider.split(name) {
        Error(Nil) ->
          // A foreign entry whose name carries no reserved
          // separator is a corrupt manifest row, not a
          // resolution miss: refused loudly, never narrowed.
          Error(Reason(
            "frozen entry '" <> name <> "' has no reserved separator",
          ))
        Ok(#(server, tool)) ->
          case dict.get(foreign, server) {
            Error(Nil) ->
              Error(Reason("mcp server '" <> server <> "' is not available"))
            Ok(server_mount) ->
              // Belt-and-braces: the frozen text was validated
              // at freeze; a corrupted row refuses hydration
              // loudly rather than encoding garbage.
              case tool_provider.valid_parameters(schema_json) {
                True ->
                  Ok([
                    foreign_spec(
                      cfg: cfg,
                      qualified: name,
                      description: description,
                      tool: tool,
                      server: server_mount,
                      schema_json: schema_json,
                    ),
                  ])
                False ->
                  Error(Reason(
                    "frozen schema for '"
                    <> name
                    <> "' failed boundary validation",
                  ))
              }
          }
      }
  }
}

/// `by_entries_with`'s internal error vocabulary: a name the catalog
/// does not know (the loud `by_names` wording) versus a foreign entry
/// with its own reason text (already phrased for the operator).
type ResolutionError {
  UnknownName(String)
  Reason(String)
}

fn tools_is_compiled_name(name: String) -> Bool {
  is_compiled_name(name)
}

/// The FOREIGN spec executor (plugin-api plan Phase 2): identical to a
/// plugin spec's — the executor addresses its adapter actor BY NAME
/// (the pre-minted value from `ForeignServer`) through the SAME select
/// loop (`tool_provider.run`), deadline, monitor, cancel re-signal and
/// all — but the wire schema is the FROZEN canonical text, not live
/// catalog state. A server that died after create renders the honest
/// tool error; nothing about the frozen envelope changes.
pub fn foreign_spec(
  cfg cfg: Config,
  qualified qualified: String,
  description description: String,
  tool tool: String,
  server server: ForeignServer,
  schema_json schema_json: String,
) -> ToolSpec {
  ToolSpec(
    tool: function_tool(
      name: qualified,
      description: description,
      parameters_json: schema_json,
    ),
    run: fn(ctx, arguments) {
      tool_provider.run(
        provider: server.name,
        tool: tool,
        timeout_ms: server.timeout_ms,
        max_output_chars: cfg.plugin_max_output_chars,
        cancel: ctx.cancel,
        arguments: arguments,
      )
    },
  )
}

/// The bot-to-bot delivery tool (bots plan P3c, #97). Never part of the
/// HUMAN default toolset — a plain thread has no bot identity to send
/// from, so its executor errors honestly if a hand-built toolset ever
/// names it. Create-from-bot with `bot.tools = NULL` resolves to the
/// human default PLUS this name (the registry's bot-default transform),
/// so ordinary bots get the feature without listing it; a bot that wants
/// it gone names an explicit list without it. The executor is a thin
/// adapter over the ctx's `Delivery` closures: resolve the sender's
/// current display name (ask-at-send — renames stay current, a deleted
/// sender is an honest tool error), then ask the thread registry to
/// route + deliver. Async by decision (#77): the result is the receipt —
/// it never waits for the target's turn. Guard refusals and a busy
/// target render as failed tool results (tool errors are not loop
/// errors); the receipt names the thread the conversation landed in.
fn bot_message_spec() -> ToolSpec {
  ToolSpec(
    tool: function_tool(
      name: "bot_message",
      description: "Send an async message to another bot. `to` is the bot's"
        <> " name, or a thread id from a previous bot_message receipt"
        <> " (precise addressing). Returns a receipt naming the thread the"
        <> " message landed in; the target bot answers on its own next turn"
        <> " — replies arrive as user messages prefixed `From <bot> (thread"
        <> " <id>):`. Refused when the target is unknown, archived, has"
        <> " inbound disabled, is yourself, or the hop-depth limit is hit;"
        <> " busy when it is mid-turn (retry then).",
      parameters_json: "{\"type\":\"object\",\"properties\":{\"to\":{\"type\":\"string\","
        <> "\"description\":\"Target bot name, or a thread id (s<N>) from a"
        <> " previous receipt\"},\"text\":{\"type\":\"string\","
        <> "\"description\":\"Message to deliver\"}},\"required\":[\"to\","
        <> "\"text\"],\"additionalProperties\":false}",
    ),
    run: fn(ctx, arguments) { bot_message_run(ctx.delivery, arguments) },
  )
}

fn bot_message_run(
  delivery: Option(Delivery),
  arguments: String,
) -> Result(String, String) {
  case delivery {
    // Only reachable through a hand-built toolset naming the tool on a
    // plain thread (snapshots persist what they were created with): the
    // thread has no bot identity to send from.
    None -> Error("bot_message: this thread has no bot identity to send from")
    Some(d) -> {
      use parsed <- result.try(parse_bot_message_args(arguments))
      use sender <- result.try(case d.sender_name() {
        Ok(name) -> Ok(name)
        Error(Nil) ->
          // Both honest causes: a deleted sender (ON DELETE SET NULL left
          // the thread without a working identity) or an ask that timed
          // out — the model cannot tell them apart, so neither does the
          // error text (cubic PR review).
          Error(
            "bot_message: the sender bot is unavailable (deleted, or the"
            <> " registry ask timed out)",
          )
      })
      let request =
        delivery.Request(
          from_bot_id: d.bot_id,
          from_bot_name: sender,
          from_thread_id: d.thread_id,
          depth: d.depth,
          to: parsed.to,
          text: parsed.text,
        )
      case d.deliver(request) {
        Error(_) ->
          // At-most-once, honestly stated: the timeout means the outcome
          // is UNKNOWN — the registry may have taken the line and be
          // delivering it right now, so a blind retry can duplicate it
          // (cubic PR review).
          Error(
            "bot_message: delivery timed out; outcome unknown — the message"
            <> " may still have been delivered",
          )
        Ok(delivery.Delivered(thread_id)) ->
          Ok(
            "delivered to "
            <> parsed.to
            <> " in thread "
            <> thread_id
            <> " — replies arrive as a user message; address yours to"
            <> " thread "
            <> thread_id
            <> " or the bot's name",
          )
        Ok(delivery.Busy) ->
          Error(
            "bot_message: "
            <> parsed.to
            <> " is mid-turn; try again on its next turn",
          )
        Ok(delivery.Refused(reason)) -> Error("bot_message refused: " <> reason)
      }
    }
  }
}

type BotMessageArgs {
  BotMessageArgs(to: String, text: String)
}

fn parse_bot_message_args(arguments: String) -> Result(BotMessageArgs, String) {
  let decoder = {
    use to <- decode.field("to", decode.string)
    use text <- decode.field("text", decode.string)
    decode.success(BotMessageArgs(to: string.trim(to), text: text))
  }
  case json.parse(arguments, decoder) {
    Ok(args) ->
      case args.to, string.trim(args.text) == "" {
        "", _ | _, True ->
          Error("bot_message requires a non-empty `to` and `text`")
        _, False -> Ok(args)
      }
    Error(_) -> Error("invalid bot_message arguments: {\"to\", \"text\"}")
  }
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
