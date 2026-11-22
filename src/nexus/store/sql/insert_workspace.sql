-- Insert a managed workspace row directly (used for standalone/shared
-- workspaces and crash-recovery fixtures). Empty-string sentinels for
-- thread_id / bot_id insert NULL; 0 sentinels for last_used_at / deleted_at
-- insert NULL.
insert into workspace (id, kind, root, rel_path, thread_id, bot_id, created_at, last_used_at, deleted_at)
values (
  $1,
  $2,
  $3,
  $4,
  nullif($5, ''),
  nullif($6, ''),
  to_timestamp($7),
  to_timestamp(nullif($8, 0::bigint)),
  to_timestamp(nullif($9, 0::bigint))
)
