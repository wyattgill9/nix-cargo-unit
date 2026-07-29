{
  description = "Render Cargo unit graphs as composable Nix derivations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    systems = [
      "aarch64-darwin"
      "aarch64-linux"
      "x86_64-darwin"
      "x86_64-linux"
    ];
    forAllSystems = fn:
      nixpkgs.lib.genAttrs systems (system: fn nixpkgs.legacyPackages.${system});

    package = {
      lib,
      rustPlatform,
    }:
      rustPlatform.buildRustPackage {
        pname = "nix-cargo-unit";
        version = (lib.importTOML ./Cargo.toml).package.version;

        src = lib.fileset.toSource {
          root = ./.;
          fileset = lib.fileset.unions [
            ./Cargo.toml
            ./Cargo.lock
            ./src
            # `render.rs` pulls the units template in with `include_str!`.
            ./templates
          ];
        };

        cargoLock.lockFile = ./Cargo.lock;

        meta = {
          description = "Render Cargo unit graphs as composable Nix derivations";
          license = lib.licenses.mit;
          mainProgram = "nix-cargo-unit";
        };
      };
  in {
    packages = forAllSystems (pkgs: rec {
      nix-cargo-unit = pkgs.callPackage package {};
      default = nix-cargo-unit;
    });

    overlays.default = final: _prev: {
      nix-cargo-unit = final.callPackage package {};
    };

    devShells = forAllSystems (pkgs: {
      default = pkgs.mkShell {
        inputsFrom = [self.packages.${pkgs.system}.nix-cargo-unit];
        packages = [
          pkgs.cargo
          pkgs.clippy
          pkgs.rust-analyzer
          pkgs.rustc
          pkgs.rustfmt
        ];
        env.RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";
      };
    });

    checks = forAllSystems (pkgs: {
      inherit (self.packages.${pkgs.system}) nix-cargo-unit;
    });

    formatter = forAllSystems (pkgs: pkgs.alejandra);
  };
}
