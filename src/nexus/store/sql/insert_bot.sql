-- A new bot row. `system_prompt` is NULL = global default (resolved at
-- thread creation, never at request time); the '' sentinel inserts NULL —
-- Postgres exposes no parameter nullability, so squirrel parameters cannot
-- be nullable and the sentinel is its documented workaround (see
-- insert_provider.sql).
insert into bot (id, name, description, provider_id, model, system_prompt, created_at, updated_at)
values ($1, $2, $3, $4, $5, nullif($6, ''), to_timestamp($7), to_timestamp($7))
