# `nix-cargo-unit` vs `crate2nix`

A structured comparison against the closest prior art. Sources: `research/nix-cargo-unit.md`
(this repo's internals), `research/crate2nix.md` (crate2nix as of v0.15.0, 2026-01-28), and
`bench/nix-cargo-unit/BENCH_BASE.md` (measured, 2026-07-28).

## TL;DR

- **The defining difference is what each tool asks cargo for.** crate2nix asks cargo *what the
  dependency graph is* (`cargo metadata`), then re-derives features, `cfg()`, and the compile plan
  itself in Nix, at **one derivation per crate**. nix-cargo-unit asks cargo *what the compile plan
  is* (`cargo build --unit-graph -Z unstable-options`), then transcribes it, at **one derivation
  per compilation unit**. Nearly every other difference follows from that one choice.
- **nix-cargo-unit is the more correct design and the less mature implementation.** Taking the unit
  graph eliminates crate2nix's entire feature/cfg/target-drift bug class by construction rather
  than by patching, and the source-closure, path-remapping, and build-script-environment work
  solves problems crate2nix has open issues for. Against that: nightly-only, IFD by construction,
  no nixpkgs `defaultCrateOverrides`, no eval-level tests, and one live correctness bug.
- **Finer granularity is not free.** rust-analyzer builds as 320 units against ~330 crates, and
  measured per-derivation fixed cost is ~175 ms — **~56 s, ~27% of a 211 s cold build**. With a
  median unit of 0.73 s, the median unit spends more time in Nix scaffolding than in rustc.
  crate2nix pays the same tax at roughly a third of the count.
- **The two projects converge on the same next move.** Both independently concluded that per-crate
  cross-project sharing is defeated by feature skew, so granularity's real payoff is incrementality
  *within* one project — and both want to stop emitting thousands of literal Nix attrsets in favour
  of compact JSON read by a thin Nix consumer. crate2nix has that shipped as experimental
  (`--format json` + `lib/build-from-json.nix`); nix-cargo-unit has it as a proposal
  (`research/FASTER.md`, §3).

---

## 1. Position in the pipeline

```
crate2nix                                nix-cargo-unit
─────────                                ──────────────
Cargo.toml + Cargo.lock                  Cargo.toml + Cargo.lock
    │                                        │
    │ cargo metadata (stable)                │ cargo build --unit-graph
    │                                        │   -Z unstable-options (nightly)
    ▼                                        ▼
IndexedMetadata                          unit-graph JSON
    │ resolve → CrateDerivation               │ merge (optional, N graphs → 1)
    │ prefetch sha256                         │
    │ render (Tera)                           │ render (+ Cargo.lock, vendor dir)
    ▼                                        ▼
Cargo.nix  ──consumed by──▶ buildRustCrate   units.nix  ──self-contained──▶ rustc
             (nixpkgs, bash)                              (own template)
```

crate2nix stops at *data*; nixpkgs' `buildRustCrate` turns that data into `rustc` invocations.
nix-cargo-unit owns the invocation end to end in `render.rs` + `templates/units.nix.in`.

## 2. Granularity

| | crate2nix | nix-cargo-unit |
|---|---|---|
| Derivation per | resolved crate | Cargo compilation unit |
| lib + `build.rs` compile + `build.rs` run | 1 derivation (script runs in `configurePhase`) | 3 derivations |
| Tests | `.override { runTests = true; }` on the same derivation | separate unit, plus one derivation **per `#[test]`** |
| Doctests | not modeled | separate rustdoc-driven derivations, `List`/`RunAll`/`RunCase` |
| Clippy | not modeled | per-unit `clippy-driver` derivation, aggregated `clippyByPackage` |
| Benches, obj-emit-for-panic-scan | not modeled | separate derivations |
| rust-analyzer workload | ~330 crates | **320 units** (231 lib, 69 custom-build, 16 proc-macro, 4 bin), 46 roots |

Under crate2nix, the same crate needed at two different feature sets collapses into one `crates`
entry with features resolved at build time. Under nix-cargo-unit the unit graph already contains
both units and they hash differently. Strictly more faithful; strictly more derivations.

## 3. Fidelity to cargo — the strongest argument for the unit-graph approach

crate2nix's known-limitations list is dominated by **re-derivation drift**:

| crate2nix issue | Cause |
|---|---|
| Non-existent feature refs in `target.'cfg(...)'` cause Nix **eval failures** (#141) | feature resolution reimplemented in Nix |
| Target-specific features don't auto-activate (#129) | same |
| `cfg()` support "reasonable but incomplete" (e.g. processor-feature cfgs) | cfg translated at generation time |
| `cargo:rustc-*` directives historically ignored (#180 / nixpkgs #119382) | `buildRustCrate` is a bash reimplementation of cargo |
| proc-macro prelude mismatch (#113); cross + proc-macro still awkward (#397) | same |

nix-cargo-unit **does not resolve features, cfg, or targets at all**. `Unit.features`, `platform`,
`profile`, `lint_rustflags`, and `check_cfg_args` arrive pre-resolved from cargo and go straight
into the identity hash and the rustc argv. The whole class is structurally absent.

The price is paid elsewhere:

- **Unstable cargo interface.** `--unit-graph` is `-Z unstable-options`, so planning runs with
  `RUSTC_BOOTSTRAP=1` set inside the planner derivation (`nix/graph.nix`). A stable toolchain is
  therefore enough, but the flag is gated for a reason and cargo owes no compatibility on either
  side of it. crate2nix runs on stable `cargo metadata`.
- **Unstable input schema.** `model.rs` pays for it explicitly: lenient `Lto` / `DebugInfo` /
  `Strip` deserialization accepting every spelling cargo has used, and `UnitMode::Other(String)`
  preserving unknown modes verbatim so a future cargo mode doesn't break `merge`.

**Trade:** crate2nix buys stability of *interface* at the cost of fidelity of *result*.
nix-cargo-unit buys fidelity at the cost of interface stability.

## 4. Who emits the rustc invocation

**crate2nix → `buildRustCrate`.** Real leverage: it's in nixpkgs, maintained by others, and
`defaultCrateOverrides` ships `buildInputs`/`nativeBuildInputs` for openssl, pkg-config `-sys`
crates, protobuf, and friends for free. Real liability: since carnix's removal crate2nix is
essentially `buildRustCrate`'s only significant consumer, and nixpkgs PR #373744 has floated that
"it may be in crate2nix's own interest to continue maintenance of `buildRustCrate` inside their own
repository."

**nix-cargo-unit → its own template.** No nixpkgs coupling, no `rustPlatform`, no flake layout baked
in — `units.nix` is a *function* over `pkgs`, `rustToolchain`, `src`, `workspaceRoot`. Also no free
native-dependency database. Its escape hatches are:

- `extraEnv` / `extraNativeBuildInputs` / `extraRustcArgs` / `extraRustcArgsForPlatform` — workspace-wide
- **`packageBuildEnv` / `packageRustcArgs`** — per-package, keyed by cargo package name, existing
  specifically so a fast-churning value (a git commit baked into one crate) invalidates one
  package's units rather than the whole closure. `mkUnit` strips the `packageName` tag before
  `mkDerivation`, so a package with no override renders byte-identically.
- **`extraUnits` / `extraLibraries`** — merged *over* the generated set and *outside* the `rec`, so
  a downstream unit's `units.<key>` reference resolves to an injected prebuilt.

crate2nix's equivalent is `buildRustCrateForPkgs` + `crateOverrides`, which is a coarser knob but
lands you in ordinary `mkDerivation` phases (`preConfigure`, `postPatch`, `patches`).

## 5. What nix-cargo-unit does that crate2nix does not

These are the clearest wins, and several map directly onto crate2nix's open issue list.

**Workspace-sibling source access.** crate2nix #17: a crate only sees its own source directory, so
`include_bytes!("../../testdata/x")` or a build script reading a sibling breaks.
nix-cargo-unit's `source_closure_relatives` promotes a unit from package scope to a filtered
workspace/vendor closure on two triggers: symlinks pointing outside the package (walked
transitively; escaping the workspace/vendor boundary is a hard error), and textual scanning of
`.rs` files for `include!` / `include_str!` / `include_bytes!`. Deliberately an over-approximation —
it can match inside a comment, and a spurious directory just vanishes at the Nix filter.

**`--remap-path-prefix` on every unit.** `file!()` expands to an absolute `/nix/store/…` path, and
every `panic!` / `unwrap` / `assert` / `#[track_caller]` site bakes one in as plain string data that
no `strip` removes. Nix's reference scanner finds the 32-char hash anywhere in an output, so each
string pins the entire source derivation; one std generic monomorphized in your crate pins the
~1.9 GiB toolchain. Both remaps are emitted unconditionally, for every driver. Measured result:
rust-analyzer's binary closure is **91.6 MiB over 2 store paths** (itself + `libiconv`). Nothing in
crate2nix's model addresses this, and the crate2nix documentation is silent on whether
`buildRustCrate` remaps at all — see §11.

**Build-script environment completeness.** Both tools export `OUT_DIR`, `CARGO_MANIFEST_DIR`,
`CARGO_PKG_*`, `CARGO_FEATURE_<NAME>=1`, `TARGET`/`HOST`/`PROFILE`/`NUM_JOBS`/`RUSTC`, propagate
`DEP_<LINKS>_*`, and both deliberately drop `rerun-if-changed` / `rerun-if-env-changed`.
nix-cargo-unit additionally:

| Addition | Why it exists |
|---|---|
| `CARGO_CFG_*` synthesized from `rustc --print cfg --target "$TARGET"`, comma-joining repeated keys | that's how `target_feature` arrives; `libm` fails without it |
| `CARGO_MANIFEST_LINKS` from `package.links` | `ring` panics without it |
| `OUT_DIR` nested two levels under `mktemp -d` | `rusty_v8` locks at `OUT_DIR/../../v8.fslock` |
| Writable copy of the package source as `CARGO_MANIFEST_DIR` | build scripts mutate their manifest dir |
| Offline `cargo metadata` shim: `linkFarm` of the package's lockfile closure + registry replacement, `CARGO_NET_OFFLINE=true`, shipped `Cargo.lock` deleted, dev-dep tables stripped | `cbindgen` shells out to `cargo metadata` and dies on DNS in the sandbox |
| `OUT_DIR` copied to a fixed `/cargo-unit-build-script-out` and remapped | `mktemp` entropy in a generated source path would make CA dependencies byte-incompatible |

crate2nix's reported failures — `CARGO_MANIFEST_DIR` metadata lookups (#26), `anyhow`'s `build.rs`
overwriting `lib.rs` (nixpkgs #74071), missing `protoc` (#66), glib resource compilation — are
mostly this same category, handled by overrides rather than by emulation.

**Policy, test, and coverage surfaces with no crate2nix analogue:**

- one derivation per `#[test]`, fanned out behind a **single** test-discovery IFD (`testManifestDrv`
  lists every target in one derivation rather than one IFD per binary), with
  `allowSubstitutes = false; preferLocalBuild = true` on the leaves
- doctests via a rustdoc contract, with `--output-format doctest` JSON listing and a
  `running 1 test` assertion to defend against rustdoc's substring filter
- `clippyByPackage` — per-unit `clippy-driver`, `symlinkJoin`ed per package rather than one
  workspace aggregate
- `unusedCrateDependenciesByPackage` — flagged only when **every** unit of the package that declares
  a dependency reports it unused
- `policyChecks.panicFreedom` — relocation-based panic-reachability scan over `--emit obj` output
  (`panic_scan.rs`), fail-closed, with honest documented limits
- LCOV coverage that un-remaps source paths back to workspace-relative form via the `sourceAudit`
  `remapPrefix` records — the counterpart to the remapping above
- `compareTangoBenchmarks`, `testPlan`/`benchmarkPlan` TSV manifests, `nextest-metadata` fabrication

**Selective content addressing.** `--content-addressed` applies to libs and bins only; tests and
build-script runs stay input-addressed on purpose, with the failure modes recorded (NixOS/nix#15649
for the test-manifest case; a `rcgen → ring` realisation wedge after a CI `nix-gc` for build-script
runs). crate2nix has no CA story.

## 6. Caching keys — different bets

**crate2nix bets on cross-project sharing.** Keyed on package id with features resolved at build
time, the hope is that identical crate derivations are shared between projects and served from a
binary cache (cachix). Its own documentation concedes the theory outruns practice: "different
feature-flag combinations across projects prevent deduplication, so cross-project cache sharing is
more limited than the theory suggests." The Crane #539 discussion puts it bluntly — four Rust
packages each want a different combination of exact tokio version, tokio features, and toolchain
version, and you get no sharing anyway.

**nix-cargo-unit bets on precision within one project.** `Unit::identity_hash` folds in package
identity, target name/edition, sorted crate types, sorted features, the full profile, lint
rustflags, check-cfg args, mode, platform, `is_std`, sorted dependency edges *including edge
attributes* (`extern_crate_name:public:noprelude:<dep hash>`), and the toolchain id. Cross-project
sharing is effectively off the table — the entire transitive closure must match. What it buys:

- `package_identity` collapses `path+` ids to `path#<name>@<version>`, discarding the absolute
  directory, so two checkouts of the same workspace at different store paths produce **identical
  unit hashes** (pinned by `path_package_identity_ignores_absolute_source_roots`)
- edge attributes keep two otherwise-identical units distinct when one renames a dependency via
  `extern_crate_name` — a case `merge` has a regression test for
- `--toolchain-id` salts everything, so a toolchain bump invalidates the graph rather than silently
  reusing incompatible rlibs

Measured payoff on rust-analyzer: a `stdx` edit (deepest crate, 30 reverse-deps) rebuilds **31 of
320 units, 9.7%** — but costs 127 s, 60% of a full cold build, because those 31 units *are* the
critical chain. Granularity bounds *what* rebuilds; it does not shorten the chain.

## 7. Generation strategy and IFD

crate2nix offers a genuine choice, and documents both as first-class:

| | Committed `Cargo.nix` | IFD (`appliedCargoNix`) |
|---|---|---|
| Sync with `Cargo.lock` | manual (`regenerate_cargo_nix.sh`) | automatic |
| Eval | no IFD, full build parallelism | serializes evaluation |
| nixpkgs | upstreamable | disallowed |
| Gotchas | PR noise from regeneration diffs | `overrideAttrs` doesn't propagate (nix #4265) |

**nix-cargo-unit is IFD by construction.** The pipeline is `plannerSource → unitGraphJson →
unitsNix → import`, and producing the unit graph means *running cargo inside a derivation against
the vendored tree*. That can't be a pure evaluation, so crate2nix's committed-file escape hatch
doesn't really exist here. The mitigation is that the pipeline is cheap and staged so the expensive
stage rarely re-runs:

| Stage | Cold rebuild | Re-runs when |
|---|---:|---|
| `plannerSource` | 8.9 s | a file is added/removed, or a manifest changes |
| `unitGraphJson` | 0.50 s | `plannerSource` changes |
| `unitsNix` (render) | 0.76 s | any source edit |
| plan + render together | **1.00 s** | |

A source-body edit leaves `plannerSource` byte-identical, so the whole-workspace cargo resolve is
skipped and only the ~0.76 s render re-runs. Against a 211 s build, **planning is not the
bottleneck** — 99.5% of a cold build is compilation.

Generated-artifact size is a shared worry: crate2nix's `Cargo.nix` reaches "tens of thousands of
lines" for big projects (one reason nixpkgs won't accept it, and the motivation for its experimental
JSON output); nix-cargo-unit's `units.nix` is **2.6 MB** for 320 units.

## 8. Measured performance

crate2nix publishes no benchmark numbers. nix-cargo-unit does (`bench/nix-cargo-unit/BENCH_BASE.md`, rust-analyzer
release build, Apple M5 10-core, `max-jobs=10`, `sandbox=false`, CA off):

| | |
|---|---:|
| Cold build, whole workspace | 212.9 s (~211 s ±1.5%) |
| Cold build vs. plain cargo `--offline` | **2.62× slower** (cargo: 81.4 s) |
| No-op rebuild vs. cargo | **0.69×** (0.18 s vs 0.26 s) |
| Parallel speedup on 10 cores | 1.51× (theoretical max from the DAG: 3.25×) |
| Critical path (21 units) | 115.6 s, **55% of wall clock** |
| Per-derivation fixed cost | ~175 ms → **~56 s over 320 units, ~27% of the cold build** |
| Median unit compile | 0.73 s (248 of 320 units are under 1 s) |

Two of these bear directly on the comparison:

**The per-derivation tax scales with granularity.** With a median unit at 0.73 s and ~175 ms of Nix
scaffolding per derivation, **the median unit spends more time in Nix machinery than in rustc.**
crate2nix pays the same tax at roughly a third of the derivation count. `research/FASTER.md`
Change 8 concedes the point directly and proposes coarsening the external-dependency tier toward
crate2nix-like granularity, reserving per-unit granularity for workspace crates where
incrementality actually pays.

**No pipelining — shared with crate2nix, inherent to derivation-per-anything.** Cargo unblocks a
dependent as soon as its dependency emits `--emit=metadata`; a Nix derivation is atomic, so a
dependent cannot start until its dependency has fully completed and registered. On a 21-unit
critical chain that compounds. `FASTER.md` Change 1 proposes splitting each unit into a metadata
derivation and a codegen derivation to recover it — which is what rules_rust and Buck2 do — but
notes the magnitude is unmeasured in a Nix-scheduler context.

Scheduler tuning is not the answer: four cold builds across `(max-jobs, cores)` pairs all landed
within 3%.

## 9. Maturity and ecosystem

| | crate2nix | nix-cargo-unit |
|---|---|---|
| Age / home | ~2018–, `nix-community/crate2nix`, ~498 ⭐, dual Apache-2.0/MIT | this repo |
| Latest release | v0.15.0, 2026-01-28, after a ~2-year gap | — |
| Adoption | devenv `languages.rust.import` (July 2025), own cachix-backed CI | rust-analyzer benchmark only |
| Toolchain | stable cargo | **nightly required** |
| Native deps | nixpkgs `defaultCrateOverrides` + `crateOverrides` | `extraNativeBuildInputs`, `packageBuildEnv`, `packageRustcArgs` |
| Cross-compilation | translated at generation; "weakest area," weaker than cargo2nix; host/build split for proc-macros | pre-resolved per unit by cargo; `extraRustcArgsForPlatform` hooks; **not exercised in bench** |
| Private registries | v0.15.0+ (#366) | via `vendorSources` / `nix/vendor.nix` |
| Tests | Tera + **Nix-level** unit tests under `templates/nix/crate2nix/tests`, run by `cargo test` | 55 in-tree Rust tests, **all textual assertions on emitted Nix** |
| Live known bug | eval failures on cfg-feature refs (#141) | `checkedRoots` missing parens (`render.rs:3131`) → `[ <lambda> <derivation> ]` instead of one policy-checked derivation; no test covers it |
| Bus factor | small community project, uneven maintenance, `buildRustCrate` dependency at risk | single repo |

The test-shape row is the sharpest asymmetry. crate2nix evaluates its generated Nix in CI;
nix-cargo-unit asserts on substrings of emitted text and consequently carries a live bug of exactly
the class an eval test catches. `render_panic_freedom_check` gets the same construct right, and
`render_default_entry` is unaffected because it isn't in a list — so this is a one-site slip, not a
design flaw, but it went unnoticed precisely because no test evaluates the output.

## 10. When to pick which

**Pick crate2nix** for: stable-toolchain projects; anything you might upstream to nixpkgs (via the
committed-`Cargo.nix`, no-IFD path); dependency trees that lean on `defaultCrateOverrides`;
devenv users (it's already wired in); teams that want someone else maintaining the builder.

**Pick nix-cargo-unit** for: workspaces where cargo-fidelity matters more than toolchain stability —
crates with demanding build scripts, `include!`-heavy sources, workspace-sibling file access,
`links`/`-sys` chains; projects where binary closure size matters (the path-remapping work is not
replicable by configuration alone); anywhere the policy surface (clippy per package, unused-crate
deps, panic freedom, coverage, per-test derivations) is the actual deliverable rather than a nice-to-have.

**Pick neither** if you want fast Nix builds with minimal ceremony and don't need per-crate sharing:
crane remains the pragmatic default, and its two-derivation dep-blob model sidesteps the
per-derivation tax that both of these tools pay.

## 11. Caveats on this comparison

- **crate2nix's per-crate cross-project sharing is unmeasured on both sides.** Its own docs describe
  the deduplication failure qualitatively; nobody has published numbers.
- **Whether `buildRustCrate` does any `--remap-path-prefix` could not be confirmed.** The crate2nix
  research doc is silent on it, and §5 treats it as absent. If it does remap, that section
  overstates the difference.
- **Cross-compilation is not exercised by this repo's benchmark.** The claim that pre-resolved
  `platform` per unit is cleaner than crate2nix's generation-time cfg translation is a design
  argument, not a measured one.
- **All performance figures are one machine, one workload, one configuration** (`aarch64-darwin`,
  `sandbox = false`, `contentAddressed = false`). A sandboxed Linux store would likely raise the
  per-derivation overhead in §8. The only end-to-end scenario run twice gave 212.9 s / 209.9 s, so
  read single-run figures with ~1.5% noise.
- **crate2nix details are current as of v0.15.0 / early 2026** and are drawn from its design docs
  and the `buildRustCrate` source on master; older nixpkgs pins exhibit older behavior.
