-- A new bot row. `system_prompt` is NULL = global default (resolved at
-- thread creation, never at request time); the '' sentinel inserts NULL —
-- Postgres exposes no parameter nullability, so squirrel parameters cannot
-- be nullable and the sentinel is its documented workaround (see
-- insert_provider.sql).
-- `tools` (bots plan P2) has TWO parameters for the same reason: $7 is the
-- explicit name list ('{}' = chat-only — an EMPTY array is meaningful, so
-- no nullif-style value sentinel can express NULL) and $8 is the
-- is-default flag — true inserts NULL = resolve the current default set
-- at thread creation.
-- `allow_inbound` (bots plan P3a) is the row's gate verbatim — creates
-- always carry true (bot.to_row), but the seam writes full rows, so the
-- column is a parameter like every other.
insert into bot (id, name, description, provider_id, model, system_prompt, tools, allow_inbound, created_at, updated_at)
values ($1, $2, $3, $4, $5, nullif($6, ''), case when $8::boolean then null else $7::text[] end, $10::boolean, to_timestamp($9), to_timestamp($9))
