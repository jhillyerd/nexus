{
  description = "nexus - self-hosted Gleam/BEAM agent harness";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      linuxSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems =
        f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      forLinuxSystems =
        f: nixpkgs.lib.genAttrs linuxSystems (system: f nixpkgs.legacyPackages.${system});

      mkNexus =
        pkgs:
        pkgs.callPackage ./nix/package.nix {
          erlang = pkgs.beamPackages.erlang;
        };

      nixosModule = import ./nix/module.nix self;
    in
    {
      packages = forAllSystems (pkgs: rec {
        nexus = mkNexus pkgs;
        default = nexus;
      });

      overlays.default = final: _prev: {
        nexus-agent = mkNexus final;
      };

      nixosModules = {
        nexus-agent = nixosModule;
        default = nixosModule;
      };

      checks = forLinuxSystems (pkgs: {
        nixos-service = import ./nix/test.nix { inherit pkgs self; };
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages =
            with pkgs;
            [
              gleam
              beamPackages.erlang
              rebar3
            ]
            ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              bubblewrap
            ];

          shellHook = ''
            echo "gleam $(gleam --version)"
          '';
        };
      });
    };
}
