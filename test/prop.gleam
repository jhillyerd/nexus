//// Tiny, zero-dependency deterministic seeded property-testing helper for
//// offline `gleam test` verification suites (Phase 3 of
//// `docs/plans/verification.md`).
////
//// Uses SplitMix64 masked to 64 bits so every sequence is 100% deterministic
//// across BEAM runs and platforms. Every failure logs the property name,
//// root seed, failing trial index, and diagnostic message so counterexamples
//// are immediately replayable.

import gleam/bit_array
import gleam/int
import gleam/list

const mask_64 = 0xFFFFFFFFFFFFFFFF

const sm_gamma = 0x9E3779B97F4A7C15

const sm_mul1 = 0xBF58476D1CE4E5B9

const sm_mul2 = 0x94D049BB133111EB

/// Pure deterministic PRNG state.
pub opaque type Rng {
  Rng(state: Int)
}

/// Seed a new deterministic generator.
pub fn seed(value: Int) -> Rng {
  Rng(state: mask64(value))
}

fn mask64(x: Int) -> Int {
  int.bitwise_and(x, mask_64)
}

/// Advance SplitMix64 one step, returning a 64-bit unsigned integer and the
/// next generator state.
pub fn next_u64(rng: Rng) -> #(Int, Rng) {
  let next_state = mask64(rng.state + sm_gamma)
  let z1 =
    mask64(
      int.bitwise_exclusive_or(
        next_state,
        int.bitwise_shift_right(next_state, 30),
      )
      * sm_mul1,
    )
  let z2 =
    mask64(
      int.bitwise_exclusive_or(z1, int.bitwise_shift_right(z1, 27)) * sm_mul2,
    )
  let out =
    mask64(int.bitwise_exclusive_or(z2, int.bitwise_shift_right(z2, 31)))
  #(out, Rng(state: next_state))
}

/// Generate a uniform integer in `[min, max]` inclusive.
pub fn int_range(rng: Rng, min: Int, max: Int) -> #(Int, Rng) {
  case max <= min {
    True -> #(min, rng)
    False -> {
      let #(raw, next_rng) = next_u64(rng)
      let span = max - min + 1
      let offset = raw % span
      #(min + offset, next_rng)
    }
  }
}

/// Generate a boolean.
pub fn bool(rng: Rng) -> #(Bool, Rng) {
  let #(raw, next_rng) = next_u64(rng)
  #(int.bitwise_and(raw, 1) == 1, next_rng)
}

/// Pick one item from a non-empty list (`first`, `rest`).
pub fn one_of(rng: Rng, first: a, rest: List(a)) -> #(a, Rng) {
  let items = [first, ..rest]
  let len = list.length(items)
  let #(idx, next_rng) = int_range(rng, 0, len - 1)
  let picked = case list.drop(items, idx) {
    [head, ..] -> head
    [] -> first
  }
  #(picked, next_rng)
}

/// Generate a list of length in `[min_len, max_len]` using `gen_item`.
pub fn list_of(
  rng: Rng,
  min_len: Int,
  max_len: Int,
  gen_item: fn(Rng) -> #(a, Rng),
) -> #(List(a), Rng) {
  let #(count, rng) = int_range(rng, min_len, max_len)
  gen_list_loop(rng, count, gen_item, [])
}

fn gen_list_loop(
  rng: Rng,
  remaining: Int,
  gen_item: fn(Rng) -> #(a, Rng),
  acc: List(a),
) -> #(List(a), Rng) {
  case remaining <= 0 {
    True -> #(list.reverse(acc), rng)
    False -> {
      let #(item, next_rng) = gen_item(rng)
      gen_list_loop(next_rng, remaining - 1, gen_item, [item, ..acc])
    }
  }
}

/// Randomly partition `bits` into chunks of size in `[min_chunk, max_chunk]`.
/// When `allow_empty` is `True`, occasionally injects `<<>>` zero-byte chunks
/// to exercise empty-packet boundaries.
pub fn bit_array_splits(
  rng: Rng,
  bits: BitArray,
  min_chunk: Int,
  max_chunk: Int,
  allow_empty: Bool,
) -> #(List(BitArray), Rng) {
  let total = bit_array.byte_size(bits)
  split_bits_loop(rng, bits, 0, total, min_chunk, max_chunk, allow_empty, [])
}

fn split_bits_loop(
  rng: Rng,
  bits: BitArray,
  offset: Int,
  total: Int,
  min_chunk: Int,
  max_chunk: Int,
  allow_empty: Bool,
  acc: List(BitArray),
) -> #(List(BitArray), Rng) {
  case offset >= total {
    True -> #(list.reverse(acc), rng)
    False -> {
      let #(inject_empty, rng) = case allow_empty {
        True -> {
          let #(roll, next_rng) = int_range(rng, 0, 9)
          #(roll == 0, next_rng)
        }
        False -> #(False, rng)
      }
      case inject_empty {
        True ->
          split_bits_loop(
            rng,
            bits,
            offset,
            total,
            min_chunk,
            max_chunk,
            allow_empty,
            [<<>>, ..acc],
          )
        False -> {
          let remaining = total - offset
          let capped_max = int.max(1, int.min(max_chunk, remaining))
          let capped_min = int.min(int.max(1, min_chunk), capped_max)
          let #(size, next_rng) = int_range(rng, capped_min, capped_max)
          let assert Ok(chunk) = bit_array.slice(bits, offset, size)
          split_bits_loop(
            next_rng,
            bits,
            offset + size,
            total,
            min_chunk,
            max_chunk,
            allow_empty,
            [chunk, ..acc],
          )
        }
      }
    }
  }
}

/// Split `bits` into 1-byte chunks — the worst-case boundary split that cuts
/// through every multi-byte UTF-8 sequence and every `\r\n\r\n` delimiter.
pub fn single_byte_chunks(bits: BitArray) -> List(BitArray) {
  let total = bit_array.byte_size(bits)
  single_byte_loop(bits, 0, total, [])
}

fn single_byte_loop(
  bits: BitArray,
  offset: Int,
  total: Int,
  acc: List(BitArray),
) -> List(BitArray) {
  case offset >= total {
    True -> list.reverse(acc)
    False -> {
      let assert Ok(chunk) = bit_array.slice(bits, offset, 1)
      single_byte_loop(bits, offset + 1, total, [chunk, ..acc])
    }
  }
}

/// Run `trials` deterministic iterations of a property test starting from
/// `root_seed`. Panics with property name, seed, trial index, and failure
/// message on the first failing trial so any failure is directly replayable.
pub fn forall(
  name: String,
  root_seed: Int,
  trials: Int,
  check: fn(Rng, Int) -> Result(Nil, String),
) -> Nil {
  case trials <= 0 {
    True ->
      panic as {
        "Property misconfigured: "
        <> name
        <> " (trials="
        <> int.to_string(trials)
        <> " must be > 0, root_seed="
        <> int.to_string(root_seed)
        <> ")"
      }
    False -> forall_loop(name, root_seed, 0, trials, check)
  }
}

fn forall_loop(
  name: String,
  root_seed: Int,
  trial: Int,
  trials: Int,
  check: fn(Rng, Int) -> Result(Nil, String),
) -> Nil {
  case trial >= trials {
    True -> Nil
    False -> {
      // Pass (root_seed, trial) through the SplitMix64 mixer so each trial
      // starts from an uncorrelated state instead of one gamma-step into the
      // previous trial's stream.
      let #(trial_seed, _) =
        next_u64(seed(mask64(root_seed + trial * sm_gamma)))
      case check(seed(trial_seed), trial) {
        Ok(Nil) -> forall_loop(name, root_seed, trial + 1, trials, check)
        Error(reason) ->
          panic as {
            "Property failed: "
            <> name
            <> " (root_seed="
            <> int.to_string(root_seed)
            <> ", trial="
            <> int.to_string(trial)
            <> ", trial_seed="
            <> int.to_string(trial_seed)
            <> "): "
            <> reason
          }
      }
    }
  }
}
