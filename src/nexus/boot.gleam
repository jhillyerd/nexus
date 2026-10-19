//// Boot: load config (loudly), then bring up the M3 supervision tree —
//// root supervisor (OneForAll) with the session **factory supervisor**
//// first, the **session registry** second, and the mist server third, so
//// HTTP traffic always finds a live registry and the registry always finds
//// its factory (M2 plan §2/§7 step 3).
////
//// Session actors are started dynamically as temporary children of the
//// factory; only the registry replaces them (same ID, empty transcript).
////
//// Restart recovery (PRD acceptance): the supervisor is linked to this
//// process; if it gives up (crash loop) the VM halts and the *outer*
//// supervisor (Nomad job / run script) restarts us into a clean, empty
//// registry — history loss on restart is accepted by the PRD for the MVP.

import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/option.{None, Some}
import gleam/otp/factory_supervisor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/string
import mist
import nexus/config
import nexus/provider_registry
import nexus/session_registry
import nexus/store/persist
import nexus/ui_runtime
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
      let factory_name = process.new_name("nexus_factory")
      let registry_name = process.new_name("nexus_registry")
      let component_name = process.new_name("nexus_chat_component")
      // The provider seam handed to the session registry: every session
      // freezes the endpoint this resolves at create/hydration time
      // (multi-provider plan §8). Mapping lives here so neither registry
      // depends on the other.
      let resolve_provider = fn(id) {
        let providers = process.named_subject(provider_registry_name)
        case provider_registry.resolve(providers, id) {
          Ok(resolved) -> Ok(resolved.endpoint)
          Error(provider_registry.Unknown) ->
            Error(session_registry.ProviderUnknown)
          Error(provider_registry.Disabled) ->
            Error(session_registry.ProviderDisabled)
          Error(_) -> Error(session_registry.ProviderKeyUnavailable)
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
          // factory/session registry (sessions resolve endpoints through
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
          // Factory third: the session registry resolves it by name at
          // startup.
          supervision.supervisor(fn() {
            factory_supervisor.start(session_registry.factory_builder(
              factory_name,
            ))
          }),
        )
        |> supervisor.add(
          supervision.supervisor(fn() {
            session_registry.start(
              cfg,
              factory_supervisor.get_by_name(factory_name),
              registry_name,
              persist.seam(process.named_subject(store_name)),
              resolve_provider,
            )
          }),
        )
        |> supervisor.add(
          // Lustre runtime: after the registry (it resolves sessions
          // through it), before Mist (the WebSocket handler looks the
          // component up by name).
          ui_runtime.supervised(
            component_name,
            process.named_subject(registry_name),
            process.named_subject(provider_registry_name),
          ),
        )
        |> supervisor.add(
          supervision.supervisor(fn() {
            mist.new(web.handler(
              cfg,
              registry_name,
              provider_registry_name,
              component_name,
            ))
            |> mist.bind(cfg.http_bind)
            |> mist.port(cfg.http_port)
            |> mist.start
          }),
        )
      case supervisor.start(root) {
        Ok(_) -> {
          // No session is minted at boot: creation is user-initiated (the
          // sidebar's create panel auto-opens whenever no active session is
          // selectable), so a restart never adds an empty session — and the
          // registry's boot sweep retired any never-used leftovers from
          // earlier runs while hydrating. The tool schema is still frozen
          // before any session can exist: the registry built it from the
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
