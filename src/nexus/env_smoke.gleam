import gleam/erlang/process
import gleam/io
import gleam/option.{Some}
import gleam/string
import nexus/env

pub fn main() {
  let e = Some(env.Environment(workspace_root: "/tmp/nexus-env-sent7", thread_id: "t1"))
  let r = env.bash(timeout_ms: 5000, max_output_bytes: 100_000, environment: e, cancel: process.new_subject(), arguments: "{\"target\":\"workspace\",\"command\":\"exec -a stray7x sleep 42 & echo done\"}")
  io.println("normal-with-stray: " <> string.inspect(r))
}
