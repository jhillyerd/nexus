//// Bot-to-bot delivery context (bots plan P3c, issue #97): the per-thread
//// identity a `bot_message` tool call needs, carried inside `ToolCtx` on
//// threads created from a bot.
////
//// This module is a LEAF: it imports nothing from nexus, because
//// `nexus/tools` (which holds `ToolCtx`) is imported by
//// `nexus/thread_registry`, and raw `Subject` fields typed against the
//// registry message types would close an import cycle. The two registry
//// asks therefore ride as CLOSURES — capabilities built by the thread
//// registry when it wraps a bot thread's turn runner (create/hydrate),
//// resolved at ask time inside the unlinked turn worker, exactly like the
//// injected `utility_apply` closure (§8 rule 1's unlinked-worker
//// exception class). Neither ask ever runs in a thread actor.
////
//// Identity is per-THREAD, never per-toolset: runner bundles are cached
//// by name tuple and shared across a bot's threads, so the wrapper is
//// applied per thread at create/hydrate and only closes over this
//// thread's own id and bot id.
////
//// `depth` is the hop depth this turn's deliveries carry: the initiating
//// user message's sidecar depth + 1 (a human send resets to 0, so the
//// first bot turn delivers at depth 1). Computed per turn from the
//// transcript sidecar — persisted data — so the counter survives
//// restarts.

/// One delivery ask: everything the registry's `Deliver` guard needs.
/// `from_*` are the SENDING side (resolved at send time so the `From`
/// prefix stays current across bot renames); `to` is a bot name or a
/// thread id; `text` is the raw tool argument — the registry builds the
/// model-visible `From` prefix onto it.
pub type Request {
  Request(
    from_bot_id: String,
    from_bot_name: String,
    from_thread_id: String,
    depth: Int,
    to: String,
    text: String,
  )
}

/// The registry's routing verdict. `Delivered` names the TARGET thread —
/// the thread the message landed in (and that the target's replies are
/// keyed to), so the sender model can address it precisely by id even
/// after a restart has lost the in-memory DM map. `Busy` is retryable (the
/// target answers on its next turn); `Refused` carries a fixed reason
/// string. Both non-Delivered variants render as failed tool results —
/// tool errors are not loop errors.
pub type Reply {
  Delivered(thread_id: String)
  Busy
  Refused(reason: String)
}

/// The per-thread delivery context. The two closures encapsulate the
/// worker-side registry asks (both bounded, both answered immediately by
/// their actors — the thread registry never blocks on a turn worker, the
/// bot registry answers from boot-loaded state):
///
/// - `deliver` — the `Deliver` ask into the thread registry (routing,
///   guards, and the send into the target thread). `Error` is a
///   transport-level failure of the ask itself (timeout); guard verdicts
///   arrive as `Ok(Reply)`.
/// - `sender_name` — the bot registry `Get(bot_id)` for the sender's
///   CURRENT display name, asked at send time. `Error` = the sender bot
///   was deleted (an honest tool error — the thread keeps running, it
///   just cannot send).
pub type Delivery {
  Delivery(
    /// The sending thread's id (rides the `From` prefix, so the target
    /// can reply by addressing this thread precisely).
    thread_id: String,
    /// The sending bot's id (provenance + the DM-map key half).
    bot_id: String,
    /// The hop depth this turn's deliveries carry (see module docs).
    depth: Int,
    deliver: fn(Request) -> Result(Reply, String),
    sender_name: fn() -> Result(String, Nil),
  )
}
