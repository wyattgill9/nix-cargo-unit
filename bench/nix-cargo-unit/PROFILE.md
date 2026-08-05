# `PROFILE.md` — where the time actually goes, and what to benchmark next

Deep profile taken **2026-07-29**, after `BENCH_BASE.md` (2026-07-28) and
`research/NEXT.md`. Same machine, same workload: rust-analyzer's workspace,
`--profile release`, one Nix derivation per Cargo compilation unit.

It differs from its predecessors in one methodological respect, which turns out to
explain most of the disagreement between them: **every figure here is measured on
the real build**, by instrumenting the 320 units that actually run, rather than
extrapolated from synthetic probe derivations. Where a synthetic probe is still
the right tool (§5) it is run in three arms and at two parallelism levels —
because one arm at one parallelism is what produced the contradiction.

Harness: `bench/nix-cargo-unit/tools/` (see its README). Nothing here deletes from the store.

---

## 0. Read this first — three findings that invalidate prior numbers

### 0.1 The benchmark does not build at `HEAD`

Commit `39a8eda` added the `advisory-db` input to the root `flake.nix` but did not
update `bench/nix-cargo-unit/flake.lock`, which still locks `nix-cargo-unit` with `nixpkgs` as its
only input:

```
error: function 'outputs' called without required argument 'advisory-db'
       at flake.nix:19:13
```

Every measurement below required `nix flake update nix-cargo-unit --flake ./bench/nix-cargo-unit`
first. **A baseline that cannot be run is not a baseline.** Highest-priority fix,
and it is a lockfile regeneration (§10.1).

### 0.2 `research/NEXT.md` §8–§9 measure code that is in no branch of this repository

§8 states "Stage A and Stage B both landed" and reports gate results for a
stdenv-free unit builder. Against the actual tree at `3c61bb9`:

| `NEXT.md` §8 claims | Actual state |
|---|---|
| `mkUnit` is a plain `derivation` with `__structuredAttrs` | `templates/units.nix.in:169` — `pkgs.stdenv.mkDerivation`; `__structuredAttrs` is `""` on every unit derivation |
| builder is `nix/unit-builder.sh` | file does not exist |
| five fixture checks under `nix/tests/fixture/` | directory does not exist |
| all ten deletion-ledger rows deleted | all ten present: `dontStrip` (`render.rs:952`, `:1880`), `dontUnpack`/`dontConfigure` (`units.nix.in:170-171`), `postFixup` (`render.rs:970`), three `set +x` (`:1291`, `:1314`, `:3327`), `buildPhase`/`installPhase` as attributes (`:965-969`) |
| `checkedRoots` fixed by a `nix_list` emitter | `render_checked_roots` (`render.rs:3131`) still ends `.join(" ")`; no `nix_list` exists; all six join sites unchanged |

`git log --all` contains no such commit and there is no stash. So §8.1's headline —
per-derivation cost is "~110 ms of Nix floor", stdenv worth "~13 ms, about 10%" —
describes something not present here, and §8.3's "correctness: met" cannot be true
of this tree. §9's "264 unit derivations" contradicts both `BENCH_BASE.md` §2 (320)
and this profile (320, cross-checked in §3).

The §5 probe is *independent of this repository*, so it can adjudicate the overhead
question anyway — and it does not reproduce §8.1's stdenv number either.

### 0.3 The `checkedRoots` bug is live

`render_checked_roots` emits

```nix
checkedRoots = [ withPolicyChecks units."a" withPolicyChecks units."b" ];
```

— a `2N`-element list alternating lambdas and derivations, so **every policy check
on every root is silently dropped**. `research/comparison.md` §9 records this
correctly. `NEXT.md` §8.5 claims it fixed. It is not fixed.

---

## 1. Provenance

| | |
|---|---|
| Machine | Apple M5, 10 cores, 16 GiB RAM |
| OS | macOS (Darwin 25.5.0), `aarch64-darwin` |
| Nix | Determinate Nix 3.21.8 (Nix 2.34.8) |
| Nix settings | `max-jobs = 10`, `cores = 0`, `sandbox = false`, **`lazy-trees = true`** |
| nixpkgs | `624af665418d3c65d544145b4d34ad696439570e` (same as `BENCH_BASE.md`) |
| Toolchain | rustc 1.97.0 / cargo 1.97.0 |
| `nix-cargo-unit` | `3c61bb9` + regenerated `bench/nix-cargo-unit/flake.lock` |
| rust-analyzer | submodule `bec66814323579659ffd77c909b3d963af118ece` |

`lazy-trees = true` is **not** in `BENCH_BASE.md`'s settings table. It is on here.
It is a Determinate-only evaluation feature that `FASTER.md` Change 3 recommends
adopting; whether it was on for the baseline is unknown, which is a provenance gap
worth closing before the two documents' `plannerSource` and eval figures are
compared again.

**How the rebuild was forced.** Rather than `nix store delete` the 320 outputs, the
toolchain id is salted — `bench/nix-cargo-unit/flake.nix`'s `symlinkJoin` name gains a suffix from
`NCU_SALT` — which moves every unit hash and forces a full rebuild while leaving
the store intact. With the variable empty the derivation path is byte-identical
(verified: `lgxcx091…-rust-analyzer-workspace.drv` either way). Vendoring and
`plannerSource` do not depend on the toolchain and stayed warm, so §3's wall clock
is **the unit build plus plan and render**; §2 measures the other stages
separately.

---

## 2. Pipeline stages — not the bottleneck, confirmed

Each stage rebuilt by `.drv` path with `nix build --rebuild`, which re-runs the
builder without deleting anything. Three reps; every rebuild verified to exit 0.

| Stage | This profile (median) | `BENCH_BASE.md` §4 | Re-runs when |
|---|---:|---:|---|
| `plannerSource` | **9.89 s** | 8.9 s | a file is added/removed, or a manifest changes |
| `unitGraphJson` (cargo plan) | **0.51 s** | 0.50 s | `plannerSource` changes |
| `unitsNix` (render) | **0.655 s** | 0.76 s | any source edit |
| `vendorDir` | **2.35 s** | 0.95 s | `Cargo.lock` changes |
| `nix eval` of `workspace.outPath` | **1.12 s** warm | 1.0–1.2 s | |

`vendorDir` is 2.5× its documented figure; everything else reproduces. Worst case
the whole planning pipeline is ~13 s against a ~204 s build, and ~1 s on a
source-body edit. **`BENCH_BASE.md`'s conclusion stands: planning is not worth
optimizing**, and neither is the renderer (0.655 s to emit 2.6 MB of Nix).

This also disposes of one stated rationale for `FASTER.md` Change 9 (shrink input
closures for "faster eval"): evaluation is 1.12 s.

---

## 3. The cold build, attributed per derivation *and per phase*

One full rebuild, per-derivation start/stop from `nix build --log-format
internal-json`, stamped on arrival (internal-json carries no timestamps of its
own).

Two parsing rules matter, because getting either wrong produces nonsense:

- Nix **re-announces a queued build's `actBuild` activity under a fresh id** each
  time the goal is re-created. Taking min-start to max-stop across every activity
  naming a drv measures queue latency, not build time — by that method
  `unicode_ident` appears to take **39 s** and average parallelism comes out at
  **15×** on a 10-job build. An activity is a real build **iff it emitted a
  `resBuildLogLine`**.
- `resSetPhase` events within that activity give the **stdenv phase timeline**,
  which is what separates rustc from scaffolding.

```
wall clock                203.6 s
sum of build time         829.4 s
avg parallelism             4.07x   at max-jobs=10
derivations that built        321
```

| kind | count | seconds | share of sum |
|---|---:|---:|---:|
| compile unit | 251 | 712.9 | 86.0% |
| build-script run | 37 | 69.8 | 8.4% |
| build-script compile | 32 | 46.5 | 5.6% |
| workspace `buildEnv` | 1 | 0.2 | 0.0% |

Cross-check against `BENCH_BASE.md` §2: 251 compile + 32 build-script compile =
**283 `build`**; plus 37 `run-custom-build` = **320 units**. Both match the
baseline exactly. That is the main consistency check on this section, and it is why
`NEXT.md` §9's 264 cannot be reconciled with either document.

### 3.1 42% of a derivation's own time is not rustc

The measurement no prior document has, and the one that settles the
per-derivation-overhead argument. Summed over all 321 builds:

| phase | builds | seconds | share of sum | median |
|---|---:|---:|---:|---:|
| `buildPhase` (rustc) | 320 | **480.9** | **58.0%** | 723 ms |
| *pre-phase* (daemon setup + stdenv startup) | 321 | **201.9** | **24.3%** | 577 ms |
| `fixupPhase` | 308 | **105.4** | **12.7%** | 259 ms |
| `installPhase` | 311 | 26.1 | 3.2% | 0 ms |
| `updateAutotoolsGnuConfigScriptsPhase` | 320 | 11.9 | 1.4% | |
| `patchPhase` | 320 | 3.0 | 0.4% | |
| unaccounted | | 0.2 | 0.0% | |

`fixupPhase` burns 105 s on a graph that sets `dontStrip = true` everywhere and
produces mostly `.rlib` archives — 259 ms of median-case walking of an output tree
that needs none of it. `updateAutotoolsGnuConfigScriptsPhase` runs on all 320 units
and is pure waste for a rustc invocation.

**But read §4.1 before ranking any of this.**

### 3.2 The scaffolding does not scale with the input closure

The obvious mechanism — stdenv's `findInputs` walking `buildInputs` transitively —
is **not** what this is:

```
corr(direct buildInputs, pre-phase ms)  = -0.207
corr(total inputDrvs,    pre-phase ms)  = -0.255
```

| direct `buildInputs` | n | median pre-phase | median fixup | median `buildPhase` |
|---|---:|---:|---:|---:|
| 0–4 | 265 | 596 ms | 310 ms | 568 ms |
| 5–19 | 47 | 483 ms | 182 ms | 2195 ms |
| 20–49 | 6 | 286 ms | 160 ms | 7222 ms |
| 50–119 | 2 | 346 ms | 170 ms | 10133 ms |

The correlation is *negative*: units with more inputs show **less** startup cost.
The cause is not input count but **concurrency** — the 265 small units run during
the wide early phase where ten builds start at once and contend for the daemon,
while the few large units run during the serial drain with the machine to
themselves. This is why §5's probe varies `max-jobs` and not only derivation shape.

It also removes the other stated rationale for `FASTER.md` Change 9: more
`-L dependency=` flags and larger `.drv` inputs do not measurably cost build time
here.

### 3.3 Nearly half the wall clock has one build running

| concurrent builds | seconds | share of wall |
|---:|---:|---:|
| 0 | 5.9 | 2.9% |
| **1** | **88.1** | **43.3%** |
| 2–4 | 31.7 | 15.6% |
| 5–9 | 49.0 | 24.1% |
| 10 | 28.9 | 14.2% |

**46.2% of wall clock has ≤1 build running.** `BENCH_BASE.md` §9 described this
qualitatively; it is 94 s.

---

## 4. The critical path, measured under load

Longest weighted path through the real DAG (edges from each derivation's own
`inputs.drvs`), weighted by durations measured **in the loaded run**:

```
critical path   155.1 s over 22 derivations   = 76% of the 203.6 s wall clock
  on-path rustc (buildPhase)      138.1 s   (89% of the path)
  on-path Nix/stdenv scaffolding   17.0 s   (11% of the path, 772 ms per derivation)
```

| total | rustc | scaffold | unit |
|---:|---:|---:|---|
| 1.82s | 0.00s | 1.82s | `build-script-build` (proc-macro2) |
| 1.94s | 0.73s | 1.20s | `proc-macro2-build-script-output` |
| 1.26s | 0.43s | 0.83s | `proc_macro2` |
| 1.86s | 0.49s | 1.37s | `quote` |
| 4.77s | 4.11s | 0.66s | `syn` |
| 3.67s | 2.44s | 1.23s | `serde_derive` |
| 1.88s | 1.32s | 0.56s | `serde` |
| 1.91s | 0.54s | 1.36s | `triomphe` |
| **23.50s** | 22.77s | 0.74s | `intern` |
| 0.90s | 0.49s | 0.40s | `tt` |
| 1.03s | 0.42s | 0.61s | `cfg` |
| 3.68s | 2.74s | 0.94s | `base_db` |
| 7.37s | 6.83s | 0.54s | `hir_expand` |
| 13.57s | 13.03s | 0.54s | `hir_def` |
| **24.54s** | 24.01s | 0.53s | `hir_ty` |
| 6.41s | 5.98s | 0.43s | `hir` |
| 5.22s | 4.73s | 0.49s | `ide_db` |
| **20.48s** | 19.55s | 0.92s | `ide_assists` |
| 7.67s | 7.20s | 0.47s | `ide` |
| **19.00s** | 18.42s | 0.58s | `rust_analyzer` |
| 2.36s | 1.85s | 0.51s | `rust-analyzer` (bin) |
| 0.23s | 0.00s | 0.23s | `rust-analyzer-workspace` |

### 4.1 The one number that re-ranks everything

**Scaffolding is 42% of summed build time and 11% of the critical path.**

Only path time is wall clock. The other 331 s of scaffolding is charged against a
sum that has ~6 idle cores to absorb it. So removing stdenv from the unit path
entirely is worth **at most ~17 s of ~204 s (8%)** — and §5 shows most of that
772 ms per derivation is Nix's own floor rather than stdenv's, so the realistic
figure is about half.

`BENCH_BASE.md` §11 ranks per-derivation cost **first**, at "~56 s, ~27% of the
cold build, the clearest optimization target in the whole document". That conflates
summed overhead with wall clock. In *summed* terms the cost is far larger than §8
estimated (348 s, not 56 s); in the only terms that determine wall clock, it is far
smaller.

### 4.2 `BENCH_BASE.md`'s "unexplained ~95 s" is now fully accounted for

§11 item 3 lists "the unexplained ~95 s between critical path and wall clock" as
the third-ranked target. That gap was `211 − 115.6`, and **115.6 s was a path
summed from *solo* unit costs** — which §12 correctly flags as a floor. Measured
under load the path is **155.1 s**, so the real gap is 48.5 s; and the list
scheduler in §9 reproduces 191.4 s of the 203.6 s from dependency order and job
count alone. That leaves **12.2 s** genuinely unexplained, not 95 s.

There is no 95 s of mystery to go hunting for.

---

## 5. Per-derivation overhead — three arms, two parallelism levels

`BENCH_BASE.md` §8 measured one arm (stdenv) at one parallelism and reported
175 ms. `NEXT.md` §8.1 measured three arms at the same parallelism and reported
123.4 / 113.1 / 110.4 ms. Neither varied `max-jobs`, which is the axis that says
whether the cost is *serial* — and therefore whether more cores can ever absorb it.

N = 40 vs 160, marginal = Δt/ΔN, three reps, every arm's builder verified to have
actually run. **36 runs, 0 failures.**

| arm | max-jobs | reps (ms/derivation) | median |
|---|---:|---|---:|
| `minimal` — plain `derivation`, builder writes `$out` | 10 | 121.1 / 121.5 / 122.6 | **121.5** |
| `plain` — `derivation` + `__structuredAttrs` + static builder | 10 | 119.4 / 120.0 / 137.2 | **120.0** |
| `stdenv` — `mkDerivation` + `dontUnpack`/`dontConfigure`/`dontStrip` | 10 | 172.1 / 173.3 / 178.6 | **173.3** |
| `minimal` | 1 | 136.4 / 138.5 / 140.0 | **138.5** |
| `plain` | 1 | 136.7 / 140.8 / 141.9 | **140.8** |
| `stdenv` | 1 | 308.3 / 311.5 / 351.4 | **311.5** |

### 5.1 What this settles

**`BENCH_BASE.md`'s 175 ms reproduces exactly (173.3 ms). `NEXT.md` §8.1's 123.4 ms
does not.** The probe does not depend on `nix-cargo-unit` at all, so §0.2's tree
discrepancy cannot explain this one — it is simply an unreproducible measurement,
and it is the sole basis for §8.1's conclusion that "stdenv was worth ~13 ms, about
10% of the per-derivation cost". Measured here:

```
max-jobs=10   Nix floor 121.5 ms | plain  -1.5 ms | stdenv  +51.8 ms  (30% of its total)
max-jobs=1    Nix floor 138.5 ms | plain  +2.3 ms | stdenv +173.0 ms  (56% of its total)
```

Three readings, in order of importance:

1. **The Nix floor is ~121.5 ms and it is essentially serial.** Going from 10 jobs
   to 1 changes it by only **1.14×**; per-job CPU work would have gone up ~10×. It
   is daemon round-trips, build-directory setup, output registration and store
   bookkeeping — and **no change to the shape of a unit can touch it. Only fewer
   derivations can.** `NEXT.md` §1 asserted this on theoretical grounds; this is
   the direct evidence for it.
2. **`__structuredAttrs` plus a static builder is free** — `plain` measures 1.5 ms
   *below* the bare floor, i.e. within noise. `NEXT.md` §8.1's finding #3 ("~3 ms
   over the bare floor") reproduces cleanly. That part of the plan was right.
3. **stdenv costs ~52 ms per derivation at `max-jobs=10`, ~30% — not ~10%, not
   ~50%.** And unlike the floor it *is* absorbed by cores: 173 ms of serial work
   compresses to 52 ms of marginal wall clock at 10 jobs (1.80× ratio). So
   `FASTER.md` Change 2's "~2× per-derivation fixed cost reduction", sourced from a
   10k-trivial-build benchmark, over-promises here by roughly 2× — the measured
   ratio is **1.43×** (173.3 / 121.5).

### 5.2 Two independent methods agree

Extrapolated to 320 units at `max-jobs=10`:

| | marginal wall clock | share of 203.6 s |
|---|---:|---:|
| irreducible Nix floor (121.5 ms × 320) | **38.9 s** | 19% |
| stdenv's own marginal cost (51.8 ms × 320) | **16.6 s** | 8% |

The probe says removing stdenv is worth **16.6 s**. §4's phase timings, measured by
a completely different method on the real build, say on-path scaffolding is
**17.0 s**. Those agreeing to within 3% is the strongest single consistency check
in this document, and both say the same thing: **stdenv removal is an ~8%
wall-clock change.**

The floor is *already inside* the measured pre-phase of §3.1 — not additive to it.
Of the 38.9 s, only 22 × 121.5 ms ≈ **2.7 s** sits on the critical path; the rest
competes for job slots, which is where §4.2's residual goes.

---

## 6. Inside rustc — the layer nothing in this repo has looked at

`FASTER.md` §1 ends with "**What to measure first, in order:** `-Zself-profile` on
the tallest crates (where does rustc time go — frontend/codegen/LLVM)". That was
the right call and it was never executed. It is executed here.

Each unit's `buildPhase` is a generated bash script that assembles a `rustc_args`
array and ends in `env "${rustc_env[@]}" rustc "${rustc_args[@]}"`. Everything it
needs from the build environment is `$src` (plus `$NIX_BUILD_TOP` when the package
has a build script), so the exact invocation replays outside Nix against store
dependencies that are already present. All 11 critical-path crates, three ways:
full `--emit`, `--emit metadata` only, and full with `-Ztime-passes`.

### 6.1 Linking is 0.1% of compile time

Non-overlapping buckets only. `LLVM_passes` and `LLVM_thinlto` are summed across
worker threads and can exceed the backend's wall time, so they are reported as a
breakdown *inside* `finish_ongoing_codegen`, never added to it.

| unit | total | frontend | IR gen | LLVM backend | link | backend % |
|---|---:|---:|---:|---:|---:|---:|
| `hir_ty` | 17.92 | 6.24 | 2.17 | 9.48 | 0.03 | 53% |
| `rust_analyzer` | 17.02 | 3.77 | 2.02 | 11.19 | 0.03 | 66% |
| `ide_assists` | 9.64 | 2.49 | 1.12 | 6.03 | 0.01 | 63% |
| `hir_def` | 9.40 | 3.02 | 1.08 | 5.28 | 0.01 | 56% |
| `ide` | 6.62 | 1.80 | 0.94 | 3.87 | 0.01 | 58% |
| `intern` | 6.30 | 0.40 | 0.06 | 5.84 | 0.00 | **93%** |
| `hir` | 5.58 | 1.94 | 0.56 | 3.07 | 0.01 | 55% |
| `ide_db` | 4.55 | 1.30 | 0.55 | 2.70 | 0.01 | 59% |
| `hir_expand` | 3.61 | 0.82 | 0.45 | 2.33 | 0.00 | 65% |
| `syntax` | 2.57 | 1.01 | 0.25 | 1.30 | 0.01 | 51% |
| `base_db` | 1.43 | 0.37 | 0.21 | 0.84 | 0.00 | 59% |
| **sum** | **84.63** | **23.18** | **9.40** | **51.94** | **0.11** | **61%** |

```
frontend                          23.18 s   27%
  type_check_crate                 4.60 s
  MIR_borrow_checking              5.12 s
  generate_crate_metadata         10.60 s
IR generation (MIR -> LLVM IR)     9.40 s   11%
LLVM backend (wall)               51.94 s   61%
  LLVM_passes   (thread-summed)   26.72 s
  LLVM_thinlto  (thread-summed)   34.72 s
link                               0.11 s    0.1%
```

**`FASTER.md`'s linker change (Change 4) is dead** — not deprioritised. Its
magnitude claim comes from ripgrep *debug* builds on *Linux*, where "roughly half
the time is spent in the linker". This workload is release `aarch64-darwin`, and
231 of 320 units are `lib` targets producing `.rlib` archives that rustc writes
itself with no linker involved. Measured: **0.11 s of 84.63 s.** `NEXT.md` §9.4
demoted it by counting link *steps*; this measures the time and agrees.

### 6.2 The ThinLTO surprise, and what it does and does not mean

`-C lto` appears **nowhere** in any unit's argument vector, yet `LLVM_thinlto` is
the single largest pass (34.72 s thread-summed, 41% of backend). That is rustc's
implicit **local, intra-crate** ThinLTO across the 16 codegen units it defaults to
at `opt-level=3`.

Two consequences, pointing opposite ways:

- **It is not a `nix-cargo-unit` cost.** cargo pays it identically, so it explains
  no part of the 2.62× cold-build gap. `-C lto=off` and `-C codegen-units=N` are
  absolute-speed levers, not parity levers, and both change the produced binary's
  runtime performance — so neither is a free win and neither may be measured
  without a runtime benchmark beside it.
- **It does not block pipelining.** `FASTER.md` Change 1 risk (4) warns "LTO pulls
  codegen to link time and defeats the split for release; gate the split to non-LTO
  profiles." rust-analyzer's `[profile.release]` sets only `debug = 0`. Local
  ThinLTO happens *inside* each crate's own codegen and moves nothing to link time.
  **Release profile does not block the metadata/codegen split here** — a reader of
  that risk list would conclude the opposite.

### 6.3 Metadata is 16% of a compile

| unit | full | metadata | metadata share | dependents unblock earlier by |
|---|---:|---:|---:|---:|
| `hir_ty` | 18.07 | 3.54 | 20% | 80% |
| `rust_analyzer` | 16.72 | 2.14 | 13% | 87% |
| `hir_def` | 9.54 | 1.86 | 20% | 80% |
| `ide_assists` | 9.38 | 1.12 | 12% | 88% |
| `ide` | 6.95 | 0.92 | 13% | 87% |
| `intern` | 6.33 | 0.30 | **5%** | 95% |
| `hir` | 5.86 | 1.38 | 24% | 76% |
| `ide_db` | 4.64 | 0.87 | 19% | 81% |
| `hir_expand` | 3.40 | 0.49 | 14% | 86% |
| `syntax` | 3.03 | 0.91 | 30% | 70% |
| `base_db` | 1.34 | 0.26 | 19% | 81% |
| **total** | **85.27** | **13.80** | **16%** | **84%** |

These ratios reproduce `NEXT.md` §9.2 closely (`intern` 5%, `base_db` ~19%,
`hir_def` 20%), which is worth saying plainly: §9's *ratio* work looks sound even
though the tree it was taken on is not in this repository.

---

## 7. Contention — why solo numbers mislead

Validation that the phase timings track reality: the least-contended unit on the
path shows only 1.10× inflation over its standalone time.

| unit | loaded `buildPhase` | standalone | inflation |
|---|---:|---:|---:|
| `rust_analyzer` | 18.42 s | 16.72 s | 1.10× |
| `hir_ty` | 24.01 s | 18.07 s | 1.33× |
| `hir_def` | 13.03 s | 9.54 s | 1.37× |
| `ide_assists` | 19.55 s | 9.38 s | 2.08× |
| `intern` | 22.77 s | 6.33 s | **3.60×** |

`cores = 0` means each of up to ten concurrent rustc processes believes it owns all
ten cores. `BENCH_BASE.md` §9 tested `cores ∈ {0,1,2}`, found all within 3% on wall
clock, and concluded there is no win in scheduler config — correct, and a different
statement from "there is no contention". Contention does not change wall clock; it
changes how a *per-unit* number may be read.

`intern` looks like a 6 s crate solo and behaves like a 23 s crate in the build.
`BENCH_BASE.md` §5's whole table (median 0.73 s, sum 376.2 s) and the 115.6 s path
derived from it are solo figures; the loaded path is 34% longer.

---

## 8. Corrections ledger

| Claim | Source | Measured here |
|---|---|---|
| Per-derivation cost ~175 ms | `BENCH_BASE.md` §8 | **Reproduces** — 173.3 ms for the stdenv arm at `max-jobs=10` |
| That is ~56 s, ~27% of the cold build, "the clearest optimization target" | `BENCH_BASE.md` §8, §11 | Summed scaffolding is 348 s, but only **17.0 s is on the critical path (8%)**. Ranked #1 on a sum-vs-wall-clock conflation |
| ~95 s between path and wall clock is unexplained | `BENCH_BASE.md` §11 | Path under load is 155.1 s, not 115.6 s; a list scheduler explains all but **12.2 s** |
| Per-unit median 0.73 s, sum 376.2 s, path 115.6 s | `BENCH_BASE.md` §5 | Solo-measured; loaded path is **155.1 s**, and `intern` is 3.6× its solo cost under load |
| Planning pipeline is not the bottleneck | `BENCH_BASE.md` §4 | **Confirmed.** ≤13 s worst case, ~1 s on a body edit |
| Nix floor ~110 ms, stdenv ~123 ms, so stdenv is ~10% of cost | `NEXT.md` §8.1 | Floor **121.5 ms** (close); stdenv **173.3 ms**, so stdenv is **30%**. The 123 ms figure does not reproduce |
| Static builder + `__structuredAttrs` costs ~3 ms over the floor | `NEXT.md` §8.1 | **Reproduces** — measured at −1.5 ms, i.e. free |
| Stage A/B landed; stdenv gone from the unit path; `checkedRoots` fixed | `NEXT.md` §8 | **Not in the tree** (§0.2, §0.3) |
| 264 unit derivations | `NEXT.md` §9 | **320**, matching `BENCH_BASE.md` §2 exactly |
| Metadata is ~5–31% of a compile per crate | `NEXT.md` §9.2 | **Reproduces** (§6.3) |
| On-path derivation overhead is 2.5 s, "no longer worth spending anything on" | `NEXT.md` §9.4 | On-path scaffolding is **17.0 s**; the on-path Nix floor alone is 2.7 s. Understated ~7× |
| Pipelining would largely vanish on a 4-core box | `NEXT.md` §9.4 | **Confirmed and worse** — simulated at **0.90×**, a net regression (§9.2) |
| `mkDerivation` is ~2× a raw `derivation` | `FASTER.md` TL;DR, Change 2 | **1.43×** here at `max-jobs=10` |
| Linkers are "on your critical path constantly", large low-risk win | `FASTER.md` finding 5, Change 4 | **0.11 s of 84.63 s.** Dead |
| LTO defeats the split on release; gate to non-LTO | `FASTER.md` Change 1 risk 4 | No `-C lto` in any unit; the ThinLTO observed is intra-crate. **Does not block the split** |
| Shrink input closures for faster eval / fewer edges | `FASTER.md` Change 9 | Eval is 1.12 s; scaffolding *anti*-correlates with input count. No build-time case |
| Measure `-Zself-profile` on the tallest crates first | `FASTER.md` §1 | **Correct, and never done.** Doing it killed one ranked change and created another |

---

## 9. Simulating the split before building it

A greedy list scheduler over the measured DAG, **first validated against the run it
came from** — if it cannot reproduce that run's makespan from that run's graph, its
prediction for a different graph is worthless.

Pipelined graph: `meta_i` (frontend only) and `code_i` (full compile) both depend
on `meta_j` for each dependency *j* — **not** on `code_j`, because rustc only needs
a dependency's `.rmeta` to monomorphise and codegen against it; the `.rlib` is
needed at final link only. The root link needs every `code_i`. Each new derivation
carries a full measured scaffolding cost, and `code_i` redoes the frontend, so the
extra CPU is modelled rather than waved away. Per-crate metadata shares are the
measured ones from §6.3, defaulting to a deliberately conservative 25% elsewhere
(a higher share means less benefit, so the default cannot flatter the result).

### 9.1 At 10 cores: 1.38×

```
validation
  measured wall clock          203.6 s
  simulated, today's graph     191.4 s    (94% of measured)
  unmodelled overhead           12.2 s

prediction
  derivations       321  ->  572     (+251)
  total work      829.4s -> 1200.6s  (+45% CPU, frontend runs twice)
  work / 10 cores  82.9s ->  120.1s  (lower bound from cores)
  simulated wall  191.4s ->  138.7s  (1.38x)
  + the same unmodelled overhead:  ~151 s vs 204 s today
```

94% validation is good enough to trust the direction and roughly the magnitude.
**This is the strongest available evidence for `FASTER.md` Change 1** — and note it
already pays the +251 derivations' full scaffolding and Nix-floor cost.

### 9.2 At 4 cores: 0.90× — a regression

```
  work / 4 cores  207.4s ->  300.1s
  simulated wall  280.7s ->  311.7s   (0.90x)
```

`NEXT.md` §9.4's closing caveat is right, and it is worse than "the gain would
largely vanish": the +45% CPU makes it a **net loss**. Caveat on the caveat —
durations were measured at 10-way concurrency, so both arms are inflated equally
and the *ratio* is more trustworthy than the absolute; the 4-core arm is a
counterfactual, not a validated measurement.

**Change 1 is therefore not unconditionally good. It is a trade of CPU for latency
that pays only when cores are idle** — which on this machine they are, ~6 of 10 on
average.

---

## 10. What to do — re-ranked, with the empirical basis

### 10.1 Fix the harness (hours)

1. **Make the bench build**, and put something in CI that at minimum evaluates
   `#workspace` and runs `checks.smoke`, so §0.1 cannot recur silently.
2. **Fix `checkedRoots`** (`render.rs:3131`) behind a single `nix_list` emitter
   that parenthesises every element, plus an evaluation check asserting element
   *counts and types*. `nix-instantiate --parse` cannot see this bug — the output
   is syntactically valid.
3. **Reconcile or retract `NEXT.md` §8–§9.** They read as measurements and are
   cited as such by `comparison.md`. Either land the code they describe or mark the
   sections as a plan.

### 10.2 Metadata/codegen split — now the clear #1

Basis: 76% of wall clock is the critical path; 89% of the path is rustc; 84% of a
lib's rustc time is deferrable past the point a dependent needs it; simulation says
**1.38× at 10 cores** including all new derivation overhead. Release profile does
not block it (§6.2).

Build it **gated on available parallelism** (§9.2), and prototype on the five path
crates before all 320. The correctness risk to test first is `-Zshare-generics` /
cross-crate inlining needing the producer's rlib (`FASTER.md` Change 1 risk 2), and
`-C metadata` must be identical across both invocations.

### 10.3 The LLVM backend — a new candidate, unexamined until now

61% of rustc time, of which `LLVM_thinlto` is the largest single pass, with no
`-C lto` requested. `-C lto=off` and `-C codegen-units=N` are one flag each through
the existing `extraRustcArgs` / `packageRustcArgs` seams — the cheapest experiment
available relative to the size of the term.

**It is not a parity lever** and it trades the produced binary's runtime
performance, so it must be measured with a runtime benchmark beside it or it is a
false win. Measure it anyway: nothing else in the ranking has this ratio of size to
cost.

### 10.4 Fewer derivations, not cheaper ones

The Nix floor is 121.5 ms, serial, 38.9 s over 320 units. Only **count** touches
it. That makes `FASTER.md` Change 8 (coarsen the external-dependency tier) the
right shape — and it is in direct tension with §10.2, which adds 251 derivations.
Both should be measured against the same wall clock before either ships.

### 10.5 stdenv removal — do it, but not for speed

Worth **~8% of wall clock** by two independent methods (§5.2) — not the 27%
`BENCH_BASE.md` §11 claims, nor the 1.6% `NEXT.md` §8.1 concludes. `NEXT.md`'s own
§8.5 is the honest case for it (correctness, one escaping regime instead of three,
the deletion ledger) and that case needs no performance claim. The cheapest slice
is `fixupPhase` + `updateAutotoolsGnuConfigScriptsPhase`: **117 s of summed time**
doing nothing useful to an `.rlib`.

### 10.6 Dead

The linker change (`FASTER.md` Change 4): 0.11 s of 84.63 s.

---

## 11. The benchmarking policy this exercise implies

Nine rules, each with the specific error that motivates it.

1. **A benchmark that cannot be run is not a baseline.** `bench/` must build in CI.
   — §0.1.
2. **Every number needs a commit hash that contains the code measured.** — §0.2.
3. **Never rank by summed cost.** Report sum and critical path separately, always;
   a cost deserves wall-clock attention only in proportion to how much of it lands
   on the path. — 42% vs 11%, §4.1.
4. **Do not extrapolate from synthetic probes to the real graph.** The same probe
   method produced 56 s (`BENCH_BASE.md`) and 3.3 s (`NEXT.md`) for the same
   quantity — wrong in both directions. Instrument the real build; it is cheaper and
   it answers the actual question. Keep probes only for isolating a *floor*, and
   then run every arm. — §3.1, §5.
5. **Vary `max-jobs` and state whether a cost is serial.** A cost that does not
   shrink with parallelism cannot be absorbed by hardware and has an entirely
   different remedy. Neither prior document varied it. — §5.1.
6. **Never use solo per-unit timings for schedule reasoning.** 3.6× inflation under
   load; label every per-unit number with its regime. — §7.
7. **Simulate before implementing, and validate the simulator against the run it
   came from.** A 94% reproduction earns the right to predict; the residual is
   itself the interesting number. — §9.
8. **Instrument rustc, not only Nix.** 58% of summed derivation time is one
   `buildPhase`, and looking inside it killed one ranked change and created
   another. — §6.
9. **Verify that what you measured actually ran.** Every `--rebuild` checked for
   exit 0; every probe builder required to leave a marker. A plain `derivation` has
   no `PATH`, so an unqualified `mkdir` fails silently and the arm measures nothing
   — `NEXT.md` §8.1 records hitting exactly this, and this profile hit it twice
   more (the `plain` arm's `__structuredAttrs` outputs, and `$NIX_BUILD_TOP` in the
   rustc replay).

### Gaps this profile does not close

- **Everything is `aarch64-darwin`, `sandbox = false`, 10 cores.** A sandboxed Linux
  store would likely raise the Nix floor, making §10.4 more attractive and §10.2
  less. Untested, and it is the single largest hole.
- **`lazy-trees = true` here, unknown in the baseline** (§1). The one setting whose
  effect on `plannerSource` and eval is plausibly large is unpinned across the two
  documents.
- **No incremental profile.** `BENCH_BASE.md` §6 is the only incremental data and it
  is solo-timed. The project exists for incrementality; the phase-level harness
  should be pointed at a `stdx` edit next, and that is probably the most valuable
  single measurement still missing.
- **Content addressing / early cutoff still unmeasured**, and `BENCH_BASE.md` §12
  and `FASTER.md` finding 3 still contradict each other on it. The one-day
  determinism check (build twice, diff rmeta) remains unrun.
- **`n = 1` on the metadata/full split.** §6.3's ratios are single runs; the
  aggregate is stable but per-crate figures carry unquantified noise.
- **The §9 simulator ignores the daemon's serial resource**, which is exactly its
  12.2 s residual. A pipelined graph with 572 derivations would pay more of that,
  so 1.38× is an optimistic bound.
