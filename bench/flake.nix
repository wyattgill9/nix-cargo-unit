{
  description = "rust-analyzer's workspace built one Cargo unit at a time, by nix-cargo-unit";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Relative, so it resolves against whatever tree this flake was fetched
    # from — `git+file://$PWD?submodules=1&dir=bench` lands on the repository
    # root and keeps the submodule. `path:$PWD/bench` would make a standalone
    # store copy of this directory, and `..` would then resolve to `/nix`.
    nix-cargo-unit = {
      url = "path:..";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    nixpkgs,
    nix-cargo-unit,
    ...
  }: let
    inherit (nixpkgs) lib;

    systems = [
      "aarch64-darwin"
      "aarch64-linux"
      "x86_64-darwin"
      "x86_64-linux"
    ];
    forAllSystems = fn: lib.genAttrs systems (system: fn nixpkgs.legacyPackages.${system});

    # `bench/rust-analyzer` is a git submodule, and a submodule's contents are
    # not part of a `git+file://` flake source unless the flakeref asks for
    # them: git records the submodule as a gitlink, and Nix's git fetcher skips
    # gitlinks without `submodules=1`. Checked here so the failure names the two
    # commands that fix it, instead of surfacing a hundred lines later as cargo
    # refusing to open a manifest that is not there.
    workspaceSrc =
      if builtins.pathExists (./rust-analyzer + "/Cargo.toml")
      then ./rust-analyzer
      else
        throw ''
          bench/rust-analyzer is empty: the rust-analyzer submodule is not visible to this flake.

          Populate it once:
              git submodule update --init bench/rust-analyzer

          Then build with a flakeref that carries submodules:
              nix build "git+file://$PWD?submodules=1&dir=bench"

          `nix build ./bench` alone resolves to a plain `git+file://` fetch of the
          repository, which drops every gitlink.
        '';

    # Everything this bench builds, per system: what
    # `cargoUnit.buildWorkspace` returns (`units`, `roots`, `binaries`,
    # `libraries`, `packages`, `tests`, plus the pipeline stages), extended with
    # the toolchain those units were compiled with and with `workspace`, the
    # graph's roots merged into one tree.
    benchFor = pkgs: let
      # `rustc` in nixpkgs is a thin wrapper that only forwards `$NIX_RUSTFLAGS`
      # and ships `bin/` alone; the unwrapped derivation is the one carrying
      # `lib/rustlib`, which the rendered units reference for the std
      # `--remap-path-prefix` and for `llvm-cov`.
      #
      # `mkCargoUnit` derives the toolchain id baked into every unit hash
      # from this derivation's store path, so a nixpkgs bump that moves rustc
      # invalidates the graph instead of silently reusing artifacts built by a
      # different compiler. Cargo's `--unit-graph` is still behind
      # `-Z unstable-options`, but the planner IFD sets `RUSTC_BOOTSTRAP=1`
      # itself, so a stable nixpkgs toolchain is enough and no nightly overlay
      # input is needed.
      rustToolchain = pkgs.symlinkJoin {
        name = "cargo-unit-rust-toolchain-${pkgs.rustc.version}";
        paths = [
          pkgs.rustc.unwrapped
          pkgs.cargo
          pkgs.clippy
          pkgs.rustfmt
        ];
      };

      # The consumer entry point: the flake's own library, which wires vendoring,
      # build policy and the renderer together and hands back `buildWorkspace`
      # and friends. The whole Cargo.lock -> vendor -> unit graph -> units.nix ->
      # per-unit derivation pipeline lives behind that one call; nothing of it is
      # spelled out here, and the renderer binary is built from `pkgs` rather
      # than picked out of the input by system.
      cargoUnit = nix-cargo-unit.lib.mkCargoUnit {
        inherit pkgs rustToolchain;
      };

      graph = cargoUnit.buildWorkspace {
        # Names the workspace-level policy check derivations. With `pureBuild`
        # below none are enabled, so it only shows up in error messages.
        pname = "rust-analyzer";

        # One store path used as both: cargo plans against it (through the
        # content-stubbed planner tree `buildWorkspace` derives from it), and
        # the renderer slices every local unit's source closure out of it.
        # rust-analyzer's checkout root is its Cargo workspace root, so `src`
        # and `workspaceRoot` are the same tree.
        src = workspaceSrc;
        workspaceRoot = workspaceSrc;

        # The profile is baked into every unit hash, so changing it re-plans,
        # re-renders and rebuilds the graph.
        profile = "release";

        # This is a build benchmark: the point is the shape and the wall clock
        # of the unit graph, not gating someone else's tree. `pureBuild` turns
        # off unused-crate-dependency denial, cargo-audit, cargo-machete and
        # per-unit clippy in one named preset. Two of those would fail here for
        # reasons that have nothing to do with cargo-unit (rust-analyzer does
        # not build under `-D unused_crate_dependencies`, and its advisory
        # surface is upstream's to carry); per-unit clippy additionally wants a
        # `clippy.package.toolchain`, which the nixpkgs `clippy` derivation does
        # not carry — that seam is for fenix/rust-overlay toolchains.
        policy = cargoUnit.policyPresets.pureBuild;

        # Content-addressed units need the `ca-derivations` experimental
        # feature. Off by default in Nix, so opt out rather than hand every
        # consumer of this bench a store that refuses to build it. Turn it back
        # on to measure early cutoff (see README §9).
        contentAddressed = false;
      };

      # `graph.default` is only the graph's first root. The whole workspace is
      # every root: each member crate's library and binary targets.
      #
      # `pathsToLink` drops each unit's `nix-support/extern-path`, the pointer
      # the renderer uses to wire one unit's rlib into the next. Every root
      # carries one, they all collide, and none of them means anything once the
      # units are merged into a single tree.
      workspace = pkgs.buildEnv {
        name = "rust-analyzer-workspace";
        paths = graph.roots;
        pathsToLink = [
          "/bin"
          "/lib"
        ];
      };
    in
      graph
      // {
        inherit rustToolchain workspace;
      };
  in {
    # Flat derivations only, so `nix flake show` and `nix flake check` stay
    # happy. The nested per-unit / per-target sets live in `legacyPackages`,
    # which `nix build .#<attr>` falls through to anyway.
    packages = forAllSystems (
      pkgs: let
        ra = benchFor pkgs;
      in {
        # Every workspace root in one tree: the point of the exercise.
        default = ra.workspace;
        inherit (ra) workspace;

        rust-analyzer = ra.binaries."rust-analyzer";
        rust-analyzer-proc-macro-srv = ra.binaries."rust-analyzer-proc-macro-srv";

        # The pipeline's intermediate stages, buildable on their own when a
        # planning or render problem needs to be looked at directly.
        inherit
          (ra)
          plannerSource
          rustToolchain
          unitGraphJson
          unitsNix
          vendorDir
          ;
      }
    );

    # The whole `buildWorkspace` result. `nix build` resolves a bare `#attr`
    # against `packages.<system>` first and `legacyPackages.<system>` second, so
    # individual compile units and per-target sets keep their short spellings:
    #
    #     nix build ./bench#units.'"syntax-0.0.0-<hash>"'
    #     nix build ./bench#libraries.syntax
    #     nix build ./bench#targetSets.'"0"'.binaries.rust-analyzer
    legacyPackages = forAllSystems benchFor;

    checks = forAllSystems (
      pkgs: let
        ra = benchFor pkgs;
      in {
        # The unit graph only proves the pieces link. This proves the linked
        # binary is the real one: it answers `--version` and its parser produces
        # a syntax tree, so a mislinked or truncated artifact still fails here.
        smoke =
          pkgs.runCommand "rust-analyzer-smoke" {
            nativeBuildInputs = [ra.binaries."rust-analyzer"];
          } ''
            rust-analyzer --version | tee version.txt
            grep -q '^rust-analyzer ' version.txt

            printf 'fn main() { let x: i32 = 1; }\n' > input.rs
            rust-analyzer parse < input.rs | tee parsed.txt
            grep -q 'SOURCE_FILE@' parsed.txt
            # `!` keeps `set -e` from tripping on grep's no-match exit.
            ! grep -qi 'error' parsed.txt

            mkdir -p "$out"
            cp version.txt parsed.txt "$out"/
          '';
      }
    );

    # The cargo/rustc the units are built with, for poking at the workspace by
    # hand. Not used by the build itself.
    devShells = forAllSystems (pkgs: {
      default = pkgs.mkShell {
        packages = [(benchFor pkgs).rustToolchain];
      };
    });

    # Matches the parent repository's formatter.
    formatter = forAllSystems (pkgs: pkgs.alejandra);
  };
}
