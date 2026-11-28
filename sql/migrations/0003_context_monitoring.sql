-- Context monitoring & per-bot/thread context budgets (Phase 1 of
-- docs/plans/context-compaction.md). All three columns are display/budget
-- metadata and never enter request bytes.

alter table bot
  add column context_window int check (context_window is null or context_window >= 4096);

alter table thread
  add column context_window int check (context_window is null or context_window >= 4096),
  add column last_context_tokens int check (last_context_tokens is null or last_context_tokens >= 0);
