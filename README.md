# nexus

A Gleam-on-BEAM personal assistant and agent harness talking to any
OpenAI-compatible `/v1` provider. It provides a Lustre server-component
UI over WebSocket, durable Postgres-backed threads, bot templates and
inter-bot channels, sandboxed local workspaces, remote node TUIs, and
strict append-only request encoding for KV prefix-cache reuse.

## Mission

Some of my goals for this project:

- Be a good personal assistant first, coding agent second
- Strong support for small local LLMs, maximizing use of their prefix-cache
- NixOS friendly, for both hosting and coding
- Take advantage of the BEAM's actor model and OTP supervision trees

## Quickstart

Enter the dev shell (provides Gleam, Erlang/OTP, and rebar3):

```sh
nix develop
```

Create a local `.env` (untracked; loaded by `.envrc` and `bin/dev-server`):

```sh
DATABASE_URL=postgres://nexus@127.0.0.1:5433/nexus
# Generate a 32-byte key with `openssl rand -base64 32` and paste it here:
NEXUS_ENCRYPTION_KEY=<base64-key>
```

Start Postgres, run migrations, and launch the server:

```sh
docker compose up -d --wait
gleam run -m nexus/store/migrate
gleam run
```

Or run `bin/dev-server` (starts Postgres, migrates, runs `dev_seed`, and
boots the server; pass `--reset` to wipe the dev DB volume first).
`dev_seed` runs unconditionally and requires
`NEXUS_SEED_PROVIDER_BASE_URL` in `.env` (see [docs/api.md](docs/api.md));
without it, use the three commands above instead.

> Non-Nix Erlang note: if `crypto` fails to load `libcrypto`, export
> `LD_LIBRARY_PATH` pointing at OpenSSL's `lib/` directory. The flake
> devShell handles this automatically.

### First run

A fresh database starts with zero providers and zero threads.

1. Open `http://127.0.0.1:8080/` (or `/?token=<NEXUS_UI_TOKEN>` if auth
   is enabled).
2. Add an OpenAI-compatible `/v1` endpoint in **Settings → Providers**
   (keyless local endpoints like Ollama, llama.cpp, or vLLM work with no
   API key).
3. Create a bot in **Settings → Bots** (provider, model, optional system
   prompt and toolset).
4. Click **New**, pick the bot beside the composer, and send a message.

### Tests & formatting

```sh
gleam test                  # offline unit tests (no network or database)
gleam format src test
```

Browser and integration suites live in [e2e/README.md](e2e/README.md).

## Configuration

Common environment variables to get running (see
[docs/configuration.md](docs/configuration.md) for the full list):

| Variable | Default | Purpose |
|---|---|---|
| `NEXUS_ENCRYPTION_KEY` | — | **Required.** Master key for provider API keys at rest (`openssl rand -base64 32`). |
| `NEXUS_UI_TOKEN` | unset | Single-user bearer token; unset disables UI/API auth. |
| `NEXUS_HTTP_BIND` | `127.0.0.1` | Server bind address. |
| `NEXUS_HTTP_PORT` | `8080` | Server port. |
| `NEXUS_PG_HOST` / `PORT` / `DATABASE` / `USER` / `PASSWORD` | `127.0.0.1` / `5433` / `nexus` / `nexus` / unset | Server Postgres connection (defaults match `docker-compose.yml`). |
| `NEXUS_WORKSPACE_ROOT` | unset | Enables local workspace tools (`bash`, `read_file`, `write_file`, `list_dir`) under `<root>/<thread-id>`. |
| `NEXUS_WORKSPACE_SANDBOX` | `none` | OS sandbox for local `bash`: `none`, `bwrap`, or `nono`. |

`nexus/store/migrate` prefers `DATABASE_URL` (falling back to
`NEXUS_PG_*`), `nexus/dev_seed` and `squirrel` read `DATABASE_URL`, and
the server itself reads `NEXUS_PG_*`.

## Node TUI

`bin/nexus-tui` is a bundled REPL client that dials out to nexus over
`/node/ws`, streams thread events, sends input, and optionally exposes
the host as a remote workspace environment.

Mint a pairing URL from a thread's info pane (**Environments → Pair a
TUI…**), then run:

```sh
bin/nexus-tui http://127.0.0.1:8080/pair/<code>   # first launch on a host
bin/nexus-tui                                     # relaunch with stored credential
bin/nexus-tui --reset                             # forget stored credential(s)
```

See [docs/node-tui.md](docs/node-tui.md) for environment overrides,
re-pairing behavior, and manual API pairing.

## NixOS deployment

The flake exposes `packages.<system>.default` (`nexus` +
`nexus-migrate`), `overlays.default`, `nixosModules.default`, and a
Linux VM check (`checks.<linux-system>.nixos-service`).

```nix
{
  inputs.nexus.url = "github:<owner>/nexus";

  outputs = { nixpkgs, nexus, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        nexus.nixosModules.default
        {
          services.nexus-agent = {
            enable = true;
            # Quoted string paths so secrets never enter /nix/store:
            environmentFile = "/run/secrets/nexus.env"; # NEXUS_ENCRYPTION_KEY, NEXUS_UI_TOKEN, ...
            database = {
              createLocally = true;
              passwordFile = "/run/secrets/nexus-pg-password";
            };
            workspace = {
              enable = true;
              sandbox = "bwrap"; # builds an immutable pkgs.buildEnv toolchain
            };
          };
        }
      ];
    };
  };
}
```

With `database.createLocally = true`, the unit provisions the local
PostgreSQL role, runs `nexus-migrate` in `ExecStartPre`, and enables
systemd cgroup delegation when sandboxing is active. See
[nix/module.nix](nix/module.nix) for all module options.

## Documentation

- [docs/configuration.md](docs/configuration.md) — full environment variable reference
- [docs/api.md](docs/api.md) — HTTP/WebSocket API and `dev_seed` CLI
- [docs/node-tui.md](docs/node-tui.md) — remote node TUI pairing and options
- [docs/audit.md](docs/audit.md) — warm/cold TTFT prefix-cache audit tool
- [ARCHITECTURE.md](ARCHITECTURE.md) — OTP process model, supervision tree, and message flow
- [AGENTS.md](AGENTS.md) — schema, UI, and agent-loop invariants
- [e2e/README.md](e2e/README.md) — Playwright browser and integration test suites
