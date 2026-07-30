# The composition root behind the flake's `lib.mkCargoUnit`: build a Cargo
# workspace as one derivation per rustc compile unit.
#
# Reached through the flake, never by path:
#
#     inputs.nix-cargo-unit.url = "github:wyattgill9/nix-cargo-unit";
#     ...
#     cargoUnit = nix-cargo-unit.lib.mkCargoUnit {
#       inherit pkgs;
#       rustToolchain = <cargo + rustc, carrying lib/rustlib>;
#     };
#
# The renderer binary is built from the caller's own `pkgs` (see `package.nix`),
# so a consumer supplies only the two things this flake cannot decide for them:
# which nixpkgs, and which Rust toolchain.
#
# Returns
#   buildWorkspace         plan, render and build a workspace's unit graph
#   selectBinary           pick one root out of a built workspace, wired for
#   selectLibrary          `passthru.tests` and the per-crate policy gates
#   mkPrebuiltLibraryUnit  a library unit from an already-compiled rlib/rmeta
#   policyPresets          named partial policies (`pureBuild`)
#   toolchainId            the id this call salts every unit hash with
#
# One call means one toolchain and one clippy, so a workspace that needs
# different ones is a second `mkCargoUnit` call rather than a per-call override.
#
# Module map
#   workspace.nix  `buildWorkspace`: composes everything below
#   vendor.nix     Cargo.lock -> vendor tree + cargo config script
#   graph.nix      the two IFD stages: cargo plan, then render `units.nix`
#   policy.nix     the policy schema, and every policy-to-flags mapping
#   checks.nix     the workspace policy gates cargo-audit and cargo-machete
#   rustflags.nix  every source of rustc args, composed per platform
#   test-run.nix   the nextest and libtest checks for each test target
#   prebuilt.nix   prebuilt library units and the injection guards
#   select.nix     `selectBinary` / `selectLibrary`
#   package.nix    the `nix-cargo-unit` binary itself
{
  pkgs,
  # The toolchain every unit compiles with. Cargo only emits a unit graph under
  # `-Z unstable-options`, but the planner sets `RUSTC_BOOTSTRAP=1` itself, so a
  # stable toolchain is enough. nixpkgs' `rustc` is a thin wrapper shipping
  # `bin/` alone, so pass something that also carries `lib/rustlib` — the
  # rendered units reference it for the std `--remap-path-prefix` and for
  # `llvm-cov` (e.g. `symlinkJoin` of `rustc.unwrapped` and `cargo`).
  rustToolchain,
}: let
  inherit (pkgs) lib;

  # The renderer, built from the caller's nixpkgs. The flake input is the version
  # selector, so there is no seam for substituting a different binary here.
  nixCargoUnit = pkgs.callPackage ./package.nix {};

  # A toolchain's id is the basename of its store path. The renderer salts every
  # unit hash with it, so a toolchain move invalidates the graph instead of
  # silently reusing artifacts built by a different compiler.
  toolchainId = builtins.baseNameOf (toString rustToolchain);

  # This machine's *Rust* target triple, which is not `hostPlatform.config`:
  # that is an LLVM triple and spells darwin's arm64 `arm64-apple-darwin`, where
  # rustc, `lib/rustlib/<triple>`, and a `[target.<triple>]` cargo config
  # section all say `aarch64-apple-darwin`. Everything downstream of here — the
  # platform a unit's rustc args are resolved for, and the triple nextest is
  # handed — is a Rust triple, so it is spelled once, here.
  hostTriple = pkgs.stdenv.hostPlatform.rust.rustcTarget;

  vendor = import ./vendor.nix {inherit lib pkgs;};
  policyLib = import ./policy.nix {inherit lib pkgs;};
  rustflags = import ./rustflags.nix {inherit lib policyLib hostTriple;};
  checks = import ./checks.nix {
    inherit
      lib
      pkgs
      policyLib
      rustToolchain
      vendor
      ;
  };
  graph = import ./graph.nix {
    inherit
      lib
      pkgs
      nixCargoUnit
      rustToolchain
      toolchainId
      ;
  };
  testRun = import ./test-run.nix {
    inherit
      lib
      pkgs
      nixCargoUnit
      policyLib
      rustToolchain
      ;
  };
  prebuilt = import ./prebuilt.nix {inherit lib pkgs toolchainId;};
  select = import ./select.nix {inherit lib;};
in {
  inherit toolchainId;
  inherit (policyLib) policyPresets;
  inherit (prebuilt) mkPrebuiltLibraryUnit;
  inherit (select) selectBinary selectLibrary;

  buildWorkspace = import ./workspace.nix {
    inherit
      lib
      pkgs
      nixCargoUnit
      rustToolchain
      hostTriple
      checks
      graph
      policyLib
      prebuilt
      rustflags
      testRun
      vendor
      ;
  };
}
