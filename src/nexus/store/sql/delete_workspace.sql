-- Hard-delete one tombstoned workspace row after its directory has been
-- removed on disk (or confirmed absent). Scoped to `deleted_at is not null`
-- so GC can never drop a live workspace row.
delete from workspace
where id = $1
  and deleted_at is not null
