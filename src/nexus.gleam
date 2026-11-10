//// nexus — a Gleam-on-BEAM agent harness (see docs/plans/).
////
//// `gleam run` boots the durable system: the Postgres store actor first
//// (boot fails without it), a thread factory supervisor, the registry
//// hydrated from the store, the Lustre server-component runtime, and a
//// Mist server at the bound address serving the chat UI over `/ws` plus
//// the JSON scripting API. The warm/cold TTFT audit tool remains via
//// `gleam run -m audit/ttft`.

import nexus/boot

pub fn main() -> Nil {
  boot.main()
}
