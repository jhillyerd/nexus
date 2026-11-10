-- Append one assistant tool-call row (content = the message text, '' for
-- continuation rows of the same assistant message). The run's FIRST row
-- also carries the message's reasoning; the '' sentinel inserts NULL
-- (Postgres exposes no parameter nullability — see insert_provider.sql).
-- created_at is display-only and follows the same first-row rule as
-- content/reasoning; the 0 sentinel inserts NULL (see
-- append_plain_message.sql).
insert into thread_message (thread_id, seq, role, content, tool_call_id, tool_name, tool_args, reasoning, created_at)
values ($1, $2, 'assistant', $3, $4, $5, $6, nullif($7, ''::text), to_timestamp(nullif($8, 0::bigint)))
on conflict (thread_id, seq) do nothing
