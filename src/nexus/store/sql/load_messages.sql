-- One thread's messages in append-only order, with the thread's
-- denormalized message_count (the authoritative persisted transcript
-- length, including the system prompt — a multi-call assistant message is
-- one message but several rows, so rows alone would undercount).
-- created_at is the display-only wall-clock stamp (NULL for unstamped
-- rows: a multi-call assistant message's continuation rows carry no
-- stamp of their own — the stamp rides the message's first row).
-- author/hop_depth are the display-only provenance columns (bots P3b):
-- author is a plain nullable column (wire nullability is visible for
-- plain references, unlike expressions), hop_depth is NOT NULL DEFAULT
-- 0 so human rows read as 0 without a sentinel.
-- It reads through the 0 sentinel (0 = unstamped) rather than relying on
-- NULL: Postgres reports expression results as NOT NULL in the wire
-- protocol's row description, so squirrel would generate a non-optional
-- decoder for a bare extract(...) and crash on NULL rows — the same
-- sentinel workaround as the '' text sentinel (insert_provider.sql).
select m.seq, m.role, m.content, m.tool_call_id, m.tool_name, m.tool_args, m.tool_ok, m.reasoning, coalesce(extract(epoch from m.created_at)::int8, 0) as created_s, m.author, m.hop_depth, s.message_count
from thread_message m
join thread s on s.id = m.thread_id
where m.thread_id = $1
order by m.seq
