# The `nix-cargo-unit` binary: merges Cargo unit graphs, renders them as
# `units.nix`, synthesizes cargo-nextest metadata for a rendered test binary, and
# scans compiled artifacts for reachable panics.
#
# Callable from any nixpkgs, so `mkCargoUnit` can build the tool from the
# consumer's own `pkgs` instead of pinning them to this flake's nixpkgs.
{
  lib,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "nix-cargo-unit";
  version = (lib.importTOML ../Cargo.toml).package.version;

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../Cargo.toml
      ../Cargo.lock
      ../src
      # `render.rs` pulls the units template in with `include_str!`.
      ../templates
    ];
  };

  cargoLock.lockFile = ../Cargo.lock;

  meta = {
    description = "Render Cargo unit graphs as composable Nix derivations";
    license = lib.licenses.mit;
    mainProgram = "nix-cargo-unit";
  };
}
