-- Append one tool-result row.
-- created_at is display-only (the chat log's per-message ages); the 0
-- sentinel inserts NULL (see append_plain_message.sql).
insert into session_message (session_id, seq, role, content, tool_call_id, tool_name, tool_ok, created_at)
values ($1, $2, 'tool', $3, $4, $5, $6, to_timestamp(nullif($7, 0::bigint)))
on conflict (session_id, seq) do nothing
