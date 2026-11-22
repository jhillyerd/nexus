//// Unit tests for `nexus/web_fetch_cache`: key normalization, TTL expiry,
//// LRU eviction by entry count and byte cap, oversized-doc skip, and
//// fault-isolated named seam degradation.

import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import nexus/web_fetch_cache.{type CachedDoc, CachedDoc}

fn doc(url: String, content: String) -> CachedDoc {
  CachedDoc(
    status: 200,
    final_url: url,
    title: Some("Title"),
    content_type: "text/html",
    format: "markdown",
    content: content,
    total_chars: string.length(content),
    raw_truncated: False,
  )
}

pub fn cache_key_strips_fragment_lowercases_host_keeps_query_test() {
  web_fetch_cache.cache_key("HTTPS://Example.COM:8443/docs/page?a=1&b=2#sec1")
  |> should.equal("https://example.com:8443/docs/page?a=1&b=2")

  web_fetch_cache.cache_key("https://example.com/docs/page?a=1#other")
  |> should.equal(web_fetch_cache.cache_key("https://example.com/docs/page?a=1"))

  // Different query params produce distinct keys.
  should.not_equal(
    web_fetch_cache.cache_key("https://example.com/docs?p=1#a"),
    web_fetch_cache.cache_key("https://example.com/docs?p=2#a"),
  )
}

pub fn hit_miss_and_fragment_equivalence_test() {
  let c = web_fetch_cache.new(ttl_ms: 10_000, max_entries: 8, max_bytes: 1024)
  let #(c, miss) = web_fetch_cache.get(c, "https://example.com/a", 100)
  miss |> should.equal(None)

  let d = doc("https://example.com/a", "hello")
  let c = web_fetch_cache.put(c, "https://example.com/a#intro", d, 100)
  let #(_c, hit) = web_fetch_cache.get(c, "https://example.com/a#footer", 200)
  hit |> should.equal(Some(d))
}

pub fn ttl_expiry_evicts_on_get_and_put_test() {
  let c = web_fetch_cache.new(ttl_ms: 1000, max_entries: 8, max_bytes: 1024)
  let d = doc("https://example.com/a", "hello")
  let c = web_fetch_cache.put(c, "https://example.com/a", d, 100)

  // Still valid at t=1099 (age 999ms < 1000ms).
  let #(c, hit) = web_fetch_cache.get(c, "https://example.com/a", 1099)
  hit |> should.equal(Some(d))

  // Expired at t=1100 (age 1000ms >= 1000ms) -> lazily removed.
  let #(c, expired) = web_fetch_cache.get(c, "https://example.com/a", 1100)
  expired |> should.equal(None)
  web_fetch_cache.size(c) |> should.equal(0)
  web_fetch_cache.total_bytes(c) |> should.equal(0)
}

pub fn lru_eviction_by_entry_count_test() {
  let c = web_fetch_cache.new(ttl_ms: 60_000, max_entries: 2, max_bytes: 1024)
  let d1 = doc("https://example.com/1", "one")
  let d2 = doc("https://example.com/2", "two")
  let d3 = doc("https://example.com/3", "three")

  let c = web_fetch_cache.put(c, "https://example.com/1", d1, 10)
  let c = web_fetch_cache.put(c, "https://example.com/2", d2, 20)
  // Touch /1 so /2 becomes the least-recently-used entry.
  let #(c, hit1) = web_fetch_cache.get(c, "https://example.com/1", 30)
  hit1 |> should.equal(Some(d1))

  // Inserting /3 must evict /2, keeping /1 and /3.
  let c = web_fetch_cache.put(c, "https://example.com/3", d3, 40)
  web_fetch_cache.size(c) |> should.equal(2)
  let #(c, check2) = web_fetch_cache.get(c, "https://example.com/2", 50)
  check2 |> should.equal(None)
  let #(c, check1) = web_fetch_cache.get(c, "https://example.com/1", 50)
  check1 |> should.equal(Some(d1))
  let #(_c, check3) = web_fetch_cache.get(c, "https://example.com/3", 50)
  check3 |> should.equal(Some(d3))
}

pub fn lru_eviction_by_byte_cap_and_oversized_skip_test() {
  let c = web_fetch_cache.new(ttl_ms: 60_000, max_entries: 10, max_bytes: 10)
  let d1 = doc("https://example.com/1", "12345")
  let d2 = doc("https://example.com/2", "67890")
  let d3 = doc("https://example.com/3", "abcdef")
  let huge = doc("https://example.com/huge", "01234567890")

  let c = web_fetch_cache.put(c, "https://example.com/1", d1, 10)
  let c = web_fetch_cache.put(c, "https://example.com/2", d2, 20)
  web_fetch_cache.total_bytes(c) |> should.equal(10)

  // Adding 6 bytes must evict BOTH /1 and /2 (10 -> 5 -> 0 -> 6).
  let c = web_fetch_cache.put(c, "https://example.com/3", d3, 30)
  web_fetch_cache.size(c) |> should.equal(1)
  web_fetch_cache.total_bytes(c) |> should.equal(6)
  let #(c, check3) = web_fetch_cache.get(c, "https://example.com/3", 35)
  check3 |> should.equal(Some(d3))

  // Oversized doc (11 > 10) is silently skipped without evicting /3.
  let c = web_fetch_cache.put(c, "https://example.com/huge", huge, 40)
  let #(c, check_huge) = web_fetch_cache.get(c, "https://example.com/huge", 45)
  check_huge |> should.equal(None)
  let #(_c, still_there) = web_fetch_cache.get(c, "https://example.com/3", 45)
  still_there |> should.equal(Some(d3))
}

pub fn named_actor_roundtrip_and_dead_actor_degrades_cleanly_test() {
  // Missing actor degrades to miss / no-op without crashing.
  let missing = process.new_name("nexus_web_fetch_cache_missing_test")
  let missing_seam = web_fetch_cache.named_seam(missing)
  missing_seam.put("https://example.com/x", doc("https://example.com/x", "hi"))
  missing_seam.get("https://example.com/x") |> should.equal(None)

  // Live actor stores and returns docs.
  let live = process.new_name("nexus_web_fetch_cache_live_test")
  let assert Ok(started) = web_fetch_cache.start_named(live, 60_000)
  let seam = web_fetch_cache.named_seam(live)
  let d = doc("https://example.com/live", "cached body")
  seam.put("https://example.com/live#top", d)
  seam.get("https://example.com/live#bottom") |> should.equal(Some(d))

  // Killing the actor degrades subsequent calls cleanly to miss / no-op.
  process.unlink(started.pid)
  process.kill(started.pid)
  process.sleep(50)
  seam.put("https://example.com/after", d)
  seam.get("https://example.com/live") |> should.equal(None)
}
