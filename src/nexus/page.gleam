//// The M3 page shell: server-rendered HTML hosting the Lustre server
//// component. The page carries no client-side application code — just the
//// prebuilt Lustre client runtime, a `<lustre-server-component>` element
//// whose `route` points at the WebSocket transport, and two tiny static
//// scripts (see `indicator_js` and `session_js`).
////
//// The bearer token (when auth is on) is echoed into the route's query
//// string server-side, mirroring the M2 `?token=` convention: the token
//// never enters JavaScript. The same query string carries the
//// client-supplied last-selected session back to the server (per-client
//// runtimes: `session_js` persists it and re-supplies it on connect so a
//// reload re-opens the same session).

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

pub fn html(token: Option(String)) -> String {
  string.concat([
    "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
      <> "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
      <> "<title>nexus</title>\n<style>\n",
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
    session_js(),
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
/// host element — onto the `#status` dot inside its (open) shadow root. A
/// reconnect remounts the full server view, which resets the dot to truth.
/// The script is static and token-free; auth still rides the query string.
fn indicator_js() -> String {
  "(function () {\n"
  <> "  'use strict';\n"
  <> "  var host = document.querySelector('lustre-server-component');\n"
  <> "  if (!host) return;\n"
  <> "  var setDot = function (live) {\n"
  <> "    var dot = host.shadowRoot && host.shadowRoot.getElementById('status');\n"
  <> "    if (dot) {\n"
  <> "      dot.className = live ? 'dot live' : 'dot off';\n"
  <> "      dot.textContent = live ? '●' : '○';\n"
  <> "    }\n"
  <> "  };\n"
  <> "  host.addEventListener('lustre:close', function () { setDot(false); });\n"
  <> "  host.addEventListener('lustre:connect', function () { setDot(true); });\n"
  <> "})();"
}

/// Per-client runtime break: each /ws connection owns its model, so a
/// reload must tell the fresh runtime which session to re-open. This
/// static script is the only client-side keeper of that choice. Storage is
/// `sessionStorage` — per-tab and reload-surviving, so one tab's selection
/// never leaks into another tab's restore (a brand-new tab falls back to
/// the server's auto-selection). Before the runtime module loads (it is
/// deferred; this classic script runs during parsing) it appends the
/// stored session to the `route` attribute's query string; once the
/// component renders it mirrors the server-rendered
/// `#layout[data-selected]` back into storage, and on `lustre:close` it
/// re-syncs the route's `session` parameter with the CURRENT selection so
/// a reconnect without a reload re-opens what this tab is looking at, not
/// what it opened at load. The script is static, token-free, and never
/// touches the rendered DOM — auth still rides the query string.
fn session_js() -> String {
  "(function () {\n"
  <> "  'use strict';\n"
  <> "  var host = document.querySelector('lustre-server-component');\n"
  <> "  if (!host) return;\n"
  <> "  var read = function () {\n"
  <> "    try { return sessionStorage.getItem('nexus.session'); } catch (e) { return null; }\n"
  <> "  };\n"
  <> "  var write = function (id) {\n"
  <> "    try {\n"
  <> "      if (id) sessionStorage.setItem('nexus.session', id);\n"
  <> "      else sessionStorage.removeItem('nexus.session');\n"
  <> "    } catch (e) {}\n"
  <> "  };\n"
  <> "  var currentId = function () {\n"
  <> "    var layout = host.shadowRoot && host.shadowRoot.getElementById('layout');\n"
  <> "    return layout ? (layout.getAttribute('data-selected') || '') : null;\n"
  <> "  };\n"
  <> "  // Pre-connect: append this tab's last-selected session to the ws\n"
  <> "  // route. The attribute is final before the element upgrades, so\n"
  <> "  // the runtime connects once, with the session in hand.\n"
  <> "  var stored = read();\n"
  <> "  if (stored) {\n"
  <> "    var route = host.getAttribute('route');\n"
  <> "    if (route) {\n"
  <> "      var url = new URL(route, location.href);\n"
  <> "      url.searchParams.set('session', stored);\n"
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
  <> "    var carried = url.searchParams.get('session') || '';\n"
  <> "    if (carried === id) return;\n"
  <> "    if (id) url.searchParams.set('session', id);\n"
  <> "    else url.searchParams.delete('session');\n"
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

fn css() -> String {
  "
:root { color-scheme: light dark; }
* { box-sizing: border-box; }
html, body { height: 100%; }
body { margin: 0; font: 15px/1.45 system-ui, sans-serif; display: flex; }
lustre-server-component { display: contents; }
#app { min-width: 100%; height: 100dvh; display: flex; flex-direction: column; }
header { display: flex; align-items: baseline; gap: .75rem; padding: .6rem 1rem;
  border-bottom: 1px solid color-mix(in srgb, currentColor 15%, transparent); }
header h1 { font-size: 1.05rem; margin: 0; }
header button { font-size: .8rem; padding: .28rem .7rem; }
.muted { opacity: .6; font-size: .85rem; }
.dot { margin-left: auto; font-size: 1.2rem; }
.dot.live { color: #2e9e5b; }
.dot.off { color: #c0392b; }
#layout { flex: 1; min-height: 0; display: grid; grid-template-columns: 17rem minmax(0,1fr) 16rem; }
#layout.settings-mode { grid-template-columns: minmax(0,1fr); }
#layout.settings-mode > aside, #layout.settings-mode > main { display: none; }
aside { overflow-y: auto; padding: .8rem; border-right: 1px solid
  color-mix(in srgb, currentColor 15%, transparent); }
#metrics-panel { border-right: 0; border-left: 1px solid
  color-mix(in srgb, currentColor 15%, transparent); }
aside h2 { font-size: .78rem; text-transform: uppercase; letter-spacing: .06em; margin: 0; }
.section-head { display: flex; align-items: center; justify-content: space-between; margin-bottom: .6rem; }
.filter-row { display: flex; gap: .35rem; align-items: center; margin-bottom: .45rem; }
.filter-row input { flex: 1; min-width: 0; }
#filter-clear { padding: .3rem .55rem; font-size: .85rem; }
.archive-toggle-row { margin-bottom: .6rem; }
.toggle { font-size: .78rem; padding: .28rem .6rem; opacity: .8; }
.toggle.on { opacity: 1; border-color: #3b82f6; color: #3b82f6; }
.session-list { display: flex; flex-direction: column; gap: .55rem; }
.session-group { display: flex; flex-direction: column; gap: .3rem; }
.group-label { font-size: .68rem; text-transform: uppercase; letter-spacing: .07em; opacity: .55;
  margin: .5rem 0 .1rem; }
.pinned-group .group-label { opacity: .9; }
.session-row { display: flex; flex-direction: column; gap: .25rem; border: 1px solid transparent;
  border-radius: 10px; padding: .3rem; }
.session-row.selected { border-color: #3b82f6; background: color-mix(in srgb, #3b82f6 12%, transparent); }
.session-main { display: flex; flex-direction: column; gap: .1rem; text-align: left; }
.session-title { overflow-wrap: anywhere; }
.session-sub { font-size: .72rem; opacity: .6; overflow-wrap: anywhere; }
.tag-chips { display: flex; flex-wrap: wrap; gap: .25rem; }
.tag-chip { font-size: .68rem; padding: .1rem .45rem; border-radius: 999px;
  border-color: color-mix(in srgb, currentColor 35%, transparent); background:
  color-mix(in srgb, currentColor 6%, transparent); }
.row-controls { display: flex; flex-wrap: wrap; gap: .25rem; }
.ctl { font-size: .7rem; padding: .18rem .5rem; opacity: .75; }
.ctl:hover { opacity: 1; }
.ctl.danger, button.danger { color: #c0392b; border-color: color-mix(in srgb, #c0392b 45%, transparent); }
.inline-editor { display: flex; flex-wrap: wrap; gap: .3rem; }
.inline-editor input { flex: 1; min-width: 0; }
.inline-editor button { font-size: .72rem; padding: .2rem .55rem; flex-shrink: 0; }
.inline-editor[hidden], .confirm-delete[hidden] { display: none; }
.confirm-delete { display: flex; flex-wrap: wrap; align-items: center; gap: .35rem; font-size: .74rem;
  color: #c0392b; }
.confirm-delete button { font-size: .72rem; padding: .2rem .55rem; }
.session-item { display: block; width: 100%; text-align: left; overflow-wrap: anywhere; }
.session-item[aria-current='true'] { border-color: #3b82f6; background: color-mix(in srgb, #3b82f6 16%, transparent); }
#create-panel { margin-top: 1rem; padding-top: .8rem; border-top: 1px solid
  color-mix(in srgb, currentColor 15%, transparent); display: flex; flex-direction: column; gap: .45rem; }
#create-panel[hidden] { display: none; }
.settings-page { overflow-y: auto; padding: 1.2rem 1.2rem 2.5rem; display: flex; flex-direction: column;
  gap: 1rem; }
.settings-page section { display: flex; flex-direction: column; gap: .55rem; width: 100%;
  max-width: 46rem; }
.models-status { font-size: .74rem; overflow-wrap: anywhere; }
.models-status.loading { opacity: .6; }
.models-status.ok { color: #2e9e5b; }
.models-status.failed { color: #c0392b; }
.settings-error { font-size: .78rem; color: #c0392b; overflow-wrap: anywhere; }
.provider-list { display: flex; flex-direction: column; gap: .45rem; }
.provider-row { display: flex; flex-direction: column; gap: .25rem; border: 1px solid transparent;
  border-radius: 10px; padding: .3rem; }
.provider-main { display: flex; flex-direction: column; gap: .1rem; }
.provider-name { overflow-wrap: anywhere; }
.provider-sub { font-size: .72rem; opacity: .6; overflow-wrap: anywhere; }
.badge { font-size: .68rem; padding: .05rem .4rem; border-radius: 999px; align-self: flex-start;
  border: 1px solid color-mix(in srgb, currentColor 35%, transparent); background:
  color-mix(in srgb, currentColor 6%, transparent); }
.badge.off { color: #b8860b; border-color: color-mix(in srgb, #b8860b 45%, transparent); }
.provider-form { display: flex; flex-direction: column; gap: .3rem; }
.provider-form[hidden] { display: none; }
.provider-form input { min-width: 0; }
.provider-form-buttons { display: flex; gap: .3rem; }
.provider-form-buttons button { font-size: .75rem; padding: .25rem .6rem; }
select, textarea, input { font: inherit; color: inherit; background: transparent; border-radius: 8px;
  border: 1px solid color-mix(in srgb, currentColor 25%, transparent); padding: .45rem .6rem; }
#chat { min-width: 0; display: flex; flex-direction: column; }
#log { flex: 1; overflow-y: auto; padding: 1rem; display: flex; flex-direction: column; gap: .8rem; }
.turn { max-width: 46rem; padding: .55rem .8rem; border-radius: 10px; white-space: pre-wrap; overflow-wrap: anywhere; }
.turn.user { align-self: flex-end; background: color-mix(in srgb, #3b82f6 18%, transparent); }
.turn.assistant { align-self: flex-start; background: color-mix(in srgb, currentColor 8%, transparent); }
details.turn.reasoning { align-self: flex-start; max-width: 46rem; padding: .35rem .7rem; border-radius: 10px;
  font-size: .8rem; color: color-mix(in srgb, currentColor 80%, transparent);
  border: 1px dashed color-mix(in srgb, currentColor 22%, transparent);
  background: color-mix(in srgb, currentColor 4%, transparent); }
details.turn.reasoning > summary { cursor: pointer; font-style: italic; opacity: .75; font-size: .72rem;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace; list-style: revert; }
details.turn.reasoning.live > summary { color: #b8860b; opacity: 1; }
.reasoning-body { white-space: pre-wrap; overflow-wrap: anywhere; padding: .3rem 0 .1rem;
  max-height: 40vh; overflow-y: auto; }
.turn.tool { align-self: flex-start; font-size: .78rem; font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  padding: .45rem .6rem; gap: .25rem; }
.tool-head { display: flex; align-items: baseline; gap: .5rem; min-width: 0; flex-wrap: wrap; }
.tool-name { overflow-wrap: anywhere; }
.call-id { opacity: .55; font-size: .7rem; overflow-wrap: anywhere; }
.tool-status { margin-left: auto; font-size: .68rem; text-transform: uppercase; letter-spacing: .05em; opacity: .8; }
.tool.running { border-color: color-mix(in srgb, #b8860b 55%, transparent); }
.tool.running .tool-status { color: #b8860b; }
.tool.done { border-color: color-mix(in srgb, #2e9e5b 45%, transparent); }
.tool.done .tool-status { color: #2e9e5b; }
.tool.failed { border-color: color-mix(in srgb, #c0392b 55%, transparent); }
.tool.failed .tool-status { color: #c0392b; }
.tool-args, .tool-result { white-space: pre-wrap; overflow-wrap: anywhere; opacity: .85; margin: 0; }
.tool-result { border-top: 1px dashed color-mix(in srgb, currentColor 15%, transparent); padding-top: .25rem; }
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
button { font: inherit; padding: .42rem .8rem; border-radius: 8px; cursor: pointer;
  border: 1px solid color-mix(in srgb, currentColor 25%, transparent); background: transparent; color: inherit; }
button#send, button#create-session { background: #3b82f6; border-color: #3b82f6; color: #fff; }
button:disabled { opacity: .45; cursor: default; }
.metrics-list { display: flex; flex-direction: column; gap: .45rem; }
.metric { padding: .5rem; font-size: .75rem; border-radius: 8px;
  background: color-mix(in srgb, currentColor 7%, transparent); overflow-wrap: anywhere; }
.metric strong { display: block; margin-bottom: .15rem; }
@media (max-width: 900px) {
  #layout { grid-template-columns: 1fr; grid-template-rows: auto minmax(0,1fr) auto; }
  #layout.settings-mode { grid-template-rows: minmax(0,1fr); }
  aside { border: 0; border-bottom: 1px solid color-mix(in srgb, currentColor 15%, transparent); }
  #metrics-panel { border-bottom: 0; border-top: 1px solid color-mix(in srgb, currentColor 15%, transparent); }
  .settings-page { padding: .8rem .8rem 2rem; }
}
"
}
