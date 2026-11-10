-- One session's messages in append-only order, with the session's
-- denormalized message_count (the authoritative persisted transcript
-- length, including the system prompt — a multi-call assistant message is
-- one message but several rows, so rows alone would undercount).
-- created_at is the display-only wall-clock stamp (NULL for unstamped
-- rows: a multi-call assistant message's continuation rows carry no
-- stamp of their own — the stamp rides the message's first row).
-- It reads through the 0 sentinel (0 = unstamped) rather than relying on
-- NULL: Postgres reports expression results as NOT NULL in the wire
-- protocol's row description, so squirrel would generate a non-optional
-- decoder for a bare extract(...) and crash on NULL rows — the same
-- sentinel workaround as the '' text sentinel (insert_provider.sql).
select m.seq, m.role, m.content, m.tool_call_id, m.tool_name, m.tool_args, m.tool_ok, m.reasoning, coalesce(extract(epoch from m.created_at)::int8, 0) as created_s, s.message_count
from session_message m
join session s on s.id = m.session_id
where m.session_id = $1
order by m.seq
