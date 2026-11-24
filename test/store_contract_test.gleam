//// Offline half of the differential `Store` contract suite
//// (`docs/plans/verification.md`, Phase 1).
////
//// Exercises every case in `nexus/store/contract` against the in-memory
//// `store_mock` inside plain offline `gleam test`. The exact same cases run
//// against real Postgres 17 + `nexus/store/persist` via
//// `gleam run -m nexus/store/verify`.

import gleam/list
import gleeunit/should
import nexus/store/contract
import store_mock

pub fn store_contract_matches_mock_test() {
  let failures =
    list.filter_map(contract.cases(), fn(c) {
      let seam = store_mock.seam(store_mock.start())
      case c.run(seam) {
        Ok(Nil) -> Error(Nil)
        Error(reason) -> Ok(c.name <> ": " <> reason)
      }
    })
  should.equal(failures, [])
}
