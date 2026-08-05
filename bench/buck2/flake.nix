{
  description = "rust-analyzer's workspace built by buck2, for comparison against the nix-cargo-unit bench";

  inputs = {
    # Pinned to the exact revision `bench/nix-cargo-unit/flake.lock` resolves to.
    # The comparison is only meaningful if both sides invoke the same rustc, and
    # this is the only thing that guarantees it: buck2's `system_rust_toolchain`
    # takes whatever `rustc` is on `$PATH`, so the devShell *is* the toolchain
    # pin. Move this when the other bench's lock moves.
    nixpkgs.url = "github:NixOS/nixpkgs/624af665418d3c65d544145b4d34ad696439570e";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    inherit (nixpkgs) lib;

    systems = [
      "aarch64-darwin"
      "aarch64-linux"
      "x86_64-darwin"
      "x86_64-linux"
    ];
    forAllSystems = fn: lib.genAttrs systems (system: fn nixpkgs.legacyPackages.${system});
  in {
    # There is no package output: buck2 is the build system here, so the build
    # happens in `buck2 build`, not in Nix. This flake exists only to put the
    # right binaries on `$PATH` — which, for a build whose toolchain is resolved
    # from `$PATH`, is not a small thing.
    devShells = forAllSystems (pkgs: {
      default = pkgs.mkShell {
        packages = [
          pkgs.buck2
          pkgs.reindeer

          # The same two derivations the nix-cargo-unit bench compiles with.
          # `rustc` here is nixpkgs' wrapper, unlike over there: the wrapper only
          # forwards `$NIX_RUSTFLAGS` (unset) and is what `rustc --version`
          # resolves to on a normal `$PATH`, which is what buck2 and reindeer
          # both expect to find.
          pkgs.rustc
          pkgs.cargo

          # `system_cxx_toolchain` shells out to `clang` for the link step, and
          # prelude's internal tools are python scripts.
          pkgs.clang
          pkgs.python3
        ];

        # Every binary here links `-liconv`, and nothing else in this shell pulls
        # it in: `clang` above is the compiler, not a libc closure. It has to be
        # `buildInputs` rather than `packages`, because it is cc-wrapper's
        # buildInputs hook that puts `-L<libiconv>/lib` into `$NIX_LDFLAGS`,
        # which is the only way the linker buck2 invokes ever hears about it.
        #
        # This was latent for as long as some unrelated derivation happened to
        # keep libiconv alive in the store: the link picked it up from the
        # ambient store rather than from anything this flake declares. A
        # `nix-collect-garbage -d` removes it and every binary target fails with
        # `ld: library not found for -liconv`. The nix-cargo-unit bench never had
        # the bug — libiconv is a declared runtime dependency there, and is one
        # of the two paths in the LSP binary's closure.
        buildInputs = [pkgs.libiconv];
      };
    });

    # Matches the parent repository's formatter.
    formatter = forAllSystems (pkgs: pkgs.alejandra);
  };
}
