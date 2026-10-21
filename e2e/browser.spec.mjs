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
//   4. text-only turn (streaming → completed, metrics)
//   5. stop during streaming (partial commit, stopped metric)
//   6. reconnect/replay: full tool history re-rendered after reload
//   7. http_fetch + web_search loops with typed tool cards
//   8. iteration-guard terminal rendering (max=2 instance)
//   9. byte-identical request prefixes turn-over-turn (fake records them)
//  10. mobile viewport: a second context gets an independent per-client
//      runtime (own selection, non-mirroring panels, reload restores its
//      own session) with no horizontal overflow with tool cards
//  11. connection dot: red while the backend is down, green on reconnect
//  12. provider management end-to-end (multi-provider P5): create a
//      provider in the Providers panel, pick it in the create panel
//      (aliases reload per provider), pin a session to it, stream a turn,
//      and hit the delete/disable guard rails
//
// Usage: node e2e/browser.spec.mjs   (see e2e/README.md)

import { spawn } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, writeFileSync } from "node:fs";
import { chromium } from "playwright";
import { startServices } from "./services.mjs";

const ROOT = new URL("..", import.meta.url).pathname;
const TOKEN = "e2e-token";
const results = [];
let current = null;
// Hoisted so failure diagnostics (dumpPageState) can reach the live page.
let page = null;

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

// The per-client selection mirror (`#layout[data-selected]`, persisted
// client-side by the page shell and re-supplied on the /ws route).
async function selectedId(p) {
  return await p.locator("#layout").evaluate((el) => el.getAttribute("data-selected") || "");
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
    page.on("pageerror", (err) => console.log(`  [pageerror] ${err}`));
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

      // Manual rename through the inline editor pins the title.
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

      // Tags through the inline editor render as chips.
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
      await smartRow.getByRole("button", { name: "Restore", exact: true }).click();
      await poll(async () => await smartRow.locator(".session-main").isVisible(), {
        timeout: 10_000,
        message: "restored row back in the list",
      });
      // Restored sessions are active again: the pin control is back (the
      // pin itself stays cleared until re-pinned).
      await poll(
        async () =>
          await smartRow.getByRole("button", { name: "Pin", exact: true }).isVisible(),
        { timeout: 10_000, message: "pin control back after restore" },
      );

      // Delete the fast session: two-step confirm, hard removal.
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

    // -- 4. text-only turn ---------------------------------------------------
    await test("turn: text-only round streams and completes with metrics", async () => {
      await sendAndWaitIdle(page, "case:text just answer");
      const user = await page.$$eval(".turn.user", (els) => els.map((e) => e.textContent));
      assert(user.some((t) => t.includes("case:text")), `user bubble: ${user}`);
      const assistant = await page.$$eval(".turn.assistant", (els) => els.map((e) => e.textContent));
      assert(assistant.some((t) => t.includes("Plain answer")), `assistant text: ${assistant}`);
      const metrics = await page.$$eval("#metrics .metric", (els) => els.map((e) => e.textContent));
      assert(metrics.some((m) => m.includes("completed")), `completed metric: ${metrics}`);
      assert(metrics.some((m) => m.includes("cached 800/1000")), `cached tokens visible: ${metrics}`);
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
      const metrics = await page.$$eval("#metrics .metric", (els) => els.map((e) => e.textContent));
      assert(metrics.some((m) => m.includes("stopped")), `stopped metric: ${metrics}`);
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
      }));
      eq(info.tool, "http_fetch", "tool name");
      eq(info.status, "completed", "terminal status");
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
    });

    // -- 7. web_search tool loop -----------------------------------------------
    await test("tools: web_search card completes with stub result", async () => {
      await sendAndWaitIdle(page, "case:search look it up");
      const card = page.locator(".turn.tool[data-tool='web_search']");
      await card.first().waitFor({ timeout: 30_000 });
      await card
        .first()
        .locator(".tool-status")
        .filter({ hasText: "completed" })
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
        })),
      );
      const fetchCards = cards.filter((c) => c.tool === "http_fetch");
      const searchCards = cards.filter((c) => c.tool === "web_search");
      assert(fetchCards.length === 2, `two fetch cards replayed: ${JSON.stringify(cards)}`);
      eq(searchCards.length, 1, "one search card replayed");
      assert(cards.every((c) => c.status === "completed" && c.hasResult), "all replayed cards completed with results");
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
      // Requests from the two nexus instances interleave in one log; a
      // request that does not extend the previous one starts a new chain
      // (one chain per session). Every chain must grow by suffix only.
      const chains = [];
      for (const chat of chats) {
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
      await dpage.goto(`${base}/?token=${TOKEN}`);
      await connected(dpage);
      await dpage.waitForSelector("#session-list .session-main", { timeout: 30_000 });

      const mobile = await browser.newContext({ viewport: { width: 390, height: 844 } });
      const mpage = await mobile.newPage();
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
      await ipage.goto(`${guardBase}/?token=${TOKEN}`);
      await connected(ipage);

      await guard.stop();
      await ipage.waitForSelector("#status.off", { timeout: 15_000 });
      eq(
        await ipage.locator("#status").evaluate((el) => el.textContent),
        "○",
        "dot glyph while offline",
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
      await ctx.close();
    });

    // -- 13. provider management + provider→model picker (P5) ---------------
    // The P5 acceptance, end to end through the real UI: create a
    // provider in the Providers panel, pick it in the create panel
    // (model aliases reload per provider), create a session pinned to
    // it, and stream a turn. Then the guard rails: the delete is
    // refused while the new session pins the provider, and disable/
    // enable flip the picker.
    await test("providers: create in UI, pick, pin a session, stream a turn", async () => {
      // Back on the MAIN instance: test 10 navigated `page` to the guard
      // instance, and the indicator test used its own context.
      await page.goto(`${base}/?token=${TOKEN}`);
      await connected(page);
      const fakeUrl = `http://127.0.0.1:${services.bifrostPort}/v1`;

      // The panel lists the seeded keyless provider.
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

      // Pick it in the create panel: the model aliases reload scoped to
      // the selection, and the session pins (provider, model).
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
      // 409 semantics) and surfaces as a note.
      await madeRow.getByRole("button", { name: "Delete", exact: true }).click();
      await madeRow.getByRole("button", { name: "Delete forever", exact: true }).click();
      await poll(
        async () =>
          (await page.locator(".note.err").last().textContent())
            ?.includes("provider is still pinned by sessions"),
        { timeout: 15_000, message: "409 guard note after pinned delete" },
      );
      await poll(async () => await madeRow.isVisible(), {
        timeout: 10_000,
        message: "pinned provider row survives refused delete",
      });

      // Disable: the row badges as disabled and the picker drops it.
      await madeRow.getByRole("button", { name: "Disable", exact: true }).click();
      await poll(
        async () => (await madeRow.locator(".badge.off").textContent()) === "disabled",
        { timeout: 15_000, message: "disabled badge" },
      );
      await poll(
        async () => (await page.locator("#provider-picker option").count()) === 1,
        { timeout: 15_000, message: "picker drops disabled provider" },
      );
      // Disabling blocks new resolutions, not the already-frozen session
      // endpoint — the pinned session keeps streaming either way.
      await madeRow.getByRole("button", { name: "Enable", exact: true }).click();
      await poll(
        async () => (await page.locator("#provider-picker option").count()) === 2,
        { timeout: 15_000, message: "re-enabled provider back in picker" },
      );
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
