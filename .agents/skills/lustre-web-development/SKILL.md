---
name: lustre-web-development
description: Gleam Lustre web development patterns, event handlers, and server components
license: MIT
compatibility:
  lustre: ">= 5.0.0"
---

# Lustre Web Development

A guide for building web applications with Gleam's Lustre framework, focusing on server components, WebSocket integration, and event handling patterns.

## Server Component Pattern

### Basic Setup

Server components use Lustre with WebSocket connections for real-time updates. The pattern consists of three files:

1. **Component file** (e.g., `src/agent/chat.gleam`): The Lustre application
2. **Socket file** (e.g., `src/agent/socket.gleam`): WebSocket handler —
   starts **one runtime per connection**
3. **Router integration**: Add routes to both HTTP and WebSocket handlers

### Component Structure: One Runtime per Connection (default)

A server-component runtime owns exactly one model. Start a single runtime
at boot and share it between clients, and every connected browser shares
that model — tabs mirror each other's selection, open panels, and drafts.
Any app with per-client state wants one runtime per WebSocket connection
(verified on Lustre 5.7.1):

```gleam
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option}
import lustre
import lustre/component
import lustre/effect
import lustre/server_component

/// Per-connection inputs: actor subjects plus anything client-specific
/// (e.g. the client's last selection, read from the route's query string
/// by the page shell). `init` receives these as plain values — nothing
/// is globally registered.
pub type Flags {
  Flags(events: Subject(EventMsg), selected: Option(String))
}

pub fn app() -> lustre.App(Flags, Model, Msg) {
  lustre.component(init: init, update: update, view: view, options: [
    // Open by default; keep it open — see CSS Integration / Shadow DOM.
    component.open_shadow_root(True),
  ])
}

pub type Model {
  Model(
    // The actor that feeds events, retained from Flags — the GotEvents
    // arm below needs it to wire the fresh subject; dropped, the
    // subscription would have no destination.
    actor: Subject(EventMsg),
    // THIS runtime's subscription subject; None until GotEvents lands.
    events: Option(Subject(EventMsg)),
    selected: Option(String), // ... your fields
  )
}

pub opaque type Msg {
  GotEvents(Subject(EventMsg))
  ExternalMsg(EventMsg)
  // ... your messages
}

fn init(flags: Flags) -> #(Model, effect.Effect(Msg)) {
  #(
    Model(actor: flags.events, events: None, selected: flags.selected),
    subscribe(),
  )
}

// Subscribe via a fresh subject owned by THIS runtime. Hand the subject
// to whoever should feed events (here via GotEvents) — that dispatch is
// also the connect point of a per-client runtime: there are no
// on_connect/on_disconnect hooks, connect is `init` and disconnect is
// the runtime dying with its socket.
fn subscribe() -> effect.Effect(Msg) {
  server_component.select(fn(dispatch, subject: Subject(EventMsg)) {
    dispatch(GotEvents(subject))
    process.new_selector()
    |> process.select_map(subject, ExternalMsg)
  })
}

// In `update`: hand the fresh subject to the actor retained in the
// model, so external events can reach this client. Subscribe is a
// constructor of YOUR EventMsg telling the actor to fan out to the
// subject (nexus sends session.Join here). This arm is also the place
// for the initial data load — a fresh model starts empty.
GotEvents(subject) -> {
  let actor = model.actor
  #(
    Model(..model, events: Some(subject)),
    effect.from(fn(_dispatch) { process.send(actor, Subscribe(subject)) }),
  )
}
```

Lifecycle rules that make the per-connection split work:

- The socket's `on_init` calls `lustre.start_server_component(app(),
  flags)`; the runtime spawns **linked to the socket process** and does
  not trap exits, so socket and runtime die together. A closed socket
  takes its runtime down; a crashed runtime takes the socket down, and
  the browser reconnects into a fresh runtime. `close_socket` sends
  `lustre.shutdown()` for the clean stop (see
  [Socket Handler Pattern](#socket-handler-pattern)).
- The runtime is never a supervisor child and never registered under a
  process name.
- Client state across reload: the page shell persists the client's last
  selection and re-supplies it as a query parameter on the component's
  `route`, landing in `Flags`. Use `sessionStorage` (per-tab), not
  `localStorage` — a shared key lets one tab's selection restore in
  another tab's reload, breaking the per-client invariant.

### Shared Runtime (single client only)

The older pattern — one runtime started in the supervisor under a
`process.Name`, the component's `init` doing
`process.register(process.self(), name)` and selecting on
`process.named_subject(name)` — still works, and is fine when exactly
one browser will ever connect (a kiosk, an internal dashboard). Don't
use it for multi-client apps: the shared model silently couples every
client.

## Event Handlers

### Text Input

Controlled inputs work for plain fields — but read
[Inputs: Controlled vs Uncontrolled](#inputs-controlled-vs-uncontrolled-server-components)
first: with server components, controlled drafts can race queued `input`
echoes over the WebSocket.

```gleam
pub opaque type Msg {
  UserTypedInput(String)
}

// In view function:
ht.input([
  at.class("chat-input"),
  at.placeholder("Type here..."),
  at.value(model.input),
  event.on_input(UserTypedInput),
  at.type_("text"),
])
```

### Button Click

```gleam
pub opaque type Msg {
  UserClickedButton
}

// In view function:
ht.button([event.on_click(UserClickedButton)], [
  ht.text("Click me")
])
```

### Form Submission

`event.on_submit` **works** with server components (Lustre ≥ 5). It
decodes `detail.formData` (a list of `#(name, value)` pairs the client
runtime assembles from the live form) and automatically `preventDefault`s
the browser's native submission. State which fields the decoder needs via
`server_component.include`:

```gleam
pub opaque type Msg {
  UserSubmittedForm(String)
}

// In view function — the form owns the submit handler:
ht.form(
  [event.on_submit(fn(entries) {
    case list.find(entries, fn(e) { e.0 == "text" }) {
      Ok(#(_, value)) -> UserSubmittedForm(value)
      Error(_) -> Ignored
    }
  })
  |> server_component.include(["detail.formData"])],
  [
    ht.textarea([at.name("text")], ""),
    ht.button([at.type_("submit")], [ht.text("Send")]),
  ],
)
```

Notes:

- The submit button needs `at.type_("submit")`; any other button inside the
  form must explicitly be `at.type_("button")` or it will submit too.
- Enter in a `<textarea>` does **not** trigger form submission (only
  single-line inputs do) — see [Enter-to-send](#enter-to-send-textarea) below.
- `at.action("#")` documents that no navigation is intended.

### Custom Events with Data

For events that need to pass data:
```gleam
pub opaque type Msg {
  UserSelectedOption(String)
}

// In view function:
ht.select([
  event.on_change(UserSelectedOption),
  at.value(model.selected_option),
], [
  ht.option([at.value("option1")], [ht.text("Option 1")]),
  ht.option([at.value("option2")], [ht.text("Option 2")]),
])
```

## Inputs: Controlled vs Uncontrolled (Server Components)

Three transport facts drive every input decision in a server component:

1. **No conditional `preventDefault`.** The handler runs on the server,
   long after the browser already ran the default action. Lustre's
   `event.prevent_default` is unconditional per event name — applying it to
   `keydown` blocks *all* typing (docs say so explicitly for
   [`event.advanced`](https://hexdocs.pm/lustre/lustre/event.html)).
2. **One WS message in flight.** The client queues events and flushes the
   queue only when the next server message arrives. A controlled draft races
   against the queued `input` echo: a default action you didn't want (e.g.
   Enter's newline) mutates the DOM, fires `input`, and that echo lands
   *after* your next render — re-polluting the model with stale text.
3. **Value sync is attribute-based.** Lustre's runtime syncs `value` via a
   special-cased attribute (`node.value = ...`). Rendering a `<textarea>`'s
   content as children patches text nodes, which **never** update a
   textarea's `value` property after mount. Use `at.value(...)` if you need
   patches to reach the field at all.

For a chat composer (Enter-to-send), the race in (1)+(2) is unwinnable with a
controlled draft. Use the pattern Lustre documents in
[controlled-vs-uncontrolled-inputs](https://github.com/lustre-labs/lustre/blob/main/pages/hints/controlled-vs-uncontrolled-inputs.md):
**uncontrolled input inside a keyed container**:

- No `on_input` at all — the field owns its text; zero per-keystroke traffic.
- Read the text from the event itself: `target.value` at `keydown` time is
  read *before* the default action runs, so it is exactly what the user sees.
- Clear the field by **rotating the key**: a changed key makes the diff
  replace the element wholesale. Recreate it with `at.autofocus(True)` —
  autofocus is a runtime-synced attribute, so the fresh element grabs focus.

### Enter-to-send textarea

```gleam
import lustre/element/keyed

// Model: composer: Int  — bumped on accepted send (SendAccepted)

fn composer(model: Model) -> Element(Msg) {
  keyed.element("form", [at.id("composer"), submit_requested()], [
    #(
      "composer-" <> int.to_string(model.composer),  // rotation key
      ht.textarea(
        [
          at.name("text"),
          at.autofocus(True),
          enter_key(),
        ],
        "",  // uncontrolled: content stays ""
      ),
    ),
    #("controls", ht.div([at.class("buttons")], [send_button()])),
  ])
}

fn enter_key() -> attr.Attribute(Msg) {
  let decoder = {
    use key <- decode.field("key", decode.string)
    // Value read BEFORE the newline default runs — newline-free by design.
    use value <- decode.subfield(["target", "value"], decode.string)
    use shift <- decode.optional_field("shiftKey", False, decode.bool)
    use composing <- decode.optional_field("isComposing", False, decode.bool)
    case key, shift, composing {
      // Plain Enter sends; Shift+Enter keeps the browser newline (multi-line);
      // isComposing guards IME confirmation Enters.
      "Enter", False, False -> SendRequested(value)
      _, _, _ -> Ignored
    }
    |> decode.success
  }
  event.on("keydown", decoder)
  |> server_component.include(["key", "target.value", "shiftKey", "isComposing"])
}

// SendAccepted -> Model(..model, composer: model.composer + 1, streaming: True)
```

Known trade-off: for one round-trip between Enter and the accept event the
newline may flash briefly before the keyed replacement wipes it. The only
alternative is client-side JS in the page (preventDefault in a capture
listener) — which a zero-client-JS page rules out, and which **cannot reach
into a closed shadow root** anyway (see Shadow DOM section).

### When controlled *is* fine

Use `at.value(model.field)` + `event.on_input` for short fields (search
boxes, pickers) where no default action fights you. Consider
`event.debounce(handler, 200)` to cut per-keystroke round trips. For long
text or send-on-Enter flows, prefer the uncontrolled pattern above.

## WebSocket Integration

### Socket Handler Pattern

The socket handler owns the per-connection runtime: build `Flags`
(actor subjects + route query params), start the runtime, shuttle frames.

```gleam
import gleam/erlang/process.{type Selector, type Subject}
import gleam/http/request.{type Request}
import gleam/json
import gleam/option.{type Option, Some}
import lustre
import lustre/server_component
import mist.{type Connection}

pub fn html() {
  server_component.element([server_component.route("/ws/chat")], [])
  |> web.layout(title: "Chat Page")
  |> Ok
  |> web.html_response
}

pub fn serve(request: Request(Connection), ctx: Context) {
  // runtime_flags reads the client-supplied query params (e.g. the
  // last-selected id persisted by the page shell) onto the Flags.
  mist.websocket(
    request:,
    // on_init wants a callback receiving the connection — wrap the
    // call. Calling init_socket here would run it eagerly in the
    // router process and pass its state tuple where a function belongs.
    on_init: fn(_connection) { init_socket(runtime_flags(request, ctx)) },
    handler: loop_socket,
    on_close: close_socket,
  )
}

type Socket {
  Socket(
    runtime: lustre.Runtime(your_component.Msg),
    client: Subject(server_component.ClientMessage(your_component.Msg)),
  )
}

type SocketMessage =
  server_component.ClientMessage(your_component.Msg)

// One runtime per connection, linked to this socket process (it does
// not trap exits, so the pair die together). `start_server_component`
// only fails if the actor cannot start at all; crashing here drops the
// socket and the client runtime reconnects to try again.
fn init_socket(flags: Flags) -> #(Socket, Option(Selector(SocketMessage))) {
  let assert Ok(runtime) =
    lustre.start_server_component(your_component.app(), flags)
  let client = process.new_subject()
  let selector =
    process.new_selector()
    |> process.select(client)

  server_component.register_subject(client)
  |> lustre.send(to: runtime)

  #(Socket(runtime:, client:), Some(selector))
}

fn loop_socket(
  state: Socket,
  message: mist.WebsocketMessage(SocketMessage),
  connection: mist.WebsocketConnection,
) -> mist.Next(Socket, SocketMessage) {
  case message {
    // Client → Server messages (input, clicks)
    mist.Text(json) -> {
      case json.parse(json, server_component.runtime_message_decoder()) {
        Ok(runtime_message) -> lustre.send(state.runtime, runtime_message)
        Error(_) -> Nil
      }
      mist.continue(state)
    }

    mist.Binary(_) -> mist.continue(state)

    // Server → Client messages (UI updates)
    mist.Custom(client_message) -> {
      let json = server_component.client_message_to_json(client_message)
      let assert Ok(_) = mist.send_text_frame(connection, json.to_string(json))
      mist.continue(state)
    }

    mist.Closed | mist.Shutdown -> mist.stop()
  }
}

fn close_socket(state: Socket) -> Nil {
  // The link already ties the runtime to this socket; shutdown is the
  // clean stop for the normal close path. No deregister_subject needed:
  // the runtime served exactly this client and is going away with it.
  lustre.shutdown()
  |> lustre.send(to: state.runtime)
}
```

## Router Integration

### Add to Context

The context carries the actor subjects the per-connection `Flags` need —
not a component runtime (each connection brings its own).

```gleam
// In src/web.gleam
import some_actor

pub type Context {
  Context(
    db: process.Name(pog.Message),
    some_actor: Subject(some_actor.Msg),
  )
}
```

### Add HTTP Route

```gleam
// In src/router.gleam - wisp_handler
case wisp.path_segments(req) {
  // ... existing routes ...
  ["chat"] -> your_socket.html()
  _ -> wisp.not_found()
}
```

### Add WebSocket Route

```gleam
// In src/router.gleam - mist_handler
case request.path_segments(req) {
  // ... existing routes ...
  ["ws", "chat"] -> your_socket.serve(req, ctx)
  _ -> next(req)
}
```

### No Supervisor Child

With one runtime per connection there is **no component entry in the
supervision tree** — no `process.new_name`, no boot-time
`lustre.start_server_component`. The socket's `on_init` starts the
runtime linked to itself; app boot only starts the actors whose
subjects go into `Flags`.

## Common Patterns

### Model Update with List

```gleam
fn update(model: Model, msg: Msg) -> #(Model, effect.Effect(Msg)) {
  case msg {
    AddItem(item) -> {
      let new_items = [item, ..model.items]
      #(Model(..model, items: new_items), effect.none())
    }
  }
}
```

### Prevent Redundant Updates

```gleam
fn update(model: Model, msg: Msg) -> #(Model, effect.Effect(Msg)) {
  case msg {
    UpdateInput(text) -> {
      case text == model.input {
        True -> #(model, effect.none())  // Skip if unchanged
        False -> #(Model(..model, input: text), effect.none())
      }
    }
  }
}
```

### External Message Handling

```gleam
fn update(model: Model, msg: Msg) -> #(Model, effect.Effect(Msg)) {
  case msg {
    ExternalMsg(ext) -> {
      case ext {
        AddMessage(msg) -> {
          let new_messages = [msg, ..model.messages]
          #(Model(..model, messages: new_messages), effect.none())
        }
      }
    }
    UserClickedSend -> {
      // Handle user action
      #(model, effect.none())
    }
  }
}
```

## Sub-Components (element.map / effect.map)

When one component grows a second surface (a settings page, an editor
panel), split it into a sub-component module with its own
`State`/`Msg`/`update`/`view`, and lift it into the parent app
(`element.map`/`effect.map` are the whole mechanism; verified on Lustre
5.7.1). Keep the split one-way:

- the parent owns the shared data and passes it into `view` as arguments;
- the sub-component owns its own editor states and effects;
- results the parent must act on travel back as an explicit `Signal`
  out-msg returned from `update` — the sub-component never reaches into
  the parent's model.

```gleam
// Parent Msg wraps the sub-component's Msg
pub type Msg {
  Settings(settings_component.Msg)
  // ...
}

// In the parent's update: delegate, fold the signals, lift the effect
Settings(msg) -> {
  let #(state, inner_eff, signals) =
    settings_component.update(model.settings, msg, model.shared_data)
  let #(model, effs) = fold_signals(model, signals)
  #(model, effect.batch([effect.map(inner_eff, Settings), ..effs]))
}

// In the parent's view: lift the sub-view
element.map(
  settings_component.view(model.settings, model.shared_data),
  Settings,
)
```

The `Signal` list keeps the child's outcomes — "a record was created",
"the list changed", "operation failed: reason" — as data the parent
interprets, so the two modules stay decoupled in both directions.

## Rendering Untrusted Text

Everything a model, tool, or external service produces is hostile text.
Render it exclusively as Lustre text nodes (`ht.text(...)`, or element
content) — the virtual DOM never interprets it, so payloads like
`<script>` or misclosed markup display inertly. Never splice untrusted
strings into inline-JS attributes (`at.attribute("onclick", ...)` with
interpolation) or any raw-HTML escape hatch; tool output belongs in the
view as truncated, inert text previews.

## Common Pitfalls

### 1. Conditional preventDefault in Server Components

**Error**: wanting to cancel only *some* events' default action (e.g. Enter
in a textarea) — the handler runs server-side, after the default already
happened; a blanket `event.prevent_default` on `keydown` blocks all typing.

**Fix**: restructure so the default is harmless — uncontrolled inputs,
reading `target.value` at keydown time, keyed replacement to clear (see
[Inputs: Controlled vs Uncontrolled](#inputs-controlled-vs-uncontrolled-server-components)).

### 2. `html.textarea` Takes a String, Not Children

**Error**: `ht.textarea([attrs], [ht.text(model.draft)])` — type error.

**Fix**: `ht.textarea([attrs], model.draft)` — the second argument is the
content `String` (which also sets a `value` property on the element).

### 3. `decode.at` Is Not `use`-able

**Error**: `use value <- decode.at(["target", "value"], decode.string)` —
arity error (all args already supplied).

**Fix**: `use value <- decode.subfield(["target", "value"], decode.string)`.

### 4. External Messages Not Received

**Error**: Component not getting messages from actors

**Fix**: Ensure the `server_component.select` effect is in `init` and the
feeding actor actually holds the per-connection subject (dispatch it from
the selector callback). With the single-client shared runtime, also check
`process.register()` succeeded

### 5. Duplicate Route Definitions

**Error**: Multiple routes causing 404s

**Fix**: Check both HTTP and WebSocket route handlers in router.gleam

### 6. Context Type Mismatch

**Error**: Type errors building per-connection flags or accessing actors in Context

**Fix**: Update `web.Context` to carry the actor subjects the `Flags` need and adjust the `mist_starter` signature to pass them through

### 7. Attribute Module Confusion

**Error**: Using wrong attribute functions

**Fix**: Import `lustre/attribute as at` and use `at.class()`, `at.value()`, etc.

## CSS Integration

Add CSS file to `priv/static/your-style.css` and include in layout:

```gleam
// In src/web.gleam - layout function
ht.link([at.rel("stylesheet"), at.href("/static/your-style.css")]),
```

### CSS Inheritance in Shadow DOM

Server components always render into a shadow root. In Lustre ≥ 5,
`component.adopt_styles` defaults to `True`: the runtime copies/adopts the
page's stylesheets into the shadow root on mount, so page CSS styles the
component out of the box. Set `component.adopt_styles(False)` only if you
ship component-scoped styles instead.

`component.open_shadow_root` defaults to `True` (an *open* root — page JS
can reach inside via `host.shadowRoot` or `event.composedPath()`). Passing
`False` gives a **closed** root — not light DOM — and closed means page JS
cannot see inside even via `composedPath()`: event targets retarget to the
host element. Useful for encapsulation, fatal for page-script helpers.

## Shadow DOM JavaScript

### Accessing Elements Inside Shadow DOM

`document.querySelector()` cannot find elements inside a server component's shadow DOM. From an element inside the component, use `getRootNode()` to access the shadow root:

```gleam
// Inline onclick to scroll a container inside the server component
ht.button(
  [
    at.attribute(
      "onclick",
      "const sr=this.getRootNode();const el=sr.querySelector('.scrollable');if(el){el.scrollTop=el.scrollHeight}",
    ),
  ],
  [ht.text("Scroll to bottom")],
)
```

**Key pattern**: `this.getRootNode()` returns the shadow root when called from an element inside it. Use this to query other elements within the same server component.

### Page-Shell JS for Browser-Only State

Some state — scroll position, viewport geometry, the user's scroll
*intent* — exists only in the browser and must not round-trip through the
server. Give the page shell a small **static, token-free script** that
owns what the server view cannot know (chat-log auto-follow is the
canonical example):

- Find the host (`document.querySelector('lustre-server-component')`),
  then its shadow root; query elements inside the root, not `document`.
- Follow new content with a `MutationObserver` on the scroll container
  (`scrollTop = scrollHeight` immediately, plus one
  `requestAnimationFrame` follow-up for late layout — no debounce).
- Unpin on explicit upward gestures (wheel up, touch drag,
  ArrowUp/PageUp/Home, scrollbar drag); re-pin when the user scrolls back
  near the bottom.
- Let the server keep owning the markup: mirror the pin state onto a
  server-rendered inert element's attribute (e.g. toggle its `hidden`),
  and handle its clicks by delegation on the shadow root so the press
  never becomes a server message.
- This requires an **open** shadow root (the default) — see
  [CSS Inheritance in Shadow DOM](#css-inheritance-in-shadow-dom).

Scrollbar-drag subtlety while content streams in: your own `scrollTop`
sets fire `scroll` events (echoes) — ignore events for a short window
after each set, but treat a `scrollTop` materially **below** your last
set position as a scrollbar drag (content growth never lowers
`scrollTop`) and unpin immediately, or the rAF follow-up will yank the
drag back.

### Limitations

- `before_paint` and `after_paint` effects are ignored for server components
- External JavaScript cannot directly access shadow DOM elements without a reference
- `autofocus` **is** honoured via runtime sync (it re-`focus()`es when the
  attribute is applied to a freshly created element) — handy after keyed
  replacements to restore focus without JS

## Testing

### Protocol-Level Testing (No Browser)

The server-component flow is testable end-to-end with a plain WebSocket
client speaking the runtime protocol — valuable for the class of bug that
only shows up over the transport (echo races, patch shapes, event routing).

Wire format (client → server): one JSON object per frame,
`{"kind":3,"messages":[{"kind":1,"path":"…","name":"keydown","event":{…}}]}`
(`kind:1` = event_fired, `kind:0` = attribute_changed, `kind:2` =
property_changed, wrapped in `kind:3` batches). Server → client: `kind:0`
mount (full vdom), `kind:1` reconcile (patch tree).

Event **path** rules (must match exactly or the server silently drops the
event):

- Segments joined with `"\t"`; the view root element contributes a leading
  `"0"` (its index inside the mount container).
- Plain children contribute their **index**; **keyed children contribute
  their key string** (e.g. `"0\t1\t1\t1\tcomposer-0"`).
- The handler cache keys on `path <> "\n" <> event_name`.

Auto-included event fields (no `server_component.include` needed): `key` for
keydown/keyup/keypress, `target.value`/`target.checked` for input/change,
`detail.formData` for submit. Everything else your decoder reads must be
listed in `include`.

With this, a ~150-line raw-socket script verified: mount vdom shape, event
decoding, and that a key rotation produces a keyed **Replace** patch (the
clearing mechanism) — before any browser was involved.

### Manual Testing Checklist

1. ✅ HTTP route loads HTML page
2. ✅ WebSocket route connects successfully
3. ✅ Browser console shows no WebSocket errors
4. ✅ Clicks and input send messages to server
5. ✅ External messages update UI in real-time
6. ✅ Page refresh reconnects WebSocket
7. ✅ Multiple browser tabs work independently
8. ✅ Composer: Enter sends and the field clears + refocuses; Shift+Enter
   inserts a newline (and only sends on the next plain Enter)
9. ✅ Reload re-opens the client's own state (per-tab); two tabs never
   mirror each other's selection or panels

## Reference

- [Lustre Documentation](https://lustre.build/)
- [Lustre Examples](https://github.com/lustre-labs/lustre/tree/main/examples)
- [Mist WebSocket](https://hexdocs.pm/mist/)
- [Gleam Process](https://tour.gleam.run/basics/processes/)
