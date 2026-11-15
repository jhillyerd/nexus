-- Bump a node's last-seen stamp on an authenticated connect.
update node set last_seen_at = now() where id = $1
