-- Persist the latest context token count (measured or estimated) for a
-- thread so the UI usage pill seeds immediately after restart/hydration.
-- Display/budget metadata only — never enters request bytes.
update thread
set last_context_tokens = $1::int
where id = $2
