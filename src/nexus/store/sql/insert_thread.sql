-- A new thread row + its frozen toolset manifest in ONE statement
-- (plugin-api plan Phase 2): the manifest rows ride a CTE off the
-- inserted thread's id, so a half-thread (row without manifest) can
-- never exist. Created/last_active from the registry's epoch seconds;
-- message_count is the transcript length (1 = system prompt).
-- provider_id is frozen at creation with the model (contract rule 2).
-- The manifest arrives as ONE json array param ($12) — a transport
-- encoding only; the stored columns stay TEXT (jsonb normalizes, which
-- would break the byte-identical hydration contract). Entries:
-- [{"seq":N,"name":"<qualified>","description":"...","schema_json":...|"null"}]
-- in envelope order; schema_json null = a plain in-process name.
-- bot_id is provenance only (bots plan P1): the '' sentinel inserts
-- NULL (see insert_bot.sql). workspace_root (environments plan Phase 1)
-- is the RESOLVED root frozen at creation for env-carrying threads; the
-- '' sentinel inserts NULL (the same nullif pattern as bot_id).
-- tags_manual is '{}' literally and tags_source is left to its column
-- default 'auto' (utility-tags plan §3.5): a new thread has no tags and
-- an open auto path.
with new_thread as (
  insert into thread (id, provider_id, title, title_source, model, system_prompt, pinned, tags, tags_manual, created_at, last_active_at, message_count, bot_id, workspace_root)
  values ($1, $2, $3, $4, $5, $6, $7, $8, '{}', to_timestamp($9), to_timestamp($9), $10, nullif($11, ''), nullif($13, ''))
  returning id
),
manifest as (
  insert into thread_toolset (thread_id, seq, name, description, schema_json)
  select
    new_thread.id,
    e.seq,
    e.name,
    e.description,
    e.schema_json
  from new_thread,
       json_to_recordset($12::json)
         as e(seq int, name text, description text, schema_json text)
)
-- Environments plan Phase 1: the creation-time roster row, persisted
-- in the SAME statement so the write-behind watermark (seeded from
-- message_count, which counts it) matches the stored rows from the
-- first insert — the row is seq 0 under the watermark's
-- transcript-index-to-seq mapping (system prompt rides the column,
-- never a row). ''-sentinel content = no roster row.
insert into thread_message (thread_id, seq, role, content, reasoning, created_at, author, hop_depth)
select new_thread.id, 0, 'user', $14, NULL, to_timestamp(nullif($15, 0::bigint)), 'system', 0
from new_thread
where $14 <> ''
on conflict (thread_id, seq) do nothing
