// e2e fake-node suite (environments plan Phase 2b-4) — validation only.
//
// The browser suite cannot exercise the node protocol (it needs a TUI
// peer), but a raw WebSocket client can. This suite runs Nexus in its
// production posture on loopback with:
//
//   - a fake OpenAI SSE provider scripting env-tool turns (`case:nodebash`,
//     `case:nodehang`), so tool calls targeting an attached node are
//     deterministic — no network beyond loopback, no Playwright;
//   - a headless FAKE NODE (Node's built-in WebSocket) speaking the
//     /node/ws client protocol v1: it pairs through POST /nodes, joins
//     a thread, receives the event plane, and serves tools/call frames.
//
// It verifies, through the REAL socket and the REAL thread actor:
//   1. the connect sequence (hello + replay + attached) and roster lines
//      in the replay (system-authored user rows);
//   2. a full remote tool round: model calls bash(target=node-a) →
//      tools/call frame down with arguments VERBATIM → node's result →
//      committed tool row → the model's round-2 answer names the node's
//      marker;
//   3. replace-on-reconnect: a second connection with the same name
//      kills the first socket, registers the new plane, and appends NO
//      roster line (message_count unchanged);
//   4. detach mid-call: the node drops the socket with a call in
//      flight → the executor-side monitor answers an ordinary failed
//      tool result (the round commits) → the queued detach line lands
//      after the turn;
//   5. auth: a wrong node token is a plain 401; role=viewer on a plain
//      thread joins with events + send but no tool plane.
//
// Usage: node e2e/node.spec.mjs
// Preconditions: Postgres on 127.0.0.1:5433 with the schema applied
// (docker compose up -d + migrate — see e2e/README.md).
// Writes e2e/node-report.json; exits non-zero on any failure.

import { spawn } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer } from "node:http";

const ROOT = new URL("..", import.meta.url).pathname;
const TOKEN = "smoke-token-node-" + Date.now();
const PORT = 18090;
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

async function poll(fn, { timeout = 20_000, interval = 250, message = "poll" } = {}) {
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

/// Reset the shared e2e database (node rows included — this suite pairs
/// through the real table).
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

/// The fake OpenAI-compatible provider: /v1/models + scripted SSE
/// completions. Env-tool scenarios stream a bash tool call whose target
/// is the attached node; round 2 (after the tool result) answers text
/// that embeds whatever the node reported, proving the round trip.
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
          id: "chatcmpl-node-e2e",
          object: "chat.completion.chunk",
          created: 1,
          model: "smart",
          choices: [{ index: 0, delta, finish_reason: finish }],
        });
        const finish = () => {
          sse({
            id: "chatcmpl-node-e2e",
            object: "chat.completion.chunk",
            created: 1,
            model: "smart",
            choices: [],
            usage: {
              prompt_tokens: 100,
              completion_tokens: 8,
              total_tokens: 108,
              prompt_tokens_details: { cached_tokens: 80 },
            },
          });
          res.write("data: [DONE]\n\n");
          res.end();
        };

        if (scenario === "nodebash" && !toolDone) {
          // Round 1: call bash on the attached node, echoing the user's
          // marker so the node can assert the arguments it receives.
          const marker = /marker:(\S+)/.exec(userText)?.[1] ?? "plain";
          sse(chunk({ role: "assistant", content: "" }));
          sse(chunk({ tool_calls: [{ index: 0, id: callId, type: "function", function: { name: "bash", arguments: "" } }] }));
          sse(chunk({ tool_calls: [{ index: 0, function: { arguments: `{"target":"node-a","command":"echo ${marker}"}` } }] }));
          sse(chunk({}, "tool_calls"));
          finish();
          return;
        }
        if (scenario === "nodebash" && toolDone) {
          // Round 2: answer FROM the tool result, proving the node's
          // bytes reached the model's context.
          const toolMsg = request.messages.findLast((m) => m.role === "tool");
          sse(chunk({ role: "assistant", content: "" }));
          res.write(`data: ${JSON.stringify(chunk({ content: "the node replied: " + String(toolMsg?.content ?? "") }))}\n\n`);
          sse(chunk({}, "stop"));
          finish();
          return;
        }
        if (scenario === "nodehang" && !toolDone) {
          // A call the node will never answer (it drops the socket
          // instead): nexus's monitor must answer a failed tool result.
          sse(chunk({ role: "assistant", content: "" }));
          sse(chunk({ tool_calls: [{ index: 0, id: callId, type: "function", function: { name: "bash", arguments: "" } }] }));
          sse(chunk({ tool_calls: [{ index: 0, function: { arguments: `{"target":"node-a","command":"sleep 999"}` } }] }));
          sse(chunk({}, "tool_calls"));
          finish();
          return;
        }
        if (scenario === "nodehang" && toolDone) {
          sse(chunk({ role: "assistant", content: "" }));
          sse(chunk({ content: "the call failed as data" }));
          sse(chunk({}, "stop"));
          finish();
          return;
        }
        // Default: a plain text answer (the viewer-role send).
        sse(chunk({ role: "assistant", content: "" }));
        sse(chunk({ content: "plain answer" }));
        sse(chunk({}, "stop"));
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

/// Seed the fake provider as a provider row (the only provider source
/// since the P3 hard cut).
function seedProvider(port) {
  const env = {
    ...process.env,
    DATABASE_URL,
    NEXUS_ENCRYPTION_KEY: ENC_KEY,
    NEXUS_SEED_PROVIDER_NAME: "fakenode",
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
    // Generous: the hang case must be answered by the MONITOR (the node
    // dying), not by this deadline.
    NEXUS_ENV_TIMEOUT_MS: "20000",
    NEXUS_SYSTEM_PROMPT: "You are nexus under node-protocol e2e test.",
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
// The fake node: Node's built-in WebSocket speaking client protocol v1.
// ---------------------------------------------------------------------------

class FakeNode {
  constructor(url) {
    this.url = url;
    this.frames = [];
    this.waiters = [];
    this.closed = null;
    this.closeCode = null;
    this.ws = null;
  }

  connect() {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(this.url);
      this.ws = ws;
      ws.addEventListener("open", () => resolve(this));
      ws.addEventListener("message", (ev) => {
        let frame;
        try {
          frame = JSON.parse(ev.data);
        } catch {
          reject(new Error(`non-JSON frame: ${ev.data}`));
          return;
        }
        this.frames.push(frame);
        this.waiters = this.waiters.filter((w) => !w(frame));
      });
      ws.addEventListener("close", (ev) => {
        this.closeCode = ev.code;
        this.closed = new Promise((r) => r(ev.code));
        resolve(null);
      });
      ws.addEventListener("error", () => {
        // An abrupt server death can end in error WITHOUT a close
        // handshake (the peer never answers the close frame): settle
        // `closed` here too — the connection is over either way.
        if (this.closed === null) {
          this.closeCode = -1;
          this.closed = new Promise((r) => r(-1));
          resolve(null);
        }
      });
      // A 401/403/404 upgrade refusal surfaces as an abrupt close
      // (undichi reports unexpected server response): make connect()
      // fail loudly in that case.
      setTimeout(() => {
        if (this.ws.readyState === WebSocket.CLOSED && !this.frames.length) {
          reject(new Error(`connection closed before any frame (code ${this.closeCode})`));
        }
      }, 3000);
    });
  }

  /// Wait for the first frame matching pred (frames already seen count).
  waitFor(pred, label, timeoutMs = 20_000) {
    const seen = this.frames.find(pred);
    if (seen) return Promise.resolve(seen);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error(`fake node: no ${label} frame within ${timeoutMs}ms (have: ${this.frames.map((f) => f.type ?? f.method).join(",")})`)),
        timeoutMs,
      );
      this.waiters.push((frame) => {
        if (pred(frame)) {
          clearTimeout(timer);
          resolve(frame);
          return true;
        }
        return false;
      });
    });
  }

  send(obj) {
    this.ws.send(JSON.stringify(obj));
  }

  /// Answer one tools/call with plain text content.
  answer(id, text, isError = false) {
    this.send({
      v: 1,
      jsonrpc: "2.0",
      id,
      result: { content: [{ type: "text", text }], isError },
    });
  }

  close() {
    this.ws.close();
  }
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
  const workspaceRoot = mkdtempSync(join(tmpdir(), "nexus-node-e2e-"));
  nexus = startNexus(provider.port, workspaceRoot);
  await waitHealthy();

  // --- Pairing + thread setup -------------------------------------------
  const pair = await check("pair node through POST /nodes", async () => {
    const res = await api("POST", "/nodes", { name: "node-a" });
    if (res.status !== 201) throw new Error(`expected 201, got ${res.status}: ${JSON.stringify(res.body)}`);
    if (typeof res.body.token !== "string" || res.body.token.length < 20) {
      throw new Error("no plaintext token in the create answer");
    }
    return res.body;
  });
  const nodeToken = pair.token;

  const envThread = await check("create env-toolset thread", async () => {
    const res = await api("POST", "/threads", {
      provider: "fakenode",
      model: "smart",
      tools: ["bash", "read_file", "write_file", "list_dir"],
    });
    if (res.status !== 201) throw new Error(`expected 201, got ${res.status}: ${JSON.stringify(res.body)}`);
    return res.body.id;
  });

  const nodeUrl = (thread, extra = "") =>
    `ws://127.0.0.1:${PORT}/node/ws?node=node-a&token=${encodeURIComponent(nodeToken)}&thread=${thread}${extra}`;

  // --- 1. Connect sequence + replay --------------------------------------
  const nodeA = new FakeNode(nodeUrl(envThread));
  await check("connect sequence: hello, replay, attached", async () => {
    await nodeA.connect();
    const hello = await nodeA.waitFor((f) => f.type === "hello", "hello");
    if (hello.model !== "smart") throw new Error(`hello model: ${hello.model}`);
    // The replay carries the creation roster line as a system-authored
    // user frame.
    const roster = await nodeA.waitFor(
      (f) => f.type === "user" && f.author === "system" && /attached targets: workspace\.$/.test(f.text),
      "creation roster line",
    );
    if (typeof roster.at !== "number") throw new Error("roster line at-stamp missing");
    await nodeA.waitFor((f) => f.type === "attached" && f.target === "node-a", "attached");
  });

  // The attach appended the growing roster line to the transcript.
  await check("attach appended the roster line", async () => {
    const state = await threadState(envThread);
    const lines = state.messages.filter(
      (m) => m.role === "user" && m.origin?.author === "system",
    );
    const last = lines[lines.length - 1];
    if (last?.content !== "attached targets: workspace, node-a.") {
      throw new Error(`unexpected roster tail: ${last?.content}`);
    }
  });

  // --- 2. The remote tool round ------------------------------------------
  await check("remote bash round trip through the node", async () => {
    const sent = api("POST", `/threads/${envThread}/send`, { text: "case:nodebash marker:ROUND-1" });
    const call = await nodeA.waitFor(
      (f) => f.method === "tools/call" && f.params?.name === "bash",
      "tools/call",
    );
    if (call.params.arguments?.target !== "node-a") {
      throw new Error(`wrong target in arguments: ${JSON.stringify(call.params.arguments)}`);
    }
    if (call.params.arguments?.command !== "echo ROUND-1") {
      throw new Error(`arguments not verbatim: ${JSON.stringify(call.params.arguments)}`);
    }
    if (call.v !== 1 || call.jsonrpc !== "2.0") {
      throw new Error(`frame envelope wrong: ${JSON.stringify(call)}`);
    }
    nodeA.answer(call.id, "node says: ROUND-1-DONE");
    const toolResult = await nodeA.waitFor(
      (f) => f.type === "tool_result" && f.ok === true,
      "tool_result event",
    );
    if (!toolResult.content.includes("ROUND-1-DONE")) {
      throw new Error(`tool result content: ${toolResult.content}`);
    }
    await nodeA.waitFor((f) => f.type === "turn_done", "turn_done");
    const sentRes = await sent;
    if (sentRes.status !== 202) throw new Error(`send status: ${sentRes.status}`);
    // The model's round-2 answer embeds the node's bytes.
    const state = await poll(
      async () => {
        const s = await threadState(envThread);
        const last = s.messages[s.messages.length - 1];
        return last?.role === "assistant" && /ROUND-1-DONE/.test(last.content ?? "") ? s : null;
      },
      { message: "round-2 assistant text naming the node marker" },
    );
    const toolRow = state.messages.find((m) => m.role === "tool");
    if (toolRow.is_error !== false) throw new Error("tool row flagged as error");
  });

  // --- 3. Replace-on-reconnect -------------------------------------------
  await check("replace-on-reconnect kills the old socket, no roster line", async () => {
    const before = await threadState(envThread);
    const countBefore = before.status.message_count;

    const nodeB = new FakeNode(nodeUrl(envThread));
    await nodeB.connect();
    await nodeB.waitFor((f) => f.type === "attached" && f.target === "node-a", "B attached");
    // A dies (its adapter was killed by the replace).
    const code = await Promise.race([nodeA.closed, sleep(5000).then(() => null)]);
    if (code === null) throw new Error("old socket still open after replace");

    // No roster line: the list is unchanged.
    await sleep(500);
    const after = await threadState(envThread);
    if (after.status.message_count !== countBefore) {
      throw new Error(
        `roster line appended on replace: ${countBefore} -> ${after.status.message_count}`,
      );
    }

    // B serves the next round (the new plane routes).
    await api("POST", `/threads/${envThread}/send`, { text: "case:nodebash marker:ROUND-2" });
    const call = await nodeB.waitFor(
      (f) => f.method === "tools/call" && f.params?.name === "bash",
      "B tools/call",
    );
    nodeB.answer(call.id, "node says: ROUND-2-DONE");
    await nodeB.waitFor((f) => f.type === "turn_done", "round-2 turn_done", 30_000);
    const streamed = nodeB.frames
      .filter((f) => f.type === "token")
      .map((f) => f.text)
      .join("");
    if (!/ROUND-2-DONE/.test(streamed)) {
      throw new Error(`round-2 stream missing the node marker: ${streamed}`);
    }

    // Graceful close: the detach line lands (idle, so immediately).
    nodeB.close();
    await poll(
      async () => {
        const s = await threadState(envThread);
        const lines = s.messages.filter(
          (m) => m.role === "user" && m.origin?.author === "system",
        );
        return lines[lines.length - 1]?.content === "attached targets: workspace.";
      },
      { message: "detach roster line after close" },
    );

    // nodeB is used up; the hang case reconnects fresh below.
  });

  // --- 4. Detach mid-call -------------------------------------------------
  await check("detach mid-call: monitor answers a failed tool result", async () => {
    const nodeC = new FakeNode(nodeUrl(envThread));
    await nodeC.connect();
    await nodeC.waitFor((f) => f.type === "attached", "C attached");

    await api("POST", `/threads/${envThread}/send`, { text: "case:nodehang" });
    const call = await nodeC.waitFor(
      (f) => f.method === "tools/call" && f.params?.name === "bash",
      "C tools/call",
    );
    // Answer never comes: the node just drops the socket mid-call.
    // (The server side dies with its adapter, so the close handshake
    // may never complete — bounded wait, then move on to what the
    // SERVER did, which is the assertion that matters.)
    nodeC.ws.close();
    await Promise.race([nodeC.closed, sleep(3000)]);
    void call;

    // The monitor answers an ordinary failed tool result; the round
    // COMMITS and round 2 answers text.
    let lastSeen = "none";
    const state = await poll(
      async () => {
        const s = await threadState(envThread);
        const toolRows = s.messages.filter((m) => m.role === "tool");
        const last = toolRows[toolRows.length - 1];
        if (last && last.is_error === true) return s;
        lastSeen =
          s.status.streaming === true
            ? "streaming"
            : s.messages
                .slice(-3)
                .map((m) => `${m.role}:${m.is_error}:${String(m.content ?? "").slice(0, 60)}`)
                .join(" | ");
        return null;
      },
      { message: "failed tool result after mid-call detach" },
    ).catch((err) => {
      throw new Error(`${err.message}; last state tail: [${lastSeen}]`);
    });
    const toolRows = state.messages.filter((m) => m.role === "tool");
    const last = toolRows[toolRows.length - 1];
    if (!/unavailable/i.test(last.content ?? "")) {
      throw new Error(`expected unavailable wording, got: ${last.content}`);
    }
    // The turn finished and the queued detach line landed behind it.
    await poll(
      async () => {
        const s = await threadState(envThread);
        const lines = s.messages.filter(
          (m) => m.role === "user" && m.origin?.author === "system",
        );
        return lines[lines.length - 1]?.content === "attached targets: workspace.";
      },
      { message: "detach line after the mid-call turn" },
    );
  });

  // --- 5. Auth + viewer role ----------------------------------------------
  await check("wrong node token refused with 401", async () => {
    const bad = new FakeNode(
      `ws://127.0.0.1:${PORT}/node/ws?node=node-a&token=wrong&thread=${envThread}`,
    );
    let failed = false;
    try {
      const opened = await bad.connect();
      if (opened === null) failed = true;
      if (!failed && bad.frames.length) {
        throw new Error(`frames arrived on a bad-token socket: ${bad.frames[0]}`);
      }
      failed = true;
    } catch (err) {
      if (/closed before any frame|unexpected server response/i.test(err.message)) {
        failed = true;
      } else {
        throw err;
      }
    }
    if (!failed) throw new Error("bad-token socket unexpectedly connected");
  });

  await check("env role refused on a plain thread (403)", async () => {
    const plain = await api("POST", "/threads", {
      provider: "fakenode",
      model: "smart",
    });
    const bad = new FakeNode(nodeUrl(plain.body.id));
    try {
      const opened = await bad.connect();
      if (opened !== null && bad.frames.length) {
        throw new Error(`frames arrived: ${bad.frames[0]}`);
      }
    } catch (err) {
      if (!/closed before any frame|unexpected server response/i.test(err.message)) {
        throw err;
      }
    }
  });

  await check("viewer role: events + send, no tool plane", async () => {
    const plain = await api("POST", "/threads", {
      provider: "fakenode",
      model: "smart",
    });
    const threadId = plain.body.id;
    const viewer = new FakeNode(nodeUrl(threadId, "&role=viewer"));
    const opened = await viewer.connect();
    if (opened === null) throw new Error("viewer socket closed at connect");
    await viewer.waitFor((f) => f.type === "hello", "viewer hello");
    // No `attached` frame ever arrives — assert by sending and seeing
    // the flow work without one.
    viewer.send({ v: 1, type: "send", text: "hello from the viewer" });
    await viewer.waitFor((f) => f.type === "turn_done", "viewer turn_done", 30_000);
    const streamed = viewer.frames
      .filter((f) => f.type === "token")
      .map((f) => f.text)
      .join("");
    if (!/plain answer/.test(streamed)) {
      throw new Error(`viewer send did not round-trip: ${streamed}`);
    }
    const attached = viewer.frames.find((f) => f.type === "attached");
    if (attached) throw new Error("viewer received an attached frame");
    // Ping/pong liveness.
    viewer.send({ v: 1, type: "ping" });
    await viewer.waitFor((f) => f.type === "pong", "pong");
    viewer.close();
  });

  writeFileSync(
    join(ROOT, "e2e", "node-report.json"),
    JSON.stringify({ results, ok: results.every((r) => r.ok) }, null, 2),
  );
  console.log(`\n${results.length} checks, all ok`);
}

main()
  .then(async () => {
    if (nexus) await nexus.stop();
    if (provider) await provider.close();
    process.exit(0);
  })
  .catch(async (err) => {
    console.error("\nsuite failed:", err.message);
    if (nexus) {
      console.error("--- nexus log tail ---\n" + nexus.log().slice(-4000));
      await nexus.stop();
    }
    if (provider) await provider.close();
    writeFileSync(
      join(ROOT, "e2e", "node-report.json"),
      JSON.stringify({ results, ok: false, error: err.message }, null, 2),
    );
    process.exit(1);
  });
