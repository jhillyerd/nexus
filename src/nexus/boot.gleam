//// Boot: load config (loudly), then bring up the supervision tree — one
//// OneForAll root, started in the order ARCHITECTURE.md §2 maps: the
//// **store** first (persistence is mandatory — an unreachable database
//// fails boot), the **provider registry** second (it loads and
//// decrypt-validates every provider row), the **bot registry** third
//// (it loads the bot table — the settings entities group), the thread
//// **factory supervisor** fourth, the **thread registry** fifth (it
//// hydrates the dormant set from the store before serving), and the
//// mist server last, so HTTP traffic always finds a live registry.
////
//// Beside the root sits ONE separate tree, started before it (plugin-api
//// plan Phase 1): `plugin_sup`, a OneForOne supervisor over the
//// configured tool-provider actors, linked to this process — a
//// crash-looping plugin exhausts its tolerance and takes boot down
//// with it (the root tree's own fail-loud mechanism, applied to
//// plugins), while a single crashing plugin restarts alone instead of
//// restarting every thread actor. It is separate because the boot-built
//// provider table (each provider's bounded `ListTools` snapshot) must
//// be ONE value shared by the bot registry's toolset validation and
//// the thread registry's resolution — root-tree children cannot hand
//// values to each other. `NEXUS_PLUGINS` unset (the default) starts no
//// tree and changes nothing.
////
//// Thread actors are started dynamically as temporary children of the
//// factory; the registry replaces them by restarting through the factory
//// and rehydrating their transcript from the store.
////
//// Restart recovery (PRD acceptance): the supervisor is linked to this
//// process; if it gives up (crash loop) the VM halts and the *outer*
//// supervisor (Nomad job / run script) restarts us — persisted history
//// rehydrates from the store, so only turn commits still queued in the
//// write-behind lane are lost (the PRD accepts this window for the MVP).

import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/factory_supervisor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/string
import mist
import nexus/bot_registry
import nexus/config
import nexus/env
import nexus/mcp_adapter
import nexus/plugin
import nexus/provider_registry
import nexus/store/persist
import nexus/thread_registry
import nexus/tool_provider
import nexus/tools
import nexus/web

@external(erlang, "nexus_boot_ffi", "halt")
fn halt(code: Int) -> a

/// The bot registry's tool-validation closure (bots plan P2, wired at
/// boot): the compiled ∪ plugin catalog check, plus the two plan gates —
/// a foreign name passes only while its server is mounted (no live ask:
/// a bot save must not depend on a server's mood), and an env name only
/// while a workspace root exists to freeze (environments plan Phase 1 —
/// the same refusal a create gets, at the surface where the operator
/// still has the form open). Extracted so the gates are offline-
/// testable without booting the tree.
pub fn bot_validate_tools(
  cfg: config.Config,
  providers: tools.ProviderTable,
  foreign: dict.Dict(String, tools.ForeignServer),
) -> fn(List(String)) -> Result(List(String), String) {
  fn(names) {
    let #(foreign_names, plain_names) =
      list.fold(names, #([], []), fn(acc, name) {
        let #(foreign_names, plain_names) = acc
        let is_foreign = case tool_provider.split(name) {
          Ok(#(server, _)) -> dict.has_key(foreign, server)
          Error(Nil) -> False
        }
        case is_foreign {
          True -> #([name, ..foreign_names], plain_names)
          False -> #(foreign_names, [name, ..plain_names])
        }
      })
    // Environments plan Phase 1: a bot template may pin env tools only
    // while a workspace root exists to freeze.
    case list.any(names, env.is_env_name), cfg.workspace_root {
      True, option.None ->
        Error("workspace tools require NEXUS_WORKSPACE_ROOT to be set")
      _, _ ->
        // Plain names resolve through the compiled ∪ plugin catalog
        // (the loud refusal unchanged); a foreign name passed
        // classification above, which already proved its server is
        // mounted.
        case tools.by_names_with(cfg, providers, list.reverse(plain_names)) {
          Error(reason) -> Error(reason)
          Ok(_) -> {
            let _ = foreign_names
            Ok(names)
          }
        }
    }
  }
}

pub fn main() -> Nil {
  io.println("nexus — M3 server-component UI")
  case config.load() {
    Error(message) -> {
      io.println("config error: " <> message)
      io.println(
        "required: NEXUS_ENCRYPTION_KEY (base64 of 32 bytes); "
        <> "see the README env table",
      )
      halt(2)
    }
    Ok(cfg) -> {
      // Plugins FIRST (plugin-api plan Phase 1): the provider table must
      // exist before the root tree's closures capture it. Loud on every
      // failure — an unknown name, a provider that will not start or
      // answer, an invalid ToolDef — because a compiled plugin is part
      // of the release (the no-silent-fallback philosophy). With no
      // configured plugins this is the empty table and no tree.
      let providers = case plugin.boot(cfg) {
        Ok(table) -> table
        Error(reason) -> {
          io.println("plugin boot error: " <> reason)
          halt(2)
        }
      }
      // MCP servers SECOND (plugin-api plan Phase 2): their adapters
      // live in their own linked tree, but a server that will not
      // spawn or answer DEGRADES (external dependency — the loud log
      // and the honest 400 at create are the contract), never fails
      // boot. The foreign map — like the provider table — is ONE value
      // shared by the bot registry's validation and the thread
      // registry's freeze. With no configured servers this is the
      // empty map and no tree.
      let foreign = case mcp_adapter.boot(cfg) {
        Ok(mounts) -> dict.from_list(mounts)
        Error(reason) -> {
          io.println("mcp boot error: " <> reason)
          halt(2)
        }
      }
      // Names are stable across restarts of the supervisor itself.
      let store_name = process.new_name("nexus_store")
      let provider_registry_name = process.new_name("nexus_provider_registry")
      let bot_registry_name = process.new_name("nexus_bot_registry")
      let factory_name = process.new_name("nexus_factory")
      let registry_name = process.new_name("nexus_registry")
      // The provider seam handed to the thread registry: every thread
      // freezes the endpoint this resolves at create/hydration time
      // (multi-provider plan §8). Mapping lives here so neither registry
      // depends on the other.
      let resolve_provider = fn(id) {
        let providers = process.named_subject(provider_registry_name)
        case provider_registry.resolve(providers, id) {
          Ok(resolved) -> Ok(resolved.endpoint)
          Error(provider_registry.Unknown) ->
            Error(thread_registry.ProviderUnknown)
          Error(provider_registry.Disabled) ->
            Error(thread_registry.ProviderDisabled)
          Error(_) -> Error(thread_registry.ProviderKeyUnavailable)
        }
      }
      let root =
        supervisor.new(supervisor.OneForAll)
        // Store first (Phase 2): the registry hydrates from it at start —
        // persistence is mandatory, so an unreachable database fails boot
        // here (no silent ephemeral mode).
        |> supervisor.add(
          supervision.supervisor(fn() { persist.supervised(cfg, store_name) }),
        )
        |> supervisor.add(
          // Provider registry second (multi-provider plan §7): after the
          // store (it loads and decrypt-validates every provider row at
          // start — a bad envelope or key fails boot here), before the
          // factory/thread registry (threads resolve endpoints through
          // it once P3 pins providers into the turn runner).
          supervision.supervisor(fn() {
            provider_registry.start(
              cfg,
              persist.seam(process.named_subject(store_name)),
              provider_registry_name,
            )
          }),
        )
        |> supervisor.add(
          // Bot registry third (bots plan P1, #74): after the provider
          // registry (the settings entities group; strictly it needs only
          // the store) and before the factory/thread registry. It loads
          // the whole bot table at start — an unreachable store fails
          // boot here, like the provider registry. No security machinery:
          // bots carry no key material, so there is nothing to validate
          // at load. Mutually ignorant of the provider registry — each
          // surface that needs the other's truth (a bot's provider_id
          // check, the provider delete guard's bot count) reaches it
          // through its own seam or its own caller.
          supervision.supervisor(fn() {
            bot_registry.start(
              persist.seam(process.named_subject(store_name)),
              bot_registry_name,
              // The catalog check (bots plan P2): submitted toolsets are
              // validated against the SAME registry that builds the wire
              // schemas — injected as a fn so this actor stays decoupled
              // from the config and the tool modules. The specs are
              // built and discarded; only the verdict crosses the seam.
              // Plugin-api Phase 1: the check resolves through the
              // provider table too, so a bot may pin plugin tools.
              // Plugin-api Phase 2: a name whose server half is a
              // mounted MCP server passes here (no LIVE ask at bot
              // validation — a bot save must not depend on a server's
              // mood); the freeze happens per THREAD at create.
              bot_validate_tools(cfg, providers, foreign),
              // The pinnable-catalog enumeration (issue #121): the
              // forms' checkbox list reads the same ONE provider/foreign
              // values the validate closure captured, through the same
              // injected-fn rule (the actor stays tool-module-free).
              // Unlike validation this DOES ask live per mounted server
              // (bounded by the freeze budget inside tools.catalog) so
              // the picker shows the servers' current tools; a failed
              // server degrades into the catalog's `unavailable` list.
              fn() {
                let tools.Catalog(names, unavailable) =
                  tools.catalog(providers, foreign, tools.freeze_ask_ms + 2000)
                bot_registry.ToolCatalog(names, unavailable)
              },
            )
          }),
        )
        |> supervisor.add(
          // Factory fourth: the thread registry resolves it by name at
          // startup.
          supervision.supervisor(fn() {
            factory_supervisor.start(thread_registry.factory_builder(
              factory_name,
            ))
          }),
        )
        |> supervisor.add(
          supervision.supervisor(fn() {
            thread_registry.start(
              cfg,
              factory_supervisor.get_by_name(factory_name),
              registry_name,
              persist.seam(process.named_subject(store_name)),
              resolve_provider,
              // The bot registry's NAME (bots P3c): no registry-to-registry
              // edge — the delivery wrapper hands it to the `bot_message`
              // tool's sender-name closure, which resolves it at ask time
              // inside the unlinked turn worker (the TagCorpus pattern).
              bot_registry_name,
              providers,
              // The mounted MCP servers (plugin-api plan Phase 2): the
              // freeze seam for create-time schema snapshots.
              foreign,
            )
          }),
        )
        |> supervisor.add(
          // Mist last. There is no shared UI child anymore (the per-client
          // break): the /ws handler starts one linked component runtime
          // per connection, so a UI crash costs one socket — the browser
          // reconnects into a fresh runtime — instead of restarting this
          // OneForAll tree (and every thread actor with it).
          supervision.supervisor(fn() {
            mist.new(web.handler(
              cfg,
              registry_name,
              provider_registry_name,
              bot_registry_name,
              persist.seam(process.named_subject(store_name)),
            ))
            |> mist.bind(cfg.http_bind)
            |> mist.port(cfg.http_port)
            |> mist.start
          }),
        )
      case supervisor.start(root) {
        Ok(_) -> {
          // No thread is minted at boot: creation is user-initiated (the
          // sidebar's create panel auto-opens whenever no active thread is
          // selectable), so a restart never adds an empty thread — and the
          // registry's boot sweep retired any never-used leftovers from
          // earlier runs while hydrating. The tool schema is still frozen
          // before any thread can exist: the registry built it from the
          // global config at its own start.
          io.println(
            "listening on http://"
            <> cfg.http_bind
            <> ":"
            <> int.to_string(cfg.http_port),
          )
          case cfg.ui_token {
            Some(_) -> io.println("auth: token required")
            None -> io.println("auth: disabled (NEXUS_UI_TOKEN unset)")
          }
          process.sleep_forever()
        }
        Error(reason) -> {
          io.println(
            "failed to start supervision tree: " <> string.inspect(reason),
          )
          halt(1)
        }
      }
    }
  }
}
