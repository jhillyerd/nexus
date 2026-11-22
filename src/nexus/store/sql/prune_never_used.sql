-- Delete locked never-used candidate thread ids inside the boot-prune
-- transaction, after their workspaces have been tombstoned.
delete from thread
where id = any($1::text[])
returning id
