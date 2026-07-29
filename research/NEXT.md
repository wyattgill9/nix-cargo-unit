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
cannot validate a template rewrite and would need rewriting anyway. No test anywhere evaluates
the generated Nix (`nix eval` / `nix-instantiate` appear nowhere in `src/`, `flake.nix`, or
`nix/`).

The gap is not hypothetical. `render_checked_roots` (`src/render.rs:3131`) joins entries with a
space into `checkedRoots = [ {{ checked_roots }} ];` (`templates/units.nix.in:856`), so

```nix
checkedRoots = [ withPolicyChecks units."hello-0.1.0-e7d39f05" ];
```

evaluates to a two-element list `[ <lambda> <derivation> ]` — 2N elements for N roots, policy
checks silently dropped. It was found by reading, not by testing.

### A.1 The fixture check

One fixture workspace under `nix/tests/fixture/`, rendered and evaluated as a flake check
(`flake.nix:72`, currently just `inherit … nix-cargo-unit`):

| Check | Asserts |
|---|---|
| `render-evaluates` | `nix eval --apply builtins.attrNames` over `units` — the whole file evaluates, every unit key exists |
| `render-shapes` | element **counts and types** for `checkedRoots`, `roots`, `policyChecks`, `targetSets`, `binaries`, `libraries` |
| `render-drv` | `nix-instantiate` on one root and one test target — `.drv` produced, inputs resolve |
| `render-no-op-seams` | `extraUnits = {}` / `extraLibraries = {}` renders byte-identically to no seam (the property `templates/units.nix.in:175` claims) |

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
