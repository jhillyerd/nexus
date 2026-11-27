{
  pkgs,
  self,
}:

pkgs.testers.runNixOSTest {
  name = "nexus-service";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ self.nixosModules.default ];

      # Provision test-only secrets outside /nix/store at activation time.
      system.activationScripts.nexusTestSecrets = ''
        install -d -m 0755 /run/nexus-secrets
        cat > /run/nexus-secrets/nexus.env <<'EOF'
NEXUS_ENCRYPTION_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
NEXUS_UI_TOKEN=test-ui-token-1234
EOF
        chmod 0600 /run/nexus-secrets/nexus.env

        # Include single-quote and dollar-sign characters to exercise SQL escaping.
        printf "pg-pass'\$test-42\n" > /run/nexus-secrets/pg-password
        chmod 0600 /run/nexus-secrets/pg-password
      '';

      services.nexus-agent = {
        enable = true;
        environmentFile = "/run/nexus-secrets/nexus.env";
        database = {
          createLocally = true;
          passwordFile = "/run/nexus-secrets/pg-password";
          runMigrations = true;
        };
        workspace = {
          enable = true;
          sandbox = "bwrap";
        };
      };
    };

  testScript = ''
    machine.wait_for_unit("postgresql.service")
    machine.wait_for_unit("nexus-agent.service")
    machine.wait_for_open_port(8080)

    # Health check answers 200 without auth.
    machine.succeed("curl -fsS http://127.0.0.1:8080/healthz")

    # Protected API rejects missing token and accepts the configured bearer token.
    unauth = machine.succeed(
        "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/threads"
    ).strip()
    assert unauth == "401", f"expected 401 without token, got {unauth}"

    machine.succeed(
        "curl -fsS -H 'Authorization: Bearer test-ui-token-1234' http://127.0.0.1:8080/threads"
    )

    # Bundled priv/ assets load via application.priv_directory from the shipment.
    pico = machine.succeed(
        "curl -fsS 'http://127.0.0.1:8080/css/pico.min.css?token=test-ui-token-1234'"
    )
    assert "pico" in pico, "expected pico.min.css content"
    runtime_js = machine.succeed(
        "curl -fsS 'http://127.0.0.1:8080/lustre/runtime.mjs?token=test-ui-token-1234'"
    )
    assert len(runtime_js) > 0, "expected non-empty lustre runtime.mjs"

    # Migrations ran automatically via ExecStartPre using NEXUS_PG_* + passwordFile.
    mig_count = int(
        machine.succeed(
            "runuser -u postgres -- psql -d nexus -tAc 'SELECT count(*) FROM schema_migration'"
        ).strip()
    )
    assert mig_count >= 2, f"expected >= 2 applied migrations, got {mig_count}"

    # Verify cgroup v2 delegation is active for nexus-agent.service:
    # `cgroup.controllers` exposes memory/pids, and systemd chowns the
    # service's `cgroup.subtree_control` to `nexus` only when Delegate= is
    # active (nexus_env_ffi enables +memory +pids lazily on first bash call).
    controllers = machine.succeed(
        "cat /sys/fs/cgroup/system.slice/nexus-agent.service/cgroup.controllers"
    )
    assert "memory" in controllers and "pids" in controllers, (
        f"expected memory and pids in nexus-agent.service cgroup.controllers, got: {controllers!r}"
    )
    machine.succeed(
        "stat -c %U /sys/fs/cgroup/system.slice/nexus-agent.service/cgroup.subtree_control | grep -qx nexus"
    )

    # Verify workspace directories exist with nexus ownership.
    machine.succeed("test -d /var/lib/nexus/workspaces")
    machine.succeed("stat -c %U /var/lib/nexus/workspaces | grep -qx nexus")
    machine.succeed("test -d /var/lib/nexus/sandbox-state")
    machine.succeed("stat -c %U /var/lib/nexus/sandbox-state | grep -qx nexus")

    # Verify sandbox toolchain env vars are wired and bwrap works as the nexus user.
    env_out = machine.succeed("systemctl show -p Environment --value nexus-agent.service")
    env_map = dict(
        entry.split("=", 1) for entry in env_out.split() if "=" in entry
    )
    assert env_map.get("NEXUS_WORKSPACE_SANDBOX") == "bwrap", env_out
    bwrap_bin = env_map["NEXUS_WORKSPACE_SANDBOX_BIN"]
    toolchain = env_map["NEXUS_WORKSPACE_TOOLCHAIN"]
    assert toolchain.startswith("/nix/store/"), toolchain
    machine.succeed(
        f"runuser -u nexus -- {bwrap_bin} --tmpfs / --ro-bind /nix/store /nix/store "
        f"--unshare-net --unshare-pid --die-with-parent -- "
        f"{toolchain}/bin/bash -c 'echo ok' | grep -qx ok"
    )
  '';
}
