update thread set archived_at = now(), pinned = false
where id = $1
