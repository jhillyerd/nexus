-- All compaction checkpoints for one thread in chronological order (oldest
-- first, by insertion id) so hydration replays them through
-- `transcript.apply_compaction` in exact order.
select
  id,
  cutoff_index,
  summary,
  roster_snapshot,
  focus,
  trigger_kind,
  before_tokens,
  after_tokens,
  extract(epoch from created_at)::int8 as created_s
from thread_compaction
where thread_id = $1
order by id asc
