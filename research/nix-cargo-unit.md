# nix-cargo-unit — Internals

`nix-cargo-unit` translates a **Cargo unit graph** into a **Nix expression in which every
Cargo compilation unit is its own derivation**.

Cargo's own model is "one `cargo build` invocation compiles the whole graph." Nix's model is
"one derivation produces one output from declared inputs." Most Rust-on-Nix tooling bridges
these by making the whole workspace (or a whole dependency tier) a single derivation and
letting Cargo do the scheduling inside it. This project takes the other route: it replays
Cargo's dependency resolution *outside* the build, then emits one `stdenv.mkDerivation` per
unit that calls `rustc` directly. Nix becomes the build scheduler; Cargo is only consulted
for planning.

The consequence is granularity. Editing one crate rebuilds that crate's units and their
dependents — not the workspace. It also means this tool has to reimplement, faithfully, every
piece of environment Cargo normally supplies to `rustc` and to `build.rs`. Most of the code
is exactly that reimplementation.

---

## 1. Position in the pipeline

```
cargo +nightly build --unit-graph -Z unstable-options   (one invocation per target set)
        │
        │  unit-graph JSON
        ▼
nix-cargo-unit merge          ← optional: fold several graphs into one, dedup by identity
        │
        ▼
nix-cargo-unit render         ← + Cargo.lock, workspace root, vendor dir
        │
        │  units.nix  (a Nix function)
        ▼
import ./units.nix { pkgs, rustToolchain, src, workspaceRoot, ... }
        │
        ▼
{ units, packages, binaries, libraries, tests, doctests, benchmarks,
  policyChecks, clippyByPackage, testPlan, coverageReport, targetSets, ... }
```

`render` is a pure function of `(unit graph JSON, Cargo.lock, filesystem layout of the
sources)`. It reads the filesystem — package manifests, and directory trees for source
scoping — but performs no builds and resolves no network.

The rendered file is a **function**, not a fixed derivation set. The caller supplies the
toolchain, the vendored sources, and a large surface of per-package escape hatches
(§10). Nothing about nixpkgs, `rustPlatform`, or a particular flake layout is baked in.

---

## 2. CLI surface

`src/main.rs` — four subcommands, no shared state between them.

| Command | Role |
|---|---|
| `render` | The main event. Unit graph on **stdin**, Nix on **stdout**. |
| `merge` | Merge N unit-graph JSON files into one, deduplicating units by identity hash and recording each input's roots as a *root set*. |
| `scan-panics` | Standalone binary analysis over `.rlib`/`.o` artifacts. Invoked from inside a rendered derivation, not by humans. |
| `nextest-metadata` | Synthesizes the two JSON files `cargo-nextest` needs so it will run a test binary that Cargo never built. |

`render` flags:

- `--workspace-root` / `--vendor-root` — the two filesystem boundaries all sources must fall inside.
- `--cargo-lock` — required; the authority on external package source identity (§6.2).
- `--content-addressed` — opt into CA derivations for libs and bins (§9).
- `--toolchain-id` — salt every unit hash, so a toolchain bump invalidates everything.
- `--deny-unused-crate-dependencies`, `--deny-panics` — enable the two policy gates (§11).

---

## 3. Module map

| File | Lines | Responsibility |
|---|---|---|
| `src/model.rs` | 943 | Unit-graph deserialization, unit identity hashing, graph merge/validation. |
| `src/render.rs` | 6406 | Everything else: source scoping, build-phase synthesis, build-script emulation, policy checks, template filling. ~3700 lines of logic + ~2700 of tests. |
| `src/panic_scan.rs` | 462 | Relocation-based panic-reachability analysis over object files. |
| `src/hash.rs` | 21 | 16-hex-char SHA-256 prefix. The single identity-stamp primitive. |
| `src/shell.rs` | 13 | Single- and double-quote shell escaping. |
| `templates/units.nix.in` | 873 | The Nix scaffolding the renderer splices generated fragments into. |

---

## 4. The data model (`model.rs`)

### 4.1 Schema

`UnitGraph { version, units, roots, root_sets }` — `root_sets` is *not* Cargo's; it is added
by `merge` so a merged graph remembers which roots came from which original invocation.

A `Unit` carries `pkg_id`, `target` (kind, crate types, name, src path, edition, test/doctest/doc
flags), `profile`, `features`, `lint_rustflags`, `check_cfg_args`, `mode`, `dependencies`,
`platform`, `is_std`.

### 4.2 Lenient deserialization

`cargo --unit-graph` is an unstable interface and has spelled the same profile fields several
ways across releases. Rather than pin a version, the model absorbs every shape:

- `Lto` — accepts `true`, `"true"`, `"fat"`, `"thin"`, anything else → `Off`.
- `DebugInfo` — accepts `true`, integers `0/1/2`, and the strings `"line-tables-only"`,
  `"line-directives-only"`, `"limited"`, `"full"`.
- `Strip` — accepts `true`, a bare string, `{ resolved: "…" }`, and `{ resolved: { Named: "…" } }`.
- `UnitMode` — known modes become variants; **unknown modes are preserved verbatim** in
  `UnitMode::Other(String)` and round-trip through serialization. A future Cargo mode does not
  break `merge`.

Each of these also re-serializes to a single canonical string, so `merge`'s output is stable
regardless of which Cargo version produced its inputs.

### 4.3 Package-id parsing

`parse_pkg_id` handles both the modern (`registry+https://…#serde@1.0.228`) and legacy
(`serde 1.0.228 (registry+…)`) forms, plus `path+`, `git+`, and `sparse+`. When the fragment
carries no `@version`, the package name is recovered from the URL's last path segment
(stripping `.git`) and the fragment is taken as the version — which is how
`git+https://…/rtnetlink?rev=eb68…#0.20.0` resolves to `rtnetlink 0.20.0`.

---

## 5. Unit identity

This is the load-bearing abstraction. `Unit::identity_hash(dependency_hashes, toolchain_id)`
feeds a canonical byte stream into SHA-256 and takes the first 8 bytes as 16 hex characters
(`hash::short_digest`). That one string becomes:

- the Nix attribute name: `units."<target-name>-<version>-<hash>"`
  (or `"<pkg>-build-script-run-<version>-<hash>"`);
- `rustc -C metadata=<hash>`, so symbol mangling differs between distinct units;
- `rustc -C extra-filename=-<hash>`, so artifacts of the same crate name coexist in one `-L` dir.

### 5.1 What goes into the hash

Package identity, target name and edition, **sorted** crate types, **sorted** features, the
full profile (name, opt-level, LTO, debuginfo, panic, strip, debug-assertions, overflow-checks,
rpath, incremental, codegen-units, split-debuginfo, rustflags), lint rustflags, check-cfg args,
mode, platform, `is_std`, and the target's `test`/`doctest`/`doc` booleans. Then **sorted**
dependency edges, each contributed as `extern_crate_name:public:noprelude:<dep hash>`, and
finally the optional toolchain id.

Sorting features, crate types, and dependency hashes makes identity independent of Cargo's
emission order. Including the *edge attributes* (not just the dependency's hash) is what keeps
two otherwise-identical units distinct when one renames a dependency via `extern_crate_name` —
a case `merge` has a regression test for.

### 5.2 What is deliberately *left out*

`package_identity` collapses any `path+` package id to `path#<name>@<version>`, discarding the
absolute directory. Two checkouts of the same workspace at different store paths therefore
produce **identical unit hashes**. Without this, every unit name would change whenever the
source store path changed, and nothing would ever cache across checkouts. `path_package_identity_ignores_absolute_source_roots` in `model.rs` pins this.

### 5.3 Two hash passes, one function

- `model::merge_identity_hash` — used by `merge`, always with `toolchain_id = None`. Merging is
  a toolchain-agnostic dedup step.
- `render::compute_hash` — used by `render`, threading the real `--toolchain-id`.

Both memoize over the DAG. Both include `run-custom-build` dependencies in the hash (a comment
records why: a name hash that skipped them once collided two merged units that differed only in
their build-script-run variant). The *transitive dependency* walk used for `-L` flags
(`collect_transitive_unit_deps`) does the opposite and skips build-script runs, since those
contribute no rlib.

---

## 6. Rendering

`render_units_nix` is a three-step function:

1. `graph.ensure_supported()` — version check plus index validation (every root and every
   dependency index must be in bounds).
2. `prepare_graph` — compute hashes, names, per-unit source entries, transitive dependency
   sets, and the build-script-run index.
3. Render ~20 named slots and splice them into `templates/units.nix.in`.

`fill_template` is the entire template engine: scan for `{{ name }}`, look the name up in the
slot table, splice. Spliced values are never rescanned. An unknown or unterminated placeholder
**panics** — these are compile-time invariants of a file that ships inside the binary via
`include_str!`, not runtime input.

### 6.1 Source scoping

Each unit gets a `SourceEntry` describing the narrowest store path that can hold its sources.
This is where most of the incremental-rebuild benefit comes from: if a unit's `src` is the
whole workspace, editing any file anywhere rebuilds everything.

The scope is one of four `SourceBase` values:

| Base | Nix expression | Meaning |
|---|---|---|
| `Workspace` | `scopedWorkspaceSource <name> <relative>` | `builtins.path` rooted at the *package* directory. The common case. |
| `WorkspaceClosure` | `scopedWorkspaceClosureSource <name> <includes>` | Rooted at the workspace with a filter admitting only listed subtrees. |
| `VendorPackage` | `vendorSources.<key>` | A caller-supplied per-crate vendored source. |
| `VendorClosure` | `scopedVendorClosureSource <name> <includes>` | Filtered subtree of the vendor dir. |

A unit starts as `Package` scope and is promoted to `Closure` only when
`source_closure_relatives` discovers the package needs directories outside its own root. Two
things trigger that:

**Symlinks.** `collect_source_closure_roots` walks the package tree. A symlink pointing outside
the package (but inside the workspace/vendor boundary) adds its target as another included root,
and the walk continues into it. A symlink escaping the *boundary* is a hard error — Nix could
not reproduce it anyway.

**`include!` macros.** `.rs` files are scanned textually by `extract_include_macro_paths` for
`include!`, `include_bytes!`, and `include_str!`. Plain `"…"` and `r"…"` literals are resolved
relative to the file's directory; a `concat!("dir/", …)` form contributes the leading literal
directory. The scan does not parse Rust, so it can match inside a comment — harmless, since a
non-existent directory just disappears at the Nix filter. Computed arguments (`env!("OUT_DIR")`)
are skipped on purpose: they resolve to build-script output, not source.

This is what makes the `regex-lite` shape work — an integration test at
`crate/tests/lib.rs` doing `include_bytes!("../../testdata/anchored.toml")` promotes the unit
to a workspace closure over `[ "regex-lite" "testdata" ]`.

`include_closure_root` has a specific guard: if an include resolves to a file sitting *directly*
at the boundary (say `vendorDir/README.md`), the closure root stays that single file rather than
being promoted to the boundary directory — promoting it would pull in every vendored crate.

### 6.2 External source identity

External units are keyed by `"<cargo-lock source>#<name>@<version>"`, and the source string comes
from **Cargo.lock**, not from the unit graph. `CargoLockSources::package_for_unit` requires
exactly one match on `(name, version, source)`; zero or many are both errors.

`cargo_lock_source_matches_pkg_id` handles the one systematic disagreement between the two files:
Cargo.lock spells a git source with a trailing `#<commit>` that the unit graph's `pkg_id` omits.
The comparison strips it.

### 6.3 Source store naming and the remap prefix

`source_name` produces `cargo-unit-source-<pkg>-<version>-<hash16>`, hashing
`base_label ‖ name ‖ version ‖ source_key ‖ relative`. Every unit of the same package shares one
source derivation.

`source_remap_prefix` produces `/build/<pkg>-<version>` — and this is one of the more consequential
details in the codebase, so it deserves its own section.

---

## 7. Path remapping and closure size

Every compile unit emits, unconditionally:

```
rustc_args+=( --remap-path-prefix "$src=/build/<pkg>-<version>" )
rustc_args+=( --remap-path-prefix "${rustToolchain}/lib/rustlib/src/rust=/rustc" )
```

**Why it exists.** `file!()` expands to the absolute path of the source file. Here that is a
`/nix/store/…` path. Every `panic!`, `unwrap`, `assert`, and `#[track_caller]` site bakes one into
the artifact as plain string data — data no `strip` removes. Nix's reference scanner looks for the
32-character store hash *anywhere* in an output, so each of those strings pins the entire source
derivation into the binary's runtime closure.

The second remap covers std. Upstream compiles std against a virtual `/rustc/<commit>` prefix, but
`rustc` translates that straight back to the local `rust-src` directory when the component is
installed (`-Ztranslate-remapped-path-to-local-path`, on by default). One `unwrap` on a std generic
monomorphized in your crate is enough to pin the whole ~1.9 GiB toolchain. Half a remap leaves half
the closure, which is why both are emitted together and for every driver.

**Why the prefix is derived from package name/version** rather than from the source store name: it
must be a pure function of the graph. Relocating a source — a rename, a filter change, a different
but byte-identical checkout — must not perturb the bytes of an rlib that quotes it. That is
precisely the property content addressing's early cutoff depends on.

**The cost**, documented honestly in the source: backtraces name `/build/<crate>-<ver>` instead of a
real path. `include_str!`, `include!`, and `env!("CARGO_MANIFEST_DIR")` read the real filesystem and
are untouched by `--remap-path-prefix`, so a crate that deliberately embeds a store path keeps both
the path and its reference. Coverage *does* read these paths back, which is why `sourceAudit`
records `remapPrefix` and the template's `normalize_source_path` reverses the mapping (§13).

A third remap exists for build-script output: `OUT_DIR` content is copied to a fixed
`$NIX_BUILD_TOP/cargo-unit-build-script-out` and remapped to `/cargo-unit-build-script-out`,
because `mktemp` entropy in a generated source path would otherwise make separately-realized
content-addressed dependencies byte-incompatible.

---

## 8. Anatomy of a compile unit

Every non-build-script unit renders through one shared scaffold, `render_unit_derivation`,
parameterized by a `UnitDerivation { pname, native_build_inputs, driver, install_phase, package_name }`.

### 8.1 The three drivers

| Driver | Binary | Emit | Purpose |
|---|---|---|---|
| `Rustc` | `rustc` | `dep-info,metadata,link` (or `-o build/<name>` for bins/tests) | The real artifact. |
| `Clippy` | `clippy-driver` | `dep-info,metadata` | Lints only — no codegen, no link. |
| `ObjectEmit` | `rustc` | `obj` | Relocatable objects for the panic scan (§12). |

All three see the same source, the same dependency rlibs, and the same flags. They differ only
in name, emit, extra native inputs, and install phase. Clippy additionally appends
`extraClippyLintArgs` at the very end of the argument vector, so caller policy overrides defaults.

### 8.2 Build phase construction

`render_driver_build_phase` assembles a bash script into three arrays — `rustc_args`,
`rustc_env`, `build_script_flags` — in a fixed order:

1. `mkdir -p build`, array initialization.
2. `CARGO_*` package environment (`cargo_package_exports`): crate name, package name, the four
   split version fields including the empty `CARGO_PKG_VERSION_PRE` (ring's `links` invariant reads
   it), plus authors/description/homepage/repository/license/license-file/rust-version read from the
   package's real `Cargo.toml`. `CARGO_BIN_NAME` for bins.
3. `CARGO_MANIFEST_DIR`, resolved through `crate_root_for_unit` → nearest ancestor directory
   containing a `Cargo.toml`. This handles nested build-script entrypoints like
   `aws-lc-sys`'s `builder/main.rs`, where the manifest dir is the package root, not the file's parent.
4. `CARGO_BIN_EXE_<name>` for integration tests and benches, pointing at same-package **build-mode**
   bin units.
5. Build-script flag reading, if the unit has a build-script run (§8.4).
6. `DEP_<LINKS>_*` from direct dependencies that declare `links`.
7. `push_rustc_args` — the profile translation.
8. Path remaps, target linker, `extraRustcArgs` hooks.
9. `-L dependency=…/lib` for every transitive non-bin dependency.
10. `--extern <name>=$(cat …/nix-support/extern-path)` for every direct non-bin, non-run dependency.
11. The crate root source path, then emit/output flags.
12. `"${build_script_flags[@]}"`, then the driver invocation.

`push_rustc_args` covers `--crate-name` (with `-`→`_`), `--edition`, each `--crate-type`,
`-C prefer-dynamic` for proc-macros, opt-level, debuginfo, LTO, codegen-units, debug-assertions,
overflow-checks, `panic=`, `strip=`, `split-debuginfo=`, `rpath`, `-C metadata`, `-C extra-filename`,
profile rustflags, lint rustflags, check-cfg args, `--cfg feature="…"` per feature, `--test` (when the
target uses a harness) or `--cfg test`, `--target`, and `--cap-lints warn` for external crates.

Two small correctness details:

- **`lto_for_unit`** only emits `-C lto` when *every* crate type is `bin`/`cdylib`/`staticlib`.
  rustc rejects LTO on rlib-producing units.
- **`uses_explicit_output_path`** — bins and tests get `-o build/<name>`, and `-C extra-filename` is
  then suppressed. Passing both makes rustc warn "ignoring -C extra-filename flag due to -o flag" on
  every such build, and the flag is a no-op there anyway.

The driver invocation is wrapped in `set -x` / `set +x`. The `set +x` matters: without it stdenv's
`fixupPhase` streams its own trace into the log and CI truncates the step.

### 8.3 Install phase and the `extern-path` protocol

Units communicate through a small on-disk contract:

```
$out/lib/…                              build artifacts (minus .dwo/.dwp)
$out/nix-support/extern-path            absolute path to the rlib/so/dylib/dll/rmeta
$out/nix-support/cargo-metadata         build-script metadata, if any
$out/nix-support/unused-crate-dependencies   policy report, if enabled
$out/bin/<name>                         for bins and test binaries
```

`extern-path` is written by probing a fixed candidate list in order
(`lib<name>-<hash>.rlib`, `.so`, `.dylib`, `<name>-<hash>.dll`, `lib<name>-<hash>.rmeta`).
Consumers read it with `$(cat …)` rather than reconstructing the filename, so the platform-specific
extension logic exists in exactly one place.

Split-debuginfo sidecars (`.dwo`/`.dwp`) are excluded from the `lib` copy loop and re-installed in
`postFixup`, after stdenv's fixup would otherwise have choked on them.

**`ORPHAN_OUTPUT_PRECHECK`** prefixes every install phase. A killed content-addressed build on a
sandbox-less store (the darwin default) can leave an invalid, non-root-owned directory at the
resolved `$out`. A later build by a different `_nixbld` uid then fails with a bare
`cp: … Permission denied` one phase after `rustc` succeeded — which reads like a linker or OOM
failure. The precheck detects it, prints the path, its owner, and the `nix-store --check-validity`
recovery recipe, and exits. It only *reports*; it never deletes a store path from inside a builder.

### 8.4 Build-script emulation

This is the largest single subsystem, because running `build.rs` outside Cargo means synthesizing
everything Cargo would have provided.

**The compile/run split.** Cargo models a build script as two units: a `custom-build` compile
(build.rs → executable) and a `run-custom-build` (execute it). `prepare_graph` pairs them, and also
records the run's *other* run-dependencies, which is how `DEP_*` metadata propagates between build
scripts.

**Environment the run derivation constructs:**

- A **writable copy** of the package source at `$out/<package_root>` (build scripts mutate their
  manifest dir), with `CARGO_MANIFEST_DIR` pointed at it.
- `OUT_DIR` at `$(mktemp -d)/build/out` — nested **two levels deep on purpose**. Cargo's real
  `OUT_DIR` is `target/<profile>/build/<pkg>-<hash>/out`, and scripts write relative to its
  ancestors: `rusty_v8` takes a lock at `OUT_DIR/../../v8.fslock`. A bare `mktemp -d` would put that
  grandparent at `/`.
- `RUSTC`, `RUSTDOC`, `HOST` (from `rustc -vV`), `TARGET`, `PROFILE`, `OPT_LEVEL`, `DEBUG`,
  `NUM_JOBS` (from `NIX_BUILD_CORES`), `CARGO_ENCODED_RUSTFLAGS` (`\x1f`-separated).
- `CARGO_MANIFEST_LINKS` from the manifest's `package.links` — `ring` panics without it.
- `CARGO_FEATURE_<NAME>=1` per feature.
- `CARGO_CFG_*` — synthesized by running `rustc --print cfg --target "$TARGET"` and transforming
  each line: uppercase, `-`→`_`, strip quotes, and **comma-join repeated keys** (which is how
  `target_feature` arrives). Crates like `libm` fail without these.
- `DEP_<LINKS>_*` from dependency build-script runs.

**Output parsing.** The script's stdout is read line by line. `cargo::` is normalized to `cargo:`,
the temp `OUT_DIR` path is rewritten to `$out/out-dir`, and directives are demultiplexed into files:

| Directive | Destination |
|---|---|
| `rustc-cfg`, `rustc-link-lib`, `rustc-link-search`, `rustc-env` | `$out/<name>`, one value per line |
| `rustc-cdylib-link-arg`, `rustc-link-arg`, `rustc-link-arg-{bins,tests,benches}` | `$out/<name>` |
| `warning=…` | stderr, prefixed |
| `rerun-if-changed`, `rerun-if-env-changed` | dropped (Nix owns invalidation) |
| any other `cargo:key=value` | `$out/cargo-metadata` |

The `OUT_DIR` tree is copied to `$out/out-dir`, and every text file in it that mentions the temp
path is rewritten with `substituteInPlace --replace-fail` — generated sources routinely embed it.

**Consumption.** `append_build_script_flag_reader` emits the mirror image on the compile side:
read each file back into `build_script_flags` with the right rustc flag prefix, `export` the
`rustc-env` lines, copy `cargo-metadata` forward, and copy `out-dir` into the fixed
`cargo-unit-build-script-out` path before remapping it.

**Offline `cargo metadata`.** Some build scripts shell out to `cargo metadata` — `cbindgen` does,
from `Builder::generate`. Inside the sandbox that resolve reaches for crates.io and dies on DNS.
Rather than wire a vendored registry into every build-script run (which would make each one depend
on its package's whole vendored closure, re-running expensive scripts like `ring` and `aws-lc-sys`
on unrelated lockfile bumps), the renderer detects the case narrowly:

- `CARGO_INVOKING_BUILD_DEPS` is a curated list — currently just `["cbindgen"]`.
- `build_script_invokes_cargo` BFSes the build-script compile's dependency closure for a hit.
- On a hit, `metadata_universe_for_unit` computes the package's Cargo.lock dependency closure
  (excluding itself) and `render_metadata_cargo_config` emits a `pkgs.linkFarm` of exactly those
  crates plus a cargo config replacing crates-io — and each git source — with it.
- The run phase then sets `CARGO_HOME`/`CARGO_NET_OFFLINE=true`, **deletes any `Cargo.lock` the crate
  shipped to crates.io** (it pins versions the workspace did not resolve), and **strips
  dev-dependency tables** from the manifest copy with `awk` (a workspace lockfile never records a
  non-member's dev-deps, so they are absent from the vendored universe).

---

## 9. Content addressing policy

`--content-addressed` is opt-in, and applies *selectively*. The reasoning is recorded at each site:

| Unit kind | Addressing | Why |
|---|---|---|
| Libraries, binaries | CA when requested | Early cutoff: a byte-identical rebuild lets dependents skip rebuilding. |
| Tests, benches | **always input-addressed** | Leaf derivations nothing consumes — no early cutoff to buy, only floating-realisation fragility. A stale or GC'd test realisation on a shared store resurfaces as `build of resolved derivation '…-cargo-unit-test-manifest' failed: N dependencies failed` with no builder error (NixOS/nix#15649). |
| Build-script runs | **always input-addressed** | `OUT_DIR` can hold arbitrary non-reproducible content. Under floating CA, one varying byte makes the output hash differ between builds; after a GC drops one copy, the next mismatching realisation wedges the store ("Trying to register a realisation … but we already have another one locally"). Observed in practice via `rcgen → ring`, triggered by a CI host's periodic `nix-gc`. |

The comments are candid about the ceiling on CA's benefit: rustc's rmeta is oversensitive (a comment
or formatting change still changes it), and link targets always relink when any transitive rlib
changed. The upstream "Relink, don't Rebuild" rustc project goal is named as the thing that would
widen it.

Because build-script outputs are input-addressed, the `strip --strip-debug` pass over
`$out/out-dir` is explicitly **best-effort** — a pure size win against C-toolchain crates that bake
absolute build paths into DWARF (briansmith/ring#715). It tolerates a missing `strip` and per-file
failures, and it never uses `--strip-all`, since the crate links against these objects' symbols.

---

## 10. The Nix template

`templates/units.nix.in` is compiled into the binary with `include_str!` and is the *only* handwritten
Nix in the project.

### 10.1 Inputs

Required: `pkgs`, `rustToolchain`, `src`, `workspaceRoot`.

Optional seams, roughly in order of how often you'd reach for them:

- `vendorDir`, `vendorSources` — external crate sources.
- `extraEnv`, `extraNativeBuildInputs`, `extraRustcArgs`, `extraRustcArgsForPlatform`,
  `extraLinkRustcArgsForPlatform` — workspace-wide.
- `packageBuildEnv`, `packageRustcArgs` — **per-package**, keyed by Cargo package name. These exist
  specifically so that a fast-churning value (a git commit baked into one crate) invalidates one
  package's units instead of the whole dependency closure. This is what the render-time
  `packageName` tag on each unit is for; `mkUnit` strips it before `mkDerivation`, so a package with
  no override renders byte-identically to one with no tag at all.
- `packageTestInputs`, `packageTestEnv`, `testArgsByPackage`, `testRunPrelude` — test execution.
- `extraClippyLintArgs`, `clippyEnabled`, `extraPolicyChecks` — policy.
- `includeIgnored` — whether `tests.<bin>.cases` includes `#[ignore]`d tests.
- `cargoUnit` — the scanner package, required only when `--deny-panics` was rendered.
- **`extraUnits`, `extraLibraries`** — the injection seam. `extraUnits` is merged *over* the generated
  set and *outside* the `rec`, so a downstream unit's `units.<key>` reference resolves to an injected
  prebuilt unit, and an injection can override a from-source unit of the same key. Both default to
  `{}`, in which case output is byte-identical to a graph rendered without the seam.

### 10.2 Outputs

`units`, `packages`, `binaries`, `libraries`, `benchmarks`, `tests`, `doctests`, `roots`,
`checkedRoots`, `targetSets`, `default`, `clippyUnits`, `clippyByPackage`,
`unusedCrateDependenciesByPackage`, `policyChecks`, `sourceAudit`, `testPlan`, `benchmarkPlan`,
`coverageReport`, `makeCoverageReport`, `compareTangoBenchmarks`, `testTargetNamesByPackage`,
`doctestTargetNamesByPackage`.

`targetSets` mirrors `root_sets` — one record per original `cargo` invocation, each with its own
`binaries`/`libraries`/`tests`/`doctests`/`benchmarks` — so a merged graph can still expose
per-invocation namespaced outputs.

---

## 11. Test, doctest, and benchmark surfaces

### 11.1 One IFD for test discovery

Enumerating `#[test]` functions requires *running* each test binary with `--list`. Doing that
per-binary would mean one import-from-derivation per binary, each blocking evaluation.

Instead, `testManifestDrv` is a **single** derivation that lists every test target in the graph,
with `NIX_BUILD_CORES`-bounded parallelism and per-target failure attribution. `mkTestCases` then
reads `<manifest>/<name>.list`, filters `": test"` lines, and fans out to ordinary derivations.
First access to *any* binary's `cases` triggers the one IFD.

Each test target exposes:

- `all` — the whole binary in one derivation, mirroring `cargo test`, with
  `RUST_TEST_THREADS=$NIX_BUILD_CORES`.
- `cases.<test name>` — one derivation per `#[test]`, run with `--exact --nocapture`.

Per-test leaves set `allowSubstitutes = false; preferLocalBuild = true`. The reasoning is in the
template: a leaf produces an empty marker `$out` nothing consumes, so substituting it costs a
narinfo round-trip against every configured substituter — thousands of leaves × N caches per CI run
— to fetch an empty directory, when re-running the test locally is cheaper.

Derivation names forbid `:`, so `sanitizeTestName` maps `::`→`--` and `:`/space→`_`.

### 11.2 Doctests

Doctests can't reuse the compiled test binary; they need `rustdoc`. `render_doctest_command` emits
three variants of one script — `List`, `RunAll`, `RunCase` — differing only in the leading rustdoc
flags. `List` uses `-Z unstable-options --output-format doctest` to get JSON, parsed by
`parseDoctestList`, which keeps entries where `doctest_attributes.rust` holds and `ignore == "None"`
(unless `includeIgnored`).

`RunCase` filters by `$TEST_NAME` and then **asserts** that `running 1 test` appears in the output —
rustdoc's filter is substring-based, so without this check a case could silently run zero or many.

The doctest script also handles the runtime-library-path problem: any build-script
`rustc-link-search` pointing into `out-dir` is collected and exported as `LD_LIBRARY_PATH`
(or `DYLD_FALLBACK_LIBRARY_PATH` on darwin, with the correct default fallback chain).

`Unit::has_doctests` excludes proc-macro targets, with a note explaining why: the rendered doctest
command compiles the crate as a plain library, but a proc-macro target only compiles under
`--crate-type proc-macro` (Cargo special-cases this when driving rustdoc), so every
`#[proc_macro_attribute]` item would error.

### 11.3 Plans and benchmark comparison

`testPlan` and `benchmarkPlan` emit TSV manifests (`packages/<pkg>/test-binaries`,
`source-roots.tsv`, `benchmarks.tsv`) for external drivers. `compareTangoBenchmarks` runs each
benchmark binary in `compare` mode against a baseline plan, copying both binaries out of the store
first (Tango needs them writable/executable locally), aggregating logs and failures.

---

## 12. Policy checks

Three gates, deliberately scoped so a one-crate edit doesn't rebuild the workspace's checks.

### 12.1 Clippy — `clippyByPackage`

Candidates are non-external, non-`run-custom-build` units. Externals compile under
`--cap-lints warn` precisely so a churning upstream can't break the workspace lint gate. The
custom-build *compile* unit **is** workspace Rust and is included.

Each candidate gets its own `clippy-driver` derivation emitting metadata only. `clippyByPackage`
then `symlinkJoin`s just that package's units — not one workspace aggregate that fans out to
everything. `clippyUnits` remains available for callers wanting individual units.

### 12.2 Unused crate dependencies — `unusedCrateDependenciesByPackage`

With `--deny-unused-crate-dependencies`, each local unit builds with
`-W unused-crate-dependencies --error-format=json --json=unused-externs-silent`, and `jq` extracts
`unused_extern` diagnostics into `$out/nix-support/unused-crate-dependencies`.

The aggregation rule matters: a dependency is reported unused only when **every** unit of the
package that declares it reports it unused. A dependency used by the lib but not the test binary is
not flagged.

Because the rustc invocation now needs its stderr captured, that branch of
`append_driver_invocation` disables `set -e` around the call, replays diagnostics, and re-raises the
original exit status — so a compile error still fails the build with its real message.

### 12.3 Panic freedom — `policyChecks.panicFreedom`

With `--deny-panics`, each candidate unit gets a second derivation (`Driver::ObjectEmit`,
`--emit obj`) whose `.o` files are installed, and a `scanUnit` derivation runs
`nix-cargo-unit scan-panics --crate-name <each workspace crate> …` over them. The gate asserts
`cargoUnit != null`, so enabling the policy without wiring the scanner fails loudly rather than
passing silently.

Candidates exclude externals, proc-macros, build-script units, tests, and benches — test bodies
legitimately panic.

---

## 13. `panic_scan.rs`

The analysis avoids disassembly entirely.

**Premise.** A function that can panic emits a call to a `core::panicking::*` entrypoint. In a
*relocatable* object, that call survives as a **relocation** whose target is the undefined panic
symbol, at an offset inside the calling function's text range. Reading symbols and relocations with
the `object` crate attributes each panic call to its containing function — and the same code works
for ELF and Mach-O.

**Why objects, not binaries.** A linked binary resolves panic calls to direct branches with no
relocation left to read. This is also why generics work: a generic is codegened where it is
*monomorphized*, so a library generic carrying no relocation in its own rlib does carry one in the
bin object that instantiates it. Scanning every production unit and scoping findings to the whole
workspace crate set attributes it back to its defining crate.

**Function attribution.** `function_ranges` collects text symbols in a section, sorts by address,
and **clamps each function's end to the next function's start** — Mach-O omits symbol sizes, so the
neighbor's address is the only reliable upper bound.

**Symbol matching** is careful about mangling. `at_crate_boundary` requires the needle to be preceded
by `_` (v0's `Cs<id>_` disambiguator) or `ZN` (legacy), so:

- `crate::core::panicking::helper` does **not** match `4core9panicking`;
- a crate's own `panicking` module does not match;
- workspace crate `de` (token `2de`) does not match `serde`'s `de` module.

`crate_token` builds the length-prefixed form shared by both manglings, normalizing `-`→`_`.
Unmangled symbols (`#[unsafe(no_mangle)]` FFI exports) are always scanned — they carry no crate
token but are still defined in this crate's object.

**Fail-closed design.** Zero artifacts found → error. An artifact that is neither an archive nor a
parseable object → error. An archive member named `*.o` that fails to parse → error. A gate that
can't read what it was handed must not report success.

**Honest limits**, stated in the module docs: this is a best-effort detector, not a soundness proof.
Two classes escape by construction — generics no production unit instantiates (never codegened
anywhere), and panics routed through std cold paths not in the `PANIC_SINKS` catalog. The docs name
call-graph reachability over the linked, monomorphized binary (what `findpanics` does) as the sound
successor.

---

## 14. Coverage

`mkCoverageReport` requires the workspace to have been built with
`extraRustcArgs = [ "-Cinstrument-coverage" ]` and errors with that hint if no `.profraw` appears.
It runs every test target with `LLVM_PROFILE_FILE` set, merges with `llvm-profdata`, exports LCOV
with `llvm-cov`, then **normalizes source paths back to workspace-relative form**.

That last step is the counterpart to §7. `normalize_source_path` first tries each recorded
`remapPrefix` from `sourceAudit` — the form instrumented units actually emit — then falls back to
matching `/nix/store/<hash>-<name>/…` against `sourceStoreName`, which still matters for prebuilt
units injected through `extraUnits` that this graph never compiled and never remapped. Records that
normalize to nothing are dropped entirely, and an empty final report is an error.

`writableTestCwd` (default true) copies each test's source root to a writable location before
running, since tests that write relative to their manifest dir would otherwise fail against a
read-only store path.

`llvm-cov`/`llvm-profdata` default to the paths inside `rustToolchain` and are checked for
executability up front, with a hint about toolchains built without LLVM tools.

---

## 15. `nextest-metadata`

`cargo-nextest` refuses to run without Cargo's metadata. This subcommand fabricates the minimum:
a `cargo metadata` JSON with a single synthetic package
(`path+file://<workspace_root>#<target>@0.0.0`) and a nextest `binaries-metadata` JSON pointing at
the already-built test binary, with host triple and rust libdir filled in. It writes both files and
does nothing else — the caller wires them into a nextest invocation.

---

## 16. Escaping: three layers stacked

Generated bash lands inside Nix `''…''` indented strings, so the renderer juggles three escaping
regimes at once — worth understanding before editing any emitter.

| Helper | Layer | Rule |
|---|---|---|
| `shell::quote` | bash | `'…'`, with `'` → `'\''`. |
| `shell::double_quote` | bash | `"…"`, escaping `\`, `"`, and `` ` ``. |
| `nix_indented_string_fragment` | Nix | `''` → `'''`, `${` → `''${`. |
| `nix_attr` | Nix | `serde_json::to_string` — JSON string escaping. |

The interesting part is what is *deliberately not* escaped. `${units.foo}`,
`${renderExtraRustcArgs …}`, and `${pkgs.lib.escapeShellArgs extraClippyLintArgs}` are written raw
so **Nix** interpolates them. Bash array expansions are written `''${rustc_args[@]}` so Nix emits a
literal `${rustc_args[@]}` for **bash**. Getting these backwards is the most likely way to break an
emitter, and the mistake is invisible until the generated Nix is evaluated.

`nix_attr` leaning on JSON escaping is sound for the values it actually receives (crate names,
versions, hex hashes, relative paths, registry URLs) because JSON and Nix agree on `\"`, `\\`, and
control escapes. It assumes no value contains a literal `${`, which JSON would not escape but Nix
would treat as interpolation.

---

## 17. Testing

55 tests, all passing, all in-tree. The style is consistent: build a synthetic `UnitGraph` (often
against a real temp directory with real `Cargo.toml` files), render it, and assert on substrings of
the emitted Nix. Tests are named as behavioral claims rather than function names —
`installs_split_debuginfo_sidecars_after_fixup`, `tests_stay_input_addressed_even_with_content_addressing`,
`include_macro_does_not_promote_vendor_root_to_source_closure`,
`user_panicking_module_is_not_a_panic_sink`.

`panic_scan`'s tests synthesize ELF objects with `object::write`, placing a relocation at a known
offset inside a known text symbol — real analysis over real object bytes, no fixtures on disk.

`doctest_commands_match_cargo_rustdoc_contract` is the notable one: it builds a workspace, renders,
and asserts the full rustdoc contract in one place, since that command has no other executable
specification.

The gap: no test evaluates the emitted Nix. Every assertion is textual (see §19).

---

## 18. Packaging

The flake is the only door. A consumer takes the GitHub flakeref and calls one function:

```nix
inputs.nix-cargo-unit.url = "github:wyattgill9/nix-cargo-unit";
...
cargoUnit = nix-cargo-unit.lib.mkCargoUnit {
  inherit pkgs;
  rustToolchain = <cargo + rustc, carrying lib/rustlib>;
};
graph = cargoUnit.buildWorkspace { src = ./.; workspaceRoot = ./.; };
```

`lib.mkCargoUnit` is `import ./nix`, and it is deliberately **not** system-indexed: it reads the
system off the `pkgs` it is handed and builds the renderer from that same nixpkgs
(`nix/package.nix`, a plain `callPackage`-able derivation), so a consumer never indexes an
attribute by system and never wires the binary in by hand. The flake input is the version
selector, which is why there is no seam for substituting a different renderer.

The remaining outputs serve narrower purposes. `packages.<system>.nix-cargo-unit` is the CLI on
its own, for a shell or a CI step that wants the binary rather than the library — built with
`rustPlatform.buildRustPackage` across four systems, using `lib.fileset` to include exactly
`Cargo.toml`, `Cargo.lock`, `src`, and `templates` (the last because `render.rs` pulls the
template in with `include_str!`). `devShells.<system>.default` is the crate's own dev shell, and
`formatter` is `alejandra`.

`checks.<system>.library` applies `mkCargoUnit` to this repository's own workspace. Evaluating it
is most of the check: it resolves the policy schema and the vendor plan, runs both IFD stages, and
instantiates every unit in the rendered graph, so a break anywhere in the library or the generated
Nix fails `nix flake check` without compiling a crate. Building it is the rendered `units.nix`.

There is no overlay. The library needs a Rust toolchain argument, so it cannot be a plain
attribute on a `pkgs`, and an overlay carrying only the CLI would be a second way to reach what
`packages` already exposes.

The only other input is `advisory-db` (`flake = false`), the RustSec database that
`policy.cargoAudit` checks a lockfile against. It is an input rather than a rev and hash
maintained in-tree, so `nix flake update advisory-db` bumps it and consumers inherit the pin
through the lock; `mkCargoUnit` passes it down as the `cargoAudit.db` default. It is forced only
when an audit check is, so a graph with the gate off never fetches it.

`Cargo.toml` declares an **empty `[workspace]`**, with the reason stated: this is the bootstrap tool
that renders Cargo unit graphs as Nix, so it cannot be built through its own output. Keeping it a
self-contained crate with its own lockfile means vendoring it into a larger repo never folds it into
that repo's workspace, and a lock bump elsewhere never invalidates its Nix build.

Lints are aggressive: `warnings`, `clippy::all`, `pedantic`, `nursery`, and `cargo` all set to
`deny`, with only `multiple_crate_versions` allowed. The group-priority ordering is commented,
because Cargo emits `lint_groups_priority` errors otherwise.

---

## 19. Sharp edges

**`checkedRoots` is not applying its function.** `render_checked_roots` (`render.rs:3131`) joins
entries with a space into the template's `checkedRoots = [ {{ checked_roots }} ];`, producing:

```nix
checkedRoots = [ withPolicyChecks units."hello-0.1.0-e7d39f058b269996" ];
```

In Nix, whitespace separates list elements and function application needs parentheses, so this
evaluates to a two-element list `[ <lambda> <derivation> ]` rather than one policy-checked
derivation — and with N roots it yields 2N elements. `render_panic_freedom_check` gets the same
construct right (`(scanUnit … …)` inside `paths = [ … ]`), and `render_default_entry` is fine
because it isn't in a list. No test asserts on `checkedRoots`. The fix is to wrap each entry in
parentheses. (Nix isn't installed on this machine, so I couldn't confirm by evaluation — this is
from the language's list/application semantics and the contrast with the two sites that handle it
correctly.)

**Textual `include!` scanning** can match inside comments and string literals. Harmless by design —
a spurious directory disappears at the Nix filter — but it means the source closure is an
over-approximation, not an exact set.

**`CARGO_INVOKING_BUILD_DEPS` is a hand-maintained allowlist.** A build script that shells out to
`cargo metadata` without depending on `cbindgen` will fail on DNS inside the sandbox, and the fix is
to add its marker crate to that list.

**`PANIC_SINKS` is likewise curated** and explicitly incomplete. Adding a std cold path is a
one-line change; knowing you need to is the hard part.

**`fill_template` panics** on an unknown or unterminated placeholder. That is intentional — the
template ships inside the binary — but it means a typo in a slot name is a runtime abort, not a
compile error.

---

## 20. Reading order

If you're picking this up cold:

1. `model.rs::Unit::identity_hash` — the abstraction everything else hangs off.
2. `render.rs::render_units_nix` → `prepare_graph` — the shape of the whole pass.
3. `templates/units.nix.in` — read top to bottom; it's the output contract.
4. `render_driver_build_phase` + `render_install_phase` — one unit, end to end.
5. `render_build_script_run_phase` — the hardest part, and where the Cargo-compatibility bodies
   are buried.
6. `panic_scan.rs` — self-contained; readable in one sitting.

The comments throughout are unusually load-bearing. Many encode a specific upstream bug, an
observed CI failure, or a rejected alternative (`NixOS/nix#15649`, `briansmith/ring#715`,
rustc's "Relink, don't Rebuild" goal, the `rusty_v8` lock path, the darwin orphan-output failure).
Deleting one usually deletes the only record of why the surrounding code is shaped that way.
