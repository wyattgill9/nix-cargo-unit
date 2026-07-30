# `NEXT.md` — what the benchmarks say, and what to do next

Written **2026-07-29** against `de0ffac`. Sources: `bench/BENCH_BASE.md` (baseline,
2026-07-28), `bench/PROFILE.md` (deep profile, 2026-07-29), `bench/tools/` (the
harness), and the tree itself.

This file supersedes the deleted `research/NEXT.md` and `research/FASTER.md`
(removed in `de0ffac` as outdated). Where those documents are cited below it is
only through `bench/PROFILE.md`'s corrections ledger, which is the record of why
they were retracted.

## TL;DR

- **The two measurement documents disagree, and `PROFILE.md` wins.** It measures
  the real 320-unit build phase by phase instead of extrapolating from synthetic
  probes, and that one methodological change re-ranks the entire optimization
  list, kills two proposed changes outright, and creates a new one nobody had
  looked at.
- **`BENCH_BASE.md`'s #1 target is really #4.** Per-derivation overhead is 42% of
  *summed* build time but **11% of the critical path** — worth ~8% of wall clock,
  not the claimed 27%. Ranking by summed cost on a build with ~6 idle cores is a
  category error.
- **The metadata/codegen split is the clear #1**, on a complete chain of evidence:
  76% of wall clock is the critical path, 89% of the path is rustc, 84% of a lib's
  rustc time is deferrable past the point a dependent needs it, and a validated
  simulator predicts **1.38× at 10 cores** including all new derivation overhead.
  It is **not unconditionally good** — at 4 cores the same simulator gives 0.90×,
  a net regression.
- **A new #2 appeared the moment anyone ran `-Zself-profile`:** 61% of rustc time
  is the LLVM backend, and its largest single pass is ThinLTO that **nobody
  requested**.
- **The `checkedRoots` bug is still live at `de0ffac`.** Every policy check on
  every root is silently dropped. Fix this before trusting any gate result.

---

## 1. What the benchmark measures

rust-analyzer's workspace, `--profile release`, one Nix derivation per Cargo
compilation unit. Apple M5 / 10 cores / 16 GiB, `aarch64-darwin`, `max-jobs=10`,
`cores=0`, `sandbox=false`, rustc 1.97.0, submodule `bec66814`.

Graph shape — both documents agree exactly, which is the main cross-consistency
check between them:

| | |
|---|---:|
| Compilation units | **320** (283 `build` + 37 `run-custom-build`) |
| By target kind | 231 `lib`, 69 `custom-build`, 16 `proc-macro`, 4 `bin` |
| Roots | 46 (42 libraries + 4 binaries) |
| Dependency edges | 4046, max in-degree 209 (`rust_analyzer[lib]`) |
| Longest chain | 22 units |
| `units.nix` | 2.6 MB, rendered in 0.65 s |

### 1.1 Standings against cargo

| Scenario | cargo | nix-cargo-unit | Ratio |
|---|---:|---:|---:|
| Cold `build --release --workspace` | 81.4 s | **203.6–212.9 s** | **2.6× slower** |
| No-op rebuild | 0.26 s | **0.18 s** | **0.69× — faster** |
| Edit `rust-analyzer` (leafmost, 4 units) | 14.5 s | 24.5 s | 1.69× |
| Edit `ide` (3 units) | 18.3 s | 30.1 s | 1.65× |
| Edit `hir-ty` (mid, 11 units) | 50.6 s | 91.0 s | 1.80× |
| Edit `syntax` (deep, 26 units) | 63.2 s | 122.9 s | 1.94× |
| Edit `stdx` (deepest, 31 units) | 65.1 s | 127.3 s | 1.96× |

The project's thesis — granular derivations buy incrementality — is half
delivered. It wins the no-op case outright, but on real incremental edits it is
consistently **1.65–1.96× slower than plain cargo**, and the ratio worsens with
depth. A `stdx` edit rebuilds 9.7% of the units and costs 60% of a full cold
build, because those 31 units *are* the critical chain. **Incremental cost tracks
fan-out, not unit count** — granularity does not help when the edit is at the
bottom of the graph.

### 1.2 The planning pipeline is not the bottleneck

Confirmed twice, independently. Worst case the whole pipeline is ~13 s against a
~204 s build; on a source-body edit it is ~1 s, because `plannerSource` stays
byte-identical and only the render IFD re-runs.

| Stage | `PROFILE.md` | `BENCH_BASE.md` |
|---|---:|---:|
| `plannerSource` | 9.89 s | 8.9 s |
| `unitGraphJson` (cargo plan) | 0.51 s | 0.50 s |
| `unitsNix` (render) | 0.655 s | 0.76 s |
| `vendorDir` | 2.35 s | 0.95 s |
| `nix eval` of `workspace.outPath` | 1.12 s warm | 1.0–1.2 s |

Nothing here needs work. `vendorDir`'s 2.5× drift between the two runs is
unexplained and worth a glance, but 1.4 s is not a target.

---

## 2. The finding that re-ranks everything: sum ≠ wall clock

`BENCH_BASE.md` §11 ranks per-derivation Nix overhead **first**, at "~56 s, ~27%
of the cold build, the clearest optimization target in the whole document."

Measured on the real build, per stdenv phase, summed over all 321 builds:

| phase | seconds | share of *sum* | median |
|---|---:|---:|---:|
| `buildPhase` (rustc) | 480.9 | 58.0% | 723 ms |
| pre-phase (daemon setup + stdenv startup) | 201.9 | 24.3% | 577 ms |
| `fixupPhase` | 105.4 | 12.7% | 259 ms |
| `installPhase` | 26.1 | 3.2% | 0 ms |
| `updateAutotoolsGnuConfigScriptsPhase` | 11.9 | 1.4% | |
| `patchPhase` | 3.0 | 0.4% | |

Scaffolding is **42% of summed build time**. But the sum is 829.4 s against a
203.6 s wall clock — average parallelism is 4.07× on a 10-job build, so roughly
six cores sit idle and absorb it. On the critical path (155.1 s over 22
derivations, **76% of wall clock**):

```
on-path rustc (buildPhase)      138.1 s   89% of the path
on-path Nix/stdenv scaffolding   17.0 s   11% of the path (772 ms per derivation)
```

**Removing stdenv from the unit path entirely is worth at most ~17 s of ~204 s —
about 8%.** Two entirely different methods agree to within 3%: the phase timings
say 17.0 s, and the synthetic probe extrapolates stdenv's marginal cost at
51.8 ms × 320 = 16.6 s. That agreement is the strongest single consistency check
in the profile.

Only path time is wall clock. A cost deserves attention in proportion to how much
of it lands on the path — which is `PROFILE.md` §11's rule 3, and it exists
because of this exact error.

---

## 3. The work, re-ranked

### 3.1 Fix the harness first (hours)

1. **`checkedRoots` is broken and it is live.** `render_checked_roots`
   (`src/render.rs:3131`) still ends `.join(" ")`, and
   `templates/units.nix.in:856` wraps the result in `[ ... ]`, producing a
   `2N`-element list alternating `withPolicyChecks` lambdas and derivations:

   ```nix
   checkedRoots = [ withPolicyChecks units."a" withPolicyChecks units."b" ];
   ```

   **Every policy check on every root is silently dropped.** `nix-instantiate
   --parse` cannot see this — the output is syntactically valid. Fix behind a
   single `nix_list` emitter that parenthesises every element (there are six join
   sites), plus an evaluation check asserting element *counts and types*.

2. **Put the bench in CI.** `bench/flake.lock` was stale enough that the benchmark
   could not be evaluated at all until it was regenerated in `d2ef272`; a baseline
   that cannot be run is not a baseline. At minimum, evaluate `#workspace` and run
   `checks.smoke`.

3. **`research/comparison.md` cites the superseded figure.** Its TL;DR carries
   "~56 s, ~27% of a 211 s cold build" and "the median unit spends more time in
   Nix scaffolding than in rustc" as measured fact. Both are the sum-vs-wall-clock
   conflation of §2 and should be restated as ~8% of wall clock.

### 3.2 #1 — the metadata/codegen split

The evidence chain is unusually complete:

- 76% of wall clock is the critical path
- 89% of the path is rustc's `buildPhase`
- `--emit metadata` is **16% of a full compile** (5% for `intern`, 30% for
  `syntax`), so **84% of a lib's rustc time is deferrable** past the moment a
  dependent needs it
- a greedy list scheduler over the measured DAG, **validated to 94% against the
  run it came from** (191.4 s simulated vs 203.6 s measured), predicts
  **1.38× at 10 cores** — already paying the full Nix floor and scaffolding for
  +251 new derivations and modelling the frontend running twice (+45% CPU)

| unit | full | metadata | share | dependents unblock earlier by |
|---|---:|---:|---:|---:|
| `hir_ty` | 18.07 | 3.54 | 20% | 80% |
| `rust_analyzer` | 16.72 | 2.14 | 13% | 87% |
| `hir_def` | 9.54 | 1.86 | 20% | 80% |
| `ide_assists` | 9.38 | 1.12 | 12% | 88% |
| `intern` | 6.33 | 0.30 | **5%** | 95% |
| `syntax` | 3.03 | 0.91 | 30% | 70% |
| **total** | **85.27** | **13.80** | **16%** | **84%** |

This is the thing Nix structurally cannot do today. A derivation is atomic, so a
dependent cannot start until its dependency's `.rlib` is registered, while cargo
starts as soon as the dependency emits metadata. On a 22-unit critical chain that
compounds, and it is the primary structural reason cargo wins the cold case.

**Conditions on shipping it:**

- **Gate on available parallelism.** At 4 cores the same simulator gives
  **0.90× — a net regression**, because +45% CPU stops being free when no cores
  are idle. This is a trade of CPU for latency that pays only when cores sit idle,
  which on this machine they do, ~6 of 10 on average.
- **Prototype on the ~5 path crates** before all 320.
- **Correctness risk to test first:** `-Zshare-generics` / cross-crate inlining
  needing the producer's rlib, and `-C metadata` must be byte-identical across
  both invocations.
- 1.38× is an **optimistic bound**: the simulator ignores the daemon's serial
  resource, which is exactly its 12.2 s residual, and a 572-derivation graph pays
  more of that.

### 3.3 #2 — the LLVM backend (new, unexamined until the profile)

Nothing in this repo had ever run `-Zself-profile`. On the 11 critical-path
crates:

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

61% of rustc time is the backend. `-C lto=off` and `-C codegen-units=N` are one
flag each through the existing `extraRustcArgs` / `packageRustcArgs` seams — the
cheapest experiment available relative to the size of the term.

**It is not a parity lever.** cargo pays the same cost, so it explains no part of
the 2.6× gap, and both flags change the produced binary's runtime performance. It
must be measured with a runtime benchmark beside it or it is a false win. Measure
it anyway: nothing else in the ranking has this ratio of size to cost.

### 3.4 #3 — fewer derivations, not cheaper ones

The probe settles the shape of the tax. Three arms × two parallelism levels ×
3 reps, N = 40 vs 160, marginal = Δt/ΔN (36 runs, 0 failures):

| arm | `max-jobs=10` | `max-jobs=1` |
|---|---:|---:|
| `minimal` — plain `derivation` | **121.5 ms** | 138.5 ms |
| `plain` — `+ __structuredAttrs`, static builder | 120.0 ms | 140.8 ms |
| `stdenv` — `mkDerivation` | **173.3 ms** | 311.5 ms |

**The Nix floor is ~121.5 ms and it is essentially serial** — 10 jobs to 1 moves
it by only 1.14×, where per-job CPU work would have risen ~10×. It is daemon
round-trips, build-directory setup, output registration and store bookkeeping.
**No change to a unit's shape can touch it. Only fewer derivations can.** That is
38.9 s over 320 units (19% of wall clock), of which only ~2.7 s sits on the path.

Two corollaries:

- `__structuredAttrs` plus a static builder is **free** — measured 1.5 ms *below*
  the bare floor, i.e. within noise. A rare unqualified green light.
- Coarsening the external-dependency tier is the right shape, and it is in
  **direct tension with §3.2**, which adds 251 derivations. Both must be measured
  against the same wall clock before either ships.

### 3.5 #4 — stdenv removal: do it, but not for speed

Worth ~8% of wall clock by two independent methods (§2) — not 27%. The honest
case is correctness: one escaping regime instead of three, and a deletion ledger
of ten workarounds (`dontStrip`, `dontUnpack`/`dontConfigure`, `postFixup`, three
`set +x`, `buildPhase`/`installPhase` as attributes). That case needs no
performance claim.

The cheapest slice is `fixupPhase` + `updateAutotoolsGnuConfigScriptsPhase`:
**117 s of summed time doing nothing useful.** The graph sets `dontStrip = true`
on every unit and produces mostly `.rlib` archives, yet fixup still walks the
output tree for a median 259 ms per unit, and the autotools config-script phase
runs on all 320 units for what is a single `rustc` invocation.

### 3.6 Dead

**The linker change.** Its magnitude claim came from ripgrep *debug* builds on
*Linux*, where roughly half the time is in the linker. This workload is release
`aarch64-darwin`, and 231 of 320 units are `lib` targets producing `.rlib`
archives that rustc writes itself with no linker involved. Measured:
**0.11 s of 84.63 s.**

**Shrinking input closures for faster eval / fewer edges.** Eval is 1.12 s, and
scaffolding *anti*-correlates with input count (§4). Neither stated rationale
survives.

---

## 4. What was unexpected

**ThinLTO nobody asked for.** `-C lto` appears **nowhere** in any unit's argument
vector, yet `LLVM_thinlto` is the single largest pass at 34.72 s thread-summed —
41% of the backend. It is rustc's implicit *local, intra-crate* ThinLTO across the
16 codegen units it defaults to at `opt-level=3`. This cuts two ways, both
surprising: it explains **none** of the 2.6× cargo gap, and — because it happens
inside each crate's own codegen rather than at link time — **the release profile
does not block the metadata/codegen split**, which is the opposite of what the
retracted risk analysis concluded.

**Scaffolding anti-correlates with input closure size.** The obvious mechanism was
stdenv's `findInputs` walking `buildInputs` transitively. Measured:

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

The cause is not input count but **concurrency regime**: the 265 small units run
during the wide early phase where ten builds start at once and contend for the
daemon, while the few large units run during the serial drain with the machine to
themselves.

**Solo timings lie by up to 3.6×.**

| unit | loaded `buildPhase` | standalone | inflation |
|---|---:|---:|---:|
| `rust_analyzer` | 18.42 s | 16.72 s | 1.10× |
| `hir_ty` | 24.01 s | 18.07 s | 1.33× |
| `ide_assists` | 19.55 s | 9.38 s | 2.08× |
| `intern` | 22.77 s | 6.33 s | **3.60×** |

`intern` looks like a 6 s crate solo and behaves like a 23 s crate in the build.
This invalidates `BENCH_BASE.md` §5's whole table (median 0.73 s, sum 376.2 s) *as
a basis for schedule reasoning*, and with it the 115.6 s critical path derived
from it — measured under load the path is **155.1 s**, 34% longer.

**The "unexplained ~95 s" never existed.** `BENCH_BASE.md` ranked it third and
called for investigation. It was `211 − 115.6`, i.e. an artifact of the solo-cost
path above. With the loaded path at 155.1 s and the validated list scheduler
reproducing 191.4 s from dependency order and job count alone, the genuinely
unexplained residual is **12.2 s** — almost certainly the daemon's serial
resource, which the simulator does not model.

**The scheduler is insensitive, yet the machine is idle half the time.**
`(max-jobs, cores)` across `{10,1}`, `{10,2}`, `{5,2}`, `{10,0}` all land within
3% — there is no tuning win. And yet:

| concurrent builds | seconds | share of wall |
|---:|---:|---:|
| 0 | 5.9 | 2.9% |
| **1** | **88.1** | **43.3%** |
| 2–4 | 31.7 | 15.6% |
| 5–9 | 49.0 | 24.1% |
| 10 | 28.9 | 14.2% |

**46.2% of wall clock has ≤1 build running.** Both facts hold because the limiter
is graph shape, not configuration: 309 of 320 units finish in the first ~126 s and
the last 11 drain through `hir_ty → hir → ide_db → ide_* → ide → rust_analyzer`
over the remaining ~85 s.

**A prior document measured code that exists in no branch.** `PROFILE.md` §0.2
establishes that the retracted `NEXT.md` §8–§9 reported gate results for a
stdenv-free unit builder that is not in this repository's history: `mkUnit` is
still `pkgs.stdenv.mkDerivation` (`templates/units.nix.in:169`),
`nix/unit-builder.sh` does not exist, all ten deletion-ledger rows are present,
and it reported 264 unit derivations where both real measurements say 320. Its
per-derivation figure (123.4 ms) does not reproduce even though the probe is
independent of this repo. That is what motivates the benchmarking policy below —
every rule is attached to an error that actually happened here.

---

## 5. The benchmarking policy this implies

From `bench/PROFILE.md` §11, restated because it governs every future measurement
in this repository:

1. A benchmark that cannot be run is not a baseline. `bench/` must build in CI.
2. Every number needs a commit hash that contains the code measured.
3. **Never rank by summed cost.** Report sum and critical path separately, always.
4. Do not extrapolate from synthetic probes to the real graph. Instrument the real
   build; keep probes only for isolating a *floor*, and then run every arm.
5. Vary `max-jobs` and state whether a cost is serial. A cost that does not shrink
   with parallelism cannot be absorbed by hardware and has a different remedy.
6. Never use solo per-unit timings for schedule reasoning. Label every per-unit
   number with its regime.
7. Simulate before implementing, and validate the simulator against the run it
   came from. The residual is itself the interesting number.
8. Instrument rustc, not only Nix. Looking inside `buildPhase` killed one ranked
   change and created another.
9. Verify that what you measured actually ran. A plain `derivation` has no `PATH`,
   so an unqualified `mkdir` fails silently and the arm measures nothing.

---

## 6. Gaps — what is still unmeasured

- **Everything is `aarch64-darwin`, `sandbox = false`, 10 cores.** A sandboxed
  Linux store would likely raise the 121.5 ms Nix floor, which makes §3.4 *more*
  attractive and §3.2 *less*. The two top-ranked items move in opposite directions
  under the single largest hole in the data.
- **No incremental profile.** The project exists for incrementality, and the only
  incremental data (`BENCH_BASE.md` §6) is solo-timed — which §4 just proved is
  worth up to 3.6× of error. Pointing `bench/tools/`'s phase-level harness at a
  `stdx` edit is the most valuable single measurement still missing.
- **Content addressing / early cutoff is completely unmeasured.** The bench runs
  `contentAddressed = false`, so early cutoff — arguably the strongest structural
  argument for one-derivation-per-unit — has never been benchmarked at all. The
  one-day determinism check (build twice, diff rmeta) remains unrun.
- **`lazy-trees = true` in the profile, unknown in the baseline.** The one setting
  whose effect on `plannerSource` and eval is plausibly large is unpinned across
  the two documents.
- **`n = 1` on the metadata/full split.** The aggregate is stable; per-crate
  figures carry unquantified noise.
