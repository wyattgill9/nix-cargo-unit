# The consumer entry point: wire the Rust build context (`resolve.nix`, which
# owns vendoring and build policy) into the cargo-unit renderer and return its
# surface — `buildWorkspace`, `buildBinary`, `buildBinaries`,
# `selectBinaryWithTests`, `selectLibraryWithTests`, `mkPrebuiltLibraryUnit`,
# `defaultToolchainId`, `policyPresets`.
#
#   import ./nix {
#     inherit pkgs;
#     rustToolchain = <a nightly toolchain>;
#     nixCargoUnit = <the nix-cargo-unit binary>;
#   }
{
  pkgs,
  lib ? pkgs.lib,
  # The `nix-cargo-unit` binary that renders a unit graph into `units.nix`
  # (this repo's flake package).
  nixCargoUnit,
  # Cargo only emits a unit graph under `-Z unstable-options`, so this must be
  # a nightly toolchain. Supplied by the caller: nixpkgs carries no nightly, so
  # the toolchain source (fenix, rust-overlay, ...) is the consumer's choice.
  rustToolchain,
  # `clippy-driver` for the per-unit clippy checks; override to run a fork.
  clippyPackage ? pkgs.clippy,
}:
import ./cargo-unit.nix {
  inherit lib pkgs nixCargoUnit;
  rust = import ./resolve.nix {
    inherit
      lib
      pkgs
      rustToolchain
      clippyPackage
      ;
  };
}
