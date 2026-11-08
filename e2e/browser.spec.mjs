// M3 Workstream C — browser suite.
//
// Drives headless Chromium (Playwright) against a real Nexus server whose
// model backend is the controlled fake Bifrost (see services.mjs) and whose
// tools run against the controlled doc/searxng stubs. Verifies the complete
// M3 flow end-to-end through the real WebSocket UI:
//
//   1. bearer auth (401 without token, page with token)
//   2. model list (picker) and session list
//   3. create / switch sessions
//   4. text-only turn (streaming → completed)
//   5. stop during streaming (partial commit)
//   6. reconnect/replay: full tool history re-rendered after reload
//   7. http_fetch + web_search loops with typed tool cards
//   8. iteration-guard terminal rendering (max=2 instance)
//   9. byte-identical request prefixes turn-over-turn (fake records them)
//  10. mobile viewport: a second context gets an independent per-client
//      runtime (own selection, non-mirroring panels, reload restores its
//      own session) with no horizontal overflow with tool cards
//  11. connection dot: red while the backend is down, green on reconnect
//  12. provider management end-to-end (multi-provider P5, now in the
//      Settings view): create a provider in Settings, test its
//      connection (live model aliases), pick it in the create panel
//      (aliases reload per provider), pin a session to it, stream a turn,
//      and hit the delete/disable guard rails
//  13. utility branch (utility-titles §4.1 / utility-tags §3.1): the
//      model's two-line reply (line 1 title, line 2 tags) lands through
//      the auto path as sidebar chips — inert text nodes, <script>
//      payloads included — while a manual tags save freezes the set so
//      the racing model apply is refused by the both-provenance guard
//
// Usage: node e2e/browser.spec.mjs   (see e2e/README.md)

import { spawn } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, writeFileSync } from "node:fs";
import { chromium } from "playwright";
import { startServices, UTILITY_REPLY_DELAY_MS } from "./services.mjs";

const ROOT = new URL("..", import.meta.url).pathname;
const TOKEN = "e2e-token";
const results = [];
let current = null;
// Hoisted so failure diagnostics (dumpPageState) can reach the live page.
let page = null;
// Every page the suite opens contributes here; the final test asserts it
// is empty. A pageerror means a shell script or the runtime threw in the
// browser — exactly the class of bug (an undefined function left behind
// by an edit) that per-test assertions can miss.
const pageErrors = [];
const track = (p) =>
  p.on("pageerror", (err) => {
    pageErrors.push(String(err));
    console.log(`  [pageerror] ${err}`);
  });

function test(name, fn) {
  current = { name, status: "pass", error: null, ms: 0 };
  const started = Date.now();
  return Promise.resolve()
    .then(fn)
    .then(() => {
      current.ms = Date.now() - started;
      results.push(current);
      console.log(`  ok  ${name} (${current.ms}ms)`);
    })
    .catch(async (err) => {
      current.status = "fail";
      current.error = String(err?.stack ?? err);
      current.ms = Date.now() - started;
      results.push(current);
      console.log(`FAIL  ${name}\n      ${current.error}`);
      await dumpPageState(name).catch(() => {});
    });
}

/// Failure diagnostics: the component lives in a shadow root, so dump its
/// HTML plus a screenshot — raw `document.body` shows only the host element.
async function dumpPageState(name) {
  if (!page) return;
  const shadow = await page
    .evaluate(() => {
      const host = document.querySelector("lustre-server-component");
      return host?.shadowRoot?.innerHTML ?? "(no shadow root)";
    })
    .catch(() => "(evaluate failed)");
  const probes = await page
    .evaluate(() => {
      const hosts = document.querySelectorAll("lustre-server-component").length;
      const sr = document.querySelector("lustre-server-component")?.shadowRoot;
      return {
        hosts,
        url: location.href,
        pickerOptions: sr?.querySelectorAll("#model-picker option").length ?? -1,
        userTurns: sr?.querySelectorAll(".turn.user").length ?? -1,
        toolCards: sr?.querySelectorAll(".turn.tool").length ?? -1,
      };
    })
    .catch((e) => ({ error: String(e).slice(0, 100) }));
  const locatorCounts = {
    pickerOptions: await page.locator("#model-picker option").count(),
    userTurns: await page.locator(".turn.user").count(),
    toolCards: await page.locator(".turn.tool").count(),
  };
  const dump = `--- page state after FAIL ${name} ---\nprobes=${JSON.stringify(probes)} locatorCounts=${JSON.stringify(locatorCounts)}\n${String(shadow).slice(0, 2000)}\n--- end ---`;
  console.log(dump);
  const shot = new URL(`./failure-${name.replace(/[^a-z0-9]+/gi, "-").slice(0, 40)}.png`, import.meta.url).pathname;
  await page.screenshot({ path: shot, fullPage: true }).catch(() => {});
}

function assert(cond, message) {
  if (!cond) throw new Error(`assert failed: ${message}`);
}

function eq(actual, expected, message) {
  if (actual !== expected) {
    throw new Error(`${message}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/// Poll a locator-based predicate. Raw `document.*` queries cannot pierce
/// the component's shadow root; Playwright locators can — so every DOM
/// predicate in this suite goes through locators.
async function poll(fn, { timeout = 30_000, interval = 250, message = "poll" } = {}) {
  const deadline = Date.now() + timeout;
  let lastErr = null;
  while (Date.now() < deadline) {
    try {
      const value = await fn();
      if (value) return value;
    } catch (err) {
      lastErr = err;
    }
    await new Promise((r) => setTimeout(r, interval));
  }
  throw new Error(`poll timeout: ${message}${lastErr ? ` (last error: ${lastErr.message})` : ""}`);
}

async function waitHealthy(port, timeoutMs = 30_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/healthz`);
      if (res.ok) return;
    } catch {
      /* not up yet */
    }
    await new Promise((r) => setTimeout(r, 300));
  }
  throw new Error(`nexus on :${port} never became healthy`);
}

const ENC_KEY = "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=";
const DATABASE_URL = process.env.E2E_DATABASE_URL ?? "postgres://nexus@127.0.0.1:5433/nexus";

/// Reset the shared e2e database so the suite starts from nothing —
/// reruns and interleaved integration runs must not leave sessions
/// (breaking the empty-list assertions) or extra providers (the create
/// panel auto-targets the FIRST enabled provider by name, and e.g. an
/// integration run's "bifrost" would sort before this suite's "fake").
/// Requires `psql` next to the (already mandatory) Postgres.
function resetDatabase() {
  return new Promise((resolve, reject) => {
    const child = spawn(
      "psql",
      ["-q", DATABASE_URL, "-c", "truncate session_message, session, provider cascade;"],
      { stdio: ["ignore", "pipe", "pipe"] },
    );
    let out = "";
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (out += d));
    child.on("error", (err) => reject(new Error(`psql not found (${err.message}) — it ships with the Postgres the suite already requires`)));
    child.on("exit", (code) =>
      code === 0
        ? resolve()
        : reject(new Error(`database reset failed (${code}):\n${out}`)),
    );
  });
}

/// Seed (or re-point) the suite's keyless provider. The provider table is
/// the only provider source since the P3 hard cut — nexus reads no
/// BIFROST_* env anymore — so the fake endpoint has to be a row first.
/// dev_seed is idempotent by name and re-points base_url when the fake's
/// port changed between runs.
function seedProvider(bifrostPort) {
  const env = {
    ...process.env,
    DATABASE_URL,
    NEXUS_ENCRYPTION_KEY: ENC_KEY,
    NEXUS_SEED_PROVIDER_NAME: "fake",
    NEXUS_SEED_PROVIDER_BASE_URL: `http://127.0.0.1:${bifrostPort}/v1`,
  };
  return new Promise((resolve, reject) => {
    const child = spawn("gleam", ["run", "-m", "nexus/dev_seed"], {
      cwd: ROOT,
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let out = "";
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (out += d));
    child.on("exit", (code) =>
      code === 0
        ? resolve()
        : reject(new Error(`dev_seed failed (${code}):\n${out}`)),
    );
  });
}

function startNexus({ port, bifrostPort, searxPort, maxToolIterations }) {
  const env = {
    ...process.env,
    NEXUS_ENCRYPTION_KEY: ENC_KEY,
    NEXUS_HTTP_BIND: "127.0.0.1",
    NEXUS_HTTP_PORT: String(port),
    NEXUS_UI_TOKEN: TOKEN,
    NEXUS_MAX_TOOL_ITERATIONS: String(maxToolIterations),
    // The http_fetch target is a loopback service under our control.
    NEXUS_HTTP_FETCH_ALLOW_PRIVATE: "true",
    NEXUS_SEARXNG_BASE_URL: `http://127.0.0.1:${searxPort}`,
    NEXUS_SYSTEM_PROMPT:
      "You are nexus under e2e test. Follow the case: markers exactly.",
  };
  const child = spawn("gleam", ["run"], {
    cwd: ROOT,
    env,
    stdio: ["ignore", "pipe", "pipe"],
    detached: true,
  });
  const log = [];
  const collect = (stream) => {
    stream.on("data", (d) => log.push(d.toString()));
  };
  collect(child.stdout);
  collect(child.stderr);
  return { child, log: () => log.join(""), stop: () => killTree(child) };
}

function killTree(child) {
  return new Promise((done) => {
    child.on("exit", () => done());
    try {
      process.kill(-child.pid, "SIGTERM");
    } catch {
      try { child.kill("SIGTERM"); } catch { /* already gone */ }
    }
    setTimeout(done, 3000);
  });
}

async function connected(page) {
  await page.waitForSelector("#status.live", { timeout: 15_000 });
}

// Settings-view navigation (the header toggle swaps the main area):
// every transition ASSERTS arrival, so a wrong-view divergence fails
// here with a clear message instead of as a confusing poll timeout on
// a chat-only (or settings-only) selector further down.
async function settingsOpen(page) {
  return (await page.locator("#layout.settings-mode").count()) === 1;
}

async function openSettings(page) {
  if (await settingsOpen(page)) return;
  await page.click("#settings");
  await poll(() => settingsOpen(page), {
    timeout: 10_000,
    message: "settings view open",
  });
}

async function backToChat(page) {
  if (!(await settingsOpen(page))) return;
  await page.click("#settings");
  await poll(async () => !(await settingsOpen(page)), {
    timeout: 10_000,
    message: "chat view restored",
  });
}

// The per-client selection mirror (`#layout[data-selected]`, persisted
// client-side by the page shell and re-supplied on the /ws route).
async function selectedId(p) {
  return await p.locator("#layout").evaluate((el) => el.getAttribute("data-selected") || "");
}

/// Reveal a session row's hover controls (ui-polish F2) before driving
/// them. Playwright's `click()` waits for visibility *before* hovering,
/// so a control that only exists on `:hover`/`:focus-within` must be
/// revealed first — the same thing a real pointer user does by moving
/// onto the row. Selecting the row is the always-visible path; hover is
/// the desktop path, and it doubles as the reachability proof.
async function revealRowControls(row) {
  const controls = row.locator(".row-controls");
  if (await controls.isVisible()) return;
  await row.hover();
  await poll(async () => await controls.isVisible(), {
    timeout: 5000,
    message: "row controls revealed by hover",
  });
}

/// Walk real Tab presses from the sidebar's last pre-list control and
/// return once `row`'s select button holds focus, reporting the trail.
/// `focus()` is deliberately avoided: it proves nothing about the order,
/// so a control dropping out of the tab order would pass unnoticed.
async function tab_to_row_main(page, row) {
  await page.locator("#show-archived").focus();
  const want = row.locator(".session-main");
  for (let i = 0; i < 40; i++) {
    await page.keyboard.press("Tab");
    const hit = await want.evaluate((el) => el === document.activeElement || el.getRootNode().activeElement === el).catch(() => false);
    if (hit) return true;
  }
  return false;
}

async function sendAndWaitIdle(page, text) {
  await page.fill("#input", text);
  const before = await page.$$eval(".turn.user", (els) => els.length);
  await page.press("#input", "Enter");
  // The user bubble arriving proves the turn started; the Send button
  // re-enabling proves it ended (done / stopped / failed).
  await poll(
    async () => (await page.locator(".turn.user").count()) > before,
    { timeout: 15_000, message: "user bubble after send" },
  );
  await poll(() => page.locator("#send").evaluate((el) => !el.disabled), {
    timeout: 120_000,
    message: "send re-enabled after turn",
  });
}

// Split a serialized request body at the messages/stream boundary: the
// messages array must grow by suffix only, and the envelope after it must
// stay byte-identical (model, stream, tools, tool_choice).
function bodyParts(body) {
  const idx = body.indexOf(',"stream"');
  if (idx < 0) throw new Error(`request body has no stream marker: ${body.slice(0, 120)}`);
  return { messages: body.slice(0, idx), envelope: body.slice(idx) };
}

/// The one documented, generation-side envelope delta carried by
/// utility-title branch requests (utility.gleam `utility_token_cap`, plan
/// §4.1): it caps the completion and never tokenizes into the prompt, so
/// the prompt-cache prefix is untouched — but it IS an envelope byte
/// change, so the strict suffix-only rule below does not apply to it.
const UTILITY_DELTA = ',"max_completion_tokens":512';

function extendsRequest(prevBody, nextBody) {
  const prev = bodyParts(prevBody);
  const next = bodyParts(nextBody);
  // Appending messages inserts before the messages array's closing bracket,
  // so the byte-prefix property is: everything except that `]` reappears
  // verbatim at the head of the next request, and the envelope after it is
  // unchanged.
  return (
    next.messages.startsWith(prev.messages.slice(0, -1)) &&
    next.envelope === prev.envelope
  );
}

// ---------------------------------------------------------------------------

async function main() {
  console.log("starting controlled services…");
  const services = await startServices();
  const mainPort = 18081;
  const guardPort = 18082;
  await resetDatabase();
  await seedProvider(services.bifrostPort);
  const main = startNexus({ port: mainPort, maxToolIterations: 8, ...pick(services) });
  let guard = startNexus({ port: guardPort, maxToolIterations: 2, ...pick(services) });
  const base = `http://127.0.0.1:${mainPort}`;
  const guardBase = `http://127.0.0.1:${guardPort}`;

  let browser = null;
  let exitCode = 0;
  try {
    await waitHealthy(mainPort);
    await waitHealthy(guardPort);
    console.log("nexus up; launching chromium…");
    browser = await chromium.launch({
      headless: true,
      args: ["--no-sandbox", "--disable-dev-shm-usage"],
      // On NixOS (e2e/playwright.nix) the browser is nixpkgs' Chromium.
      executablePath: process.env.NIX_PLAYWRIGHT_CHROMIUM || undefined,
    });
    const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
    page = await context.newPage();
    track(page);
    page.on("console", (msg) => {
      if (["error", "warning"].includes(msg.type())) {
        console.log(`  [console.${msg.type()}] ${msg.text().slice(0, 200)}`);
      }
    });

    // -- 1. auth ------------------------------------------------------------
    await test("auth: page without token is 401", async () => {
      const res = await page.request.get(base + "/");
      eq(res.status(), 401, "unauthenticated status");
    });
    await test("auth: page with token is 200 html", async () => {
      const res = await page.request.get(`${base}/?token=${TOKEN}`);
      eq(res.status(), 200, "authenticated status");
      assert((await res.text()).includes("lustre-server-component"), "component host element");
    });
    await test("auth: session create pins provider + model (no token → 401)", async () => {
      // GET /models is gone (P3 hard cut: no default provider); the
      // create route is the scripted surface now.
      // The route is gone entirely: the router's catch-all answers 404
      // before the auth gate is even consulted.
      eq((await page.request.get(base + "/models")).status(), 404, "models gone (no token)");
      eq(
        (
          await page.request.get(`${base}/models`, {
            headers: { authorization: `Bearer ${TOKEN}` },
          })
        ).status(),
        404,
        "models gone (with token)",
      );
      const no = await page.request.post(`${base}/sessions`, {
        data: { provider: "fake", model: "smart" },
      });
      eq(no.status(), 401, "no-token create");
      const res = await page.request.post(`${base}/sessions`, {
        headers: { authorization: `Bearer ${TOKEN}` },
        data: { provider: "fake", model: "smart" },
      });
      eq(res.status(), 201, "bearer create pins fake/smart");
      const unknown = await page.request.post(`${base}/sessions`, {
        headers: { authorization: `Bearer ${TOKEN}` },
        data: { provider: "nope", model: "smart" },
      });
      eq(unknown.status(), 400, "unknown provider refused");
      // Leave no row behind: the next test asserts an empty session list.
      const created = await res.json();
      const gone = await page.request.delete(`${base}/sessions/${created.id}`, {
        headers: { authorization: `Bearer ${TOKEN}` },
      });
      eq(gone.status(), 204, "created session cleaned up");
    });

    // -- 2. page load: shell, websocket, aliases, empty session list -------
    await test("page: loads, connects websocket, opens the create panel", async () => {
      await page.goto(`${base}/?token=${TOKEN}`);
      await connected(page);
      await poll(
        async () => (await page.locator("#model-picker option").count()) >= 2,
        { timeout: 15_000, message: "alias options" },
      );
      const options = await page.$$eval("#model-picker option", (els) => els.map((e) => e.value));
      assert(options.includes("smart") && options.includes("fast"), `alias options: ${options}`);
      // The provider picker (P5) targets the seeded keyless provider by
      // default — the first enabled row — and the aliases above belong
      // to it.
      const providerOptions = await page.$$eval("#provider-picker option", (els) => els.map((e) => e.textContent));
      assert(
        providerOptions.length === 1 && providerOptions[0].includes("fake") && providerOptions[0].includes("keyless"),
        `provider options: ${providerOptions}`,
      );
      // No session is minted for the visitor: the list stays empty and the
      // create panel auto-opens, so the model is the user's choice.
      await poll(
        async () => page.locator("#create-panel").evaluate((el) => !el.hidden),
        { timeout: 15_000, message: "create panel auto-opened" },
      );
      eq(await page.locator("#session-list .session-main").count(), 0, "no sessions yet");
      assert(
        (await page.getAttribute("#input", "disabled")) !== null,
        "composer disabled without a session",
      );
      // ui-polish F5: an empty transcript renders an intentional muted
      // hint, not a blank void.
      await poll(
        async () =>
          (await page.locator("#log .note").textContent()).includes(
            "Send a message to start",
          ),
        { timeout: 15_000, message: "empty-state note" },
      );
    });

    // -- 3. create + switch sessions ----------------------------------------
    await test("sessions: create on both aliases and switch back", async () => {
      // The panel may be open (auto-opened on the empty list) or closed;
      // make it open.
      const panelOpen = () =>
        page.locator("#create-panel").evaluate((el) => !el.hidden);
      if (!(await panelOpen().catch(() => false))) {
        await page.click("#new-session");
      }
      await poll(panelOpen, { timeout: 10_000, message: "create panel open" });
      await page.selectOption("#model-picker", "smart");
      await page.click("#create-session");
      await poll(
        async () => (await page.locator("#session-list .session-main").count()) === 1,
        { timeout: 15_000, message: "first session appears" },
      );
      // A second session on the other alias.
      if (!(await panelOpen().catch(() => false))) {
        await page.click("#new-session");
      }
      await poll(panelOpen, { timeout: 10_000, message: "create panel reopened" });
      await page.selectOption("#model-picker", "fast");
      await page.click("#create-session");
      await poll(
        async () => (await page.locator("#session-list .session-main").count()) === 2,
        { timeout: 15_000, message: "second session appears" },
      );
      const labels = await page.$$eval("#session-list .session-main", (els) => els.map((e) => e.textContent));
      // Subtitles are `provider/model · age` (P5), so the label carries
      // the seeded provider's name before the alias.
      assert(labels.some((l) => l.includes("fake/fast")), `new session label: ${labels}`);
      const currentLabels = await page.$$eval(
        "#session-list .session-main[aria-current='true']",
        (els) => els.map((e) => e.textContent),
      );
      eq(currentLabels.length, 1, "exactly one current session");
      assert(currentLabels[0].includes("fake/fast"), `current is the new session: ${currentLabels}`);
      // Switch back to the original smart session (Created prepends, so
      // match by label rather than DOM position).
      await page
        .locator("#session-list .session-main", { hasText: "fake/smart ·" })
        .first()
        .click();
      await poll(
        () => page.locator("#model").evaluate((el) => el.textContent === "smart"),
        { timeout: 15_000, message: "header label after switch" },
      );
      // ui-polish F8: the header context is the session's TITLE; "smart"
      // here is the alias fallback (the fresh session is untitled), the
      // same rule the row title uses. The real title is asserted in the
      // organize test after its manual rename.
      const smartCurrent = await page
        .locator("#session-list .session-main", { hasText: "fake/smart ·" })
        .first()
        .getAttribute("aria-current");
      eq(smartCurrent, "true", "smart session current again");
    });

    // -- 3b. session organization --------------------------------------------
    await test("organize: auto-title, rename, tags, pin, filter, archive, delete", async () => {
      const headers = { authorization: `Bearer ${TOKEN}` };
      const sessions = async (query = "") =>
        (await (await page.request.get(`${base}/sessions${query}`, { headers })).json()).sessions;
      const byModel = async (m, query = "") =>
        (await sessions(query)).find((s) => s.model === m);
      const smart = await byModel("smart");
      const fast = await byModel("fast");
      const smartRow = page.locator(`.session-row[data-session-id="${smart.id}"]`);
      const fastRow = page.locator(`.session-row[data-session-id="${fast.id}"]`);

      // Sidebar density (ui-polish F2): an unselected row keeps its five
      // controls out of the way until you actually want them. Pinned here
      // so the pass cannot regress in either direction — permanently
      // hidden (controls unreachable) or permanently shown (no density
      // win). `fastRow` is the unselected one right now, so it is the
      // honest subject.
      {
        const controls = fastRow.locator(".row-controls");
        eq(await controls.isVisible(), false, "unselected row hides its controls");
        // Pointer path.
        await fastRow.hover();
        await poll(async () => await controls.isVisible(), {
          timeout: 5000,
          message: "hover reveals the row controls",
        });
        // Keyboard path: real sequential Tab navigation, not `focus()`.
        // `focus()` would pass even if the row's controls fell out of the
        // tab order entirely, which is the regression worth catching. The
        // sidebar's own `#show-archived` button is the last focusable
        // before the list, so starting there and pressing Tab walks the
        // actual order: every hidden control is out of the order until its
        // row has focus, so the row's `.session-main` is the stop that
        // opens it.
        await page.mouse.move(0, 0); // leave the list: no hover help
        const reached = await tab_to_row_main(page, fastRow);
        assert(
          reached,
          "Tab navigation reached the unselected row's select button",
        );
        await poll(async () => await controls.isVisible(), {
          timeout: 5000,
          message: "keyboard focus reveals the row controls",
        });
        // And it is the *focus* that did it: leaving the row hides them
        // again, with the pointer still off the list.
        await page.locator("#new-session").focus();
        await poll(async () => !(await controls.isVisible()), {
          timeout: 5000,
          message: "controls hide again once focus leaves the row",
        });
      }

      // Auto-title: the row title becomes the collapsed first message.
      await sendAndWaitIdle(page, "hello   organize world");
      let s = await byModel("smart");
      eq(s.title, "hello organize world", "auto title in API");
      eq(s.title_source, "auto", "auto title source");
      await poll(
        async () =>
          (await smartRow.locator(".session-title").textContent()).includes(
            "hello organize world",
          ),
        { timeout: 10_000, message: "auto title in row" },
      );

      // Manual rename through the inline editor pins the title. Row
      // controls are hover-revealed (ui-polish F2), so every control
      // drive starts with a reveal — that also proves the controls are
      // reachable, not merely present in the DOM.
      await revealRowControls(smartRow);
      await smartRow.getByRole("button", { name: "Rename", exact: true }).click();
      await smartRow.locator('input[name="title"]').fill("Renamed session");
      await smartRow
        .locator(".inline-editor:not([hidden])")
        .getByRole("button", { name: "Save", exact: true })
        .click();
      await poll(
        async () =>
          (await smartRow.locator(".session-title").textContent()).includes(
            "Renamed session",
          ),
        { timeout: 10_000, message: "renamed row" },
      );
      s = await byModel("smart");
      eq(s.title, "Renamed session", "manual title in API");
      eq(s.title_source, "manual", "manual title source");
      // ui-polish F8: the header context follows the session's title, not
      // just the alias fallback.
      await poll(
        () =>
          page
            .locator("#model")
            .evaluate((el) => el.textContent === "Renamed session"),
        { timeout: 10_000, message: "header shows the session title" },
      );

      // Tags through the inline editor render as chips.
      await revealRowControls(smartRow);
      await smartRow.getByRole("button", { name: "Tags", exact: true }).click();
      // Regression check: the open editor (input + Save + Cancel) must fit
      // inside the sidebar — the input shrinks (flex/min-width) instead of
      // pushing the buttons past the border.
      {
        const sidebarBox = await page.locator("#sidebar").boundingBox();
        const saveBox = await smartRow
          .locator(".inline-editor:not([hidden])")
          .getByRole("button", { name: "Save", exact: true })
          .boundingBox();
        assert(
          saveBox && saveBox.x + saveBox.width <= sidebarBox.x + sidebarBox.width + 1,
          `save button inside sidebar: save right ${saveBox?.x + saveBox?.width}, sidebar right ${sidebarBox.x + sidebarBox.width}`,
        );
      }
      await smartRow.locator('input[name="tags"]').fill("ops, infra");
      await smartRow
        .locator(".inline-editor:not([hidden])")
        .getByRole("button", { name: "Save", exact: true })
        .click();
      await poll(async () => (await smartRow.locator(".tag-chip").count()) === 2, {
        timeout: 10_000,
        message: "two tag chips",
      });

      // Chip click filters the list; the clear button brings rows back.
      await smartRow.locator(".tag-chip", { hasText: "ops" }).first().click();
      await poll(
        async () => {
          const n = await fastRow.count();
          return n === 0 || !(await fastRow.isVisible());
        },
        { timeout: 10_000, message: "non-matching row filtered out" },
      );
      await page.locator("#filter-clear").click();
      await poll(async () => await fastRow.isVisible(), {
        timeout: 10_000,
        message: "row back after clearing the filter",
      });

      // Pin: the row moves into the global pinned section.
      await revealRowControls(smartRow);
      await smartRow.getByRole("button", { name: "Pin", exact: true }).click();
      await poll(
        async () => {
          const pinned = page.locator(".pinned-group .session-row");
          return (
            (await pinned.count()) === 1 &&
            (await pinned.first().getAttribute("data-session-id")) === smart.id
          );
        },
        { timeout: 10_000, message: "pinned section" },
      );

      // Archive: the row soft-hides; the toggle reveals it; Restore works.
      await revealRowControls(smartRow);
      await smartRow.getByRole("button", { name: "Archive", exact: true }).click();
      await poll(
        async () => (await smartRow.count()) === 0 || !(await smartRow.isVisible()),
        { timeout: 10_000, message: "archived row hidden" },
      );
      await page.locator("#show-archived").click();
      await poll(
        async () =>
          (await page
            .locator(".archive-group .session-row")
            .first()
            .isVisible()),
        { timeout: 10_000, message: "archive group shown" },
      );
      s = await byModel("smart", "?archived=1");
      eq(s.archived, true, "archived in API");
      // Invariant: an archived session is never pinned — archiving cleared
      // the pin and the archived row carries no pin control at all.
      eq(s.pinned, false, "archiving cleared the pin in API");
      eq(
        await smartRow.getByRole("button", { name: "Pin", exact: true }).count(),
        0,
        "no pin control on archived row",
      );
      await revealRowControls(smartRow);
      await smartRow.getByRole("button", { name: "Restore", exact: true }).click();
      await poll(async () => await smartRow.locator(".session-main").isVisible(), {
        timeout: 10_000,
        message: "restored row back in the list",
      });
      // Restored sessions are active again: the pin control is back (the
      // pin itself stays cleared until re-pinned). Reveal first — the
      // restored row is neither selected nor hovered yet.
      await revealRowControls(smartRow);
      await poll(
        async () =>
          await smartRow.getByRole("button", { name: "Pin", exact: true }).isVisible(),
        { timeout: 10_000, message: "pin control back after restore" },
      );

      // Delete the fast session: two-step confirm, hard removal.
      await revealRowControls(fastRow);
      await fastRow.getByRole("button", { name: "Delete", exact: true }).click();
      await fastRow
        .getByRole("button", { name: "Delete forever", exact: true })
        .click();
      await poll(async () => (await fastRow.count()) === 0, {
        timeout: 10_000,
        message: "deleted row gone",
      });
      const after = await sessions();
      assert(!after.some((x) => x.id === fast.id), "deleted session gone from API");
      eq(after.length, 1, "only the smart session remains");
    });

    // -- 3c. utility tags: manual freeze refuses the racing apply --------
    // The organize test's first exchange armed the smart session's
    // once-per-session utility attempt; the branch request left at the
    // debounce and the fake HOLDS its reply UTILITY_REPLY_DELAY_MS, so
    // the manual rename + tags save above had already flipped both
    // provenance columns to 'manual' while the apply was still in
    // flight. Wait the held reply out: the store's both-column guard
    // (auto_meta_upgrade) must refuse the late apply — title AND tags
    // stay exactly the manual set (utility-tags plan §3.5).
    await test("utility: manual tags freeze refuses the racing model apply", async () => {
      const headers = { authorization: `Bearer ${TOKEN}` };
      // The smart session's is the suite's FIRST utility request — its
      // exchange is the first committed turn of the run (the guard and
      // ui-made sessions have not sent one yet).
      await poll(
        async () =>
          services.requests.filter(
            (r) => r.url === "/v1/chat/completions" && r.body.includes(UTILITY_DELTA),
          ).length >= 1,
        { timeout: 15_000, message: "utility branch request recorded" },
      );
      // The premise must be OBSERVED, not assumed: poll the API until
      // both manual saves are visible (the tags save is the later one)
      // and remember WHEN. That timestamp must beat the held reply's
      // completion — proving the freeze was really in place while the
      // apply was still in flight; if a run ever loses that race, fail
      // here rather than passing vacuously afterwards.
      const manualAt = await poll(
        async () => {
          const s = (
            await (await page.request.get(`${base}/sessions`, { headers })).json()
          ).sessions.find((x) => x.model === "smart");
          return s &&
            s.title_source === "manual" &&
            s.title === "Renamed session" &&
            s.tags.join(",") === "ops,infra"
            ? Date.now()
            : false;
        },
        {
          timeout: 15_000,
          message: "manual title + tags saved while the reply is held",
        },
      );
      // Outlast the held reply plus the worker's parse/apply.
      await sleep(UTILITY_REPLY_DELAY_MS + 2000);
      const reply = services.utilityTimeline[0];
      assert(reply?.completedAt, "held reply timeline recorded");
      assert(
        manualAt < reply.completedAt,
        `manual save (${manualAt}) must precede the held reply's completion ` +
          `(${reply.completedAt}) — this run did not stage the race; ` +
          `increase UTILITY_REPLY_DELAY_MS`,
      );
      const smart = (
        await (await page.request.get(`${base}/sessions`, { headers })).json()
      ).sessions.find((s) => s.model === "smart");
      eq(smart.title, "Renamed session", "manual title survived the utility apply");
      eq(smart.title_source, "manual", "title still manual");
      eq(smart.tags.join(","), "ops,infra", `manual tags survived the apply: ${smart.tags}`);
      // The sidebar agrees: exactly the two manual chips — no model tag
      // (hostile or plain) ever landed on the row.
      const row = page.locator(`.session-row[data-session-id="${smart.id}"]`);
      await poll(async () => (await row.locator(".tag-chip").count()) === 2, {
        timeout: 10_000,
        message: "exactly the two manual chips",
      });
      const chips = await row.locator(".tag-chip").allTextContents();
      assert(
        chips.includes("ops") && chips.includes("infra"),
        `manual chips only: ${chips}`,
      );
    });

    // -- 4. text-only turn ---------------------------------------------------
    await test("turn: text-only round streams and completes", async () => {
      await sendAndWaitIdle(page, "case:text just answer");
      const user = await page.$$eval(".turn.user", (els) => els.map((e) => e.textContent));
      assert(user.some((t) => t.includes("case:text")), `user bubble: ${user}`);
      const assistant = await page.$$eval(".turn.assistant", (els) => els.map((e) => e.textContent));
      assert(assistant.some((t) => t.includes("Plain answer")), `assistant text: ${assistant}`);
    });

    // -- 4b. reasoning (chain of thought) -------------------------------------
    await test("reasoning: streams live, commits collapsed, replays on reload", async () => {
      await page.fill("#input", "case:reasoning think it through");
      await page.press("#input", "Enter");
      // Live: an OPEN details block labelled "thinking…" whose body grows.
      await poll(
        async () => {
          const live = page.locator("details.turn.reasoning.live");
          if ((await live.count()) === 0) return false;
          const state = await live.last().evaluate((el) => ({
            open: el.open,
            label: el.querySelector("summary")?.textContent ?? "",
            body: el.querySelector(".reasoning-body")?.textContent ?? "",
          }));
          return (
            state.open && state.label.includes("thinking") && state.body.includes("weighing")
          );
        },
        { timeout: 30_000, interval: 100, message: "live thinking block streaming" },
      );
      await poll(() => page.locator("#send").evaluate((el) => !el.disabled), {
        timeout: 120_000,
        message: "send re-enabled after reasoning turn",
      });
      // Committed: a CLOSED block also labelled "thinking" (one label for
      // both states, F8), rendered above the assistant text it preceded.
      const committed = await page.$$eval("details.turn.reasoning", (els) =>
        els.map((e) => ({
          open: e.open,
          label: e.querySelector("summary")?.textContent ?? "",
          body: e.querySelector(".reasoning-body")?.textContent ?? "",
        })),
      );
      assert(
        committed.some(
          (b) => !b.open && b.label.includes("thinking") && b.body.includes("carefully"),
        ),
        `committed reasoning block: ${JSON.stringify(committed)}`,
      );
      // The centered conversation column (F6) is the log's single child, so
      // the turn order lives one level down. Committed reasoning is a chip
      // INSIDE a .chip-row wrapper (chips flow together since #43), so the
      // scan flattens one level into chip rows to keep the order assertion.
      const classes = await page.$$eval("#log .conversation > *", (els) =>
        els.flatMap((e) =>
          /(^| )chip-row( |$)/.test(e.className)
            ? [...e.children].map((c) => c.className)
            : [e.className],
        ),
      );
      // Within the LAST turn: its reasoning block must precede its answer.
      const reasoningAt = classes.findLastIndex((c) => /(^| )reasoning( |$)/.test(c));
      const answerAt = classes.findIndex(
        (c, i) => i > reasoningAt && /(^| )assistant( |$)/.test(c),
      );
      assert(
        reasoningAt !== -1 && answerAt !== -1 && reasoningAt < answerAt,
        `reasoning renders above the answer: ${classes}`,
      );
      // Reload: the reasoning replays from persistence, collapsed.
      await page.reload();
      await poll(
        async () =>
          (await page.locator("details.turn.reasoning:not(.live)").count()) > 0,
        { timeout: 30_000, message: "reasoning replayed after reload" },
      );
      const replayed = await page.locator("details.turn.reasoning:not(.live)").last().evaluate((el) => ({
        open: el.open,
        body: el.querySelector(".reasoning-body")?.textContent ?? "",
      }));
      assert(!replayed.open, `replayed reasoning collapsed: ${JSON.stringify(replayed)}`);
      assert(replayed.body.includes("carefully"), `replayed body: ${replayed.body}`);
    });

    // -- 5. stop during streaming ---------------------------------------------
    await test("stop: mid-stream stop commits partial text", async () => {
      await page.fill("#input", "case:slow stream slowly");
      await page.press("#input", "Enter");
      // Wait until some streamed text is visible and Stop is enabled.
      await poll(
        async () => {
          const last = page.locator(".turn.assistant").last();
          const text = (await last.count()) > 0 ? await last.evaluate((el) => el.textContent.trim()) : "";
          const stopEnabled = await page.locator("#stop").evaluate((el) => !el.disabled);
          return text.length > 0 && stopEnabled;
        },
        { timeout: 30_000, message: "streaming bubble visible with stop enabled" },
      );
      const partial = await page.locator(".turn.assistant").last().evaluate((el) => el.textContent);
      await page.click("#stop");
      await poll(() => page.locator("#send").evaluate((el) => !el.disabled), {
        timeout: 30_000,
        message: "send re-enabled after stop",
      });
      const committed = await page.$$eval(".turn.assistant", (els) => els.map((e) => e.textContent));
      assert(committed.some((t) => t.startsWith(partial.trim().slice(0, 8))), `partial committed: ${committed}`);
    });

    // -- 6. http_fetch tool loop ----------------------------------------------
    await test("tools: http_fetch card renders args, result, and status", async () => {
      await sendAndWaitIdle(
        page,
        `case:fetch fetch http://127.0.0.1:${services.docPort}/doc.json`,
      );
      const card = page.locator(".turn.tool[data-call-id]");
      await card.first().waitFor({ timeout: 30_000 });
      const info = await card.first().evaluate((el) => ({
        tool: el.getAttribute("data-tool"),
        status: el.querySelector(".tool-status").textContent,
        args: el.querySelector(".tool-args").textContent,
        result: el.querySelector(".tool-result")?.textContent ?? null,
        open: el.open,
      }));
      eq(info.tool, "http_fetch", "tool name");
      eq(info.status, "completed", "terminal status");
      // Completed cards collapse like committed reasoning blocks.
      assert(!info.open, `completed card collapsed: ${JSON.stringify(info)}`);
      assert(info.args.includes(`/doc.json`), `argument preview: ${info.args}`);
      assert(info.result.includes("nexus-e2e-doc"), `result preview: ${info.result}`);
      assert(info.result.includes("<script>alert"), "result preview shows markup as text");
      // Inertness: the document keeps exactly its two static scripts (the
      // runtime module and the connection indicator), and the component's
      // shadow root — where rendered tool output lives — has none.
      const scripts = await page.evaluate(() => ({
        document: document.querySelectorAll("script").length,
        shadow: document
          .querySelector("lustre-server-component")
          ?.shadowRoot?.querySelectorAll("script").length ?? -1,
      }));
      eq(scripts.document, 2, "static scripts only");
      eq(scripts.shadow, 0, "no scripts inside the component view");
      const finalText = await page.$$eval(".turn.assistant", (els) => els.map((e) => e.textContent));
      assert(finalText.some((t) => t.includes("Fetch complete")), `final answer: ${finalText}`);
      // Auto-follow must survive the transition this turn just exercised:
      // bubble -> tool chip -> bubble shrinks #log twice (the thinking
      // chip collapses at commit, the tool card collapses on completion),
      // and each shrink clamps scrollTop downward. A drag-detector that
      // reads that clamp as a user gesture unpins and following dies for
      // the rest of the turn.
      //
      // The distance-from-bottom check is only meaningful when #log
      // actually overflows — with a short transcript fromBottom reads ~0
      // whether or not following works (Cubic P2) — so shrink the pane
      // until it provably does, assert the overflow precondition
      // explicitly, then measure. try/finally restores the pane: the
      // test() helper swallows failures and keeps the suite running, and
      // the turn tests after this one need the full height back.
      const pane = page.viewportSize();
      await page.setViewportSize({ width: pane.width, height: 320 });
      let follow;
      try {
        await poll(
          async () => {
            follow = await page.evaluate(() => {
              const sr = document.querySelector("lustre-server-component")?.shadowRoot;
              const log = sr?.getElementById("log");
              const jump = sr?.getElementById("jump-latest");
              return {
                overflow: log ? log.scrollHeight > log.clientHeight + 1 : false,
                fromBottom: log ? log.scrollHeight - log.scrollTop - log.clientHeight : -1,
                jumpShown: jump ? !jump.hidden : null,
              };
            });
            return follow.overflow;
          },
          { timeout: 10_000, message: "#log overflows at the shrunk pane height" },
        );
        assert(follow.fromBottom < 80, `auto-follow died mid-turn: ${JSON.stringify(follow)}`);
        assert(!follow.jumpShown, `jump button surfaced mid-turn: ${JSON.stringify(follow)}`);
      } finally {
        await page.setViewportSize(pane);
      }
    });

    // -- 7. web_search tool loop -----------------------------------------------
    await test("tools: web_search card completes with stub result", async () => {
      await sendAndWaitIdle(page, "case:search look it up");
      const card = page.locator(".turn.tool[data-tool='web_search']");
      await card.first().waitFor({ timeout: 30_000 });
      await page
        .locator("details.turn.tool.done[data-tool='web_search']")
        .first()
        .waitFor({ timeout: 30_000 });
      const result = await card.first().locator(".tool-result").textContent();
      assert(result.includes("nexus-e2e stub title"), `searxng stub result: ${result}`);
    });

    // -- 8. loop chip appeared during tool turns -------------------------------
    await test("loop: iteration chip visible while streaming, hidden after", async () => {
      // Trigger another tool turn and catch the chip mid-flight.
      await page.fill("#input", "case:fetch fetch http://127.0.0.1:" + services.docPort + "/doc.json");
      await page.press("#input", "Enter");
      await poll(
        () => page.locator("#loop-status").evaluate((el) => !el.hidden),
        { timeout: 60_000, message: "loop chip visible" },
      );
      // The scripted model streams fast, so the chip may already have moved
      // past iteration 1 — assert the shape and the cap, not the exact step.
      const chip = await page.textContent("#loop-status");
      assert(/iter \d+\/8 · (request|tools)/.test(chip), `chip text: ${chip}`);
      await poll(() => page.locator("#loop-status").evaluate((el) => el.hidden), {
        timeout: 90_000,
        message: "loop chip hidden after turn",
      });
    });

    // -- 9. reconnect / replay ---------------------------------------------------
    await test("reconnect: reload replays full tool history as cards", async () => {
      await page.reload();
      await connected(page);
      await page.waitForSelector(".turn.tool[data-call-id]", { timeout: 30_000 });
      const cards = await page.$$eval(".turn.tool[data-call-id]", (els) =>
        els.map((el) => ({
          id: el.getAttribute("data-call-id"),
          tool: el.getAttribute("data-tool"),
          status: el.querySelector(".tool-status").textContent,
          hasResult: Boolean(el.querySelector(".tool-result")),
          open: el.open,
        })),
      );
      const fetchCards = cards.filter((c) => c.tool === "http_fetch");
      const searchCards = cards.filter((c) => c.tool === "web_search");
      assert(fetchCards.length === 2, `two fetch cards replayed: ${JSON.stringify(cards)}`);
      eq(searchCards.length, 1, "one search card replayed");
      assert(cards.every((c) => c.status === "completed" && c.hasResult), "all replayed cards completed with results");
      // Replay renders completed cards collapsed, like reasoning on reload.
      assert(cards.every((c) => !c.open), `replayed cards collapsed: ${JSON.stringify(cards)}`);
      assert(cards.every((c) => c.id.startsWith("call_")), "stable call ids preserved");
      // Tool events must never render as model text.
      const assistantText = await page.$$eval(".turn.assistant", (els) => els.map((e) => e.textContent));
      assert(
        assistantText.every((t) => !t.includes("call_") && !t.includes("http_fetch") && !t.includes("web_search")),
        `assistant bubbles free of tool noise: ${assistantText}`,
      );
      const userText = await page.$$eval(".turn.user", (els) => els.map((e) => e.textContent));
      assert(userText.some((t) => t.includes("case:fetch")), "user bubbles replayed");
    });

    // -- 9b. mid-turn reload (in-flight replay) ----------------------------------
    await test("mid-turn reload: finished rounds replay while the turn still runs", async () => {
      // A tool round completes and is broadcast; the final round then holds
      // the stream open (fetchslow). Reloading mid-hold used to drop every
      // already-broadcast round: the committed transcript did not hold them
      // until WorkerDone, so Join replayed nothing of the running turn.
      // This session already carries earlier tests' turns, so the new turn's
      // cards are identified positionally (the DOM renders oldest-first).
      const cardsBefore = await page.$$eval(".turn.tool[data-call-id]", (els) => els.length);
      await page.fill(
        "#input",
        `case:fetchslow fetch http://127.0.0.1:${services.docPort}/doc.json`,
      );
      await page.press("#input", "Enter");
      const myCards = () =>
        page.$$eval(".turn.tool[data-call-id]", (els, before) =>
          els
            .slice(before)
            .map((el) => ({
              status: el.querySelector(".tool-status")?.textContent,
              hasResult: Boolean(el.querySelector(".tool-result")),
            })),
        cardsBefore,
      );
      // Round 1 done: one completed fetch card, pre-reload.
      await poll(
        async () => {
          const cards = await myCards();
          return cards.length === 1 && cards[0].status === "completed";
        },
        { timeout: 30_000, interval: 100, message: "round 1 card completed" },
      );
      // Reload while the final round holds the stream open. The session
      // re-opens via the route query (page shell persistence).
      await page.reload();
      await connected(page);
      // The finished round replays from the session's in-flight mirror:
      // same single completed card, with its result attached.
      await poll(
        async () => {
          const cards = await myCards();
          return (
            cards.length === 1 && cards[0].status === "completed" && cards[0].hasResult
          );
        },
        { timeout: 30_000, interval: 100, message: "in-flight round replayed after reload" },
      );
      // The turn was NOT restarted: the held final text lands live and the
      // send re-enables when the same turn finishes.
      await poll(() => page.locator("#send").evaluate((el) => !el.disabled), {
        timeout: 60_000,
        message: "turn finished live after mid-turn reload",
      });
      const texts = await page.$$eval(".turn.assistant", (els) =>
        els.map((e) => e.textContent),
      );
      assert(
        texts.some((t) => t.includes("nexus-e2e-doc")),
        `final text streamed live: ${texts}`,
      );
    });

    // -- 10. iteration guard (max=2 instance) -------------------------------------
    await test("guard: max-iteration turn renders terminal state", async () => {
      await page.goto(`${guardBase}/?token=${TOKEN}`);
      await connected(page);
      // No session is minted at boot (the model is the user's choice), so
      // create one here — the panel auto-opens on the empty list.
      await poll(
        async () => page.locator("#create-panel").evaluate((el) => !el.hidden),
        { timeout: 15_000, message: "guard create panel open" },
      );
      await page.click("#create-session");
      await poll(
        async () => (await page.locator("#session-list .session-main").count()) === 1,
        { timeout: 15_000, message: "guard session appears" },
      );
      await sendAndWaitIdle(page, "case:loop never stop calling tools");
      // Guard terminal: chip reached guard phase, note rendered, send re-enabled.
      const note = page.locator(".note.err");
      await note.first().waitFor({ timeout: 90_000 });
      const noteText = await note.first().textContent();
      assert(
        noteText.includes("iteration guard: reached max 2 model round-trips"),
        `guard note: ${noteText}`,
      );
      const cards = await page.$$eval(".turn.tool[data-call-id]", (els) => els.map((el) => ({
        status: el.querySelector(".tool-status").textContent,
      })));
      assert(cards.length >= 1 && cards.every((c) => c.status === "completed"), `completed rounds kept: ${JSON.stringify(cards)}`);
      const chipHidden = await page.locator("#loop-status").evaluate((el) => el.hidden);
      eq(chipHidden, true, "chip hidden after terminal failure");
    });

    // -- 11. byte-identical prefixes (controlled evidence) -------------------------
    await test("prefix: recorded request bodies grow by suffix only", async () => {
      const chats = services.requests.filter((r) => r.url === "/v1/chat/completions");
      assert(chats.length >= 8, `recorded chat requests: ${chats.length}`);
      // Keep raw evidence for the verification report.
      writeFileSync(
        new URL("./requests.json", import.meta.url),
        JSON.stringify(chats.map((c) => c.body), null, 2),
      );
      // Utility-title branches (utility-titles plan §4.1) reuse the
      // session's frozen envelope plus exactly the UTILITY_DELTA above, so
      // they are not suffix-growths of the chat chain; they are judged by
      // their own contract after the chain scan, not lumped into it.
      const isUtility = (chat) => chat.body.includes(UTILITY_DELTA);
      const turnChats = chats.filter((c) => !isUtility(c));
      // Requests from the two nexus instances interleave in one log; a
      // request that does not extend the previous one starts a new chain
      // (one chain per session). Every chain must grow by suffix only.
      const chains = [];
      for (const chat of turnChats) {
        const last = chains[chains.length - 1];
        if (last && extendsRequest(last[last.length - 1].body, chat.body)) {
          last.push(chat);
        } else {
          chains.push([chat]);
        }
      }
      eq(chains.length, 2, `session chains (main + guard): ${chains.map((c) => c.length)}`);
      for (const [i, chain] of chains.entries()) {
        assert(chain.length >= 2, `chain ${i} too short: ${chain.length}`);
        for (let j = 1; j < chain.length; j++) {
          assert(
            extendsRequest(chain[j - 1].body, chain[j].body),
            `chain ${i}: request ${j} does not extend ${j - 1} by suffix`,
          );
        }
      }
      // Each utility branch must extend its session's committed transcript
      // byte-for-byte (the branch point is the last committed turn), and
      // its envelope must be the frozen one with exactly the documented
      // delta at exactly the documented spot — no other byte may move.
      for (const utility of chats.filter(isUtility)) {
        const branchBase = [...chats.slice(0, chats.indexOf(utility))]
          .reverse()
          .find((c) => !isUtility(c));
        assert(branchBase, "utility branch has a preceding chat request");
        const base = bodyParts(branchBase.body);
        const next = bodyParts(utility.body);
        assert(
          next.messages.startsWith(base.messages.slice(0, -1)),
          "utility branch extends the committed transcript prefix",
        );
        assert(
          next.envelope ===
            base.envelope.replace(
              ',"stream":true',
              `,"stream":true${UTILITY_DELTA}`,
            ),
          "utility envelope differs by exactly the max_completion_tokens delta",
        );
      }
    });

    // -- 12. mobile viewport + per-client runtimes -----------------------------
    // Since the per-client runtime break every /ws connection owns its
    // model: a second context gets a fresh runtime (its own auto-selection
    // and Hello replay, never an inherited view), panels no longer mirror
    // between contexts, and a reload re-opens the context's own
    // last-selected session (persisted client-side, re-supplied on the
    // /ws route). A second session created in the mobile context makes
    // the divergence real: the two contexts hold DIFFERENT selections at
    // the same time, which a shared runtime could never show. The mobile
    // overflow check stays.
    await test("mobile: independent per-client view, no overflow with cards", async () => {
      const desktop = await browser.newContext({ viewport: { width: 1280, height: 900 } });
      const dpage = await desktop.newPage();
      track(dpage);
      await dpage.goto(`${base}/?token=${TOKEN}`);
      await connected(dpage);
      await dpage.waitForSelector("#session-list .session-main", { timeout: 30_000 });

      const mobile = await browser.newContext({ viewport: { width: 390, height: 844 } });
      const mpage = await mobile.newPage();
      track(mpage);
      await mpage.goto(`${base}/?token=${TOKEN}`);
      await connected(mpage);
      // Fresh runtime, fresh model: the session re-opens through this
      // connection's own auto-selection and Hello replay, not an
      // inherited view (the shared runtime used to mirror the first
      // context's state into every later context).
      await mpage.waitForSelector(".turn.tool[data-call-id]", { timeout: 30_000 });
      const first = await selectedId(mpage);
      assert(first, "mobile context has its own selection");
      eq(
        await selectedId(dpage),
        first,
        "fresh context auto-selects like any fresh model",
      );

      // Panels are per-client: opening the create panel on mobile must
      // not open it on the desktop context.
      await mpage.click("#new-session");
      await poll(
        async () => await mpage.locator("#create-panel").evaluate((el) => !el.hidden),
        { timeout: 15_000, message: "mobile create panel open" },
      );
      eq(
        await dpage.locator("#create-panel").evaluate((el) => el.hidden),
        true,
        "desktop create panel stays closed",
      );

      const overflow = await mpage.evaluate(() => ({
        scrollWidth: document.documentElement.scrollWidth,
        innerWidth: window.innerWidth,
      }));
      assert(overflow.scrollWidth <= overflow.innerWidth + 1, `overflow: ${JSON.stringify(overflow)}`);

      // ui-polish F3(a): stacked, the sidebar is capped so the transcript
      // keeps the rest of the viewport — without the cap three sessions
      // pushed #chat into a ~100px sliver clipped under the composer.
      const mobileBox = await mpage.evaluate(() => {
        const sr = document.querySelector("lustre-server-component")?.shadowRoot;
        const rect = (el) => (el ? el.getBoundingClientRect() : null);
        const aside = rect(sr?.getElementById("sidebar"));
        const chat = rect(sr?.getElementById("chat"));
        const composer = rect(sr?.getElementById("composer"));
        return {
          asideHeight: aside?.height,
          asideBottom: aside?.bottom,
          innerHeight: window.innerHeight,
          chatTop: chat?.top,
          chatBottom: chat?.bottom,
          composerBottom: composer?.bottom,
        };
      });
      // The cap is on the aside's HEIGHT, not its bottom: the header sits
      // above it, so `bottom` runs past 40dvh even when the cap holds.
      assert(
        mobileBox.asideHeight <= mobileBox.innerHeight * 0.4 + 1,
        `sidebar exceeds its 40dvh cap: ${JSON.stringify(mobileBox)}`,
      );
      assert(
        mobileBox.chatTop >= mobileBox.asideBottom - 1 &&
          mobileBox.composerBottom <= mobileBox.innerHeight + 1,
        `transcript is crushed or the composer is off-screen: ${JSON.stringify(mobileBox)}`,
      );

      // ui-polish F4: the create panel opens ABOVE the session list, so it
      // lands on screen — previously it opened below the fold, which is what
      // made the create flow unusable on a phone. The panel is already open
      // here (the per-client check above), so measure it as-is and only
      // toggle it open if that changed.
      const panelVisible = await mpage
        .locator("#create-panel")
        .evaluate((el) => !el.hidden)
        .catch(() => false);
      if (!panelVisible) {
        await mpage.click("#new-session");
        await poll(
          async () => await mpage.locator("#create-panel").evaluate((el) => !el.hidden),
          { timeout: 15_000, message: "create panel open before measuring" },
        );
      }
      const panelBox = await mpage.locator("#create-panel").evaluate((el) => {
        const r = el.getBoundingClientRect();
        return { top: r.top, bottom: r.bottom, height: window.innerHeight };
      });
      assert(
        panelBox.top >= 0 && panelBox.bottom <= panelBox.height,
        `create panel opens off-screen: ${JSON.stringify(panelBox)}`,
      );

      // Desktop height clamp: a transcript must scroll inside #log, never
      // grow the document. The #layout grid needs its explicit
      // `grid-template-rows: minmax(0,1fr)` — without it the implicit auto
      // row sizes to #chat's content, the page scrollbar appears, and the
      // auto-follow script has nothing to scroll (the mobile breakpoint
      // always had explicit rows, which is why this only bit desktop).
      // The transcript must be long enough that #log genuinely overflows,
      // so wait for the replayed history before measuring.
      await dpage.waitForSelector(".turn.tool[data-call-id]", { timeout: 30_000 });
      const dOverflow = await dpage.evaluate(() => {
        const sr = document.querySelector("lustre-server-component")?.shadowRoot;
        const layout = sr?.getElementById("layout");
        const log = sr?.getElementById("log");
        return {
          docScrollHeight: document.documentElement.scrollHeight,
          innerHeight: window.innerHeight,
          layoutScrollH: layout?.scrollHeight,
          layoutClientH: layout?.clientHeight,
          logScrolls: log ? log.scrollHeight > log.clientHeight + 1 : false,
          logScrollH: log?.scrollHeight,
          logClientH: log?.clientHeight,
        };
      });
      assert(
        dOverflow.logScrolls,
        `#log does not scroll internally with a long transcript: ${JSON.stringify(dOverflow)}`,
      );
      assert(
        dOverflow.docScrollHeight <= dOverflow.innerHeight + 1,
        `desktop page grows instead of #log scrolling: ${JSON.stringify(dOverflow)}`,
      );
      assert(
        dOverflow.layoutScrollH <= dOverflow.layoutClientH + 1,
        `#layout row is content-sized (missing grid-template-rows): ${JSON.stringify(dOverflow)}`,
      );

      // ui-polish F6: the log's children live in one centered column, so a
      // wide pane no longer pins user and assistant bubbles to opposite
      // edges. Assert the geometry, not just the class: the column must be
      // narrower than the pane AND horizontally centered inside it.
      const column = await dpage.evaluate(() => {
        const sr = document.querySelector("lustre-server-component")?.shadowRoot;
        const log = sr?.getElementById("log");
        const col = sr?.querySelector("#log > .conversation");
        const jump = sr?.getElementById("jump-latest");
        if (!log || !col || !jump) return null;
        const l = log.getBoundingClientRect();
        const c = col.getBoundingClientRect();
        return {
          paneWidth: l.width,
          colWidth: c.width,
          leftGap: c.left - l.left,
          rightGap: l.right - c.right,
          // The jump button is hidden until the autoscroll script unpins,
          // so measure its ANCHORING structurally instead of geometrically:
          // it must sit in `#log-wrap` (the positioned ancestor), never
          // inside the column, or it would drift with the column's width.
          jumpParent: jump.parentElement?.id ?? "",
          wrapPosition: getComputedStyle(jump.parentElement).position,
          colPosition: getComputedStyle(col).position,
        };
      });
      assert(column, "#log renders the centered .conversation column");
      assert(
        column.colWidth < column.paneWidth - 1,
        `column fills the pane, so turns stay edge-pinned: ${JSON.stringify(column)}`,
      );
      assert(
        Math.abs(column.leftGap - column.rightGap) <= 1,
        `column is not centered: ${JSON.stringify(column)}`,
      );
      assert(
        column.jumpParent === "log-wrap" && column.wrapPosition === "relative",
        `jump-to-latest is not anchored to the pane: ${JSON.stringify(column)}`,
      );
      assert(
        column.colPosition === "static",
        `column became a containing block for the jump button: ${JSON.stringify(column)}`,
      );

      // Diverge the contexts for real: create a second session in the
      // mobile context (its model learns it; the desktop context's model
      // never does), so mobile holds the new session while desktop keeps
      // the original — two live connections, two different selections.
      await mpage.selectOption("#model-picker", "fast");
      await mpage.click("#create-session");
      await poll(
        async () => (await mpage.locator("#session-list .session-main").count()) === 2,
        { timeout: 15_000, message: "second session appears on mobile" },
      );
      const second = await selectedId(mpage);
      assert(second && second !== first, `mobile moved to its new session: ${second} vs ${first}`);
      eq(
        await selectedId(dpage),
        first,
        "desktop keeps its own selection while mobile diverges",
      );
      eq(
        await dpage.locator("#session-list .session-main").count(),
        1,
        "desktop model never sees the other context's session",
      );

      // Reload: the context's own last-selected session (the second one —
      // not the auto-selected first) comes back through the client-
      // supplied route parameter, and the opened panel — per-connection
      // state — does not survive.
      await mpage.reload();
      await connected(mpage);
      await poll(
        async () => (await selectedId(mpage)) === second,
        { timeout: 15_000, message: "reload restores the diverged selection" },
      );
      eq(
        await mpage.locator("#create-panel").evaluate((el) => el.hidden),
        true,
        "panel state does not survive a reload",
      );
      eq(
        await selectedId(dpage),
        first,
        "desktop selection untouched by the mobile reload",
      );

      // Touch devices and sidebar density (ui-polish F2): the hover half
      // of the reveal must be off, so the selected row is the reachable
      // case. A dedicated hasTouch context rather than reusing this one,
      // so the per-client assertions above stay pointer-only.
      const touch = await browser.newContext({
        viewport: { width: 390, height: 844 },
        hasTouch: true,
        isMobile: true,
      });
      const tpage = await touch.newPage();
      track(tpage);
      await tpage.goto(`${base}/?token=${TOKEN}`);
      await connected(tpage);
      await tpage.waitForSelector(".session-row", { timeout: 15_000 });
      const touchState = await tpage.evaluate(() => {
        const sr = document
          .querySelector("lustre-server-component")
          ?.shadowRoot;
        const rows = [...sr.querySelectorAll(".session-row")];
        return {
          hoverHover: matchMedia("(hover: hover)").matches,
          rows: rows.map((r) => ({
            selected: r.classList.contains("selected"),
            shown:
              getComputedStyle(r.querySelector(".row-controls")).display !==
              "none",
          })),
        };
      });
      eq(
        touchState.hoverHover,
        false,
        "touch context reports no hover capability",
      );
      assert(
        touchState.rows.some((r) => r.selected && r.shown),
        "the selected row shows its controls on touch",
      );
      assert(
        !touchState.rows.some((r) => !r.selected && r.shown),
        "an unselected row keeps its controls hidden on touch",
      );
      // And a tap selects: the row you are in is the row you can act on.
      const untapped = tpage
        .locator(".session-row:not(.selected) .session-main")
        .first();
      if (await untapped.count()) {
        await untapped.tap();
        await poll(
          async () =>
            await tpage
              .locator(".session-row.selected .row-controls")
              .first()
              .isVisible(),
          { timeout: 10_000, message: "tap selects and reveals the controls" },
        );
      }
      await touch.close();

      // Leave one session behind, as the suite found it: later tests
      // count rows and chat-request chains.
      await mpage.request.delete(`${base}/sessions/${second}`, {
        headers: { authorization: `Bearer ${TOKEN}` },
      });
      await desktop.close();
      await mobile.close();
    });

    // -- 11. connection indicator ----------------------------------------------
    await test("indicator: dot goes red when the backend dies, green on reconnect", async () => {
      // The dot is server-rendered, so a dead backend can never push the
      // "off" view; the page must flip it from the client runtime's own
      // lustre:close event. Uses the guard instance (done with its turn).
      const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 } });
      const ipage = await ctx.newPage();
      track(ipage);
      await ipage.goto(`${guardBase}/?token=${TOKEN}`);
      await connected(ipage);

      await guard.stop();
      await ipage.waitForSelector("#status.off", { timeout: 15_000 });
      eq(
        await ipage.locator("#status").evaluate((el) => el.textContent),
        "○",
        "dot glyph while offline",
      );
      // ui-polish F8: the label is the dot's text twin and flips with it.
      eq(
        await ipage.locator("#status-label").evaluate((el) => el.textContent),
        "offline",
        "connection label while offline",
      );

      guard = startNexus({ port: guardPort, maxToolIterations: 2, ...pick(services) });
      await waitHealthy(guardPort);
      // The client runtime auto-reconnects (500ms backoff) and remounts the
      // server view, whose dot renders live again.
      await connected(ipage);
      eq(
        await ipage.locator("#status").evaluate((el) => el.textContent),
        "●",
        "dot glyph after reconnect",
      );
      eq(
        await ipage.locator("#status-label").evaluate((el) => el.textContent),
        "connected",
        "connection label after reconnect",
      );
      await ctx.close();
    });

    // -- 13. provider management + provider→model picker (P5) ---------------
    // The P5 acceptance, end to end through the real UI — now inside the
    // Settings view (the header button swaps the main area; provider
    // management moved off the sidebar): create a provider in Settings,
    // test the seeded provider's connection (live model aliases), pick
    // it in the create panel (model aliases reload per provider), create
    // a session pinned to it, and stream a turn. Then the guard rails:
    // the delete is refused while the new session pins the provider, and
    // disable/enable flip the picker.
    await test("providers: create in UI, pick, pin a session, stream a turn", async () => {
      // Back on the MAIN instance: test 10 navigated `page` to the guard
      // instance, and the indicator test used its own context.
      await page.goto(`${base}/?token=${TOKEN}`);
      await connected(page);
      const fakeUrl = `http://127.0.0.1:${services.bifrostPort}/v1`;

      // Provider management lives in the Settings view now — open it.
      await openSettings(page);

      // The page lists the seeded keyless provider.
      await poll(
        async () => (await page.locator("#providers-panel .provider-row").count()) === 1,
        { timeout: 15_000, message: "seeded provider row" },
      );
      const seededRow = page.locator(".provider-row").first();
      assert(
        (await seededRow.locator(".provider-sub").textContent()) === fakeUrl,
        "seeded provider base url",
      );
      assert((await seededRow.locator(".badge").textContent()) === "keyless", "keyless badge");

      // F7 restyle geometry (which the offline suite cannot see): the
      // settings section is a centered column (the F6 shape) and provider
      // rows render as bordered cards.
      {
        const pane = await page.locator("#settings-page").boundingBox();
        const section = await page.locator("#providers-panel").boundingBox();
        assert(
          section.width < pane.width - 100,
          `settings column narrower than pane: ${section.width} vs ${pane.width}`,
        );
        const delta = Math.abs(
          section.x + section.width / 2 - (pane.x + pane.width / 2),
        );
        assert(delta < 2, `settings column centered: delta ${delta}px`);
        const border = await seededRow.evaluate(
          (el) =>
            `${getComputedStyle(el).borderTopStyle} ${getComputedStyle(el).borderTopWidth}`,
        );
        eq(border, "solid 1px", "provider row renders as a bordered card");
      }

      // The Test control fetches the provider's live model list on
      // demand and renders the fake gateway's aliases.
      await seededRow.getByRole("button", { name: "Test", exact: true }).click();
      await poll(
        async () =>
          (await seededRow.locator(".models-status.ok").textContent())
            ?.includes("smart")
          && (await seededRow.locator(".models-status.ok").textContent())
            ?.includes("fast"),
        { timeout: 15_000, message: "test button lists model aliases" },
      );

      // Add a second keyless provider through the UI form.
      await page.click("#add-provider");
      await page.fill('#add-provider-form input[name="name"]', "ui-made");
      await page.fill('#add-provider-form input[name="base_url"]', fakeUrl);
      await page.locator('#add-provider-form button[type="submit"]').click();
      const madeRow = page.locator('.provider-row[data-provider-id]', { hasText: "ui-made" }).first();
      await poll(async () => await madeRow.isVisible(), {
        timeout: 15_000,
        message: "created provider row appears",
      });
      const madeId = await madeRow.getAttribute("data-provider-id");
      // The API agrees: masked metadata, keyless, never a key.
      const providers = await (
        await page.request.get(`${base}/providers`, { headers: { authorization: `Bearer ${TOKEN}` } })
      ).json();
      const made = providers.providers.find((p) => p.id === madeId);
      eq(made.name, "ui-made", "created provider in API");
      eq(made.has_key, false, "created provider keyless in API");
      eq(made.base_url, fakeUrl, "created provider url in API");

      // Back to chat for the create-panel flow: pick it in the create
      // panel, the model aliases reload scoped to the selection, and the
      // session pins (provider, model).
      await backToChat(page);
      const sessionsBefore = await page.locator("#session-list .session-main").count();
      const panelOpen = () =>
        page.locator("#create-panel").evaluate((el) => !el.hidden);
      if (!(await panelOpen().catch(() => false))) {
        await page.click("#new-session");
      }
      await poll(panelOpen, { timeout: 10_000, message: "create panel open" });
      await poll(
        async () => (await page.locator("#provider-picker option").count()) === 2,
        { timeout: 15_000, message: "both providers in picker" },
      );
      await page.selectOption("#provider-picker", madeId);
      await poll(
        async () => (await page.locator("#model-picker option").count()) >= 2,
        { timeout: 15_000, message: "aliases reloaded for the picked provider" },
      );
      await page.selectOption("#model-picker", "smart");
      await page.click("#create-session");
      await poll(
        async () => (await page.locator("#session-list .session-main").count()) === sessionsBefore + 1,
        { timeout: 15_000, message: "pinned session appears" },
      );
      // The row subtitle names the pinned provider (provider/model · age).
      const madeSessionRow = page
        .locator("#session-list .session-main", { hasText: "ui-made/smart ·" })
        .first();
      await poll(async () => await madeSessionRow.isVisible(), {
        timeout: 10_000,
        message: "session subtitle pins provider/model",
      });

      // Stream a turn end-to-end through the new provider.
      await sendAndWaitIdle(page, "case:text provider ui round");
      const assistant = await page.$$eval(".turn.assistant", (els) => els.map((e) => e.textContent));
      assert(assistant.some((t) => t.includes("Plain answer")), `assistant turn via ui-made: ${assistant}`);

      // Guard rail: deleting a provider its session pins is refused (the
      // 409 semantics) — the refusal note lands in the chat log, so the
      // row-survival is asserted in Settings and the note back in chat.
      await openSettings(page);
      await madeRow.getByRole("button", { name: "Delete", exact: true }).click();
      await madeRow.getByRole("button", { name: "Delete forever", exact: true }).click();
      await poll(async () => await madeRow.isVisible(), {
        timeout: 10_000,
        message: "pinned provider row survives refused delete",
      });
      // The refusal is ALSO visible right where the action happened:
      // the settings page renders the mutation error inline.
      await poll(
        async () =>
          (await page.locator(".settings-error").textContent())
            ?.includes("provider is still pinned by sessions"),
        { timeout: 15_000, message: "409 guard error visible in settings" },
      );
      await backToChat(page);
      await poll(
        async () =>
          (await page.locator(".note.err").last().textContent())
            ?.includes("provider is still pinned by sessions"),
        { timeout: 15_000, message: "409 guard note after pinned delete" },
      );

      // Disable: the row badges as disabled (in Settings) and the picker
      // drops it (back in chat).
      await openSettings(page);
      await madeRow.getByRole("button", { name: "Disable", exact: true }).click();
      await poll(
        async () => (await madeRow.locator(".badge.off").textContent()) === "disabled",
        { timeout: 15_000, message: "disabled badge" },
      );
      await backToChat(page);
      await poll(
        async () => (await page.locator("#provider-picker option").count()) === 1,
        { timeout: 15_000, message: "picker drops disabled provider" },
      );
      // Disabling blocks new resolutions, not the already-frozen session
      // endpoint — the pinned session keeps streaming either way.
      await openSettings(page);
      await madeRow.getByRole("button", { name: "Enable", exact: true }).click();
      await poll(
        async () => (await madeRow.locator(".badge").count()) === 1,
        { timeout: 15_000, message: "re-enabled provider badge restored" },
      );
      await backToChat(page);
      await poll(
        async () => (await page.locator("#provider-picker option").count()) === 2,
        { timeout: 15_000, message: "re-enabled provider back in picker" },
      );
    });

    // -- 18. utility tags: model title + tags land as inert chips --------
    // The ui-made session's first exchange (providers test, above) armed
    // its utility attempt, and nothing manual ever touched that row, so
    // the two-line reply applies through the open auto path: line 1
    // upgrades the title, line 2 lands as tag chips — including a
    // <script> payload tag, which must render as an inert TEXT node
    // (hostile-text contract; utility-tags plan §3.8). The parser
    // normalizes to kebab-case, truncates each tag at 24 chars, and
    // keeps at most 2 corpus-absent tags (the K cap — every existing
    // tag here is a singleton below the corpus frequency floor), so the
    // landing set is exactly the truncated script payload plus "login".
    await test("utility: model title and tags land as inert chips", async () => {
      const headers = { authorization: `Bearer ${TOKEN}` };
      const tagged = await poll(
        async () => {
          const sessions = (
            await (await page.request.get(`${base}/sessions`, { headers })).json()
          ).sessions;
          return sessions.find((s) => s.title === "Fix login redirect loop") ?? false;
        },
        { timeout: 30_000, message: "utility title applied" },
      );
      eq(tagged.title_source, "auto", "model title applied through the auto path");
      eq(
        JSON.stringify(tagged.tags),
        JSON.stringify(["<script>alert('utility-t", "login"]),
        `model tags landed: ${tagged.tags}`,
      );
      // Chips render as text nodes: textContent carries the payload
      // verbatim, innerHTML carries it ESCAPED (no markup was parsed),
      // and no script element exists anywhere inside the component's
      // shadow root — where rendered model output lives.
      const row = page.locator(`.session-row[data-session-id="${tagged.id}"]`);
      await poll(async () => (await row.locator(".tag-chip").count()) === 2, {
        timeout: 10_000,
        message: "model tag chips in sidebar",
      });
      const chips = await row.locator(".tag-chip").evaluateAll((els) =>
        els.map((el) => ({ text: el.textContent, html: el.innerHTML })),
      );
      eq(chips[0].text, "<script>alert('utility-t", "hostile tag rendered as text");
      assert(
        chips[0].html.includes("&lt;script&gt;"),
        `hostile tag escaped in innerHTML: ${chips[0].html}`,
      );
      eq(chips[1].text, "login", "plain tag chip");
      const shadowScripts = await page.evaluate(
        () =>
          document
            .querySelector("lustre-server-component")
            ?.shadowRoot?.querySelectorAll("script").length ?? -1,
      );
      eq(shadowScripts, 0, "no script elements inside the component view");
    });

    // -- 19. no uncaught page errors ----------------------------------------
    // Guards the shell scripts (and the runtime wiring) as a whole: any
    // uncaught exception on any page the suite opened fails the run — a
    // dead script otherwise sails through with green per-behavior tests.
    await test("page: no uncaught browser errors", async () => {
      eq(pageErrors.length, 0, `pageerrors: ${pageErrors.join(" | ")}`);
    });
  } catch (err) {
    console.error("fatal:", err);
    exitCode = 1;
  } finally {
    writeFileSync(
      new URL("./report.json", import.meta.url),
      JSON.stringify({ results, summary: summarize() }, null, 2),
    );
    if (browser) await browser.close().catch(() => {});
    if (page) await page.close().catch(() => {});
    await main.stop();
    await guard.stop();
    await services.close();
    const summary = summarize();
    console.log(`\n${summary.passed} passed, ${summary.failed} failed`);
    if (summary.failed > 0) {
      console.log("nexus log tail:\n" + main.log().split("\n").slice(-30).join("\n"));
      exitCode = 1;
    }
    process.exit(exitCode);
  }

  function summarize() {
    const passed = results.filter((r) => r.status === "pass").length;
    const failed = results.length - passed;
    return { passed, failed };
  }
}

function pick(services) {
  return {
    bifrostPort: services.bifrostPort,
    searxPort: services.searxPort,
  };
}

main();
