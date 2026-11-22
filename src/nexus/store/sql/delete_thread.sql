-- Hard-delete a thread (cascading its channel subtree and messages).
-- Run inside a transaction after tombstoning owned workspaces so
-- ON DELETE SET NULL never overlaps with setting deleted_at.
delete from thread where id = $1
