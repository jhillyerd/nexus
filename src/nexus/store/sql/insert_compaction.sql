-- Append one immutable compaction checkpoint for a thread.
-- roster_snapshot and focus use the '' -> NULL sentinel (squirrel has no
-- nullable parameters); before_tokens and after_tokens use the -1 -> NULL
-- sentinel (matching insert_thread.sql's last_context_tokens convention).
insert into thread_compaction (
  thread_id,
  cutoff_index,
  summary,
  roster_snapshot,
  focus,
  trigger_kind,
  before_tokens,
  after_tokens,
  created_at
) values (
  $1,
  $2::int,
  $3,
  nullif($4, ''::text),
  nullif($5, ''::text),
  $6,
  case when $7::int < 0 then null else $7::int end,
  case when $8::int < 0 then null else $8::int end,
  to_timestamp($9::bigint)
)
