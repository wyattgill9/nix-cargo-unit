{
  description = "rust-analyzer's workspace built by buck2, for comparison against the nix-cargo-unit bench";

  inputs = {
    # Pinned to the exact revision `bench/nix-cargo-unit/flake.lock` resolves to.
    # The comparison is only meaningful if both sides invoke the same rustc, and
    # this is what guarantees it: `toolchains/BUCK` names `packages.<system>.rustc`
    # from *this* flake, so the pin below is the compiler buck2 runs. Move it when
    # the other bench's lock moves.
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
    # The toolchains buck2 builds with. `toolchains/BUCK` names these through
    # buck2.nix's `flake.package()`, which runs `nix build` as a build action, so
    # every compiler invocation resolves to a store path this file decides rather
    # than to whatever `$PATH` happened to hold when the daemon started.
    #
    # There is still no package output for rust-analyzer itself: buck2 is the
    # build system here, so that build happens in `buck2 build`, not in Nix.
    packages = forAllSystems (pkgs: {
      # `rustc` is nixpkgs' wrapper, unlike on the nix-cargo-unit side: it only
      # forwards `$NIX_RUSTFLAGS` (unset). It carries `bin/rustdoc` as well,
      # which `nix_rust_toolchain` requires and reaches as a sub-target.
      inherit (pkgs) rustc clippy python3;

      # `nix_cxx_toolchain` wants one package holding the whole cc + binutils
      # set, and nixpkgs' compiler is only correct with its `$NIX_*` variables
      # set. A buck2 action inherits none of this shell's environment, so the
      # wrapper scripts below are how those variables reach the compiler at all.
      cxx = pkgs.stdenv.mkDerivation {
        name = "buck2-cxx";
        dontUnpack = true;
        dontCheck = true;
        nativeBuildInputs = [pkgs.makeWrapper];

        # Every binary target links `-liconv`. Declaring it here is what puts
        # `-L<libiconv>/lib` into the `$NIX_LDFLAGS` captured below, and so into
        # the link buck2 runs.
        #
        # The old setup declared it in the devShell instead, which worked only
        # for as long as the link inherited that shell's environment. It also
        # hid the failure until a `nix-collect-garbage -d`: until then the
        # linker found libiconv in the ambient store rather than through
        # anything this flake declares.
        buildInputs = [pkgs.libiconv];

        buildPhase = ''
          # Everything cc-wrapper communicates to the compiler out of band.
          # `makeWrapper --set` bakes it in, since there is no shell in between
          # a buck2 action and the compiler to export it.
          function capture_env() {
            local -ar vars=(
              NIX_CC_WRAPPER_TARGET_HOST_
              NIX_CFLAGS_COMPILE
              NIX_DONT_SET_RPATH
              NIX_ENFORCE_NO_NATIVE
              NIX_HARDENING_ENABLE
              NIX_IGNORE_LD_THROUGH_GCC
              NIX_LDFLAGS
              NIX_NO_SELF_RPATH
            )
            for prefix in "''${vars[@]}"; do
              for v in $(eval 'echo "''${!'"$prefix"'@}"'); do
                echo "--set"
                echo "$v"
                echo "''${!v}"
              done
            done
          }

          mkdir -p "$out/bin"

          # The binutils half reads no `$NIX_*` and needs no wrapping.
          for tool in ar nm objcopy ranlib strip; do
            ln -st "$out/bin" "$NIX_CC/bin/$tool"
          done

          mapfile -t < <(capture_env)

          makeWrapper "$NIX_CC/bin/$CC" "$out/bin/cc" "''${MAPFILE[@]}"
          makeWrapper "$NIX_CC/bin/$CXX" "$out/bin/c++" "''${MAPFILE[@]}"
        '';
      };
    });

    # What drives the build, not what the build compiles with — that distinction
    # is the point of the buck2.nix setup, and did not exist before it.
    # `reindeer` shells out to `cargo metadata` to resolve the graph, so cargo
    # and rustc are here for *generation*. Nothing on this `$PATH` reaches a
    # compile action.
    devShells = forAllSystems (pkgs: {
      default = pkgs.mkShellNoCC {
        packages = [
          pkgs.buck2
          pkgs.reindeer
          pkgs.cargo
          pkgs.rustc

          # buck2 shells out to `git` to fetch the `nix` external cell declared
          # in `../.buckconfig`, and to nothing else.
          pkgs.git
        ];
      };
    });

    # Matches the parent repository's formatter.
    formatter = forAllSystems (pkgs: pkgs.alejandra);
  };
}
