-- Workspace tracking and crash-safe disk GC (docs/plans/workspace-sandbox.md,
-- Phase 1, #126).
--
-- Managed workspace directories on disk are tracked by rows in `workspace`
-- (`kind`: 'thread' | 'bot' | 'tmp') with a frozen `root` and `rel_path` so
-- cascade deletion and crash-safe boot GC never guess paths.
--
-- Mutual FK design: `workspace.thread_id` references `thread(id)` and
-- `thread.workspace_id` / `thread.tmp_workspace_id` reference `workspace(id)`.
-- Deferring the `thread -> workspace` FKs (`DEFERRABLE INITIALLY DEFERRED`)
-- lets `insert_thread.sql` create the thread row and its owned workspace rows
-- atomically in a single statement, while still enforcing referential integrity
-- at statement/transaction commit.

CREATE TABLE workspace (
  id           text PRIMARY KEY,
  kind         text NOT NULL,       -- 'thread' | 'bot' | 'tmp'
  root         text NOT NULL,       -- frozen resolved NEXUS_WORKSPACE_ROOT
  rel_path     text NOT NULL,       -- relative to root ('threads/<id>', 'bots/<id>', 'tmp/<id>', or legacy '<id>'); never absolute or '..'
  thread_id    text REFERENCES thread(id) ON DELETE SET NULL,
  bot_id       text REFERENCES bot(id) ON DELETE SET NULL,
  created_at   timestamptz NOT NULL,
  last_used_at timestamptz,
  deleted_at   timestamptz          -- NULL = live; non-NULL = tombstoned awaiting disk rm -rf
);

CREATE UNIQUE INDEX workspace_path
  ON workspace (root, rel_path);

CREATE INDEX workspace_thread
  ON workspace (thread_id)
  WHERE thread_id IS NOT NULL;

CREATE UNIQUE INDEX workspace_bot_live
  ON workspace (bot_id)
  WHERE kind = 'bot' AND deleted_at IS NULL;

CREATE INDEX workspace_pending_gc
  ON workspace (deleted_at)
  WHERE deleted_at IS NOT NULL;

ALTER TABLE thread
  ADD COLUMN workspace_id     text REFERENCES workspace(id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,
  ADD COLUMN tmp_workspace_id text REFERENCES workspace(id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED;

-- FK lookup indexes (matching thread_bot / node_grant_thread): Postgres does
-- not auto-index FK columns, so without these every workspace hard-delete or
-- bot-workspace ref check seq-scans thread.
CREATE INDEX thread_workspace
  ON thread (workspace_id)
  WHERE workspace_id IS NOT NULL;

CREATE INDEX thread_tmp_workspace
  ON thread (tmp_workspace_id)
  WHERE tmp_workspace_id IS NOT NULL;

-- Backfill legacy Phase 1 env threads whose directories live at
-- `<workspace_root>/<thread_id>`. Tracks and GCs existing directories cleanly
-- without moving a single file on disk.
INSERT INTO workspace (id, kind, root, rel_path, thread_id, bot_id, created_at, last_used_at, deleted_at)
SELECT
  'ws-thread-' || id,
  'thread',
  workspace_root,
  id,
  id,
  NULL,
  created_at,
  last_active_at,
  NULL
FROM thread
WHERE workspace_root IS NOT NULL AND workspace_root <> '';

UPDATE thread
SET workspace_id = 'ws-thread-' || id
WHERE workspace_root IS NOT NULL AND workspace_root <> '';
