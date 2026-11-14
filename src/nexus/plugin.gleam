//// The tier-1 plugin SDK + the boot-side catalog assembly (plugin-api
//// plan Phase 1).
////
//// **Tier 1** is for the fetch-shaped plugin: declare a name, ToolDefs,
//// and one synchronous call fn, and `start_named` builds the provider
//// actor FOR you — it spawns an unlinked worker per `Call` (the
//// kill-tree on `Cancelled`), monitors it, and guarantees
//// exactly-one-reply WITHIN THE CALLER'S DEADLINE: a crashed tool
//// worker is answered with `ToolErr("plugin tool crashed")`, a late
//// report after a kill is dropped, and the one nanosecond-scale hole —
//// a call fn crashing in the spawn→monitor arm window yields neither
//// report nor DOWN, so the ADAPTER's deadline answers instead — is
//// bounded by that deadline (a tool error either way, never a hang or
//// a loop error; the pinned gleam_erlang has no spawn-with-monitor to
//// close it). Stateful plugins (a port, a connection, ETS) are tier 2:
//// speak `tool_provider.Msg` in your own actor — the protocol is the
//// whole contract.
////
//// **Boot** (`boot`) is load-mechanism-agnostic on purpose: v1 plugins
//// are compiled into the release and listed by config
//// (`NEXUS_PLUGINS`); a future load mechanism only has to produce the
//// same two things (register the name, speak `Msg`). It starts a
//// separate OneForOne `plugin_sup` tree linked to the caller, then
//// asks each provider `ListTools` ONCE with a short fixed timeout,
//// validates every ToolDef at the boundary (charset, reserved `__`,
//// object-rooted parseable schema under the byte bound, no collisions),
//// and returns the catalog's provider table (`tools.ProviderTable`).
//// Anything wrong fails LOUDLY — a compiled plugin is part of the
//// release — via the same mechanism the root tree relies on: a
//// crash-looping plugin exhausts the supervisor's tolerance, the tree
//// dies, and the linked boot process (or test) goes down with it.
////
//// Why a separate tree rather than a child of the OneForAll root: the
//// table must be ONE value shared by the thread registry's resolution
//// and the bot registry's validation closure, but root-tree children
//// cannot hand values to each other — they only start in order. A
//// linked standalone tree lets boot mint the names once, build the
//// table once, and thread both consumers off the same value.
////
//// Naming mechanics: the actor's PUBLIC address is the pre-minted
//// `Name(tool_provider.Msg)`; the actor's own message type is the
//// superset `SdkMsg` (protocol + internal worker traffic), fed by a
//// custom selector that maps the named subject, a private subject, and
//// monitor downs into it. The initialiser itself performs
//// `process.register` — on supervisor restart the fresh pid re-runs it
//// and re-registers the same atom (the death auto-unregistered it).

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Subject}
import gleam/erlang/reference.{type Reference}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/result
import nexus/config.{type Config}
import nexus/plugins/example
import nexus/tool_provider.{type Plugin, type ToolDef, type ToolReply}
import nexus/tools

/// The boot-time `ListTools` budget: short and fixed so nothing can
/// hang boot — an MCP adapter that will not answer (Phase 2) degrades
/// like an unreachable server, while a compiled plugin failing here
/// fails boot outright.
const boot_ask_ms = 5000

// ---------------------------------------------------------------------------
// Tier 1: the SDK actor (the Plugin declaration lives in `tool_provider`)
// ---------------------------------------------------------------------------

/// One in-flight SDK call: everything needed to answer exactly once or
/// reap it on cancel. The monitor is per-call and demonitored on every
/// non-Down settle.
type Pending {
  Pending(
    reply: Subject(ToolReply),
    worker: process.Pid,
    monitor: process.Monitor,
  )
}

/// The SDK actor's mailbox: the public protocol plus internal worker
/// traffic. The named subject carries `Provider(...)`; the private
/// subject and monitor downs carry `Internal(...)`.
pub type SdkMsg {
  Provider(tool_provider.Msg)
  Internal(Internal)
}

// Public only because `SdkMsg` (the actor's message type) mentions
// it; nothing outside ever constructs or matches these — the named
// subject and the initialiser's selector are the only ways in.
pub type Internal {
  WorkerDone(ref: Reference, outcome: Result(String, String))
  WorkerDown(process.Down)
}

type SdkState {
  SdkState(
    plugin: Plugin,
    pending: Dict(Reference, Pending),
    internal: Subject(Internal),
  )
}

/// Start a tier-1 plugin's provider actor under its pre-minted name.
/// The name is minted ONCE (boot or a test — see `tool_provider.name`)
/// and the caller supervises the actor; under `plugin_sup` a restart
/// re-registers the same name, and executors addressing it by name see
/// at worst a brief "unavailable" window.
pub fn start_named(
  p p: Plugin,
  name name: Name(tool_provider.Msg),
) -> actor.StartResult(Subject(SdkMsg)) {
  actor.new_with_initialiser(5000, fn(self) {
    // The whole-declaration boundary rule (name + timeout override):
    // an invalid plugin refuses to START — loudly, before it can mint
    // ambiguous wire names or a crash-inducing deadline.
    case validate_plugin(p) {
      Error(reason) -> Error(reason)
      Ok(Nil) ->
        // Register HERE, not via `actor.named`: the name's payload type is
        // the protocol's, while this actor's message type is the superset
        // — and re-running on a supervisor restart re-registers the fresh
        // pid (the death auto-unregistered the old one).
        case process.register(process.self(), name) {
          Error(Nil) -> Error("plugin name already registered")
          Ok(Nil) -> {
            let internal = process.new_subject()
            actor.initialised(SdkState(
              plugin: p,
              pending: dict.new(),
              internal: internal,
            ))
            |> actor.returning(self)
            |> actor.selecting(
              process.new_selector()
              // Public protocol via the named subject…
              |> process.select_map(process.named_subject(name), Provider)
              // …worker reports and monitor downs privately.
              |> process.select_map(internal, Internal)
              |> process.select_monitors(fn(down) { Internal(WorkerDown(down)) }),
            )
            |> Ok
          }
        }
    }
  })
  |> actor.on_message(handle)
  |> actor.start
}

fn handle(state: SdkState, msg: SdkMsg) -> actor.Next(SdkState, SdkMsg) {
  case msg {
    Provider(tool_provider.ListTools(reply)) -> {
      process.send(reply, Ok(state.plugin.tools))
      actor.continue(state)
    }

    Provider(tool_provider.Call(ref, tool, arguments, reply)) ->
      case list.find(state.plugin.tools, fn(def) { def.name == tool }) {
        // Unreachable through the catalog (executors are bound to a
        // validated ToolDef); honest refusal if a caller bypasses it.
        Error(Nil) -> {
          process.send(
            reply,
            tool_provider.ToolErr("unknown plugin tool: " <> tool),
          )
          actor.continue(state)
        }
        Ok(_def) -> {
          // Unlinked on purpose: a crashing call fn must not take the
          // actor (and every sibling call) down with it — the monitor
          // answers the caller instead. The report races nothing: it
          // queues behind this handle, so `pending` is always inserted
          // before the outcome can be processed.
          let call = state.plugin.call
          let worker =
            process.spawn_unlinked(fn() {
              let outcome = call(tool, arguments)
              process.send(state.internal, WorkerDone(ref, outcome))
            })
          let monitor = process.monitor(worker)
          actor.continue(
            SdkState(
              ..state,
              pending: dict.insert(
                state.pending,
                ref,
                Pending(reply: reply, worker: worker, monitor: monitor),
              ),
            ),
          )
        }
      }

    Provider(tool_provider.Cancelled(ref)) ->
      case dict.get(state.pending, ref) {
        // Best-effort notice: the adapter already ended the call
        // (cancelled/timeout text in the transcript), so NO reply —
        // kill the worker, demonitor (flushes a racing DOWN), untrack.
        Error(Nil) -> actor.continue(state)
        Ok(entry) -> {
          process.kill(entry.worker)
          process.demonitor_process(entry.monitor)
          actor.continue(
            SdkState(..state, pending: dict.delete(state.pending, ref)),
          )
        }
      }

    Internal(WorkerDone(ref, outcome)) ->
      case dict.get(state.pending, ref) {
        // Untracked = already settled (a kill won the race): drop the
        // late report, exactly-once holds.
        Error(Nil) -> actor.continue(state)
        Ok(entry) -> {
          process.demonitor_process(entry.monitor)
          process.send(entry.reply, case outcome {
            Ok(content) -> tool_provider.ToolOk(content)
            Error(message) -> tool_provider.ToolErr(message)
          })
          actor.continue(
            SdkState(..state, pending: dict.delete(state.pending, ref)),
          )
        }
      }

    Internal(WorkerDown(down)) ->
      // A worker died without reporting (crash, or killed externally).
      // Match by pid: an untracked pid is a stale DOWN from a call we
      // already settled or cancelled — dropped.
      case down {
        process.ProcessDown(pid: pid, ..) ->
          case
            list.find(dict.to_list(state.pending), fn(entry) {
              { entry }.1.worker == pid
            })
          {
            Error(Nil) -> actor.continue(state)
            Ok(#(ref, entry)) -> {
              process.send(
                entry.reply,
                tool_provider.ToolErr("plugin tool crashed"),
              )
              actor.continue(
                SdkState(..state, pending: dict.delete(state.pending, ref)),
              )
            }
          }
        // Nothing this actor monitors is a port; ignored for totality.
        _ -> actor.continue(state)
      }
  }
}

// ---------------------------------------------------------------------------
// Boot: the compiled-in registry, supervision, the catalog snapshot
// ---------------------------------------------------------------------------

/// The compiled-in plugin registry (v1: plugins ship in the release and
/// are selected by config). An unknown name is a config error — loud at
/// boot, no silent skip.
pub fn by_config_name(name: String) -> Result(Plugin, String) {
  case name {
    "example" -> Ok(example.plugin())
    other -> Error("unknown plugin '" <> other <> "' in NEXUS_PLUGINS")
  }
}

/// Boot the plugin subsystem and build the catalog's provider table:
///
/// 1. `NEXUS_PLUGINS` empty (the default) → no tree, empty table — the
///    pre-plugin boot, byte for byte.
/// 2. Otherwise resolve each name through the compiled-in registry,
///    mint its process name ONCE, start the OneForOne `plugin_sup`
///    (linked to the caller), ask every provider `ListTools` under the
///    fixed boot budget, validate at the boundary, and build the specs
///    whose executors address providers by name.
///
/// Failures are loud: an unknown plugin name, a duplicate, a provider
/// that will not start or answer, an invalid ToolDef, or a collision
/// all return `Error` — boot exits, exactly like a config error.
pub fn boot(cfg: Config) -> Result(tools.ProviderTable, String) {
  case cfg.plugins {
    [] -> Ok(dict.new())
    names -> {
      use plugins <- result.try(compile_plugins(names))
      use table <- result.try(start_and_snapshot(cfg, plugins))
      Ok(table)
    }
  }
}

/// The floor a plugin's per-call timeout override must meet — the same
/// floor the config applies to `NEXUS_PLUGIN_TIMEOUT_MS` (a sub-100ms
/// deadline could never serve a call; and a NEGATIVE value reaches
/// Erlang's `after` and crashes with `timeout_value`, killing the
/// per-turn worker — a loop error, not a tool error).
const min_call_timeout_ms = 100

/// The provider half of the boundary rule: `^[a-zA-Z0-9_-]+$`, no `__`,
/// no leading or trailing `_` (see `tool_provider.valid_name`). Checked
/// where a plugin is resolved at boot AND at the actor seam, so no
/// caller can skip it.
pub fn validate_provider_name(name: String) -> Result(Nil, String) {
  case tool_provider.valid_name(name) {
    True -> Ok(Nil)
    False ->
      Error(
        "plugin '"
        <> name
        <> "' refused registration: provider name must match"
        <> " ^[a-zA-Z0-9_-]+$ with no '__' and no leading or trailing '_'",
      )
  }
}

/// The whole-declaration boundary check a plugin passes before it may
/// start or enter the catalog: the name rule above, plus a timeout
/// override that meets the config's floor (so an override can never
/// smuggle a crash-inducing deadline past the config validation).
pub fn validate_plugin(p: Plugin) -> Result(Nil, String) {
  use Nil <- result.try(validate_provider_name(p.name))
  case p.timeout_ms {
    Some(ms) if ms >= min_call_timeout_ms -> Ok(Nil)
    Some(_) ->
      Error(
        "plugin '"
        <> p.name
        <> "' refused registration: timeout_ms override must be >= "
        <> int.to_string(min_call_timeout_ms)
        <> " ms",
      )
    None -> Ok(Nil)
  }
}

/// Resolve config names to plugins, refusing duplicates, unknowns, and
/// (before anything starts) invalid provider names.
fn compile_plugins(names: List(String)) -> Result(List(Plugin), String) {
  use acc <- result.try(
    list.try_fold(names, #(dict.new(), []), fn(acc, name) {
      let #(seen, plugins) = acc
      case dict.has_key(seen, name) {
        True -> Error("duplicate plugin '" <> name <> "' in NEXUS_PLUGINS")
        False ->
          case by_config_name(name) {
            Error(reason) -> Error(reason)
            Ok(plugin) -> {
              use Nil <- result.try(validate_plugin(plugin))
              Ok(#(dict.insert(seen, name, Nil), [plugin, ..plugins]))
            }
          }
      }
    }),
  )
  Ok(list.reverse({ acc }.1))
}

/// Start `plugin_sup` (one worker per plugin, OneForOne — a crashing
/// plugin restarts alone; a crash LOOP exhausts the tolerance and takes
/// the linked caller down), then run the bounded snapshot.
fn start_and_snapshot(
  cfg: Config,
  plugins: List(Plugin),
) -> Result(tools.ProviderTable, String) {
  let entries = list.map(plugins, fn(p) { #(p, tool_provider.name(p.name)) })
  let sup =
    list.fold(entries, supervisor.new(supervisor.OneForOne), fn(sup, entry) {
      let #(p, name) = entry
      supervisor.add(sup, supervision.worker(fn() { start_named(p, name) }))
    })
  use _started <- result.try(
    supervisor.start(sup)
    |> result.replace_error("plugin_sup failed to start"),
  )
  list.try_fold(entries, dict.new(), fn(table, entry) {
    let #(p, name) = entry
    use defs <- result.try(
      tool_provider.list_tools(name, boot_ask_ms)
      |> result.map_error(fn(reason) {
        "plugin '" <> p.name <> "' did not answer ListTools: " <> reason
      }),
    )
    catalog_entries(cfg, p, name, table, defs)
  })
}

/// Validate one provider's ToolDefs at the boundary and fold them into
/// the table as specs. Every refusal names the provider and the rule —
/// before any name enters the catalog, where a bad entry could freeze
/// into a thread's envelope.
fn catalog_entries(
  cfg: Config,
  p: Plugin,
  name: Name(tool_provider.Msg),
  table: tools.ProviderTable,
  defs: List(ToolDef),
) -> Result(tools.ProviderTable, String) {
  let timeout_ms = option.unwrap(p.timeout_ms, cfg.plugin_timeout_ms)
  list.try_fold(defs, table, fn(table, def) {
    use Nil <- result.try(case tool_provider.valid_name(def.name) {
      True -> Ok(Nil)
      False ->
        Error(invalid(
          p.name,
          def,
          "tool name must match ^[a-zA-Z0-9_-]+$ with no '__' and no"
            <> " leading or trailing '_'",
        ))
    })
    use Nil <- result.try(
      case tool_provider.valid_parameters(def.parameters_json) {
        True -> Ok(Nil)
        False ->
          Error(invalid(
            p.name,
            def,
            "parameters_json must be an object-rooted JSON document under "
              <> int.to_string(tool_provider.max_parameters_bytes)
              <> " bytes",
          ))
      },
    )
    let qualified = tool_provider.qualified(p.name, def.name)
    use Nil <- result.try(case tools.is_compiled_name(qualified) {
      // Unreachable while compiled names stay `__`-free (the reserved
      // separator makes a qualified name disjoint from them); the guard
      // keeps that invariant enforced rather than assumed.
      True ->
        Error(invalid(
          p.name,
          def,
          "qualified name collides with a compiled tool",
        ))
      False -> Ok(Nil)
    })
    use Nil <- result.try(case dict.has_key(table, qualified) {
      True ->
        Error(invalid(
          p.name,
          def,
          "duplicate qualified tool name in the catalog",
        ))
      False -> Ok(Nil)
    })
    // The executor addresses the provider by NAME at call time — the
    // SAME pre-minted `Name` value the supervisor registered (a fresh
    // `tool_provider.name` call would mint a different atom: never
    // re-derive it) — and truncates centrally at the adapter.
    let spec =
      tools.ToolSpec(
        tool: tools.function_tool(
          name: qualified,
          description: def.description,
          parameters_json: def.parameters_json,
        ),
        run: fn(ctx, arguments) {
          tool_provider.run(
            provider: name,
            tool: def.name,
            timeout_ms: timeout_ms,
            max_output_chars: cfg.plugin_max_output_chars,
            cancel: ctx.cancel,
            arguments: arguments,
          )
        },
      )
    Ok(dict.insert(table, qualified, spec))
  })
}

fn invalid(provider: String, def: ToolDef, rule: String) -> String {
  "plugin '"
  <> provider
  <> "' refused registration: tool '"
  <> def.name
  <> "': "
  <> rule
}
