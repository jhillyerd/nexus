---
title: Nexus — web_fetch tool (HTML-to-Markdown, pagination, and fetch cache)
status: active — v1 (Phases 1–3) shipped in #159; v2 bounded decompression shipped 2026-11-22
tags: [computing, self-hosting, local-llm, agents, gleam, beam, tools, web-fetch]
updated: 2026-11-22
---

# `web_fetch`: readable web fetching with HTML-to-Markdown and pagination

**Thesis.** Introduce a higher-level `web_fetch` tool that fetches public web
pages with a generous bounded raw-byte budget, converts HTML into compact
Markdown via a pure-Erlang HTML5 parser, caches the extracted document in
memory for fast, offset-stable pagination, and replaces `http_fetch` in the
default toolset. `http_fetch` stays in the compiled catalog as an opt-in,
low-level raw HTTP tool (the curl-like escape hatch for bots without `bash`,
and so existing threads with frozen `http_fetch` manifests continue hydrating
untouched).

Design plan for [#39](https://github.com/jhillyerd/nexus/issues/39) ("Rename
`http_fetch`" — including its note on HTML compression and giving models
control over truncated results).

---

## Why not a utility-model query pass in v1

Many agent harnesses offer a `web_fetch(url, prompt)` mode that summarizes a
page through a secondary fast model. We deliberately defer that to a future
phase:

1. **Nexus has no separate utility model today.** `src/nexus/utility.gleam`
   piggybacks on the thread's own model and cached KV prefix for titles/tags.
   Running a second model mid-turn on a single-GPU local inference server
   (Ollama, llama.cpp) risks VRAM model-swapping or queueing behind the active
   turn.
2. **HTML conversion + pagination solves the real bottleneck first.** Today's
   20 KB raw byte cap on `http_fetch` often truncates modern pages inside
   `<head>`, inline CSS/SVG, and nav bars before the article even starts.
   Separating the raw wire cap (e.g. 1 MB) from the returned Markdown cap and
   adding offset pagination eliminates both token bloat and dead-end
   truncation — deterministically, offline-testably, and with zero extra LLM
   latency.
3. **Composable later.** Any future `prompt`/`extract` mode sits cleanly on top
   of the exact same HTML-to-Markdown + cache pipeline (feeding Markdown, not
   raw HTML, into the extractor).

---

## Design summary

### 1. Tool split and catalog placement

- **New compiled tool: `web_fetch`** (pairs with `web_search` in
  `tools.catalog_names()`, matches the Anthropic Claude API / Gemini CLI
  convention, and avoids colliding with the raw semantics of `http_fetch`).
- **Default toolset change (`src/nexus/tools.gleam`):**
  - `catalog_names()` includes both `"http_fetch"` and `"web_fetch"` (sorted).
  - `default_names(cfg)` includes `"web_fetch"` and excludes `"http_fetch"`
    (explicit opt-in via bot toolset picker or explicit create toolset — keeps
    the default schema lean and prevents models from hesitating between two
    fetch tools).
  - Existing threads with frozen `"http_fetch"` manifests continue resolving
    through `by_names_with` / manifest hydration with zero migration needed
    (frozen toolset invariant).
- **Codemode synergy:** `web_fetch` registers in `specs` before `codemode`, so
  Lua scripts automatically get `tools.web_fetch({url = ..., start_index = ...})`.

### 2. Wire schema and response shape

**Tool name:** `web_fetch`

**Description:** Concise guidance telling the model it fetches a public
`http(s)` URL, converts HTML to Markdown (passing plain text/Markdown/JSON
through), and supports paginated reading via `start_index` and `max_length`.

**Parameters JSON schema:**

```json
{
  "type": "object",
  "properties": {
    "url": {
      "type": "string",
      "description": "Absolute http:// or https:// URL to fetch"
    },
    "start_index": {
      "type": "integer",
      "minimum": 0,
      "description": "Character offset to start reading from (default 0). Use with has_more to read further chunks."
    },
    "max_length": {
      "type": "integer",
      "minimum": 1,
      "description": "Maximum number of characters to return (default 12000; clamped to server max)."
    }
  },
  "required": ["url"],
  "additionalProperties": false
}
```

- `start_index` defaults to `0`; negative values are rejected as argument
  errors (`Error(...)`).
- `max_length` defaults to `cfg.web_fetch_default_chars` (default `12_000`)
  and is clamped to `[1, cfg.web_fetch_max_chars]` (default ceiling `32_000`)
  so a model asking for `999_999` still stays bounded instead of blowing up
  its own context window.
- Slicing is **character/grapheme-based** (`string.length` / `string.slice`),
  never raw UTF-8 byte offsets, so multi-byte text is never split mid-codepoint.
- If `start_index >= total_chars` (on a non-empty document), return `content: ""`,
  `returned_chars: 0`, `has_more: false` (clean empty tail, not a crash).

**Success result (2xx — JSON string, inert tool content):**

```json
{
  "status": 200,
  "url": "https://example.com/final-after-redirects",
  "title": "Page Title",
  "content_type": "text/html; charset=utf-8",
  "format": "markdown",
  "total_chars": 28410,
  "start_index": 0,
  "returned_chars": 12000,
  "has_more": true,
  "raw_truncated": false,
  "cached": false,
  "content": "# Page Title\n\n..."
}
```

- `title` is omitted or `null` when absent (non-HTML or HTML without `<title>`).
- `format` is `"markdown"` (converted HTML or native `text/markdown`) or
  `"text"` (passed-through `text/plain`, `application/json`, `application/xml`,
  etc.).
- `raw_truncated` surfaces whether the upstream HTML/text hit the raw wire cap
  before conversion (so the model knows if the tail of a multi-MB page was cut
  off at the network boundary).
- **Non-2xx statuses and transport/SSRF errors** return `Error(...)` (same
  convention as `http_fetch`: rendered as failed tool content, never a loop
  error). Non-2xx responses are never cached.

### 3. Transport (`nexus/net` + `nexus_net_ffi.erl`)

Reuse `nexus/net`'s existing SSRF guard, manual per-hop redirect validation,
streaming byte cap, and hard per-hop deadline, with four focused updates:

1. **RFC 3986-correct relative redirect resolution (`nexus/net`):**
   `net.gleam`'s current `relative_to` helper prepends `/` to relative
   `Location` paths and discards the previous hop's directory path (so a
   redirect from `/docs/v1/intro.html` to `guide.html` wrongly resolves to
   `/guide.html`). Replace `resolve_location`/`relative_to` with `gleam/uri.merge`
   against the parsed previous hop URL (handling nested relative paths,
   `..` segments, query-only targets, and protocol-relative `//host/...`
   URLs per RFC 3986, still re-validating every hop through `validate_url`).
2. **Return `final_url` and `content_encoding` on `net.FetchResponse`:**
   - `do_fetch` already computes `validated.url` on each redirect hop; threading
     it onto `FetchResponse` lets `web_fetch` report the post-redirect URL and
     resolve relative HTML links accurately.
   - Read the `content-encoding` response header in `nexus_net_ffi.erl`
     (normalized lowercase, empty when absent) onto `FetchResponse`.
3. **Request headers and compression posture for `web_fetch`:**
   - Send `Accept: text/markdown, text/html;q=0.9, text/plain;q=0.8, */*;q=0.5`
     so Markdown-aware docs servers (Cloudflare Markdown for Agents, Mintlify,
     etc.) can serve clean Markdown directly without HTML parsing.
   - Send a clean, honest `User-Agent` (e.g. `nexus-web-fetch/1.0`) — some
     public docs/CDNs reject empty or default `hackney/...` user agents with
     403.
   - **Compression posture (v1):** Send `Accept-Encoding: identity` (do *not*
     advertise `gzip`/`deflate`/`br`), so the FFI's `MaxBytes` cap bounds real
     uncompressed bytes directly and structurally prevents decompression-bomb
     memory amplification. Because an origin may still ignore `Accept-Encoding`
     and return compressed bytes anyway, **reject any non-empty `content_encoding`
     other than `"identity"` before UTF-8 decoding or HTML parsing** with
     `Error("unsupported content-encoding: <encoding>")`. Bounded streaming
     decompression is deferred to a future phase if real-world origins require it.

     > **As-built delta (2026-11-22, v2): superseded.** Real-world origins did
     > require it. `web_fetch` now advertises `Accept-Encoding: gzip, deflate`
     > and decodes a single gzip/x-gzip/deflate coding through
     > `net.inflate_bounded` under `NEXUS_WEB_FETCH_MAX_DECOMPRESSED_BYTES` —
     > see the as-built deltas section for the full posture.
4. **Lossy UTF-8 decoding at the boundary:** Web pages occasionally emit
   non-UTF-8 bytes (Latin-1 / Windows-1252 / truncated multi-byte sequences at
   `MaxBytes`). After verifying identity encoding and non-binary `Content-Type`,
   decode response bytes lossily into valid UTF-8 (reusing the same Erlang
   pattern as `nexus_env_ffi:to_text_lossy/1`) before handing the body to the
   HTML parser or JSON encoder so malformed bytes never crash a turn.

### 4. Content-Type dispatch & HTML-to-Markdown (`nexus/html_markdown.gleam`)

**Parser dependency:** Add **`htmgrrrl`** (Gleam bindings by `lpil`,
Apache-2.0) over **`htmerl`** (`0.2.1`, pure-Erlang HTML 5.2 SAX parser). Zero
C/Rust NIFs, pure BEAM, handles broken real-world HTML (unclosed `<p>`/`<li>`,
void elements, HTML entities, malformed attributes) cleanly, and streams tokens
in a single pass without allocating a full DOM tree.

> **Verification gate before implementation:** Run `gleam add htmgrrrl` and
> confirm both clean compilation under the repo's Gleam + OTP 28 toolchain
> **and** that `htmgrrrl` exposes `htmerl`'s `{preserve_ws, true}` SAX option
> (required so whitespace-only text nodes inside `<pre>` and between inline
> tags are not dropped by `htmerl`'s default `preserve_ws: false`). If
> `htmgrrrl` lags behind OTP 28/stdlib or does not expose `preserve_ws`,
> depend directly on `htmerl` via a ~40-line `nexus_html_ffi.erl` wrapper
> passing `[{preserve_ws, true}]` — same pure-Erlang parser, zero risk.

**Content-Type handling** (strip parameters like `; charset=...`, lowercase):

| Media type | Behavior |
|---|---|
| `text/html`, `application/xhtml+xml` | Parse with `htmerl` → Markdown + extracted `<title>` |
| `text/markdown`, `text/x-markdown` | Pass through as-is (`format: "markdown"`) |
| `text/plain`, `application/json`, `application/xml`, `text/xml`, `text/csv`, `application/javascript`, `text/css`, `...+json`, `...+xml` | Pass through as-is (`format: "text"`) |
| Empty / missing `Content-Type` | Sniff leading non-whitespace for `<!doctype html` / `<html` → HTML, else pass through as text (rejecting if NUL bytes present) |
| Binary (`image/*`, `audio/*`, `video/*`, `application/pdf`, `application/octet-stream`, `application/zip`, etc.) | Return `Error("unsupported binary content-type: <type>")` |

**HTML-to-Markdown conversion rules (pure Gleam SAX state machine):**

- **Dropped subtrees** (track nesting depth so nested tags inside dropped
  blocks don't leak):
  - Always drop: `script`, `style`, `noscript`, `template`, `svg`, `iframe`,
    `canvas`, `object`, `embed`, `audio`, `video`, `form` (or keep text inside
    `<form>` only if it contains article prose — actually dropping `button`,
    `select`, `option`, `textarea`, `input` is safer than dropping `<form>`
    because some legacy sites wrap whole pages in `<form>`!).
  - Chrome/boilerplate drop: `nav`, `footer`, `aside` (with a safety fallback:
    if dropping chrome yields empty/near-empty output, re-run without dropping
    `nav`/`footer`/`aside` so minimal or oddly structured pages still return
    text).
  - `<head>`: capture `<title>` text, drop everything else (`meta`, `link`,
    `style`, `script`, etc.).
  - HTML comments (`<!-- ... -->`): dropped automatically by the SAX pass.
- **Block elements:**
  - `h1`–`h6` → `#` through `######` with blank-line separation.
  - `p`, `div`, `section`, `article`, `main`, `header`, `blockquote` →
    paragraph breaks; `blockquote` prefixes lines with `> `.
  - `br` → newline; `hr` → `\n---\n`.
  - `pre` / `pre > code` → fenced code block (`` ```lang `` when
    `class="language-..."` or `lang-...` is present), preserving whitespace
    verbatim inside `<pre>` (guaranteed by invoking the SAX parser with
    `preserve_ws: true` and applying whitespace normalization only outside
    `<pre>` in the converter state machine).
  - `ul` / `ol` / `li` → `- ` / `1. ` with nesting indentation.
  - `table` / `tr` / `th` / `td` → compact GFM Markdown tables (with graceful
    fallback for nested/irregular tables).
- **Inline elements:**
  - `a[href]` → `[label](resolved_url)`:
    - Resolve relative URLs against `final_url` (`uri.merge` / path helper).
    - Drop `javascript:`, `data:`, and `vbscript:` hrefs (keep label text only).
    - Collapse `[url](url)` or empty labels cleanly; skip icon-only links with
      no visible text (or use `alt` from a nested `<img>` if meaningful).
  - `code` (outside `<pre>`) → `` `text` ``.
  - `strong`/`b` → `**text**`, `em`/`i` → `*text*` (skip empty wrappers).
  - `img` → keep `alt` text only when non-empty and short (no `data:` URLs).
- **Whitespace normalization:**
  - Outside `<pre>`, collapse runs of ASCII spaces/tabs/newlines into single
    spaces; trim trailing spaces per line; collapse 3+ consecutive newlines
    into `\n\n`.
- **Hostile text invariant:** The output is plain Markdown text inside a JSON
  tool-result string, rendered by Lustre as text nodes (`src/nexus/ui.gleam`
  never uses `innerHTML`). No code execution or raw HTML passthrough.

### 5. In-memory fetch cache (`nexus/web_fetch_cache.gleam`)

**Purpose:** Make follow-up pagination calls (`start_index > 0`) instant and
offset-stable even on dynamic pages, and avoid hammering origin servers across
turns or bots.

**Cached value:**

```gleam
pub type CachedDoc {
  CachedDoc(
    status: Int,
    final_url: String,
    title: Option(String),
    content_type: String,
    format: String,
    content: String,
    total_chars: Int,
    raw_truncated: Bool,
  )
}
```

- **Key:** Normalized requested URL with the URI fragment (`#...`) stripped
  while retaining scheme, host (lowercased), port, path, and query parameters
  (fragments are client-side only and never alter the HTTP response, so anchor
  links to the same page hit the same cache entry). Only 2xx converted
  documents are stored; errors and non-2xx responses are never cached.
- **Bounds & eviction:**
  - **TTL:** `cfg.web_fetch_cache_ttl_ms` (default `600_000` = 10 minutes).
    Checked lazily on `get` and pruned on `put` using monotonic time
    (`timing.now_us()` / `timing.elapsed_ms`, behind an injectable clock fn for
    deterministic offline tests).
  - **Max entries:** `64` (const or config) and **max total cached bytes:**
    `16_777_216` (16 MiB). On `put`, first sweep expired entries, then evict
    least-recently-used (`last_access_ms`) until within both bounds. A single
    document larger than the total byte budget is simply not cached.
- **Process model & failure isolation:**
  - A small `gleam/otp/actor` registered under `process.Name(Msg)` at boot
    (like `bot_registry_name`), started in its own `OneForOne` child or
    independent sibling — **never** allowed to crash threads or fail turns.
  - Exposed to `web_fetch` via a small seam record:
    ```gleam
    pub type Seam {
      Seam(
        get: fn(String) -> Option(CachedDoc),
        put: fn(String, CachedDoc) -> Nil,
      )
    }
    ```
  - The live `seam(name)` resolves `process.named(name)` and wraps the bounded
    `actor.call` (e.g. 250 ms) with `rescue.rescue` (the repo's `try_send_named`
    discipline): if the cache actor is absent, restarting, or slow, `get`
    returns `None` and `put` is a no-op, degrading cleanly to an uncached
    direct fetch.
  - `Option(web_fetch_cache.Seam)` is threaded into `tools.by_names_with_cache`
    / `tools.by_entries_with` from `thread_registry` (wired at `boot.gleam`).
    `tools.by_names` and `tools.by_names_with` pass `None`, keeping bot
    validation and existing offline tests untouched.

### 6. Configuration (`src/nexus/config.gleam`)

Fail-fast validation at boot like every other knob; `web_fetch` reuses
`http_fetch_timeout_ms` and `http_fetch_allow_private` so SSRF/timeout policy
stays one shared knob across both HTTP tools:

| Env var | Default | Validation | Purpose |
|---|---|---|---|
| `NEXUS_WEB_FETCH_MAX_RAW_BYTES` | `1048576` (1 MiB) | `> 0` | Streaming raw response cap in `nexus_net_ffi` for `web_fetch` (bounds COMPRESSED wire bytes) |
| `NEXUS_WEB_FETCH_MAX_DECOMPRESSED_BYTES` | `8388608` (8 MiB) | `> 0` | Hard cap on decompressed bytes when decoding gzip/deflate; over-cap truncates with `raw_truncated` set (v2) |
| `NEXUS_WEB_FETCH_DEFAULT_CHARS` | `12000` | `> 0` | Default `max_length` when the model omits it |
| `NEXUS_WEB_FETCH_MAX_CHARS` | `32000` | `>= default_chars` | Hard upper clamp on `max_length` per call |
| `NEXUS_WEB_FETCH_CACHE_TTL_MS` | `600000` (10m) | `>= 0` (`0` disables cache) | In-memory extracted-doc TTL |

*(Update `README.md` env table and all `Config(...)` test constructors.)*

---

## As-built deltas

**v1 (Phases 1–3) shipped in
[#159](https://github.com/jhillyerd/nexus/pull/159) (2026-11-21).** The
implementation plan above landed essentially as written; deltas worth
recording:

- `title` is OMITTED from the result JSON when absent (the design allowed
  "omitted or null"; omission keeps absent titles invisible to models that
  branch on key presence).
- Non-2xx failures return a JSON error object
  `{"status":N,"error":"non-success status"}` (rendered as failed tool
  content, per the plan's convention).
- `web_fetch_cache` runs in its own standalone `OneForOne` supervisor
  started at boot OUTSIDE the `OneForAll` root (the plan offered either an
  isolated child or an independent sibling; the sibling keeps a cache crash
  from restarting threads by construction).
- `test/m3_prefix_test.gleam` pins its captured fixture to
  `tools.by_names(smoke_config(), ["http_fetch", "web_search"])` as
  planned, keeping the golden envelope byte-faithful to the capture.

**v2 (2026-11-22): bounded streaming decompression — replaces the v1
identity-only posture (§3 item 3 above).**

- `web_fetch` now sends `Accept-Encoding: gzip, deflate` and decodes a
  SINGLE supported coding — `gzip`, `x-gzip`, or `deflate` — via the new
  `net.inflate_bounded` (FFI `nexus_net_ffi:inflate_bounded/3`). `identity`
  tokens are filtered out of the header, so an `"identity, gzip"` list
  decodes; brotli, zstd, and stacked non-identity codings are still refused
  before any decoding, with all offending tokens named.
- **Boundedness:** the compressed body (already capped on the wire by
  `max_raw_bytes`) is fed to zlib in fixed 4 KiB slices with the accumulated
  output checked after every slice against
  `NEXUS_WEB_FETCH_MAX_DECOMPRESSED_BYTES`. Over-cap TRUNCATES —
  `raw_truncated` in the result now ORs the wire-cap flag and the
  inflate-cap flag, so the model sees one "the document was cut" signal.
  Peak memory is the cap plus one slice's worst-case expansion; post-hoc
  truncation would not have bounded allocation (the env-tools "cap while
  reading" rule).
- **Formats:** zlib auto-detection (windowBits 15+32) accepts gzip and
  zlib-wrapped deflate (RFC 1950); a `deflate` coding that fails there is
  retried as RAW deflate (windowBits -15) — servers that send RFC 1951
  bytes under the `deflate` token. Only the first gzip member of a
  multi-member stream is decoded (zlib ignores trailing member bytes —
  probe-verified; HTTP origins emit single members). A corrupt stream is
  the tool error `"failed to decode <coding>: corrupt compressed stream"`;
  an EMPTY body passes through untouched (nothing to decode); a
  wire-truncated gzip decodes partially with `raw_truncated` carried from
  the wire cap.
- **hackney does none of this:** the pinned hackney 1.25's manual
  `stream_body` path performs no content-encoding decoding (verified in
  source — its parser handles only transfer-encoding), so decompression is
  wholly nexus's, and `http_fetch` (which sends no `Accept-Encoding`)
  observes no behavior change.
- New knob `NEXUS_WEB_FETCH_MAX_DECOMPRESSED_BYTES` (default 8 MiB, `> 0`,
  fail-fast at boot, README row added). No cross-validation against
  `NEXUS_WEB_FETCH_MAX_RAW_BYTES`: a smaller decompressed cap is a
  legitimate aggressive-memory configuration, not a contradiction (the
  knobs bound different things — wire bytes vs expanded bytes).

## Phased implementation plan

### Phase 1 — Transport prep + pure HTML-to-Markdown converter
1. Add `htmgrrrl` (or `htmerl` + thin `nexus_html_ffi.erl` with
   `[{preserve_ws, true}]` if OTP 28 or missing `preserve_ws` requires it) in
   `gleam.toml` and verify `gleam build` + `gleam test`.
2. Update `nexus/net` and `nexus_net_ffi.erl`:
   - Fix relative redirect resolution using `gleam/uri.merge` (RFC 3986) and
     add nested-path / `..` / query-only relative redirect tests in
     `test/net_test.gleam`.
   - Extend `net.FetchResponse` with `final_url: String` and
     `content_encoding: String`, plus lossy UTF-8 decoding helper.
3. Create `src/nexus/html_markdown.gleam`:
   - `pub type Converted { Converted(title: Option(String), markdown: String) }`
   - `pub fn convert(html: String, base_url: String) -> Converted`
   - Always invoke `htmerl` with `preserve_ws: true` and normalize whitespace
     only outside `<pre>`.
   - Unit tests in `test/html_markdown_test.gleam`: headings, paragraphs,
     nested lists, `<pre><code>` indentation & blank-line preservation, inline
     tag boundary spacing (`<b>a</b> <i>b</i>`), links (absolute, relative,
     fragment, `javascript:` stripped), tables, `<script>`/`<style>`/`<svg>`/
     `<!-- comment -->` stripping, `<nav>`/`<footer>` drop + empty-body
     fallback, HTML entities, malformed/unclosed tags, non-UTF-8/Unicode.

### Phase 2 — Bounded TTL/LRU cache
1. Create `src/nexus/web_fetch_cache.gleam`:
   - Pure cache state + fragment-stripping key normalization + `Seam` +
     supervised OTP actor + rescued `named_seam`.
2. Unit tests in `test/web_fetch_cache_test.gleam` (offline, injected clock):
   - Hit/miss, fragment-stripping key equivalence (`#a` vs `#b`, query params
     preserved), TTL expiry, LRU eviction on entry count, eviction on byte cap,
     oversized doc skipped, dead/missing actor degrades to miss without
     crashing.

### Phase 3 — `web_fetch` tool + config + registry + boot wiring
1. Add the 4 `web_fetch_*` fields to `src/nexus/config.gleam` (+ validation
   tests in `test/config_test.gleam` and `README.md`).
2. Create `src/nexus/web_fetch.gleam`:
   - `schema()`, argument parsing/validation (`url`, `start_index`,
     `max_length`), non-identity `Content-Encoding` rejection, `Content-Type`
     dispatch, cache lookup/store, character pagination, JSON output encoding.
   - Inject the fetch fn (`fn(url, headers) -> Result(FetchResponse, String)`)
     into an inner `run_with` so `test/web_fetch_test.gleam` covers every path
     completely offline (HTML conversion, native `text/markdown` passthrough,
     JSON/plain passthrough, unsolicited `Content-Encoding: gzip` rejection,
     binary rejection, pagination across cached pages, fragment URL cache hit,
     `start_index` past end, `max_length` clamping, non-2xx not cached,
     SSRF/transport errors, `raw_truncated` propagation).
3. Update `src/nexus/tools.gleam`:
   - Add `"web_fetch"` to `catalog_names()`.
   - Update `default_names(cfg)`: include `"web_fetch"`, exclude
     `"http_fetch"` (so `http_fetch` becomes opt-in while staying resolvable
     for frozen snapshots and explicit bot toolsets).
   - Wire `web_fetch_spec(cfg, cache)` in `by_names_with_cache` /
     `by_entries_with`.
4. Update `src/nexus/boot.gleam` and `src/nexus/thread_registry.gleam`:
   - Start `web_fetch_cache` actor at boot (outside `OneForAll` or isolated so
     cache crashes never restart threads) when `web_fetch_cache_ttl_ms > 0`,
     and pass its `Option(web_fetch_cache.Seam)` into `thread_registry.start`.
5. Update existing tests affected by `default_names` switching from
   `"http_fetch"` to `"web_fetch"`:
   - `test/tools_test.gleam` (default name expectations; add explicit test that
     `"http_fetch"` remains in `catalog_names()` and resolves via `by_names`).
   - `test/thread_registry_test.gleam` / `test/m3_prefix_test.gleam` (pin
     `m3_prefix_test`'s captured smoke envelope to `tools.by_names(smoke_config(), ["http_fetch", "web_search"])`
     so it keeps testing the captured fixture faithfully).
   - Test `Config(...)` struct literals across `test/*_test.gleam`.
6. Run full `gleam test` (offline, zero network) and update `AGENTS.md` with
   the new `web_fetch` invariants if warranted.

---

## Future phases (out of scope for v1)

- **Phase 4 — Utility-model extraction (`prompt` / `query` parameter):**
  Once Nexus has a configured fast/utility model (or explicit sub-call policy
  safe for local GPUs), add an optional `prompt: String` parameter to
  `web_fetch` that runs over the cached Markdown document and returns a focused
  answer.
- **Phase 5 — `http_fetch` curl upgrades:**
  Now that `http_fetch` is cleanly separated as the low-level opt-in tool for
  bots without `bash`, it can grow optional `method`, custom `headers`,
  response headers, and request `body` without bloating `web_fetch`'s schema.
- **Readability scoring:** If heuristic `<nav>`/`<footer>`/`<aside>` dropping
  leaves too much clutter on news/blog sites, add a pure-Gleam link-density /
  text-density scorer over the parsed block tree behind the same
  `html_markdown.convert` seam.
