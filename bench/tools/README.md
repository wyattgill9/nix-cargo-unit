# `bench/tools` — the profiling harness

The scripts that produced `bench/PROFILE.md`. They exist because the two
measurement documents that came before it disagreed by an order of magnitude
about per-derivation overhead, and the disagreement was only resolvable by
instrumenting the real build instead of extrapolating from synthetic probes.

Everything here is read-only with respect to the store: no `nix store delete`.
A full rebuild is forced by **salting the toolchain id**, which moves every unit
hash while leaving existing outputs in place.

## Prerequisites

```console
$ git submodule update --init --depth 1 bench/rust-analyzer
$ nix flake update nix-cargo-unit --flake ./bench   # if bench/flake.lock is stale
```

Add the salt seam to `bench/flake.nix` (one line, reverted afterwards):

```nix
name = "cargo-unit-rust-toolchain-${pkgs.rustc.version}${builtins.getEnv "NCU_SALT"}";
```

With `NCU_SALT` empty this is a no-op — the unsalted derivation path is
byte-identical, so the seam can be left in place without moving any hash.

## 1. Profile a full build

```console
$ export NCU_SALT=-prof1
$ FLAKE="git+file://$PWD?submodules=1&dir=bench"
$ python3 bench/tools/build_prof.py /tmp/prof/run1 \
    nix build --impure --log-format internal-json -v --no-link \
    "$FLAKE#packages.aarch64-darwin.workspace"
```

Writes `run1.events.jsonl` (every stamped event), `run1.builds.tsv` and
`run1.summary.json`.

`--log-format internal-json` carries no timestamps of its own, so events are
stamped on arrival.

## 2. Attribute it

```console
$ python3 bench/tools/analyze.py /tmp/prof run1     # per kind and per stdenv phase
$ python3 bench/tools/critpath.py /tmp/prof run1    # weighted critical path
$ python3 bench/tools/mechanism.py /tmp/prof run1   # does overhead scale with inputs?
```

`analyze.py` is where the two non-obvious parsing rules live, and both matter:

- Nix **re-announces a queued build's `actBuild` activity under a fresh id** each
  time the goal is re-created. Taking min-start to max-stop over every activity
  naming a drv measures queue latency, not build time — it reports a 39 s
  `unicode_ident`. An activity is a real build **iff it emitted a
  `resBuildLogLine`**.
- `resSetPhase` events inside that activity give the stdenv phase timeline, which
  is what separates rustc from scaffolding.

## 3. Split rustc's own time

```console
$ python3 bench/tools/rustc_split.py /tmp/prof/split "$TOOLCHAIN/bin" \
    hir_ty /nix/store/…-hir_ty-0.0.0.drv 1
$ python3 bench/tools/parse_passes.py /tmp/prof
```

Replays a unit's exact `rustc` invocation outside Nix, three ways: full `--emit`,
`--emit metadata` only, and full with `-Ztime-passes`. This works because a
unit's generated `buildPhase` needs only `$src` from the build environment (plus
`$NIX_BUILD_TOP` when the package has a build script).

`parse_passes.py` sums only **non-overlapping** `-Ztime-passes` buckets.
`LLVM_passes` and `LLVM_thinlto` are summed across worker threads and can exceed
the backend's wall time, so they are reported as a breakdown inside
`finish_ongoing_codegen`, never added to it.

## 4. Per-derivation overhead

```console
$ bench/tools/probe_run.sh > /tmp/prof/probe.tsv
```

Three arms (`minimal` plain `derivation`, `plain` + `__structuredAttrs`,
`stdenv`) × `max-jobs` ∈ {10, 1} × 3 reps × N ∈ {40, 160}; marginal cost is
Δt/ΔN. The `minimal` arm is what says how much of the cost is Nix's own floor,
which no change to a unit's shape can touch. The `max-jobs` axis is what says
whether the tax is *serial* — neither prior document varied it.

Every probe's builder is verified to have run (a plain `derivation` has no
`PATH`, so an unqualified `mkdir` fails silently — the trap that made an earlier
`minimal` arm measure nothing).

## 5. Predict before building

```console
$ python3 bench/tools/simulate.py /tmp/prof run1 10
```

A greedy list scheduler over the measured DAG. It is **first validated** against
the run it came from: if it cannot reproduce that run's makespan from that run's
graph, its prediction for a different graph is worthless — and the size of the
miss is itself the interesting number, because it is the part of wall clock that
is neither dependency order nor job count.

Then it re-runs over the pipelined graph, where `code_i` depends on `meta_j` for
each dependency (not on `code_j` — rustc only needs a dependency's `.rmeta` to
codegen against it) and the root link needs every `code_i`. The extra CPU from
running each frontend twice is modelled, not waved away.
