-- Pending disk GC rows (docs/plans/workspace-sandbox.md, Phase 1): every
-- tombstoned workspace awaiting guarded recursive removal on disk, oldest
-- tombstone first.
select
  id,
  root,
  rel_path
from workspace
where deleted_at is not null
order by deleted_at asc, id asc
