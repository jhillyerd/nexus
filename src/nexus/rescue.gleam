//// Run a thunk with Erlang's catch-all: any crash (error, exit, throw)
//// becomes an `Error` carrying a depth-capped print of class and reason,
//// instead of killing the calling process.
////
//// Exists for unlinked worker bodies whose caller's state must survive
//// the worker dying: the UI create workers (#88) hand the create's
//// outcome back to the runtime as a `Created`/`CreateFailed` dispatch,
//// and a registry `actor.call` panic (dead callee) inside the worker
//// must land on that failure path too — otherwise the connection's
//// pending-creation guard never clears and Create stays disabled until
//// a reload.

@external(erlang, "nexus_rescue_ffi", "rescue")
pub fn rescue(thunk: fn() -> a) -> Result(a, String)
