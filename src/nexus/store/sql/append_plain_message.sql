-- Append a user or plain-assistant row. Idempotent on replay.
-- reasoning is display-only chain-of-thought; the '' sentinel inserts
-- NULL — Postgres exposes no parameter nullability, so squirrel
-- parameters cannot be nullable and the sentinel is its documented
-- workaround (see insert_provider.sql).
-- created_at is display-only (the chat log's per-message ages); the 0
-- sentinel inserts NULL the same way (to_timestamp(NULL) is NULL), so
-- unstamped rows stay honestly unstamped instead of borrowing the write
-- instant as a fake append time.
insert into session_message (session_id, seq, role, content, reasoning, created_at)
values ($1, $2, $3, $4, nullif($5, ''::text), to_timestamp(nullif($6, 0::bigint)))
on conflict (session_id, seq) do nothing
