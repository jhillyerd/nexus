//// Phase 2 durable persistence: the swappable store seam.
////
//// Mirrors the seam pattern of `nexus/net`: policy and pure mapping live
//// here, the byte-moving implementation lives behind it
//// (`nexus/store/persist` — a pog-backed actor over the queries generated
//// by squirrel from `src/nexus/store/sql`). The seam is a record of
//// functions so offline tests can substitute a fully in-memory store and
//// `gleam test` never touches a database.
////
//// KV-cache contract (the hard constraint): the store persists *rows*,
//// never request bodies. Hydration rebuilds a transcript exclusively
//// through `nexus/transcript.new(model, system_prompt)` + the existing
//// `append_*` functions — there is no second encoding or construction
//// path anywhere — so a hydrated session re-encodes byte-identically
//// (guarded by the golden restart tests).
////
//// Row model (messages table, `sql/schema.sql`):
//// - `role` is one of the transcript roles 'user' | 'assistant' | 'tool'.
//// - A plain user or assistant message is one row.
//// - An assistant message carrying N tool calls is N consecutive
////   `ToolCallRow`s (one per call); the FIRST row of the run carries the
////   message text in `content` ('' when the message had no text). A
////   maximal run of consecutive tool-call rows is exactly one assistant
////   message — the OpenAI protocol never places two assistant messages
////   back-to-back without a tool result between them.
//// - A tool result is one row; `name` is resolved from the preceding
////   assistant call (display metadata, like the SSE replay does) and
////   `ok` is persisted as the replay value (the transcript itself does
////   not carry an ok flag).
//// - The system prompt is NOT a row: it lives in `sessions.system_prompt`
////   and hydration refreezes it via `transcript.new`.
//// - `seq` is the 0-based index of the row within the session
////   (transcript message index minus one, skipping the system message).
////   `message_count` on the session row counts messages INCLUDING the
////   system prompt, matching Phase 1's `SessionSummary.message_count`.

import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import glopenai/chat.{type ChatMessage}
import nexus/session
import nexus/transcript.{type Transcript}

/// A stored session's organizational metadata — exactly the Phase 1
/// `SessionSummary` field set minus live state (streaming, metrics).
pub type StoredSummary {
  StoredSummary(
    id: String,
    /// The pinned provider (frozen at creation with the model, contract
    /// rule 2; `session.provider_id` → `provider.id`).
    provider_id: String,
    title: String,
    title_source: session.TitleSource,
    model: String,
    pinned: Bool,
    archived: Bool,
    tags: List(String),
    /// Epoch seconds (Phase 1 wire format).
    created_at: Int,
    /// Epoch seconds; bumped on turn commit.
    last_active_at: Int,
    /// Includes the system prompt (Phase 1 semantics).
    message_count: Int,
  )
}

/// A stored session including the frozen system prompt — everything needed
/// to rebuild its transcript. `system_prompt` is contract rule 2: frozen at
/// creation, stored so hydration refreezes the identical prefix even if
/// `NEXUS_SYSTEM_PROMPT` changed between runs.
pub type StoredSession {
  StoredSession(summary: StoredSummary, system_prompt: String)
}

/// A stored provider row — **ciphertext only**. `api_key_encrypted` is
/// the `nexus/crypto` envelope; the store never sees plaintext keys
/// (encryption lives in the provider registry, so this seam and its
/// mocks stay secret-free). `None` = a keyless provider (local
/// endpoints).
pub type StoredProvider {
  StoredProvider(
    id: String,
    /// Display + lookup key (unique).
    name: String,
    /// OpenAI-compatible base URL, ends `/v1`.
    base_url: String,
    /// AES-256-GCM envelope (`0x01 || nonce(12) || tag(16) ||
    /// ciphertext`, AAD = provider id); `None` = keyless.
    api_key_encrypted: Option(BitArray),
    /// Envelope key version — 1 today; exists so rotation is additive.
    key_version: Int,
    /// Always `'openai'` today; exists so future dialects need no
    /// schema change.
    dialect: String,
    enabled: Bool,
    /// Epoch seconds.
    created_at: Int,
    /// Epoch seconds; bumped on update.
    updated_at: Int,
  )
}

/// One append-only message row. The write shape and the read shape are the
/// same type; `seq` is assigned by the store, not carried here.
pub type MessageRow {
  UserRow(content: String)
  AssistantRow(
    content: String,
    /// The model's chain-of-thought for this message, when it emitted
    /// any. Display-only — never sent back to the model. Plain text for
    /// the same byte-stability rationale as `tool_args` (never jsonb).
    reasoning: Option(String),
  )
  ToolCallRow(
    /// The assistant message's text — set on the FIRST row of a run, ''
    /// on continuation rows.
    content: String,
    call_id: String,
    name: String,
    /// Raw model-emitted argument JSON, byte-stable (a `text` column on
    /// purpose: jsonb would normalize it — see docs/plans/p2-verification.md).
    arguments: String,
    /// The message's reasoning — set on the FIRST row of a run only,
    /// exactly like `content`.
    reasoning: Option(String),
  )
  ToolResultRow(call_id: String, name: String, ok: Bool, content: String)
}

/// Sanitized store error (already safe to log; never contains secrets).
pub type StoreError =
  String

/// The swappable seam. Every function is synchronous except `commit`,
/// which must never block the caller (it rides the session actor's commit
/// path): implementations enqueue and persist write-behind, in order.
pub type Store {
  Store(
    /// Every stored session (boot hydration of the dormant set).
    list_summaries: fn() -> Result(List(StoredSummary), StoreError),
    /// One stored session incl. system prompt. `Error` for unknown ids.
    get_session: fn(String) -> Result(StoredSession, StoreError),
    /// All rows of one session in seq order (lazy start / restart
    /// hydration). Also teaches the store the session's persisted length.
    load_messages: fn(String) -> Result(List(MessageRow), StoreError),
    /// Persist a new session row (write-through at create).
    insert_session: fn(StoredSummary, String) -> Result(Nil, StoreError),
    /// Write-behind turn commit: enqueue the (full, immutable) committed
    /// transcript. The store appends the delta past what it already
    /// persisted, in seq order, then bumps recency + count. Replay of an
    /// unchanged or shorter transcript is a no-op; duplicate seqs are
    /// skipped (idempotent crash recovery).
    commit: fn(String, Transcript) -> Nil,
    /// Metadata write-through (mirrors the registry's setters).
    set_title: fn(String, String) -> Result(Nil, StoreError),
    /// Guarded like the registry: applies only while the stored title is
    /// the untouched auto default. `Ok(True)` when it applied.
    auto_title: fn(String, String) -> Result(Bool, StoreError),
    set_tags: fn(String, List(String)) -> Result(Nil, StoreError),
    set_pinned: fn(String, Bool) -> Result(Nil, StoreError),
    /// Archiving clears the pin (Phase 1 invariant, enforced in SQL too).
    archive: fn(String) -> Result(Nil, StoreError),
    unarchive: fn(String) -> Result(Nil, StoreError),
    /// Hard delete; cascades to the session's message rows.
    delete_session: fn(String) -> Result(Nil, StoreError),
    /// Boot sweep: delete every never-used stored session older than the
    /// grace window — one statement, so the work is bounded wherever it
    /// runs (the registry calls it inside its actor-initialiser
    /// deadline). The grace window keeps an empty session another
    /// concurrently-running server just created (still empty until its
    /// first commit) from being deleted under its live actor. Returns
    /// the deleted ids; an error leaves the store untouched.
    prune_never_used: fn() -> Result(List(String), StoreError),
    // ---- provider rows (docs/plans/multi-provider.md §5.3) ----
    /// Every stored provider, ordered by id (registry boot load). The
    /// ciphertext rides along: decryption lives in the registry.
    list_providers: fn() -> Result(List(StoredProvider), StoreError),
    /// One stored provider incl. envelope. `Error` for unknown ids.
    get_provider: fn(String) -> Result(StoredProvider, StoreError),
    /// Persist a new provider row (write-through at create). Errors on
    /// duplicate id or name, like the schema's constraints.
    insert_provider: fn(StoredProvider) -> Result(Nil, StoreError),
    /// Full-metadata update. `replace_key = False` keeps the stored
    /// envelope and `key_version` — a PATCH without an api_key must not
    /// null the key; `True` writes `api_key_encrypted` from the record,
    /// where `None` means become keyless.
    update_provider: fn(StoredProvider, Bool) -> Result(Nil, StoreError),
    /// Sessions pinning this provider — the registry's delete guard.
    count_sessions_for_provider: fn(String) -> Result(Int, StoreError),
    /// Hard delete; refused (`Error`) while any session references the
    /// provider (the FK is the enforcement). Disabling is the
    /// reversible path.
    delete_provider: fn(String) -> Result(Nil, StoreError),
  )
}

// ---------------------------------------------------------------------------
// Pure mappers: transcript ⇄ rows (the ONLY translation code there is)
// ---------------------------------------------------------------------------

/// The rows for the messages of `tr` past the first `already_persisted`
/// chronological messages (`already_persisted` counts the system prompt,
/// which is never a row). This is the write-behind delta.
pub fn transcript_rows(
  tr: Transcript,
  already_persisted: Int,
) -> List(MessageRow) {
  let base = int_max(already_persisted, 0)
  let #(rows, _) =
    tr
    |> transcript.messages
    |> list.drop(base)
    |> messages_to_rows_with(base, fn(index) {
      transcript.reasoning_at(tr, index)
    })
  rows
}

/// Translate chronological transcript messages into rows. Messages this
/// module's constructors never produce (developer messages, non-text user
/// content) are skipped — see the module docs for the row model. This is
/// the reasoning-free shape; the write-behind lane uses
/// `messages_to_rows_with` against the transcript's sidecar.
pub fn messages_to_rows(messages: List(ChatMessage)) -> List(MessageRow) {
  let #(rows, _) = messages_to_rows_with(messages, 0, fn(_) { None })
  rows
}

/// The reasoning-aware row mapping: `reasoning_at` resolves a message's
/// chronological index into its recorded chain-of-thought, so assistant
/// rows carry it without it ever existing as a message. `base` is the
/// chronological index of `messages`' head (non-zero when the caller
/// already dropped a persisted prefix).
fn messages_to_rows_with(
  messages: List(ChatMessage),
  base: Int,
  reasoning_at: fn(Int) -> Option(String),
) -> #(List(MessageRow), dict.Dict(String, String)) {
  let #(rows, names, _) =
    list.index_fold(messages, #([], dict.new(), 0), fn(acc, message, index) {
      let #(rows, names, _index) = acc
      let reasoning = reasoning_at(base + index)
      case message {
        chat.UserMessage(content: chat.UserTextContent(text), ..) -> #(
          [UserRow(text), ..rows],
          names,
          index + 1,
        )
        chat.AssistantMessage(content: text, tool_calls: calls, ..) ->
          case calls {
            Some(calls) -> {
              let text = case text {
                Some(chat.AssistantTextContent(content)) -> content
                _ -> ""
              }
              // The outer accumulator is newest-first; within this
              // message the calls are already chronological because
              // index_fold prepends, so `new_rows` is newest-first too
              // (last call first) — exactly how it must splice in.
              let #(new_rows, names) =
                list.index_fold(calls, #([], names), fn(acc, call, index) {
                  let #(rows, names) = acc
                  let chat.FunctionToolCall(id: id, function: f) = call
                  #(
                    [
                      ToolCallRow(
                        content: case index {
                          0 -> text
                          _ -> ""
                        },
                        call_id: id,
                        name: f.name,
                        arguments: f.arguments,
                        reasoning: case index {
                          0 -> reasoning
                          _ -> None
                        },
                      ),
                      ..rows
                    ],
                    dict.insert(names, id, f.name),
                  )
                })
              #(list.append(new_rows, rows), names, index + 1)
            }
            None ->
              case text {
                Some(chat.AssistantTextContent(content)) -> #(
                  [AssistantRow(content, reasoning), ..rows],
                  names,
                  index + 1,
                )
                _ -> #(rows, names, index + 1)
              }
          }
        chat.ToolMessage(
          content: chat.ToolTextContent(content),
          tool_call_id: id,
        ) -> #(
          [
            ToolResultRow(
              call_id: id,
              name: result.unwrap(dict.get(names, id), "tool"),
              ok: True,
              content: content,
            ),
            ..rows
          ],
          names,
          index + 1,
        )
        // System prompts are not rows (sessions.system_prompt); the other
        // shapes have no constructor in nexus — skipping is losing nothing
        // that can exist.
        _ -> #(rows, names, index + 1)
      }
    })
  #(list.reverse(rows), names)
}

/// Rebuild a transcript from stored rows through the one construction
/// path: `transcript.new` (refreezing model + system prompt) then the
/// existing `append_*` functions, in seq order. This is what lazy start,
/// restart recovery, and the byte-identical golden tests all use.
pub fn transcript_from_rows(
  model: String,
  system_prompt: String,
  rows: List(MessageRow),
) -> Transcript {
  append_rows(transcript.new(model, system_prompt), rows)
}

fn append_rows(tr: Transcript, rows: List(MessageRow)) -> Transcript {
  case rows {
    [] -> tr
    [UserRow(content), ..rest] ->
      append_rows(transcript.append_user(tr, content), rest)
    [AssistantRow(content, reasoning), ..rest] ->
      append_rows(
        transcript.append_assistant_with_reasoning(tr, content, reasoning),
        rest,
      )
    [ToolResultRow(call_id: id, content: content, ..), ..rest] ->
      append_rows(transcript.append_tool_result(tr, id, content), rest)
    [ToolCallRow(..), ..] -> {
      // A maximal run of consecutive tool-call rows is one assistant
      // message: the first row's content is the message text, the run's
      // calls are the message's tool calls, and the first row's
      // reasoning is the message's reasoning.
      let #(group, rest) = split_call_run(rows, [])
      let assert [ToolCallRow(content: text, reasoning: reasoning, ..), ..] =
        group
      let calls =
        list.filter_map(group, fn(row) {
          case row {
            ToolCallRow(_, id, name, arguments, _) -> Ok(#(id, name, arguments))
            _ -> Error(Nil)
          }
        })
      append_rows(
        transcript.append_assistant_tool_calls(
          tr,
          text: case text {
            "" -> None
            text -> Some(text)
          },
          calls: calls,
          reasoning: reasoning,
        ),
        rest,
      )
    }
  }
}

fn split_call_run(
  rows: List(MessageRow),
  acc: List(MessageRow),
) -> #(List(MessageRow), List(MessageRow)) {
  case rows {
    [ToolCallRow(..) as row, ..rest] -> split_call_run(rest, [row, ..acc])
    _ -> #(list.reverse(acc), rows)
  }
}

/// True when the store's `message_count` bookkeeping (which counts the
/// system prompt) has nothing new for `transcript_rows`.
pub fn has_delta(transcript: Transcript, already_persisted: Int) -> Bool {
  transcript.length(transcript) > already_persisted
}

fn int_max(a: Int, b: Int) -> Int {
  case a > b {
    True -> a
    False -> b
  }
}
