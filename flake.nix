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

    # A toolchain for the flake's own outputs. nixpkgs' `rustc` is a thin wrapper
    # shipping `bin/` alone; the rendered units reference `lib/rustlib`, which
    # lives in the unwrapped derivation.
    toolchainFor = pkgs:
      pkgs.symlinkJoin {
        name = "nix-cargo-unit-rust-toolchain-${pkgs.rustc.version}";
        paths = [
          pkgs.rustc.unwrapped
          pkgs.cargo
        ];
      };
  in {
    # The library. Not system-indexed on purpose: `mkCargoUnit` reads the system
    # off the `pkgs` it is handed and builds the renderer from that same nixpkgs,
    # so a consumer never indexes an attribute by system and never wires the
    # binary in by hand.
    #
    #     cargoUnit = nix-cargo-unit.lib.mkCargoUnit {
    #       inherit pkgs;
    #       rustToolchain = <cargo + rustc, carrying lib/rustlib>;
    #     };
    #     graph = cargoUnit.buildWorkspace { src = ./.; workspaceRoot = ./.; };
    lib.mkCargoUnit = import ./nix;

    # The renderer binary on its own, for a shell or a CI step that wants the
    # CLI. Consumers of the library do not need this: `mkCargoUnit` builds it.
    packages = forAllSystems (pkgs: rec {
      nix-cargo-unit = pkgs.callPackage ./nix/package.nix {};
      default = nix-cargo-unit;
    });

    devShells = forAllSystems (pkgs: {
      default = pkgs.mkShell {
        inputsFrom = [self.packages.${pkgs.stdenv.hostPlatform.system}.nix-cargo-unit];
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
      inherit (self.packages.${pkgs.stdenv.hostPlatform.system}) nix-cargo-unit;

      # The exported library, reached the way a consumer reaches it, applied to
      # this repository's own workspace.
      #
      # Evaluating this check is most of the check: it resolves the policy schema
      # and the vendor plan, runs both IFD stages (cargo plans the graph, the
      # renderer emits `units.nix`), and then instantiates every unit in the
      # rendered graph. So a break anywhere in `mkCargoUnit`, the modules behind
      # it, or the generated Nix fails `nix flake check` without compiling a
      # single crate. `bench/` is where units actually get built.
      library = let
        cargoUnit = self.lib.mkCargoUnit {
          inherit pkgs;
          rustToolchain = toolchainFor pkgs;
        };
        graph = cargoUnit.buildWorkspace {
          pname = "nix-cargo-unit";
          src = ./.;
          workspaceRoot = ./.;
          policy = cargoUnit.policyPresets.pureBuild;
          contentAddressed = false;
        };
      in
        builtins.deepSeq (map (unit: unit.drvPath) (builtins.attrValues graph.units)) graph.unitsNix;
    });

    formatter = forAllSystems (pkgs: pkgs.alejandra);
  };
}
