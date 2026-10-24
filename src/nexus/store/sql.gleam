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
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- Append a user or plain-assistant row. Idempotent on replay.
-- reasoning is display-only chain-of-thought; the '' sentinel inserts
-- NULL — Postgres exposes no parameter nullability, so squirrel
-- parameters cannot be nullable and the sentinel is its documented
-- workaround (see insert_provider.sql).
insert into session_message (session_id, seq, role, content, reasoning)
values ($1, $2, $3, $4, nullif($5, ''::text))
on conflict (session_id, seq) do nothing
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.text(arg_5))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Append one assistant tool-call row (content = the message text, '' for
/// continuation rows of the same assistant message). The run's FIRST row
/// also carries the message's reasoning; the '' sentinel inserts NULL
/// (Postgres exposes no parameter nullability — see insert_provider.sql).
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
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- Append one assistant tool-call row (content = the message text, '' for
-- continuation rows of the same assistant message). The run's FIRST row
-- also carries the message's reasoning; the '' sentinel inserts NULL
-- (Postgres exposes no parameter nullability — see insert_provider.sql).
insert into session_message (session_id, seq, role, content, tool_call_id, tool_name, tool_args, reasoning)
values ($1, $2, 'assistant', $3, $4, $5, $6, nullif($7, ''::text))
on conflict (session_id, seq) do nothing
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.text(arg_5))
  |> pog.parameter(pog.text(arg_6))
  |> pog.parameter(pog.text(arg_7))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Append one tool-result row.
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
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- Append one tool-result row.
insert into session_message (session_id, seq, role, content, tool_call_id, tool_name, tool_ok)
values ($1, $2, 'tool', $3, $4, $5, $6)
on conflict (session_id, seq) do nothing
"
  |> pog.query
  |> pog.parameter(pog.text(arg_1))
  |> pog.parameter(pog.int(arg_2))
  |> pog.parameter(pog.text(arg_3))
  |> pog.parameter(pog.text(arg_4))
  |> pog.parameter(pog.text(arg_5))
  |> pog.parameter(pog.bool(arg_6))
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

  "update session set archived_at = now(), pinned = false
where id = $1
"
  |> pog.query
  |> pog.parameter(pog.text(id))
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
update session set title = $1
where id = $2 and title_source = 'auto' and title = ''
"
  |> pog.query
  |> pog.parameter(pog.text(title))
  |> pog.parameter(pog.text(id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Model-title upgrade (utility-titles plan §4.4): the guard is provenance
/// ONLY — the heuristic placeholder may be upgraded while the title is still
/// auto-generated; a manual rename wins forever. Twin of the registry's
/// in-memory UpgradeAutoTitle guard.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn auto_title_upgrade(
  db: pog.Connection,
  title: String,
  id: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- Model-title upgrade (utility-titles plan §4.4): the guard is provenance
-- ONLY — the heuristic placeholder may be upgraded while the title is still
-- auto-generated; a manual rename wins forever. Twin of the registry's
-- in-memory UpgradeAutoTitle guard.
update session set title = $1
where id = $2 and title_source = 'auto'
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
update session set last_active_at = now(), message_count = $1
where id = $2
"
  |> pog.query
  |> pog.parameter(pog.int(message_count))
  |> pog.parameter(pog.text(id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// A row you get from running the `count_sessions_for_provider` query
/// defined in `./src/nexus/store/sql/count_sessions_for_provider.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type CountSessionsForProviderRow {
  CountSessionsForProviderRow(sessions: Int)
}

/// How many sessions pin this provider — the registry's delete guard
/// (409 while > 0; prefer disabling).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn count_sessions_for_provider(
  db: pog.Connection,
  provider_id: String,
) -> Result(pog.Returned(CountSessionsForProviderRow), pog.QueryError) {
  let decoder = {
    use sessions <- decode.field(0, decode.int)
    decode.success(CountSessionsForProviderRow(sessions:))
  }

  "-- How many sessions pin this provider — the registry's delete guard
-- (409 while > 0; prefer disabling).
select count(*)::int8 as sessions
from session
where provider_id = $1
"
  |> pog.query
  |> pog.parameter(pog.text(provider_id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Hard delete of an unreferenced provider. While any session pins it,
/// the session_provider_id FK (ON DELETE RESTRICT) refuses the delete —
/// the registry's count-based 409 pre-check is the friendly copy of that
/// guard, this is the enforcement.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn delete_provider(
  db: pog.Connection,
  id: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- Hard delete of an unreferenced provider. While any session pins it,
-- the session_provider_id FK (ON DELETE RESTRICT) refuses the delete —
-- the registry's count-based 409 pre-check is the friendly copy of that
-- guard, this is the enforcement.
delete from provider where id = $1
"
  |> pog.query
  |> pog.parameter(pog.text(id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Runs the `delete_session` query
/// defined in `./src/nexus/store/sql/delete_session.sql`.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn delete_session(
  db: pog.Connection,
  id: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "delete from session where id = $1
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

/// A row you get from running the `get_session` query
/// defined in `./src/nexus/store/sql/get_session.sql`.
///
/// > 🐿️ This type definition was generated automatically using v4.7.0 of the
/// > [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub type GetSessionRow {
  GetSessionRow(
    id: String,
    provider_id: String,
    title: String,
    title_source: String,
    model: String,
    system_prompt: String,
    pinned: Bool,
    archived: Bool,
    tags: List(String),
    created_s: Int,
    last_active_s: Int,
    message_count: Int,
  )
}

/// One stored session row (lazy hydration of a dormant session).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn get_session(
  db: pog.Connection,
  id: String,
) -> Result(pog.Returned(GetSessionRow), pog.QueryError) {
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
    use created_s <- decode.field(9, decode.int)
    use last_active_s <- decode.field(10, decode.int)
    use message_count <- decode.field(11, decode.int)
    decode.success(GetSessionRow(
      id:,
      provider_id:,
      title:,
      title_source:,
      model:,
      system_prompt:,
      pinned:,
      archived:,
      tags:,
      created_s:,
      last_active_s:,
      message_count:,
    ))
  }

  "-- One stored session row (lazy hydration of a dormant session).
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
  extract(epoch from created_at)::int8 as created_s,
  extract(epoch from last_active_at)::int8 as last_active_s,
  message_count
from session
where id = $1
"
  |> pog.query
  |> pog.parameter(pog.text(id))
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

/// A new session row: created/last_active from the registry's epoch
/// seconds; message_count is the transcript length (1 = system prompt).
/// provider_id is frozen at creation with the model (contract rule 2).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn insert_session(
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
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "-- A new session row: created/last_active from the registry's epoch
-- seconds; message_count is the transcript length (1 = system prompt).
-- provider_id is frozen at creation with the model (contract rule 2).
insert into session (id, provider_id, title, title_source, model, system_prompt, pinned, tags, created_at, last_active_at, message_count)
values ($1, $2, $3, $4, $5, $6, $7, $8, to_timestamp($9), to_timestamp($9), $10)
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
    created_s: Int,
    last_active_s: Int,
    message_count: Int,
  )
}

/// All stored session summaries, ordered by id (the registry re-sorts).
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
    use created_s <- decode.field(8, decode.int)
    use last_active_s <- decode.field(9, decode.int)
    use message_count <- decode.field(10, decode.int)
    decode.success(ListSummariesRow(
      id:,
      provider_id:,
      title:,
      title_source:,
      model:,
      pinned:,
      archived:,
      tags:,
      created_s:,
      last_active_s:,
      message_count:,
    ))
  }

  "-- All stored session summaries, ordered by id (the registry re-sorts).
select
  id,
  provider_id,
  title,
  title_source,
  model,
  pinned,
  (archived_at is not null) as archived,
  tags,
  extract(epoch from created_at)::int8 as created_s,
  extract(epoch from last_active_at)::int8 as last_active_s,
  message_count
from session
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
    message_count: Int,
  )
}

/// One session's messages in append-only order, with the session's
/// denormalized message_count (the authoritative persisted transcript
/// length, including the system prompt — a multi-call assistant message is
/// one message but several rows, so rows alone would undercount).
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn load_messages(
  db: pog.Connection,
  m_session_id: String,
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
    use message_count <- decode.field(8, decode.int)
    decode.success(LoadMessagesRow(
      seq:,
      role:,
      content:,
      tool_call_id:,
      tool_name:,
      tool_args:,
      tool_ok:,
      reasoning:,
      message_count:,
    ))
  }

  "-- One session's messages in append-only order, with the session's
-- denormalized message_count (the authoritative persisted transcript
-- length, including the system prompt — a multi-call assistant message is
-- one message but several rows, so rows alone would undercount).
select m.seq, m.role, m.content, m.tool_call_id, m.tool_name, m.tool_args, m.tool_ok, m.reasoning, s.message_count
from session_message m
join session s on s.id = m.session_id
where m.session_id = $1
order by m.seq
"
  |> pog.query
  |> pog.parameter(pog.text(m_session_id))
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

/// Boot sweep: hard-delete never-used sessions older than the grace
/// window, in ONE statement (bounded startup work — the registry runs
/// this inside its actor-initialiser deadline).
///
/// Never-used = holds nothing but the frozen system prompt
/// (message_count <= 1 — the same "no user message yet" rule the send
/// paths use for auto-titling), never titled (title_source 'auto'; a
/// manual rename is intent and survives), never pinned (also intent).
/// Archived or not: an archived empty is still litter.
///
/// The grace window protects a session another concurrently-running
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

  "-- Boot sweep: hard-delete never-used sessions older than the grace
-- window, in ONE statement (bounded startup work — the registry runs
-- this inside its actor-initialiser deadline).
--
-- Never-used = holds nothing but the frozen system prompt
-- (message_count <= 1 — the same \"no user message yet\" rule the send
-- paths use for auto-titling), never titled (title_source 'auto'; a
-- manual rename is intent and survives), never pinned (also intent).
-- Archived or not: an archived empty is still litter.
--
-- The grace window protects a session another concurrently-running
-- server created moments ago and still holds live — it stays empty
-- until its first turn commits. 15 minutes is far past any first turn.
delete from session
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

  "update session set pinned = $1
where id = $2
"
  |> pog.query
  |> pog.parameter(pog.bool(pinned))
  |> pog.parameter(pog.text(id))
  |> pog.returning(decoder)
  |> pog.execute(db)
}

/// Runs the `set_tags` query
/// defined in `./src/nexus/store/sql/set_tags.sql`.
///
/// > 🐿️ This function was generated automatically using v4.7.0 of
/// > the [squirrel package](https://github.com/giacomocavalieri/squirrel).
///
pub fn set_tags(
  db: pog.Connection,
  tags: List(String),
  id: String,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let decoder = decode.map(decode.dynamic, fn(_) { Nil })

  "update session set tags = $1
where id = $2
"
  |> pog.query
  |> pog.parameter(pog.array(fn(value) { pog.text(value) }, tags))
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

  "update session set title = $1, title_source = 'manual'
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

  "update session set archived_at = null
where id = $1
"
  |> pog.query
  |> pog.parameter(pog.text(id))
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
/// updated_at is server-side now(), like the session metadata writes.
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
-- updated_at is server-side now(), like the session metadata writes.
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
