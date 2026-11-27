---
title: Nexus — Postgres-backed skills (progressive disclosure via `read_skill`)
status: active
tags: [computing, self-hosting, local-llm, agents, gleam, beam, skills, postgres]
updated: 2026-11-27
---

# Skills: Postgres-backed progressive disclosure for bots and threads

Related: #152 (skills support), `docs/plans/completed/bots.md` (snapshot-at-creation bot templates), `docs/plans/environments.md` (tool routing & remote nodes), `docs/plans/workspace-sandbox.md` (read-only sandbox mounts).

**Thesis.** Skills are reusable, task-specific playbooks (following the `agentskills.io` progressive-disclosure model: lightweight `name` + `description` catalog in the system prompt, full instructions loaded on demand). In Nexus, **Postgres is the store of record** — matching `provider` and `bot` as first-class Settings entities editable from the web UI and HTTP API, synced across instances, and backed up with the database.

Exposing skills through a **dedicated compiled-in `read_skill` tool** (rather than `read_file` on host paths) decouples skill access from workspaces:

- **KV-cache safe by construction:** each thread freezes its Tier 1 `<available_skills>` index into `thread.system_prompt` at creation and loads full bodies later as ordinary tool results appended to the transcript tail.
- **Works for workspace-less bots:** chat/research/web bots without `bash` or `read_file` (and deployments without `NEXUS_WORKSPACE_ROOT`) use skills natively.
- **Sandbox confinement stays airtight:** `read_file` remains lexically confined to the thread workspace and `bwrap`/`nono` keep host reads blocked; executable `scripts/` (Phase 3) enter local sandboxes only as explicit read-only mounts.
- **Storage remains extensible:** hiding the read path behind a `SkillLoader` seam means an optional read-only disk/NixOS skill layer can be added later without changing the model-facing contract.

---

## Vocabulary

- **Skill** — a named, reusable instruction package stored in the `skill` table (`name`, `description`, `body`), conceptually equivalent to an `agentskills.io` `SKILL.md` (frontmatter metadata + markdown body).
- **Skill file** *(Phase 2)* — a bundled text resource attached to a skill (`skill_file` table, e.g. `references/api.md`, `scripts/check.sh`, `assets/template.txt`).
- **Tier 1 (Discovery)** — the terse `<available_skills>` catalog (`name` + `description` only) appended to the resolved `system_prompt` and frozen on `thread.system_prompt` at thread creation.
- **Tier 2 (Activation)** — the model calling `read_skill(name)` to load the skill's `body` (plus a listing of any bundled `skill_file` paths) as a normal tool result at the transcript tail.
- **Tier 3 (Resources)** — loading a bundled file via `read_skill(name, path)` *(Phase 2)* or executing a staged read-only script inside a sandboxed local workspace *(Phase 3)*.
- **Skill binding (`thread_skill`)** — the frozen per-thread snapshot of which skills a thread was granted at creation, mapping the frozen `name` in `<available_skills>` to its `skill.id` so later renames never break an active thread and deletions fail cleanly.
- **Skill mode (`bot.skill_mode`)** — how a bot selects skills for new threads: `'selected'` (default; uses the bot's explicit `bot_skill` rows, 0 rows = no skills) or `'all'` (live template that snapshots all currently defined skills at thread creation).

---

## Design summary

### 1. KV-cache contract (zero amendments required)

Every existing KV-cache rule in `docs/plans/mvp-requirements.md` and `AGENTS.md` holds unamended:

1. **Tier 1 freezes into `thread.system_prompt` at creation.** When a thread resolves ≥ 1 skills, a deterministic `<available_skills>` block (sorted ascending by `name`) is appended to the bot's resolved `system_prompt` and persisted in `thread.system_prompt`. Hydration still calls `transcript.new(model, stored.system_prompt)` verbatim — no second encoding path, no change to `nexus/transcript`.
2. **Threads with 0 skills change zero bytes.** Existing bots default to `skill_mode = 'selected'` with no `bot_skill` rows, so neither `system_prompt` nor `thread_toolset` changes for existing bots or `test/m3_prefix_test.gleam`.
3. **Wire schema is skill-count-independent.** `read_skill` takes `name` (free string) and optional `path` (free string), never an enum of skill names — identical to how env tools take a free-string `target`. The `tools` envelope never varies when skills are added, renamed, or edited.
4. **`read_skill` lives in `thread_toolset` like any compiled-in tool.** It is excluded from `tools.default_names(cfg)` when a thread has 0 skills (avoiding wasted tool-schema tokens on skill-less threads) and automatically included by `thread_registry.effective_toolset` when a thread resolves ≥ 1 skills. Hydration replays `thread_toolset` verbatim without consulting `bot` or `skill` tables.
5. **Tier 2/3 loads land at the tail.** Calling `read_skill` appends a normal `tool` row to `thread_message`. Reading the live `skill.body` at call time is KV-cache safe: once returned, that tool result is persisted verbatim in `thread_message.content` and never changes on subsequent turns or restarts.

### 2. Schema (`sql/migrations/0003_skills.sql`)

All table and column names are singular, unquoted-safe in Postgres (verify against a live database before applying), and use `timestamptz` read as epoch seconds via `extract(epoch from x)::int8`.

#### Phase 1 tables and columns

```sql
CREATE TABLE skill (
  id          text PRIMARY KEY,               -- 'sk<N>', minted by skill_registry
  name        text NOT NULL UNIQUE,           -- lowercase slug ^[a-z0-9]+(-[a-z0-9]+)*$, 1..64 chars
  description text NOT NULL,                  -- single-line Tier 1 summary, 1..1024 bytes
  body        text NOT NULL,                  -- markdown instructions (plain text, never jsonb)
  created_at  timestamptz NOT NULL,
  updated_at  timestamptz NOT NULL,
  CHECK (name = lower(name))
);

ALTER TABLE bot
  ADD COLUMN skill_mode text NOT NULL DEFAULT 'selected'
    CHECK (skill_mode IN ('selected', 'all'));

CREATE TABLE bot_skill (
  bot_id   text NOT NULL REFERENCES bot(id) ON DELETE CASCADE,
  skill_id text NOT NULL REFERENCES skill(id) ON DELETE CASCADE,
  PRIMARY KEY (bot_id, skill_id)
);

-- FK lookup index so DELETE FROM skill never seq-scans bot_skill.
CREATE INDEX bot_skill_skill ON bot_skill (skill_id);

-- Per-thread frozen skill bindings: maps the frozen name placed into
-- thread.system_prompt to its skill row so a later rename keeps working
-- and a deletion degrades cleanly to a tool error.
CREATE TABLE thread_skill (
  thread_id text NOT NULL REFERENCES thread(id) ON DELETE CASCADE,
  name      text NOT NULL,                    -- frozen name at thread creation
  skill_id  text REFERENCES skill(id) ON DELETE SET NULL,
  PRIMARY KEY (thread_id, name)
);

-- FK lookup index so DELETE FROM skill never seq-scans thread_skill.
CREATE INDEX thread_skill_skill ON thread_skill (skill_id)
  WHERE skill_id IS NOT NULL;
```

Why `bot_skill` (join table) instead of `bot.skills text[]`:
- Referential integrity: Postgres guarantees every assigned skill exists.
- Rename-safe: renaming a skill never breaks bots that reference it.
- Delete-safe: `ON DELETE CASCADE` cleanly detaches a deleted skill from bots without leaving dangling IDs (unlike `provider`, a bot remains usable without a deleted skill; the UI delete confirmation can still report how many bots reference it).

Why `thread_skill` (with `name` + nullable `skill_id`):
- Authorizes `read_skill` strictly to the skills frozen on this thread (a prompt-injected thread cannot enumerate or read skills assigned only to other bots).
- Survives skill renames (`thread.system_prompt` still advertises the creation-time `name`, which resolves through `thread_skill.skill_id` to the renamed row).
- Survives skill deletion (`skill_id` becomes `NULL`; `read_skill` answers with an honest tool error rather than crashing hydration).

#### Phase 2 table (`0004_skill_files.sql`)

```sql
CREATE TABLE skill_file (
  skill_id   text NOT NULL REFERENCES skill(id) ON DELETE CASCADE,
  path       text NOT NULL,                   -- normalized relative path, e.g. 'references/api.md' or 'scripts/check.sh'
  content    text NOT NULL,                   -- UTF-8 text content (capped at save time)
  executable boolean NOT NULL DEFAULT false,  -- true for scripts materialized with +x in Phase 3
  updated_at timestamptz NOT NULL,
  PRIMARY KEY (skill_id, path)
);
```

### 3. Validation rules (`nexus/skill.gleam`)

Pure domain module (zero network or store imports, matching `nexus/bot.gleam`):

- **`name`**: trimmed, then rejected loudly if it fails `^[a-z0-9]+(-[a-z0-9]+)*$` or contains uppercase characters (never silently rewritten, matching `CHECK (name = lower(name))`), length 1–64. Matches the `agentskills.io` naming rule so skills remain portable to and from disk folders.
- **`description`**: trimmed, non-empty, control characters and newlines collapsed to single spaces, max 1024 bytes (measured with `bit_array.byte_size`, matching `NEXUS_SKILL_MAX_BYTES`).
- **`body`**: trimmed, non-empty, max `NEXUS_SKILL_MAX_BYTES` (default 64 KiB, configurable).
- **Bot validation interaction**:
  - `skill_mode: 'selected'` with `skill_ids: [...]` validates that every id exists in the skill catalog (through an injected closure wired in `boot.gleam`, matching `bot_validate_tools` — no cross-registry actor call).
  - A chat-only bot (`tools: Some([])`) cannot enable skills (`skill_mode == 'all'` or non-empty `skill_ids`) — refused loudly with a 400 (`"chat-only bots cannot enable skills"`) at bot save time so the operator sees the contradiction while the form is open.
  - When a bot has explicit `tools: Some([..])` (non-empty) AND skills enabled, `thread_registry.effective_toolset` ensures `read_skill` is included in the frozen `thread_toolset` (deduplicated) so operators don't have to remember to check `read_skill` manually beside every skill.

### 4. Tier 1 system prompt format

Deterministic, minimal-token block appended to the resolved `system_prompt` when a thread has ≥ 1 resolved skills (sorted by `name` ascending):

```markdown

<available_skills>
The following skills are available via the `read_skill` tool. When a user request matches a skill's description, call `read_skill` with its exact name to load the full instructions before proceeding.
- `<name>`: <sanitized single-line description>
</available_skills>
```

Formatting rules:
- XML-escape `&`, `<`, and `>` inside descriptions so a description can never close `</available_skills>` prematurely.
- Keep formatting pure and unit-tested in `nexus/skill.gleam` so byte determinism is pinned offline.

### 5. The `read_skill` tool (`nexus/tools.gleam`)

- Registered in `tools.catalog_names()` as `"read_skill"` (no `__`).
- Excluded from `tools.default_names(cfg)` (auto-injected by `thread_registry.effective_toolset` when the thread's resolved skill list is non-empty; also explicitly selectable if desired).
- **Wire schema** (includes optional `path` from Phase 1 so Phase 2 requires zero schema drift on frozen threads):

```json
{
  "type": "object",
  "properties": {
    "name": {
      "type": "string",
      "description": "Exact name of the skill from <available_skills>."
    },
    "path": {
      "type": "string",
      "description": "Optional relative path of a bundled resource file within the skill (for example, 'references/guide.md'). Omit to read the main skill instructions."
    }
  },
  "required": ["name"],
  "additionalProperties": false
}
```

- **Execution seam (`tools.ToolCtx`):**
  - `ToolCtx` gains `skills: Option(SkillLoader)` beside `delivery` and `environment`, injected by `thread_registry`'s per-thread runner wrapper.
  - `SkillLoader` closes over the thread's frozen `thread_skill` map (`Dict(String, Option(String))`: frozen name → `Option(skill_id)`) and a read-only store lookup fn — no `skill_registry` ask during tool execution.
- **Outcomes (all failures are ordinary tool errors, never loop errors):**
  - Unknown `name` (not in this thread's `thread_skill` bindings): `Error("unknown skill \"<name>\". available skills: a, b")` (or `"no skills are attached to this thread"` when empty) — self-healing, matching `env.gleam`'s unknown-target rule.
  - Deleted skill (`skill_id == None`, or row vanished): `Error("skill \"<name>\" is no longer available")`.
  - Unknown `path` (or any `path` in Phase 1 before `skill_file` exists): `Error("skill \"<name>\" has no file at \"<path>\"")` (listing available file paths in Phase 2).
  - Success: returns `skill.body` (in Phase 2, if the skill has `skill_file` rows, appends a compact `Bundled files:\n- references/…` footer so Tier 3 is discoverable without extra calls), capped at `NEXUS_SKILL_MAX_BYTES`.
  - Codemode synergy: because `read_skill` is an ordinary compiled-in tool, Lua codemode scripts can invoke it with zero extra plumbing.

### 6. Process ownership and supervision (`boot.gleam`)

Follows the exact `bot_registry` / `provider_registry` pattern (see `docs/plans/completed/bots.md` §Process ownership):

- **`nexus/skill_registry`**: OTP actor started in the `OneForAll` root supervisor right after `provider_registry` and before `bot_registry` (settings entities group).
  - Loads all `skill` rows from `store` at boot (unreachable DB fails boot loudly).
  - Owns skill CRUD (`List`, `Get`, `Create`, `Update`, `Delete`) and `sk<N>` ID minting with the multi-instance re-read heal on create (same fix as `bot_registry` `b<N>` / `provider_registry` `p<N>`).
  - No cross-registry edges: `skill_registry` depends only on `store`.
- **`bot_registry`**: gains an injected `validate_skills: fn(List(String)) -> Result(List(String), String)` closure wired in `boot.gleam` (using `skill_registry` or `store`, matching `bot_validate_tools`).
- **`thread_registry`**: resolves a bot's skills through `state.store` at thread creation — covering **both** user-initiated `create_thread_from_bot` (`thread_create.gleam`) AND bot-to-bot `create_dm` (`thread_registry.gleam`) in one path. On hydration, loads `thread_skill` rows from `state.store` to build `ToolCtx.skills`.

### 7. Interaction with workspaces and remote TUI nodes

Answering #152's core question explicitly:

1. **Phase 1 & Phase 2 (no workspace coupling):**
   - `SKILL.md` bodies and text `references/`/`assets/` live in Postgres and are served exclusively via `read_skill`.
   - Zero dependency on `NEXUS_WORKSPACE_ROOT`; works identically for chat/research bots, local-workspace bots, and threads paired with remote TUI nodes.
2. **Phase 3 (executable `scripts/` in local workspaces):**
   - Only activates when a thread has a local workspace (`workspace_id IS NOT NULL`) AND at least one bound skill has `skill_file` rows.
   - **Never copy scripts into the writable thread workspace** — a prompt-injected `bash` call could modify them or confuse them with user artifacts.
   - Instead, materialize bound skill files into a dedicated, managed **read-only staging directory** beneath `workspace_root` (e.g., `<workspace_root>/skills/<thread_id>/<skill_name>/...`, tracked in `workspace` with `kind = 'skill'` or cleaned up alongside the thread's `tmp` workspace on delete/GC) and mount it read-only inside the sandbox:
     - `bwrap`: `--ro-bind <staged_dir> /skills`
     - `nono`: read-only path grant on `<staged_dir>` + `NEXUS_SKILLS_DIR` env var in the allowlist prelude
     - `none` (dev/tests): `NEXUS_SKILLS_DIR` pointing at `<staged_dir>` (lexical hygiene only, matching v1 `none` posture).
   - `read_skill(name)` mentions the mounted path (e.g. `Scripts are available read-only under /skills/<name>/`) only when the thread has a local workspace with staged files.
3. **Remote paired TUI nodes (`target != "workspace"`):**
   - Server-side Postgres skills are still readable via `read_skill` on any thread paired with a remote node.
   - Server-side `scripts/` are **not** implicitly pushed onto remote machines (different trust boundary and host OS).
   - Future enhancement (deferred, orthogonal): a TUI node working in a git repo could advertise repo-local `.agents/skills/` on attach via a passive tail roster message (same mechanism as `[system] attached targets: ...`), read directly via `read_file(target="<node>", ...)`.

### 8. HTTP API and Settings UI

#### HTTP routes (`src/nexus/web.gleam`, all gated by `requires_auth`)

- `GET /skills` — list skills (`id`, `name`, `description`, `body`, `bot_count`, `created_at`, `updated_at`)
- `GET /skills/:id` — get one skill (by id or slug name)
- `POST /skills` — create skill (`name`, `description`, `body`) → `201` (or `400` validation, `409` duplicate name)
- `PATCH /skills/:id` — partial update (`name`, `description`, `body`) → `200` (`400` / `404` / `409`)
- `DELETE /skills/:id` — hard delete (cascades `bot_skill`, nulls `thread_skill.skill_id`) → `204` (`404`)
- `POST /bots` & `PATCH /bots/:id` — accept optional `skill_mode` (`"selected"` | `"all"`) and `skill_ids` (`List(String)`). `GET /bots` returns both fields.

#### Web UI (`src/nexus/ui_settings.gleam`, `src/nexus/ui.gleam`)

- Add `SkillsTab` to `SettingsTab` (`Providers | Bots | Skills`) in the Settings tab rail.
- **Skills tab:** list rows (name, description, bot usage count), add form, inline edit form (Pico-styled textarea with monospace styling for markdown `body`), two-step delete confirmation warning when bots reference the skill. All fields rendered as Lustre text nodes (hostile text, zero `innerHTML`).
- **Bot add/edit form:** add a **Skills** section (`Selected skills` vs `All skills` radio/toggle + skill checkbox list, mirroring the `#121` toolset checkboxes). Disable/explain when the bot is chat-only (`tools = []`).
- **Thread info pane:** show the thread's frozen attached skill names (read-only) beside frozen model/tools when non-empty.

---

## Phased rollout

### Phase 1 — Postgres skills, bot assignment, and `read_skill` (MVP)

Deliverable: end-to-end markdown skills stored in Postgres, editable in Settings UI and HTTP API, assignable to bots, snapshotted onto threads, and loadable by the model via `read_skill`.

1. **Schema & store:**
   - Add `sql/migrations/0003_skills.sql` (`skill`, `bot.skill_mode`, `bot_skill`, `thread_skill`).
   - Add SQL queries under `src/nexus/store/sql/` and regenerate `sql.gleam` via `gleam run -m squirrel`.
   - Extend `nexus/store`, `nexus/store/persist`, `test/store_mock.gleam`, and the differential Postgres-vs-mock contract suite (#174).
2. **Domain & registry:**
   - Add `nexus/skill.gleam` (validation, `<available_skills>` formatting, pure unit tests).
   - Add `nexus/skill_registry.gleam` and wire into `boot.gleam` before `bot_registry`.
   - Extend `nexus/bot.gleam` and `nexus/bot_registry.gleam` (`skill_mode`, `skill_ids`, validation closure, chat-only refusal).
3. **Thread creation, hydration, and tool execution:**
   - Add `read_skill` to `nexus/tools.gleam` (`ToolCtx.skills`, `catalog_names`, excluded from `default_names`).
   - Update `nexus/thread_registry.gleam` (`start_new_thread`, `create_dm`, hydration, `effective_toolset`) to resolve skills from `state.store`, append `<available_skills>` to the frozen `system_prompt`, persist `thread_skill`, and inject `ToolCtx.skills`.
4. **HTTP API & Settings UI:**
   - Add `/skills` CRUD routes and bot `skill_mode`/`skill_ids` fields in `nexus/web.gleam`.
   - Add `SkillsTab` and bot-form skill picker in `nexus/ui_settings.gleam`, plus frozen skill display in the thread info pane.
5. **Verification:**
   - Offline tests (`gleam test`): slug/description/body validation, `<available_skills>` determinism & escaping, `read_skill` happy/unknown/renamed/deleted paths, `create_dm` skill inheritance, KV-cache prefix golden (`m3_prefix_test` unchanged for 0-skill threads + new multi-turn prefix-stability test with `read_skill` tool calls), UI hostile-text (`<script>`) regression tests.
   - Migration + `squirrel check` + differential store suite against Postgres.

### Phase 2 — Bundled resource files (`skill_file`) and `agentskills.io` import/export

Deliverable: multi-file skills (`references/`, `scripts/`, `assets/`) in Postgres plus ergonomic import/export of standard `SKILL.md` directories.

- Add `sql/migrations/0004_skill_files.sql` (`skill_file`).
- Path validation: relative POSIX paths only, no `..`, no leading `/`, allowed charset, per-file and per-skill size caps.
- Wire `read_skill(name, path)` and the `Bundled files:` footer on `read_skill(name)` (zero wire-schema change).
- HTTP endpoints (`GET/PUT/DELETE /skills/:id/files/*path` or JSON payload) + UI file list/editor inside a skill row.
- CLI helper (`gleam run -m nexus/skill_cli import <dir>` / `export <dir>`) and/or HTTP `SKILL.md` frontmatter import so community `agentskills.io` folders load into Postgres cleanly.

### Phase 3 — Read-only workspace staging for executable `scripts/`

Deliverable: local sandboxed `bash` can execute bundled `scripts/` without weakening `workspace-sandbox.md` guarantees.

- Stage bound `skill_file` rows lazily (on first env tool call) into a managed read-only staging dir tracked for crash-safe GC alongside the thread's `tmp` workspace.
- Mount read-only in `env.build_spawn_plan` (`bwrap` `--ro-bind <dir> /skills`, `nono` read-only grant + `NEXUS_SKILLS_DIR`).
- Set `0o555` / `0o444` permissions based on `skill_file.executable`.
- Sandbox escape probes verifying `bash` can execute `/skills/<name>/scripts/...` but cannot write to `/skills` or read skills not bound to the thread.

### Phase 4 — Deferred (recorded, not scheduled)

- **User slash invocation** (`/skill-name` in composer injecting a tail hint or pre-loading the skill cleanly at the tail).
- **Read-only disk/NixOS skill layer** (`NEXUS_SKILLS_DIR` merged behind the same `SkillLoader` seam for declarative Nix-packaged skills alongside Postgres skills).
- **Bot-authored skills (`write_skill` tool)** — explicitly opt-in and gated, because prompt injection → persistent skill poisoning crosses threads (same threat model as opt-in bot-shared workspaces).
- **Repo-local skills from paired TUI nodes** — announced via passive tail roster messages on node attach.

---

## Settled decisions

1. **Skill deletion cascades bot links:** `ON DELETE CASCADE` on `bot_skill` (deleting a skill detaches it cleanly from bots; the Settings UI two-step delete confirmation reports the referencing bot count) and `ON DELETE SET NULL` on `thread_skill` (existing threads degrade cleanly to a `read_skill` tool error).
2. **Zero skills by default on new bots:** both the schema default and the UI add-bot form default to `skill_mode = 'selected'` with no skills checked, keeping cold prefill token budgets predictable and existing bots unchanged.
3. **Body size cap:** `NEXUS_SKILL_MAX_BYTES` defaults to 64 KiB (65,536 bytes) per skill body, enforced on save and on `read_skill` output.

---

## Non-goals (recorded, not planned)

- **Injecting full skill bodies into the system prompt** — defeats progressive disclosure and bloats cold prefill for every turn.
- **Exposing skills via `read_file` on host directories** — breaks workspace-less bots and weakens `bwrap`/`nono` confinement.
- **Per-skill dynamic tool schemas (e.g. `skill_<name>` tools or enum parameters)** — violates KV-cache rule 4 by changing the `tools` envelope whenever skills change.
- **Mid-thread skill catalog mutation** — mutating `system_prompt` mid-thread invalidates the entire KV prefix.
- **Binary asset storage in Postgres** — `skill_file` is UTF-8 text only; binary tools belong in NixOS `workspace.packages` (`docs/plans/workspace-sandbox.md`).

---

## Invariant checklist (what this plan must not break)

- **KV-cache contract:** `thread.system_prompt` and `thread_toolset` remain frozen at thread creation; `nexus/transcript` stays the single encode path; `test/m3_prefix_test.gleam` passes unmodified; warm/cold TTFT gate holds.
- **No cross-registry edges:** `skill_registry`, `bot_registry`, `provider_registry`, and `thread_registry` never call each other's actors directly; orchestration stays in `boot.gleam` closures, `thread_create.gleam`, and `state.store`.
- **Both thread-creation paths stay symmetric:** user `create_thread_from_bot` and bot-to-bot `create_dm` both freeze skills through the same `thread_registry` path.
- **Hostile text in UI:** skill names, descriptions, bodies, and file paths render exclusively as Lustre text nodes — zero `innerHTML`.
- **Offline `gleam test`:** all skill unit, tool, registry, and UI tests run against `test/store_mock.gleam` with zero live database or network dependency; Postgres parity is verified in the differential store contract suite.
- **Schema conventions:** singular unquoted-safe tables (`skill`, `bot_skill`, `thread_skill`, `skill_file`), `timestamptz` timestamps, plain `text` bodies, explicit FK lookup indexes, sequential migrations only.
- **Workspace sandbox boundaries:** Phase 1–2 touch no workspace paths; Phase 3 mounts staged scripts read-only outside the writable thread workspace.
