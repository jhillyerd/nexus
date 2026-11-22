//// Bounded in-memory TTL + LRU cache for `web_fetch` converted documents.
////
//// Keeps follow-up pagination calls (`start_index > 0`) instant and
//// offset-stable even when the upstream page is dynamic, and avoids hammering
//// origin servers across turns or bots.
////
//// Process & failure isolation: the live actor runs under its own standalone
//// `OneForOne` supervisor started at boot (outside the `OneForAll` root tree)
//// so a cache crash never restarts threads or fails turns. Callers talk to it
//// through `Seam`, whose `named_seam` resolves `process.named` and wraps every
//// interaction in `rescue.rescue` + a short bounded call timeout — an absent,
//// restarting, or slow cache degrades transparently to an uncached fetch.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/string
import gleam/uri
import nexus/log
import nexus/rescue
import nexus/timing

/// Default maximum cached entries before LRU eviction.
pub const default_max_entries = 64

/// Default maximum total cached content bytes (16 MiB).
pub const default_max_bytes = 16_777_216

/// Bounded ask timeout for cache lookups — slow cache degrades to a miss
/// rather than delaying a tool call.
const call_timeout_ms = 250

/// One cached, already-converted `web_fetch` document (2xx only).
pub type CachedDoc {
  CachedDoc(
    status: Int,
    final_url: String,
    title: Option(String),
    content_type: String,
    format: String,
    content: String,
    total_chars: Int,
    raw_truncated: Bool,
  )
}

/// Injectable cache seam handed to `web_fetch` (real named actor or offline
/// fake).
pub type Seam {
  Seam(get: fn(String) -> Option(CachedDoc), put: fn(String, CachedDoc) -> Nil)
}

/// Messages accepted by the cache actor.
pub type Msg {
  Get(key: String, reply: Subject(Option(CachedDoc)))
  Put(key: String, doc: CachedDoc, reply: Subject(Nil))
}

// ---------------------------------------------------------------------------
// Key normalization
// ---------------------------------------------------------------------------

/// Normalize a requested URL into its cache key: strip the client-side URI
/// fragment (`#...`), lowercase scheme and host, and keep port, path, and
/// query parameters intact.
pub fn cache_key(url: String) -> String {
  let trimmed = string.trim(url)
  case uri.parse(trimmed) {
    Ok(parsed) ->
      uri.Uri(
        ..parsed,
        scheme: option.map(parsed.scheme, string.lowercase),
        host: option.map(parsed.host, string.lowercase),
        fragment: None,
      )
      |> uri.to_string
    Error(Nil) ->
      case string.split_once(trimmed, "#") {
        Ok(#(before, _)) -> before
        Error(Nil) -> trimmed
      }
  }
}

/// Size accounting for the total-bytes cap (UTF-8 bytes of the stored content).
pub fn doc_bytes(doc: CachedDoc) -> Int {
  string.byte_size(doc.content)
}

// ---------------------------------------------------------------------------
// Pure cache state (deterministic, offline-testable)
// ---------------------------------------------------------------------------

type Entry {
  Entry(
    doc: CachedDoc,
    bytes: Int,
    inserted_at_ms: Int,
    last_access_ms: Int,
    access_seq: Int,
  )
}

pub opaque type Cache {
  Cache(
    ttl_ms: Int,
    max_entries: Int,
    max_bytes: Int,
    total_bytes: Int,
    next_seq: Int,
    entries: Dict(String, Entry),
  )
}

pub fn new(
  ttl_ms ttl_ms: Int,
  max_entries max_entries: Int,
  max_bytes max_bytes: Int,
) -> Cache {
  Cache(
    ttl_ms: ttl_ms,
    max_entries: max_entries,
    max_bytes: max_bytes,
    total_bytes: 0,
    next_seq: 1,
    entries: dict.new(),
  )
}

pub fn size(cache: Cache) -> Int {
  dict.size(cache.entries)
}

pub fn total_bytes(cache: Cache) -> Int {
  cache.total_bytes
}

/// Look up `url` at monotonic timestamp `now_ms`. Lazily evicts an expired hit
/// and updates `last_access_ms` + `access_seq` on a live hit.
pub fn get(
  cache: Cache,
  url: String,
  now_ms: Int,
) -> #(Cache, Option(CachedDoc)) {
  case cache.ttl_ms <= 0 {
    True -> #(cache, None)
    False -> {
      let key = cache_key(url)
      case dict.get(cache.entries, key) {
        Error(Nil) -> #(cache, None)
        Ok(entry) ->
          case is_expired(entry, cache.ttl_ms, now_ms) {
            True -> {
              let next =
                Cache(
                  ..cache,
                  total_bytes: cache.total_bytes - entry.bytes,
                  entries: dict.delete(cache.entries, key),
                )
              #(next, None)
            }
            False -> {
              let touched =
                Entry(
                  ..entry,
                  last_access_ms: now_ms,
                  access_seq: cache.next_seq,
                )
              let next =
                Cache(
                  ..cache,
                  next_seq: cache.next_seq + 1,
                  entries: dict.insert(cache.entries, key, touched),
                )
              #(next, Some(entry.doc))
            }
          }
      }
    }
  }
}

/// Insert or replace `url` at monotonic timestamp `now_ms`.
///
/// Sweeps expired entries first, then evicts least-recently-used entries until
/// both `max_entries` and `max_bytes` are satisfied. Documents larger than
/// `max_bytes` (or when `ttl_ms <= 0` / `max_entries <= 0`) are not cached.
pub fn put(cache: Cache, url: String, doc: CachedDoc, now_ms: Int) -> Cache {
  let bytes = doc_bytes(doc)
  let key = cache_key(url)
  case cache.ttl_ms <= 0 || cache.max_entries <= 0 || bytes > cache.max_bytes {
    True -> delete_key(sweep_expired(cache, now_ms), key)
    False -> {
      let cache =
        cache
        |> sweep_expired(now_ms)
        |> delete_key(key)
        |> evict_for(bytes)
      let entry =
        Entry(
          doc: doc,
          bytes: bytes,
          inserted_at_ms: now_ms,
          last_access_ms: now_ms,
          access_seq: cache.next_seq,
        )
      Cache(
        ..cache,
        total_bytes: cache.total_bytes + bytes,
        next_seq: cache.next_seq + 1,
        entries: dict.insert(cache.entries, key, entry),
      )
    }
  }
}

fn is_expired(entry: Entry, ttl_ms: Int, now_ms: Int) -> Bool {
  now_ms - entry.inserted_at_ms >= ttl_ms
}

fn sweep_expired(cache: Cache, now_ms: Int) -> Cache {
  dict.fold(cache.entries, cache, fn(acc, key, entry) {
    case is_expired(entry, acc.ttl_ms, now_ms) {
      True -> delete_key(acc, key)
      False -> acc
    }
  })
}

fn delete_key(cache: Cache, key: String) -> Cache {
  case dict.get(cache.entries, key) {
    Error(Nil) -> cache
    Ok(entry) ->
      Cache(
        ..cache,
        total_bytes: cache.total_bytes - entry.bytes,
        entries: dict.delete(cache.entries, key),
      )
  }
}

fn evict_for(cache: Cache, incoming_bytes: Int) -> Cache {
  let need_slot = dict.size(cache.entries) >= cache.max_entries
  let need_bytes = cache.total_bytes + incoming_bytes > cache.max_bytes
  case need_slot || need_bytes {
    False -> cache
    True ->
      case oldest_key(cache.entries) {
        None -> cache
        Some(victim) -> evict_for(delete_key(cache, victim), incoming_bytes)
      }
  }
}

fn oldest_key(entries: Dict(String, Entry)) -> Option(String) {
  dict.to_list(entries)
  |> list.fold(None, fn(best: Option(#(String, Entry)), pair) {
    let #(key, entry) = pair
    case best {
      None -> Some(#(key, entry))
      Some(#(_, best_entry)) ->
        case
          entry.last_access_ms < best_entry.last_access_ms
          || {
            entry.last_access_ms == best_entry.last_access_ms
            && entry.access_seq < best_entry.access_seq
          }
        {
          True -> Some(#(key, entry))
          False -> best
        }
    }
  })
  |> option.map(fn(pair) { pair.0 })
}

// ---------------------------------------------------------------------------
// OTP actor, supervision, and fault-isolated Seam
// ---------------------------------------------------------------------------

type ActorState {
  ActorState(cache: Cache, now_ms: fn() -> Int)
}

fn monotonic_now_ms() -> Int {
  timing.now_us() / 1000
}

/// Start a named cache actor with the default entry/byte bounds and monotonic
/// clock.
pub fn start_named(
  name: Name(Msg),
  ttl_ms: Int,
) -> actor.StartResult(Subject(Msg)) {
  start_named_with_options(
    name: name,
    ttl_ms: ttl_ms,
    max_entries: default_max_entries,
    max_bytes: default_max_bytes,
    now_ms: monotonic_now_ms,
  )
}

/// Start a named cache actor with custom bounds and clock (for offline tests).
pub fn start_named_with_options(
  name name: Name(Msg),
  ttl_ms ttl_ms: Int,
  max_entries max_entries: Int,
  max_bytes max_bytes: Int,
  now_ms now_ms: fn() -> Int,
) -> actor.StartResult(Subject(Msg)) {
  actor.new(ActorState(
    cache: new(ttl_ms: ttl_ms, max_entries: max_entries, max_bytes: max_bytes),
    now_ms: now_ms,
  ))
  |> actor.named(name)
  |> actor.on_message(handle_message)
  |> actor.start
}

fn handle_message(state: ActorState, msg: Msg) -> actor.Next(ActorState, Msg) {
  let now = state.now_ms()
  case msg {
    Get(key, reply) -> {
      let #(next_cache, hit) = get(state.cache, key, now)
      process.send(reply, hit)
      actor.continue(ActorState(..state, cache: next_cache))
    }
    Put(key, doc, reply) -> {
      let next_cache = put(state.cache, key, doc, now)
      process.send(reply, Nil)
      actor.continue(ActorState(..state, cache: next_cache))
    }
  }
}

/// Build a fault-isolated `Seam` addressing `name`. Resolves `process.named`
/// first and wraps every bounded call in `rescue.rescue` — a dead, absent,
/// restarting, or wedged cache actor degrades silently to a miss / no-op.
pub fn named_seam(name: Name(Msg)) -> Seam {
  Seam(
    get: fn(url) {
      case process.named(name) {
        Error(_) -> None
        Ok(_) ->
          case
            rescue.rescue(fn() {
              actor.call(
                process.named_subject(name),
                call_timeout_ms,
                fn(reply) { Get(url, reply) },
              )
            })
          {
            Ok(hit) -> hit
            Error(_) -> None
          }
      }
    },
    put: fn(url, doc) {
      case process.named(name) {
        Error(_) -> Nil
        Ok(_) -> {
          let _ =
            rescue.rescue(fn() {
              actor.call(
                process.named_subject(name),
                call_timeout_ms,
                fn(reply) { Put(url, doc, reply) },
              )
            })
          Nil
        }
      }
    },
  )
}

/// Boot the cache actor inside its own standalone `OneForOne` supervisor
/// (outside the `OneForAll` root tree and unlinked from the caller) when
/// `ttl_ms > 0`. Returns `None` when disabled (`ttl_ms <= 0`) or if startup
/// fails (logged; degrades cleanly to uncached fetches rather than failing
/// boot). Because the supervisor is unlinked after start, even a cache
/// crash-loop exhausting restart tolerance only disables caching and never
/// terminates the server.
pub fn boot(ttl_ms: Int) -> Option(Seam) {
  case ttl_ms <= 0 {
    True -> None
    False -> {
      let name = process.new_name("nexus_web_fetch_cache")
      let sup =
        supervisor.new(supervisor.OneForOne)
        |> supervisor.add(
          supervision.worker(fn() { start_named(name, ttl_ms) }),
        )
      case supervisor.start(sup) {
        Ok(started) -> {
          process.unlink(started.pid)
          Some(named_seam(name))
        }
        Error(reason) -> {
          log.warn(
            "web_fetch_cache",
            "failed to start cache; running uncached",
            [
              log.str("reason", string.inspect(reason)),
            ],
          )
          None
        }
      }
    }
  }
}
