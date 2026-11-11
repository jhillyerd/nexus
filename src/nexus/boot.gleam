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
//// Thread actors are started dynamically as temporary children of the
//// factory; the registry replaces them by restarting through the factory
//// and rehydrating their transcript from the store.
////
//// Restart recovery (PRD acceptance): the supervisor is linked to this
//// process; if it gives up (crash loop) the VM halts and the *outer*
//// supervisor (Nomad job / run script) restarts us — persisted history
//// rehydrates from the store, so only turn commits still queued in the
//// write-behind lane are lost (the PRD accepts this window for the MVP).

import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/option.{None, Some}
import gleam/otp/factory_supervisor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/string
import mist
import nexus/bot_registry
import nexus/config
import nexus/provider_registry
import nexus/store/persist
import nexus/thread_registry
import nexus/web

@external(erlang, "nexus_boot_ffi", "halt")
fn halt(code: Int) -> a

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
