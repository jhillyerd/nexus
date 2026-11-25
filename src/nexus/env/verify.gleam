//// Live Linux sandbox escape probe runner (`docs/plans/verification.md`,
//// Phase 2).
////
//// Invoked explicitly (never from offline `gleam test`, which remains
//// network-free and free of host sandbox binary requirements):
////
////     gleam run -m nexus/env/verify
////     NEXUS_VERIFY_SANDBOX=bwrap gleam run -m nexus/env/verify
////     NEXUS_VERIFY_SANDBOX=bwrap,nono gleam run -m nexus/env/verify
////
//// Executes hostile bash probes through Nexus's real `env.bash_with_sandbox`
//// spawn plan for each selected backend (`bwrap` and/or `nono`):
////
////   1. Workspace confinement & per-thread TMPDIR wiring
////   2. Environment secret scrub (`DATABASE_URL`, `NEXUS_UI_TOKEN`,
////      `NEXUS_ENCRYPTION_KEY` planted in the BEAM env must not leak)
////   3. Filesystem isolation (sibling thread dir, host sentinel outside
////      workspace root, and `/etc/shadow` are unreadable)
////   4. Offline network isolation (real loopback listener positive control
////      succeeds on host, fails inside sandbox)
////   5. Grandchild process reaping on timeout (observed live on host first,
////      zero lingering processes after timeout)
////   6. Grandchild process reaping on cancel (observed live on host first,
////      cancel subject re-signaled, zero lingering processes after cancel)
////   7. Resource cap enforcement (tight memory cap trips cleanly as a normal
////      tool result without harming the BEAM VM; subsequent command succeeds)

import filepath
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import nexus/env
import nexus/timing
import simplifile

type Socket

@external(erlang, "nexus_env_verify_ffi", "put_env")
fn put_env(name: String, value: String) -> Nil

@external(erlang, "nexus_env_verify_ffi", "unset_env")
fn unset_env(name: String) -> Nil

@external(erlang, "nexus_env_verify_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

@external(erlang, "nexus_env_verify_ffi", "listen_loopback")
fn listen_loopback() -> Result(#(Socket, Int), Nil)

@external(erlang, "nexus_env_verify_ffi", "close_socket")
fn close_socket(socket: Socket) -> Nil

@external(erlang, "nexus_env_verify_ffi", "with_cleanup")
fn with_cleanup(run: fn() -> a, cleanup: fn() -> b) -> a

@external(erlang, "nexus_env_ffi", "resolve")
fn resolve_bin(name: String) -> Result(String, Nil)

pub fn main() -> Nil {
  let mode =
    get_env("NEXUS_VERIFY_SANDBOX")
    |> result.unwrap("auto")
    |> string.trim
    |> string.lowercase

  let backends = select_backends(mode)
  case backends {
    [] ->
      panic as "env/verify: no sandbox backend available (install bubblewrap or nono, or set NEXUS_VERIFY_SANDBOX)"
    _ -> Nil
  }

  let total =
    list.fold(backends, 0, fn(acc, backend) { acc + run_backend(backend) })
  io.println(
    "env/verify: "
    <> int.to_string(total)
    <> " probes passed across "
    <> string.join(list.map(backends, backend_label), ", "),
  )
}

fn select_backends(mode: String) -> List(env.SandboxBackend) {
  case mode {
    "" | "auto" -> {
      let bwrap = case
        get_env("NEXUS_TEST_BWRAP_BIN") |> result.or(resolve_bin("bwrap"))
      {
        Ok(_) -> [env.SandboxBwrap]
        Error(_) -> []
      }
      let nono = case
        get_env("NEXUS_TEST_NONO_BIN") |> result.or(resolve_bin("nono"))
      {
        Ok(_) -> [env.SandboxNono]
        Error(_) -> []
      }
      list.append(bwrap, nono)
    }
    "all" -> [env.SandboxBwrap, env.SandboxNono]
    explicit ->
      explicit
      |> string.split(",")
      |> list.map(string.trim)
      |> list.filter(fn(s) { s != "" })
      |> list.map(fn(name) {
        case name {
          "bwrap" -> env.SandboxBwrap
          "nono" -> env.SandboxNono
          other ->
            panic as {
              "env/verify: unknown NEXUS_VERIFY_SANDBOX entry: " <> other
            }
        }
      })
  }
}

fn backend_label(backend: env.SandboxBackend) -> String {
  case backend {
    env.SandboxNone -> "none"
    env.SandboxBwrap -> "bwrap"
    env.SandboxNono -> "nono"
  }
}

fn run_backend(backend: env.SandboxBackend) -> Int {
  let label = backend_label(backend)
  let uniq = int.to_string(int.absolute_value(timing.now_us()))
  let #(root, state_dir, host_sentinel) = prepare_dirs(backend, uniq)
  let sibling_dir = filepath.join(root, "threads/sibling")
  let assert Ok(Nil) = simplifile.create_directory_all(sibling_dir)
  let assert Ok(Nil) =
    simplifile.write(
      filepath.join(sibling_dir, "secret.txt"),
      "sibling-thread-secret-" <> uniq,
    )
  let assert Ok(Nil) =
    simplifile.write(host_sentinel, "host-sentinel-secret-" <> uniq)

  let handle =
    Some(env.Environment(
      workspace_root: root,
      thread_id: "t1",
      workspace_rel_path: Some("threads/t1"),
      tmp_rel_path: Some("tmp/t1"),
      roster: env.attached_targets(),
      remote: None,
    ))
  let sandbox = build_config(backend, state_dir, 1024, 64)
  let tight_sandbox = build_config(backend, state_dir, 128, 32)

  with_cleanup(
    fn() {
      let probes = [
        #("confinement and TMPDIR wiring", fn() {
          probe_confinement(backend, root, state_dir, handle, sandbox)
        }),
        #("environment secret scrub", fn() {
          probe_env_scrub(handle, sandbox, uniq)
        }),
        #("sibling thread and host sentinel read refusal", fn() {
          probe_fs_isolation(
            backend,
            sibling_dir,
            host_sentinel,
            uniq,
            handle,
            sandbox,
          )
        }),
        #("offline network isolation", fn() {
          probe_network_isolation(handle, sandbox)
        }),
        #("timeout reaps background grandchildren", fn() {
          probe_timeout_reap(label, uniq, handle, sandbox)
        }),
        #("cancel reaps background grandchildren and re-signals", fn() {
          probe_cancel_reap(label, uniq, handle, sandbox)
        }),
        #("memory cap trips cleanly without harming BEAM", fn() {
          probe_memory_cap(handle, tight_sandbox, sandbox)
        }),
      ]
      list.each(probes, fn(probe) {
        let #(name, run) = probe
        run()
        io.println("  ok  [" <> label <> "] " <> name)
      })
      list.length(probes)
    },
    fn() {
      let _ = simplifile.delete(root)
      let _ = simplifile.delete(host_sentinel)
      case state_dir {
        Some(dir) -> {
          let _ = simplifile.delete(dir)
          Nil
        }
        None -> Nil
      }
    },
  )
}

fn prepare_dirs(
  backend: env.SandboxBackend,
  uniq: String,
) -> #(String, Option(String), String) {
  case backend {
    env.SandboxBwrap | env.SandboxNone -> #(
      "/tmp/nexus-env-verify-bwrap-" <> uniq,
      None,
      "/tmp/nexus-env-verify-sentinel-" <> uniq <> ".txt",
    )
    env.SandboxNono -> {
      // nono treats /tmp and /var/tmp as protected state roots; place its
      // workspace and state directories under HOME (or NEXUS_TEST_NONO_ROOT).
      let base = case get_env("NEXUS_TEST_NONO_ROOT") {
        Ok(dir) -> dir
        Error(Nil) ->
          case get_env("HOME") {
            Ok(home) -> filepath.join(home, ".cache/nexus-nono-verify")
            Error(Nil) ->
              panic as "env/verify: nono requires HOME or NEXUS_TEST_NONO_ROOT outside /tmp"
          }
      }
      let assert Ok(Nil) = simplifile.create_directory_all(base)
      #(
        filepath.join(base, "ws-" <> uniq),
        Some(filepath.join(base, "state-" <> uniq)),
        filepath.join(base, "host-sentinel-" <> uniq <> ".txt"),
      )
    }
  }
}

fn build_config(
  backend: env.SandboxBackend,
  state_dir: Option(String),
  max_memory_mb: Int,
  max_pids: Int,
) -> env.SandboxConfig {
  let sandbox_bin = case backend {
    env.SandboxBwrap -> get_env("NEXUS_TEST_BWRAP_BIN") |> option.from_result
    env.SandboxNono -> get_env("NEXUS_TEST_NONO_BIN") |> option.from_result
    env.SandboxNone -> None
  }
  env.SandboxConfig(
    backend: backend,
    sandbox_bin: sandbox_bin,
    toolchain: get_env("NEXUS_TEST_TOOLCHAIN") |> option.from_result,
    state_dir: state_dir,
    max_memory_mb: max_memory_mb,
    max_pids: max_pids,
  )
}

fn run_cmd(
  handle: Option(env.Environment),
  sandbox: env.SandboxConfig,
  cancel: process.Subject(Nil),
  timeout_ms: Int,
  command: String,
) -> Result(String, String) {
  env.bash_with_sandbox(
    timeout_ms: timeout_ms,
    max_output_bytes: 50_000,
    sandbox: sandbox,
    environment: handle,
    cancel: cancel,
    arguments: json_args([#("target", "workspace"), #("command", command)]),
  )
}

fn run_host_bash(
  handle: Option(env.Environment),
  timeout_ms: Int,
  command: String,
) -> Result(String, String) {
  env.bash(
    timeout_ms: timeout_ms,
    max_output_bytes: 50_000,
    environment: handle,
    cancel: process.new_subject(),
    arguments: json_args([#("target", "workspace"), #("command", command)]),
  )
}

fn probe_confinement(
  backend: env.SandboxBackend,
  root: String,
  state_dir: Option(String),
  handle: Option(env.Environment),
  sandbox: env.SandboxConfig,
) -> Nil {
  let assert Ok(out) =
    run_cmd(
      handle,
      sandbox,
      process.new_subject(),
      10_000,
      "pwd && echo HOME=$HOME && echo TMPDIR=$TMPDIR && echo ok > \"$TMPDIR/probe.txt\"",
    )
  case backend {
    env.SandboxBwrap -> {
      assert_true(string.contains(out, "/workspace"), "bwrap cwd is /workspace")
      assert_true(
        string.contains(out, "HOME=/workspace"),
        "bwrap HOME=/workspace",
      )
      assert_true(string.contains(out, "TMPDIR=/tmp"), "bwrap TMPDIR=/tmp")
    }
    env.SandboxNono -> {
      assert_true(
        string.contains(out, "HOME=" <> filepath.join(root, "threads/t1")),
        "nono HOME re-exported to workspace",
      )
      assert_true(
        string.contains(out, "TMPDIR=" <> filepath.join(root, "tmp/t1")),
        "nono TMPDIR re-exported to thread tmp",
      )
      case state_dir {
        Some(dir) ->
          assert_false(
            string.contains(out, dir),
            "nono state_dir hidden from bash env",
          )
        None -> Nil
      }
    }
    env.SandboxNone -> Nil
  }
  let assert Ok("ok\n") =
    simplifile.read(filepath.join(root, "tmp/t1/probe.txt"))
  Nil
}

fn probe_env_scrub(
  handle: Option(env.Environment),
  sandbox: env.SandboxConfig,
  uniq: String,
) -> Nil {
  let canaries = [
    #("DATABASE_URL", "postgres://verify-secret-" <> uniq <> "@db/nexus"),
    #("NEXUS_UI_TOKEN", "ui-token-secret-" <> uniq),
    #("NEXUS_ENCRYPTION_KEY", "enc-key-secret-" <> uniq),
    #("NEXUS_VERIFY_CANARY", "canary-val-" <> uniq),
  ]
  let originals = list.map(canaries, fn(pair) { #(pair.0, get_env(pair.0)) })
  let out =
    with_cleanup(
      fn() {
        list.each(canaries, fn(pair) { put_env(pair.0, pair.1) })
        run_cmd(handle, sandbox, process.new_subject(), 10_000, "env")
      },
      fn() {
        list.each(originals, fn(entry) {
          case entry.1 {
            Ok(val) -> put_env(entry.0, val)
            Error(Nil) -> unset_env(entry.0)
          }
        })
      },
    )
  let assert Ok(env_out) = out
  list.each(canaries, fn(pair) {
    assert_false(
      string.contains(env_out, pair.0),
      "secret var name leaked into sandbox env: " <> pair.0,
    )
    assert_false(
      string.contains(env_out, pair.1),
      "secret var value leaked into sandbox env: " <> pair.0,
    )
  })
}

fn probe_fs_isolation(
  backend: env.SandboxBackend,
  sibling_dir: String,
  host_sentinel: String,
  uniq: String,
  handle: Option(env.Environment),
  sandbox: env.SandboxConfig,
) -> Nil {
  let sibling_secret = filepath.join(sibling_dir, "secret.txt")
  let assert Ok(out1) =
    run_cmd(
      handle,
      sandbox,
      process.new_subject(),
      10_000,
      "cat " <> env.shell_single_quote(sibling_secret),
    )
  assert_false(
    string.contains(out1, "sibling-thread-secret-" <> uniq),
    "sibling workspace secret must be unreadable",
  )
  assert_true(
    string.starts_with(out1, "exit status"),
    "sibling read exits non-zero",
  )

  let assert Ok(out2) =
    run_cmd(
      handle,
      sandbox,
      process.new_subject(),
      10_000,
      "cat " <> env.shell_single_quote(host_sentinel),
    )
  assert_false(
    string.contains(out2, "host-sentinel-secret-" <> uniq),
    "host sentinel file must be unreadable",
  )
  assert_true(
    string.starts_with(out2, "exit status"),
    "host sentinel read exits non-zero",
  )

  let assert Ok(out3) =
    run_cmd(handle, sandbox, process.new_subject(), 10_000, "cat /etc/shadow")
  assert_true(
    string.starts_with(out3, "exit status"),
    "/etc/shadow read exits non-zero",
  )

  case backend {
    env.SandboxNono -> {
      let escape_path = "/tmp/nexus-nono-verify-escape-" <> uniq
      let assert Ok(out4) =
        run_cmd(
          handle,
          sandbox,
          process.new_subject(),
          10_000,
          "echo bad > " <> env.shell_single_quote(escape_path),
        )
      assert_true(
        string.starts_with(out4, "exit status"),
        "nono blocks writes to host /tmp",
      )
      let assert Ok(False) = simplifile.is_file(escape_path)
      Nil
    }
    _ -> Nil
  }
}

fn probe_network_isolation(
  handle: Option(env.Environment),
  sandbox: env.SandboxConfig,
) -> Nil {
  let assert Ok(#(sock, port)) = listen_loopback()
  let tcp_probe =
    "bash -c 'exec 3<>/dev/tcp/127.0.0.1/"
    <> int.to_string(port)
    <> "' 2>&1; echo probe_done rc=$?"
  let #(host_res, sandbox_res) =
    with_cleanup(
      fn() {
        let host_out = run_host_bash(handle, 10_000, tcp_probe)
        let box_out =
          run_cmd(handle, sandbox, process.new_subject(), 10_000, tcp_probe)
        #(host_out, box_out)
      },
      fn() { close_socket(sock) },
    )
  let assert Ok(host_out) = host_res
  assert_true(
    string.contains(host_out, "probe_done rc=0"),
    "positive control: host loopback TCP connect succeeds",
  )
  let assert Ok(box_out) = sandbox_res
  assert_true(
    string.contains(box_out, "probe_done rc="),
    "sandbox network probe actually executed",
  )
  assert_false(
    string.contains(box_out, "probe_done rc=0"),
    "sandbox blocks TCP loopback connect",
  )
}

fn probe_timeout_reap(
  label: String,
  uniq: String,
  handle: Option(env.Environment),
  sandbox: env.SandboxConfig,
) -> Nil {
  let tag = "nxvto" <> label <> uniq <> "q"
  // Match the grandchild's own `<tag> 60` argv for presence (so the sandbox
  // wrapper's `exec -a <tag> sleep 60` command line cannot satisfy it before
  // `sleep 60` forks), then verify the broader tag is completely gone after
  // timeout so neither wrapper nor grandchild remains.
  let present_pattern = "nxvto" <> label <> uniq <> "[q] 6[0]"
  let gone_pattern = "nxvto" <> label <> uniq <> "[q]"
  let reply = process.new_subject()
  let _worker =
    process.spawn_unlinked(fn() {
      let res =
        run_cmd(
          handle,
          sandbox,
          process.new_subject(),
          2500,
          "exec -a " <> tag <> " sleep 60 & sleep 60",
        )
      process.send(reply, res)
    })
  poll_tag_present(present_pattern, 50)
  let assert Ok(Error(msg)) = process.receive(reply, 10_000)
  assert_true(
    string.contains(msg, "timed out"),
    "timeout error reported: " <> msg,
  )
  poll_tag_gone(gone_pattern, 25)
}

fn probe_cancel_reap(
  label: String,
  uniq: String,
  handle: Option(env.Environment),
  sandbox: env.SandboxConfig,
) -> Nil {
  let tag = "nxvcn" <> label <> uniq <> "q"
  let present_pattern = "nxvcn" <> label <> uniq <> "[q] 6[0]"
  let gone_pattern = "nxvcn" <> label <> uniq <> "[q]"
  // Subjects can only be received on by their owning process: create `cancel`
  // inside the worker and hand it back so the worker's bash_loop can select it
  // and verify the one-shot re-signal afterward.
  let cancel_back = process.new_subject()
  let reply = process.new_subject()
  let _worker =
    process.spawn_unlinked(fn() {
      let cancel = process.new_subject()
      process.send(cancel_back, cancel)
      let res =
        run_cmd(
          handle,
          sandbox,
          cancel,
          20_000,
          "exec -a " <> tag <> " sleep 60 & sleep 60",
        )
      let resignalled = process.receive(cancel, 1000) == Ok(Nil)
      process.send(reply, #(res, resignalled))
    })
  let assert Ok(cancel) = process.receive(cancel_back, 2000)
  poll_tag_present(present_pattern, 50)
  process.send(cancel, Nil)
  let assert Ok(#(Error(msg), resignalled)) = process.receive(reply, 10_000)
  assert_true(
    string.contains(msg, "cancelled"),
    "cancel error reported: " <> msg,
  )
  assert_true(resignalled, "one-shot cancel subject re-signalled")
  poll_tag_gone(gone_pattern, 25)
}

fn probe_memory_cap(
  handle: Option(env.Environment),
  tight_sandbox: env.SandboxConfig,
  normal_sandbox: env.SandboxConfig,
) -> Nil {
  // Exponentially double a 64 KiB string in pure bash (up to ~1 GiB in 14
  // iterations) under a 128 MiB cap. Trips both Linux cgroup v2 `memory.max`
  // and `prlimit --as` fallback quickly without external interpreters.
  let mem_hog =
    "s=$(printf '%*s' 65536 ''); for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do s=\"$s$s\"; done; echo SURVIVED_MEM_CAP"
  let outcome =
    run_cmd(handle, tight_sandbox, process.new_subject(), 15_000, mem_hog)
  case outcome {
    Ok(out) -> {
      assert_false(
        string.contains(out, "SURVIVED_MEM_CAP"),
        "memory hog must not survive 128 MiB cap: " <> out,
      )
      assert_true(
        string.starts_with(out, "exit status"),
        "memory-capped command exits non-zero as normal tool data: " <> out,
      )
    }
    // Only a pre-marker non-zero sandbox wrapper exit under the tight 128 MiB
    // cap (e.g. OOM-killed before bash prints its PID marker) counts as
    // memory-cap enforcement; timeouts and unrelated errors must fail.
    Error(msg) ->
      assert_true(
        string.starts_with(msg, "bash: sandbox wrapper (")
          && string.contains(msg, "exited with status "),
        "memory cap probe failed with non-cap error: " <> msg,
      )
  }

  // Positive follow-up: the BEAM VM and workspace remain completely healthy.
  let assert Ok(after) =
    run_cmd(
      handle,
      normal_sandbox,
      process.new_subject(),
      10_000,
      "echo beam_healthy",
    )
  assert_true(
    string.contains(after, "beam_healthy"),
    "subsequent sandboxed command succeeds after memory cap trip",
  )
}

fn poll_tag_present(pattern: String, attempts: Int) -> Nil {
  let host_tmp =
    Some(env.Environment(
      workspace_root: "/tmp",
      thread_id: "probe",
      workspace_rel_path: None,
      tmp_rel_path: None,
      roster: env.attached_targets(),
      remote: None,
    ))
  case
    run_host_bash(
      host_tmp,
      10_000,
      "ps -eo cmd | grep -c '" <> pattern <> "' || true",
    )
  {
    Ok(n) ->
      case int.parse(string.trim(n)) {
        Ok(count) if count > 0 -> Nil
        _ -> retry_present(pattern, attempts)
      }
    _ -> retry_present(pattern, attempts)
  }
}

fn retry_present(pattern: String, attempts: Int) -> Nil {
  case attempts {
    0 -> panic as { "env/verify: tagged grandchild never appeared: " <> pattern }
    n -> {
      process.sleep(200)
      poll_tag_present(pattern, n - 1)
    }
  }
}

fn poll_tag_gone(pattern: String, attempts: Int) -> Nil {
  let host_tmp =
    Some(env.Environment(
      workspace_root: "/tmp",
      thread_id: "probe",
      workspace_rel_path: None,
      tmp_rel_path: None,
      roster: env.attached_targets(),
      remote: None,
    ))
  case
    run_host_bash(
      host_tmp,
      5000,
      "ps -eo cmd | grep -c '" <> pattern <> "' || true",
    )
  {
    Ok("0") -> Nil
    Ok("exit status 1" <> _) -> Nil
    _ ->
      case attempts {
        0 ->
          panic as { "env/verify: tagged grandchild survived reap: " <> pattern }
        n -> {
          process.sleep(200)
          poll_tag_gone(pattern, n - 1)
        }
      }
  }
}

fn json_args(pairs: List(#(String, String))) -> String {
  json.to_string(
    json.object(list.map(pairs, fn(p) { #(p.0, json.string(p.1)) })),
  )
}

fn assert_true(cond: Bool, message: String) -> Nil {
  case cond {
    True -> Nil
    False -> panic as { "env/verify assert failed: " <> message }
  }
}

fn assert_false(cond: Bool, message: String) -> Nil {
  case cond {
    False -> Nil
    True -> panic as { "env/verify assert failed: " <> message }
  }
}
