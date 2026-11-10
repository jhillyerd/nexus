//// The M3 page shell: server-rendered HTML hosting the Lustre server
//// component. The page carries no client-side application code — just the
//// prebuilt Lustre client runtime, a `<lustre-server-component>` element
//// whose `route` points at the WebSocket transport, and four tiny static
//// scripts (see `indicator_js`, `thread_js`, `autoscroll_js`, and
//// `timestamps_js`).
////
//// The bearer token (when auth is on) is echoed into the route's query
//// string server-side, mirroring the M2 `?token=` convention: the token
//// never enters JavaScript. The same query string carries the
//// client-supplied last-selected thread back to the server (per-client
//// runtimes: `thread_js` persists it and re-supplies it on connect so a
//// reload re-opens the same thread).

import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/uri

/// `route` attribute for the component element. The token rides the query
/// string (the WebSocket handshake cannot set headers), exactly like M2.
pub fn ws_route(token: Option(String)) -> String {
  case token {
    None -> "/ws"
    Some(t) -> "/ws?token=" <> uri.percent_encode(t)
  }
}

/// `src` for the Lustre client runtime. A plain `<script>` cannot send an
/// Authorization header, so (like the ws route) the token rides the query
/// string — otherwise the asset 401s and the whole UI dies under auth.
pub fn runtime_src(token: Option(String)) -> String {
  case token {
    None -> "/lustre/runtime.mjs"
    Some(t) -> "/lustre/runtime.mjs?token=" <> uri.percent_encode(t)
  }
}

/// `href` for the vendored Pico stylesheet. Like the runtime asset, a plain
/// `<link>` cannot send an Authorization header, so the token rides the
/// query string. The stylesheet sits before the inline `<style>` in the
/// head: the client runtime adopts document stylesheets in document order
/// into the shadow root, so Pico is the baseline and `css()` overrides it.
pub fn pico_href(token: Option(String)) -> String {
  case token {
    None -> "/css/pico.min.css"
    Some(t) -> "/css/pico.min.css?token=" <> uri.percent_encode(t)
  }
}

pub fn html(token: Option(String)) -> String {
  string.concat([
    "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
      <> "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
      <> "<title>nexus</title>\n"
      <> "<link rel=\"stylesheet\" href=\""
      <> pico_href(token),
    "\">\n<style>\n",
    css(),
    "</style>\n<script type=\"module\" src=\"",
    runtime_src(token),
    "\"></script>\n"
      <> "</head>\n<body>\n"
      <> "<lustre-server-component route=\"",
    ws_route(token),
    "\"></lustre-server-component>\n<script>\n",
    indicator_js(),
    "\n",
    thread_js(),
    "\n",
    autoscroll_js(),
    "\n",
    timestamps_js(),
    "\n</script>\n</body>\n</html>\n",
  ])
}

/// The connection dot lives in the component's server-rendered view, but a
/// dropped backend can never deliver the "off" render — there is no socket
/// left to send it on, so the browser would keep the last green frame
/// forever (the M2 hand-written client set it red on stream error, and that
/// behaviour was lost in the Lustre migration). Only the browser knows its
/// own connection state, so this static script mirrors the client runtime's
/// own transport events — `lustre:close` / `lustre:connect` dispatched on the
/// host element — onto the `#status` dot inside its (open) shadow root, and
/// onto its text twin `#status-label` (ui-polish F8: "connected"/"offline",
/// so the state is legible without color). A reconnect remounts the full
/// server view, which resets both to truth. The script is static and
/// token-free; auth still rides the query string.
fn indicator_js() -> String {
  "(function () {\n"
  <> "  'use strict';\n"
  <> "  var host = document.querySelector('lustre-server-component');\n"
  <> "  if (!host) return;\n"
  <> "  var setStatus = function (live) {\n"
  <> "    var root = host.shadowRoot;\n"
  <> "    var dot = root && root.getElementById('status');\n"
  <> "    var label = root && root.getElementById('status-label');\n"
  <> "    if (dot) {\n"
  <> "      dot.className = live ? 'dot live' : 'dot off';\n"
  <> "      dot.textContent = live ? '●' : '○';\n"
  <> "    }\n"
  <> "    if (label) {\n"
  <> "      label.textContent = live ? 'connected' : 'offline';\n"
  <> "    }\n"
  <> "  };\n"
  <> "  host.addEventListener('lustre:close', function () { setStatus(false); });\n"
  <> "  host.addEventListener('lustre:connect', function () { setStatus(true); });\n"
  <> "})();"
}

/// Per-client runtime break: each /ws connection owns its model, so a
/// reload must tell the fresh runtime which thread to re-open. This
/// static script is the only client-side keeper of that choice. Storage is
/// `sessionStorage` — per-tab and reload-surviving, so one tab's selection
/// never leaks into another tab's restore (a brand-new tab falls back to
/// the server's auto-selection). Before the runtime module loads (it is
/// deferred; this classic script runs during parsing) it appends the
/// stored thread to the `route` attribute's query string; once the
/// component renders it mirrors the server-rendered
/// `#layout[data-selected]` back into storage, and on `lustre:close` it
/// re-syncs the route's `thread` parameter with the CURRENT selection so
/// a reconnect without a reload re-opens what this tab is looking at, not
/// what it opened at load. The script is static, token-free, and never
/// touches the rendered DOM — auth still rides the query string.
fn thread_js() -> String {
  "(function () {\n"
  <> "  'use strict';\n"
  <> "  var host = document.querySelector('lustre-server-component');\n"
  <> "  if (!host) return;\n"
  <> "  var read = function () {\n"
  <> "    try { return sessionStorage.getItem('nexus.thread'); } catch (e) { return null; }\n"
  <> "  };\n"
  <> "  var write = function (id) {\n"
  <> "    try {\n"
  <> "      if (id) sessionStorage.setItem('nexus.thread', id);\n"
  <> "      else sessionStorage.removeItem('nexus.thread');\n"
  <> "    } catch (e) {}\n"
  <> "  };\n"
  <> "  var currentId = function () {\n"
  <> "    var layout = host.shadowRoot && host.shadowRoot.getElementById('layout');\n"
  <> "    return layout ? (layout.getAttribute('data-selected') || '') : null;\n"
  <> "  };\n"
  <> "  // Pre-connect: append this tab's last-selected thread to the ws\n"
  <> "  // route. The attribute is final before the element upgrades, so\n"
  <> "  // the runtime connects once, with the thread in hand.\n"
  <> "  var stored = read();\n"
  <> "  if (stored) {\n"
  <> "    var route = host.getAttribute('route');\n"
  <> "    if (route) {\n"
  <> "      var url = new URL(route, location.href);\n"
  <> "      url.searchParams.set('thread', stored);\n"
  <> "      host.setAttribute('route', url.pathname + url.search);\n"
  <> "    }\n"
  <> "  }\n"
  <> "  var persist = function () {\n"
  <> "    var id = currentId();\n"
  <> "    if (id === null) return;\n"
  <> "    write(id);\n"
  <> "  };\n"
  <> "  // A reconnect (no reload) re-uses the route attribute, so sync it\n"
  <> "  // with the current selection whenever the transport drops: the\n"
  <> "  // next connect then re-opens what this tab is looking at. The\n"
  <> "  // attribute is only touched when the parameter actually changes.\n"
  <> "  var syncRoute = function () {\n"
  <> "    var id = currentId();\n"
  <> "    if (id === null) return;\n"
  <> "    write(id);\n"
  <> "    var route = host.getAttribute('route');\n"
  <> "    if (!route) return;\n"
  <> "    var url = new URL(route, location.href);\n"
  <> "    var carried = url.searchParams.get('thread') || '';\n"
  <> "    if (carried === id) return;\n"
  <> "    if (id) url.searchParams.set('thread', id);\n"
  <> "    else url.searchParams.delete('thread');\n"
  <> "    host.setAttribute('route', url.pathname + url.search);\n"
  <> "  };\n"
  <> "  var watch = function () {\n"
  <> "    if (!host.shadowRoot || host.__nexusSel) return;\n"
  <> "    host.__nexusSel = true;\n"
  <> "    new MutationObserver(persist).observe(host.shadowRoot, {\n"
  <> "      subtree: true,\n"
  <> "      childList: true,\n"
  <> "      attributeFilter: ['data-selected'],\n"
  <> "    });\n"
  <> "    persist();\n"
  <> "  };\n"
  <> "  host.addEventListener('lustre:close', syncRoute);\n"
  <> "  host.addEventListener('lustre:connect', watch);\n"
  <> "})();"
}

/// Auto-follow for the chat log (`#log`): only the browser knows the
/// scroll position and the user's scroll intent, so (like the indicator
/// and thread scripts) a static script owns what the server view
/// cannot. While the log sits near its bottom the latest content is kept
/// in view — every streamed chunk scrolls immediately (`scrollTop =
/// scrollHeight`, no debounce, no overshoot) with one animation-frame
/// follow-up for late layout. An explicit upward gesture (wheel up,
/// touch drag, arrow/page/home keys, or a scrollbar drag — recognized
/// even inside the echo window by the position check in `onScroll`)
/// unpins at once so a quick flick beats the stream; any other scroll
/// re-pins near the bottom. The
/// server renders the inert `#jump-latest` button (`nexus/ui`); this
/// script mirrors the pin state onto its `hidden` attribute and handles
/// clicks by delegation on the shadow root, so the press never
/// round-trips through the server. Opening or switching a thread
/// (`#layout[data-selected]`) or a remount re-opens at the latest
/// message, following again. The script is static and token-free; auth
/// still rides the query string.
fn autoscroll_js() -> String {
  "(function () {\n"
  <> "  'use strict';\n"
  <> "  var host = document.querySelector('lustre-server-component');\n"
  <> "  if (!host) return;\n"
  <> "  var THRESHOLD = 80; // px from the bottom that still counts as following\n"
  <> "  var ECHO_MS = 150; // scroll events this soon after our own set are echoes\n"
  <> "  var root = null;\n"
  <> "  var log = null;\n"
  <> "  var pinned = true;\n"
  <> "  var lastSet = 0;\n"
  <> "  var lastSetTop = -1;\n"
  <> "  var lastSetHeight = -1;\n"
  <> "  var waiting = null;\n"
  <> "  var syncButton = function () {\n"
  <> "    // hidden mirrors the pin: following -> hidden, reading -> shown.\n"
  <> "    var btn = root && root.getElementById('jump-latest');\n"
  <> "    if (btn && btn.hidden !== pinned) btn.hidden = pinned;\n"
  <> "  };\n"
  <> "  // A scrollTop drop is a scrollbar drag only while the content holds\n"
  <> "  // still. Growth never lowers scrollTop, but SHRINKAGE does: the\n"
  <> "  // browser clamps scrollTop when scrollHeight falls, and the\n"
  <> "  // bubble -> chips -> bubble transition shrinks twice — the live\n"
  <> "  // thinking block collapses when it commits, and a tool card\n"
  <> "  // collapses when its call completes. The clamp lands materially\n"
  <> "  // below the last set even though the user never moved, so a drop\n"
  <> "  // explained by a shrink keeps following; only an unchanged-height\n"
  <> "  // drop unpins.\n"
  <> "  var dragged = function () {\n"
  <> "    return (\n"
  <> "      log.scrollTop < lastSetTop - 4 &&\n"
  <> "      log.scrollHeight >= lastSetHeight - 4\n"
  <> "    );\n"
  <> "  };\n"
  <> "  var toBottom = function () {\n"
  <> "    if (!log) return;\n"
  <> "    // Never yank a position the user moved — see dragged().\n"
  <> "    if (dragged()) {\n"
  <> "      unpin();\n"
  <> "      return;\n"
  <> "    }\n"
  <> "    lastSet = performance.now();\n"
  <> "    log.scrollTop = log.scrollHeight;\n"
  <> "    lastSetTop = log.scrollTop; // read back the CLAMPED position\n"
  <> "    lastSetHeight = log.scrollHeight;\n"
  <> "    requestAnimationFrame(function () {\n"
  <> "      if (!log || !pinned) return;\n"
  <> "      // The frame gap is exactly where a drag lands unseen (its\n"
  <> "      // scroll event may not have fired yet), so the same guard.\n"
  <> "      if (dragged()) {\n"
  <> "        unpin();\n"
  <> "        return;\n"
  <> "      }\n"
  <> "      lastSet = performance.now();\n"
  <> "      log.scrollTop = log.scrollHeight;\n"
  <> "      lastSetTop = log.scrollTop;\n"
  <> "      lastSetHeight = log.scrollHeight;\n"
  <> "    });\n"
  <> "  };\n"
  <> "  // Forced jumps (open, thread switch, button click) re-pin and\n"
  <> "  // reset the moved-position detector: the fresh content's scrollTop\n"
  <> "  // is not comparable to the previous content's last set.\n"
  <> "  var forceBottom = function () {\n"
  <> "    pinned = true;\n"
  <> "    lastSetTop = -1;\n"
  <> "    lastSetHeight = -1;\n"
  <> "    toBottom();\n"
  <> "    syncButton();\n"
  <> "  };\n"
  <> "  var onScroll = function () {\n"
  <> "    // Suppress the echo of our own set — unless the position moved\n"
  <> "    // somewhere we never put it: we only ever set the bottom, so a\n"
  <> "    // scrollTop materially below the last set position is a scrollbar\n"
  <> "    // drag (content growth never lowers scrollTop) and must unpin,\n"
  <> "    // echo window or not.\n"
  <> "    if (\n"
  <> "      performance.now() - lastSet < ECHO_MS &&\n"
  <> "      log.scrollTop >= lastSetTop - 4\n"
  <> "    )\n"
  <> "      return;\n"
  <> "    pinned = log.scrollHeight - log.scrollTop - log.clientHeight\n"
  <> "      < THRESHOLD;\n"
  <> "    syncButton();\n"
  <> "  };\n"
  <> "  var unpin = function () {\n"
  <> "    if (pinned) {\n"
  <> "      pinned = false;\n"
  <> "      syncButton();\n"
  <> "    }\n"
  <> "  };\n"
  <> "  var logReady = function (el) {\n"
  <> "    log = el;\n"
  <> "    if (log.__nexusFollow) return;\n"
  <> "    log.__nexusFollow = true;\n"
  <> "    log.addEventListener('scroll', onScroll, { passive: true });\n"
  <> "    log.addEventListener(\n"
  <> "      'wheel',\n"
  <> "      function (e) {\n"
  <> "        if (e.deltaY < 0) unpin();\n"
  <> "      },\n"
  <> "      { passive: true }\n"
  <> "    );\n"
  <> "    log.addEventListener('touchmove', unpin, { passive: true });\n"
  <> "    log.addEventListener('keydown', function (e) {\n"
  <> "      if (e.key === 'ArrowUp' || e.key === 'PageUp' || e.key === 'Home')\n"
  <> "        unpin();\n"
  <> "    });\n"
  <> "    new MutationObserver(function () {\n"
  <> "      if (pinned) toBottom();\n"
  <> "    }).observe(log, {\n"
  <> "      childList: true,\n"
  <> "      subtree: true,\n"
  <> "      characterData: true,\n"
  <> "    });\n"
  <> "    forceBottom();\n"
  <> "  };\n"
  <> "  var setup = function () {\n"
  <> "    root = host.shadowRoot;\n"
  <> "    if (!root) return;\n"
  <> "    if (!root.__nexusJump) {\n"
  <> "      root.__nexusJump = true;\n"
  <> "      root.addEventListener('click', function (e) {\n"
  <> "        var t = e.target;\n"
  <> "        if (t && t.closest && t.closest('#jump-latest')) {\n"
  <> "          forceBottom();\n"
  <> "        }\n"
  <> "      });\n"
  <> "      // A thread switch re-renders #log for another conversation:\n"
  <> "      // open it at the latest message, following again.\n"
  <> "      new MutationObserver(function () {\n"
  <> "        forceBottom();\n"
  <> "      }).observe(root, {\n"
  <> "        subtree: true,\n"
  <> "        attributeFilter: ['data-selected'],\n"
  <> "      });\n"
  <> "      // A viewport resize re-clamps scrollTop, which is not a user\n"
  <> "      // scroll: reset the detector so the next set is not mistaken\n"
  <> "      // for a drag, and re-settle if we were following.\n"
  <> "      window.addEventListener('resize', function () {\n"
  <> "        if (!log) return;\n"
  <> "        lastSetTop = -1;\n"
  <> "        lastSetHeight = -1;\n"
  <> "        if (pinned) toBottom();\n"
  <> "      });\n"
  <> "    }\n"
  <> "    var el = root.getElementById('log');\n"
  <> "    if (el) {\n"
  <> "      if (el !== log) logReady(el);\n"
  <> "      return;\n"
  <> "    }\n"
  <> "    if (waiting) return;\n"
  <> "    waiting = new MutationObserver(function () {\n"
  <> "      var found = root && root.getElementById('log');\n"
  <> "      if (found) {\n"
  <> "        waiting.disconnect();\n"
  <> "        waiting = null;\n"
  <> "        logReady(found);\n"
  <> "      }\n"
  <> "    });\n"
  <> "    waiting.observe(root, { childList: true, subtree: true });\n"
  <> "  };\n"
  <> "  host.addEventListener('lustre:mount', setup);\n"
  <> "  host.addEventListener('lustre:connect', setup);\n"
  <> "  setup();\n"
  <> "})();"
}

/// Re-ages the chat log's per-message timestamps (`nexus/ui` `time_stamp`
/// renders `<time data-epoch>` with the server clock's label as its
/// no-JS fallback). The server label is frozen at render time — a tab
/// sitting idle would show "3m ago" forever — so this script recomputes
/// each label from the viewer's clock on a fixed cadence and localizes
/// `title` (the hover tooltip's absolute instant) to the viewer's
/// timezone. A MutationObserver covers the render-time case the cadence
/// misses: messages arrive over the WebSocket AFTER this script's first
/// pass, so without it the server's RFC3339 fallback would sit in every
/// `title` until the next tick — the first hover would show machine
/// format where later hovers show the localized string. Writes only on
/// change: our own textContent writes are shadow-root mutations this
/// very observer watches, so an unconditional write would feed itself
/// forever (the guard makes each refresh quiesce after one settling
/// pass). Static and token-free, like its sibling scripts.
fn timestamps_js() -> String {
  "(function () {\n"
  <> "  'use strict';\n"
  <> "  var host = document.querySelector('lustre-server-component');\n"
  <> "  if (!host) return;\n"
  <> "  var AGE_MS = 30000; // how often labels re-age\n"
  <> "  // Same thresholds as the server's rel_time (nexus/ui), plus the\n"
  <> "  // ' ago' suffix of age_label; negative deltas (clock skew) read as\n"
  <> "  // 'just now', mirroring the server's clamp.\n"
  <> "  var label = function (ms) {\n"
  <> "    if (ms < 60000) return 'just now';\n"
  <> "    var compact =\n"
  <> "      ms < 3600000 ? Math.floor(ms / 60000) + 'm'\n"
  <> "      : ms < 86400000 ? Math.floor(ms / 3600000) + 'h'\n"
  <> "      : ms < 604800000 ? Math.floor(ms / 86400000) + 'd'\n"
  <> "      : ms < 31536000000 ? Math.floor(ms / 604800000) + 'w'\n"
  <> "      : Math.floor(ms / 31536000000) + 'y';\n"
  <> "    return compact + ' ago';\n"
  <> "  };\n"
  <> "  var refresh = function () {\n"
  <> "    var root = host.shadowRoot;\n"
  <> "    if (!root) return;\n"
  <> "    var now = Date.now();\n"
  <> "    var times = root.querySelectorAll('time[data-epoch]');\n"
  <> "    for (var i = 0; i < times.length; i++) {\n"
  <> "      var el = times[i];\n"
  <> "      var epoch = parseInt(el.getAttribute('data-epoch'), 10) * 1000;\n"
  <> "      var text = label(now - epoch);\n"
  <> "      if (el.textContent !== text) el.textContent = text;\n"
  <> "      var title = new Date(epoch).toLocaleString();\n"
  <> "      if (el.getAttribute('title') !== title) el.setAttribute('title', title);\n"
  <> "    }\n"
  <> "  };\n"
  <> "  var attached = false;\n"
  <> "  var attach = function () {\n"
  <> "    var root = host.shadowRoot;\n"
  <> "    if (!root || attached) return;\n"
  <> "    attached = true;\n"
  <> "    new MutationObserver(function () {\n"
  <> "      refresh();\n"
  <> "    }).observe(root, { childList: true, subtree: true });\n"
  <> "  };\n"
  <> "  // The shadow root does not exist until the client runtime mounts;\n"
  <> "  // the mount/connect hooks are the same re-entry points the sibling\n"
  <> "  // scripts use (a crash costs one socket and the browser reconnects\n"
  <> "  // into a fresh runtime — re-attach there too).\n"
  <> "  host.addEventListener('lustre:mount', attach);\n"
  <> "  host.addEventListener('lustre:connect', attach);\n"
  <> "  attach();\n"
  <> "  setInterval(refresh, AGE_MS);\n"
  <> "  refresh();\n"
  <> "})();"
}

fn css() -> String {
  "
:root { color-scheme: light dark; }
/* Pico tokens tuned to the pre-Pico look: 15px base, 1.45 leading, 8px
   radii, selection blue as primary, compact form fields. This is the
   Pico-first surface (AGENTS.md): prefer a token over a new rule. Both
   token blocks restate at Pico's own theme-rule specificity: its light
   rule is :root:not([data-theme=dark]) and its dark rule (inside the
   prefers-color-scheme media block) is :root:not([data-theme]), both
   (0,2,0) — a plain :root block (0,1,0) silently loses and the primary
   falls back to Pico blue in light mode. The dark mirror below uses
   :not([data-theme=light]) rather than Pico's :not([data-theme]) so an
   explicit data-theme=dark stays on the app blues too; without the
   attribute the two are equivalent, and ours is the later sheet either
   way. */
:root:not([data-theme=dark]), :host(:not([data-theme=dark])) {
  --pico-font-size: 15px;
  --pico-line-height: 1.45;
  --pico-border-radius: 8px;
  --pico-form-element-spacing-vertical: .3rem;
  --pico-form-element-spacing-horizontal: .6rem;
  --pico-primary: #3b82f6;
  --pico-primary-background: #3b82f6;
  --pico-primary-border: #3b82f6;
  --pico-primary-hover: #60a5fa;
  --pico-primary-hover-background: #2563eb;
  --pico-primary-hover-border: #2563eb;
  --pico-primary-focus: color-mix(in srgb, #3b82f6 35%, transparent);
}
@media only screen and (prefers-color-scheme: dark) {
  :root:not([data-theme=light]), :host(:not([data-theme=light])) {
    --pico-primary: #60a5fa;
    --pico-primary-background: #2563eb;
    --pico-primary-border: #2563eb;
    --pico-primary-hover: #93c5fd;
    --pico-primary-hover-background: #3b82f6;
    --pico-primary-hover-border: #3b82f6;
    --pico-primary-focus: color-mix(in srgb, #60a5fa 40%, transparent);
  }
}
* { box-sizing: border-box; }
html, body { height: 100%; }
/* Font comes from Pico's tokens (--pico-font-size/-line-height/-font-family);
   only the app-shell layout is ours. */
body { margin: 0; display: flex; }
lustre-server-component { display: contents; }
#app { min-width: 100%; height: 100dvh; display: flex; flex-direction: column; }
header { display: flex; align-items: baseline; gap: .75rem; padding: .6rem 1rem;
  border-bottom: 1px solid color-mix(in srgb, currentColor 15%, transparent); }
header h1 { font-size: 1.05rem; margin: 0; }
#app header button { font-size: .8rem; padding: .28rem .7rem; }
.muted { opacity: .6; font-size: .85rem; }
/* ui-polish F8: the connection state is one labelled group — dot + text
   twin — pushed right as a unit (the auto margin used to sit on the dot). */
.conn { margin-left: auto; display: inline-flex; align-items: baseline; gap: .4rem; }
.dot { font-size: 1.2rem; }
.dot.live { color: #2e9e5b; }
.dot.off { color: #c0392b; }
#layout { flex: 1; min-height: 0; display: grid; grid-template-columns: 17rem minmax(0,1fr);
  grid-template-rows: minmax(0,1fr); }
  /* ^ the explicit row is not cosmetic: without it the single implicit row
     is content-sized, so a long #log grows the row past the viewport and
     the whole page scrolls instead of #log (measured on desktop; the
     mobile breakpoint below always had explicit rows and never showed
     it). minmax(0,1fr) keeps the row exactly the container height, so
     #chat -> #log-wrap -> #log clamp in sequence and #log scrolls. */
#layout.settings-mode { grid-template-columns: minmax(0,1fr); }
#layout.settings-mode > aside, #layout.settings-mode > main { display: none; }
aside { overflow-y: auto; padding: .8rem; border-right: 1px solid
  color-mix(in srgb, currentColor 15%, transparent); }
aside h2 { font-size: .78rem; text-transform: uppercase; letter-spacing: .06em; margin: 0; }
.section-head { display: flex; align-items: center; justify-content: space-between; margin-bottom: .6rem; }
.filter-row { display: flex; gap: .35rem; align-items: center; margin-bottom: .45rem; }
.filter-row input { flex: 1; min-width: 0; }
#app #filter-clear { padding: .3rem .55rem; font-size: .85rem; }
.archive-toggle-row { margin-bottom: .6rem; }
#app .toggle { font-size: .78rem; padding: .28rem .6rem; opacity: .8; }
#app .toggle.on { opacity: 1; border-color: #3b82f6; color: #3b82f6; }
.thread-list { display: flex; flex-direction: column; gap: .55rem; }
.thread-group { display: flex; flex-direction: column; gap: .3rem; }
.group-label { font-size: .68rem; text-transform: uppercase; letter-spacing: .07em; opacity: .55;
  margin: .5rem 0 .1rem; }
.pinned-group .group-label { opacity: .9; }
.thread-row { display: flex; flex-direction: column; gap: .25rem; border: 1px solid transparent;
  border-radius: 10px; padding: .3rem; }
.thread-row.selected { border-color: #3b82f6; background: color-mix(in srgb, #3b82f6 12%, transparent); }
.thread-main { display: flex; flex-direction: column; gap: .1rem; text-align: left; }
.thread-title { overflow-wrap: anywhere; }
.thread-sub { font-size: .72rem; opacity: .6; overflow-wrap: anywhere; }
.tag-chips { display: flex; flex-wrap: wrap; gap: .25rem; }
/* Quiet chip (ui-polish F2): no border by default, so a tagged row reads
   as content rather than as five more buttons; the outline returns on
   hover so the chip is still recognizably clickable. */
#app .tag-chip { font-size: .68rem; padding: .1rem .45rem; border-radius: 999px;
  border-color: transparent; background:
  color-mix(in srgb, currentColor 6%, transparent); }
#app .tag-chip:hover { border-color: color-mix(in srgb, currentColor 35%, transparent); }
.row-controls { display: flex; flex-wrap: wrap; gap: .25rem; }
/* Thread-row controls appear on demand (ui-polish F2) — five bordered
   buttons per active row outweighed the title and subtitle, and wrapped
   to three lines at 390px. Scoped to `.thread-row` deliberately:
   Settings' provider rows share `.row-controls` and must keep
   Disable/Enable/Edit/Test/Delete visible at all times.
   Keyboard reachability survives `display: none`: the row's own
   `.thread-main` button is the first tab stop inside the row, so
   tabbing to a row matches `:focus-within`, reveals the controls, and
   the next Tab presses step through them in DOM order. `:selected` is
   the always-on case, which is also the touch story — a device with no
   hover still shows the controls for the row you are in. */
.thread-row .row-controls { display: none; }
.thread-row.selected .row-controls,
.thread-row:focus-within .row-controls { display: flex; }
@media (hover: hover) {
  .thread-row:hover .row-controls { display: flex; }
}
#app .ctl { font-size: .7rem; padding: .18rem .5rem; opacity: .75; }
/* :not(:disabled) keeps the hover brighten from outranking the
   #app button:disabled dim below ((1,2,0) would beat its (1,1,1) on
   class count): a hovered disabled control — the provider Test button
   mid-test — must stay dimmed, exactly like before the prefix went on. */
#app .ctl:hover:not(:disabled) { opacity: 1; }
#app .ctl.danger, #app button.danger { color: #c0392b; border-color: color-mix(in srgb, #c0392b 45%, transparent); }
.inline-editor { display: flex; flex-wrap: wrap; gap: .3rem; }
.inline-editor input { flex: 1; min-width: 0; }
#app .inline-editor button { font-size: .72rem; padding: .2rem .55rem; flex-shrink: 0; }
.inline-editor[hidden], .confirm-delete[hidden] { display: none; }
.confirm-delete { display: flex; flex-wrap: wrap; align-items: center; gap: .35rem; font-size: .74rem;
  color: #c0392b; }
#app .confirm-delete button { font-size: .72rem; padding: .2rem .55rem; }
.thread-item { display: block; width: 100%; text-align: left; overflow-wrap: anywhere; }
.thread-item[aria-current='true'] { border-color: #3b82f6; background: color-mix(in srgb, #3b82f6 16%, transparent); }
/* ui-polish F4: the panel moved ABOVE the thread list in `sidebar()`, so
   its separator is a bottom rule now (it used to sit below the whole list,
   which is why 'New' opened it off-screen). */
#create-panel { margin-bottom: 1rem; padding-bottom: .8rem; border-bottom: 1px solid
  color-mix(in srgb, currentColor 15%, transparent); display: flex; flex-direction: column; gap: .45rem; }
#create-panel[hidden] { display: none; }
/* ui-polish F7: the settings page reads as one structured column. The
   46rem section is the column — centered like the chat lane (F6), so
   the header row's title/Add ends stop pinning to opposite edges of a
   wide pane ('Add' used to float mid-page on the left-pinned column).
   Provider rows and the add/edit forms render as cards (the .turn.tool
   hairline border recipe), with the heading language of the rest of
   the shell. */
.settings-page { overflow-y: auto; padding: 1.2rem 1.2rem 2.5rem; display: flex; flex-direction: column;
  gap: 1rem; }
.settings-page section { display: flex; flex-direction: column; gap: .7rem; width: 100%;
  max-width: 46rem; margin-inline: auto; }
#app .settings-page h2 { margin: 0; font-size: 1.15rem; }
.models-status { font-size: .74rem; overflow-wrap: anywhere; }
.models-status.loading { opacity: .6; }
.models-status.ok { color: #2e9e5b; }
.models-status.failed { color: #c0392b; }
.settings-error { font-size: .78rem; color: #c0392b; overflow-wrap: anywhere; }
/* ui-polish F7: the row is a card — the visible hairline border is the
   .turn.tool recipe; it used to be transparent (invisible), so rows
   read as bare text plus a button row. */
.provider-row { display: flex; flex-direction: column; gap: .4rem; border: 1px solid
  color-mix(in srgb, currentColor 15%, transparent); border-radius: 10px; padding: .55rem .8rem; }
.provider-main { display: flex; flex-direction: column; gap: .15rem; }
/* The row head: name and badges on one line (F7), base URL below. */
.provider-head { display: flex; align-items: center; gap: .4rem; flex-wrap: wrap; }
.provider-name { overflow-wrap: anywhere; }
.provider-sub { font-size: .72rem; opacity: .6; overflow-wrap: anywhere; }
/* Badges ride the .provider-head row now (F7): align-self center keeps
   the pill vertically centered against the name instead of stretching
   (default) or pinning to the row's top edge (flex-start). */
.badge { font-size: .68rem; padding: .05rem .4rem; border-radius: 999px; align-self: center;
  border: 1px solid color-mix(in srgb, currentColor 35%, transparent); background:
  color-mix(in srgb, currentColor 6%, transparent); }
.badge.off { color: #b8860b; border-color: color-mix(in srgb, #b8860b 45%, transparent); }
/* The add/edit form is a bordered card with a heading (F7) — the add
   form used to be three bare stacked inputs. The heading mirrors the
   sidebar's label language (tiny caps) instead of Pico's h3 scale;
   its spacing is the flex gap, hence margin: 0. */
.provider-form { display: flex; flex-direction: column; gap: .45rem; border: 1px solid
  color-mix(in srgb, currentColor 15%, transparent); border-radius: 10px; padding: .6rem .8rem; }
.provider-form[hidden] { display: none; }
#app .provider-form h3 { margin: 0; font-size: .7rem; font-weight: 600; text-transform: uppercase;
  letter-spacing: .07em; opacity: .55; }
.provider-form input { min-width: 0; }
.provider-form-buttons { display: flex; gap: .3rem; }
#app .provider-form-buttons button { font-size: .75rem; padding: .25rem .6rem; }
/* Form visuals (borders, focus rings, filled backgrounds, dark mode) are
   Pico's, driven by the tokens above. Only the layout leftovers are
   patched: every form here is a flex row/column with explicit gaps, so
   Pico's stacked-form margins (fields and labels) are noise, and form
   elements must keep inheriting the 15px base. */
#app select, #app textarea, #app input, #app label { margin: 0; font: inherit; }
#chat { min-width: 0; display: flex; flex-direction: column; }
#log-wrap { flex: 1; min-height: 0; position: relative; display: flex; flex-direction: column; }
#log { flex: 1; min-height: 0; overflow-y: auto; padding: 1rem; display: flex; flex-direction: column; }
/* ui-polish F6: `#log` spans the whole pane, so on a wide screen a 46rem
   `.turn` with `align-self: flex-end`/`flex-start` pinned user and assistant
   to OPPOSITE edges with dead space between. The fix is one inner column:
   a centered 52rem wrapper gives the bubbles a narrow enough lane for their
   existing per-child `align-self` to read as right/left, not edge-pinned.
   (`align-items: center` on `#log` was ruled out — `align-self` on the turns
   overrides it per child, so the bubbles stay edge-pinned.) The wrapper is
   the only child, so the gap moves inside it; `#log` stays the scroll
   container that `autoscroll_js` observes, and `#jump-latest` stays
   pane-relative (it anchors to `#log-wrap`, not to this column). */
.conversation { width: 100%; max-width: 52rem; margin-inline: auto;
  display: flex; flex-direction: column; gap: .8rem; }
/* The prefix is load-bearing in BOTH directions: it lifts the bare-element
   resets below above Pico, and every compact app-local button class must
   carry it too — bare `.ctl`/`.tag-chip`/`#filter-clear` ((0,x,x) or a
   lone id) lose to `#app button` (1,0,1) on the id count, which is how
   the chrome rendered at full CTA size (ui-polish F1). New compact button
   rules: prefix them. */
#app #jump-latest { position: absolute; right: 1rem; bottom: .8rem; width: 2.2rem; height: 2.2rem;
  padding: 0; border-radius: 50%; font-size: 1.1rem; line-height: 1; opacity: .85; }
#app #jump-latest:hover { opacity: 1; }
#app #jump-latest[hidden] { display: none; }
.turn { max-width: 46rem; padding: .55rem .8rem; border-radius: 10px; white-space: pre-wrap; overflow-wrap: anywhere; }
.turn.user { align-self: flex-end; background: color-mix(in srgb, #3b82f6 18%, transparent); }
.turn.assistant { align-self: flex-start; background: color-mix(in srgb, currentColor 8%, transparent); }
/* Per-message timestamp (nexus/ui time_stamp): a small muted line under
   the bubble text. #app-prefix per the cascade traps above (bare `time`
   could meet framework element rules); `white-space` resets off `.turn`'s
   pre-wrap so the label wraps as a normal short line. The server label is
   the no-JS fallback — `timestamps_js` re-ages it and localizes `title`.
   User bubbles right-align the stamp to hug the pill's anchored edge. */
#app .turn time.ts { display: block; margin-top: .3rem; font-size: .72rem; opacity: .62;
  white-space: normal; }
#app .turn.user time.ts { text-align: right; }
#app .turn.md > time.ts:last-child { margin-bottom: 0; }
/* Markdown assistant turns (.md, see nexus/ui/markdown): the renderer
   emits block semantics, so pre-wrap text flow switches off and the
   blocks get chat-sized margins. Headings collapse to body size — a
   chat bubble is not a document page. #app-prefixed per the Pico
   cascade traps: Pico matches bare h1..h6/pre/p rules and these must
   beat them inside the bubble. */
#app .turn.md { white-space: normal; }
#app .turn.md > :first-child { margin-top: 0; }
#app .turn.md > :last-child { margin-bottom: 0; }
#app .turn.md :is(h1,h2,h3,h4,h5,h6) { font-size: 1em; line-height: 1.35; margin: .6rem 0 .2rem; }
#app .turn.md p { margin: .3rem 0; }
#app .turn.md :is(ul,ol) { margin: .3rem 0; }
#app .turn.md pre { margin: .4rem 0; white-space: pre; }
#app .turn.md table { margin: .4rem 0; font-size: .9em; }
#app .turn.md blockquote { margin: .4rem 0; }
details.turn.reasoning { align-self: flex-start; max-width: 46rem; padding: .35rem .7rem; border-radius: 10px;
  font-size: .8rem; color: color-mix(in srgb, currentColor 80%, transparent);
  border: 1px dashed color-mix(in srgb, currentColor 22%, transparent);
  background: color-mix(in srgb, currentColor 4%, transparent); }
details.turn.reasoning > summary { cursor: pointer; font-style: italic; opacity: .75; font-size: .72rem;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
details.turn.reasoning.live > summary { color: color-mix(in srgb, currentColor 85%, #b8860b); opacity: 1; }
.reasoning-body { white-space: pre-wrap; overflow-wrap: anywhere; padding: .3rem 0 .1rem;
  max-height: 40vh; overflow-y: auto; }
/* Tool chips are real buttons (nexus/ui tool_card / pending_card): one
   compact clickable control — the tool name — whose click opens the
   full-call dialog. Everything here is #app-prefixed on purpose: the
   #app button reset above is (1,0,1), so the bare .turn.tool rules of
   the old details cards lost to it on the id count (font, padding,
   background AND the state tints below would all have reverted to the
   reset). Chip look matches the old collapsed card: transparent
   background, hairline tinted border, mono face, shrink-wrapped. */
#app .turn.tool { display: inline-block; align-self: flex-start; font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: .78rem; line-height: 1.45; padding: .1rem .5rem; margin: 0; border-radius: 10px;
  border: 1px solid color-mix(in srgb, currentColor 15%, transparent); background: transparent;
  color: inherit; text-align: left; }
/* Hover/focus affordance is a box-shadow ring, NOT a border-color
   change: a hover border would out-rank the state tints below (same id
   count, more classes) and the running/completed/failed state would
   vanish whenever the user pointed at the chip. */
#app .turn.tool:hover:not(:disabled), #app .turn.tool:focus-visible {
  box-shadow: 0 0 0 1px color-mix(in srgb, currentColor 30%, transparent); }
.tool-meta { display: flex; align-items: baseline; gap: .5rem; min-width: 0; flex-wrap: wrap; }
.tool-name { overflow-wrap: anywhere; }
.call-id { opacity: .55; font-size: .7rem; overflow-wrap: anywhere; }
.tool-status { margin-left: auto; font-size: .68rem; text-transform: uppercase; letter-spacing: .05em; opacity: .8; }
#app .tool.running { border-color: color-mix(in srgb, #b8860b 55%, transparent); }
#app .tool.running .tool-status { color: #b8860b; }
#app .tool.done { border-color: color-mix(in srgb, #2e9e5b 45%, transparent); }
#app .tool.done .tool-status { color: #2e9e5b; }
#app .tool.failed { border-color: color-mix(in srgb, #c0392b 55%, transparent); }
#app .tool.failed .tool-status { color: #c0392b; }
/* Full-call popup (nexus/ui tool_pop): Pico styles <dialog open> as the
   centered overlay — backdrop blur and dim included, no script — and its
   article child as the card. These rules only carry the app's chip
   language into the card (mono face, state tints, tiny-caps section
   labels), widen it for reading code, and style the chrome: the close X
   floats in the card's top-right corner (the article is its positioning
   context), and the header keeps its text clear of it. The backdrop
   click-catcher (.tool-pop-hit) is styled with the dialog rules below.
   #app-prefix per the cascade traps. */
#app .tool-pop { position: relative; max-width: min(58rem, 92vw); font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  border: 1px solid color-mix(in srgb, currentColor 15%, transparent); }
/* The card is the scroll container (Pico), so the header — and the ✕
   anchored to it — must stick: top: 0 pins both while long content
   scrolls underneath, and the opaque card background stops scrolled text
   showing through. Sticky is a positioned value, so the header becomes
   the ✕'s anchor (replacing the article-relative position on .tool-pop). */
#app .tool-pop > header { position: sticky; top: 0; padding-right: 2.4rem; margin: 0;
  background: var(--pico-card-background-color); }
#app .tool-pop h3 { margin: .8rem 0 0; font-size: .7rem; font-weight: 600; text-transform: uppercase;
  letter-spacing: .07em; opacity: .55; }
/* pre-wrap + anywhere, not Pico's scrolling pre: a codemode script
   decodes to real newlines but can still carry long lines, and raw JSON
   arguments are one giant line — wrap them inside the card instead of
   scrolling horizontally. */
#app .tool-pop pre { margin: .3rem 0 0; font-size: .78rem; white-space: pre-wrap;
  overflow-wrap: anywhere; }
#app .tool-pop .tool-meta { margin-top: .2rem; }
/* The close X: a text glyph pinned to the card's corner, out of the
   header's flow (absolute + float-cancelled). Sized ~1.5x a header
   button label so it reads as a control, not punctuation. The shell's
   #app button reset out-ranks Pico's .close rule and strips the icon
   background — the glyph replaces it. */
#app .tool-pop .close { position: absolute; top: .35rem; right: .55rem; background-image: none;
  width: auto; height: auto; padding: 0 .3rem; margin: 0; border: none; font-size: 1.4rem;
  line-height: 1.3; opacity: .55; }
#app .tool-pop .close:hover, #app .tool-pop .close:focus { opacity: 1; }
/* The backdrop click-catcher (nexus/ui tool_pop): an invisible inset-0
   layer inside the dialog, BELOW the card in paint order (later sibling
   wins, both positioned), carrying the close handler — clicks outside
   the card hit it, clicks on the card never reach it. */
#app .tool-pop-hit { position: absolute; inset: 0; }
#app .tool-pop.running { border-color: color-mix(in srgb, #b8860b 55%, transparent); }
#app .tool-pop.running .tool-status { color: #b8860b; }
#app .tool-pop.done { border-color: color-mix(in srgb, #2e9e5b 45%, transparent); }
#app .tool-pop.done .tool-status { color: #2e9e5b; }
#app .tool-pop.failed { border-color: color-mix(in srgb, #c0392b 55%, transparent); }
#app .tool-pop.failed .tool-status { color: #c0392b; }
/* Collapsed chips flow like spans, not blocks: consecutive collapsible
   lines (committed reasoning + tool chips) render inside one .chip-row —
   a wrapping flex line, so each chip sizes to its label on a shared row
   instead of stacking a full-width block per chip (which cost a whole
   row + conversation gap apiece). The row itself takes the full 46rem
   lane (width 100%, capped): flex-basis 100% on an OPENED reasoning chip
   must resolve against a definite width — against a shrink-wrapped row
   the percentage is cyclic during intrinsic sizing and browsers size the
   open chip to its content instead. The row is an invisible wrapper, so
   the definite width costs nothing visually. Expansion is pure CSS off
   the native [open] attribute (reasoning only — tool chips click through
   to the popup instead of expanding): flex-basis 100% wraps an open chip
   onto its own full-width line, and the per-type rules restore the
   roomy block padding. Closed chips keep their tint/border identity;
   only the padding shrinks. Margins are zeroed because Pico gives
   details AND their summary a 1rem bottom margin each — inside the flex
   row they don't collapse, so every chip would carry dead space and the
   row's gap would no longer control vertical spacing. */
.chip-row { width: 100%; max-width: 46rem; display: flex; flex-wrap: wrap;
  align-items: flex-start; gap: .3rem .5rem; }
.chip-row > details.turn.reasoning, .chip-row > .turn.tool { padding: .1rem .5rem; margin: 0; }
.chip-row > details[open] { flex: 1 1 100%; }
.chip-row > details.turn.reasoning[open] { padding: .35rem .7rem; }
.chip-row > details > summary { margin: 0; }
#loop-status { padding: .3rem 1rem; font-size: .72rem; font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  border-top: 1px dashed color-mix(in srgb, currentColor 15%, transparent); opacity: .75; }
#loop-status[hidden] { display: none; }
#loop-status.guard { color: #c0392b; opacity: 1; }
.note { align-self: center; font-size: .75rem; opacity: .55; max-width: 46rem; }
.note.err { opacity: .85; color: #c0392b; }
#composer { display: flex; gap: .5rem; padding: .75rem; border-top: 1px solid
  color-mix(in srgb, currentColor 15%, transparent); }
textarea { flex: 1; resize: none; }
.buttons { display: flex; flex-direction: column; gap: .35rem; }
/* Bare-element overrides are #app-prefixed on purpose: Pico matches
   buttons/inputs twice (e.g. `button` AND `[type=button]`/`[type=text]`,
   the attribute selectors at 0,1,0), so a bare `button` reset loses the
   cascade. #app gives (1,0,x): it wins outright, matches inside the
   shadow root (everything renders under #app), and stays inert in the
   light DOM. See the #jump-latest comment above for the other half of
   the rule: app-local compact classes carry the prefix too. */
#app button { font: inherit; padding: .42rem .8rem; border-radius: var(--pico-border-radius); cursor: pointer;
  border: 1px solid color-mix(in srgb, currentColor 25%, transparent); background: transparent; color: inherit;
  /* Pico's button defaults are for full-width form CTAs; the shell's
     chrome buttons are inline-sized, self-spaced, and flat. */
  width: auto; margin: 0; }
button#send, button#create-thread { background: var(--pico-primary-background);
  border-color: var(--pico-primary-border); color: #fff; }
#app button:disabled { opacity: .45; cursor: default; }
@media (max-width: 900px) {
  #layout { grid-template-columns: 1fr; grid-template-rows: auto minmax(0,1fr); }
  #layout.settings-mode { grid-template-rows: minmax(0,1fr); }
  aside { border: 0; border-bottom: 1px solid color-mix(in srgb, currentColor 15%, transparent); }
  /* ui-polish F3(a): stacked, `aside` used to take its natural height, so
     three threads pushed the transcript into a ~100px sliver clipped under
     the composer. Capping the list at 40dvh keeps the composer on screen and
     gives the transcript the rest; the list scrolls inside `aside` (already
     `overflow-y: auto`). A real collapse toggle/drawer (options b/c) stays
     parked until this cap proves too tight against a 20+ thread list. */
  aside { max-height: 40dvh; }
  .settings-page { padding: .8rem .8rem 2rem; }
}
"
}
