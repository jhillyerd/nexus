-- The channel re-derivation lookup (bot-channels plan, #123): find the
-- existing DM channel for one (parent thread, target bot) pair. The
-- registry consults this on a `dm` MAP MISS — a restart lost the map,
-- and blind find-or-create would open a DUPLICATE channel behind the
-- first post-restart delivery. The partial unique index thread_channel
-- guarantees at most one row answers; the caller maps [] to "none, may
-- create" and a row to "repoint the map and deliver". A store ERROR is
-- never a miss: the caller refuses retryably instead of creating.
select id
from thread
where parent_thread_id = $1
  and bot_id = $2
