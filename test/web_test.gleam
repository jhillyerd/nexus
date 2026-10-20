//// Offline tests for the pure halves of the web layer: auth, route
//// metadata, JSON wire formats, and safe page rendering.

import gleam/http.{Delete, Get, Patch, Post}

import gleam/http/request
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import nexus/page as nexus_page
import nexus/provider
import nexus/provider_registry
import nexus/session
import nexus/session_registry
import nexus/web

fn req_with_token_query() -> request.Request(String) {
  // The WS handshake (and the runtime script tag) authenticate with the
  // token query parameter: a plain <script src> cannot set headers.
  let assert Ok(req) = request.to("http://127.0.0.1:8080/ws?token=sekrit")
  req
}

pub fn auth_disabled_when_token_unset_test() {
  let req = request.new()
  web.authorized(req, None) |> should.be_true
}

pub fn auth_via_bearer_header_test() {
  let req =
    request.new()
    |> request.set_header("authorization", "Bearer sekrit")
  web.authorized(req, Some("sekrit")) |> should.be_true
  web.authorized(req, Some("wrong")) |> should.be_false
}

pub fn auth_via_query_param_test() {
  // The WebSocket handshake and the runtime asset URL carry ?token=,
  // since a plain <script src> cannot set headers.
  web.authorized(req_with_token_query(), Some("sekrit")) |> should.be_true
  web.authorized(req_with_token_query(), Some("wrong")) |> should.be_false
}

pub fn auth_missing_is_rejected_test() {
  web.authorized(request.new(), Some("sekrit")) |> should.be_false
  // A wrong header alone is not rescued by an absent query param.
  let req = request.new() |> request.set_header("authorization", "Bearer wrong")
  web.authorized(req, Some("sekrit")) |> should.be_false
}

pub fn models_json_test() {
  let data = json.to_string(web.models_json(["alias-a", "alias-b"]))
  data
  |> should.equal("{\"models\":[\"alias-a\",\"alias-b\"]}")
}

pub fn sessions_json_test() {
  let sample =
    session.MetricSample(
      outcome: session.Failed,
      ttft_ms: None,
      duration_ms: 25,
      token_deltas: 1,
      prompt_tokens: None,
      cached_tokens: None,
      stopped_chars: None,
      failure_reason: Some("upstream"),
    )
  let summary =
    session.SessionSummary(
      id: "s-2",
      provider_id: "p1",
      model: "alias-b",
      title: "renamed by hand",
      title_source: session.ManualTitle,
      pinned: True,
      tags: ["work", "notes"],
      archived: False,
      message_count: 4,
      streaming: True,
      created_at: 1_729_000_000,
      last_active_at: 1_729_003_600,
      metrics: [sample],
    )
  let data = json.to_string(web.sessions_json([summary]))
  should.be_true(string.contains(data, "\"sessions\":["))
  should.be_true(string.contains(data, "\"id\":\"s-2\""))
  // The pinned provider is part of the summary wire shape (multi-provider
  // §11): the id is the stable key — display names resolve caller-side.
  should.be_true(string.contains(data, "\"provider_id\":\"p1\""))
  should.be_true(string.contains(data, "\"model\":\"alias-b\""))
  should.be_true(string.contains(data, "\"message_count\":4"))
  should.be_true(string.contains(data, "\"streaming\":true"))
  should.be_true(string.contains(data, "\"outcome\":\"failed\""))
  should.be_true(string.contains(data, "\"failure_reason\":\"upstream\""))
  // M3 organization metadata rides beside the transcript.
  should.be_true(string.contains(data, "\"title\":\"renamed by hand\""))
  should.be_true(string.contains(data, "\"title_source\":\"manual\""))
  should.be_true(string.contains(data, "\"pinned\":true"))
  should.be_true(string.contains(data, "\"tags\":[\"work\",\"notes\"]"))
  should.be_true(string.contains(data, "\"archived\":false"))
  should.be_true(string.contains(data, "\"created_at\":1729000000"))
  should.be_true(string.contains(data, "\"last_active_at\":1729003600"))
  should.be_true(string.contains(
    data,
    "\"created_at_rfc3339\":\"2024-10-15T13:46:40Z\"",
  ))
  should.be_true(string.contains(
    data,
    "\"last_active_rfc3339\":\"2024-10-15T14:46:40Z\"",
  ))
}

pub fn auto_title_test() {
  // Short message: trimmed, whitespace collapsed, no ellipsis.
  session_registry.title_from_first_message("  hello   there  ")
  |> should.equal("hello there")
  session_registry.title_from_first_message("line one\nline two\tand\r\ntabs")
  |> should.equal("line one line two and tabs")
  // Truncation at 60 characters with an ellipsis.
  let long = string.repeat("ab ", 50)
  let titled = session_registry.title_from_first_message(long)
  should.be_true(string.length(titled) == 61)
  should.be_true(string.ends_with(titled, "…"))
  // The collapsed prefix survives intact.
  should.be_true(string.starts_with(titled, "ab ab ab"))
}

pub fn filter_archived_test() {
  let active = summary_with_archived("s-1", False)
  let archived = summary_with_archived("s-2", True)
  let all = [active, archived]
  web.filter_archived(all, False) |> should.equal([active])
  web.filter_archived(all, True) |> should.equal([archived])
}

fn summary_with_archived(id: String, archived: Bool) -> session.SessionSummary {
  session.SessionSummary(
    id: id,
    provider_id: "p1",
    model: "alias-b",
    title: "",
    title_source: session.AutoTitle,
    pinned: False,
    tags: [],
    archived: archived,
    message_count: 0,
    streaming: False,
    created_at: 0,
    last_active_at: 0,
    metrics: [],
  )
}

pub fn patch_body_decoders_test() {
  // Present keys decode; absent keys stay None (untouched).
  let assert Ok(full) =
    web.parse_patch_json(
      "{\"title\":\"new name\",\"pinned\":true,\"tags\":[\"a\",\"b\"],\"archived\":false}",
    )
  should.equal(full.title, Some("new name"))
  should.equal(full.pinned, Some(True))
  should.equal(full.tags, Some(["a", "b"]))
  should.equal(full.archived, Some(False))

  let assert Ok(partial) = web.parse_patch_json("{\"pinned\":true}")
  should.equal(partial.title, None)
  should.equal(partial.tags, None)

  // Explicit nulls read as absent.
  let assert Ok(nulled) = web.parse_patch_json("{\"title\":null}")
  should.equal(nulled.title, None)

  // Wrong types still fail loudly.
  web.parse_patch_json("{\"pinned\":\"yes\"}") |> should.equal(Error(Nil))
  web.parse_patch_json("not json") |> should.equal(Error(Nil))
}

pub fn request_body_decoders_test() {
  web.parse_text_json("{\"text\":\"hello\"}")
  |> should.equal(Ok("hello"))
  // POST /sessions now pins provider + model (multi-provider §11).
  web.parse_create_json("{\"provider\":\"p1\",\"model\":\"alias-a\"}")
  |> should.equal(Ok(web.CreateFields(provider: "p1", model: "alias-a")))
  web.parse_text_json("{\"model\":\"alias-a\"}")
  |> should.equal(Error(Nil))
  web.parse_create_json("{\"model\":\"alias-a\"}")
  |> should.equal(Error(Nil))
  web.parse_create_json("{\"provider\":\"p1\"}")
  |> should.equal(Error(Nil))
}

pub fn provider_body_decoders_test() {
  // Create: name + base_url required, api_key optional (keyless).
  let assert Ok(full) =
    web.parse_provider_create_json(
      "{\"name\":\"Bifrost\",\"base_url\":\"https://gw.test/v1/\",\"api_key\":\"sk-1\"}",
    )
  should.equal(full.name, "Bifrost")
  should.equal(full.api_key, Some("sk-1"))
  let assert Ok(keyless) =
    web.parse_provider_create_json(
      "{\"name\":\"Ollama\",\"base_url\":\"http://127.0.0.1:11434/v1\"}",
    )
  should.equal(keyless.api_key, None)
  // Explicit null api_key reads as keyless.
  let assert Ok(nulled) =
    web.parse_provider_create_json(
      "{\"name\":\"x\",\"base_url\":\"https://x.test/v1\",\"api_key\":null}",
    )
  should.equal(nulled.api_key, None)
  web.parse_provider_create_json("{\"name\":\"x\"}")
  |> should.equal(Error(Nil))
  web.parse_provider_create_json("{\"base_url\":\"https://x.test/v1\"}")
  |> should.equal(Error(Nil))
  web.parse_provider_create_json("not json")
  |> should.equal(Error(Nil))

  // Patch: present keys decode; absent and explicit-null keys keep.
  let assert Ok(patch) =
    web.parse_provider_patch_json(
      "{\"name\":\"y\",\"base_url\":\"https://y.test/v1\",\"api_key\":\"sk-2\",\"enabled\":false}",
    )
  should.equal(patch.name, Some("y"))
  should.equal(patch.base_url, Some("https://y.test/v1"))
  should.equal(patch.api_key, Some("sk-2"))
  should.equal(patch.enabled, Some(False))
  let assert Ok(partial) = web.parse_provider_patch_json("{\"enabled\":true}")
  should.equal(partial.name, None)
  should.equal(partial.base_url, None)
  should.equal(partial.api_key, None)
  should.equal(partial.enabled, Some(True))
  let assert Ok(nulled_patch) =
    web.parse_provider_patch_json("{\"name\":null,\"api_key\":null}")
  should.equal(nulled_patch.name, None)
  should.equal(nulled_patch.api_key, None)
  web.parse_provider_patch_json("{\"enabled\":\"yes\"}")
  |> should.equal(Error(Nil))
  web.parse_provider_patch_json("[]") |> should.equal(Error(Nil))
}

pub fn providers_json_test() {
  let p =
    provider.Provider(
      id: "p1",
      name: "Bifrost",
      base_url: "https://gw.test/v1",
      dialect: "openai",
      enabled: True,
      has_key: True,
      created_at: 1_729_000_000,
      updated_at: 1_729_003_600,
    )
  let data = json.to_string(web.providers_json([p]))
  should.be_true(string.contains(data, "\"providers\":["))
  should.be_true(string.contains(data, "\"id\":\"p1\""))
  should.be_true(string.contains(data, "\"name\":\"Bifrost\""))
  should.be_true(string.contains(data, "\"base_url\":\"https://gw.test/v1\""))
  should.be_true(string.contains(data, "\"dialect\":\"openai\""))
  should.be_true(string.contains(data, "\"enabled\":true"))
  should.be_true(string.contains(data, "\"has_key\":true"))
  should.be_true(string.contains(data, "\"created_at\":1729000000"))
  should.be_true(string.contains(data, "\"updated_at\":1729003600"))
  should.be_true(string.contains(
    data,
    "\"created_at_rfc3339\":\"2024-10-15T13:46:40Z\"",
  ))
  should.be_true(string.contains(
    data,
    "\"updated_at_rfc3339\":\"2024-10-15T14:46:40Z\"",
  ))
  // The masked record cannot carry key material — and the wire shape has
  // no field for it either.
  should.be_false(string.contains(data, "api_key"))
  should.be_false(string.contains(data, "encrypted"))
}

/// The registry's closed error vocabulary maps onto the plan's §11
/// statuses with `describe`'s fixed text.
pub fn registry_error_fields_test() {
  web.registry_error_fields(provider_registry.Unknown)
  |> should.equal(#(404, "unknown provider"))
  web.registry_error_fields(provider_registry.Disabled)
  |> should.equal(#(400, "provider is disabled"))
  web.registry_error_fields(provider_registry.InvalidName)
  |> should.equal(#(400, "provider name must be non-empty after trimming"))
  web.registry_error_fields(provider_registry.InvalidBaseUrl)
  |> should.equal(#(
    400,
    "provider base URL should be the OpenAI-compatible base ending in /v1",
  ))
  web.registry_error_fields(provider_registry.DuplicateName)
  |> should.equal(#(409, "provider name already exists"))
  web.registry_error_fields(provider_registry.StillReferenced)
  |> should.equal(#(
    409,
    "provider is still pinned by sessions; disable it instead",
  ))
  web.registry_error_fields(provider_registry.DecryptFailed)
  |> should.equal(#(
    500,
    "decryption failed: wrong key, provider, or tampered data",
  ))
  web.registry_error_fields(provider_registry.KeyOperationFailed)
  |> should.equal(#(500, "provider key operation failed"))
  // Store/list failures surface their sanitized text with 502.
  web.registry_error_fields(provider_registry.StoreFailed("store down"))
  |> should.equal(#(502, "store down"))
  web.registry_error_fields(provider_registry.ModelsFailed(
    "model list failed: HTTP 503",
  ))
  |> should.equal(#(502, "model list failed: HTTP 503"))
}

pub fn protected_route_matrix_test() {
  [
    #(Get, []),
    #(Get, ["sessions"]),
    #(Post, ["sessions"]),
    #(Post, ["sessions", "s-1", "send"]),
    #(Post, ["sessions", "s-1", "stop"]),
    // M3 organization: metadata + deletion sit behind the same gate.
    #(Patch, ["sessions", "s-1"]),
    #(Delete, ["sessions", "s-1"]),
    // P4: the whole provider management surface (§11 — all provider
    // routes require NEXUS_UI_TOKEN when set).
    #(Get, ["providers"]),
    #(Post, ["providers"]),
    #(Get, ["providers", "p-1", "models"]),
    #(Patch, ["providers", "p-1"]),
    #(Delete, ["providers", "p-1"]),
    // M3: the Lustre client runtime asset and the WebSocket transport sit
    // behind the same token gate as the page itself.
    #(Get, ["lustre", "runtime.mjs"]),
    #(Get, ["ws"]),
  ]
  |> list.each(fn(route) {
    let #(method, segments) = route
    web.requires_auth(method, segments) |> should.be_true
  })
  web.requires_auth(Get, ["healthz"]) |> should.be_false
  web.requires_auth(Get, ["nope"]) |> should.be_false
  // GET /models was removed at the P3 hard cut (no default provider);
  // an unknown path stays unprotected-but-404 like before.
  web.requires_auth(Get, ["models"]) |> should.be_false
  web.requires_auth(Delete, ["models"]) |> should.be_false
}

pub fn m3_page_hosts_server_component_test() {
  let html = nexus_page.html(None)
  should.be_false(string.contains(html, "innerHTML"))
  should.be_true(string.contains(html, "<lustre-server-component"))
  should.be_true(string.contains(html, "route=\"/ws\""))
  should.be_true(string.contains(html, "/lustre/runtime.mjs"))
  should.be_true(string.contains(html, "type=\"module\""))
  // The token never enters JavaScript: no inline script beyond the module.
  should.be_false(string.contains(html, "Bearer"))
}

/// The connection dot must be driven client-side: a dropped backend cannot
/// deliver the "off" render, so the page mirrors the client runtime's own
/// `lustre:close` / `lustre:connect` events onto the dot.
pub fn m3_page_indicator_script_test() {
  let html = nexus_page.html(None)
  should.be_true(string.contains(html, "lustre:close"))
  should.be_true(string.contains(html, "lustre:connect"))
  // It toggles the dot classes the server-rendered stylesheet knows.
  should.be_true(string.contains(html, "'dot off'"))
  should.be_true(string.contains(html, "'dot live'"))
  // It reaches the dot through the open shadow root, not innerHTML.
  should.be_true(string.contains(html, "getElementById('status')"))
  should.be_false(string.contains(html, "innerHTML"))
}

/// Under auth, a plain `<script src>` cannot send an Authorization header,
/// so the runtime asset URL must carry the token like the ws route does.
pub fn m3_page_tokenizes_runtime_src_test() {
  let html = nexus_page.html(Some("s3cret token"))
  should.be_true(string.contains(
    html,
    "/lustre/runtime.mjs?token=s3cret%20token",
  ))
  should.be_true(string.contains(html, "route=\"/ws?token=s3cret%20token\""))
  // The inline indicator script is static: the token never enters it.
  should.be_false(string.contains(html, "Bearer"))
}

pub fn m3_page_route_carries_token_test() {
  let html = nexus_page.html(Some("sekrit"))
  should.be_true(string.contains(html, "route=\"/ws?token=sekrit\""))
  // Exactly two token occurrences (runtime src + ws route): never a third
  // hiding in the inline indicator script.
  string.split(html, "sekrit")
  |> list.length
  |> should.equal(3)
}

pub fn ws_route_token_encoding_test() {
  nexus_page.ws_route(None) |> should.equal("/ws")
  nexus_page.ws_route(Some("a b&c"))
  |> should.equal("/ws?token=a%20b%26c")
}
