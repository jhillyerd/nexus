// e2e node-TUI suite (environments plan Phase 2b-5) — validation only.
//
// The fake-node suite (node.spec.mjs) proves the SERVER side of the
// /node/ws protocol with a hand-written peer. This suite proves the
// GLEAM node TUI (gleam run -m nexus/tui) end to end: the real binary,
// piped stdin, against the real server and real thread actor —
//
//   1. the TUI joins (rendered hello + replay lines on ITS stdout) and
//      its attach lands the growing roster line server-side;
//   2. a typed line drives a full remote tool round: the model calls
//      bash(target=tui-node) → tools/call down → the TUI executes the
//      command LOCALLY (in its own workspace dir) → its response frame
//      commits as the tool row → round-2 answer embeds the marker —
//      with the TUI's own stdout showing the rendered chips;
//   3. stdin EOF is a graceful /quit: the process exits 0 and the
//      queued detach line lands behind the turn.
//
// Plus (tui-pairing plan Phase B) the bin/nexus-tui LAUNCHER: grants
// seeded straight into the store (there is deliberately no HTTP mint
// route — the web UI mints them, Phase C), then the whole credential
// life against a second node name — exchange → 0600 state file →
// stored-credential relaunch (same node row, replay) → revoked
// credential refuses with exit 4 → a fresh pairing URL re-pairs.
//
// Same loopback posture as node.spec.mjs: fake OpenAI SSE provider
// scripting the env-tool turn (`case:nodebash`), Postgres on loopback,
// no Playwright, no network beyond loopback.
//
// Usage: node e2e/tui.spec.mjs
// Preconditions: Postgres on 127.0.0.1:5433 with the schema applied
// (docker compose up -d + migrate — see e2e/README.md). The TUI must
// already be built (`gleam build`), or the first run pays the compile.
// Writes e2e/tui-report.json; exits non-zero on any failure.

import { spawn } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer } from "node:http";

const ROOT = new URL("..", import.meta.url).pathname;
const TOKEN = "smoke-token-tui-" + Date.now();
const NODE_NAME = "tui-node";
const PAIR_NODE = "tui-pair-node";
const PORT = 18091;
const BASE = `http://127.0.0.1:${PORT}`;
const ENC_KEY = "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=";
const DATABASE_URL =
  process.env.E2E_DATABASE_URL ?? "postgres://nexus@127.0.0.1:5433/nexus";

const results = [];
function check(name, fn) {
  return fn()
    .then((value) => {
      results.push({ name, ok: true });
      console.log(`ok   ${name}`);
      return value;
    })
    .catch((err) => {
      results.push({ name, ok: false, error: err.message });
      console.error(`FAIL ${name}: ${err.message}`);
      throw err;
    });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

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
    await sleep(interval);
  }
  throw new Error(`poll timeout: ${message}${lastErr ? ` (last: ${lastErr.message})` : ""}`);
}

// ---------------------------------------------------------------------------
// Harness: shared plumbing with node.spec.mjs (duplicated on purpose —
// each spec is standalone and validation-only).
// ---------------------------------------------------------------------------

function resetDatabase() {
  return new Promise((resolve, reject) => {
    const child = spawn(
      "psql",
      ["-q", DATABASE_URL, "-c", "truncate thread_message, thread, bot, node, provider cascade;"],
      { stdio: ["ignore", "pipe", "pipe"] },
    );
    let out = "";
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (out += d));
    child.on("error", (err) => reject(new Error(`psql not found (${err.message})`)));
    child.on("exit", (code) =>
      code === 0 ? resolve() : reject(new Error(`database reset failed (${code}):\n${out}`)),
    );
  });
}

/// The fake OpenAI-compatible provider. The `nodebash` scenario streams
/// a bash tool call whose target is THIS suite's node; round 2 answers
/// from the tool result, proving the TUI's execution bytes reached the
/// model. The argument JSON is deliberately NONCANONICAL — the TUI
/// re-encodes the parsed value (execution reads values, not bytes),
/// and the round proves exactly that.
function startFakeProvider() {
  let callSeq = 0;
  const server = createServer((req, res) => {
    const url = new URL(req.url, "http://127.0.0.1");
    if (req.method === "GET" && url.pathname === "/v1/models") {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ data: [{ id: "smart" }] }));
      return;
    }
    if (req.method === "POST" && url.pathname === "/v1/chat/completions") {
      let body = "";
      req.on("data", (c) => (body += c));
      req.on("end", () => {
        const request = JSON.parse(body);
        const lastUserIndex = request.messages.findLastIndex((m) => m.role === "user");
        const lastUser = request.messages[lastUserIndex];
        const userText = String(lastUser?.content ?? "");
        const scenario = /case:(\w+)/.exec(userText)?.[1] ?? "text";
        const toolDone = request.messages
          .slice(lastUserIndex + 1)
          .some((m) => m.role === "tool");
        callSeq += 1;
        const callId = `call_${callSeq}`;

        res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache" });
        const sse = (obj) => res.write(`data: ${JSON.stringify(obj)}\n\n`);
        const chunk = (delta, finish = null) => ({
          id: `chatcmpl-${callId}`,
          object: "chat.completion.chunk",
          created: 1,
          model: "smart",
          choices: [{ index: 0, delta, finish_reason: finish }],
        });
        const finish = () => {
          sse(chunk({}, "stop"));
          sse({
            id: `chatcmpl-${callId}`,
            object: "chat.completion.chunk",
            created: 1,
            model: "smart",
            choices: [],
            usage: {
              prompt_tokens: 90,
              completion_tokens: 18,
              total_tokens: 108,
              prompt_tokens_details: { cached_tokens: 80 },
            },
          });
          res.write("data: [DONE]\n\n");
          res.end();
        };

        if (scenario === "nodebash" && !toolDone) {
          const marker = /marker:(\S+)/.exec(userText)?.[1] ?? "plain";
          // touch proves the command ran with cwd = the TUI's workspace
          // (the marker file is asserted there, and absent from the
          // server's workspace).
          const args = `{  "command" : "echo ${marker} && touch tui-e2e-marker" , "target":"${NODE_NAME}"}`;
          sse(chunk({ role: "assistant", content: "" }));
          sse(chunk({ tool_calls: [{ index: 0, id: callId, type: "function", function: { name: "bash", arguments: "" } }] }));
          sse(chunk({ tool_calls: [{ index: 0, function: { arguments: args } }] }));
          sse(chunk({}, "tool_calls"));
          finish();
          return;
        }
        if (scenario === "nodebash" && toolDone) {
          const toolMsg = request.messages.findLast((m) => m.role === "tool");
          sse(chunk({ role: "assistant", content: "" }));
          res.write(`data: ${JSON.stringify(chunk({ content: "the node replied: " + String(toolMsg?.content ?? "") }))}\n\n`);
          finish();
          return;
        }
        // Default: a plain text answer.
        sse(chunk({ role: "assistant", content: "" }));
        sse(chunk({ content: "plain answer" }));
        finish();
      });
      return;
    }
    res.writeHead(404);
    res.end("not found");
  });
  return new Promise((resolve) =>
    server.listen(0, "127.0.0.1", () =>
      resolve({ port: server.address().port, close: () => new Promise((d) => server.close(() => d())) }),
    ),
  );
}

function seedProvider(port) {
  const env = {
    ...process.env,
    DATABASE_URL,
    NEXUS_ENCRYPTION_KEY: ENC_KEY,
    NEXUS_SEED_PROVIDER_NAME: "faketui",
    NEXUS_SEED_PROVIDER_BASE_URL: `http://127.0.0.1:${port}/v1`,
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
      code === 0 ? resolve() : reject(new Error(`dev_seed failed (${code}):\n${out}`)),
    );
  });
}

function startNexus(providerPort, workspaceRoot) {
  // Derive the server's Postgres settings from the selected database
  // URL — reset/seed already honor E2E_DATABASE_URL, so a non-default
  // URL must not leave the server pointed at the default database
  // (cubic PR review).
  const pg = new URL(DATABASE_URL);
  const env = {
    ...process.env,
    NEXUS_ENCRYPTION_KEY: ENC_KEY,
    NEXUS_HTTP_BIND: "127.0.0.1",
    NEXUS_HTTP_PORT: String(PORT),
    NEXUS_UI_TOKEN: TOKEN,
    NEXUS_MAX_TOOL_ITERATIONS: "8",
    NEXUS_WORKSPACE_ROOT: workspaceRoot,
    NEXUS_ENV_TIMEOUT_MS: "20000",
    NEXUS_SYSTEM_PROMPT: "You are nexus under the node-TUI e2e test.",
    NEXUS_PG_HOST: pg.hostname,
    NEXUS_PG_PORT: pg.port || "5432",
    NEXUS_PG_DATABASE: pg.pathname.slice(1),
    NEXUS_PG_USER: decodeURIComponent(pg.username),
    ...(pg.password ? { NEXUS_PG_PASSWORD: decodeURIComponent(pg.password) } : {}),
  };
  const child = spawn("gleam", ["run"], {
    cwd: ROOT,
    env,
    stdio: ["ignore", "pipe", "pipe"],
    detached: true,
  });
  const log = [];
  const collect = (s) => s.on("data", (d) => log.push(d.toString()));
  collect(child.stdout);
  collect(child.stderr);
  return {
    log: () => log.join(""),
    stop: () =>
      new Promise((done) => {
        child.on("exit", () => done());
        try {
          process.kill(-child.pid, "SIGTERM");
        } catch {
          try {
            child.kill("SIGTERM");
          } catch {
            /* already gone */
          }
        }
        setTimeout(done, 3000);
      }),
  };
}

async function waitHealthy() {
  await poll(
    async () => {
      try {
        const res = await fetch(`${BASE}/healthz`);
        return res.ok;
      } catch {
        return false;
      }
    },
    { timeout: 60_000, message: "nexus never became healthy" },
  );
}

async function api(method, path, body) {
  const res = await fetch(BASE + path, {
    method,
    headers: {
      authorization: `Bearer ${TOKEN}`,
      ...(body !== undefined ? { "content-type": "application/json" } : {}),
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  return { status: res.status, body: text ? JSON.parse(text) : null };
}

async function threadState(id) {
  const { status, body } = await api("GET", `/threads/${id}/state`);
  if (status !== 200) throw new Error(`state fetch failed: ${status}`);
  return body;
}

// ---------------------------------------------------------------------------
// The TUI under test: the real binary, piped stdin.
// ---------------------------------------------------------------------------

function startTui(thread, nodeToken, workspace) {
  const env = {
    ...process.env,
    NEXUS_URL: BASE,
    NEXUS_NODE: NODE_NAME,
    NEXUS_NODE_TOKEN: nodeToken,
    NEXUS_THREAD: thread,
    NEXUS_NODE_WORKSPACE: workspace,
  };
  const child = spawn("gleam", ["run", "-m", "nexus/tui"], {
    cwd: ROOT,
    env,
    stdio: ["pipe", "pipe", "pipe"],
  });
  const out = [];
  const errOut = [];
  child.stdout.on("data", (d) => out.push(d.toString()));
  child.stderr.on("data", (d) => errOut.push(d.toString()));
  return {
    child,
    stdout: () => out.join(""),
    stderr: () => errOut.join(""),
    send: (line) => child.stdin.write(line + "\n"),
    end: () => child.stdin.end(),
    waitExit: () =>
      new Promise((resolve, reject) => {
        const timer = setTimeout(
          () => reject(new Error(`tui did not exit (stderr: ${errOut.join("")})`)),
          30_000,
        );
        child.on("exit", (code) => {
          clearTimeout(timer);
          resolve(code);
        });
      }),
  };
}

// ---------------------------------------------------------------------------
// Phase B under test: the bin/nexus-tui launcher (pairing URL → 0600
// state file → stored-credential relaunch → re-pair), tui-pairing plan.
// ---------------------------------------------------------------------------

function sha256hex(text) {
  return createHash("sha256").update(text).digest("hex");
}

/// Grants enter the store directly (psql): the exchange's own auth is
/// the code, and no HTTP mint route exists by design — the web UI
/// mints through the server component (Phase C). The hash is the
/// node.hash_token discipline: hex SHA-256 of the plaintext code.
function seedGrant(code, threadId) {
  return new Promise((resolve, reject) => {
    const child = spawn(
      "psql",
      [
        "-q",
        DATABASE_URL,
        "-v",
        "ON_ERROR_STOP=1",
        "-c",
        `insert into node_grant (id, code_hash, thread_id, created_at, expires_at) ` +
          `values ('g-e2e-${sha256hex(code).slice(0, 8)}', '${sha256hex(code)}', ` +
          `'${threadId}', now(), now() + interval '1 hour');`,
      ],
      { stdio: ["ignore", "pipe", "pipe"] },
    );
    let out = "";
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (out += d));
    child.on("error", (err) => reject(new Error(`psql not found (${err.message})`)));
    child.on("exit", (code_) =>
      code_ === 0 ? resolve() : reject(new Error(`grant seed failed (${code_}):\n${out}`)),
    );
  });
}

/// The launcher's own keying: authority (host:port), filename-safe,
/// inside <XDG_STATE_HOME>/nexus — mirrored from bin/nexus-tui.
function stateFileFor(stateHome, base, node) {
  const authority = base.replace(/^https?:\/\//, "").split("/")[0];
  const key = authority.replace(/[^a-zA-Z0-9._-]/g, "-");
  return join(stateHome, "nexus", `tui-${key}-${node}.json`);
}

function startLauncher({ stateHome, args = [], pairUrlEnv = null }) {
  // The point of Phase B: NO NEXUS_URL, NEXUS_UI_TOKEN, or NEXUS_THREAD —
  // the pairing URL (arg or NEXUS_PAIR_URL) and then the state file
  // carry the server, token, and thread.
  const env = {
    ...process.env,
    NEXUS_NODE: PAIR_NODE,
    XDG_STATE_HOME: stateHome,
    NEXUS_NODE_WORKSPACE: pairWorkspace,
  };
  if (pairUrlEnv) env.NEXUS_PAIR_URL = pairUrlEnv;
  const child = spawn(join(ROOT, "bin", "nexus-tui"), args, {
    cwd: ROOT,
    env,
    stdio: ["pipe", "pipe", "pipe"],
    detached: true,
  });
  const out = [];
  const errOut = [];
  child.stdout.on("data", (d) => out.push(d.toString()));
  child.stderr.on("data", (d) => errOut.push(d.toString()));
  return {
    child,
    stdout: () => out.join(""),
    stderr: () => errOut.join(""),
    quit: () => {
      child.stdin.write("/quit\n");
      child.stdin.end();
    },
    waitExit: () =>
      new Promise((resolve, reject) => {
        const timer = setTimeout(
          () =>
            reject(
              new Error(
                `launcher did not exit (stdout: ${out.join("")} stderr: ${errOut.join("")})`,
              ),
            ),
          60_000,
        );
        child.on("exit", (code) => {
          clearTimeout(timer);
          resolve(code);
        });
      }),
    /// Simulate a crash / closed terminal: SIGKILL the whole group
    /// (bash + gleam + BEAM). The stored credential must survive it.
    killTree: () => {
      try {
        process.kill(-child.pid, "SIGKILL");
      } catch {
        try {
          child.kill("SIGKILL");
        } catch {
          /* already gone */
        }
      }
    },
  };
}

async function pairNodeRows() {
  const { status, body } = await api("GET", "/nodes");
  if (status !== 200) throw new Error(`nodes fetch failed: ${status}`);
  return body.nodes.filter((n) => n.name === PAIR_NODE);
}

// ---------------------------------------------------------------------------
// The suite
// ---------------------------------------------------------------------------

let nexus = null;
let provider = null;
let pairWorkspace = null;
let pairLauncher = null;
let pairNodeId = null;
let pairStateToken = null;

async function main() {
  await resetDatabase();
  provider = await startFakeProvider();
  await seedProvider(provider.port);
  const serverWorkspace = mkdtempSync(join(tmpdir(), "nexus-tui-e2e-server-"));
  const tuiWorkspace = mkdtempSync(join(tmpdir(), "nexus-tui-e2e-node-"));
  nexus = startNexus(provider.port, serverWorkspace);
  await waitHealthy();

  const pair = await check("pair the TUI's node through POST /nodes", async () => {
    const res = await api("POST", "/nodes", { name: NODE_NAME });
    if (res.status !== 201) throw new Error(`expected 201, got ${res.status}: ${JSON.stringify(res.body)}`);
    if (typeof res.body.token !== "string" || res.body.token.length < 20) {
      throw new Error("no plaintext token in the create answer");
    }
    return res.body;
  });

  const envThread = await check("create env-toolset thread", async () => {
    const res = await api("POST", "/threads", {
      provider: "faketui",
      model: "smart",
      tools: ["bash", "read_file", "write_file", "list_dir"],
    });
    if (res.status !== 201) throw new Error(`expected 201, got ${res.status}: ${JSON.stringify(res.body)}`);
    return res.body.id;
  });

  const tui = startTui(envThread, pair.token, tuiWorkspace);

  // --- 1. Join + replay render + attach -----------------------------------
  await check("tui joins: rendered hello, replay, server-side attach", async () => {
    // The TUI's own stdout proves the event plane decodes and renders:
    // the hello line, then the replayed creation roster line.
    await poll(
      () => {
        const out = tui.stdout();
        return out.includes("-- joined thread — model smart") &&
          out.includes("system: attached targets: workspace.")
          ? out
          : null;
      },
      { message: "tui stdout missing hello/replay render", timeout: 45_000 },
    );
    // Server side: the attach landed the growing roster line.
    await poll(async () => {
      const s = await threadState(envThread);
      const lines = s.messages.filter(
        (m) => m.role === "user" && m.origin?.author === "system",
      );
      return lines[lines.length - 1]?.content === "attached targets: workspace, tui-node."
        ? s
        : null;
    }, { message: "server roster tail naming tui-node" });
  });

  // --- 2. The full remote tool round, executed by the TUI ------------------
  await check("typed line drives a remote round the TUI executes locally", async () => {
    tui.send("case:nodebash marker:TUI-1");
    // The round completes: round-2 assistant text embeds what the TUI
    // echoed (its response frame was accepted and committed).
    const state = await poll(async () => {
      const s = await threadState(envThread);
      const last = s.messages[s.messages.length - 1];
      return last?.role === "assistant" && /the node replied: TUI-1/.test(last.content ?? "")
        ? s
        : null;
    }, { message: "round-2 assistant text naming the TUI's marker" });
    const toolRow = state.messages.find((m) => m.role === "tool");
    if (toolRow.is_error !== false) throw new Error(`tool row flagged error: ${toolRow.content}`);
    if (!/TUI-1/.test(toolRow.content ?? "")) throw new Error(`tool row content: ${toolRow.content}`);
    // The command ran in the TUI's OWN workspace (its workspace dir,
    // scoped by the thread id): the scripted command touched a marker
    // file, asserted there and absent from the server's workspace —
    // proving cwd routing, not just lazy dir creation (cubic PR
    // review).
    if (!existsSync(join(tuiWorkspace, envThread, "tui-e2e-marker"))) {
      throw new Error("bash did not run in the TUI's workspace: no marker file");
    }
    if (existsSync(join(serverWorkspace, envThread, "tui-e2e-marker"))) {
      throw new Error("marker landed in the SERVER workspace");
    }
    // The TUI rendered the round: the call chip, the result chip, and
    // the streaming answer closing with a turn-done line.
    await poll(() => {
      const out = tui.stdout();
      return out.includes("→ bash(") &&
        out.includes("← bash ok:") &&
        out.includes("-- turn done") &&
        out.includes("the node replied: TUI-1")
        ? out
        : null;
    }, { message: "tui stdout missing the rendered tool round" });
  });

  // --- 3. Graceful exit + the queued detach line ---------------------------
  await check("stdin EOF exits cleanly and lands the detach line", async () => {
    tui.end();
    const code = await tui.waitExit();
    if (code !== 0) throw new Error(`tui exit code ${code} (stderr: ${tui.stderr()})`);
    // The queued detach line landed behind the finished turn.
    await poll(async () => {
      const s = await threadState(envThread);
      const lines = s.messages.filter(
        (m) => m.role === "user" && m.origin?.author === "system",
      );
      return lines[lines.length - 1]?.content === "attached targets: workspace."
        ? s
        : null;
    }, { message: "detach line after the TUI left" });
  });

  // --- 4. Phase B: the pairing-grant launcher (tui-pairing plan) ----------
  // Two live grants seeded straight into the store (no HTTP mint route
  // exists by design — the web UI mints them, Phase C), pinned to this
  // thread; then the launcher's whole credential life under a second
  // node name: exchange → 0600 state → crash + stored-credential
  // relaunch (same row, replay) → revoked credential refuses → a fresh
  // URL re-pairs.
  pairWorkspace = mkdtempSync(join(tmpdir(), "nexus-tui-e2e-pair-"));
  const stateHome = mkdtempSync(join(tmpdir(), "nexus-tui-e2e-state-"));
  const pairCodeA = randomBytes(18).toString("base64url");
  const pairCodeB = randomBytes(18).toString("base64url");
  await seedGrant(pairCodeA, envThread);
  await seedGrant(pairCodeB, envThread);

  await check("launcher without state or pair-url exits 2 with usage", async () => {
    const l = startLauncher({ stateHome });
    const code = await l.waitExit();
    if (code !== 2) throw new Error(`expected exit 2, got ${code} (stdout: ${l.stdout()})`);
    if (!/pairing URL/i.test(l.stdout() + l.stderr())) {
      throw new Error(`no usage pointer: ${l.stdout()} ${l.stderr()}`);
    }
  });

  await check("pair via url: exchange, 0600 state file, tui joins", async () => {
    const l = startLauncher({ stateHome, args: [`${BASE}/pair/${pairCodeA}`] });
    pairLauncher = l;
    await poll(() => (l.stdout().includes("-- joined thread — model smart") ? l.stdout() : null), {
      message: "paired tui never joined",
      timeout: 45_000,
    });
    const file = stateFileFor(stateHome, BASE, PAIR_NODE);
    if (!existsSync(file)) throw new Error(`state file missing: ${file}`);
    const mode = statSync(file).mode & 0o777;
    if (mode !== 0o600) throw new Error(`state file mode ${mode.toString(8)}, want 600`);
    const state = JSON.parse(readFileSync(file, "utf8"));
    if (state.server !== BASE) throw new Error(`state server carries ${state.server}`);
    if (state.node !== PAIR_NODE) throw new Error(`state node: ${state.node}`);
    if (state.thread !== envThread) throw new Error(`state thread: ${state.thread} (grant's thread must ride along)`);
    if (typeof state.token !== "string" || state.token.length < 20) throw new Error("state token missing");
    if (JSON.stringify(state).includes("/pair/")) throw new Error("state file must never carry the pairing url");
    pairStateToken = state.token;
    const rows = await pairNodeRows();
    if (rows.length !== 1) throw new Error(`expected 1 ${PAIR_NODE} row, got ${rows.length}`);
    pairNodeId = rows[0].id;
    // The attach landed the growing roster line server-side.
    await poll(async () => {
      const s = await threadState(envThread);
      const lines = s.messages.filter(
        (m) => m.role === "user" && m.origin?.author === "system",
      );
      return lines[lines.length - 1]?.content === "attached targets: workspace, tui-pair-node."
        ? s
        : null;
    }, { message: "pair-node attach roster line" });
  });

  await check("kill the client; stored-credential relaunch keeps the node row", async () => {
    // Crash / closed terminal: the whole group dies with SIGKILL — no
    // graceful exit, no re-pair. The state file must carry the launch.
    pairLauncher.killTree();
    await sleep(500);
    const l = startLauncher({ stateHome });
    pairLauncher = l;
    // Joined AND replayed in one poll: the roster line arrives in
    // frames after the hello — asserting it outside a poll races the
    // replay (cubic).
    await poll(
      () => {
        const out = l.stdout();
        return out.includes("-- joined thread — model smart") &&
          out.includes("system: attached targets: workspace, tui-pair-node.")
          ? out
          : null;
      },
      { message: "relaunch never joined with the replayed roster", timeout: 45_000 },
    );
    // Still the SAME node row — connecting with the stored token never
    // re-pairs (no second row, no fresh token).
    const rows = await pairNodeRows();
    if (rows.length !== 1 || rows[0].id !== pairNodeId) {
      throw new Error(`node row changed after relaunch: ${JSON.stringify(rows)}`);
    }
  });

  await check("revoked credential: bare relaunch refuses with exit 4", async () => {
    pairLauncher.killTree();
    await sleep(500);
    const del = await api("DELETE", `/nodes/${pairNodeId}`);
    if (del.status !== 204) throw new Error(`revoke failed: ${del.status}`);
    const l = startLauncher({ stateHome });
    const code = await l.waitExit();
    if (code !== 4) {
      throw new Error(`expected exit 4, got ${code} (stdout: ${l.stdout()} stderr: ${l.stderr()})`);
    }
    if (!/pair again|credential rejected/i.test(l.stdout() + l.stderr())) {
      throw new Error(`no pair-again pointer: ${l.stdout()} ${l.stderr()}`);
    }
  });

  await check("fresh pairing url re-pairs over the dead credential", async () => {
    // NEXUS_PAIR_URL (the env form) this time; the stored state exists,
    // so the launcher connects first, eats the TUI's exit 4, exchanges
    // against the fresh code, and relaunches — one re-pair, no loop.
    const l = startLauncher({ stateHome, pairUrlEnv: `${BASE}/pair/${pairCodeB}` });
    pairLauncher = l;
    await poll(
      () => {
        const out = l.stdout();
        return out.includes("stored credential rejected — re-pairing from the pairing URL") &&
          out.includes("-- joined thread — model smart")
          ? out
          : null;
      },
      { message: "re-pair never completed", timeout: 60_000 },
    );
    const rows = await pairNodeRows();
    if (rows.length !== 1) throw new Error(`expected 1 ${PAIR_NODE} row, got ${rows.length}`);
    if (rows[0].id === pairNodeId) throw new Error("node row was not replaced by the re-pair");
    pairNodeId = rows[0].id;
    const state = JSON.parse(readFileSync(stateFileFor(stateHome, BASE, PAIR_NODE), "utf8"));
    if (state.token === pairStateToken) throw new Error("state file kept the dead token");
    pairStateToken = state.token;
    // Graceful exit closes the loop; the queued detach line lands.
    l.quit();
    const code = await l.waitExit();
    if (code !== 0) throw new Error(`exit ${code} (stderr: ${l.stderr()})`);
    await poll(async () => {
      const s = await threadState(envThread);
      const lines = s.messages.filter(
        (m) => m.role === "user" && m.origin?.author === "system",
      );
      return lines[lines.length - 1]?.content === "attached targets: workspace."
        ? s
        : null;
    }, { message: "detach line after the re-paired tui left" });
  });

  await nexus.stop();
  await provider.close();
  writeFileSync(
    join(ROOT, "e2e", "tui-report.json"),
    JSON.stringify({ results, ok: results.every((r) => r.ok) }, null, 2),
  );
  console.log(`\n${results.length} checks, all ok`);
}

main().catch(async (err) => {
  console.error(err);
  if (nexus) {
    console.error("--- nexus log tail ---");
    console.error(nexus.log().slice(-4000));
  }
  writeFileSync(
    join(ROOT, "e2e", "tui-report.json"),
    JSON.stringify({ results, ok: false, error: err.message }, null, 2),
  );
  pairLauncher?.killTree();
  await nexus?.stop();
  await provider?.close();
  process.exit(1);
});
