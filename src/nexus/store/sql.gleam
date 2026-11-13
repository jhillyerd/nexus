//// This module contains the code to run the sql queries defined in
//// `./src/nexus/store/sql`.
//// > 🐿️ This module was generated automatically using v4.7.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import gleam/option.{type Option}
import pog

/// Append a user or plain-assistant row. Idempotent on replay.
/// reasoning is display-only chain-of-thought; the '' sentinel inserts
/// NULL — Postgres exposes no parameter nullability, so squirrel
/// parameters cannot be nullable and the sentinel is its documented
/// workaround (see insert_provider.sql).
/// created_at is display-only (the chat log's per-message ages); the 0
/// sentinel inserts NULL the same way (to_timestamp(NULL) is NULL), so
/// unstamped rows stay honestly unstamped instead of borrowing the write
/// instant as a fake append time.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn append_plain_message(
  db: pog.Connection,
  arg_1: String,
  arg_2: Int,
  arg_3: String,
  arg_4: String,
  arg_5: String,
  arg_6: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- Append a user or plain-assistant row. Idempotent on replay.
-- reasoning is display-only chain-of-thought; the '' sentinel inserts
-- NULL — Postgres exposes no parameter nullability, so squirrel
-- parameters cannot be nullable and the sentinel is its documented
-- workaround (see insert_provider.sql).
-- created_at is display-only (the chat log's per-message ages); the 0
-- sentinel inserts NULL the same way (to_timestamp(NULL) is NULL), so
-- unstamped rows stay honestly unstamped instead of borrowing the write
-- instant as a fake append time.
insert into thread_message (thread_id, seq, role, content, reasoning, created_at)
values ($1, $2, $3, $4, nullif($5, ''::text), to_timestamp(nullif($6, 0::bigint)))
on conflict (thread_id, seq) do nothing
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.text(arg_5))
  |> pog.parameter(pog.int(arg_6))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Append one assistant tool-call row (content = the message text, '' for
/// continuation rows of the same assistant message). The run's FIRST row
/// also carries the message's reasoning; the '' sentinel inserts NULL
/// (Postgres exposes no parameter nullability — see insert_provider.sql).
/// created_at is display-only and follows the same first-row rule as
/// content/reasoning; the 0 sentinel inserts NULL (see
/// append_plain_message.sql).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn append_tool_call(
  db: pog.Connection,
  arg_1: String,
  arg_2: Int,
  arg_3: String,
  arg_4: String,
  arg_5: String,
  arg_6: String,
  arg_7: String,
  arg_8: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- Append one assistant tool-call row (content = the message text, '' for
-- continuation rows of the same assistant message). The run's FIRST row
-- also carries the message's reasoning; the '' sentinel inserts NULL
-- (Postgres exposes no parameter nullability — see insert_provider.sql).
-- created_at is display-only and follows the same first-row rule as
-- content/reasoning; the 0 sentinel inserts NULL (see
-- append_plain_message.sql).
insert into thread_message (thread_id, seq, role, content, tool_call_id, tool_name, tool_args, reasoning, created_at)
values ($1, $2, 'assistant', $3, $4, $5, $6, nullif($7, ''::text), to_timestamp(nullif($8, 0::bigint)))
on conflict (thread_id, seq) do nothing
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.text(arg_5))
  |> pog.parameter(pog.text(arg_6))
  |> pog.parameter(pog.text(arg_7))
  |> pog.parameter(pog.int(arg_8))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Append one tool-result row.
/// created_at is display-only (the chat log's per-message ages); the 0
/// sentinel inserts NULL (see append_plain_message.sql).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn append_tool_result(
  db: pog.Connection,
  arg_1: String,
  arg_2: Int,
  arg_3: String,
  arg_4: String,
  arg_5: String,
  arg_6: Bool,
  arg_7: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- Append one tool-result row.
-- created_at is display-only (the chat log's per-message ages); the 0
-- sentinel inserts NULL (see append_plain_message.sql).
insert into thread_message (thread_id, seq, role, content, tool_call_id, tool_name, tool_ok, created_at)
values ($1, $2, 'tool', $3, $4, $5, $6, to_timestamp(nullif($7, 0::bigint)))
on conflict (thread_id, seq) do nothing
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.text(arg_5))
  |> pog.parameter(pog.bool(arg_6))
  |> pog.parameter(pog.int(arg_7))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Runs the `archive` query
/// defined in `./src/nexus/store/sql/archive.sql`.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn archive(
  db: pog.Connection,
  id: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "update thread set archived_at = now(), pinned = false
where id = $1
"
  |> pog.query
  |> pog.parameter(pog.text(id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Model metadata upgrade (utility-tags plan §3.6): ONE update guarded
/// by BOTH provenance columns — it lands only while title_source AND
/// tags_source are 'auto' together. The refusal is whole-update, not
/// per-side: a manual rename OR a manual tag edit each closes the
/// ENTIRE auto path forever (neither column ever returns to 'auto'),
/// and a manual save racing an in-flight apply is refused here
/// atomically. Twin of the registry's in-memory UpgradeAutoTitle guard.
/// Rowcount is the guard outcome.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn auto_meta_upgrade(
  db: pog.Connection,
  arg_1: String,
  id: String,
  tags: List(String),
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- Model metadata upgrade (utility-tags plan §3.6): ONE update guarded
-- by BOTH provenance columns — it lands only while title_source AND
-- tags_source are 'auto' together. The refusal is whole-update, not
-- per-side: a manual rename OR a manual tag edit each closes the
-- ENTIRE auto path forever (neither column ever returns to 'auto'),
-- and a manual save racing an in-flight apply is refused here
-- atomically. Twin of the registry's in-memory UpgradeAutoTitle guard.
-- Rowcount is the guard outcome.
update thread set title = $1, tags = $3
where id = $2
  and title_source = 'auto'
  and tags_source = 'auto'
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.parameter(pog.text(id))
  |> pog.parameter(pog.array(fn(value) { pog.text(value) }, tags))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Auto-title only while the title is still the untouched auto default.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn auto_title(
  db: pog.Connection,
  title: String,
  id: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- Auto-title only while the title is still the untouched auto default.
update thread set title = $1
where id = $2 and title_source = 'auto' and title = ''
"
  |> pog.query
  |> pog.parameter(pog.text(title))
  |> pog.parameter(pog.text(id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Turn commit: recency + denormalized count (absolute, idempotent).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn bump_activity(
  db: pog.Connection,
  message_count: Int,
  id: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- Turn commit: recency + denormalized count (absolute, idempotent).
update thread set last_active_at = now(), message_count = $1
where id = $2
"
  |> pog.query
  |> pog.parameter(pog.int(message_count))
  |> pog.parameter(pog.text(id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `count_bots_for_provider` query
/// defined in `./src/nexus/store/sql/count_bots_for_provider.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type CountBotsForProviderRow {
  CountBotsForProviderRow(bots: Int)
}

/// How many bots point at this provider — the provider registry's delete
/// guard's bot half (409 while > 0, alongside count_threads_for_provider;
/// prefer disabling). A store COUNT, never a call into the bot registry.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn count_bots_for_provider(
  db: pog.Connection,
  provider_id: String,
) -> Result(pog.Returned(CountBotsForProviderRow), pog.QueryError) {
  let decoder = {
    use bots <- decode.field(0, decode.int)
    decode.success(CountBotsForProviderRow(bots:))
  }

  "-- How many bots point at this provider — the provider registry's delete
-- guard's bot half (409 while > 0, alongside count_threads_for_provider;
-- prefer disabling). A store COUNT, never a call into the bot registry.
select count(*)::int8 as bots
from bot
where provider_id = $1
"
  |> pog.query
  |> pog.parameter(pog.text(provider_id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `count_threads_for_provider` query
/// defined in `./src/nexus/store/sql/count_threads_for_provider.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type CountThreadsForProviderRow {
  CountThreadsForProviderRow(threads: Int)
}

/// How many threads pin this provider — the registry's delete guard
/// (409 while > 0; prefer disabling).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn count_threads_for_provider(
  db: pog.Connection,
  provider_id: String,
) -> Result(pog.Returned(CountThreadsForProviderRow), pog.QueryError) {
  let decoder = {
    use threads <- decode.field(0, decode.int)
    decode.success(CountThreadsForProviderRow(threads:))
  }

  "-- How many threads pin this provider — the registry's delete guard
-- (409 while > 0; prefer disabling).
select count(*)::int8 as threads
from thread
where provider_id = $1
"
  |> pog.query
  |> pog.parameter(pog.text(provider_id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Hard delete. No guard: `thread.bot_id` is ON DELETE SET NULL
/// (provenance only — a bot's threads are self-contained frozen columns),
/// so deleting a bot orphans nothing. The provider RESTRICT is the other
/// direction: `bot.provider_id` is ON DELETE RESTRICT (sql/schema.sql),
/// and delete_provider's 409 pre-check mirrors it.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn delete_bot(
  db: pog.Connection,
  id: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- Hard delete. No guard: `thread.bot_id` is ON DELETE SET NULL
-- (provenance only — a bot's threads are self-contained frozen columns),
-- so deleting a bot orphans nothing. The provider RESTRICT is the other
-- direction: `bot.provider_id` is ON DELETE RESTRICT (sql/schema.sql),
-- and delete_provider's 409 pre-check mirrors it.
delete from bot where id = $1
"
  |> pog.query
  |> pog.parameter(pog.text(id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Hard delete of an unreferenced provider. While any thread or bot
/// pins it, the thread_provider_id / bot.provider_id FKs (ON DELETE
/// RESTRICT) refuse the delete — the registry's count-based 409
/// pre-check is the friendly copy of that guard, this is the
/// enforcement.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn delete_provider(
  db: pog.Connection,
  id: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- Hard delete of an unreferenced provider. While any thread or bot
-- pins it, the thread_provider_id / bot.provider_id FKs (ON DELETE
-- RESTRICT) refuse the delete — the registry's count-based 409
-- pre-check is the friendly copy of that guard, this is the
-- enforcement.
delete from provider where id = $1
"
  |> pog.query
  |> pog.parameter(pog.text(id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Runs the `delete_thread` query
/// defined in `./src/nexus/store/sql/delete_thread.sql`.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn delete_thread(
  db: pog.Connection,
  id: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "delete from thread where id = $1
"
  |> pog.query
  |> pog.parameter(pog.text(id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `get_bot` query
/// defined in `./src/nexus/store/sql/get_bot.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type GetBotRow {
  GetBotRow(
    id: String,
    name: String,
    description: String,
    provider_id: String,
    model: String,
    system_prompt: Option(String),
    tools: Option(List(String)),
    allow_inbound: Bool,
    created_s: Int,
    updated_s: Int,
  )
}

/// One bot row by id. `Error` for unknown ids is decided by the caller
/// from the empty result. `tools` (bots plan P2): NULL = the default set
/// at thread-create time, '{}' = chat-only, else the explicit list (see
/// insert_bot.sql). `allow_inbound` (bots plan P3a) is the inbound gate.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn get_bot(
  db: pog.Connection,
  id: String,
) -> Result(pog.Returned(GetBotRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.string)
    use name <- decode.field(1, decode.string)
    use description <- decode.field(2, decode.string)
    use provider_id <- decode.field(3, decode.string)
    use model <- decode.field(4, decode.string)
    use system_prompt <- decode.field(5, decode.optional(decode.string))
    use tools <- decode.field(6, decode.optional(decode.list(decode.string)))
    use allow_inbound <- decode.field(7, decode.bool)
    use created_s <- decode.field(8, decode.int)
    use updated_s <- decode.field(9, decode.int)
    decode.success(GetBotRow(
      id:,
      name:,
      description:,
      provider_id:,
      model:,
      system_prompt:,
      tools:,
      allow_inbound:,
      created_s:,
      updated_s:,
    ))
  }

  "-- One bot row by id. `Error` for unknown ids is decided by the caller
-- from the empty result. `tools` (bots plan P2): NULL = the default set
-- at thread-create time, '{}' = chat-only, else the explicit list (see
-- insert_bot.sql). `allow_inbound` (bots plan P3a) is the inbound gate.
select
  id,
  name,
  description,
  provider_id,
  model,
  system_prompt,
  tools,
  allow_inbound,
  extract(epoch from created_at)::int8 as created_s,
  extract(epoch from updated_at)::int8 as updated_s
from bot
where id = $1
"
  |> pog.query
  |> pog.parameter(pog.text(id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `get_provider` query
/// defined in `./src/nexus/store/sql/get_provider.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type GetProviderRow {
  GetProviderRow(
    id: String,
    name: String,
    base_url: String,
    api_key_encrypted: Option(BitArray),
    key_version: Int,
    dialect: String,
    enabled: Bool,
    created_s: Int,
    updated_s: Int,
  )
}

/// One provider row by id. `Error` for unknown ids is decided by the
/// caller from the empty result; the envelope rides along for the
/// registry to decrypt (AAD = provider id).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn get_provider(
  db: pog.Connection,
  id: String,
) -> Result(pog.Returned(GetProviderRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.string)
    use name <- decode.field(1, decode.string)
    use base_url <- decode.field(2, decode.string)
    use api_key_encrypted <- decode.field(3, decode.optional(decode.bit_array))
    use key_version <- decode.field(4, decode.int)
    use dialect <- decode.field(5, decode.string)
    use enabled <- decode.field(6, decode.bool)
    use created_s <- decode.field(7, decode.int)
    use updated_s <- decode.field(8, decode.int)
    decode.success(GetProviderRow(
      id:,
      name:,
      base_url:,
      api_key_encrypted:,
      key_version:,
      dialect:,
      enabled:,
      created_s:,
      updated_s:,
    ))
  }

  "-- One provider row by id. `Error` for unknown ids is decided by the
-- caller from the empty result; the envelope rides along for the
-- registry to decrypt (AAD = provider id).
select
  id,
  name,
  base_url,
  api_key_encrypted,
  key_version,
  dialect,
  enabled,
  extract(epoch from created_at)::int8 as created_s,
  extract(epoch from updated_at)::int8 as updated_s
from provider
where id = $1
"
  |> pog.query
  |> pog.parameter(pog.text(id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `get_thread` query
/// defined in `./src/nexus/store/sql/get_thread.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type GetThreadRow {
  GetThreadRow(
    id: String,
    provider_id: String,
    title: String,
    title_source: String,
    model: String,
    system_prompt: String,
    pinned: Bool,
    archived: Bool,
    tags: List(String),
    tags_manual: List(String),
    tags_source: String,
    toolset: List(String),
    bot_id: Option(String),
    created_s: Int,
    last_active_s: Int,
    message_count: Int,
  )
}

/// One stored thread row (lazy hydration of a dormant thread). The
/// provenance columns ride along (utility-tags plan §3.5): rehydration
/// must never lack them. bot_id is the bots plan's provenance pointer
/// (NULL = created without a bot; display only, never request bytes).
/// toolset is the bots plan P2 snapshot: the resolved names hydration
/// resolves through the config-independent catalog (loud failure on a
/// name absent from the compiled code).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn get_thread(
  db: pog.Connection,
  id: String,
) -> Result(pog.Returned(GetThreadRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.string)
    use provider_id <- decode.field(1, decode.string)
    use title <- decode.field(2, decode.string)
    use title_source <- decode.field(3, decode.string)
    use model <- decode.field(4, decode.string)
    use system_prompt <- decode.field(5, decode.string)
    use pinned <- decode.field(6, decode.bool)
    use archived <- decode.field(7, decode.bool)
    use tags <- decode.field(8, decode.list(decode.string))
    use tags_manual <- decode.field(9, decode.list(decode.string))
    use tags_source <- decode.field(10, decode.string)
    use toolset <- decode.field(11, decode.list(decode.string))
    use bot_id <- decode.field(12, decode.optional(decode.string))
    use created_s <- decode.field(13, decode.int)
    use last_active_s <- decode.field(14, decode.int)
    use message_count <- decode.field(15, decode.int)
    decode.success(GetThreadRow(
      id:,
      provider_id:,
      title:,
      title_source:,
      model:,
      system_prompt:,
      pinned:,
      archived:,
      tags:,
      tags_manual:,
      tags_source:,
      toolset:,
      bot_id:,
      created_s:,
      last_active_s:,
      message_count:,
    ))
  }

  "-- One stored thread row (lazy hydration of a dormant thread). The
-- provenance columns ride along (utility-tags plan §3.5): rehydration
-- must never lack them. bot_id is the bots plan's provenance pointer
-- (NULL = created without a bot; display only, never request bytes).
-- toolset is the bots plan P2 snapshot: the resolved names hydration
-- resolves through the config-independent catalog (loud failure on a
-- name absent from the compiled code).
select
  id,
  provider_id,
  title,
  title_source,
  model,
  system_prompt,
  pinned,
  (archived_at is not null) as archived,
  tags,
  tags_manual,
  tags_source,
  toolset,
  bot_id,
  extract(epoch from created_at)::int8 as created_s,
  extract(epoch from last_active_at)::int8 as last_active_s,
  message_count
from thread
where id = $1
"
  |> pog.query
  |> pog.parameter(pog.text(id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A new bot row. `system_prompt` is NULL = global default (resolved at
/// thread creation, never at request time); the '' sentinel inserts NULL —
/// Postgres exposes no parameter nullability, so squirrel parameters cannot
/// be nullable and the sentinel is its documented workaround (see
/// insert_provider.sql).
/// `tools` (bots plan P2) has TWO parameters for the same reason: $7 is the
/// explicit name list ('{}' = chat-only — an EMPTY array is meaningful, so
/// no nullif-style value sentinel can express NULL) and $8 is the
/// is-default flag — true inserts NULL = resolve the current default set
/// at thread creation.
/// `allow_inbound` (bots plan P3a) is the row's gate verbatim — creates
/// always carry true (bot.to_row), but the seam writes full rows, so the
/// column is a parameter like every other.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn insert_bot(
  db: pog.Connection,
  arg_1: String,
  arg_2: String,
  arg_3: String,
  arg_4: String,
  arg_5: String,
  arg_6: String,
  arg_7: List(String),
  arg_8: Bool,
  arg_9: Float,
  arg_10: Bool,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- A new bot row. `system_prompt` is NULL = global default (resolved at
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
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.text(arg_5))
  |> pog.parameter(pog.text(arg_6))
  |> pog.parameter(pog.array(fn(value) { pog.text(value) }, arg_7))
  |> pog.parameter(pog.bool(arg_8))
  |> pog.parameter(pog.float(arg_9))
  |> pog.parameter(pog.bool(arg_10))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A new provider row. `api_key_encrypted` is the nexus/crypto envelope;
/// the '' sentinel inserts NULL (a keyless provider) — Postgres exposes
/// no parameter nullability, so squirrel parameters cannot be nullable
/// and the sentinel is its documented workaround.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn insert_provider(
  db: pog.Connection,
  arg_1: String,
  arg_2: String,
  arg_3: String,
  arg_4: BitArray,
  arg_5: Int,
  arg_6: String,
  arg_7: Bool,
  arg_8: Float,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- A new provider row. `api_key_encrypted` is the nexus/crypto envelope;
-- the '' sentinel inserts NULL (a keyless provider) — Postgres exposes
-- no parameter nullability, so squirrel parameters cannot be nullable
-- and the sentinel is its documented workaround.
insert into provider (id, name, base_url, api_key_encrypted, key_version, dialect, enabled, created_at, updated_at)
values ($1, $2, $3, nullif($4, ''::bytea), $5, $6, $7, to_timestamp($8), to_timestamp($8))
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.bytea(arg_4))
  |> pog.parameter(pog.int(arg_5))
  |> pog.parameter(pog.text(arg_6))
  |> pog.parameter(pog.bool(arg_7))
  |> pog.parameter(pog.float(arg_8))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A new thread row: created/last_active from the registry's epoch
/// seconds; message_count is the transcript length (1 = system prompt).
/// provider_id is frozen at creation with the model (contract rule 2).
/// toolset is the bots plan P2 snapshot: the RESOLVED tool names persisted
/// at creation (the default set's, or the creating bot's) — always
/// populated, never NULL-for-default, so neither a config change nor a
/// bot edit can re-aim this thread's envelope.
/// bot_id is provenance only (bots plan P1): the '' sentinel inserts
/// NULL (see insert_bot.sql) — a thread created without a bot.
/// tags_manual is '{}' literally and tags_source is left to its column
/// default 'auto' (utility-tags plan §3.5): a new thread has no tags and
/// an open auto path.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn insert_thread(
  db: pog.Connection,
  arg_1: String,
  arg_2: String,
  arg_3: String,
  arg_4: String,
  arg_5: String,
  arg_6: String,
  arg_7: Bool,
  arg_8: List(String),
  arg_9: Float,
  arg_10: Int,
  arg_11: List(String),
  arg_12: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- A new thread row: created/last_active from the registry's epoch
-- seconds; message_count is the transcript length (1 = system prompt).
-- provider_id is frozen at creation with the model (contract rule 2).
-- toolset is the bots plan P2 snapshot: the RESOLVED tool names persisted
-- at creation (the default set's, or the creating bot's) — always
-- populated, never NULL-for-default, so neither a config change nor a
-- bot edit can re-aim this thread's envelope.
-- bot_id is provenance only (bots plan P1): the '' sentinel inserts
-- NULL (see insert_bot.sql) — a thread created without a bot.
-- tags_manual is '{}' literally and tags_source is left to its column
-- default 'auto' (utility-tags plan §3.5): a new thread has no tags and
-- an open auto path.
insert into thread (id, provider_id, title, title_source, model, system_prompt, pinned, tags, tags_manual, created_at, last_active_at, message_count, toolset, bot_id)
values ($1, $2, $3, $4, $5, $6, $7, $8, '{}', to_timestamp($9), to_timestamp($9), $10, $11::text[], nullif($12, ''))
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.text(arg_5))
  |> pog.parameter(pog.text(arg_6))
  |> pog.parameter(pog.bool(arg_7))
  |> pog.parameter(pog.array(fn(value) { pog.text(value) }, arg_8))
  |> pog.parameter(pog.float(arg_9))
  |> pog.parameter(pog.int(arg_10))
  |> pog.parameter(pog.array(fn(value) { pog.text(value) }, arg_11))
  |> pog.parameter(pog.text(arg_12))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `list_bots` query
/// defined in `./src/nexus/store/sql/list_bots.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ListBotsRow {
  ListBotsRow(
    id: String,
    name: String,
    description: String,
    provider_id: String,
    model: String,
    system_prompt: Option(String),
    tools: Option(List(String)),
    allow_inbound: Bool,
    created_s: Int,
    updated_s: Int,
  )
}

/// All bot rows (registry boot load), ordered by id (the registry
/// re-sorts). Bots carry no secrets — the row IS the public shape.
/// `tools` (bots plan P2): NULL = the default set at thread-create time,
/// '{}' = chat-only, else the explicit list (see insert_bot.sql).
/// `allow_inbound` (bots plan P3a) is the inbound gate.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn list_bots(
  db: pog.Connection,
) -> Result(pog.Returned(ListBotsRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.string)
    use name <- decode.field(1, decode.string)
    use description <- decode.field(2, decode.string)
    use provider_id <- decode.field(3, decode.string)
    use model <- decode.field(4, decode.string)
    use system_prompt <- decode.field(5, decode.optional(decode.string))
    use tools <- decode.field(6, decode.optional(decode.list(decode.string)))
    use allow_inbound <- decode.field(7, decode.bool)
    use created_s <- decode.field(8, decode.int)
    use updated_s <- decode.field(9, decode.int)
    decode.success(ListBotsRow(
      id:,
      name:,
      description:,
      provider_id:,
      model:,
      system_prompt:,
      tools:,
      allow_inbound:,
      created_s:,
      updated_s:,
    ))
  }

  "-- All bot rows (registry boot load), ordered by id (the registry
-- re-sorts). Bots carry no secrets — the row IS the public shape.
-- `tools` (bots plan P2): NULL = the default set at thread-create time,
-- '{}' = chat-only, else the explicit list (see insert_bot.sql).
-- `allow_inbound` (bots plan P3a) is the inbound gate.
select
  id,
  name,
  description,
  provider_id,
  model,
  system_prompt,
  tools,
  allow_inbound,
  extract(epoch from created_at)::int8 as created_s,
  extract(epoch from updated_at)::int8 as updated_s
from bot
order by id
"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `list_providers` query
/// defined in `./src/nexus/store/sql/list_providers.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ListProvidersRow {
  ListProvidersRow(
    id: String,
    name: String,
    base_url: String,
    api_key_encrypted: Option(BitArray),
    key_version: Int,
    dialect: String,
    enabled: Bool,
    created_s: Int,
    updated_s: Int,
  )
}

/// All provider rows (boot load / registry cache refresh), ordered by id
/// (the registry re-sorts). The store hands CIPHERTEXT to the registry —
/// decryption lives there, never here.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn list_providers(
  db: pog.Connection,
) -> Result(pog.Returned(ListProvidersRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.string)
    use name <- decode.field(1, decode.string)
    use base_url <- decode.field(2, decode.string)
    use api_key_encrypted <- decode.field(3, decode.optional(decode.bit_array))
    use key_version <- decode.field(4, decode.int)
    use dialect <- decode.field(5, decode.string)
    use enabled <- decode.field(6, decode.bool)
    use created_s <- decode.field(7, decode.int)
    use updated_s <- decode.field(8, decode.int)
    decode.success(ListProvidersRow(
      id:,
      name:,
      base_url:,
      api_key_encrypted:,
      key_version:,
      dialect:,
      enabled:,
      created_s:,
      updated_s:,
    ))
  }

  "-- All provider rows (boot load / registry cache refresh), ordered by id
-- (the registry re-sorts). The store hands CIPHERTEXT to the registry —
-- decryption lives there, never here.
select
  id,
  name,
  base_url,
  api_key_encrypted,
  key_version,
  dialect,
  enabled,
  extract(epoch from created_at)::int8 as created_s,
  extract(epoch from updated_at)::int8 as updated_s
from provider
order by id
"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `list_summaries` query
/// defined in `./src/nexus/store/sql/list_summaries.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ListSummariesRow {
  ListSummariesRow(
    id: String,
    provider_id: String,
    title: String,
    title_source: String,
    model: String,
    pinned: Bool,
    archived: Bool,
    tags: List(String),
    tags_manual: List(String),
    tags_source: String,
    toolset: List(String),
    bot_id: Option(String),
    created_s: Int,
    last_active_s: Int,
    message_count: Int,
  )
}

/// All stored thread summaries, ordered by id (the registry re-sorts).
/// The provenance columns ride along (utility-tags plan §3.5): the boot
/// load must never lack them. bot_id is the bots plan's provenance
/// pointer (NULL = created without a bot); toolset is the bots plan P2
/// snapshot a dormant thread rehydrates its runner bundle from.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn list_summaries(
  db: pog.Connection,
) -> Result(pog.Returned(ListSummariesRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.string)
    use provider_id <- decode.field(1, decode.string)
    use title <- decode.field(2, decode.string)
    use title_source <- decode.field(3, decode.string)
    use model <- decode.field(4, decode.string)
    use pinned <- decode.field(5, decode.bool)
    use archived <- decode.field(6, decode.bool)
    use tags <- decode.field(7, decode.list(decode.string))
    use tags_manual <- decode.field(8, decode.list(decode.string))
    use tags_source <- decode.field(9, decode.string)
    use toolset <- decode.field(10, decode.list(decode.string))
    use bot_id <- decode.field(11, decode.optional(decode.string))
    use created_s <- decode.field(12, decode.int)
    use last_active_s <- decode.field(13, decode.int)
    use message_count <- decode.field(14, decode.int)
    decode.success(ListSummariesRow(
      id:,
      provider_id:,
      title:,
      title_source:,
      model:,
      pinned:,
      archived:,
      tags:,
      tags_manual:,
      tags_source:,
      toolset:,
      bot_id:,
      created_s:,
      last_active_s:,
      message_count:,
    ))
  }

  "-- All stored thread summaries, ordered by id (the registry re-sorts).
-- The provenance columns ride along (utility-tags plan §3.5): the boot
-- load must never lack them. bot_id is the bots plan's provenance
-- pointer (NULL = created without a bot); toolset is the bots plan P2
-- snapshot a dormant thread rehydrates its runner bundle from.
select
  id,
  provider_id,
  title,
  title_source,
  model,
  pinned,
  (archived_at is not null) as archived,
  tags,
  tags_manual,
  tags_source,
  toolset,
  bot_id,
  extract(epoch from created_at)::int8 as created_s,
  extract(epoch from last_active_at)::int8 as last_active_s,
  message_count
from thread
order by id
"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `load_messages` query
/// defined in `./src/nexus/store/sql/load_messages.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type LoadMessagesRow {
  LoadMessagesRow(
    seq: Int,
    role: String,
    content: String,
    tool_call_id: Option(String),
    tool_name: Option(String),
    tool_args: Option(String),
    tool_ok: Option(Bool),
    reasoning: Option(String),
    created_s: Int,
    message_count: Int,
  )
}

/// One thread's messages in append-only order, with the thread's
/// denormalized message_count (the authoritative persisted transcript
/// length, including the system prompt — a multi-call assistant message is
/// one message but several rows, so rows alone would undercount).
/// created_at is the display-only wall-clock stamp (NULL for unstamped
/// rows: a multi-call assistant message's continuation rows carry no
/// stamp of their own — the stamp rides the message's first row).
/// It reads through the 0 sentinel (0 = unstamped) rather than relying on
/// NULL: Postgres reports expression results as NOT NULL in the wire
/// protocol's row description, so squirrel would generate a non-optional
/// decoder for a bare extract(...) and crash on NULL rows — the same
/// sentinel workaround as the '' text sentinel (insert_provider.sql).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn load_messages(
  db: pog.Connection,
  m_thread_id: String,
) -> Result(pog.Returned(LoadMessagesRow), pog.QueryError) {
  let decoder = {
    use seq <- decode.field(0, decode.int)
    use role <- decode.field(1, decode.string)
    use content <- decode.field(2, decode.string)
    use tool_call_id <- decode.field(3, decode.optional(decode.string))
    use tool_name <- decode.field(4, decode.optional(decode.string))
    use tool_args <- decode.field(5, decode.optional(decode.string))
    use tool_ok <- decode.field(6, decode.optional(decode.bool))
    use reasoning <- decode.field(7, decode.optional(decode.string))
    use created_s <- decode.field(8, decode.int)
    use message_count <- decode.field(9, decode.int)
    decode.success(LoadMessagesRow(
      seq:,
      role:,
      content:,
      tool_call_id:,
      tool_name:,
      tool_args:,
      tool_ok:,
      reasoning:,
      created_s:,
      message_count:,
    ))
  }

  "-- One thread's messages in append-only order, with the thread's
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
from thread_message m
join thread s on s.id = m.thread_id
where m.thread_id = $1
order by m.seq
"
  |> pog.query
  |> pog.parameter(pog.text(m_thread_id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `prune_never_used` query
/// defined in `./src/nexus/store/sql/prune_never_used.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type PruneNeverUsedRow {
  PruneNeverUsedRow(id: String)
}

/// Boot sweep: hard-delete never-used threads older than the grace
/// window, in ONE statement (bounded startup work — the registry runs
/// this inside its actor-initialiser deadline).
///
/// Never-used = holds nothing but the frozen system prompt
/// (message_count <= 1 — the same "no user message yet" rule the send
/// paths use for auto-titling), never titled (title_source 'auto'; a
/// manual rename is intent and survives), never pinned (also intent).
/// Archived or not: an archived empty is still litter.
///
/// The grace window protects a thread another concurrently-running
/// server created moments ago and still holds live — it stays empty
/// until its first turn commits. 15 minutes is far past any first turn.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn prune_never_used(
  db: pog.Connection,
) -> Result(pog.Returned(PruneNeverUsedRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.string)
    decode.success(PruneNeverUsedRow(id:))
  }

  "-- Boot sweep: hard-delete never-used threads older than the grace
-- window, in ONE statement (bounded startup work — the registry runs
-- this inside its actor-initialiser deadline).
--
-- Never-used = holds nothing but the frozen system prompt
-- (message_count <= 1 — the same \"no user message yet\" rule the send
-- paths use for auto-titling), never titled (title_source 'auto'; a
-- manual rename is intent and survives), never pinned (also intent).
-- Archived or not: an archived empty is still litter.
--
-- The grace window protects a thread another concurrently-running
-- server created moments ago and still holds live — it stays empty
-- until its first turn commits. 15 minutes is far past any first turn.
delete from thread
where message_count <= 1
  and title_source = 'auto'
  and pinned = false
  and last_active_at < now() - interval '15 minutes'
returning id
"
  |> pog.query
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Runs the `set_pinned` query
/// defined in `./src/nexus/store/sql/set_pinned.sql`.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn set_pinned(
  db: pog.Connection,
  pinned: Bool,
  id: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "update thread set pinned = $1
where id = $2
"
  |> pog.query
  |> pog.parameter(pog.bool(pinned))
  |> pog.parameter(pog.text(id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// The manual tags save (utility-tags plan §3.5): the user's exact set
/// becomes the display set AND the manual set, and the row's auto path
/// closes — one statement, so the freeze itself is atomic (all three
/// fields or nothing; the tags_source flip is what auto_meta_upgrade's
/// guard reads).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn set_tags(
  db: pog.Connection,
  arg_1: List(String),
  id: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- The manual tags save (utility-tags plan §3.5): the user's exact set
-- becomes the display set AND the manual set, and the row's auto path
-- closes — one statement, so the freeze itself is atomic (all three
-- fields or nothing; the tags_source flip is what auto_meta_upgrade's
-- guard reads).
update thread set tags = $1, tags_manual = $1, tags_source = 'manual'
where id = $2
"
  |> pog.query
  |> pog.parameter(pog.array(fn(value) { pog.text(value) }, arg_1))
  |> pog.parameter(pog.text(id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Runs the `set_title` query
/// defined in `./src/nexus/store/sql/set_title.sql`.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn set_title(
  db: pog.Connection,
  arg_1: String,
  id: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "update thread set title = $1, title_source = 'manual'
where id = $2
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.parameter(pog.text(id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Runs the `unarchive` query
/// defined in `./src/nexus/store/sql/unarchive.sql`.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn unarchive(
  db: pog.Connection,
  id: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "update thread set archived_at = null
where id = $1
"
  |> pog.query
  |> pog.parameter(pog.text(id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Full-metadata bot update (the registry merges the PATCH onto the row
/// first, so this is a plain replace). `system_prompt` rides the ''
/// sentinel for NULL = global default (see insert_bot.sql). `tools` rides
/// the same two-parameter scheme as the insert: $7 is the explicit list
/// ('{}' = chat-only), $8 the is-default flag (true = NULL = the current
/// default set). `allow_inbound` (bots plan P3a) is the merged row's gate.
/// `updated_at` is server-side now(), like the provider/thread metadata
/// writes.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn update_bot(
  db: pog.Connection,
  id: String,
  arg_2: String,
  arg_3: String,
  arg_4: String,
  arg_5: String,
  arg_6: String,
  arg_7: List(String),
  arg_8: Bool,
  arg_9: Bool,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- Full-metadata bot update (the registry merges the PATCH onto the row
-- first, so this is a plain replace). `system_prompt` rides the ''
-- sentinel for NULL = global default (see insert_bot.sql). `tools` rides
-- the same two-parameter scheme as the insert: $7 is the explicit list
-- ('{}' = chat-only), $8 the is-default flag (true = NULL = the current
-- default set). `allow_inbound` (bots plan P3a) is the merged row's gate.
-- `updated_at` is server-side now(), like the provider/thread metadata
-- writes.
update bot set
  name = $2,
  description = $3,
  provider_id = $4,
  model = $5,
  system_prompt = nullif($6, ''),
  tools = case when $8::boolean then null else $7::text[] end,
  allow_inbound = $9::boolean,
  updated_at = now()
where id = $1
"
  |> pog.query
  |> pog.parameter(pog.text(id))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.text(arg_5))
  |> pog.parameter(pog.text(arg_6))
  |> pog.parameter(pog.array(fn(value) { pog.text(value) }, arg_7))
  |> pog.parameter(pog.bool(arg_8))
  |> pog.parameter(pog.bool(arg_9))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Full-metadata provider update. `replace_key` ($4) decides the key
/// envelope's fate so a PATCH without an api_key keeps the stored
/// ciphertext instead of nulling it:
/// false → envelope and key_version untouched (key param ignored);
/// true  → envelope := nullif($5, ''::bytea) — a real value replaces
/// it, the '' sentinel goes keyless (NULL) — and key_version
/// := $6. (Sentinel for the same reason as insert_provider.)
/// updated_at is server-side now(), like the thread metadata writes.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn update_provider(
  db: pog.Connection,
  id: String,
  arg_2: String,
  arg_3: String,
  arg_4: Bool,
  arg_5: BitArray,
  arg_6: Int,
  arg_7: Bool,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- Full-metadata provider update. `replace_key` ($4) decides the key
-- envelope's fate so a PATCH without an api_key keeps the stored
-- ciphertext instead of nulling it:
--   false → envelope and key_version untouched (key param ignored);
--   true  → envelope := nullif($5, ''::bytea) — a real value replaces
--           it, the '' sentinel goes keyless (NULL) — and key_version
--           := $6. (Sentinel for the same reason as insert_provider.)
-- updated_at is server-side now(), like the thread metadata writes.
update provider set
  name = $2,
  base_url = $3,
  api_key_encrypted = case when $4 then nullif($5, ''::bytea) else api_key_encrypted end,
  key_version = case when $4 then $6 else key_version end,
  enabled = $7,
  updated_at = now()
where id = $1
"
  |> pog.query
  |> pog.parameter(pog.text(id))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.bool(arg_4))
  |> pog.parameter(pog.bytea(arg_5))
  |> pog.parameter(pog.int(arg_6))
  |> pog.parameter(pog.bool(arg_7))
  |> pog.returning(decoder)
  |> pog.execute(db)
}
