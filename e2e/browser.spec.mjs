// e2e browser suite.
//
// Drives headless Chromium (Playwright) against a real Nexus server whose
// model backend is the controlled fake Bifrost (see services.mjs) and whose
// tools run against the controlled doc/searxng stubs. Verifies the complete
// tool-loop flow end-to-end through the real WebSocket UI:
//
//   1. bearer auth (401 without token, page with token)
//   2. model list (picker) and thread list
//   3. create / switch threads
//   4. text-only turn (streaming → completed)
//   5. stop during streaming (partial commit)
//   6. reconnect/replay: full tool history re-rendered after reload
//   7. http_fetch + web_search loops with typed tool cards
//   8. iteration-guard terminal rendering (max=2 instance)
//   9. byte-identical request prefixes turn-over-turn (fake records them)
//  10. mobile viewport: a second context gets an independent per-client
//      runtime (own selection, non-mirroring panels, reload restores its
//      own thread) with no horizontal overflow with tool cards
//  11. connection dot: red while the backend is down, green on reconnect
//  12. provider management end-to-end (multi-provider P5, in the
//      Settings view): create a provider in Settings, test its
//      connection (live model aliases), pin a thread to it THROUGH A
//      BOT (the only create shape), stream a turn, and hit the
//      delete/disable guard rails
//  13. utility branch (utility-titles §4.1 / utility-tags §3.1): the
//      model's two-line reply (line 1 title, line 2 tags) lands through
//      the auto path as sidebar chips — inert text nodes, <script>
//      payloads included — while a manual tags save freezes the set so
//      the racing model apply is refused by the both-provenance guard
//  14. bots (bots plan P1): create a bot in Settings (provider +
//      model + prompt template), start a thread FROM it at the
//      composer (type the draft, pick the bot, send — the send creates
//      the thread; the row subtitle leads with the bot name), and
//      delete the bot — the thread keeps its frozen pin and the
//      provenance name falls away
//
// Usage: node e2e/browser.spec.mjs   (see e2e/README.md)

import { spawn } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { chromium } from "playwright";
import { pgEnvFromUrl, resetDatabase as resetDb } from "./lib.mjs";
import { startServices, UTILITY_REPLY_DELAY_MS } from "./services.mjs";

const ROOT = new URL("..", import.meta.url).pathname;
const TOKEN = "e2e-token";
// The main instance's address — module-level so shared rig helpers (relayRig)
// reach it without threading a parameter (the guard instance uses its own).
const base = "http://127.0.0.1:18081";
const results = [];
let current = null;
// Hoisted so failure diagnostics (dumpPageState) can reach the live page.
let page = null;

// When organize's manual tags save landed (wall clock). The freeze test
// below needs the REAL save moment to prove it beat the held utility
// reply — observing it from that test instead would measure everything
// organize does in between (pin, archive, restore polls), not the save.
let manualSavedAt = 0;
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
        pickerOptions: sr?.querySelectorAll("#bot-picker option").length ?? -1,
        userTurns: sr?.querySelectorAll(".turn.user").length ?? -1,
        toolCards: sr?.querySelectorAll(".turn.tool").length ?? -1,
      };
    })
    .catch((e) => ({ error: String(e).slice(0, 100) }));
  const locatorCounts = {
    pickerOptions: await page.locator("#bot-picker option").count(),
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

/// The shared bot-channel rig (the relay smoke and the pane smoke):
/// two bots named `<prefix>Alpha`/`<prefix>Beta`, a parent thread FROM
/// Alpha, the `case:relay` send, and the channel discovered through
/// Alpha's committed receipt in the state dump (channels are absent
/// from `/threads` — the debug side channel is the scripting API),
/// polled until Beta's turn settles (message_count 3: system + authored
/// line + assistant answer). Returns the ids and a cleanup that deletes
/// CHILDREN FIRST — deleting a parent cascades its channel subtree (the
/// bot-channels Phase 1 FK + the transitive registry cleanup, by
/// design), so a channel deleted after its parent would 404. Cleanup
/// asserts every delete so a leak fails loudly; call it in a `finally`.
async function relayRig(prefix, note) {
  const headers = {
    authorization: `Bearer ${TOKEN}`,
    "content-type": "application/json",
  };
  const made = { bots: [], threads: [] };
  const mkBot = async (name) => {
    const res = await page.request.post(`${base}/bots`, {
      data: {
        name,
        provider: "fake",
        model: "smart",
        description: `${name} relay smoke`,
      },
      headers,
    });
    eq(res.status(), 201, `bot ${name} created`);
    const id = (await res.json()).id;
    made.bots.push(id);
    return id;
  };
  const cleanup = async () => {
    // CHILDREN FIRST (the reversed list): a parent delete would cascade
    // its channel silently — this way the channel's own 204 is asserted.
    for (const id of [...made.threads].reverse()) {
      eq(
        (await page.request.delete(`${base}/threads/${id}`, { headers })).status(),
        204,
        `thread ${id} deleted`,
      );
    }
    for (const id of made.bots) {
      eq(
        (await page.request.delete(`${base}/bots/${id}`, { headers })).status(),
        204,
        `bot ${id} deleted`,
      );
    }
  };

  // The rig owns its own failure cleanup, and BOTH bot creations live
  // inside the protected block: a failed Beta create must not leak the
  // already-created Alpha bot into the shared world of later tests
  // (the caller's try/finally covers only the caller's own body).
  try {
    const alphaId = await mkBot(`${prefix}Alpha`);
    const betaId = await mkBot(`${prefix}Beta`);
    // A thread FROM Alpha (the shared orchestration re-validates the
    // alias against the fake gateway's live list).
    const created = await page.request.post(`${base}/threads`, {
      data: { bot: alphaId },
      headers,
    });
    eq(created.status(), 201, "thread from bot created");
    const alphaThread = (await created.json()).id;
    made.threads.push(alphaThread);

    // Relay: the scripted scenario emits bot_message(to: "<prefix>Beta",
    // text: the note) — the target is everything before the `|`, so names
    // with spaces stay addressable — then answers after the receipt.
    const sent = await page.request.post(`${base}/threads/${alphaThread}/send`, {
      data: { text: `case:relay ${prefix}Beta|${note}` },
      headers,
    });
    eq(sent.status(), 202, "send accepted");

    const betaThread = await poll(
      async () => {
        const state = await (
          await page.request.get(`${base}/threads/${alphaThread}/state`, { headers })
        ).json();
        const receipt = (state.messages ?? []).find(
          (m) =>
            m.role === "tool" &&
            String(m.content).includes(`delivered to ${prefix}Beta in thread`),
        );
        return /thread (s\d+)/.exec(receipt?.content ?? "")?.[1] ?? null;
      },
      { timeout: 30_000, interval: 500, message: "delivery receipt lands" },
    );
    const settled = await poll(
      async () => {
        const state = await (
          await page.request.get(`${base}/threads/${betaThread}/state`, { headers })
        ).json();
        return state.status?.streaming === false &&
          (state.status?.message_count ?? 0) >= 3
          ? state
          : null;
      },
      { timeout: 30_000, interval: 500, message: "Beta DM turn completes" },
    );
    // The channel joins cleanup BEFORE the parent: the reversed delete
    // asserts its own 204 (a parent delete would cascade it silently).
    made.threads.push(betaThread);

    return { betaId, alphaThread, betaThread, settled, note, cleanup };
  } catch (err) {
    await cleanup();
    throw err;
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
/// reruns and interleaved integration runs must not leave threads
/// (breaking the empty-list assertions) or extra providers (the create
/// panel auto-targets the FIRST enabled provider by name, and e.g. an
/// integration run's "bifrost" would sort before this suite's "fake").
/// Requires `psql` next to the (already mandatory) Postgres.
const resetDatabase = () => resetDb(DATABASE_URL);

/// A bot over the API, uniquely named (bot names are case-insensitively
/// unique). Keyless "fake" provider, the given model alias. Returns the
/// bot id.
// `origin` defaults to the main instance; pass another instance's base
// (e.g. guardBase) when the bot must exist in THAT instance's in-memory
// bot registry — registries are boot-loaded per server and never sync.
async function createBot(model, nameHint = "e2e-bot", origin = base) {
  const headers = { authorization: `Bearer ${TOKEN}`, "content-type": "application/json" };
  const res = await page.request.post(`${origin}/bots`, {
    data: {
      name: `${nameHint}-${Date.now()}-${Math.floor(Math.random() * 1e6)}`,
      provider: "fake",
      model,
    },
    headers,
  });
  // The body names the refused registry ("provider/bot registry
  // unavailable") — a bare status code can't tell a wedged bot registry
  // from a provider lookup failure.
  const body = res.status() === 201 ? "" : ` — ${(await res.text()).slice(0, 300)}`;
  eq(res.status(), 201, `bot created (POST ${origin}/bots)${body}`);
  return (await res.json()).id;
}

/// A thread born the only way threads are born now — from a bot. Makes
/// the bot (see createBot), then POSTs the thread. Returns
/// `{ botId, thread }` for cleanup and identity assertions.
async function createBotThread(model, nameHint = "e2e-bot") {
  const headers = { authorization: `Bearer ${TOKEN}`, "content-type": "application/json" };
  const botId = await createBot(model, nameHint);
  const res = await page.request.post(`${base}/threads`, {
    data: { bot: botId },
    headers,
  });
  eq(res.status(), 201, "thread from bot created");
  return { botId, thread: await res.json() };
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
    // A NEXUS_SEED_PROVIDER_API_KEY in the CALLER's shell would key
    // the seeded provider and break the suite's keyless pins — strip it.
    NEXUS_SEED_PROVIDER_API_KEY: "",
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

function startNexus({ port, bifrostPort, searxPort, maxToolIterations, workspaceRoot }) {
  const env = {
    ...process.env,
    NEXUS_ENCRYPTION_KEY: ENC_KEY,
    NEXUS_HTTP_BIND: "127.0.0.1",
    NEXUS_HTTP_PORT: String(port),
    NEXUS_UI_TOKEN: TOKEN,
    NEXUS_MAX_TOOL_ITERATIONS: String(maxToolIterations),
    // The web_fetch target is a loopback service under our control.
    NEXUS_HTTP_FETCH_ALLOW_PRIVATE: "true",
    NEXUS_SEARXNG_BASE_URL: `http://127.0.0.1:${searxPort}`,
    NEXUS_SYSTEM_PROMPT:
      "You are nexus under e2e test. Follow the case: markers exactly.",
    ...pgEnvFromUrl(DATABASE_URL),
    // Set only for the pairing-pane instance (tui-pairing Phase C): the
    // main instances deliberately have NO root, so their threads carry
    // no env tools and the byte-prefix envelopes stay as captured. The
    // empty-string override matters: a caller's exported
    // NEXUS_WORKSPACE_ROOT would survive the spread and silently env-up
    // every instance (config treats "" as unset).
    NEXUS_WORKSPACE_ROOT: workspaceRoot ?? "",
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

// Switch the settings page's left tab rail (Providers / Bots). Idempotent:
// clicking the already-active tab is harmless (the sections swap
// visibility; both stay mounted). Providers is the default after any
// page load, so this only matters for the bots flows.
async function settingsTab(page, name) {
  await page.click(`#tab-${name}`);
  await poll(
    async () => await page.locator(`#${name}-panel`).isVisible(),
    { timeout: 10_000, message: `${name} tab open` },
  );
}

// The per-client selection mirror (`#layout[data-selected]`, persisted
// client-side by the page shell and re-supplied on the /ws route).
async function selectedId(p) {
  return await p.locator("#layout").evaluate((el) => el.getAttribute("data-selected") || "");
}

/// Reveal a thread row's hover controls (ui-polish F2) before driving
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
  await page.locator("#tag-filter").focus();
  const want = row.locator(".thread-main");
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
  const guardPort = 18082;
  await resetDatabase();
  await seedProvider(services.bifrostPort);
  const main = startNexus({ port: 18081, maxToolIterations: 8, ...pick(services) });
  let guard = startNexus({ port: guardPort, maxToolIterations: 2, ...pick(services) });
  const guardBase = `http://127.0.0.1:${guardPort}`;
  // The pairing-pane instance (tui-pairing Phase C): its own
  // NEXUS_WORKSPACE_ROOT — the mint surface needs an env-carrying
  // thread (a roster row to re-derive), and the main instances must
  // keep their env-less default toolsets for the byte-prefix pins.
  const pairPort = 18083;
  const pair = startNexus({
    port: pairPort,
    maxToolIterations: 8,
    ...pick(services),
    workspaceRoot: mkdtempSync(join(tmpdir(), "nexus-e2e-pair-")),
  });
  const pairBase = `http://127.0.0.1:${pairPort}`;

  let browser = null;
  let exitCode = 0;
  try {
    await waitHealthy(18081);
    await waitHealthy(guardPort);
    await waitHealthy(pairPort);
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
    await test("auth: thread create requires a bot (no token → 401)", async () => {
      // GET /models is gone (P3 hard cut: no default provider); the
      // create shape is bot-only now, so a provider/model body answers
      // the honest bot-required 400 — gated by the token like every
      // route, and the bot shape still needs the token.
      const noToken = await page.request.post(`${base}/threads`, {
        data: { provider: "fake", model: "smart" },
      });
      eq(noToken.status(), 401, "no token → 401");
      const denied = await page.request.post(`${base}/threads`, {
        data: { provider: "fake", model: "smart" },
        headers: { authorization: "Bearer wrong" },
      });
      eq(denied.status(), 401, "wrong token → 401");
      const shape = await page.request.post(`${base}/threads`, {
        data: { provider: "fake", model: "smart" },
        headers: { authorization: `Bearer ${TOKEN}` },
      });
      eq(shape.status(), 400, "provider/model shape is gone");
      const body = await shape.json();
      assert(
        body.error.includes("threads require a bot"),
        `bot-required error: ${JSON.stringify(body)}`,
      );
      // The live shape: {"bot": id} — and unknown bots still refuse.
      const botId = await createBot("smart", "auth-bot");
      const ok = await page.request.post(`${base}/threads`, {
        data: { bot: botId },
        headers: { authorization: `Bearer ${TOKEN}` },
      });
      eq(ok.status(), 201, "bot shape creates");
      const created = await ok.json();
      const unknown = await page.request.post(`${base}/threads`, {
        data: { bot: "b-nope" },
        headers: { authorization: `Bearer ${TOKEN}` },
      });
      eq(unknown.status(), 400, "unknown bot refused");
      // Leave no rows behind: the next test asserts an empty thread list.
      const gone = await page.request.delete(`${base}/threads/${created.id}`, {
        headers: { authorization: `Bearer ${TOKEN}` },
      });
      eq(gone.status(), 204, "created thread cleaned up");
      const botGone = await page.request.delete(`${base}/bots/${botId}`, {
        headers: { authorization: `Bearer ${TOKEN}` },
      });
      eq(botGone.status(), 204, "created bot cleaned up");
    });

    // -- 2. page load: shell, websocket, empty thread list ----------------
    await test("page: loads, connects websocket, composes against nothing", async () => {
      await page.goto(`${base}/?token=${TOKEN}`);
      await connected(page);
      // The create panel is GONE: threads are bot-only, and the bot is
      // picked beside the composer in compose-new mode.
      eq(await page.locator("#create-panel").count(), 0, "no create panel");
      eq(await page.locator("#thread-list .thread-main").count(), 0, "no threads yet");
      // No bots exist yet: the composer stands down entirely and the
      // muted hint points at Settings.
      assert(
        (await page.getAttribute("#input", "disabled")) !== null,
        "composer disabled without bots",
      );
      assert(
        (await page.getAttribute("#send", "disabled")) !== null,
        "send disabled without bots",
      );
      await poll(
        async () =>
          (await page.locator("#log .note").textContent()).includes(
            "No bots yet",
          ),
        { timeout: 15_000, message: "botless empty-state note" },
      );
    });

    // -- 3. bot-created threads + switch ------------------------------------
    await test("threads: create from bots and switch back", async () => {
      // Threads are born ONLY from bots now, and the UI's compose-new
      // flow creates on first send — so this test drives the API shape
      // (empty threads, no first message yet) to set up the rows the
      // later organize/turn tests expect, and the compose-send flow
      // itself is exercised end-to-end in the bots test below.
      const headers = { authorization: `Bearer ${TOKEN}` };
      const smartMade = await createBotThread("smart", "smart-bot");
      const fastMade = await createBotThread("fast", "fast-bot");
      const smart = smartMade.thread;
      const fast = fastMade.thread;
      // API creates broadcast nothing (empty threads carry no metadata
      // events), so the sidebar learns them on the next connect.
      await page.reload();
      await connected(page);
      await poll(
        async () => (await page.locator("#thread-list .thread-main").count()) === 2,
        { timeout: 15_000, message: "both threads appear" },
      );
      const labels = await page.$$eval("#thread-list .thread-main", (els) => els.map((e) => e.textContent));
      // #107: untitled rows read "Untitled thread" — the alias fallback
      // left the chrome with the provider/model subtitle. The rows are
      // indistinguishable by label now, so the switch-back below targets
      // the thread id from the API.
      assert(labels.some((l) => l.includes("Untitled thread")), `new thread label: ${labels}`);
      const currentLabels = await page.$$eval(
        "#thread-list .thread-main[aria-current='true']",
        (els) => els.map((e) => e.textContent),
      );
      eq(currentLabels.length, 1, "exactly one current thread");
      assert(currentLabels[0].includes("Untitled thread"), `current is a new thread: ${currentLabels}`);
      // Switch back to the smart thread (match by thread id rather than
      // DOM position — the rows are otherwise identical).
      const smartMain = page.locator(
        `#thread-list .thread-row[data-thread-id="${smart.id}"] .thread-main`,
      );
      await smartMain.click();
      // `#model` reads "Untitled thread" for EITHER untitled row — it
      // cannot prove the switch landed — so the row's own aria-current
      // is the poll target.
      await poll(
        async () => (await smartMain.getAttribute("aria-current")) === "true",
        { timeout: 15_000, message: "smart thread current again" },
      );
      // ui-polish F8 + #107: the header context is the thread's TITLE —
      // "Untitled thread" until the first message auto-titles it. The
      // real title is asserted in the organize test after its rename.
      eq(
        await page.locator("#model").textContent(),
        "Untitled thread",
        "header title placeholder",
      );
      // The bots stay for the later compose-send tests (they are
      // cleaned up with the whole world by resetDatabase).
      void fastMade;
      void headers;
    });

    // -- 3b. thread organization --------------------------------------------
    await test("organize: auto-title, rename, tags, pin, filter, archive, delete", async () => {
      const headers = { authorization: `Bearer ${TOKEN}` };
      const threads = async (query = "") =>
        (await (await page.request.get(`${base}/threads${query}`, { headers })).json()).threads;
      const byModel = async (m, query = "") =>
        (await threads(query)).find((s) => s.model === m);
      const smart = await byModel("smart");
      const fast = await byModel("fast");
      const smartRow = page.locator(`.thread-row[data-thread-id="${smart.id}"]`);
      const fastRow = page.locator(`.thread-row[data-thread-id="${fast.id}"]`);

      // Sidebar density (ui-polish F2): an unselected row keeps its five
      // controls out of the way until you actually want them. Pinned here
      // so the pass cannot regress in either direction — permanently
      // hidden (controls unreachable) or permanently shown (no density
      // win). `fastRow` is the unselected one right now, so it is the
      // honest subject.
      {
        const controls = fastRow.locator(".row-controls");
        // Park the pointer off the list first: an earlier test's row click
        // can leave the mouse sitting on a row, and hover-revealed controls
        // must not leak into the at-rest assertion.
        await page.mouse.move(0, 0);
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
        // sidebar's `#tag-filter` input is the last focusable before the
        // list (the `#show-archived` toggle moved BELOW the list, #107),
        // so starting there and pressing Tab walks the actual order: every
        // hidden control is out of the order until its row has focus, so
        // the row's `.thread-main` is the stop that opens it.
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
        await page.locator("#new-thread").focus();
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
          (await smartRow.locator(".thread-title").textContent()).includes(
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
      await smartRow.locator('input[name="title"]').fill("Renamed thread");
      await smartRow
        .locator(".inline-editor:not([hidden])")
        .getByRole("button", { name: "Save", exact: true })
        .click();
      await poll(
        async () =>
          (await smartRow.locator(".thread-title").textContent()).includes(
            "Renamed thread",
          ),
        { timeout: 10_000, message: "renamed row" },
      );
      s = await byModel("smart");
      eq(s.title, "Renamed thread", "manual title in API");
      eq(s.title_source, "manual", "manual title source");
      // ui-polish F8: the header context follows the thread's title, not
      // just the alias fallback.
      await poll(
        () =>
          page
            .locator("#model")
            .evaluate((el) => el.textContent === "Renamed thread"),
        { timeout: 10_000, message: "header shows the thread title" },
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
      // Freeze-race premise saved: the utility reply for this thread's
      // first exchange is still held at the fake (UTILITY_REPLY_DELAY_MS),
      // so this is the moment the manual columns flipped while the apply
      // was in flight. The freeze test below asserts against it.
      manualSavedAt = Date.now();

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
          const pinned = page.locator(".pinned-group .thread-row");
          return (
            (await pinned.count()) === 1 &&
            (await pinned.first().getAttribute("data-thread-id")) === smart.id
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
            .locator(".archive-group .thread-row")
            .first()
            .isVisible()),
        { timeout: 10_000, message: "archive group shown" },
      );
      s = await byModel("smart", "?archived=1");
      eq(s.archived, true, "archived in API");
      // Invariant: an archived thread is never pinned — archiving cleared
      // the pin and the archived row carries no pin control at all.
      eq(s.pinned, false, "archiving cleared the pin in API");
      eq(
        await smartRow.getByRole("button", { name: "Pin", exact: true }).count(),
        0,
        "no pin control on archived row",
      );
      await revealRowControls(smartRow);
      await smartRow.getByRole("button", { name: "Restore", exact: true }).click();
      await poll(async () => await smartRow.locator(".thread-main").isVisible(), {
        timeout: 10_000,
        message: "restored row back in the list",
      });
      // #67 contract: archiving the OPEN thread deliberately deselects
      // (`deselect` + sticky `suppress_autoselect`) and restoring does not
      // re-select — the chat pane stays blank (showing the compose-new bot
      // picker since bots exist) until a row is picked. Pin that contract
      // here, then re-select the restored thread: the always-visible
      // selected-row controls come back with the pick.
      eq(await selectedId(page), "", "archive-of-selection cleared the selection");
      await poll(async () => await page.locator("#composer-bot").isVisible(), {
        timeout: 10_000,
        message: "compose-new bot picker shown after archive-deselect",
      });
      await smartRow.locator(".thread-main").click();
      await poll(
        () =>
          page
            .locator("#model")
            .evaluate((el) => el.textContent === "Renamed thread"),
        { timeout: 10_000, message: "re-selected the restored thread" },
      );
      // Restored threads are active again: the pin control is back (the
      // pin itself stays cleared until re-pinned).
      await poll(
        async () =>
          await smartRow.getByRole("button", { name: "Pin", exact: true }).isVisible(),
        { timeout: 10_000, message: "pin control back after restore" },
      );

      // Delete the fast thread: two-step confirm, hard removal.
      await revealRowControls(fastRow);
      await fastRow.getByRole("button", { name: "Delete", exact: true }).click();
      await fastRow
        .getByRole("button", { name: "Delete forever", exact: true })
        .click();
      await poll(async () => (await fastRow.count()) === 0, {
        timeout: 10_000,
        message: "deleted row gone",
      });
      const after = await threads();
      assert(!after.some((x) => x.id === fast.id), "deleted thread gone from API");
      eq(after.length, 1, "only the smart thread remains");
    });

    // -- 3c. utility tags: manual freeze refuses the racing apply --------
    // The organize test's first exchange armed the smart thread's
    // once-per-thread utility attempt; the branch request left at the
    // debounce and the fake HOLDS its reply UTILITY_REPLY_DELAY_MS, so
    // the manual rename + tags save above had already flipped both
    // provenance columns to 'manual' while the apply was still in
    // flight. Wait the held reply out: the store's both-column guard
    // (auto_meta_upgrade) must refuse the late apply — title AND tags
    // stay exactly the manual set (utility-tags plan §3.5).
    await test("utility: manual tags freeze refuses the racing model apply", async () => {
      const headers = { authorization: `Bearer ${TOKEN}` };
      // The smart thread's is the suite's FIRST utility request — its
      // exchange is the first committed turn of the run (the guard and
      // ui-made threads have not sent one yet).
      await poll(
        async () =>
          services.requests.filter(
            (r) => r.url === "/v1/chat/completions" && r.body.includes(UTILITY_DELTA),
          ).length >= 1,
        { timeout: 15_000, message: "utility branch request recorded" },
      );
      // The premise was OBSERVED in organize: `manualSavedAt` is when the
      // manual tags save poll completed — the tags save is the later of
      // the two saves — while the held reply was still in flight. That
      // timestamp must beat the held reply's completion — proving the
      // freeze was really in place while the apply was still in flight;
      // if a run ever loses that race, fail here rather than passing
      // vacuously afterwards.
      const manualAt = manualSavedAt;
      assert(
        manualAt > 0,
        "organize did not record the manual save time",
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
        await (await page.request.get(`${base}/threads`, { headers })).json()
      ).threads.find((s) => s.model === "smart");
      eq(smart.title, "Renamed thread", "manual title survived the utility apply");
      eq(smart.title_source, "manual", "title still manual");
      eq(smart.tags.join(","), "ops,infra", `manual tags survived the apply: ${smart.tags}`);
      // The sidebar agrees: exactly the two manual chips — no model tag
      // (hostile or plain) ever landed on the row.
      const row = page.locator(`.thread-row[data-thread-id="${smart.id}"]`);
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

    // -- 6. web_fetch tool loop ----------------------------------------------
    await test("tools: web_fetch chip opens a popup with args, result, and status", async () => {
      await sendAndWaitIdle(
        page,
        `case:fetch fetch http://127.0.0.1:${services.docPort}/doc.json`,
      );
      const chip = page.locator(".turn.tool[data-call-id]");
      await chip.first().waitFor({ timeout: 30_000 });
      // The chip itself is the popup opener: one compact button carrying
      // the tool name, state tint, and an aria-label (never color-only).
      const chipInfo = await chip.first().evaluate((el) => ({
        tool: el.getAttribute("data-tool"),
        label: el.getAttribute("aria-label"),
        done: el.classList.contains("done"),
        text: el.textContent,
      }));
      eq(chipInfo.tool, "web_fetch", "tool name");
      eq(chipInfo.done, true, "terminal tint class");
      assert(chipInfo.label.includes("completed"), `aria status: ${chipInfo.label}`);
      eq(chipInfo.text.trim(), "web_fetch", "chip is the name only — no inline preview");
      // Clicking the chip opens the full-call popup.
      await chip.first().click();
      const pop = page.locator("dialog[open] article.tool-pop");
      await pop.waitFor({ timeout: 10_000 });
      const info = await pop.evaluate((el) => ({
        status: el.querySelector(".tool-status").textContent,
        sections: [...el.querySelectorAll("h3")].map((h) => h.textContent),
        pres: [...el.querySelectorAll("pre")].map((p) => p.textContent),
      }));
      eq(info.status, "completed", "terminal status");
      assert(info.sections.includes("Arguments"), `sections: ${info.sections}`);
      const args = info.pres[0];
      const result = info.pres[info.pres.length - 1];
      assert(args.includes(`/doc.json`), `full arguments: ${args}`);
      assert(result.includes("nexus-e2e-doc"), `full result: ${result}`);
      assert(result.includes("<script>alert"), "popup shows markup as text");
      // Inertness: the document keeps exactly its two static scripts (the
      // runtime module and the connection indicator), and the component's
      // shadow root — where rendered tool output lives, popup included —
      // has none.
      const scripts = await page.evaluate(() => ({
        document: document.querySelectorAll("script").length,
        shadow: document
          .querySelector("lustre-server-component")
          ?.shadowRoot?.querySelectorAll("script").length ?? -1,
      }));
      eq(scripts.document, 2, "static scripts only");
      eq(scripts.shadow, 0, "no scripts inside the component view");
      // Close the popup by clicking OUTSIDE the card — the backdrop
      // catcher dismisses it (the ✕ button path is covered in the
      // web_search test below). The fixed overlay must not block later
      // tests, so wait for it to be gone.
      await page.mouse.click(10, 10);
      await poll(
        () => page.locator("dialog[open]").count().then((c) => c === 0),
        { timeout: 10_000, message: "popup dismissed by outside click" },
      );
      const finalText = await page.$$eval(".turn.assistant", (els) => els.map((e) => e.textContent));
      assert(finalText.some((t) => t.includes("Fetch complete")), `final answer: ${finalText}`);
      // Auto-follow must survive the transitions this turn just exercised:
      // bubble -> tool chip -> bubble changes #log's height (the thinking
      // chip collapses at commit), and each shrink clamps scrollTop
      // downward. A drag-detector that reads that clamp as a user gesture
      // unpins and following dies for the rest of the turn.
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
        // A single sample can interleave with the observer's pin right as
        // the content first overflows, so sample until the follow holds;
        // a genuinely dead follow never recovers and the asserts below
        // fail with the last sampled state.
        await poll(
          async () => {
            follow = await page.evaluate(() => {
              const sr = document.querySelector("lustre-server-component")?.shadowRoot;
              const log = sr?.getElementById("log");
              const jump = sr?.getElementById("jump-latest");
              return {
                fromBottom: log ? log.scrollHeight - log.scrollTop - log.clientHeight : -1,
                jumpShown: jump ? !jump.hidden : null,
              };
            });
            return follow.fromBottom >= 0 && follow.fromBottom < 80;
          },
          { timeout: 5_000, interval: 100, message: "auto-follow settled" },
        ).catch(() => {});
        assert(follow.fromBottom < 80, `auto-follow died mid-turn: ${JSON.stringify(follow)}`);
        assert(!follow.jumpShown, `jump button surfaced mid-turn: ${JSON.stringify(follow)}`);
      } finally {
        await page.setViewportSize(pane);
      }
    });

    // -- 7. web_search tool loop -----------------------------------------------
    await test("tools: web_search chip completes with stub result", async () => {
      await sendAndWaitIdle(page, "case:search look it up");
      const chip = page.locator(".turn.tool.done[data-tool='web_search']");
      await chip.first().waitFor({ timeout: 30_000 });
      await chip.first().click();
      const pop = page.locator("dialog[open] article.tool-pop");
      await pop.waitFor({ timeout: 10_000 });
      const result = await pop.locator("pre").last().textContent();
      assert(result.includes("nexus-e2e stub title"), `searxng stub result: ${result}`);
      await pop.locator("button.close").click();
      await poll(
        () => page.locator("dialog[open]").count().then((c) => c === 0),
        { timeout: 10_000, message: "popup closed" },
      );
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
    await test("reconnect: reload replays full tool history as chips", async () => {
      await page.reload();
      await connected(page);
      await page.waitForSelector(".turn.tool[data-call-id]", { timeout: 30_000 });
      const chips = await page.$$eval(".turn.tool[data-call-id]", (els) =>
        els.map((el) => ({
          id: el.getAttribute("data-call-id"),
          tool: el.getAttribute("data-tool"),
          done: el.classList.contains("done"),
          label: el.getAttribute("aria-label"),
        })),
      );
      const fetchChips = chips.filter((c) => c.tool === "web_fetch");
      const searchChips = chips.filter((c) => c.tool === "web_search");
      assert(fetchChips.length === 2, `two fetch chips replayed: ${JSON.stringify(chips)}`);
      eq(searchChips.length, 1, "one search chip replayed");
      assert(chips.every((c) => c.done && c.label.includes("completed")), "all replayed chips completed");
      assert(chips.every((c) => c.id.startsWith("call_")), "stable call ids preserved");
      // A replayed chip still opens its popup with the result attached.
      await page.locator(".turn.tool.done[data-tool='web_search']").first().click();
      const pop = page.locator("dialog[open] article.tool-pop");
      await pop.waitFor({ timeout: 10_000 });
      const result = await pop.locator("pre").last().textContent();
      assert(result.includes("nexus-e2e stub title"), `replayed result in popup: ${result}`);
      await pop.locator("button.close").click();
      await poll(
        () => page.locator("dialog[open]").count().then((c) => c === 0),
        { timeout: 10_000, message: "popup closed" },
      );
      // Tool events must never render as model text.
      const assistantText = await page.$$eval(".turn.assistant", (els) => els.map((e) => e.textContent));
      assert(
        assistantText.every((t) => !t.includes("call_") && !t.includes("web_fetch") && !t.includes("web_search")),
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
      // This thread already carries earlier tests' turns, so the new turn's
      // cards are identified positionally (the DOM renders oldest-first).
      const cardsBefore = await page.$$eval(".turn.tool[data-call-id]", (els) => els.length);
      await page.fill(
        "#input",
        `case:fetchslow fetch http://127.0.0.1:${services.docPort}/doc.json`,
      );
      await page.press("#input", "Enter");
      const myChips = () =>
        page.$$eval(".turn.tool[data-call-id]", (els, before) =>
          els
            .slice(before)
            .map((el) => ({
              done: el.classList.contains("done"),
              label: el.getAttribute("aria-label") ?? "",
            })),
        cardsBefore,
      );
      // Round 1 done: one completed fetch chip, pre-reload.
      await poll(
        async () => {
          const chips = await myChips();
          return chips.length === 1 && chips[0].done;
        },
        { timeout: 30_000, interval: 100, message: "round 1 chip completed" },
      );
      // Reload while the final round holds the stream open. The thread
      // re-opens via the route query (page shell persistence).
      await page.reload();
      await connected(page);
      // The finished round replays from the thread's in-flight mirror:
      // same single completed chip. Its popup carries the result.
      await poll(
        async () => {
          const chips = await myChips();
          return chips.length === 1 && chips[0].done;
        },
        { timeout: 30_000, interval: 100, message: "in-flight round replayed after reload" },
      );
      await page.locator(".turn.tool[data-call-id]").last().click();
      const pop = page.locator("dialog[open] article.tool-pop");
      await pop.waitFor({ timeout: 10_000 });
      const result = await pop.locator("pre").last().textContent();
      assert(result.includes("nexus-e2e-doc"), `replayed result in popup: ${result}`);
      await pop.locator("button.close").click();
      await poll(
        () => page.locator("dialog[open]").count().then((c) => c === 0),
        { timeout: 10_000, message: "popup closed" },
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
      // No thread is minted at boot, and threads are born from bots now:
      // compose-new — pick a bot beside the composer and send; the send
      // itself starts the thread AND the turn (the instances share the
      // database, so a bot made here is visible; the reload lands its
      // row in the picker).
      // The bot registry is in-memory per instance and boot-loaded: the
      // guard instance must learn the bot through its OWN API, or its
      // compose picker (served by the guard's registry) never lists it.
      const guardBotId = await createBot("smart", "guard-bot", guardBase);
      await page.reload();
      await connected(page);
      await page.click("#new-thread");
      await poll(
        async () => (await page.locator("#bot-picker option").count()) >= 1,
        { timeout: 15_000, message: "guard picker lists the bot" },
      );
      await page.selectOption("#bot-picker", guardBotId);
      await page.fill("#input", "case:loop never stop calling tools");
      await page.press("#input", "Enter");
      await poll(
        async () => (await page.locator("#thread-list .thread-main").count()) === 1,
        { timeout: 15_000, message: "guard thread appears" },
      );
      // The turn IS the send; the Send button re-enabling proves it
      // ended (failed at the guard — that is the state under test).
      await poll(() => page.locator("#send").evaluate((el) => !el.disabled), {
        timeout: 120_000,
        message: "guard turn ended",
      });
      // Guard terminal: chip reached guard phase, note rendered, send re-enabled.
      const note = page.locator(".note.err");
      await note.first().waitFor({ timeout: 90_000 });
      const noteText = await note.first().textContent();
      assert(
        noteText.includes("iteration guard: reached max 2 model round-trips"),
        `guard note: ${noteText}`,
      );
      const chips = await page.$$eval(".turn.tool[data-call-id]", (els) => els.map((el) => ({
        label: el.getAttribute("aria-label") ?? "",
      })));
      assert(chips.length >= 1 && chips.every((c) => c.label.includes("completed")), `completed rounds kept: ${JSON.stringify(chips)}`);
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
      // thread's frozen envelope plus exactly the UTILITY_DELTA above, so
      // they are not suffix-growths of the chat chain; they are judged by
      // their own contract after the chain scan, not lumped into it.
      const isUtility = (chat) => chat.body.includes(UTILITY_DELTA);
      const turnChats = chats.filter((c) => !isUtility(c));
      // Requests from the two nexus instances interleave in one log; a
      // request that does not extend the previous one starts a new chain
      // (one chain per thread). Every chain must grow by suffix only.
      const chains = [];
      for (const chat of turnChats) {
        const last = chains[chains.length - 1];
        if (last && extendsRequest(last[last.length - 1].body, chat.body)) {
          last.push(chat);
        } else {
          chains.push([chat]);
        }
      }
      eq(chains.length, 2, `thread chains (main + guard): ${chains.map((c) => c.length)}`);
      for (const [i, chain] of chains.entries()) {
        assert(chain.length >= 2, `chain ${i} too short: ${chain.length}`);
        for (let j = 1; j < chain.length; j++) {
          assert(
            extendsRequest(chain[j - 1].body, chain[j].body),
            `chain ${i}: request ${j} does not extend ${j - 1} by suffix`,
          );
        }
      }
      // Each utility branch must extend its thread's committed transcript
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
    // last-selected thread (persisted client-side, re-supplied on the
    // /ws route). A second thread created in the mobile context makes
    // the divergence real: the two contexts hold DIFFERENT selections at
    // the same time, which a shared runtime could never show. The mobile
    // overflow check stays.
    await test("mobile: independent per-client view, no overflow with cards", async () => {
      const desktop = await browser.newContext({ viewport: { width: 1280, height: 900 } });
      const dpage = await desktop.newPage();
      track(dpage);
      await dpage.goto(`${base}/?token=${TOKEN}`);
      await connected(dpage);
      await dpage.waitForSelector("#thread-list .thread-main", { timeout: 30_000 });

      const mobile = await browser.newContext({ viewport: { width: 390, height: 844 } });
      const mpage = await mobile.newPage();
      track(mpage);
      await mpage.goto(`${base}/?token=${TOKEN}`);
      await connected(mpage);
      // Fresh runtime, fresh model: the thread re-opens through this
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

      // Selection state is per-client: entering compose-new (the bot
      // picker beside the composer) on mobile must not appear on the
      // desktop context, whose selection stays put.
      await mpage.click("#new-thread");
      await poll(
        async () => await mpage.locator("#composer-bot").isVisible(),
        { timeout: 15_000, message: "mobile compose-new picker visible" },
      );
      eq(
        await dpage.locator("#composer-bot").count(),
        0,
        "desktop stays in its thread (no picker)",
      );

      const overflow = await mpage.evaluate(() => ({
        scrollWidth: document.documentElement.scrollWidth,
        innerWidth: window.innerWidth,
      }));
      assert(overflow.scrollWidth <= overflow.innerWidth + 1, `overflow: ${JSON.stringify(overflow)}`);

      // ui-polish F3(a): stacked, the sidebar is capped so the transcript
      // keeps the rest of the viewport — without the cap three threads
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

      // ui-polish F4's successor: the compose picker rides the composer
      // at the BOTTOM of the viewport, so it lands on screen on a phone
      // by construction — measure it as-is (compose-new is still armed
      // from the per-client check above).
      const pickBox = await mpage.locator("#composer-bot").evaluate((el) => {
        const r = el.getBoundingClientRect();
        return { top: r.top, bottom: r.bottom, inner: window.innerHeight };
      });
      assert(
        pickBox.top >= 0 && pickBox.bottom <= pickBox.inner,
        `compose picker off-screen: ${JSON.stringify(pickBox)}`,
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

      // Diverge the contexts for real: start a second thread from the
      // mobile context's composer — pick a bot, send the draft; the send
      // creates the thread and selects it. The desktop context's model
      // never learns of it (the draft's auto-title does broadcast a
      // sidebar refresh — but the desktop REFRESH only relists what it
      // asks for; the divergence is the selection, asserted below), so
      // mobile holds the new thread while desktop keeps the original —
      // two live connections, two different selections.
      const divergeBotId = await createBot("smart", "diverge-bot");
      await mpage.reload();
      await connected(mpage);
      await mpage.click("#new-thread");
      await poll(
        async () => (await mpage.locator("#bot-picker option").count()) >= 1,
        { timeout: 15_000, message: "mobile compose picker lists bots" },
      );
      await mpage.selectOption("#bot-picker", divergeBotId);
      await mpage.fill("#input", "case:mobile diverge draft");
      await mpage.press("#input", "Enter");
      await poll(
        async () => (await mpage.locator("#thread-list .thread-main").count()) === 2,
        { timeout: 15_000, message: "second thread appears on mobile" },
      );
      const second = await selectedId(mpage);
      assert(second && second !== first, `mobile moved to its new thread: ${second} vs ${first}`);
      eq(
        await selectedId(dpage),
        first,
        "desktop keeps its own selection while mobile diverges",
      );
      // MetaUpdated is scoped to subscribers of the mutated thread: desktop
      // is subscribed to `first` (not `second`), so its list stays at 1 until
      // it refreshes, while mobile holds its newly created second thread.
      // Poll across a bounded window asserting the count stays 1 throughout
      // (so a transient or delayed unsolicited refresh would be caught).
      const absenceDeadline = Date.now() + 750;
      while (Date.now() < absenceDeadline) {
        eq(
          await dpage.locator("#thread-list .thread-main").count(),
          1,
          "desktop stays on its own thread list without unsolicited refresh",
        );
        await sleep(100);
      }

      // Reload: the context's own last-selected thread (the second one —
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
        await mpage.locator("#composer-bot").count(),
        0,
        "compose-new state does not survive a reload (the selection does)",
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
      await tpage.waitForSelector(".thread-row", { timeout: 15_000 });
      const touchState = await tpage.evaluate(() => {
        const sr = document
          .querySelector("lustre-server-component")
          ?.shadowRoot;
        const rows = [...sr.querySelectorAll(".thread-row")];
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
        .locator(".thread-row:not(.selected) .thread-main")
        .first();
      if (await untapped.count()) {
        await untapped.tap();
        await poll(
          async () =>
            await tpage
              .locator(".thread-row.selected .row-controls")
              .first()
              .isVisible(),
          { timeout: 10_000, message: "tap selects and reveals the controls" },
        );
      }
      await touch.close();

      // Leave one thread behind, as the suite found it: later tests
      // count rows and chat-request chains.
      await mpage.request.delete(`${base}/threads/${second}`, {
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

    // -- 13. provider management (P5) ----------------------------------------
    // The P5 acceptance, end to end through the real UI — inside the
    // Settings view (the header button swaps the main area; provider
    // management lives there): create a provider in Settings, test the
    // seeded provider's connection (live model aliases), then pin a
    // thread to it THROUGH A BOT (threads are bot-only now) and stream
    // a turn. Then the guard rails: the delete is refused while the
    // thread's bot pins the provider, and disable/enable gate bot
    // creates.
    await test("providers: create in UI, pick, pin a thread, stream a turn", async () => {
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
      // tab rail sits LEFT of the body column, the active section is a
      // centered column inside that body, and provider rows render as
      // bordered cards.
      {
        const pane = await page.locator("#settings-page").boundingBox();
        const nav = await page.locator("#settings-nav").boundingBox();
        const body = await page.locator(".settings-body").boundingBox();
        const section = await page.locator("#providers-panel").boundingBox();
        assert(
          nav.x + nav.width <= section.x,
          `tab rail left of section: nav ends ${nav.x + nav.width}, section starts ${section.x}`,
        );
        assert(
          section.width < pane.width - 100,
          `settings column narrower than pane: ${section.width} vs ${pane.width}`,
        );
        const delta = Math.abs(
          section.x + section.width / 2 - (body.x + body.width / 2),
        );
        assert(delta < 2, `settings column centered in body: delta ${delta}px`);
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

      // Back to chat to start a thread on the new provider — the only
      // way threads begin now: a BOT carrying the pin (provider
      // ui-made, alias smart), composed in the UI. The provider pin is
      // asserted through the API and the streamed turn below.
      await backToChat(page);
      const headers13 = { authorization: `Bearer ${TOKEN}`, "content-type": "application/json" };
      const madeBotRes = await page.request.post(`${base}/bots`, {
        data: { name: `ui-made-bot-${Date.now()}`, provider: madeId, model: "smart" },
        headers: headers13,
      });
      eq(madeBotRes.status(), 201, "bot on the new provider created");
      const madeBotId = (await madeBotRes.json()).id;
      // An API-side bot create is out of band for a live /ws connection,
      // so reload to pick up the new bot in the compose picker.
      await page.reload();
      await connected(page);
      const threadsBefore = await page.locator("#thread-list .thread-main").count();
      await page.click("#new-thread");
      await poll(
        async () => await page.locator("#bot-picker").isVisible(),
        { timeout: 10_000, message: "compose-new picker visible" },
      );
      await page.selectOption("#bot-picker", madeBotId);
      await page.fill("#input", "case:text provider ui round");
      await page.press("#input", "Enter");
      await poll(
        async () => (await page.locator("#thread-list .thread-main").count()) === threadsBefore + 1,
        { timeout: 15_000, message: "pinned thread appears" },
      );
      // #107: the row subtitle leads with the bot name (provenance),
      // never the provider/model — the chrome shows bot-or-nothing + age.
      eq(
        await page
          .locator("#thread-list .thread-main", { hasText: "ui-made/" })
          .count(),
        0,
        "row subtitle omits provider/model",
      );

      // The send IS the create: the first message streams end-to-end
      // through the new provider.
      await poll(() => page.locator("#send").evaluate((el) => !el.disabled), {
        timeout: 60_000,
        message: "compose-send turn ended",
      });
      const assistant = await page.$$eval(".turn.assistant", (els) => els.map((e) => e.textContent));
      assert(assistant.some((t) => t.includes("Plain answer")), `assistant turn via ui-made: ${assistant}`);

      // Guard rail: deleting a provider its thread pins is refused (the
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
            ?.includes("provider is still pinned by threads"),
        { timeout: 15_000, message: "409 guard error visible in settings" },
      );
      await backToChat(page);
      await poll(
        async () =>
          (await page.locator(".note.err").last().textContent())
            ?.includes("provider is still pinned by threads"),
        { timeout: 15_000, message: "409 guard note after pinned delete" },
      );

      // Disable: the row badges as disabled (in Settings). A bot is a
      // template so creating a bot pointing at a disabled provider is
      // allowed (201), while starting a THREAD from that bot is refused
      // (400) until the provider is re-enabled.
      await openSettings(page);
      await madeRow.getByRole("button", { name: "Disable", exact: true }).click();
      await poll(
        async () => (await madeRow.locator(".badge.off").textContent()) === "disabled",
        { timeout: 15_000, message: "disabled badge" },
      );
      const disabledBotRes = await page.request.post(`${base}/bots`, {
        data: { name: `disabled-pin-${Date.now()}`, provider: madeId, model: "smart" },
        headers: headers13,
      });
      eq(disabledBotRes.status(), 201, "bot template can reference a disabled provider");
      const disabledBotId = (await disabledBotRes.json()).id;
      const disabledThread = await page.request.post(`${base}/threads`, {
        data: { bot: disabledBotId },
        headers: headers13,
      });
      eq(disabledThread.status(), 400, "disabled provider refuses thread create");
      // Disabling blocks new resolutions, not the already-frozen thread
      // endpoint — the pinned thread keeps streaming either way (the
      // compose-send turn above already ran while enabled; the frozen
      // endpoint is what the next send would ride).
      await madeRow.getByRole("button", { name: "Enable", exact: true }).click();
      await poll(
        async () => (await madeRow.locator(".badge").count()) === 1,
        { timeout: 15_000, message: "re-enabled provider badge restored" },
      );
      const reThread = await page.request.post(`${base}/threads`, {
        data: { bot: disabledBotId },
        headers: headers13,
      });
      eq(reThread.status(), 201, "re-enabled provider takes thread creates again");
      const reThreadId = (await reThread.json()).id;
      const reThreadGone = await page.request.delete(`${base}/threads/${reThreadId}`, {
        headers: { authorization: `Bearer ${TOKEN}` },
      });
      eq(reThreadGone.status(), 204, "re-enabled test thread cleaned up");
    });

    // -- 17b. bots: create in Settings, start-from-bot, delete keeps the
    // frozen pin (bots plan P1) -----------------------------------------
    await test("bots: create in Settings, start a thread from it, delete unorphan", async () => {
      const headers = { authorization: `Bearer ${TOKEN}` };
      await page.goto(`${base}/?token=${TOKEN}`);
      await connected(page);

      // The Bots section is its own tab now; the rail switches to it.
      // The add form carries the template fields (provider select,
      // model, optional prompt).
      await openSettings(page);
      await settingsTab(page, "bots");
      await page.click("#add-bot");
      await page.fill('#add-bot-form input[name="name"]', "Writer");
      await page.fill('#add-bot-form input[name="description"]', "prose drafts");
      await page.fill('#add-bot-form input[name="model"]', "smart");
      await page.fill('#add-bot-form textarea[name="system_prompt"]', "be terse");
      await page.locator('#add-bot-form button[type="submit"]').click();

      const botRow = page.locator("#bots-panel .bot-row", { hasText: "Writer" }).first();
      await poll(async () => await botRow.isVisible(), {
        timeout: 15_000,
        message: "created bot row appears",
      });
      const botId = await botRow.getAttribute("data-bot-id");
      // The row shows the identity line (provider/model) and the
      // explicit prompt preview.
      assert(
        (await botRow.locator(".provider-sub").first().textContent())
          ?.includes("fake/smart"),
        "bot row identity line",
      );
      const botsApi = await (
        await page.request.get(`${base}/bots`, { headers })
      ).json();
      const made = botsApi.bots.find((b) => b.id === botId);
      eq(made.name, "Writer", "created bot in API");
      eq(made.system_prompt, "be terse", "bot prompt in API");

      // Back to chat: the COMPOSER carries the bot picker (compose-new
      // mode — no thread selected). Type the draft FIRST, then pick the
      // bot — changing your mind about the bot never touches the text.
      await backToChat(page);
      await page.click("#new-thread");
      await poll(
        async () => await page.locator("#bot-picker").isVisible(),
        { timeout: 10_000, message: "compose-new picker visible" },
      );
      await page.fill("#input", "case:hello writer");
      await page.selectOption("#bot-picker", botId);
      eq(
        await page.inputValue("#input"),
        "case:hello writer",
        "the draft survives the bot change",
      );
      const threadsBefore = await page.locator("#thread-list .thread-main").count();
      const beforeIds = new Set(
        (await (await page.request.get(`${base}/threads`, { headers })).json()).threads.map((s) => s.id),
      );
      // The send IS the create: the draft starts the thread and becomes
      // its first message (the turn streams via the fake gateway).
      await page.press("#input", "Enter");
      await poll(
        async () =>
          (await page.locator("#thread-list .thread-main").count())
            === threadsBefore + 1,
        { timeout: 15_000, message: "bot-sourced thread appears" },
      );
      await poll(() => page.locator("#send").evaluate((el) => !el.disabled), {
        timeout: 60_000,
        message: "compose-send turn ended",
      });
      // The API agrees: identify the created thread precisely (a diff
      // against the pre-create snapshot), so every later assertion — row
      // subtitle, provenance drop, frozen pin — is about THIS thread,
      // not any other smart-model row.
      const threadsApi = await (
        await page.request.get(`${base}/threads`, { headers })
      ).json();
      const madeThread = threadsApi.threads.find((s) => !beforeIds.has(s.id));
      assert(madeThread, "bot-sourced thread in API");
      eq(madeThread.bot_id, botId, "thread summary carries bot_id");
      // The row subtitle leads with the bot name (provenance), then the
      // age — #107 dropped the frozen pin from the chrome.
      const botThreadRow = page.locator(
        `#thread-list .thread-row[data-thread-id="${madeThread.id}"]`,
      );
      await poll(async () => await botThreadRow.isVisible(), {
        timeout: 10_000,
        message: "thread subtitle leads with bot provenance",
      });
      assert(
        (await botThreadRow.innerText()).includes("Writer · "),
        "row subtitle leads with the bot name",
      );
      // The draft auto-titled the thread at the send boundary.
      assert(
        (await botThreadRow.innerText()).includes("case:hello writer"),
        "row title is the first message",
      );

      // Delete the bot (two-step, unguarded): the thread keeps its
      // frozen pin, and the provenance name falls away from the row.
      // The bots tab is still the active one in this connection's
      // settings state, but switching again is idempotent.
      await openSettings(page);
      await settingsTab(page, "bots");
      await botRow.getByRole("button", { name: "Delete", exact: true }).click();
      await botRow
        .getByRole("button", { name: "Delete forever", exact: true })
        .click();
      await poll(async () => !(await botRow.isVisible().catch(() => false)), {
        timeout: 15_000,
        message: "bot row gone after delete",
      });
      await backToChat(page);
      // Provenance is display-side self-healing: the summary's pointer
      // stays stale until a rehydrate (the store's FK SET NULL), so the
      // assertions are the surviving thread's frozen pin (API) and its
      // row showing the age-only subtitle (display).
      await poll(
        async () => {
          const api = await (
            await page.request.get(`${base}/threads`, { headers })
          ).json();
          const kept = api.threads.find((s) => s.id === madeThread.id);
          const rowText = await botThreadRow.innerText().catch(() => "");
          return (
            !!kept
            && kept.provider_id === madeThread.provider_id
            && kept.model === madeThread.model
            && rowText.includes("case:hello writer")
            && !rowText.includes("Writer · ")
          );
        },
        { timeout: 15_000, message: "thread keeps pin, provenance name gone",
        },
      );
      // The compose picker drops the deleted bot too (the picker re-aim
      // rule, bot edition): its option is gone on the next load.
      await page.click("#new-thread");
      await poll(
        async () => {
          const options = await page.$$eval("#bot-picker option", (els) =>
            els.map((e) => e.value),
          );
          return !options.includes(botId);
        },
        { timeout: 15_000, message: "picker drops the deleted bot" },
      );
      // Leave the client freshly connected on the server's current
      // truth (the utility test below reads the sidebar this page
      // leaves behind; a reload guarantees a fresh thread list with
      // every existing row's chips, regardless of what this test's
      // create/delete churn touched).
      await page.goto(`${base}/?token=${TOKEN}`);
      await connected(page);
    });

    // -- 17c. bots P3c: bot-to-bot relay (bot_message) -------------------
    // Alpha's thread — created FROM bot Alpha, so its toolset is the
    // human default PLUS bot_message — relays a note to bot Beta: the
    // fake gateway scripts the bot_message call, Alpha's turn receives
    // the receipt, and Beta's DM thread gains the authored user turn
    // (the From prefix rides the message bytes) and completes a plain
    // turn. The gateway's recorded request bodies are the model-visible
    // ground truth (issue #97's e2e smoke).
    await test("bots: bot-to-bot relay delivers an authored user turn", async () => {
      // The shared rig (see relayRig): bots, parent thread, relay send,
      // channel discovery + settle, children-first cleanup.
      const { betaId, alphaThread, betaThread, settled, note, cleanup } =
        await relayRig("Relay", "relay-note-123");
      try {
        eq(
          settled.summary?.bot_id ?? null,
          betaId,
          "the channel hangs off Beta's provenance",
        );

        // Model-visible bytes: the gateway records raw request strings, so
        // parse them. Beta's recorded request carries the authored user
        // line — the From prefix names the sender and Alpha's thread, so
        // Beta can reply by addressing it precisely.
        const bodies = services.requests.map((r) => {
          try {
            return JSON.parse(r.body);
          } catch {
            return {};
          }
        });
        const betaMessages = bodies
          .map((body) => body?.messages ?? [])
          .find((messages) =>
            messages.some(
              (m) =>
                m.role === "user" &&
                String(m.content).startsWith(
                  `From RelayAlpha (thread ${alphaThread}): `,
                ),
            ),
          );
        assert(betaMessages, "Beta's turn carried the authored line to the model");
        const authored = betaMessages.find(
          (m) =>
            m.role === "user" && String(m.content).includes(note),
        );
        assert(
          authored &&
            authored.content.endsWith(
              "(reply via the bot_message tool with to \"" +
                alphaThread +
                "\" — a plain reply stays in this thread and never reaches the sender)",
            ),
          "authored line is the From prefix, the tool's text, and the reply hint",
        );
        // Beta's envelope carries its own (bot-default) toolset.
        const betaBody = bodies.find(
          (body) => (body?.messages ?? []) === betaMessages,
        );
        assert(
          betaBody?.tools?.some((t) => t.function?.name === "bot_message"),
          "bot thread envelope includes bot_message",
        );

        // Alpha's follow-up request carries the delivery receipt as the
        // tool result — naming Beta's thread (where the reply conversation
        // lives) — and round 2 answered after it.
        const receipt = bodies
          .flatMap((body) => body?.messages ?? [])
          .find(
            (m) =>
              m.role === "tool" &&
              String(m.content).includes("delivered to RelayBeta in thread"),
          );
        assert(receipt, "receipt landed as Alpha's tool result");
        const receiptThread = /thread (s\d+)/.exec(receipt.content)?.[1];
        eq(receiptThread, betaThread, "receipt names the DM thread");

        // Display proof (issue #122): in the UI the authored line folds up
        // as a bot chip instead of reading as the user's own bubble. The
        // channel is never a sidebar row (second-class), so the browser
        // reaches it through the parent's thread info pane — the pane
        // row navigates the main chat area to the channel, exercising
        // the replay path. The live path renders the same UserEcho shape
        // (nexus/ui bot_turn, pinned offline in ui_test). Collapsed by
        // default, the summary names the sender, the body carries the
        // note, and no plain user bubble renders for it.
        await page.goto(`${base}/?token=${TOKEN}`);
        await connected(page);
        await page
          .locator(
            `#thread-list .thread-row[data-thread-id="${alphaThread}"] .thread-main`,
          )
          .click();
        await page.locator("#info-btn").waitFor({ timeout: 15_000 });
        await page.locator("#info-btn").click();
        const paneRow = page.locator(
          `.info-pop .ch[data-thread-id="${betaThread}"]`,
        );
        await paneRow.waitFor({ timeout: 15_000 });
        await paneRow.click();
        const botChip = page.locator("details.turn.bot");
        await botChip.waitFor({ timeout: 15_000 });
        const chip = await botChip.evaluate((el) => ({
          open: el.open,
          summary: el.querySelector("summary")?.textContent ?? "",
          age: el.querySelector("summary time.ts")?.textContent ?? "",
          body: el.querySelector(".bot-body")?.textContent ?? "",
        }));
        eq(chip.open, false, "bot chip renders collapsed");
        assert(
          chip.summary.includes("RelayAlpha"),
          `chip summary names the sender: ${chip.summary}`,
        );
        assert(
          chip.age.trim().length > 0,
          `chip summary carries the message age: "${chip.age}"`,
        );
        assert(
          chip.body.includes(note),
          `chip body carries the note: ${chip.body}`,
        );
        eq(
          await page.locator(".turn.user").count(),
          0,
          "the authored line is not a plain user bubble",
        );
      } finally {
        await cleanup();
      }
    });

    // -- 17d. bot channels Phase 2: the thread info pane drives channel
    // navigation ----------------------------------------------
    // Same relay rig, pane-shaped UI proof (bot-channels plan Phase 2):
    // the parent thread's header badge appears once the Channels ask
    // lands, the pane lists Beta's channel with its ↳ label, clicking
    // the row navigates the main chat area to the channel transcript
    // (selection-without-listing — the sidebar highlights the PARENT and
    // never lists the channel), the breadcrumb + composer hint mark the
    // channel view, and the crumb returns to the parent. The offline
    // ui_test pins the render shapes; this pins the live loop: the ask
    // riding the connect cascade, the replay through the ordinary Join
    // machinery, and the CSS being actually loaded.
    await test("bots: the thread info pane navigates per-parent channels", async () => {
      // The shared rig (see relayRig): bots, parent thread, relay send,
      // channel discovery + settle, children-first cleanup.
      const { alphaThread, betaThread, note, cleanup } = await relayRig(
        "Pane",
        "pane-note-9",
      );
      try {

        // The UI, on the parent: select Alpha's thread and wait for the
        // badge — proof the Channels ask rode the connect cascade.
        await page.goto(`${base}/?token=${TOKEN}`);
        await connected(page);
        await page
          .locator(
            `#thread-list .thread-row[data-thread-id="${alphaThread}"] .thread-main`,
          )
          .click();
        const badge = page.locator("#info-btn");
        await badge.waitFor({ timeout: 15_000 });
        // The discoverability hint rides the same data.
        eq(
          await page.locator("#hint-parent").count(),
          1,
          "pane hint points at the badge",
        );

        // Open the pane: one row, Beta's channel, ↳ label + age + chevron.
        await badge.click();
        const paneRow = page.locator(
          `.info-pop .ch[data-thread-id="${betaThread}"]`,
        );
        await paneRow.waitFor({ timeout: 15_000 });
        const rowText = await paneRow.textContent();
        assert(
          rowText.includes("↳ PaneBeta"),
          `row names the target bot: "${rowText}"`,
        );
        assert(rowText.includes("›"), `row carries the chevron: "${rowText}"`);
        eq(
          await page.locator(".info-pop .ch").count(),
          1,
          "exactly the one channel row",
        );

        // Selection-without-listing: the row navigates the main chat area
        // to the channel; the pane closes; the sidebar highlights the
        // PARENT and never lists the channel.
        await paneRow.click();
        await page
          .locator("#crumb")
          .waitFor({ timeout: 15_000 });
        eq(
          await page.locator("#layout").getAttribute("data-selected"),
          betaThread,
          "channel selected into the main chat area",
        );
        eq(
          await page.locator(".info-pop").count(),
          0,
          "pane closed on navigation",
        );
        eq(
          await page
            .locator(
              `#thread-list .thread-row.selected[data-thread-id="${alphaThread}"]`,
            )
            .count(),
          1,
          "parent row carries the highlight",
        );
        eq(
          await page.locator(`#thread-list .thread-row[data-thread-id="${betaThread}"]`).count(),
          0,
          "channel is not a sidebar row",
        );
        const crumb = await page.locator("#crumb").textContent();
        assert(crumb.startsWith("‹ "), `breadcrumb reads as back: "${crumb}"`);
        const hint = await page.locator("#hint-child").textContent();
        assert(
          hint.includes("bot channel of"),
          `composer hint names the parent context: "${hint}"`,
        );

        // The channel transcript is the real thing through the ordinary
        // replay path: Alpha's authored line renders as the collapsed bot
        // chip (the same shape the sidebar-joined channel renders).
        const botChip = page.locator("details.turn.bot");
        await botChip.waitFor({ timeout: 15_000 });
        const body = await botChip.evaluate(
          (el) => el.querySelector(".bot-body")?.textContent ?? "",
        );
        assert(body.includes("pane-note-9"), "chip body carries the note");

        // The crumb returns to the parent.
        await page.locator("#crumb").click();
        await poll(
          async () =>
            (await page.locator("#layout").getAttribute("data-selected")) ===
            alphaThread
              ? true
              : null,
          { timeout: 15_000, interval: 250, message: "crumb re-selects the parent" },
        );

        // Back/forward across a CHANNEL entry: the channel's url owns a
        // history entry (selection-without-listing pushes real urls),
        // but no sidebar row exists for it — the popstate click cannot
        // serve it, so the retry's expiry falls back to a full load of
        // the entry's url, which Flags.thread resolves (the pane path
        // re-marks breadcrumb + highlight). Forward to the channel and
        // land back in it.
        // Back from the parent lands on the CHANNEL entry — but no
        // sidebar row exists for it, so the popstate click cannot serve
        // it: the retry's expiry falls back to a full load of the
        // entry's url, which Flags.thread resolves (crumb + parent
        // highlight restored through the pane path).
        await page.goBack();
        await poll(
          async () =>
            (await page.locator("#layout").getAttribute("data-selected")) ===
            betaThread
              ? true
              : null,
          {
            timeout: 20_000,
            interval: 500,
            message: "back to the channel entry loads the channel (reload fallback)",
          },
        );
        await page.locator("#crumb").waitFor({ timeout: 15_000 });
        // Forward returns to the parent entry — an ordinary row, served
        // by the popstate click.
        await page.goForward();
        await poll(
          async () =>
            (await page.locator("#layout").getAttribute("data-selected")) ===
            alphaThread
              ? true
              : null,
          { timeout: 15_000, interval: 250, message: "forward returns to the parent" },
        );
      } finally {
        await cleanup();
      }
    });

    // -- 17e. tui-pairing Phase C: the info pane mints pairing URLs -----
    // The pane's Environments section against the workspace-rooted
    // instance: the creation roster row is what the section re-derives
    // from (the newest roster row wins — the server's own hydration
    // rule), the mint renders the ONE-TIME URL with the copy control and
    // the expiry countdown, the REAL public exchange redeems the code
    // from the DOM (no auth — the code is the auth), and revoke kills
    // both the row and the display, dead-code verified against the
    // merged 404. Hostile-text rendering of roster rows is pinned
    // offline (ui_test); existing selectors are untouched by the badge
    // reachability change (the pane renders for every selection now).
    await test("pairing: the info pane mints a pairing URL, exchanges, revokes", async () => {
      // Threads are bot-only (the create shape is {"bot": id}); the bot
      // must exist on the PAIR instance (registries never sync), so this
      // one can't ride the shared createBotThread helper.
      const pairBot = await createBot("smart", "pair-bot", pairBase);
      const created = await page.request.post(`${pairBase}/threads`, {
        headers: { authorization: `Bearer ${TOKEN}` },
        data: { bot: pairBot },
      });
      eq(created.status(), 201, "env thread created on the workspace instance");
      const thread = await created.json();

      try {
        await page.goto(`${pairBase}/?token=${TOKEN}`);
        await connected(page);
        await page
          .locator(
            `#thread-list .thread-row[data-thread-id="${thread.id}"] .thread-main`,
          )
          .click();
        // The badge renders for every selection (Phase C); open the pane.
        await page.locator("#info-btn").click();
        const mintBtn = page.locator("#pair-tui");
        await mintBtn.waitFor({ timeout: 15_000 });
        const roster = await page
          .locator(".info-pop .env-row")
          .first()
          .textContent();
        assert(
          roster.includes("workspace") && roster.includes("local workspace"),
          `roster row renders: "${roster}"`,
        );

        // Mint: the URL (the DISPLAY is one-time — the server stores
        // only the hash; the grant itself stays multi-use until expiry
        // or revocation), origin-corrected by pairing_js to the
        // BROWSING origin; code shape is 32 random bytes, URL-safe
        // base64 (43 chars, no padding).
        await mintBtn.click();
        const url = page.locator("#pair-url");
        await url.waitFor({ timeout: 15_000 });
        await poll(
          async () =>
            /\/pair\/[A-Za-z0-9_-]{43}$/.test(await url.textContent()),
          {
            timeout: 15_000,
            interval: 200,
            message: "pairing URL rendered (origin-corrected)",
          },
        );
        const code = await url.getAttribute("data-pair-url");
        assert(/^[A-Za-z0-9_-]{43}$/.test(code), `code shape: "${code}"`);
        eq(await page.locator("[data-pair-copy]").count(), 1, "copy button");
        const expiry = await page.locator("[data-expires]").textContent();
        assert(expiry.includes("expires in"), `expiry countdown: "${expiry}"`);

        // The REAL exchange with the DOM's code: no auth header — the
        // code is the auth — and the answer carries the pinned thread.
        // The node name is unique PER RUN: rows now CASCADE with their
        // thread (per-thread node names), so a static name would be
        // fine too — the Date.now() suffix just keeps runs independent
        // if a cleanup ever skips.
        const nodeName = `browser-pair-${Date.now()}`;
        const exchange = await page.request.post(`${pairBase}/nodes/pair`, {
          data: { code, name: nodeName },
        });
        eq(exchange.status(), 201, "public exchange accepted the minted code");
        const paired = await exchange.json();
        eq(paired.thread_id, thread.id, "exchange answers the pinned thread");
        assert(
          typeof paired.token === "string" && paired.token.length >= 40,
          "token answered ONCE, at exchange",
        );

        // The grants list reflects the exchange on the NEXT pane open
        // (the open re-asks; the use_count bump was a route-side
        // best-effort write this client never saw mid-session). Close
        // through the pane's own close control — the hit layer covers
        // the badge while the pane is up.
        await page.locator(".info-pop .close").click();
        await page.locator("#info-btn").click();
        await poll(
          async () =>
            (await page.locator(".info-pop .grant-row").textContent()).includes(
              "paired 1 TUI",
            ),
          {
            timeout: 15_000,
            interval: 250,
            message: "grant row shows the exchange's paired count",
          },
        );
        // "Shown once" is literal: the pane CLOSE retired the one-time
        // URL display — the server-component model outlives the pane,
        // and without the clear the live credential would re-render on
        // every reopen for the whole /ws connection.
        eq(await page.locator("#pair-url").count(), 0, "pane close retired the URL");
        eq(await page.locator("#pair-tui").count(), 1, "mint button is back");

        // Revoke: the worker deletes and re-reads — the grant row goes,
        // and the one-time display drops with it (a dead code must not
        // linger; the grant was single-redeemable here only because the
        // test revokes it, never because grants are single-use).
        await page.locator("[data-revoke-grant]").click();
        await poll(
          async () =>
            (await page.locator(".info-pop .grant-row").count()) === 0,
          { timeout: 15_000, interval: 200, message: "grant row gone" },
        );
        eq(await page.locator("#pair-url").count(), 0, "display dropped");

        // The revoked code is dead: the merged unknown/expired 404 (the
        // route must not become a code oracle).
        const after = await page.request.post(`${pairBase}/nodes/pair`, {
          data: { code, name: `${nodeName}-2` },
        });
        eq(after.status(), 404, "revoked code answers the merged 404");
      } finally {
        // The thread delete cascades its grant AND the node row (a
        // credential is bound to its thread — node_thread_id_fkey).
        await page.request.delete(`${pairBase}/threads/${thread.id}`, {
          headers: { authorization: `Bearer ${TOKEN}` },
        });
      }
    });

    // -- 18. utility tags: model title + tags land as inert chips --------
    // The ui-made thread's first exchange (providers test, above) armed
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
          const threads = (
            await (await page.request.get(`${base}/threads`, { headers })).json()
          ).threads;
          return threads.find((s) => s.title === "Fix login redirect loop") ?? false;
        },
        { timeout: 30_000, message: "utility title applied" },
      );
      eq(tagged.title_source, "auto", "model title applied through the auto path");
      eq(
        JSON.stringify(tagged.tags),
        JSON.stringify(["<script>alert('utility-t", "login"]),
        `model tags landed: ${tagged.tags}`,
      );
      // The sidebar learns about the apply from a MetaUpdated broadcast —
      // which only reaches clients joined to the thread — or from a fresh
      // threads load. The bots test's trailing reload raced this apply
      // (the branch was still held when it re-read the list), so re-load
      // now that the API confirms it and read the chips from a list that
      // cannot be stale.
      await page.goto(`${base}/?token=${TOKEN}`);
      await connected(page);
      // Chips render as text nodes: textContent carries the payload
      // verbatim, innerHTML carries it ESCAPED (no markup was parsed),
      // and no script element exists anywhere inside the component's
      // shadow root — where rendered model output lives.
      const row = page.locator(`.thread-row[data-thread-id="${tagged.id}"]`);
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

    // -- 18b. url bar mirrors the selection ---------------------------------
    // thread_js (page shell): the address bar names the selected thread
    // (/threads/<id> — the RESTful app view), user-driven switches push
    // history entries, popstate re-opens the named thread through the
    // same Select path a real click uses, and a pasted link (fresh
    // context, no storage) boots straight into the named thread.
    await test("url: address bar follows the selection; links share; back/forward walks history", async () => {
      const headers = { authorization: `Bearer ${TOKEN}` };
      const made1 = await createBotThread("smart", "url-bot-1");
      const made2 = await createBotThread("fast", "url-bot-2");
      const t1 = made1.thread;
      const t2 = made2.thread;
      try {
        // An API-side create is invisible to a running client (the list
        // refreshes on own creates and joined broadcasts only), so reload
        // to fetch a fresh list. The boot restores this tab's stored
        // selection and rewrites the load entry — exactly the baseline
        // the assertions below start from.
        await page.goto(`${base}/?token=${TOKEN}`);
        await connected(page);
        const row1 = page.locator(
          `#thread-list .thread-row[data-thread-id="${t1.id}"] .thread-main`,
        );
        const row2 = page.locator(
          `#thread-list .thread-row[data-thread-id="${t2.id}"] .thread-main`,
        );
        await poll(async () => (await row1.count()) === 1 && (await row2.count()) === 1, {
          timeout: 15_000,
          message: "new rows in sidebar",
        });

        // The address bar already names the current selection: the
        // utility test's plain reload restored it from storage and the
        // boot write rewrote the load entry (replaceState, no push).
        const at = (id) => new URL(page.url()).pathname === `/threads/${id}`;
        const id0 = await selectedId(page);
        assert(id0, "a thread is selected");
        assert(at(id0), `url names the selection: ${page.url()}`);

        // A user-driven switch pushes a fresh history entry.
        await row1.click();
        await poll(async () => (await selectedId(page)) === t1.id, {
          timeout: 15_000,
          message: "t1 selected",
        });
        await poll(async () => at(t1.id), {
          timeout: 15_000,
          message: "url follows t1",
        });
        await row2.click();
        await poll(async () => (await selectedId(page)) === t2.id, {
          timeout: 15_000,
          message: "t2 selected",
        });
        await poll(async () => at(t2.id), {
          timeout: 15_000,
          message: "url follows t2",
        });

        // Back re-opens t1: popstate drives the server's Select path
        // through a synthetic click on the row (subscribe + replay), and
        // the url is never rewritten on the way.
        await page.goBack();
        await poll(async () => (await selectedId(page)) === t1.id, {
          timeout: 15_000,
          message: "back re-opened t1",
        });
        assert(at(t1.id), `back lands on t1's url: ${page.url()}`);
        await page.goForward();
        await poll(async () => (await selectedId(page)) === t2.id, {
          timeout: 15_000,
          message: "forward re-opened t2",
        });

        // Back to a row the sidebar currently HIDES: with a non-matching
        // tag filter, t1's row is not in the DOM, so the popstate handler
        // clears the filter first and clicks the row when it renders.
        await page.fill("#tag-filter", "zzz-no-match");
        await poll(async () => !(await row1.isVisible()), {
          timeout: 10_000,
          message: "t1 hidden by the filter",
        });
        await page.goBack();
        await poll(async () => (await selectedId(page)) === t1.id, {
          timeout: 15_000,
          message: "back un-hid and re-opened t1",
        });
        eq(
          await page.locator("#tag-filter").inputValue(),
          "",
          "fallback cleared the filter",
        );

        // A pasted link boots into exactly the named thread — the page
        // url names it and must OUTRANK the tab's stored selection, so
        // the peer context is seeded with a competing storage entry
        // (t2) before the /threads/t1 navigation. The RESTful path form
        // is the primary shape; a legacy ?thread= link must keep working
        // AND upgrade to the path form once its thread is live.
        const peer = await browser.newContext({ viewport: { width: 1280, height: 900 } });
        const ppage = await peer.newPage();
        track(ppage);
        const legacy = await browser.newContext({ viewport: { width: 1280, height: 900 } });
        const lpage = await legacy.newPage();
        track(lpage);
        try {
          // Seed a competing stored selection: load the app plainly, wait
          // for its auto-selection to settle into storage, then overwrite
          // it with t2. The /threads/t1 navigation below may only open t1
          // if the url beats storage.
          await ppage.goto(`${base}/?token=${TOKEN}`);
          await connected(ppage);
          await poll(async () => {
            const sel = await selectedId(ppage);
            return sel !== "" && (await ppage.evaluate(() => sessionStorage.getItem("nexus.thread"))) === sel;
          }, { timeout: 15_000, message: "peer context selection settled into storage" });
          await ppage.evaluate((id) => sessionStorage.setItem("nexus.thread", id), t2.id);
          await ppage.goto(`${base}/threads/${t1.id}?token=${TOKEN}`);
          await connected(ppage);
          await poll(async () => (await selectedId(ppage)) === t1.id, {
            timeout: 15_000,
            message: "pasted link opened t1 over the stored t2",
          });
          eq(new URL(ppage.url()).pathname, `/threads/${t1.id}`, "pasted path url kept");

          // Legacy link: opens the same thread, and the first url write
          // (the stamp-clearing in-place rewrite) upgrades the address.
          await lpage.goto(`${base}/?token=${TOKEN}&thread=${t1.id}`);
          await connected(lpage);
          await poll(async () => (await selectedId(lpage)) === t1.id, {
            timeout: 15_000,
            message: "legacy link opened t1",
          });
          await poll(async () => new URL(lpage.url()).pathname === `/threads/${t1.id}`, {
            timeout: 15_000,
            message: "legacy link upgraded to path form",
          });
          assert(!new URL(lpage.url()).searchParams.has("thread"), "legacy param dropped");
        } finally {
          await peer.close();
          await legacy.close();
        }

        // Restore the suite's working selection.
        await page
          .locator(`#thread-list .thread-row[data-thread-id="${id0}"] .thread-main`)
          .click();
        await poll(async () => (await selectedId(page)) === id0, {
          timeout: 15_000,
          message: "original selection restored",
        });
      } finally {
        // Suite cleanup is load-bearing (a shared database): a silent
        // failure here would leak threads into every later run.
        const gone1 = await page.request.delete(`${base}/threads/${t1.id}`, { headers });
        eq(gone1.status(), 204, "t1 deleted");
        const gone2 = await page.request.delete(`${base}/threads/${t2.id}`, { headers });
        eq(gone2.status(), 204, "t2 deleted");
        const botGone1 = await page.request.delete(`${base}/bots/${made1.botId}`, { headers });
        eq(botGone1.status(), 204, "url bot 1 deleted");
        const botGone2 = await page.request.delete(`${base}/bots/${made2.botId}`, { headers });
        eq(botGone2.status(), 204, "url bot 2 deleted");
      }
    });

    // -- 18c. faults: mid-stream disconnect rollback & 429 retry prefix -----
    // Verification plan Phase 2: prove that upstream stream drops roll back
    // uncommitted UI lines while keeping committed history intact, and that
    // HTTP 429 errors render cleanly and let a retry resend a byte-identical
    // request prefix.
    await test("faults: mid-stream disconnect rolls back; 429 renders error and retry preserves prefix", async () => {
      const headers = { authorization: `Bearer ${TOKEN}` };
      const made = await createBotThread("smart", "fault-bot");
      const faultThread = made.thread;
      services.setRateLimitFail(true);
      try {
        await page.goto(`${base}/threads/${faultThread.id}?token=${TOKEN}`);
        await connected(page);
        await poll(async () => (await selectedId(page)) === faultThread.id, {
          timeout: 15_000,
          message: "fault thread selected",
        });

        // 1. Committed baseline turn.
        const baselinePrompt = "case:text baseline before faults";
        await sendAndWaitIdle(page, baselinePrompt);
        eq(await page.locator(".turn.user").count(), 1, "baseline user bubble");
        eq(await page.locator(".turn.assistant").count(), 1, "baseline assistant bubble");
        const baselineReq = services.requests.findLast(
          (r) =>
            r.url === "/v1/chat/completions" &&
            !r.body.includes(UTILITY_DELTA) &&
            r.body.includes(baselinePrompt),
        );
        assert(baselineReq, "recorded baseline chat request");

        // 2. Mid-stream disconnect: partial tokens stream, TCP drops without
        //    [DONE] -> UI surfaces `.note.err` and rolls back uncommitted
        //    lines while keeping the committed baseline intact (and durable).
        await page.fill("#input", "case:disconnect drop mid-stream");
        await page.press("#input", "Enter");
        await poll(
          async () => {
            const notes = await page.locator(".note.err").allTextContents();
            const idle = await page.locator("#send").evaluate((el) => !el.disabled);
            return idle && notes.some((n) => n.includes("turn failed:"));
          },
          { timeout: 30_000, message: "disconnect surfaced turn-failed note and re-enabled send" },
        );
        // Live rollback contract (AGENTS.md + ui.gleam): a failed turn rolls
        // back to the user line — the partial assistant bubble is discarded
        // while the user line remains visible above the error note, and
        // nothing commits server-side (proved by reload below).
        const assistantsAfterDrop = await page.locator(".turn.assistant").allTextContents();
        eq(assistantsAfterDrop.length, 1, "partial disconnect assistant bubble rolled back");
        assert(
          assistantsAfterDrop.every((t) => !t.includes("Partial uncommitted")),
          `partial disconnect text rolled back: ${assistantsAfterDrop}`,
        );
        assert(
          assistantsAfterDrop.some((t) => t.includes("Plain answer")),
          `baseline assistant kept after disconnect: ${assistantsAfterDrop}`,
        );
        // Reload proves the partial disconnect output never persisted: the
        // user prompt committed at Send (preserving prefix monotonicity),
        // while the failed turn's assistant output rolled back completely.
        await page.reload();
        await connected(page);
        await poll(async () => (await selectedId(page)) === faultThread.id, {
          timeout: 15_000,
          message: "fault thread re-opened after disconnect reload",
        });
        await poll(async () => (await page.locator(".turn.user").count()) === 2, {
          timeout: 15_000,
          message: "baseline + disconnect user prompts replayed after reload",
        });
        const assistantsAfterReload = await page.locator(".turn.assistant").allTextContents();
        eq(assistantsAfterReload.length, 1, "only baseline assistant persisted after disconnect");
        assert(
          assistantsAfterReload[0].includes("Plain answer"),
          `baseline assistant replayed after disconnect: ${assistantsAfterReload}`,
        );

        // 3. Non-200 / HTTP 429 rate-limit error: renders cleanly with status
        //    + body snippet and commits no assistant output.
        const rateLimitPrompt = "case:ratelimit transient 429 retry";
        const reqsBefore429 = services.requests.length;
        await page.fill("#input", rateLimitPrompt);
        await page.press("#input", "Enter");
        await poll(
          async () => {
            const notes = await page.locator(".note.err").allTextContents();
            const idle = await page.locator("#send").evaluate((el) => !el.disabled);
            return (
              idle &&
              notes.some(
                (n) => n.includes("429") && n.includes("rate limit exceeded"),
              )
            );
          },
          { timeout: 30_000, message: "429 rate-limit error rendered cleanly" },
        );
        eq(await page.locator(".turn.assistant").count(), 1, "no assistant line on 429 failure");
        const failed429Req = services.requests
          .slice(reqsBefore429)
          .find(
            (r) =>
              r.url === "/v1/chat/completions" &&
              !r.body.includes(UTILITY_DELTA) &&
              r.body.includes(rateLimitPrompt),
          );
        assert(failed429Req, "recorded failed 429 chat request");
        assert(
          extendsRequest(baselineReq.body, failed429Req.body),
          "429 request extends committed baseline prefix byte-for-byte",
        );

        // 4. Retry after the 429 clears: succeeds AND extends the prior
        //    request's prefix byte-for-byte (never mutating earlier messages).
        services.setRateLimitFail(false);
        const reqsBeforeRetry = services.requests.length;
        await sendAndWaitIdle(page, rateLimitPrompt);
        const assistantsAfterRetry = await page.locator(".turn.assistant").allTextContents();
        assert(
          assistantsAfterRetry.some((t) => t.includes("Recovered after rate limit")),
          `retry answer rendered: ${assistantsAfterRetry}`,
        );
        const retryReq = services.requests
          .slice(reqsBeforeRetry)
          .find(
            (r) =>
              r.url === "/v1/chat/completions" &&
              !r.body.includes(UTILITY_DELTA) &&
              r.body.includes(rateLimitPrompt),
          );
        assert(retryReq, "recorded retry chat request");
        assert(
          extendsRequest(failed429Req.body, retryReq.body),
          "retry after 429 extends the failed request prefix byte-for-byte",
        );
        assert(
          extendsRequest(baselineReq.body, retryReq.body),
          "retry extends committed baseline request prefix byte-for-byte",
        );
        // Reload proves only the two completed assistant replies persisted
        // (neither the mid-stream disconnect nor the 429 committed partial text).
        await page.reload();
        await connected(page);
        await poll(async () => (await page.locator(".turn.assistant").count()) === 2, {
          timeout: 15_000,
          message: "baseline + recovered assistant turns replayed after reload",
        });
        eq(await page.locator(".turn.user").count(), 4, "all four sent user prompts persisted");
      } finally {
        services.setRateLimitFail(true);
        // Non-throwing cleanup so a cleanup hiccup never masks the original
        // test failure inside `try`.
        const gone = await page.request
          .delete(`${base}/threads/${faultThread.id}`, { headers })
          .catch(() => null);
        const botGone = await page.request
          .delete(`${base}/bots/${made.botId}`, { headers })
          .catch(() => null);
        if (gone?.status() !== 204 || botGone?.status() !== 204) {
          console.warn(
            `fault-test cleanup incomplete: thread=${gone?.status() ?? "err"} bot=${botGone?.status() ?? "err"}`,
          );
        }
      }
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
    await pair.stop();
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
