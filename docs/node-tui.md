# Node TUI

The bundled node TUI (`bin/nexus-tui` / `gleam run -m nexus/tui`) is a
proof-of-concept REPL client for the `/node/ws` protocol. It connects
outbound to nexus, prints thread events as plain lines, sends typed
input to the thread, and—in `env` role—executes workspace tools
(`bash`, `read_file`, `write_file`, `list_dir`) locally inside its own
workspace directory using the same confinement, timeout, and output-cap
logic as the server.

## Pairing with `bin/nexus-tui`

1. In the web UI, open a thread's info pane → **Environments → Pair a
   TUI…** to mint a 1-hour multi-use pairing URL.
2. Run the launcher on the target machine:

```sh
bin/nexus-tui http://127.0.0.1:8080/pair/<code>   # first launch: exchange code & connect
bin/nexus-tui                                     # relaunch with stored credential
bin/nexus-tui --reset                             # remove stored credential(s)
```

Credentials are stored in `0600` JSON files under
`${XDG_STATE_HOME:-$HOME/.local/state}/nexus/` containing
`{server, node, token, thread}` (the pairing code itself is never saved).

- **Reconnecting:** relaunches reuse the stored token without re-pairing.
- **Revoked or idle-swept credentials:** if the server rejects the token
  (`401`), the TUI exits with code `4`. Passing a pairing URL causes
  `bin/nexus-tui` to re-pair and retry once; without one it exits `4`.
- **Multi-host / multi-thread:** one pairing URL can pair multiple hosts
  (set distinct `NEXUS_NODE` names if hostnames collide). Node names are
  unique per thread, so one host can pair the same `NEXUS_NODE` into
  multiple threads; pass `NEXUS_THREAD` to select one on relaunch.

Type a line and press Enter to send it; type `/quit` or send EOF to
exit. Because it is a plain REPL, incoming output interleaves with
half-typed lines and there is no input history.

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `NEXUS_PAIR_URL` | unset | Env-var alternative to passing the pairing URL as an argument to `bin/nexus-tui`. |
| `NEXUS_NODE_TOKEN` | unset | Node credential for the manual `gleam run -m nexus/tui` path (`bin/nexus-tui` supplies it from the state file). |
| `NEXUS_NODE` | short hostname | Node name (unique per thread). |
| `NEXUS_ROLE` | `env` | `env` (events + send + local workspace tools) or `viewer` (events + send only). |
| `NEXUS_THREAD` | grant's thread | Override the thread to join, or disambiguate multiple stored credentials for the same node name. |
| `NEXUS_URL` | stored server | Disambiguate when credentials exist for multiple servers under the same node name. |
| `NEXUS_NODE_WORKSPACE` | `./node-workspace` (under repo root via `bin/nexus-tui`) | Local directory exposed by workspace tools in `env` role. Because `bin/nexus-tui` changes into the repo root before running `gleam`, relative paths resolve against the repo root there. |
| `NEXUS_ENV_TIMEOUT_MS` | `60000` | Per-call wall-clock deadline in ms for local `bash` (`>= 1000`). |
| `NEXUS_ENV_MAX_OUTPUT_BYTES` | `262144` | Byte cap on local `bash` output and file reads (`>= 1024`). |

## Exit codes (`bin/nexus-tui`)

- `0` — clean exit
- `1` — exchange or runtime error
- `2` — usage / configuration error
- `4` — stored credential rejected (revoked or idle-swept; pair again)

## Manual API pairing

For scripted setups using `NEXUS_UI_TOKEN` instead of a pairing URL:

```sh
UI="Authorization: Bearer $NEXUS_UI_TOKEN"
THREAD="<thread id>"

# Remove an existing node row with the same name in this thread first (re-pairing over it returns 409)
NODE_ID=$(curl -s -H "$UI" http://127.0.0.1:8080/nodes \
  | jq -r --arg t "$THREAD" '.nodes[] | select(.name == "laptop" and .thread_id == $t) | .id')
[ -n "$NODE_ID" ] && curl -s -X DELETE -H "$UI" "http://127.0.0.1:8080/nodes/$NODE_ID"

TOKEN=$(curl -s -X POST -H "$UI" -H 'content-type: application/json' \
  -d "{\"name\":\"laptop\",\"thread\":\"$THREAD\"}" \
  http://127.0.0.1:8080/nodes | jq -r .token)

NEXUS_URL=http://127.0.0.1:8080 \
NEXUS_NODE=laptop \
NEXUS_NODE_TOKEN="$TOKEN" \
NEXUS_THREAD="$THREAD" \
gleam run -m nexus/tui
```
