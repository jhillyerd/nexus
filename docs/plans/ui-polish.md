---
title: Nexus — UI polish pass (visual review follow-ups)
status: planned
tags: [nexus, ui, css, pico, responsive]
updated: 2026-11-05
---

# Nexus: UI polish pass

> Decisions from the 2026-11-05 visual review session:
>
> - **The review ran the real app, not a mock**: repo dev DB, auth off, the
>   e2e fake Bifrost (`e2e/services.mjs`) playing scripted streaming
>   scenarios, 20 screenshot states across desktop/tablet/mobile ×
>   light/dark plus a computed-style probe of the rendered shadow DOM.
>   Curated evidence lives in `assets/ui-review/`; the full set (ephemeral)
>   was `/tmp/nexus-shots/`.
> - **F1 (cascade) is the root finding, not a nitpick**: the sidebar was
>   *designed* compact (`.ctl` at `.7rem` etc.) and renders at full CTA
>   size because `#app button` outranks every app-local compact class.
>   Fix the cascade first — several later findings shrink or vanish once
>   the chrome renders at its intended size.
> - **No behaviour-encoding changes**: everything here is CSS and Lustre
>   view markup in `src/nexus/ui.gleam` / `ui_settings.gleam` /
>   `page.gleam`. `nexus/transcript` is untouched, so `m3_prefix_test`
>   must stay green without re-capture.
> - **Phased delivery** (§4): quick cascade/polish wins land first and
>   independently; responsive restructuring and settings restyle follow.
>   Each phase keeps `gleam test` and the e2e browser suite green.

## 1. Goal and non-goals

**Goal.** Close out the usability and visual findings from the
2026-11-05 visual review: restore the intended compact chrome (F1),
de-clutter the session list (F2), make sub-900px viewports usable (F3),
fix the off-screen create panel (F4), give empty and streaming states
intentional presentation (F5, F8), balance the wide-screen conversation
column (F6), and restyle the settings page (F7).

**Non-goals.**

- No markdown rendering, no message-actions (copy/edit/retry), no new
  features — presentation and layout only.
- No change to the commit rules, the transcript encode path, or the
  per-connection runtime topology. The settings surface keeps its
  draft-preserving design: the chat subtree stays mounted and hidden via
  `#layout.settings-mode`; nothing in this plan unmounts it.
- No CDN assets (AGENTS.md rule) — any icon work stays text glyphs or
  vendored assets, and the `web_test` no-external-URL guard keeps it
  honest.

## 2. Evidence

Captured 2026-11-05 with a live server (`docker compose up -d` +
`gleam run`, `NEXUS_UI_TOKEN` unset, fake provider from
`e2e/services.mjs` serving scripted `case:*` scenarios over a seeded dev
DB — sessions s1/s2/s5 from prior e2e runs).

| File | Shows |
|---|---|
| `assets/ui-review/01-desktop-initial.png` | 1440×900 light, initial load; F1 bulk, F2 control soup, F6 edge-pinned turns |
| `assets/ui-review/02-desktop-chat.png` | Rich transcript (reasoning + tool chips); F6, F8 chip wording |
| `assets/ui-review/08-settings.png` | Settings view; F7 unstructured layout |
| `assets/ui-review/12-mobile-initial.png` | 390×844; F3 sidebar crushes the transcript |
| `assets/ui-review/16-tablet-860.png` | 860×900; F3 at the breakpoint edge |
| `assets/ui-review/17-create-panel.png` | F4: "New" opens the panel off-screen at the sidebar's bottom |
| `assets/ui-review/18-empty-session.png` | F5: blank transcript above the composer |

Full state set from the same run (not committed): expanded tool cards,
live thinking/streaming, jump-to-latest, dark variants, mobile settings.

## 3. Findings and fix sketches

Ordered by impact; F1 first because it changes what every other finding
looks like.

### F1 — App-local compact classes lose the cascade to `#app button`

`page.gleam`'s `css()` prefixes bare-element overrides with `#app` to
beat Pico's double element/attribute match (the documented trap), but
the app's own compact classes are (0,1,0) or lose on the element count,
so `#app button { font-size: inherit; padding: .42rem .8rem; … }`
(1,0,1) overrides them. Computed styles measured in the running UI:

| Selector | Intended | Renders as |
|---|---|---|
| `.ctl` | `.7rem`, `.18/.5rem` pad | 15px, 6.3/12px pad → "Pin" measures 48×36px |
| `.tag-chip` | `.68rem` quiet chip | 15px full-size button |
| `.toggle` | `.78rem` | 15px |
| `#filter-clear` | `.85rem`, `.3/.55rem` pad | 15px (`#filter-clear` (1,0,0) loses on the element count) |
| `.inline-editor button`, `.confirm-delete button`, `.provider-form-buttons button` | `.72–.75rem` | 15px |
| `#jump-latest` | `padding: 0` circle | padding clobbered → ↓ sits off-center |

Only `#app header button` (1,0,2) and `button#send` / `button#create-session`
((1,0,1), later in source) survive.

**Fix.** Restate every compact rule with an `#app` prefix in one pass:
`#app .ctl`, `#app .tag-chip`, `#app .toggle`, `#app #filter-clear`,
`#app .inline-editor button`, `#app .confirm-delete button`,
`#app .provider-form-buttons button`, `#app #jump-latest`. Add a comment
next to the existing trap comment: the prefix is now load-bearing in both
directions. Pure `css()` change.

### F2 — Session rows are control soup

Every **active** row renders 5 bordered buttons (Pin/Rename/Tags/
Archive/Delete) plus tag-chip buttons — archived rows render 4, omitting
Pin per the never-pin-archived invariant (the control does not exist
there). With three active sessions the controls outweigh the content,
and rows wrap to ~3 lines on mobile.

**Fix.** CSS-only reveal, **scoped to session rows**: `.row-controls` is
a shared class — the settings provider rows use it too
(`ui_settings.gleam`), so a global reveal rule would hide Settings'
Disable/Enable/Edit/Test/Delete. Hide `.session-row .row-controls` (or
introduce a session-specific class) until the row is hovered,
keyboard-focused, or selected (`:hover`, `:focus-within`, `.selected`),
guarded by `@media (hover: hover)` so touch devices keep the controls on
the selected row at minimum. After F1 the chips shrink; consider dropping
their border for a quiet chip look. If hover-reveal still feels heavy on
touch, a per-row "…" overflow is the fallback (needs a view change in
`ui.gleam`, decide at implementation).

### F3 — Below 900px the sidebar crushes the chat

The `@media (max-width: 900px)` stack gives `aside` its natural height:
three sessions push the transcript into a ~100px sliver with content
clipped under the composer (`12`, `16`). Unusable without collapsing the
list.

**Fix.** Escalating options; pick at implementation:
(a) one-line cap: `aside { max-height: 40dvh }` in the mobile block;
(b) a "Sessions" toggle collapsing the list to its header row (a
`model.sidebar_open`-style flag — per-client state, allowed);
(c) proper drawer. Ship (a) first; (b)/(c) only if (a) still pinches.

### F4 — "New" opens the create panel off-screen

`#create-panel` sits at the bottom of the `aside`, below the whole list;
clicking "New" (top-right of the list) usually opens it below the fold
(`17`).

**Fix.** Move the create panel above the session list (markup order in
`sidebar()`), or have `NewSessionToggled` swap the list for the panel.
Prefer the reorder: smallest diff, keeps e2e selectors stable.

### F5 — Empty transcript renders nothing

A fresh session shows a blank void above the composer (`18`).

**Fix.** In `log_lines`, when the log is empty and nothing is streaming,
render a muted `.note` ("Send a message to start — tool calls and
reasoning will render here"). Text nodes only, per the hostile-text
invariant.

### F6 — Wide screens pin turns to opposite edges

`.turn` caps at 46rem but `#log` doesn't, so user/assistant bubbles hug
opposite edges of a ~1200px pane with dead space between (`01`–`02`).

**Fix.** Center the conversation column with an inner
`max-width: 52rem; margin-inline: auto; width: 100%` wrapper around the
log's children — the existing per-turn `align-self` user-right/
assistant-left placement then works unchanged inside the narrower
column. (`#log { align-items: center }` is not an alternative:
`.turn.user` / `.turn.assistant` override it per-child with `align-self`,
so the bubbles stay edge-pinned, and making turns full-width to avoid
that loses the bubble widths.) Verify the jump-to-latest anchor
(`#log-wrap`, absolute) is unaffected — it must stay pane-relative, not
column-relative.

### F7 — Settings page is unstructured

h1 far left, "Add" floating mid-page, provider rows as bare text +
button row, add form as three stacked bare inputs (`08`).

**Fix.** Inside the existing 46rem column: one header row (title left,
Add right); provider rows get the session-row card treatment (border,
radius, padding, badge moved to the row head); the add/edit form becomes
a bordered card with a heading. Reuse existing classes where possible
(`.session-row`, `.badge`, `.provider-form`), keeping the Pico-first
rule — prefer tokens/classes over new one-off rules.

### F8 — Small polish

- **Stop is always visible and disabled** while idle — hide it when not
  streaming (mirrors `#loop-status`'s `hidden` handling) or swap
  Stop/Send in place during a turn.
- **Reasoning chip label**: the committed chip's DOM is just the text
  `reasoning` — the left marker is the native list-style restored by
  `list-style: revert`, and the right chevron is Pico's
  `details summary::after` (it rotates when open), so the chip *renders*
  as `▶ reasoning ▶` without any authored glyph. The live block says
  "thinking…" — pick one label ("thinking") for both states; no markup
  change is needed for the chevrons.
- **Header**: `nexus  smart` (the session's model alias) is cryptic
  without context; show the selected session's title instead (alias can
  move into the session subtitle it already has). Group a text
  "connected"/"offline" label with the status dot near the Settings
  button.

## 4. Phasing

Each phase is independently landable, keeps the full offline suite and
the e2e browser suite green, and ends with a screenshot sweep against
`assets/ui-review/` (light+dark, 1440/860/390) to catch visual
regressions the offline suite cannot see.

- **P1 — cascade + composer polish (F1, F8 Stop/wording).** One `css()`
  pass plus small `ui.gleam` view tweaks. Highest leverage, lowest risk.
  **Landed 2026-11-05**: every compact button rule in `css()` carries the
  `#app` prefix (including `.ctl.danger, button.danger` and the
  `.toggle.on` / `.ctl:hover` state variants, which lost on the id count
  too; `.ctl:hover` also gained `:not(:disabled)` so the hover brighten
  cannot outrank the `#app button:disabled` dim); Stop renders `hidden`
  while idle — it stays mounted, and Pico's global
  `[hidden] { display: none !important }` does the hiding — and is only
  visible while `model.streaming`; both reasoning-chip
  states now say "thinking" (ellipsis stays on the live block as its
  streaming cue). The e2e committed-chip assertion followed the label
  rename; `ui_test` pins the hidden-Stop rule and the unified label.
- **P2 — sidebar density (F2).** Hover-reveal controls + quiet chips;
  verify keyboard reachability (`:focus-within`) and the touch guard.
  **Landed 2026-11-05**: CSS-only, scoped to `.session-row` (Settings'
  provider rows share `.row-controls` and keep theirs always on, so the
  reveal is *not* global). Controls render `display: none` and come back
  on `.selected`, `:focus-within`, or `:hover` inside `@media (hover:
  hover)` — the pointer half is off for touch, where the selected row is
  the only reachable case (verified: `hasTouch` context reports
  `(hover: hover)` false, and tapping a row selects it and shows its
  controls). Keyboard reachability is structural, not hopeful: the row's
  own `.session-main` button is its first tab stop, so tabbing in matches
  `:focus-within`, and every later control lives inside the row, so it
  stays revealed while you traverse it. `.tag-chip` lost its border
  (outline returns on hover) for the quiet-chip look. Measured with the
  always-on rule forced against the shipped CSS: 52px per unselected row
  saved at 1440px, 26px at 390px. `web_test` pins the reveal rules and
  their scope; the e2e organize pass drives every control through
  `revealRowControls()` and asserts the hidden → hover → focus → hidden
  cycle explicitly.
- **P3 — layout (F3a cap, F4 create-panel reorder, F6 centered column).**
  Grid/markup changes in `page.gleam` + `sidebar()`; browser-suite
  selectors must keep working (`#create-panel`, `#layout`, session rows).
- **P4 — settings restyle (F7).** `ui_settings.gleam` view + `.settings-page`
  CSS; `openSettings`/`backToChat` e2e helpers must stay green.
- **P5 — empty state + header (F5, F8 header).** `log_lines` branch +
  header content; `ui_test` assertions for the new nodes (text-only).

## 5. Verification

- `gleam test` offline: `ui_test` for view-markup changes (F2/F4/F5/F8),
  `web_test`'s `m3_page_no_cdn_urls_test` + `assert_no_external_urls`
  for any new CSS/HTML, `m3_prefix_test` untouched and green (no encode
  change), store/mock suites unaffected.
- e2e browser suite (`node e2e/browser.spec.mjs` + `e2e/services.mjs`):
  full pass twice per phase; hover-reveal (F2) needs an explicit
  hover/focus assertion so the controls stay provably reachable; F3/F4
  need a `390×844` viewport check that the composer is visible without
  scrolling past the list.
- Manual screenshot sweep per phase at 1440 / 860 / 390, light + dark,
  compared against `assets/ui-review/` baselines; dark mode must be
  re-checked after every `css()` touch (Pico dark token mirror).
- No schema, store, or transcript-path changes — no migration, no
  squirrel regen, no fixture re-capture.

## 6. Open questions

- F2 on touch: hover-reveal with selected-row exception vs a "…"
  overflow menu — decide during P2 with a phone in hand.
- F3: is the 40dvh cap enough, or does the session list need a real
  collapse toggle? Decide during P3 against a realistic (20+ session)
  list.
- F6: the centered column interacts with the 46rem turn cap and the
  reasoning/tool block widths — settle the wrapper mechanics (single
  inner wrapper vs per-turn max-width + auto margins) while watching a
  long tool card at 1440. The `align-items: center` variant is ruled
  out (see F6).
- F8 header: session title vs "session title · model" — trivial, decide
  in P5.
