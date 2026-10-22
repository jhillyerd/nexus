-- Append a user or plain-assistant row. Idempotent on replay.
-- reasoning is display-only chain-of-thought; the '' sentinel inserts
-- NULL — Postgres exposes no parameter nullability, so squirrel
-- parameters cannot be nullable and the sentinel is its documented
-- workaround (see insert_provider.sql).
insert into session_message (session_id, seq, role, content, reasoning)
values ($1, $2, $3, $4, nullif($5, ''::text))
on conflict (session_id, seq) do nothing
