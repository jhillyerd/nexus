//// First-run provider seeding (`gleam run -m nexus/dev_seed`) — the
//// out-of-band alternative to the provider CRUD HTTP API (P4, landed)
//// for environments where the server is not running yet (CI, compose
//// bootstrap); the settings UI is P5.
////
//// The provider table is the only provider source after the P3 hard
//// cut (BIFROST_* env vars are gone), and a fresh database starts with
//// zero providers — so the very first provider has to be created
//// out-of-band. This tool does exactly one insert: it reads the seed
//// from the environment, encrypts the API key with the same
//// AES-256-GCM envelope the registry uses (AAD = provider id), and
//// writes the row through the committed squirrel query.
////
//// Env:
////   DATABASE_URL                 postgres URL (same convention as
////                                nexus/store/migrate)
////   NEXUS_ENCRYPTION_KEY         master key (base64 of 32 bytes)
////   NEXUS_SEED_PROVIDER_NAME     display name, default "seed"
////   NEXUS_SEED_PROVIDER_BASE_URL required, OpenAI-compatible, ends /v1
////   NEXUS_SEED_PROVIDER_API_KEY  optional — omit (or blank) for a
////                                keyless local endpoint
////
//// Idempotent by name: if a provider with that name already exists the
//// tool reports it and exits without writing. Ids follow the registry's
//// `p<N>` scheme, minted past the highest stored one. The key is never
//// printed, logged, or included in any error text.

import envoy
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import nexus/crypto
import nexus/provider
import nexus/store/sql
import nexus/timing
import pog

@external(erlang, "nexus_store_ffi", "database_url")
fn database_url() -> Result(String, Nil)

pub fn main() -> Nil {
  let db =
    database_url()
    |> or_panic("DATABASE_URL is not set")
    |> fn(url) { pog.url_config(process.new_name("nexus_dev_seed_pool"), url) }
    |> or_panic("invalid DATABASE_URL")
    |> pog.connection_parameter("timezone", "UTC")
    |> pog.start
    |> or_panic("could not connect — is the database up?")
    |> fn(started) { started.data }

  let key =
    envoy.get("NEXUS_ENCRYPTION_KEY")
    |> or_panic("NEXUS_ENCRYPTION_KEY is not set")
    |> crypto.decode_key
    |> or_panic("NEXUS_ENCRYPTION_KEY is not a base64 of exactly 32 bytes")

  let name =
    envoy.get("NEXUS_SEED_PROVIDER_NAME")
    |> result.unwrap("seed")
    |> string.trim
    |> provider.validate_name
    |> or_panic("NEXUS_SEED_PROVIDER_NAME must be non-empty")

  let base_url =
    envoy.get("NEXUS_SEED_PROVIDER_BASE_URL")
    |> or_panic("NEXUS_SEED_PROVIDER_BASE_URL is not set")
    |> provider.normalize_base_url
    |> or_panic(
      "NEXUS_SEED_PROVIDER_BASE_URL must be the OpenAI-compatible base ending in /v1",
    )

  // A submitted key, trimmed: "" means keyless (create) / keep (update).
  // The key never appears in any output below.
  let submitted_key =
    envoy.get("NEXUS_SEED_PROVIDER_API_KEY")
    |> result.unwrap("")
    |> string.trim
  case sql.list_providers(db) {
    Error(error) -> die("could not read providers: " <> describe(error))
    Ok(returned) -> {
      let rows = returned.rows
      case list.find(rows, fn(row) { row.name == name }) {
        Ok(existing) if existing.base_url == base_url && submitted_key == "" ->
          io.println(
            "dev_seed: provider \""
            <> name
            <> "\" already exists ("
            <> existing.id
            <> ") — nothing to do",
          )
        Ok(existing) ->
          // Re-point (dev/e2e ergonomics): same name, new base URL and/or
          // a freshly submitted key. An absent key KEEPS the stored
          // envelope — the registry's PATCH semantics, applied directly.
          upsert(
            db,
            key,
            existing.id,
            name,
            base_url,
            existing.enabled,
            submitted_key,
          )
        Error(_) -> seed(db, key, mint_id(rows), name, base_url, submitted_key)
      }
    }
  }
}

/// Encrypt the submitted key under AAD = the provider id. Blank/absent
/// maps to the queries' `''::bytea` sentinel (NULL at rest = keyless).
fn envelope_for(
  key: BitArray,
  id: String,
  submitted: String,
) -> Result(BitArray, Nil) {
  case submitted {
    "" -> Ok(<<>>)
    submitted -> crypto.encrypt(key, id, submitted) |> result.replace_error(Nil)
  }
}

fn seed(
  db: pog.Connection,
  key: BitArray,
  id: String,
  name: String,
  base_url: String,
  submitted_key: String,
) -> Nil {
  let envelope =
    envelope_for(key, id, submitted_key)
    |> or_panic("could not encrypt the submitted key")
  let now = int.to_float(timing.wall_now_s())
  case
    sql.insert_provider(
      db,
      id,
      name,
      base_url,
      envelope,
      1,
      "openai",
      True,
      now,
    )
  {
    Ok(_) ->
      report("created", id, name, base_url, case submitted_key {
        "" -> "keyless"
        _ -> "api key encrypted"
      })
    Error(error) -> die("insert failed: " <> describe(error))
  }
}

fn upsert(
  db: pog.Connection,
  key: BitArray,
  id: String,
  name: String,
  base_url: String,
  enabled: Bool,
  submitted_key: String,
) -> Nil {
  let replace_key = submitted_key != ""
  let envelope = case replace_key {
    True ->
      envelope_for(key, id, submitted_key)
      |> or_panic("could not encrypt the submitted key")
    False -> <<>>
  }
  case
    sql.update_provider(
      db,
      id,
      name,
      base_url,
      replace_key,
      envelope,
      1,
      enabled,
    )
  {
    Ok(_) ->
      report("updated", id, name, base_url, case replace_key {
        True -> "api key encrypted"
        False -> "api key kept"
      })
    Error(error) -> die("update failed: " <> describe(error))
  }
}

/// Fixed-shape confirmation line — never the key, only a key-state note.
fn report(
  verb: String,
  id: String,
  name: String,
  base_url: String,
  key_note: String,
) -> Nil {
  io.println(
    "dev_seed: "
    <> verb
    <> " provider "
    <> id
    <> " (\""
    <> name
    <> "\" → "
    <> base_url
    <> ", "
    <> key_note
    <> ")",
  )
}

fn mint_id(rows: List(sql.ListProvidersRow)) -> String {
  let max =
    rows
    |> list.fold(0, fn(max, row) {
      case string.split(row.id, on: "p") {
        ["", suffix] ->
          case int.parse(suffix) {
            Ok(n) -> int.max(max, n)
            Error(_) -> max
          }
        _ -> max
      }
    })
  "p" <> int.to_string(max + 1)
}

fn or_panic(result: Result(a, e), message: String) -> a {
  case result {
    Ok(value) -> value
    Error(reason) -> die(message <> " — " <> string.inspect(reason))
  }
}

fn die(message: String) -> a {
  io.println("dev_seed: " <> message)
  panic as "dev_seed failed"
}

fn describe(error: pog.QueryError) -> String {
  string.inspect(error)
}
