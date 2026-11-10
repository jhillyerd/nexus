-- Turn commit: recency + denormalized count (absolute, idempotent).
update thread set last_active_at = now(), message_count = $1
where id = $2
