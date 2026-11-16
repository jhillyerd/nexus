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
import { existsSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer } from "node:http";

const ROOT = new URL("..", import.meta.url).pathname;
const TOKEN = "smoke-token-tui-" + Date.now();
const NODE_NAME = "tui-node";
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
          const args = `{  "command" : "echo ${marker}" , "target":"${NODE_NAME}"}`;
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
// The suite
// ---------------------------------------------------------------------------

let nexus = null;
let provider = null;

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
    // scoped by the thread id), not the server's.
    if (!existsSync(join(tuiWorkspace, envThread))) {
      throw new Error("bash ran somewhere else: no workspace dir under the TUI's root");
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
  await nexus?.stop();
  await provider?.close();
  process.exit(1);
});
