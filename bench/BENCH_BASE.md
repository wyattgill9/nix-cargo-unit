# `BENCH_BASE.md` — baseline speed of building rust-analyzer with nix-cargo-unit

Baseline measurements taken **2026-07-28**, before any optimization work. Every
number below is wall clock on one machine, one workload: rust-analyzer's
workspace built `--profile release`, one Nix derivation per Cargo compilation
unit.

This file is the "before" column. It exists to be compared against.

---

## 1. Provenance

| | |
|---|---|
| Machine | Apple M5, 10 cores (10 physical / 10 logical), 16 GiB RAM |
| OS | macOS (Darwin 25.5.0), `aarch64-darwin` |
| Nix | Determinate Nix 3.21.8 (Nix 2.34.8) |
| Nix settings | `max-jobs = 10`, `cores = 0`, `sandbox = false` |
| nixpkgs | `624af665418d3c65d544145b4d34ad696439570e` |
| Toolchain | rustc 1.97.0 / cargo 1.97.0 (from nixpkgs, `rustc.unwrapped`) |
| `nix-cargo-unit` | `090e6c5` |
| rust-analyzer | submodule `bec66814323579659ffd77c909b3d963af118ece` |
| Bench config | `profile = "release"`, `policy = pureBuild`, `contentAddressed = false` |

Reproduce with:

```console
$ git submodule update --init bench/rust-analyzer
$ nix build "git+file://$PWD?submodules=1&dir=bench"
```

Correctness of the artifact under test: `checks.aarch64-darwin.smoke` passes
(2.4 s) — the linked binary reports `rust-analyzer 0.0.0` and parses to a
`SOURCE_FILE@` tree.

---

## 2. Graph shape

| Metric | Value |
|---|---|
| Compilation units | **320** (283 `build`, 37 `run-custom-build`) |
| By target kind | 231 `lib`, 69 `custom-build`, 16 `proc-macro`, 4 `bin` |
| Roots | **46** (42 libraries + 4 binaries) |
| Local workspace units | 55 of 320 |
| Vendored crates | 332 |
| Intra-unit dependency edges | 4046 |
| Max in-degree | 209 (`rust_analyzer[lib]`) |
| Longest dependency chain | 22 units |
| `units.nix` | 2.6 MB |
| `unit-graph.json` | 298 KB |

Binaries: `rust-analyzer`, `rust-analyzer-proc-macro-srv`, `ungrammar2json`,
`xtask`.

---

## 3. Headline matrix

Cold = zero of the 320 unit outputs in the store, pipeline stages cached.
All figures are wall clock, `max-jobs=10`.

| # | Scenario | Wall clock | Notes |
|---|---|---:|---|
| A | **Cold build, whole workspace** | **212.9 s** | repeat run 209.9 s → **~211 s ±1.5%** |
| B | Cold build, `--max-jobs 1` | 319.4 s | serial reference |
| C | No-op rebuild (everything cached) | **0.18 s** | 1.08 s on first invocation, then 0.18/0.18 |
| D | `nix eval` of `workspace.outPath` | 1.0–1.2 s | warm and cold eval-cache within noise of each other |
| E | Full pipeline + build from cold | ~214 s | A + plan + render (§4) |
| F | Smoke check | 2.4 s | `--version` + `parse` |

**Measured parallel speedup: 319.4 / 211 = 1.51×** on a 10-core machine.

---

## 4. Pipeline stage costs

Each stage was deleted from the store and rebuilt **by `.drv` path** (so no
evaluation could silently re-trigger the IFD chain behind the measurement), and
each rebuild was verified to actually run. Three runs each.

| Stage | Cold rebuild | Re-runs when |
|---|---:|---|
| `plannerSource` | **8.9 s** (8.96 / 8.74 / 8.95) | a file is added/removed, or a manifest changes |
| `unitGraphJson` (cargo plan) | **0.50 s** (0.502 / 0.490 / 0.513) | `plannerSource` changes |
| `unitsNix` (render) | **0.76 s** (0.776 / 0.748 / 0.758) | any source edit |
| plan + render together | 1.00 s | |
| `vendorDir` (linkFarm only) | 0.95 s | `Cargo.lock` changes |

**The planning/rendering pipeline is not the bottleneck** — it is ~1 s on a
source-body edit and under 10 s even when a manifest changes. 99.5% of a cold
build is compilation.

Two structural notes:

- `plannerSource` at 8.9 s is the single most expensive stage, and it is pure
  filesystem work (stubbing every non-manifest file in the tree). It is skipped
  entirely on body-only edits, which is what makes §6 cheap.
- `unitGraphJson`'s **content pins `plannerSource`**: the emitted JSON embeds
  the planner tree's store path in its local `pkg_id`s, so the planner source
  cannot be garbage-collected while the graph exists.

---

## 5. Where the time actually goes

Per-unit cost was measured by resetting the store and building all 320 units
**one at a time in topological order**, so each unit had the machine to itself
and its dependencies already present.

| Metric | Value |
|---|---:|
| Sum of all 320 solo builds | 376.2 s |
| ...less ~0.18 s/unit harness overhead | ~318 s (matches the 319.4 s serial run) |
| Median unit | **0.73 s** |
| Mean unit | 1.18 s |
| p90 | 1.39 s |
| Max | 25.18 s |

Distribution — the graph is overwhelmingly made of cheap units:

| Bucket | Units |
|---|---:|
| < 1 s | **248** |
| 1–5 s | 63 |
| 5–20 s | 8 |
| > 20 s | 1 |

The 18% most expensive units (57 of them) account for **50%** of total serial cost.

### Costliest units

| Unit | Solo build |
|---|---:|
| `hir_ty` | 25.18 s |
| `rust_analyzer` | 19.44 s |
| `ide_assists` | 12.89 s |
| `hir_def` | 12.64 s |
| `ide` | 8.20 s |
| `intern` | 7.25 s |
| `hir` | 6.85 s |
| `ide_completion` | 5.32 s |
| `ide_db` | 5.27 s |
| `protobuf` | 4.42 s |
| `project_model` | 4.25 s |
| `ide_diagnostics` | 4.20 s |

### Critical path

Weighted longest path through the unit DAG, using the solo costs above:

**115.6 s across 21 units.**

```
build-script-build(proc-macro2)  0.63    hir_expand    4.00
proc-macro2 build-script-run     1.14    hir_def      12.64
proc_macro2                      0.66    hir_ty       25.18
quote                            0.62    hir           6.85
syn                              1.64    ide_db        5.27
serde_derive                     1.31    ide_assists  12.89
serde                            1.02    ide           8.20
triomphe                         0.58    rust_analyzer 19.44
intern                           7.25    rust-analyzer 2.46
tt                               0.98
cfg                              0.97
base_db                          1.90
```

| | |
|---|---:|
| Total work (serial) | 376.2 s |
| Critical path | 115.6 s |
| **Theoretical max speedup** | **3.25×** |
| Measured speedup | 1.51× |
| Cold wall clock | ~211 s |
| Critical path as share of wall clock | 55% |

So ~95 s of the ~211 s cold build is neither critical path nor useful
parallelism. That gap is the headroom.

---

## 6. Incremental rebuilds vs cargo

One comment appended to a crate's `lib.rs`, then the whole workspace rebuilt.
"Units" is how many of the 320 changed identity and had to be rebuilt — measured,
not estimated.

| Edited crate | Units rebuilt | nix-cargo-unit | cargo | Ratio |
|---|---:|---:|---:|---:|
| `rust-analyzer` (leafmost) | 4 | 24.5 s | 14.5 s | 1.69× |
| `ide` | 3 | 30.1 s | 18.3 s | 1.65× |
| `hir-ty` (mid) | 11 | 91.0 s | 50.6 s | 1.80× |
| `syntax` (deep) | 26 | 122.9 s | 63.2 s | 1.94× |
| `stdx` (deepest, 30 rdeps) | 31 | 127.3 s | 65.1 s | 1.96× |

The incremental story is dominated by **fan-out, not by unit count**: a `stdx`
edit rebuilds only 31 of 320 units (9.7%) but costs 127 s — 60% of a full cold
build — because those 31 units *are* the critical chain.

Confirmed, as `bench/README.md` claims: a source-body edit leaves
`plannerSource` byte-identical and moves only `unitsNix`, so the whole-workspace
cargo resolve is skipped and only the ~0.76 s render IFD re-runs.

---

## 7. Reference baseline: plain cargo

Same toolchain, same `--profile release`, same source tree, deps pre-fetched
(fetch excluded from timings), `--offline`.

| Scenario | cargo | nix-cargo-unit | Ratio |
|---|---:|---:|---:|
| Cold `build --release --workspace` | **81.4 s** | 212.9 s | **2.62×** |
| No-op rebuild | 0.26 s | **0.18 s** | **0.69×** |

cargo emitted 234 `Compiling` lines (packages) against nix-cargo-unit's 320
units — the same work, counted differently (cargo folds a package's build
script and lib into one line). `target/` came to 911 MB.

nix-cargo-unit is **2.6× slower than cargo on a cold build** and faster on a
no-op. The cold-build gap is the headline number to attack.

Two structural reasons cargo wins the cold case, neither of which is incidental:

1. **No pipelining.** cargo starts a dependent's compilation as soon as its
   dependency emits metadata (`--emit=metadata`), overlapping the two. A Nix
   derivation is atomic — a dependent cannot start until its dependency's
   derivation has fully completed and been registered. On a 21-unit critical
   chain this compounds.
2. **Per-derivation fixed cost** (§8), which cargo simply does not pay.

---

## 8. Overhead accounting

Control experiment: N trivial `stdenv.mkDerivation`s built under the same
`max-jobs=10`, N = 20 → 4.00 s, N = 80 → 14.51 s.

| | |
|---|---:|
| Marginal wall-clock cost per derivation | **~175 ms** |
| Fixed CLI + eval cost | ~495 ms |
| Extrapolated to 320 units | **~56 s** |
| Share of the ~211 s cold build | **~27%** |

Roughly a quarter of the cold build is Nix derivation machinery — sandbox setup,
stdenv bash startup, phase dispatch, output registration — not rustc. With a
median unit of 0.73 s, **the median unit spends more time in Nix scaffolding
than in compilation.** This is the clearest optimization target in the whole
document.

Treat 56 s as a lower bound: the probes are trivial derivations with tiny input
closures, while real units have up to 209 inputs to register.

---

## 9. Scheduler sensitivity

Four cold builds under different `(max-jobs, cores)` pairs:

| max-jobs | cores | Wall clock |
|---:|---:|---:|
| 10 | 1 | 204.7 s |
| 10 | 2 | 206.2 s |
| 5 | 2 | 210.3 s |
| 10 | 0 (default, = all 10) | 209.9 s |

**All within 3%.** The initial hypothesis — that `cores=0` lets 10 concurrent
rustc processes oversubscribe the machine 10× — is *not* supported: constraining
each builder to 1 or 2 cores changes nothing meaningful. There is no free win in
the scheduler config, and the 1.51× parallel speedup is not a tuning problem.

The real limiter is the shape of the graph: the tail of a cold build drains
through a narrow serial chain. Empirically, 309 of 320 units complete in the
first ~126 s; the remaining 11 (`hir_ty → hir → ide_db → ide_* → ide →
rust_analyzer → rust-analyzer`) take the other ~85 s with the machine mostly
idle.

---

## 10. Artifact sizes

| Artifact | Size |
|---|---:|
| `#rust-analyzer` closure | **91.6 MiB over 2 store paths** (itself + `libiconv`) |
| `#rust-analyzer` own NAR | 47.9 MiB (`bin/rust-analyzer` is 50 MB on disk) |
| `#workspace` closure | 592.6 MiB over 91 paths |
| All 320 unit outputs (sum of NAR) | 989.0 MiB |
| cargo `target/` (for comparison) | 911 MB |

No source tree or toolchain derivation is retained in the binary's runtime
closure, which is what the per-unit `--remap-path-prefix` is for.

---

## 11. Summary — where to optimize

Ranked by measured headroom:

1. **Per-derivation fixed cost (~56 s, ~27% of cold build).** 248 of 320 units
   build in under a second; each pays ~175 ms of Nix scaffolding regardless.
   Cutting this is the largest single win available and it needs no change to
   the graph.
2. **The 21-unit critical path (115.6 s, 55% of wall clock).** No amount of
   parallelism goes below this. It only moves by making `hir_ty` (25 s),
   `rust_analyzer` (19 s), `ide_assists` (13 s) and `hir_def` (13 s) cheaper —
   or by breaking the atomicity of a derivation so dependents can start on
   metadata rather than a finished rlib.
3. **The unexplained ~95 s** between critical path and wall clock. Not scheduler
   configuration (§9). Worth attributing precisely before optimizing blindly.
4. **`plannerSource` at 8.9 s** — only bites on manifest/file-set changes, but
   it is pure filesystem work and should be much cheaper.

Nothing here suggests the *planning* pipeline needs work: plan + render is 1 s
against a 211 s build.

---

## 12. Methodology and caveats

- Wall clock via epoch-millisecond timestamps around each command; no shell
  builtins involved in the measured region.
- "Cold" means the 320 unit outputs and the workspace `buildEnv` were deleted
  with `nix store delete` and verified absent (`0/320 present`) before each run.
  The toolchain and the 332 vendored crate tarballs were left in the store, so
  **network fetch time is excluded** from every figure.
- Building `#rustToolchain` from an almost-empty store took 117.9 s, dominated
  by substituting nixpkgs from `cache.nixos.org`. Excluded — it measures the CDN.
- Per-unit costs in §5 include ~0.18 s of `nix build` CLI overhead each; the
  net sum (~318 s) agrees with the independently measured serial run (319.4 s)
  to within 0.5%, which is the main consistency check on this document.
- Critical path in §5 is computed from *solo* unit costs. Under a loaded machine
  those units run slower, so 115.6 s is a floor, not a prediction.
- Repeatability: the only scenario run twice end-to-end (cold build) gave
  212.9 s and 209.9 s — ~1.5% spread. Single-run figures should be read with
  that much noise around them.
- `sandbox = false` (the macOS default here). A sandboxed store would likely
  raise the per-derivation overhead in §8.
- `contentAddressed = false`, so **early cutoff is not in play**. Turning it on
  would change the incremental numbers in §6 substantially and is the obvious
  next experiment.
