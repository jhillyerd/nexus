//// Monotonic timing helpers shared by the server and the TTFT audit tool.
////
//// All clocks are `erlang:monotonic_time/1` based (immune to wall-clock
//// shifts). The audit's warm/cold ratio depends on these being honest.

import gleam/float
import gleam/int
import gleam/list
import gleam/result

/// Microseconds on the Erlang monotonic clock.
@external(erlang, "nexus_timing_ffi", "monotonic_us")
pub fn now_us() -> Int

/// Wall-clock epoch seconds (`os:system_time`). **Display metadata only** —
/// thread ordering and the sidebar's relative timestamps. Never used for
/// metrics (monotonic above) and never allowed into a request body (the
/// KV-cache contract forbids volatile timestamps above the tail; these live
/// beside the transcript in the registry, not in it).
@external(erlang, "nexus_timing_ffi", "wall_now_s")
pub fn wall_now_s() -> Int

/// RFC3339 UTC string (second precision) for a wall-clock epoch value —
/// the human-readable half of the serialized timestamps. Pure.
@external(erlang, "nexus_timing_ffi", "wall_to_rfc3339")
pub fn wall_to_rfc3339(seconds: Int) -> String

/// Whole milliseconds between two `now_us()` samples, never negative.
pub fn elapsed_ms(start_us: Int, end_us: Int) -> Int {
  int.max(0, { end_us - start_us } / 1000)
}

/// warm/cold TTFT ratio. Errors on non-positive cold so a broken measurement
/// can never accidentally "pass" the 0.3 gate.
pub fn ttft_ratio(warm_ms: Float, cold_ms: Float) -> Result(Float, String) {
  case cold_ms >. 0.0 {
    True -> Ok(warm_ms /. cold_ms)
    False ->
      Error("cold TTFT must be positive, got " <> float.to_string(cold_ms))
  }
}

/// Median of a list of floats. `Error(Nil)` for the empty list.
pub fn median(values: List(Float)) -> Result(Float, Nil) {
  case values {
    [] -> Error(Nil)
    _ -> {
      let sorted = list.sort(values, float.compare)
      let n = list.length(sorted)
      case int.is_odd(n) {
        True ->
          sorted
          |> list.drop(n / 2)
          |> list.first
          |> result.replace_error(Nil)
        False -> {
          let upper =
            sorted |> list.drop(n / 2) |> list.first |> result.unwrap(0.0)
          let lower =
            sorted |> list.drop(n / 2 - 1) |> list.first |> result.unwrap(0.0)
          Ok({ lower +. upper } /. 2.0)
        }
      }
    }
  }
}
