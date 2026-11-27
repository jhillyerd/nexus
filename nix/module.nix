self:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.nexus-agent;
  system = pkgs.stdenv.hostPlatform.system;

  normalizePath =
    p:
    let
      s = toString p;
      trimmed = lib.removeSuffix "/" s;
    in
    if trimmed == "" then "/" else trimmed;

  pathsOverlap =
    a: b:
    let
      na = normalizePath a;
      nb = normalizePath b;
    in
    na == nb || lib.hasPrefix "${nb}/" na || lib.hasPrefix "${na}/" nb;

  isUnderStateDir =
    p:
    let
      np = normalizePath p;
    in
    np == "/var/lib/nexus" || lib.hasPrefix "/var/lib/nexus/" np;

  sandboxActive = cfg.workspace.enable && cfg.workspace.sandbox != "none";

  defaultSandboxPkg =
    if cfg.workspace.sandbox == "bwrap" then
      pkgs.bubblewrap
    else if cfg.workspace.sandbox == "nono" then
      pkgs.nono
    else
      null;

  effectiveSandboxPkg =
    if cfg.workspace.sandboxPackage != null then cfg.workspace.sandboxPackage else defaultSandboxPkg;

  workspaceToolchain = pkgs.buildEnv {
    name = "nexus-workspace-toolchain";
    paths = cfg.workspace.packages;
    pathsToLink = [
      "/bin"
      "/etc"
    ];
  };

  encodeMcpServer =
    server:
    {
      inherit (server)
        name
        command
        args
        env
        ;
    }
    // lib.optionalAttrs (server.timeoutMs != null) {
      timeout_ms = server.timeoutMs;
    };

  pgPkg = config.services.postgresql.package;
  pgSuperUser = config.services.postgresql.superUser;

  ensureDbOwnership = pkgs.writeShellScript "nexus-ensure-db-ownership" ''
    set -euo pipefail
    printf 'ALTER DATABASE "%s" OWNER TO "%s";\n' \
      ${lib.escapeShellArg cfg.database.name} ${lib.escapeShellArg cfg.database.user} \
      | ${pkgs.util-linux}/bin/runuser -u ${lib.escapeShellArg pgSuperUser} -- \
        ${pgPkg}/bin/psql -X -v ON_ERROR_STOP=1 -p ${toString cfg.database.port} -d postgres >/dev/null
  '';

  syncDbPassword = pkgs.writeShellScript "nexus-sync-db-password" ''
    set -euo pipefail
    pw_file=${lib.escapeShellArg (toString cfg.database.passwordFile)}
    if [ ! -r "$pw_file" ]; then
      echo "nexus: database.passwordFile is not readable: $pw_file" >&2
      exit 1
    fi
    pw="$(${pkgs.coreutils}/bin/tr -d '\r\n' < "$pw_file")"
    if [ -z "$pw" ]; then
      echo "nexus: database.passwordFile is empty: $pw_file" >&2
      exit 1
    fi
    sq="$(printf '\047')"
    pw_escaped="$(printf '%s' "$pw" | ${pkgs.gnused}/bin/sed "s/$sq/$sq$sq/g")"
    {
      printf 'BEGIN;\n'
      printf 'SET LOCAL log_statement = %snone%s;\n' "$sq" "$sq"
      printf 'SET LOCAL standard_conforming_strings = on;\n'
      printf 'ALTER ROLE "%s" WITH LOGIN PASSWORD %s%s%s;\n' \
        ${lib.escapeShellArg cfg.database.user} "$sq" "$pw_escaped" "$sq"
      printf 'COMMIT;\n'
    } | ${pkgs.util-linux}/bin/runuser -u ${lib.escapeShellArg pgSuperUser} -- \
      ${pgPkg}/bin/psql -X -v ON_ERROR_STOP=1 -p ${toString cfg.database.port} -d postgres >/dev/null
  '';

  wrapWithPgPassword =
    name: bin:
    pkgs.writeShellScript name ''
      set -euo pipefail
      ${lib.optionalString (cfg.database.passwordFile != null) ''
        export NEXUS_PG_PASSWORD="$(${pkgs.coreutils}/bin/tr -d '\r\n' < "$CREDENTIALS_DIRECTORY/pg-password")"
      ''}
      exec ${bin} "$@"
    '';

  ensureWorkspaceDirs = pkgs.writeShellScript "nexus-ensure-workspace-dirs" ''
    set -euo pipefail
    ${lib.optionalString (isUnderStateDir cfg.workspace.root) ''
      ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg (toString cfg.workspace.root)}
    ''}
    ${lib.optionalString (sandboxActive && cfg.workspace.stateDir != null && isUnderStateDir cfg.workspace.stateDir) ''
      ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg (toString cfg.workspace.stateDir)}
    ''}
  '';

  runMigrate = wrapWithPgPassword "nexus-run-migrate" "${cfg.package}/bin/nexus-migrate";
  runServer = wrapWithPgPassword "nexus-run-server" "${cfg.package}/bin/nexus";

  extraWritePaths = lib.unique (
    lib.optional (cfg.workspace.enable && !isUnderStateDir cfg.workspace.root) (
      toString cfg.workspace.root
    )
    ++ lib.optional (
      sandboxActive && cfg.workspace.stateDir != null && !isUnderStateDir cfg.workspace.stateDir
    ) (toString cfg.workspace.stateDir)
  );

  baseEnvironment =
    {
      NEXUS_HTTP_BIND = cfg.bind;
      NEXUS_HTTP_PORT = toString cfg.port;
      NEXUS_LOG_LEVEL = cfg.logLevel;

      NEXUS_PG_HOST = cfg.database.host;
      NEXUS_PG_PORT = toString cfg.database.port;
      NEXUS_PG_DATABASE = cfg.database.name;
      NEXUS_PG_USER = cfg.database.user;

      NEXUS_UTILITY_ENABLED = lib.boolToString cfg.utility.enable;
      NEXUS_UTILITY_DELAY_MS = toString cfg.utility.delayMs;

      NEXUS_CODEMODE = lib.boolToString cfg.codemode.enable;
      NEXUS_CODEMODE_TIMEOUT_MS = toString cfg.codemode.timeoutMs;
      NEXUS_CODEMODE_MAX_OUTPUT_CHARS = toString cfg.codemode.maxOutputChars;

      NEXUS_NODE_IDLE_DAYS = toString cfg.nodeIdleDays;
    }
    // lib.optionalAttrs (cfg.systemPrompt != null) {
      NEXUS_SYSTEM_PROMPT = cfg.systemPrompt;
    }
    // lib.optionalAttrs (cfg.searxng.baseUrl != null) {
      NEXUS_SEARXNG_BASE_URL = cfg.searxng.baseUrl;
    }
    // lib.optionalAttrs (cfg.plugins != [ ]) {
      NEXUS_PLUGINS = lib.concatStringsSep "," cfg.plugins;
    }
    // lib.optionalAttrs (cfg.mcpServers != [ ]) {
      NEXUS_MCP_SERVERS_JSON = builtins.toJSON (map encodeMcpServer cfg.mcpServers);
    }
    // lib.optionalAttrs cfg.workspace.enable {
      NEXUS_WORKSPACE_ROOT = toString cfg.workspace.root;
      NEXUS_WORKSPACE_SANDBOX = cfg.workspace.sandbox;
      NEXUS_WORKSPACE_MAX_MEMORY_MB = toString cfg.workspace.maxMemoryMb;
      NEXUS_WORKSPACE_MAX_PIDS = toString cfg.workspace.maxPids;
      NEXUS_ENV_TIMEOUT_MS = toString cfg.workspace.timeoutMs;
      NEXUS_ENV_MAX_OUTPUT_BYTES = toString cfg.workspace.maxOutputBytes;
    }
    // lib.optionalAttrs sandboxActive (
      {
        NEXUS_WORKSPACE_SANDBOX_BIN = "${effectiveSandboxPkg}/bin/${cfg.workspace.sandbox}";
        NEXUS_WORKSPACE_TOOLCHAIN = "${workspaceToolchain}";
      }
      // lib.optionalAttrs (cfg.workspace.stateDir != null) {
        NEXUS_WORKSPACE_STATE_DIR = toString cfg.workspace.stateDir;
      }
    );
in
{
  options.services.nexus-agent = {
    enable = lib.mkEnableOption "nexus, a self-hosted Gleam-on-BEAM AI agent harness";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${system}.nexus;
      defaultText = lib.literalExpression "inputs.nexus.packages.\${pkgs.stdenv.hostPlatform.system}.nexus";
      description = "The nexus package to run.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "nexus";
      description = "System user under which the nexus service runs.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "nexus";
      description = "System group under which the nexus service runs.";
    };

    bind = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "IP address to bind the HTTP/WebSocket server to (`NEXUS_HTTP_BIND`).";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "TCP port to listen on (`NEXUS_HTTP_PORT`).";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to open `services.nexus-agent.port` in the NixOS firewall.";
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [
        "debug"
        "info"
        "warn"
        "error"
      ];
      default = "info";
      description = "Minimum server log level (`NEXUS_LOG_LEVEL`).";
    };

    systemPrompt = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional default system prompt override (`NEXUS_SYSTEM_PROMPT`).";
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/secrets/nexus.env";
      description = ''
        Path to a systemd `EnvironmentFile` containing secrets such as
        `NEXUS_ENCRYPTION_KEY` (required), `NEXUS_UI_TOKEN`, and
        `NEXUS_SEARXNG_TOKEN`. Pass a quoted string path (e.g.
        `"/run/secrets/nexus.env"` or `config.sops.secrets.*.path`) so the
        file is not copied into the Nix store.
      '';
    };

    database = {
      createLocally = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether to enable a local PostgreSQL server and ensure the nexus
          database and role exist.
        '';
      };

      host = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "PostgreSQL TCP host (`NEXUS_PG_HOST`).";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 5432;
        description = "PostgreSQL TCP port (`NEXUS_PG_PORT`).";
      };

      name = lib.mkOption {
        type = lib.types.str;
        default = "nexus";
        description = "PostgreSQL database name (`NEXUS_PG_DATABASE`).";
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = "nexus";
        description = "PostgreSQL user (`NEXUS_PG_USER`).";
      };

      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        example = "/run/secrets/nexus-pg-password";
        description = ''
          Path to a file containing the PostgreSQL password (single line,
          loaded via systemd `LoadCredential` into `NEXUS_PG_PASSWORD`).
          When `database.createLocally` is enabled, a root `ExecStartPre`
          step also synchronizes this password onto the local PostgreSQL role.
          Pass a quoted string path so the secret is not copied into the Nix store.
        '';
      };

      runMigrations = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to run `nexus-migrate` in `ExecStartPre` before starting the server.";
      };
    };

    workspace = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to enable local workspace tools (`NEXUS_WORKSPACE_ROOT`).";
      };

      root = lib.mkOption {
        type = lib.types.path;
        default = "/var/lib/nexus/workspaces";
        description = "Directory under which thread and bot workspaces are stored (`NEXUS_WORKSPACE_ROOT`).";
      };

      stateDir = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = "/var/lib/nexus/sandbox-state";
        description = ''
          Directory for sandbox state/profiles outside `workspace.root`
          (`NEXUS_WORKSPACE_STATE_DIR`). Required when `workspace.sandbox = "nono"`.
        '';
      };

      sandbox = lib.mkOption {
        type = lib.types.enum [
          "bwrap"
          "nono"
          "none"
        ];
        default = "bwrap";
        description = "Local workspace `bash` sandbox backend (`NEXUS_WORKSPACE_SANDBOX`).";
      };

      sandboxPackage = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        description = ''
          Optional package providing the sandbox binary (`bwrap` or `nono`).
          Defaults to `pkgs.bubblewrap` for `"bwrap"` and `pkgs.nono` for `"nono"`.
        '';
      };

      packages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = with pkgs; [
          bash
          coreutils
          gnugrep
          gnused
          gawk
          findutils
          jq
          curl
          gitMinimal
          ripgrep
          python3
          sqlite
          cacert
          util-linux
          procps
        ];
        defaultText = lib.literalExpression ''
          with pkgs; [
            bash coreutils gnugrep gnused gawk findutils jq curl
            gitMinimal ripgrep python3 sqlite cacert util-linux procps
          ]
        '';
        description = ''
          Packages bundled via `pkgs.buildEnv` into the immutable workspace
          toolchain profile (`NEXUS_WORKSPACE_TOOLCHAIN`). Must include `bash`.
        '';
      };

      maxMemoryMb = lib.mkOption {
        type = lib.types.ints.between 16 1048576;
        default = 1024;
        description = "Per-command workspace memory cap in MiB (`NEXUS_WORKSPACE_MAX_MEMORY_MB`).";
      };

      maxPids = lib.mkOption {
        type = lib.types.ints.between 4 65536;
        default = 64;
        description = "Per-command workspace PID cap (`NEXUS_WORKSPACE_MAX_PIDS`).";
      };

      timeoutMs = lib.mkOption {
        type = lib.types.ints.between 1000 3600000;
        default = 60000;
        description = "Per-call wall-clock deadline for `bash` in milliseconds (`NEXUS_ENV_TIMEOUT_MS`).";
      };

      maxOutputBytes = lib.mkOption {
        type = lib.types.ints.between 1024 67108864;
        default = 262144;
        description = "Per-call byte cap for workspace `bash` and file reads (`NEXUS_ENV_MAX_OUTPUT_BYTES`).";
      };
    };

    codemode = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to enable the Lua codemode tool (`NEXUS_CODEMODE`).";
      };

      timeoutMs = lib.mkOption {
        type = lib.types.ints.between 1000 3600000;
        default = 30000;
        description = "Per-script wall-clock deadline in milliseconds (`NEXUS_CODEMODE_TIMEOUT_MS`).";
      };

      maxOutputChars = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 32768;
        description = "Rendered output cap in characters (`NEXUS_CODEMODE_MAX_OUTPUT_CHARS`).";
      };
    };

    utility = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to enable model-generated thread titles/tags (`NEXUS_UTILITY_ENABLED`).";
      };

      delayMs = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 1500;
        description = "Debounce delay in milliseconds after turn commit (`NEXUS_UTILITY_DELAY_MS`).";
      };
    };

    searxng = {
      baseUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "https://searx.example";
        description = ''
          Optional SearxNG base URL for `web_search` (`NEXUS_SEARXNG_BASE_URL`).
          Put `NEXUS_SEARXNG_TOKEN` in `environmentFile` if your instance requires auth.
        '';
      };
    };

    plugins = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Compiled-in plugin names to mount at boot (`NEXUS_PLUGINS`).";
    };

    mcpServers = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Provider name prefix for this MCP server (`<name>__<tool>`).";
            };
            command = lib.mkOption {
              type = lib.types.str;
              description = "Executable path to spawn for this stdio MCP server.";
            };
            args = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Command-line arguments passed to the MCP server.";
            };
            env = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = { };
              description = "Non-secret environment variables added/overridden for this MCP server.";
            };
            timeoutMs = lib.mkOption {
              type = lib.types.nullOr (lib.types.ints.between 100 3600000);
              default = null;
              description = "Optional per-call timeout override in milliseconds.";
            };
          };
        }
      );
      default = [ ];
      description = "Stdio MCP servers serialized into `NEXUS_MCP_SERVERS_JSON`.";
    };

    nodeIdleDays = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 7;
      description = "Days before idle paired node credentials are swept at boot (`0` disables; `NEXUS_NODE_IDLE_DAYS`).";
    };

    extraEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Additional non-secret `NEXUS_*` environment variables merged into the service environment.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !(sandboxActive && cfg.workspace.sandbox == "nono" && cfg.workspace.stateDir == null);
        message = "services.nexus-agent.workspace.stateDir must be set when services.nexus-agent.workspace.sandbox = \"nono\".";
      }
      {
        assertion =
          !(
            sandboxActive
            && cfg.workspace.stateDir != null
            && pathsOverlap cfg.workspace.root cfg.workspace.stateDir
          );
        message = "services.nexus-agent.workspace.stateDir must not overlap services.nexus-agent.workspace.root.";
      }
      {
        assertion =
          !(
            cfg.database.createLocally
            && !(builtins.elem cfg.database.host [
              "127.0.0.1"
              "localhost"
              "::1"
            ])
          );
        message = "services.nexus-agent.database.host must be local (127.0.0.1, localhost, or ::1) when database.createLocally is true.";
      }
      {
        assertion =
          !(
            cfg.database.createLocally
            && (
              builtins.match "[a-zA-Z0-9_-]+" cfg.database.user == null
              || builtins.match "[a-zA-Z0-9_-]+" cfg.database.name == null
            )
          );
        message = "services.nexus-agent.database.user and database.name must match [a-zA-Z0-9_-]+ when database.createLocally is true.";
      }
    ];

    users.users.${cfg.user} = lib.mkIf (cfg.user == "nexus") {
      isSystemUser = true;
      group = cfg.group;
      home = "/var/lib/nexus";
      description = "Nexus AI agent harness service user";
    };

    users.groups.${cfg.group} = lib.mkIf (cfg.group == "nexus") { };

    services.postgresql = lib.mkIf cfg.database.createLocally {
      enable = true;
      settings.port = lib.mkDefault cfg.database.port;
      ensureDatabases = [ cfg.database.name ];
      ensureUsers = [
        {
          name = cfg.database.user;
          ensureDBOwnership = cfg.database.name == cfg.database.user;
        }
      ];
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];

    systemd.tmpfiles.rules = map (p: "d ${p} 0750 ${cfg.user} ${cfg.group} -") extraWritePaths;

    systemd.services.nexus-agent = {
      description = "Nexus AI agent harness";
      after =
        [ "network-online.target" ]
        ++ lib.optionals cfg.database.createLocally [
          "postgresql.service"
          "postgresql-setup.service"
        ];
      wants = [ "network-online.target" ];
      requires = lib.optionals cfg.database.createLocally [
        "postgresql.service"
        "postgresql-setup.service"
      ];
      wantedBy = [ "multi-user.target" ];

      environment = cfg.extraEnvironment // baseEnvironment;

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = "/var/lib/nexus";
        StateDirectory = "nexus";
        StateDirectoryMode = "0750";

        EnvironmentFile = lib.optional (cfg.environmentFile != null) (toString cfg.environmentFile);
        LoadCredential = lib.optional (
          cfg.database.passwordFile != null
        ) "pg-password:${toString cfg.database.passwordFile}";

        ExecStartPre =
          lib.optional (cfg.database.createLocally && cfg.database.name != cfg.database.user) "+${ensureDbOwnership}"
          ++ lib.optional (cfg.database.createLocally && cfg.database.passwordFile != null) "+${syncDbPassword}"
          ++ lib.optional cfg.workspace.enable "${ensureWorkspaceDirs}"
          ++ lib.optional cfg.database.runMigrations "${runMigrate}";
        ExecStart = "${runServer}";

        Restart = "on-failure";
        RestartSec = "5s";

        # Cgroup v2 delegation for per-command workspace memory/PID caps
        # (nexus_env_ffi rehomes the BEAM into beam/ and spawns ws-* leaves).
        Delegate = lib.mkIf sandboxActive "cpu memory pids";

        # Hardening tuned for Erlang/OTP BEAM + bwrap/nono + cgroup v2:
        # - MemoryDenyWriteExecute must stay false (BEAM JIT requires RWX/W^X mmaps)
        # - ProtectControlGroups must stay false when cgroup delegation is active
        # - RestrictNamespaces must stay false when bwrap creates user/mnt/pid/net namespaces
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectClock = true;
        ProtectHostname = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        MemoryDenyWriteExecute = false;
        ProtectControlGroups = !sandboxActive;
        RestrictNamespaces = !(sandboxActive && cfg.workspace.sandbox == "bwrap");
        ReadWritePaths = lib.mkIf (extraWritePaths != [ ]) extraWritePaths;
      };
    };
  };
}
