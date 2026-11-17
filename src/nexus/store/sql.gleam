//// This module contains the code to run the sql queries defined in
//// `./src/nexus/store/sql`.
//// > 🐿️ This module was generated automatically using v4.7.0 of
//// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
////

import gleam/dynamic/decode
import gleam/json.{type Json}
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
/// author is display-only provenance (bots P3b: which bot sent this user
/// message); the '' sentinel inserts NULL the same way — NULL = a human
/// sent it, and an authored row never travels as ''.
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
  arg_7: String,
  arg_8: Int,
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
-- author is display-only provenance (bots P3b: which bot sent this user
-- message); the '' sentinel inserts NULL the same way — NULL = a human
-- sent it, and an authored row never travels as ''.
insert into thread_message (thread_id, seq, role, content, reasoning, created_at, author, hop_depth)
values ($1, $2, $3, $4, nullif($5, ''::text), to_timestamp(nullif($6, 0::bigint)), nullif($7, ''::text), $8)
on conflict (thread_id, seq) do nothing
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.text(arg_5))
  |> pog.parameter(pog.int(arg_6))
  |> pog.parameter(pog.text(arg_7))
  |> pog.parameter(pog.int(arg_8))
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

/// Archive ONE thread and CASCADE down its channel subtree (bot-channels
/// plan, #123): parent_thread_id makes channels of channels (hop chains),
/// and an archived parent cannot originate turns, so its whole descendant
/// tree goes quiescent with it. ONE idempotent recursive statement is the
/// authority — the registry syncs memory only from its acknowledged
/// outcome, so a failed write leaves nothing archived (in memory or on
/// disk). Archiving implicitly clears the pin everywhere it lands (the
/// `archived ⇒ ¬pinned` invariant). Retried on a transient failure, the
/// statement converges (already-archived rows just re-stamp).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn archive(
  db: pog.Connection,
  id: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- Archive ONE thread and CASCADE down its channel subtree (bot-channels
-- plan, #123): parent_thread_id makes channels of channels (hop chains),
-- and an archived parent cannot originate turns, so its whole descendant
-- tree goes quiescent with it. ONE idempotent recursive statement is the
-- authority — the registry syncs memory only from its acknowledged
-- outcome, so a failed write leaves nothing archived (in memory or on
-- disk). Archiving implicitly clears the pin everywhere it lands (the
-- `archived ⇒ ¬pinned` invariant). Retried on a transient failure, the
-- statement converges (already-archived rows just re-stamp).
with recursive tree as (
  select id from thread where id = $1
  union all
  select t.id from thread t join tree on t.parent_thread_id = tree.id
)
update thread set archived_at = now(), pinned = false
where id in (select id from tree)
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

/// Hard delete (token revoke): removing the row removes the node's
/// authority.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn delete_node(
  db: pog.Connection,
  id: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- Hard delete (token revoke): removing the row removes the node's
-- authority.
delete from node where id = $1
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

/// A row you get from running the `find_channel` query
/// defined in `./src/nexus/store/sql/find_channel.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type FindChannelRow {
  FindChannelRow(id: String)
}

/// The channel re-derivation lookup (bot-channels plan, #123): find the
/// existing DM channel for one (parent thread, target bot) pair. The
/// registry consults this on a `dm` MAP MISS — a restart lost the map,
/// and blind find-or-create would open a DUPLICATE channel behind the
/// first post-restart delivery. The partial unique index thread_channel
/// guarantees at most one row answers; the caller maps [] to "none, may
/// create" and a row to "repoint the map and deliver". A store ERROR is
/// never a miss: the caller refuses retryably instead of creating.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn find_channel(
  db: pog.Connection,
  parent_thread_id: String,
  bot_id: String,
) -> Result(pog.Returned(FindChannelRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.string)
    decode.success(FindChannelRow(id:))
  }

  "-- The channel re-derivation lookup (bot-channels plan, #123): find the
-- existing DM channel for one (parent thread, target bot) pair. The
-- registry consults this on a `dm` MAP MISS — a restart lost the map,
-- and blind find-or-create would open a DUPLICATE channel behind the
-- first post-restart delivery. The partial unique index thread_channel
-- guarantees at most one row answers; the caller maps [] to \"none, may
-- create\" and a row to \"repoint the map and deliver\". A store ERROR is
-- never a miss: the caller refuses retryably instead of creating.
select id
from thread
where parent_thread_id = $1
  and bot_id = $2
"
  |> pog.query
  |> pog.parameter(pog.text(parent_thread_id))
  |> pog.parameter(pog.text(bot_id))
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

/// A row you get from running the `get_node_by_name` query
/// defined in `./src/nexus/store/sql/get_node_by_name.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type GetNodeByNameRow {
  GetNodeByNameRow(
    id: String,
    name: String,
    token_hash: String,
    created_s: Int,
    last_seen_s: Int,
  )
}

/// One node row by NAME (the stateless token-verification lookup key).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn get_node_by_name(
  db: pog.Connection,
  name: String,
) -> Result(pog.Returned(GetNodeByNameRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.string)
    use name <- decode.field(1, decode.string)
    use token_hash <- decode.field(2, decode.string)
    use created_s <- decode.field(3, decode.int)
    use last_seen_s <- decode.field(4, decode.int)
    decode.success(GetNodeByNameRow(
      id:,
      name:,
      token_hash:,
      created_s:,
      last_seen_s:,
    ))
  }

  "-- One node row by NAME (the stateless token-verification lookup key).
select
  id,
  name,
  token_hash,
  extract(epoch from created_at)::int8 as created_s,
  coalesce(extract(epoch from last_seen_at)::int8, 0) as last_seen_s
from node
where name = $1
"
  |> pog.query
  |> pog.parameter(pog.text(name))
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
    toolset: String,
    bot_id: Option(String),
    workspace_root: Option(String),
    parent_thread_id: Option(String),
    created_s: Int,
    last_active_s: Int,
    message_count: Int,
  )
}

/// One stored thread row (lazy hydration of a dormant thread). The
/// provenance columns ride along (utility-tags plan §3.5): rehydration
/// must never lack them. bot_id is the bots plan's provenance pointer
/// (NULL = created without a bot; display only, never request bytes).
/// toolset is the frozen toolset manifest (plugin-api plan Phase 2),
/// aggregated in seq order as ONE json text (a transport encoding; the
/// stored columns are TEXT — see thread_toolset in schema.sql): the
/// ordered entries hydration replays through the config-independent
/// catalog ∪ foreign mounts, NEVER contacting the server.
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
    use toolset <- decode.field(11, decode.string)
    use bot_id <- decode.field(12, decode.optional(decode.string))
    use workspace_root <- decode.field(13, decode.optional(decode.string))
    use parent_thread_id <- decode.field(14, decode.optional(decode.string))
    use created_s <- decode.field(15, decode.int)
    use last_active_s <- decode.field(16, decode.int)
    use message_count <- decode.field(17, decode.int)
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
      workspace_root:,
      parent_thread_id:,
      created_s:,
      last_active_s:,
      message_count:,
    ))
  }

  "-- One stored thread row (lazy hydration of a dormant thread). The
-- provenance columns ride along (utility-tags plan §3.5): rehydration
-- must never lack them. bot_id is the bots plan's provenance pointer
-- (NULL = created without a bot; display only, never request bytes).
-- toolset is the frozen toolset manifest (plugin-api plan Phase 2),
-- aggregated in seq order as ONE json text (a transport encoding; the
-- stored columns are TEXT — see thread_toolset in schema.sql): the
-- ordered entries hydration replays through the config-independent
-- catalog ∪ foreign mounts, NEVER contacting the server.
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
  (select coalesce(json_agg(row_to_json(e) order by e.seq), '[]'::json)::text
     from thread_toolset e
    where e.thread_id = thread.id) as toolset,
  bot_id,
  workspace_root,
  parent_thread_id,
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

/// A new node row (environments plan Phase 2b): the remote paired-TUI
/// node entity. `token_hash` is the SHA-256 digest of the bearer token
/// (nexus/node.gleam) — NEVER the plaintext. `last_seen_at` is
/// to_timestamp(nullif($5, 0)): the 0 sentinel — a fresh pair has never
/// connected, so the column is NULL.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn insert_node(
  db: pog.Connection,
  arg_1: String,
  arg_2: String,
  arg_3: String,
  arg_4: Float,
  arg_5: Int,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- A new node row (environments plan Phase 2b): the remote paired-TUI
-- node entity. `token_hash` is the SHA-256 digest of the bearer token
-- (nexus/node.gleam) — NEVER the plaintext. `last_seen_at` is
-- to_timestamp(nullif($5, 0)): the 0 sentinel — a fresh pair has never
-- connected, so the column is NULL.
insert into node (id, name, token_hash, created_at, last_seen_at)
values ($1, $2, $3, to_timestamp($4), to_timestamp(nullif($5, 0::bigint)))
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.parameter(pog.text(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.float(arg_4))
  |> pog.parameter(pog.int(arg_5))
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

/// A new thread row + its frozen toolset manifest in ONE statement
/// (plugin-api plan Phase 2): the manifest rows ride a CTE off the
/// inserted thread's id, so a half-thread (row without manifest) can
/// never exist. Created/last_active from the registry's epoch seconds;
/// message_count is the transcript length (1 = system prompt).
/// provider_id is frozen at creation with the model (contract rule 2).
/// The manifest arrives as ONE json array param ($12) — a transport
/// encoding only; the stored columns stay TEXT (jsonb normalizes, which
/// would break the byte-identical hydration contract). Entries:
/// [{"seq":N,"name":"<qualified>","description":"...","schema_json":...|"null"}]
/// in envelope order; schema_json null = a plain in-process name.
/// bot_id is provenance only (bots plan P1): the '' sentinel inserts
/// NULL (see insert_bot.sql). workspace_root (environments plan Phase 1)
/// is the RESOLVED root frozen at creation for env-carrying threads; the
/// '' sentinel inserts NULL (the same nullif pattern as bot_id).
/// parent_thread_id (bot-channels plan, #123) links a DM channel to its
/// parent thread; the '' sentinel inserts NULL (ordinary threads). The
/// FK + the partial unique index thread_channel enforce the identity.
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
  arg_11: String,
  arg_12: Json,
  arg_13: String,
  arg_14: String,
  arg_15: Int,
  arg_16: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- A new thread row + its frozen toolset manifest in ONE statement
-- (plugin-api plan Phase 2): the manifest rows ride a CTE off the
-- inserted thread's id, so a half-thread (row without manifest) can
-- never exist. Created/last_active from the registry's epoch seconds;
-- message_count is the transcript length (1 = system prompt).
-- provider_id is frozen at creation with the model (contract rule 2).
-- The manifest arrives as ONE json array param ($12) — a transport
-- encoding only; the stored columns stay TEXT (jsonb normalizes, which
-- would break the byte-identical hydration contract). Entries:
-- [{\"seq\":N,\"name\":\"<qualified>\",\"description\":\"...\",\"schema_json\":...|\"null\"}]
-- in envelope order; schema_json null = a plain in-process name.
-- bot_id is provenance only (bots plan P1): the '' sentinel inserts
-- NULL (see insert_bot.sql). workspace_root (environments plan Phase 1)
-- is the RESOLVED root frozen at creation for env-carrying threads; the
-- '' sentinel inserts NULL (the same nullif pattern as bot_id).
-- parent_thread_id (bot-channels plan, #123) links a DM channel to its
-- parent thread; the '' sentinel inserts NULL (ordinary threads). The
-- FK + the partial unique index thread_channel enforce the identity.
-- tags_manual is '{}' literally and tags_source is left to its column
-- default 'auto' (utility-tags plan §3.5): a new thread has no tags and
-- an open auto path.
with new_thread as (
  insert into thread (id, provider_id, title, title_source, model, system_prompt, pinned, tags, tags_manual, created_at, last_active_at, message_count, bot_id, workspace_root, parent_thread_id)
  values ($1, $2, $3, $4, $5, $6, $7, $8, '{}', to_timestamp($9), to_timestamp($9), $10, nullif($11, ''), nullif($13, ''), nullif($16, ''))
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
  |> pog.parameter(pog.text(arg_11))
  |> pog.parameter(pog.text(json.to_string(arg_12)))
  |> pog.parameter(pog.text(arg_13))
  |> pog.parameter(pog.text(arg_14))
  |> pog.parameter(pog.int(arg_15))
  |> pog.parameter(pog.text(arg_16))
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

/// A row you get from running the `list_nodes` query
/// defined in `./src/nexus/store/sql/list_nodes.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type ListNodesRow {
  ListNodesRow(
    id: String,
    name: String,
    token_hash: String,
    created_s: Int,
    last_seen_s: Int,
  )
}

/// All node rows (registry boot load), ordered by id.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn list_nodes(
  db: pog.Connection,
) -> Result(pog.Returned(ListNodesRow), pog.QueryError) {
  let decoder = {
    use id <- decode.field(0, decode.string)
    use name <- decode.field(1, decode.string)
    use token_hash <- decode.field(2, decode.string)
    use created_s <- decode.field(3, decode.int)
    use last_seen_s <- decode.field(4, decode.int)
    decode.success(ListNodesRow(
      id:,
      name:,
      token_hash:,
      created_s:,
      last_seen_s:,
    ))
  }

  "-- All node rows (registry boot load), ordered by id.
select
  id,
  name,
  token_hash,
  extract(epoch from created_at)::int8 as created_s,
  coalesce(extract(epoch from last_seen_at)::int8, 0) as last_seen_s
from node
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
    toolset: String,
    bot_id: Option(String),
    workspace_root: Option(String),
    parent_thread_id: Option(String),
    created_s: Int,
    last_active_s: Int,
    message_count: Int,
  )
}

/// All stored thread summaries, ordered by id (the registry re-sorts).
/// The provenance columns ride along (utility-tags plan §3.5): the boot
/// load must never lack them. bot_id is the bots plan's provenance
/// pointer (NULL = created without a bot); toolset is the frozen
/// toolset manifest (plugin-api plan Phase 2), aggregated in seq order
/// as ONE json text — the entries a dormant thread rehydrates its
/// runner bundle from, without contacting any server.
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
    use toolset <- decode.field(10, decode.string)
    use bot_id <- decode.field(11, decode.optional(decode.string))
    use workspace_root <- decode.field(12, decode.optional(decode.string))
    use parent_thread_id <- decode.field(13, decode.optional(decode.string))
    use created_s <- decode.field(14, decode.int)
    use last_active_s <- decode.field(15, decode.int)
    use message_count <- decode.field(16, decode.int)
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
      workspace_root:,
      parent_thread_id:,
      created_s:,
      last_active_s:,
      message_count:,
    ))
  }

  "-- All stored thread summaries, ordered by id (the registry re-sorts).
-- The provenance columns ride along (utility-tags plan §3.5): the boot
-- load must never lack them. bot_id is the bots plan's provenance
-- pointer (NULL = created without a bot); toolset is the frozen
-- toolset manifest (plugin-api plan Phase 2), aggregated in seq order
-- as ONE json text — the entries a dormant thread rehydrates its
-- runner bundle from, without contacting any server.
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
  (select coalesce(json_agg(row_to_json(e) order by e.seq), '[]'::json)::text
     from thread_toolset e
    where e.thread_id = thread.id) as toolset,
  bot_id,
  workspace_root,
  parent_thread_id,
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
    author: Option(String),
    hop_depth: Int,
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
/// author/hop_depth are the display-only provenance columns (bots P3b):
/// author is a plain nullable column (wire nullability is visible for
/// plain references, unlike expressions), hop_depth is NOT NULL DEFAULT
/// 0 so human rows read as 0 without a sentinel.
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
    use author <- decode.field(9, decode.optional(decode.string))
    use hop_depth <- decode.field(10, decode.int)
    use message_count <- decode.field(11, decode.int)
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
      author:,
      hop_depth:,
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
/// paths use for auto-titling) PLUS, for environment threads, the
/// creation-time roster row (workspace_root IS NOT NULL AND
/// message_count <= 2 — the row exists from creation and the first send
/// takes the count to >= 3; without the second arm an abandoned empty
/// env thread would never be swept), never titled
/// (title_source 'auto'; a manual rename is intent and survives), never
/// pinned (also intent). Archived or not: an archived empty is still
/// litter.
///
/// The grace window protects a thread another concurrently-running
/// server created moments ago and still holds live — it stays empty
/// until its first turn commits. 15 minutes is far past any first turn.
///
/// Parents with channel children are NEVER swept: the FK's CASCADE
/// would take the channels' committed history with them — a parent
/// looks never-used until its first turn commits, so a crash
/// mid-first-turn plus a restart after the grace window is exactly the
/// state where an old parent row still hangs a channel with durable
/// transcripts. The child check reads the same table CASCADE would
/// delete from.
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
-- paths use for auto-titling) PLUS, for environment threads, the
-- creation-time roster row (workspace_root IS NOT NULL AND
-- message_count <= 2 — the row exists from creation and the first send
-- takes the count to >= 3; without the second arm an abandoned empty
-- env thread would never be swept), never titled
-- (title_source 'auto'; a manual rename is intent and survives), never
-- pinned (also intent). Archived or not: an archived empty is still
-- litter.
--
-- The grace window protects a thread another concurrently-running
-- server created moments ago and still holds live — it stays empty
-- until its first turn commits. 15 minutes is far past any first turn.
--
-- Parents with channel children are NEVER swept: the FK's CASCADE
-- would take the channels' committed history with them — a parent
-- looks never-used until its first turn commits, so a crash
-- mid-first-turn plus a restart after the grace window is exactly the
-- state where an old parent row still hangs a channel with durable
-- transcripts. The child check reads the same table CASCADE would
-- delete from.
delete from thread
where (message_count <= 1 or (workspace_root is not null and message_count <= 2))
  and title_source = 'auto'
  and pinned = false
  and last_active_at < now() - interval '15 minutes'
  and not exists (
    select 1 from thread c where c.parent_thread_id = thread.id
  )
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

/// Bump a node's last-seen stamp on an authenticated connect.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn touch_node(
  db: pog.Connection,
  id: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- Bump a node's last-seen stamp on an authenticated connect.
update node set last_seen_at = now() where id = $1
"
  |> pog.query
  |> pog.parameter(pog.text(id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Unarchive ONE thread and its channel subtree (bot-channels plan,
/// #123) — the symmetric twin of archive.sql: restoring a parent restores
/// everything that cascade-archived with it (unambiguous today because
/// channels have no individual archive affordance). ONE idempotent
/// recursive statement, the same authority rule as archive.sql.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn unarchive(
  db: pog.Connection,
  id: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- Unarchive ONE thread and its channel subtree (bot-channels plan,
-- #123) — the symmetric twin of archive.sql: restoring a parent restores
-- everything that cascade-archived with it (unambiguous today because
-- channels have no individual archive affordance). ONE idempotent
-- recursive statement, the same authority rule as archive.sql.
with recursive tree as (
  select id from thread where id = $1
  union all
  select t.id from thread t join tree on t.parent_thread_id = tree.id
)
update thread set archived_at = null
where id in (select id from tree)
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
