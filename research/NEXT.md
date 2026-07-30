# NEXT — Cut the per-derivation tax

The next step, specified as the end state it should arrive at rather than as a diff from
today's shape. Sources: `bench/BENCH_BASE.md` (measured, 2026-07-28), `research/FASTER.md`
(Changes 2 and 10), `research/comparison.md` §8–9.

## Intended end state

A compilation unit is a **plain derivation running one fixed builder script over a JSON
argument vector** — no stdenv, no phase dispatch, no fixup, and none of the dozen workarounds
that exist only to survive stdenv. The emitted Nix is **evaluated in CI**, so output *shape*
is proven by evaluation and the emitter's Rust tests assert only on content.

There is no `useStdenv` flag, no dual builder path, and no compatibility shim. When this lands,
`pkgs.stdenv.mkDerivation` does not appear in the unit path at all.

---

## 1. Why this step

Measured headroom: **~175 ms marginal wall clock per derivation** (probes: N=20 → 4.00 s,
N=80 → 14.51 s at `max-jobs=10`) × 320 units ≈ **56 s of a 211 s cold build, ~27%**. With a
median unit at 0.73 s and 248 of 320 units under 1 s, the median unit spends more time in Nix
scaffolding than in rustc.

Two properties make this the right next move rather than the biggest one:

**It is serial.** 175 ms is the marginal cost *at the parallelism the real build already uses*.
If the overhead were per-job CPU work, marginal wall clock at `max-jobs=10` would be a tenth of
the per-derivation cost. It isn't, so the tax is bottlenecked on something serial — daemon
round-trips, store registration, `setup.sh` sourcing — and **more cores will never absorb it**.
This also explains most of the ~95 s that `BENCH_BASE.md` §11 lists as unattributed: items #1
and #3 in that ranking are one phenomenon, not two.

**It gates the pipelining bet.** Splitting each lib unit into metadata + codegen derivations
(`FASTER.md` Change 1) is the only route to the incremental story this project exists for — but
it adds ~230 derivations, i.e. **+40 s of unabsorbable wall clock at today's 175 ms**. Cargo's
own pipelining evaluation showed ~1.2× on release builds; scaled to a chain that is 55% of wall
clock here, the plausible gain is 20–50 s. The net is currently **indeterminate in sign**, and
per-derivation cost is the term that decides it. Doing Change 1 first risks measuring a wash and
concluding, wrongly, that pipelining does not work in Nix.

Honest bound on this step alone: it fixes **cold** builds, not incremental ones. A `stdx` edit
rebuilds 31 units for 127.3 s, of which only ~5 s is derivation overhead — the rest is real
compilation on a serial chain. Cold-build parity with cargo is unreachable regardless: the
115.6 s critical path already exceeds cargo's entire 81.4 s parallel build.

---

## 2. Stage A — Evaluation becomes the output contract

**Cost: one day. Do it first.** Everything in Stage B rewrites `templates/units.nix.in` and the
emitters, and the current suite (56 Rust tests) asserts on **substrings of emitted text** — which
cannot validate a template rewrite and would need rewriting anyway. The only thing that evaluates
the generated Nix today is `checks.<system>.library`, which renders this repository's own workspace
and instantiates every unit in it; nothing asserts on the *shape* of what came out, which is where
the bug below lives.

The gap is not hypothetical. `render_checked_roots` (`src/render.rs:3131`) joins entries with a
space into `checkedRoots = [ {{ checked_roots }} ];` (`templates/units.nix.in:856`), so

```nix
checkedRoots = [ withPolicyChecks units."hello-0.1.0-e7d39f05" ];
```

evaluates to a two-element list `[ <lambda> <derivation> ]` — 2N elements for N roots, policy
checks silently dropped. It was found by reading, not by testing.

### A.1 The fixture check

One fixture workspace under `nix/tests/fixture/`, rendered and evaluated as a flake check
alongside the existing `checks.<system>.library` (which covers `render-evaluates` and
`render-drv` for the repository's own workspace, but asserts nothing about shape):

| Check | Asserts |
|---|---|
| `render-evaluates` | `nix eval --apply builtins.attrNames` over `units` — the whole file evaluates, every unit key exists |
| `render-shapes` | element **counts and types** for `checkedRoots`, `roots`, `policyChecks`, `targetSets`, `binaries`, `libraries` |
| `render-drv` | `nix-instantiate` on one root and one test target — `.drv` produced, inputs resolve |
| `render-no-op-seams` | `extraUnits = {}` / `extraLibraries = {}` renders byte-identically to no seam (the property `templates/units.nix.in:175` claims) |
| `render-builds` | *(added during Stage B, see §8.4)* the graph builds and the binary runs — the only check that can see a build-time regression |

`render-shapes` is the one that matters: a length assertion is what catches the list-vs-application
class, and `nix-instantiate --parse` alone cannot — the bug is syntactically valid.

### A.2 Fix the class, in one place

Do **not** add parentheses at `render_checked_roots` and move on. Six sites build Nix lists by
string-joining (`src/render.rs:1096`, `2050`, `2227`, `3097`, `3142`, `3661`). Five are correct
only because their elements happen to be atomic select expressions; the sixth (`3142`,
`render_checked_roots`) emits an application and is the live bug.

End state: a single `nix_list(elements)` emitter that wraps every element in parentheses
unconditionally — always correct, atomic or not — and **no other code path constructs a Nix
list**. `render_checked_roots` then returns elements, not pre-joined text.

Explicitly **not** in scope: the typed Nix-expression emitter floated in `FASTER.md` §3. That is a
framework for one bug. A list helper and an eval check cover the failure mode; build the emitter
if and when the JSON-intermediate work needs it.

---

## 3. Stage B — The unit derivation as it should exist

### B.1 Shape

`mkUnit` (`templates/units.nix.in:169`) becomes a `derivation` whose `builder` is one static
script shipped in the flake — `nix/unit-builder.sh`, one file, all units — with
`__structuredAttrs = true` carrying the arg vector as data.

The builder does exactly:

1. Read the static `rustc_args` / `rustc_env` arrays from `$NIX_ATTRS_JSON_FILE`.
2. Resolve the **build-time-only** portion: `$(cat <dep>/nix-support/extern-path)` per direct
   dependency, build-script flag files, `rustc-env` exports, `out-dir` staging.
3. `exec` the driver.
4. Install: copy `build/*`, write `nix-support/extern-path`, `cargo-metadata`,
   `unused-crate-dependencies`.

### B.2 What stays bash, and why

The arg vector is **not** fully static, and a plan that assumes otherwise is wrong. Three classes:

| Class | Example | Where it resolves |
|---|---|---|
| Render-time constant | `--crate-name`, `--edition`, `-C metadata=`, `--cfg feature="…"`, profile flags | JSON |
| Eval-time (Nix interpolation) | `-L dependency=${units.foo}/lib`, `--remap-path-prefix` | JSON |
| **Build-time** | `--extern name=$(cat …/extern-path)`, build-script `rustc-cfg`/`rustc-link-*`/`rustc-env`, `$NIX_BUILD_TOP` paths | builder, at run time |

So the end state is not "no bash" — it is **one fixed bash script consuming data** instead of a
generated bash script per unit. That is what makes the builder static and cacheable, and it
retires most of the three-layer escaping regime (`research/nix-cargo-unit.md` §16) for the static
portion: values that used to pass through `shell::quote` → `nix_indented_string_fragment` become
JSON strings. An entire class of invisible escaping bugs goes away.

`render_build_script_run_phase` keeps generating bash. It is the hardest subsystem and rewriting
it is not required for this win — but its derivation still moves off stdenv (37 of 320 units).

### B.3 Scope

| Derivation | In scope | Note |
|---|---|---|
| Compile units (`Rustc`, `Clippy`, `ObjectEmit`) | builder **and** JSON args | The 283 that dominate |
| Build-script runs | builder only | Phase script stays generated bash |
| Per-`#[test]` leaves (`templates/units.nix.in:743`) | builder only | Currently `pkgs.runCommand` = full stdenvNoCC; the tax is multiplied by *test count*, not unit count — likely a larger absolute win than the 320 units when tests are on |
| `mkTestPlan`, `mkCoverageReport`, `mkBenchmarkPlan`, manifests | **out** | Already `__structuredAttrs` + `runCommand` (`templates/units.nix.in:258, 293, 353, 430`); a handful of derivations, not a scaling cost |

---

## 4. Deletion ledger

The point of the exercise. Every row exists **only** because units run under stdenv; each is
deleted, not ported.

| Delete | Site | Existed because |
|---|---|---|
| `dontStrip = true` | `src/render.rs:952` | fixup would strip rlibs |
| `dontStrip = true` (panic-object units) | `src/render.rs:1880` | fixup's `patchelf` errors "wrong ELF type" on `.o` relocatables |
| `dontUnpack`, `dontConfigure` | `templates/units.nix.in:170-171` | phase suppression |
| `postFixup` wiring | `src/render.rs:970-975` | sidecars had to land after fixup |
| `render_split_debuginfo_sidecar_post_fixup` (whole fn) | `src/render.rs:1684` | same |
| `*.dwo\|*.dwp) continue` exclusion in the copy loop | `src/render.rs:1657-1659` | the other half of the same dance |
| `set +x` after the driver, ×2 | `src/render.rs:1291, 1314` | fixup streamed its own xtrace and CI truncated the step |
| `set +x` in the doctest command | `src/render.rs:3325-3327` | same |
| `buildPhase` / `installPhase` as attributes | `src/render.rs:965-969` | stdenv phase concept; becomes one builder |
| `installs_split_debuginfo_sidecars_after_fixup` and its assertions | `src/render.rs:3896, 3902` | encodes the workaround, not a product requirement |

`.dwo`/`.dwp` sidecars then install in the ordinary copy loop with no special case — the behavior
users wanted, expressed once.

**Not deleted:** `ORPHAN_OUTPUT_PRECHECK` (a content-addressing/sandbox-less-darwin concern,
unrelated to stdenv) and `allowSubstitutes = false; preferLocalBuild = true` on test leaves
(`templates/units.nix.in:243-244`) — that reasoning is independent and still correct.

### Tests

Rust tests asserting on bash text that no longer exists are **deleted**, not rewritten to match
new text. Tests asserting *argv content* are re-pointed at the JSON arg vector — parsed and
asserted structurally, which is strictly better than substring matching on generated bash. Output
shape moves to the Stage A eval checks, which is where it belonged.

---

## 5. Deliberate non-goals

- **No flag, no dual path.** Not `stdenvBuilder = true`, not a fallback. One builder.
- **No metadata/codegen split yet.** That is the next bet; this step exists to make its
  measurement legible.
- **No lazy trees, linker swap, or merged doctests here.** Independently shippable
  (`FASTER.md` Stage 1); bundling them makes the number unattributable.
- **No content-addressing work.** `BENCH_BASE.md` §12 and `FASTER.md` §4 contradict each other on
  CA; settle it separately with the one-day determinism check (build twice, diff rmeta/rlib) and
  keep it out of this diff.
- **No generic Nix emitter framework.** See §A.2.

---

## 6. Acceptance criteria

Falsifiable, with a stop condition.

| Gate | Target | How |
|---|---|---|
| Trivial-probe marginal cost | **< 110 ms** (from 175 ms) | Re-run the `BENCH_BASE.md` §8 probe against the new builder |
| Cold build, rust-analyzer | **≤ 185 s** (from 211 s ±1.5%) | `bench/` recipe, two runs |
| No-op rebuild | no regression from 0.18 s | |
| Serial reference | drops proportionally from 319.4 s | `--max-jobs 1` |
| Correctness | `checks.*.smoke` passes; all four eval checks pass | |
| Closure | `#rust-analyzer` stays 91.6 MiB / 2 paths | Remaps must survive the builder rewrite |
| Byte-identity of the seams | `extraUnits = {}` renders identically | `render-no-op-seams` |

**Stop condition:** if the probe does not clear 110 ms, the ~2× stdenv figure from `FASTER.md`
Change 2 does not transfer to this workload. Stop, publish the number, and re-rank — do not
proceed to Change 1 on the assumption that overhead will come down later.

Expected: ~25–30 s, ~13% of cold wall clock. Modest on its own. The reason to do it is §1.

---

## 7. Risks

- **Lost stdenv conveniences.** `PATH`, `$NIX_BUILD_CORES`, and toolchain/linker discovery become
  explicit in the builder. Mechanical, but `extraNativeBuildInputs` consumers must still work —
  the fixture needs a native-dependency case.
- **Reference scanning is a Nix-level cost and does not go away.** The remaps mean it finds
  nothing, but it is not part of the 56 s being attacked. Do not credit it.
- **`__structuredAttrs` changes derivation inputs**, so every unit hash moves once on adoption.
  A one-time full rebuild, not a correctness problem — but say so before running the bench.
- **Darwin-only measurement.** All figures are `aarch64-darwin`, `sandbox = false`. A sandboxed
  Linux store would likely show a *larger* per-derivation tax, so the win should be bigger there;
  that is an untested prediction.
- **Third-party builder assumptions.** Anything downstream reaching for stdenv phase hooks
  (`preConfigure`, `postPatch`) on a unit breaks. Grep says nothing in-tree does; the documented
  seams are `extraRustcArgs` / `packageBuildEnv` / `packageRustcArgs` / `extraUnits`, all of which
  survive.

---

## 8. Outcome — measured, 2026-07-29

Stage A and Stage B both landed. The correctness and maintainability goals were met; **the
performance premise was wrong, and the stop condition in §6 fires.**

### 8.1 The per-derivation tax is Nix, not stdenv

The §6 gate assumed stdenv was the dominant term in the ~175 ms marginal cost, so removing it should
have taken the figure below 110 ms. To test that, the `BENCH_BASE.md` §8 probe was re-run in *three*
arms rather than one — the missing arm being the one that decides the question:

| Arm | What it is | Marginal cost per derivation (3 reps) | Median |
|---|---|---|---:|
| `minimal` | plain `derivation`, builder writes `$out` and nothing else | 109.3 / 113.0 / 110.4 ms | **110.4 ms** |
| `plain` | the real new unit shape: `__structuredAttrs`, `nix/unit-builder.sh` | 112.7 / 113.1 / 113.4 ms | **113.1 ms** |
| `stdenv` | the old shape: `mkDerivation` + `dontUnpack`/`dontConfigure`/`dontStrip` | 123.0 / 125.9 / 123.4 ms | **123.4 ms** |

`N = 40` vs `N = 160` at `max-jobs=10`, marginal = Δt / ΔN, every arm verified to actually build
(the first attempt at the `minimal` arm silently failed — a plain derivation has no `PATH`, so
`mkdir` was not found — which is why exit status is now checked).

Three readings, in order of importance:

1. **~110 ms of the ~123 ms is Nix itself.** A derivation whose builder does *nothing* costs
   110.4 ms. That is daemon round-trips, build-directory setup, output registration, and store
   bookkeeping. No change to the shape of a unit can touch it.
2. **stdenv was worth ~13 ms, about 10% of the per-derivation cost — not ~50%.** The "`mkDerivation`
   is ~2× a raw `derivation`" figure from `FASTER.md` Change 2 comes from a 10k-trivial-build
   benchmark and **does not transfer to this workload**.
3. **The new builder costs ~3 ms over the bare floor.** Sourcing structured attrs, building `PATH`,
   and assembling link flags is essentially free, so there is no more to win here.

Extrapolated honestly: ~10 ms × 320 units ≈ **3.3 s** of a 211 s cold build, **~1.6%**. The §6
expectation was 25–30 s / ~13%. It was wrong by an order of magnitude.

### 8.2 `BENCH_BASE.md` §8 needs correcting

The 175 ms marginal figure does not reproduce: the same stdenv shape measures 123 ms today. More
importantly, §8 attributes the cost to "sandbox setup, stdenv bash startup, phase dispatch, output
registration" without separating them, and the three-arm probe now shows the stdenv terms in that
list are the small ones. The §8 headline — 56 s, ~27% of the cold build, "the clearest optimization
target in the whole document" — is not actionable: the tax is real and it is serial, but it is
Nix's, and the only lever on it is **fewer derivations**, never cheaper ones.

### 8.3 Gate results

| Gate | Target | Result |
|---|---|---|
| Trivial-probe marginal cost | < 110 ms | **113.1 ms — not met, and unreachable** (floor is 110.4 ms) |
| Cold build, rust-analyzer | ≤ 185 s | **not measurable**: a ~3.3 s effect is inside the ±1.5% (±3.2 s) run-to-run noise `BENCH_BASE.md` already records |
| Correctness | `smoke` passes; the eval checks pass | **met** — rust-analyzer's ~320 units build stdenv-free, the binary answers `--version` and parses Rust; all five fixture checks pass |
| Closure | `#rust-analyzer` stays 91.6 MiB / 2 paths | **met** — 2 paths (the binary and libiconv), 91.7 MiB |
| Byte-identity of the seams | `extraUnits = {}` renders identically | met (`render-no-op-seams`) |

**The stop condition applies.** Do not proceed to `FASTER.md` Change 1 (the metadata/codegen split)
expecting per-derivation overhead to come down later — it will not. What the measurement does give
that bet is a precise, no-longer-assumed penalty: **+230 derivations × ~113 ms ≈ +26 s** of
unabsorbable serial wall clock, against a plausible 20–50 s pipelining gain. Still indeterminate in
sign, but now the penalty term is a measured floor rather than something a future builder change
might shrink.

The re-ranking this implies: stop optimizing the *cost* of a derivation and start reducing their
*count* (coarsening the external-dependency tier, merged doctests), or attack the 115.6 s critical
path directly (linker swap), which is where the time that is not derivation overhead actually goes.

### 8.4 The stdenv conveniences that actually bit

§7 listed "lost stdenv conveniences" as mechanical. Two of the three were. The third was not, and it
is the one worth writing down, because a fixture cannot find it — only a real workspace can.

1. **PATH and the file utilities.** Mechanical, as predicted. Stated once in the template
   (`unitToolchain`) instead of implicitly.
2. **The cc/bintools wrappers do not read `NIX_LDFLAGS`.** They read a *salted* copy
   (`NIX_LDFLAGS_<salt>`), and they only fold the unsalted variable into it for the dependency roles
   named by a `NIX_CC_WRAPPER_TARGET_<role>_<salt>` marker — which stdenv's setup hook exports.
   Without the marker `accumulateRoles` yields no roles, the fold is skipped, and **every link flag
   the builder assembles is silently discarded**. Symptom: `ld: library not found for -lz` on a unit
   whose zlib was right there in its inputs. The salt is not guessable, so it is threaded in from the
   documented `pkgs.stdenv.cc.suffixSalt` passthru.
3. **Transitive propagation, which the fixture could not catch.** A package hands its own
   dependencies to its dependents through `nix-support/propagated-build-inputs`, and stdenv's
   `findInputs` walks that transitively. On darwin `stdenv.defaultBuildInputs` is the Apple SDK,
   which propagates libiconv — so with the walk missing, all ~320 rust-analyzer units compiled fine
   and the **final link** failed with `library not found for -liconv`. Two things had to be
   reproduced: stdenv's implicit `defaultBuildInputs`, and the transitive walk itself.

Both gaps in the fixture that let (3) through are now closed. The fixture's native input is
`pkgs.zlib.dev`, which does not itself contain `lib/libz` but propagates `zlib` — so its
`cargo:rustc-link-lib=z` resolves only if the walk happens. And a fifth check, **`render-builds`**,
actually *builds* the graph and runs the binary, because instantiation cannot see any of this: every
one of these three failures happens at build time. Removing the propagation walk now reproduces
`library not found for -lz` in the fixture, in seconds, instead of at a 320-unit workspace's final
link.

One more, purely mechanical but silent: `read -r -a arr < file` returns nonzero at EOF when the file
has no trailing newline — which is exactly how `propagated-build-inputs` is written. Under `set -e`
that aborted the builder before it produced a single line of log output.

### 8.5 What the step was still worth

None of this argues the change should be reverted. It bought, independent of speed:

- **A real bug.** `checkedRoots` evaluated to a 2N-element list of alternating `withPolicyChecks`
  lambdas and derivations, so **every policy check on every root was silently dropped**. Stage A's
  shape check catches it in both of the ways it is wrong (element count 6 instead of 3; elements that
  are functions rather than derivations), and a single `nix_list` emitter that parenthesizes every
  element makes the whole class unrepresentable.
- **Evaluation as the output contract.** Four flake checks (`render-evaluates`, `render-shapes`,
  `render-drv`, `render-no-op-seams`) over a checked-in fixture workspace. Nothing evaluated the
  generated Nix before; the renderer's 56 Rust tests asserted on substrings of emitted text, which
  cannot see a shape error in syntactically valid output.
- **The deletion ledger, in full.** All ten rows in §4 are deleted rather than ported: both
  `dontStrip`s, `dontUnpack`/`dontConfigure`, the `postFixup` wiring and
  `render_split_debuginfo_sidecar_post_fixup`, the `*.dwo|*.dwp` copy-loop exclusion, all three
  `set +x`, `buildPhase`/`installPhase` as attributes, and the test that encoded the fixup ordering.
  `pkgs.stdenv.mkDerivation` no longer appears in the unit path.
- **One escaping regime instead of three.** `rustcArgs` and `rustcEnv` are JSON, so values no longer
  pass through `shell::quote` *and* `nix_indented_string_fragment`. An argument containing a quote,
  a newline, or a `$` now reaches rustc verbatim, and the tests assert on argv structure instead of
  pattern-matching the shell text that used to produce it.

The honest summary: this was a **correctness and maintainability** change that also removed ~10 ms
per derivation. It was sold as a performance change. The measurement that would have shown that up
front is the three-arm probe in §8.1 — a `minimal` arm alongside the `stdenv` one — and it cost about
fifteen minutes.

---

## 9. Where the 133 s actually goes — measured, 2026-07-29

§8 established that per-derivation cost is Nix's floor and cannot be reduced. That says what *not*
to do; it does not say where the time is. So: a cold build of all 264 unit derivations, per-derivation
start/stop captured from `nix build --log-format internal-json` (stamped on arrival — internal-json
carries no timestamps of its own), with the toolchain id salted to force the rebuild rather than
deleting anything from the store.

Vendor and planner IFDs were warm, so **this is not comparable to the 211 s in `BENCH_BASE.md`**;
it is the unit-build portion only.

```
wall clock              132.8 s
sum of build time       419.1 s
avg parallelism           3.2x   at --max-jobs 10
critical path           107.1 s  = 81% of wall clock, over 22 derivations
```

| kind | count | seconds | share |
|---|---:|---:|---:|
| compile unit | 212 | 367.7 | 87.7% |
| build-script compile | 25 | 30.2 | 7.2% |
| build-script run | 25 | 19.9 | 4.7% |
| plan / render (IFD) | 2 | 1.4 | 0.3% |

### 9.1 The build is dependency-serialized, not overhead-bound

419 s of work finishing in 133 s is **3.2x** parallelism against a 10x budget: seven cores idle on
average. 81% of wall clock is one chain of 22 derivations, and five crates are 72 s of that 107 s
path — `hir_ty` 19.3 s, `ide_assists` 14.5 s, `rust_analyzer` 14.3 s, `intern` 13.7 s, `hir_def`
10.1 s.

Per-derivation overhead **on the path** is 22 × 113 ms ≈ **2.5 s of 107 s**. This corrects §8.1's
framing: the tax is real, but it is charged against the *sum* of build time, which has seven idle
cores to absorb it. It is not charged against the thing that is binding.

### 9.2 Metadata is ~18% of a compile, so pipelining has a large ceiling

`FASTER.md` Change 1 splits each library unit into a metadata derivation (`--emit metadata`,
frontend only) and a codegen derivation, so a dependent unblocks on metadata instead of on full
codegen. The per-crate ceiling is `1 - metadata/full`. Measured by reading each unit's exact argument
vector straight out of its derivation — `__structuredAttrs` stores it as data, which is what makes
this measurable without touching the renderer — and running rustc twice:

| unit | full | metadata | metadata share | earlier unblock |
|---|---:|---:|---:|---:|
| `intern` | 7.0 s | 0.3 s | 5% | 95% |
| `ide_assists` | 10.9 s | 1.1 s | 10% | 90% |
| `hir_ty` | 21.1 s | 3.8 s | 18% | 82% |
| `hir_def` | 11.2 s | 2.0 s | 18% | 82% |
| `base_db` | 1.2 s | 0.2 s | 18% | 82% |
| `ide_db` | 3.8 s | 0.8 s | 20% | 80% |
| `hir` | 4.7 s | 1.2 s | 26% | 74% |
| `syntax` | 2.5 s | 0.8 s | 31% | 69% |

The ~82 s of libraries on the critical path would contribute roughly **15 s** of metadata instead.
Adding the final binary's own 14.3 s (a bin must fully codegen) and the one dependency codegen that
cannot be hidden, the path plausibly lands at **50–60 s against 107 s today** — bounded also by
total work over cores, since the frontend runs twice: ~495 s / 10 cores ≈ 50 s. The two bounds meet
at about the same number, which is a good sign that ~50 s is the real floor rather than an artifact.

### 9.3 Why Cargo's ~1.2x understates this

`FASTER.md` finding 1 cites Cargo's own pipelining evaluation at up to ~1.2x and calls the gain
"concentrated in release builds and deep graphs". That number is not transferable, in the optimistic
direction for once: Cargo already overlaps units within one process and its dependency edges are not
hard barriers. **Here every unit edge is a derivation boundary — a full stop.** The loss pipelining
recovers is therefore much larger in this architecture than in Cargo, which is exactly what the 3.2x
measured parallelism against a 10x budget shows.

### 9.4 Re-ranking

1. **Pipelining (`FASTER.md` Change 1) is now the strongest candidate, not the weakest.** It targets
   the 107 s path directly, and its +230 derivations (~26 s) are charged to the sum, where the slack
   is. Prototype it on the five path crates first, not all 320 units.
2. **Linkers (`FASTER.md` Change 5: mold, wild, rust-lld) drop off the list.** Only 25 build-script
   bins (tiny), 18 proc-macro dylibs, and **one** real binary link in a cold build. The whole prize
   is bounded above by `rust_analyzer`'s 14.3 s — which is compile *and* link — so realistically well
   under 10 s of 133 s. mold is Linux/ELF only (Mach-O support went to the commercial `sold` and was
   then discontinued), so it cannot even be measured on the platform every number here comes from,
   and on Linux it would be competing against rust-lld, already the default since 1.90.
3. **Fewer derivations is still the only lever on the per-derivation tax**, but at 2.5 s on the path
   it is no longer worth spending anything on.

**Caveat to carry into the prototype:** pipelining raises total CPU work (the frontend runs twice),
so the win depends on having idle cores. At 10 cores there are seven. On a 4-core CI box the sum
bound (~495 s / 4 ≈ 124 s) would dominate and the gain would largely vanish. Measure there before
promising it.
