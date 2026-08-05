#!/usr/bin/env bash
# Marginal per-derivation cost, per arm and per parallelism level.
#
# BENCH_BASE.md sec.8 measured one arm (stdenv) at one parallelism (max-jobs=10)
# and reported 175 ms; NEXT.md sec.8.1 measured three arms at the same
# parallelism and reported 123/113/110 ms. Neither varied max-jobs, and the
# real build's phase timings suggest the cost is contention-sensitive -- so the
# jobs axis is the one that decides whether this tax is serial (unabsorbable by
# more cores) or just queueing.
#
# Usage: probe_run.sh [flakeref]
#   flakeref defaults to this repository's bench flake with submodules.
set -uo pipefail
SP="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SP/../../.." && pwd)"
FLAKE="${1:-git+file://$REPO?submodules=1&dir=bench/nix-cargo-unit}"

# Resolve nixpkgs to a store path once, so each probe build is a plain --expr
# with no flake or network resolution inside the measured region.
NIXPKGS=$(nix eval --raw --impure --expr \
  "(builtins.getFlake \"$FLAKE\").inputs.nixpkgs.outPath" \
  2>/dev/null)
echo "nixpkgs = $NIXPKGS" >&2
test -e "$NIXPKGS/default.nix" || { echo "cannot resolve nixpkgs store path" >&2; exit 1; }

printf 'arm\tjobs\trep\tn\tms\trc\n'
for jobs in 10 1; do
  for arm in minimal plain stdenv; do
    for rep in 1 2 3; do
      for n in 40 160; do
        salt="${arm}-j${jobs}-${rep}-${n}-$$"
        s=$(python3 -c 'import time;print(int(time.time()*1000))')
        # --impure: probe.nix lives outside the store, so a pure eval refuses
        # to import it. Costs nothing measurable and is outside the build.
        out=$(nix build --no-link --impure --max-jobs "$jobs" --expr \
          "import $SP/probe.nix { pkgs = import $NIXPKGS {}; n = $n; arm = \"$arm\"; salt = \"$salt\"; }" 2>&1)
        rc=$?
        e=$(python3 -c 'import time;print(int(time.time()*1000))')
        printf '%s\t%d\t%d\t%d\t%d\t%d\n' "$arm" "$jobs" "$rep" "$n" "$((e-s))" "$rc"
        if [ $rc -ne 0 ]; then echo "FAILED $arm j$jobs n$n:" >&2; echo "$out" | tail -12 >&2; fi
      done
    done
  done
done
