-- Append a user or plain-assistant row. Idempotent on replay.
-- reasoning is display-only chain-of-thought; the '' sentinel inserts
-- NULL — Postgres exposes no parameter nullability, so squirrel
-- parameters cannot be nullable and the sentinel is its documented
-- workaround (see insert_provider.sql).
-- created_at is display-only (the chat log's per-message ages); the 0
-- sentinel inserts NULL the same way (to_timestamp(NULL) is NULL), so
-- unstamped rows stay honestly unstamped instead of borrowing the write
-- instant as a fake append time.
-- author is display-only provenance (bots P3b: which bot sent this user
-- message); the '' sentinel inserts NULL the same way — NULL = a human
-- sent it, and an authored row never travels as ''.
insert into thread_message (thread_id, seq, role, content, reasoning, created_at, author, hop_depth)
values ($1, $2, $3, $4, nullif($5, ''::text), to_timestamp(nullif($6, 0::bigint)), nullif($7, ''::text), $8)
on conflict (thread_id, seq) do nothing
