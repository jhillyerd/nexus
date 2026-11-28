-- Append-only compaction checkpoints (Phase 2 of
-- docs/plans/context-compaction.md). `thread_message` rows are NEVER deleted
-- or mutated; hydration loads messages plus checkpoints and `nexus/transcript`
-- projects the active request window from the latest checkpoint's `cutoff_index`.

create table thread_compaction (
  id              bigserial primary key,
  thread_id       text not null references thread(id) on delete cascade,
  cutoff_index    int not null check (cutoff_index > 0),
  summary         text not null,
  roster_snapshot text,
  focus           text,
  trigger_kind    text not null check (trigger_kind in ('auto', 'manual', 'overflow')),
  before_tokens   int check (before_tokens is null or before_tokens >= 0),
  after_tokens    int check (after_tokens is null or after_tokens >= 0),
  created_at      timestamptz not null
);

create index thread_compaction_thread on thread_compaction (thread_id, id desc);
