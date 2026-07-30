# Per-derivation fixed-cost probe, in three arms.
#
# Settles what BENCH_BASE.md §8 (175 ms, attributed to "sandbox setup, stdenv
# bash startup, phase dispatch, output registration" without separating them)
# and NEXT.md §8.1 (123 ms stdenv, 110 ms bare floor) disagree about. The point
# of three arms rather than one is that a `minimal` arm is the only thing that
# says how much of the cost is Nix's own floor -- which no shape change can
# touch -- versus stdenv's, which one can.
#
#   minimal  a plain `derivation`; the builder writes $out and nothing else
#   plain    a plain `derivation` with __structuredAttrs and a static builder
#   stdenv   stdenv.mkDerivation with the suppressions units actually use
#
# Every arm's builder is verified to have run by requiring its output to exist
# and contain the marker (a plain derivation has no PATH, so an unqualified
# `mkdir` silently fails -- the trap NEXT.md §8.1 records hitting).
{
  pkgs ? import <nixpkgs> {},
  n ? 40,
  arm ? "minimal",
  salt ? "0",
}: let
  inherit (pkgs) lib;
  bash = "${pkgs.bash}/bin/bash";
  coreutils = "${pkgs.coreutils}/bin";

  mkMinimal = i:
    derivation {
      name = "probe-minimal-${salt}-${toString i}";
      system = pkgs.stdenv.hostPlatform.system;
      builder = bash;
      args = [
        "-c"
        "${coreutils}/mkdir -p $out && ${coreutils}/echo ${toString i} > $out/marker"
      ];
    };

  # `__structuredAttrs` moves the attrs into a JSON file the builder sources,
  # which is the shape NEXT.md §B.1 proposes for a unit. Included because it
  # changes derivation inputs and could plausibly cost something.
  staticBuilder =
    pkgs.writeScript "probe-builder.sh" ''
      #!${bash}
      set -eu
      . "$NIX_ATTRS_SH_FILE"
      # Under __structuredAttrs the outputs are an associative array, not $out.
      out="''${outputs[out]}"
      ${coreutils}/mkdir -p "$out"
      ${coreutils}/echo "$idx" > "$out/marker"
    '';

  mkPlain = i:
    derivation {
      name = "probe-plain-${salt}-${toString i}";
      system = pkgs.stdenv.hostPlatform.system;
      builder = bash;
      args = [staticBuilder];
      __structuredAttrs = true;
      idx = toString i;
    };

  mkStdenv = i:
    pkgs.stdenv.mkDerivation {
      name = "probe-stdenv-${salt}-${toString i}";
      dontUnpack = true;
      dontConfigure = true;
      dontStrip = true;
      buildPhase = "true";
      installPhase = ''
        mkdir -p "$out"
        echo ${toString i} > "$out/marker"
      '';
    };

  mk =
    {
      minimal = mkMinimal;
      plain = mkPlain;
      stdenv = mkStdenv;
    }
    .${arm};

  probes = map mk (lib.range 1 n);
in
  # One root depending on all N, so a single `nix build` schedules them all and
  # the check that each builder really ran is part of the measured graph's
  # result rather than a separate pass.
  pkgs.runCommand "probe-${arm}-${salt}-n${toString n}" {} ''
    for p in ${lib.escapeShellArgs (map toString probes)}; do
      test -s "$p/marker" || { echo "probe did not build: $p" >&2; exit 1; }
    done
    echo ${toString n} > $out
  ''
