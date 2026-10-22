-- Append one assistant tool-call row (content = the message text, '' for
-- continuation rows of the same assistant message). The run's FIRST row
-- also carries the message's reasoning; the '' sentinel inserts NULL
-- (Postgres exposes no parameter nullability — see insert_provider.sql).
insert into session_message (session_id, seq, role, content, tool_call_id, tool_name, tool_args, reasoning)
values ($1, $2, 'assistant', $3, $4, $5, $6, nullif($7, ''::text))
on conflict (session_id, seq) do nothing
