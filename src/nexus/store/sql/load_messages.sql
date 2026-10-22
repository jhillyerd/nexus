-- One session's messages in append-only order, with the session's
-- denormalized message_count (the authoritative persisted transcript
-- length, including the system prompt — a multi-call assistant message is
-- one message but several rows, so rows alone would undercount).
select m.seq, m.role, m.content, m.tool_call_id, m.tool_name, m.tool_args, m.tool_ok, m.reasoning, s.message_count
from session_message m
join session s on s.id = m.session_id
where m.session_id = $1
order by m.seq
