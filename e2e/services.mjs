//// Controlled services for the M3 browser suite (validation only — never
//// part of the Nexus runtime):
////
////   1. fake Bifrost  — an OpenAI-compatible SSE server playing scripted
////      scenarios (text / slow / fetch / search / loop) so the UI's tool
////      rendering, loop chip, stop, and guard behaviour are deterministic.
////      It also records every chat request body verbatim, which lets the
////      suite assert byte-identical prefix growth turn-over-turn.
////   2. doc server    — the http_fetch target under our control.
////   3. searxng stub  — a SearxNG-compatible `/search?format=json` endpoint.
////
//// All servers bind 127.0.0.1 on ephemeral ports and are closed by the
//// caller.

import { createServer } from "node:http";

export function startServices() {
  return new Promise((resolve, reject) => {
    const state = { requests: [] };

    const doc = createServer((req, res) => {
      const url = new URL(req.url, "http://127.0.0.1");
      if (url.pathname === "/doc.json") {
        // The <script> string proves previews are inert text nodes.
        res.writeHead(200, { "content-type": "application/json" });
        res.end(
          JSON.stringify({
            marker: "nexus-e2e-doc",
            note: "<script>alert('never executed')</script>",
          }),
        );
        return;
      }
      if (url.pathname === "/loop") {
        res.writeHead(200, { "content-type": "text/plain" });
        res.end("loop round content\n");
        return;
      }
      res.writeHead(404);
      res.end("not found");
    });

    const searx = createServer((req, res) => {
      const url = new URL(req.url, "http://127.0.0.1");
      if (url.pathname === "/search") {
        res.writeHead(200, { "content-type": "application/json" });
        res.end(
          JSON.stringify({
            query: url.searchParams.get("q"),
            results: [
              {
                title: "nexus-e2e stub title",
                url: "https://stub.example/nexus",
                content: "stub snippet with <b>markup</b>",
              },
            ],
          }),
        );
        return;
      }
      res.writeHead(404);
      res.end("not found");
    });

    const bifrost = createServer((req, res) => {
      const url = new URL(req.url, "http://127.0.0.1");
      if (req.method === "GET" && url.pathname === "/v1/models") {
        res.writeHead(200, { "content-type": "application/json" });
        res.end(
          JSON.stringify({ data: [{ id: "smart" }, { id: "fast" }] }),
        );
        return;
      }
      if (req.method === "POST" && url.pathname === "/v1/chat/completions") {
        let body = "";
        req.on("data", (chunk) => (body += chunk));
        req.on("end", () => {
          state.requests.push({ url: url.pathname, body });
          playScenario(res, JSON.parse(body), state);
        });
        return;
      }
      res.writeHead(404);
      res.end("not found");
    });

    const servers = [doc, searx, bifrost];
    let pending = 3;
    const ports = {};
    servers.forEach((server) => {
      server.on("error", reject);
      server.listen(0, "127.0.0.1", () => {
        pending -= 1;
        if (pending === 0) {
          state.docPort = doc.address().port;
          resolve({
            docPort: doc.address().port,
            searxPort: searx.address().port,
            bifrostPort: bifrost.address().port,
            requests: state.requests,
            close: () =>
              Promise.all(
                servers.map(
                  (s) => new Promise((done) => s.close(() => done())),
                ),
              ),
          });
        }
      });
    });
  });
}

// ---------------------------------------------------------------------------
// Scripted model scenarios
// ---------------------------------------------------------------------------

function sse(res, obj) {
  res.write(`data: ${JSON.stringify(obj)}\n\n`);
}

function chunk(delta, finish = null) {
  return {
    id: "chatcmpl-e2e",
    object: "chat.completion.chunk",
    created: 1,
    model: "smart",
    choices: [{ index: 0, delta, finish_reason: finish }],
  };
}

function usageChunk() {
  // Usage rides without include_usage on real Bifrost; mirror that.
  return {
    id: "chatcmpl-e2e",
    object: "chat.completion.chunk",
    created: 1,
    model: "smart",
    choices: [],
    usage: {
      prompt_tokens: 1000,
      completion_tokens: 12,
      total_tokens: 1012,
      prompt_tokens_details: { cached_tokens: 800 },
    },
  };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function playScenario(res, request, state) {
  res.writeHead(200, {
    "content-type": "text/event-stream",
    "cache-control": "no-cache",
  });
  // `: heartbeat` comments like real Bifrost sends.
  res.write(": heartbeat\n\n");

  const lastUserIndex = request.messages.findLastIndex((m) => m.role === "user");
  const lastUser = request.messages[lastUserIndex];
  const userText = String(lastUser?.content ?? "");
  const scenario = /case:(\w+)/.exec(userText)?.[1] ?? "text";
  // Round 2 of a scenario starts once this user message has been answered
  // with a tool result — earlier turns' tool messages don't count.
  const hasToolResult = request.messages
    .slice(lastUserIndex + 1)
    .some((m) => m.role === "tool");
  const callId = `call_${state.requests.length}`;

  const streamText = async (text, { delay = 25, split = " " } = {}) => {
    for (const part of text.split(split)) {
      sse(res, chunk({ content: part + (split === " " ? " " : "") }));
      if (delay) await sleep(delay);
    }
  };

  const streamToolCall = async (name, argsString) => {
    // First fragment carries id + name, second the arguments — two deltas,
    // like the real backends.
    sse(res, chunk({ tool_calls: [{ index: 0, id: callId, type: "function", function: { name, arguments: "" } }] }));
    await sleep(20);
    sse(res, chunk({ tool_calls: [{ index: 0, function: { arguments: argsString } }] }));
    await sleep(20);
    sse(res, chunk({}, "tool_calls"));
  };

  const finish = () => {
    sse(res, usageChunk());
    res.write("data: [DONE]\n\n");
    res.end();
  };

  switch (scenario) {
    case "text": {
      sse(res, chunk({ role: "assistant", content: "" }));
      await streamText("Plain answer from the scripted model.");
      sse(res, chunk({}, "stop"));
      finish();
      return;
    }
    case "reasoning": {
      // DeepSeek-R1 / vLLM shape: reasoning_content fragments stream before
      // any content, so the UI's live thinking block is exercised live and
      // the committed block above.
      sse(res, chunk({ role: "assistant", reasoning_content: "" }));
      for (const part of ["weighing ", "the ", "evidence ", "carefully "]) {
        sse(res, chunk({ reasoning_content: part }));
        await sleep(350);
      }
      await streamText("Reasoned answer from the scripted model.");
      sse(res, chunk({}, "stop"));
      finish();
      return;
    }
    case "slow": {
      sse(res, chunk({ role: "assistant", content: "" }));
      for (let i = 0; i < 40; i++) {
        sse(res, chunk({ content: `word${i} ` }));
        await sleep(600);
      }
      sse(res, chunk({}, "stop"));
      finish();
      return;
    }
    case "fetch": {
      const target = /https?:\/\/\S+/.exec(userText)?.[0] ?? "http://127.0.0.1/doc.json";
      if (!hasToolResult) {
        await streamText("Checking that URL now.");
        await streamToolCall("http_fetch", JSON.stringify({ url: target }));
        finish();
      } else {
        await streamText("Fetch complete: the document says nexus-e2e-doc.");
        sse(res, chunk({}, "stop"));
        finish();
      }
      return;
    }
    case "search": {
      if (!hasToolResult) {
        await streamText("Searching.");
        await streamToolCall("web_search", JSON.stringify({ query: "controlled query" }));
        finish();
      } else {
        await streamText("Search complete: nexus-e2e stub title found.");
        sse(res, chunk({}, "stop"));
        finish();
      }
      return;
    }
    case "loop": {
      // Never a final answer: every round issues another tool call, so the
      // iteration guard must trip (used against the max=2 instance).
      await streamToolCall("http_fetch", JSON.stringify({ url: `http://127.0.0.1:${state.docPort ?? 1}/loop` }));
      finish();
      return;
    }
    default: {
      await streamText("Unknown case marker; answering plainly.");
      sse(res, chunk({}, "stop"));
      finish();
    }
  }
}
