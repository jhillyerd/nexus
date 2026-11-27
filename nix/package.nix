{
  lib,
  stdenv,
  fetchurl,
  writeText,
  runtimeShell,
  gleam,
  rebar3,
  erlang,
  bash,
  coreutils,
  procps,
  util-linux,
}:

let
  gleamToml = builtins.fromTOML (builtins.readFile ../gleam.toml);
  manifest = builtins.fromTOML (builtins.readFile ../manifest.toml);

  fetchHexTarball =
    pkg:
    assert lib.assertMsg (pkg.source == "hex")
      "nix/package.nix: unsupported dependency source '${pkg.source}' for '${pkg.name}' (only hex packages are supported)";
    fetchurl {
      url = "https://repo.hex.pm/tarballs/${pkg.name}-${pkg.version}.tar";
      sha256 = lib.toLower pkg.outer_checksum;
    };

  packagesToml = writeText "packages.toml" (
    "[packages]\n"
    + lib.concatMapStrings (pkg: ''${pkg.name} = "${pkg.version}"'' + "\n") manifest.packages
    + "\n[git]\n"
  );

  runtimeDeps =
    [
      bash
      coreutils
    ]
    ++ lib.optionals stdenv.hostPlatform.isLinux [
      procps
      util-linux
    ];
in
stdenv.mkDerivation {
  pname = gleamToml.name;
  version = gleamToml.version;

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../gleam.toml
      ../manifest.toml
      ../src
      ../priv
      ../sql/migrations
      ../test
    ];
  };

  nativeBuildInputs = [
    gleam
    rebar3
    erlang
  ];

  nativeCheckInputs = lib.optionals stdenv.hostPlatform.isLinux [
    procps
    util-linux
  ];

  configurePhase = ''
    runHook preConfigure

    mkdir -p build/packages
    cp ${packagesToml} build/packages/packages.toml
    ${lib.concatMapStrings (pkg: ''
      mkdir -p build/packages/${lib.escapeShellArg pkg.name}
      tar -xOf ${fetchHexTarball pkg} contents.tar.gz | tar -xz -C build/packages/${lib.escapeShellArg pkg.name}
    '') manifest.packages}
    chmod -R u+w build/packages

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    export HOME="$TMPDIR"
    export REBAR_OFFLINE=1
    export HEX_OFFLINE=true
    gleam export erlang-shipment

    runHook postBuild
  '';

  doCheck = true;

  checkPhase = ''
    runHook preCheck

    export HOME="$TMPDIR"
    export REBAR_OFFLINE=1
    export HEX_OFFLINE=true
    gleam test

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/lib/nexus" "$out/share/nexus/sql/migrations" "$out/bin"
    cp -r build/erlang-shipment/. "$out/lib/nexus/"
    cp -r sql/migrations/. "$out/share/nexus/sql/migrations/"

    cat > "$out/bin/nexus" <<'EOF'
#!${runtimeShell}
set -eu
export PATH="${lib.makeBinPath runtimeDeps}''${PATH:+:$PATH}"
exec ${erlang}/bin/erl \
  -pa "@out@/lib/nexus"/*/ebin \
  -eval "'nexus@@main':run(nexus)" \
  -noshell \
  -extra "$@"
EOF
    sed -i "s|@out@|$out|g" "$out/bin/nexus"
    chmod +x "$out/bin/nexus"

    cat > "$out/bin/nexus-migrate" <<'EOF'
#!${runtimeShell}
set -eu
export NEXUS_MIGRATIONS_DIR="''${NEXUS_MIGRATIONS_DIR:-@out@/share/nexus/sql/migrations}"
exec ${erlang}/bin/erl \
  -pa "@out@/lib/nexus"/*/ebin \
  -eval "'nexus@@main':run('nexus@store@migrate')" \
  -noshell \
  -extra "$@"
EOF
    sed -i "s|@out@|$out|g" "$out/bin/nexus-migrate"
    chmod +x "$out/bin/nexus-migrate"

    runHook postInstall
  '';

  meta = {
    description = "Self-hosted Gleam-on-BEAM AI agent harness";
    mainProgram = "nexus";
    platforms = lib.platforms.unix;
  };
}
