//// Append-only transcript and the **single request-encoding path** shared
//// by the TTFT audit tool and the product.
////
//// The KV-cache contract requires that re-encoding an unchanged message
//// prefix yields byte-identical request bodies (rule 4). That property is
//// only real if there is exactly one place where requests are built — this
//// module. Messages are stored newest-first (Gleam list idiom) and reversed
//// once at encode time, deterministically, through the glopenai codec whose
//// JSON encoding is field-order-stable and omits absent optional fields.

import gleam/dict.{type Dict}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import glopenai/chat.{type ChatMessage}
import glopenai/shared

/// Options applied on top of the transcript when building a request.
/// Everything here must stay constant across a session's turns except where
/// the cache contract allows tail-only changes.
pub type Options {
  Options(
    stream: Bool,
    tools: List(chat.ChatCompletionTool),
    tool_choice: Option(chat.ToolChoice),
    max_completion_tokens: Option(Int),
    temperature: Option(Float),
  )
}

pub fn default_options() -> Options {
  Options(
    stream: False,
    tools: [],
    tool_choice: None,
    max_completion_tokens: None,
    temperature: None,
  )
}

pub opaque type Transcript {
  Transcript(
    model: String,
    messages: List(ChatMessage),
    /// Display-only reasoning sidecar: the model's chain-of-thought text
    /// keyed by the CHRONOLOGICAL message index it belongs to (0 = the
    /// system prompt). `to_request` reads only `messages`, so reasoning
    /// is structurally incapable of changing a request byte — chat-
    /// completions reasoning is never replayed to the model anyway. It
    /// rides inside the transcript so the single commit / write-behind /
    /// replay path (typed on `Transcript`) carries it for free.
    reasoning: Dict(Int, String),
    /// Display-only outcome sidecar: whether each tool result succeeded,
    /// keyed by the CHRONOLOGICAL message index of the tool message (0 =
    /// the system prompt). `chat.ToolMessage` cannot carry it and
    /// `to_request` reads only `messages`, so it rides the same sidecar
    /// path as reasoning: structurally incapable of changing a request
    /// byte, yet present on the commit / write-behind / replay lane that
    /// rebuilds the UI after a reload.
    tool_results: Dict(Int, Bool),
    /// Display-only timestamp sidecar: the wall-clock epoch second each
    /// message was appended at, keyed by the CHRONOLOGICAL message index
    /// (0 = the system prompt, which is never stamped). `to_request`
    /// reads only `messages`, so — exactly like the sidecars above — it
    /// is structurally incapable of changing a request byte, yet rides
    /// the commit / write-behind / replay lane that persists and restores
    /// it, so the chat log's per-message ages survive a reload.
    timestamps: Dict(Int, Int),
  )
}

/// New transcript: system prompt is frozen at creation (contract rule 2).
pub fn new(model: String, system: String) -> Transcript {
  Transcript(
    model: model,
    messages: [chat.system_message(system)],
    reasoning: dict.new(),
    tool_results: dict.new(),
    timestamps: dict.new(),
  )
}

pub fn model(transcript: Transcript) -> String {
  transcript.model
}

/// Messages in chronological order (oldest first).
pub fn messages(transcript: Transcript) -> List(ChatMessage) {
  list.reverse(transcript.messages)
}

pub fn length(transcript: Transcript) -> Int {
  list.length(transcript.messages)
}

pub fn append_user(transcript: Transcript, text: String) -> Transcript {
  Transcript(..transcript, messages: [
    chat.user_message(text),
    ..transcript.messages
  ])
}

pub fn append_assistant(transcript: Transcript, text: String) -> Transcript {
  append_assistant_with_reasoning(transcript, text, None)
}

/// Append an assistant turn plus the reasoning the model emitted before
/// it. The reasoning lands in the display-only sidecar — it never enters
/// `messages`, so `to_request` output stays byte-identical to the same
/// turn appended through plain `append_assistant` (guarded by the golden
/// reasoning-isolation test).
pub fn append_assistant_with_reasoning(
  transcript: Transcript,
  text: String,
  reasoning reasoning: Option(String),
) -> Transcript {
  Transcript(
    ..transcript,
    messages: [chat.assistant_message(text), ..transcript.messages],
    reasoning: attach_reasoning(transcript, reasoning),
  )
}

/// Append an assistant turn carrying a native tool call (tool round-trip).
pub fn append_assistant_tool_call(
  transcript: Transcript,
  id id: String,
  name name: String,
  arguments arguments: String,
) -> Transcript {
  let call =
    chat.FunctionToolCall(
      id: id,
      function: shared.FunctionCall(name: name, arguments: arguments),
    )
  Transcript(..transcript, messages: [
    chat.AssistantMessage(
      content: None,
      refusal: None,
      name: None,
      tool_calls: Some([call]),
    ),
    ..transcript.messages
  ])
}

/// Append an assistant turn carrying several native tool calls (M3 loop):
/// one message, one call entry each, with optional text content and the
/// optional reasoning the model emitted before the calls.
pub fn append_assistant_tool_calls(
  transcript: Transcript,
  text text: Option(String),
  calls calls: List(#(String, String, String)),
  reasoning reasoning: Option(String),
) -> Transcript {
  let calls =
    list.map(calls, fn(call: #(String, String, String)) {
      let #(id, name, arguments) = call
      chat.FunctionToolCall(
        id: id,
        function: shared.FunctionCall(name: name, arguments: arguments),
      )
    })
  Transcript(
    ..transcript,
    messages: [
      chat.AssistantMessage(
        content: case text {
          Some(content) -> Some(chat.AssistantTextContent(content))
          None -> None
        },
        refusal: None,
        name: None,
        tool_calls: Some(calls),
      ),
      ..transcript.messages
    ],
    reasoning: attach_reasoning(transcript, reasoning),
  )
}

/// Append a tool result turn (tool round-trip). `ok` records the call's
/// outcome in the display-only sidecar (failed calls stay failed across a
/// reload) — it never enters `messages`, so `to_request` output is
/// byte-identical either way.
pub fn append_tool_result(
  transcript: Transcript,
  tool_call_id tool_call_id: String,
  content content: String,
  ok ok: Bool,
) -> Transcript {
  Transcript(
    ..transcript,
    messages: [chat.tool_message(content, tool_call_id), ..transcript.messages],
    tool_results: dict.insert(
      transcript.tool_results,
      list.length(transcript.messages),
      ok,
    ),
  )
}

/// The reasoning recorded for the message at chronological `index`
/// (0 = the system prompt); `None` when that message carried none. The
/// replay / persistence read side of the sidecar.
pub fn reasoning_at(transcript: Transcript, index: Int) -> Option(String) {
  dict.get(transcript.reasoning, index) |> option.from_result
}

/// Whether the tool result message at chronological `index` (0 = the
/// system prompt) succeeded; `None` when that message is not a tool
/// result. The replay / persistence read side of the sidecar.
pub fn tool_result_at(transcript: Transcript, index: Int) -> Option(Bool) {
  dict.get(transcript.tool_results, index) |> option.from_result
}

/// Stamp the newest message with a wall-clock epoch second (the read side
/// is `stamped_at`). Call immediately after the append that created the
/// message — the chronological index is derived from the message count,
/// so a stamp applied before an append would silently land on the wrong
/// message. Never stamped messages (the system prompt at index 0) simply
/// have no entry, which the UI renders as no timestamp. Pure display
/// metadata: never enters a request body.
pub fn stamp(transcript: Transcript, at: Int) -> Transcript {
  Transcript(
    ..transcript,
    timestamps: dict.insert(
      transcript.timestamps,
      list.length(transcript.messages) - 1,
      at,
    ),
  )
}

/// Stamp only when a stamp exists — the persistence lane's helper for
/// rows loaded before `created_at` was recorded.
pub fn stamp_opt(transcript: Transcript, at: Option(Int)) -> Transcript {
  case at {
    Some(at) -> stamp(transcript, at)
    None -> transcript
  }
}

/// The wall-clock epoch second the message at chronological `index`
/// (0 = the system prompt) was appended at; `None` when it carries no
/// stamp. The replay / persistence read side of the sidecar.
pub fn stamped_at(transcript: Transcript, index: Int) -> Option(Int) {
  dict.get(transcript.timestamps, index) |> option.from_result
}

/// The stamped epoch of the NEWEST assistant text message — the terminal
/// turn's bubble text. The session actor attaches this to the terminal
/// event (TurnDone/TurnStopped/guard-committed TurnFailed), so the UI's
/// live bubble commit carries exactly the value a post-reload replay
/// attaches to that message's AssistantFull: one clock, not two. `None`
/// when the newest assistant text carries no stamp (nothing committed,
/// or rows persisted before the sidecar existed) — an OLDER message's
/// stamp never leaks into a newer text's terminal event.
pub fn last_text_stamp(transcript: Transcript) -> Option(Int) {
  let total = list.length(transcript.messages)
  do_last_text_stamp(transcript, total - 1, transcript.messages)
}

/// Newest-first scan: stop at the FIRST assistant text — even when its
/// own stamp is `None` — and report that stamp, whatever it is.
fn do_last_text_stamp(
  transcript: Transcript,
  index: Int,
  messages: List(ChatMessage),
) -> Option(Int) {
  case messages {
    [] -> None
    [chat.AssistantMessage(content: Some(chat.AssistantTextContent(_)), ..), ..] ->
      stamped_at(transcript, index)
    [_, ..rest] -> do_last_text_stamp(transcript, index - 1, rest)
  }
}

/// Record reasoning against the message about to be appended (its
/// chronological index is the current message count). Empty strings are
/// dropped — there is no such thing as an empty reasoning entry.
fn attach_reasoning(
  transcript: Transcript,
  reasoning: Option(String),
) -> Dict(Int, String) {
  case reasoning {
    Some(text) if text != "" ->
      dict.insert(transcript.reasoning, list.length(transcript.messages), text)
    _ -> transcript.reasoning
  }
}

/// Build the request value (pure). This is the one construction path; both
/// `request_body` and the transport seam consume it.
pub fn to_request(
  transcript: Transcript,
  opts opts: Options,
) -> chat.CreateChatCompletionRequest {
  let req =
    chat.new_create_request(
      model: transcript.model,
      messages: messages(transcript),
    )
  let req = case opts.stream {
    True -> chat.with_stream(req, True)
    False -> req
  }
  let req = case opts.tools {
    [] -> req
    tools -> chat.with_tools(req, tools)
  }
  let req = case opts.tool_choice {
    Some(choice) -> chat.with_tool_choice(req, choice)
    None -> req
  }
  let req = case opts.max_completion_tokens {
    Some(n) -> chat.with_max_completion_tokens(req, n)
    None -> req
  }
  let req = case opts.temperature {
    Some(t) -> chat.with_temperature(req, t)
    None -> req
  }
  req
}

/// Deterministic JSON body for the transcript under `opts`. Byte-stable by
/// construction: same messages + same options => same bytes.
pub fn request_body(transcript: Transcript, opts: Options) -> String {
  transcript
  |> to_request(opts)
  |> chat.create_chat_completion_request_to_json
  |> json.to_string
}
