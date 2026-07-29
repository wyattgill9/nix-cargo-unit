# How crate2nix Works: A Deep Technical Guide

## TL;DR
- **crate2nix generates a `Cargo.nix` Nix expression that builds a Rust project one derivation per crate** by reading `Cargo.toml`/`Cargo.lock`, running `cargo metadata`, prefetching source hashes, and rendering a Tera template; the generated file is then consumed with nixpkgs' `buildRustCrate`, which invokes `rustc` directly (bypassing cargo) so Nix rebuilds and caches only the crates that actually changed.
- **Its defining advantage over `buildRustPackage` (monolithic, cargoHash-vendored), naersk, and crane (two-derivation dep-blob + crate) is per-crate granularity**: individual crate derivations are shared across projects, cached in binary caches, and rebuilt incrementally — at the cost of a large generated file (or IFD) and known rough edges around build scripts, cross-compilation, and proc-macros.
- **As of 2026, crate2nix is under the nix-community umbrella and saw a revival with v0.15.0 (Jan 28, 2026, "after almost 2 years")**, adding private-registry support (#366, @P-E-Meunier), a selectable toolchain in `generatedCargoNix` (#390, @bengsparks), an `extraTargetFlags` cfg parameter (#416), and an experimental `--format json` output; devenv's Domen Kožar adopted it in July 2025 for `languages.rust.import` ("We evaluated the available tools and chose crate2nix, so you don't have to"), but it still carries limitations and depends critically on the continued maintenance of `buildRustCrate` in nixpkgs.

## Key Findings

- crate2nix was authored originally by Peter Kolloch (@kolloch), grew out of frustration with `carnix`, and now lives at `github.com/nix-community/crate2nix` (formerly `kolloch/crate2nix`). It is dual-licensed Apache-2.0/MIT.
- It does not replace cargo for local development — you keep using `cargo` and `rust-analyzer` — it only generates Nix build files for reproducible/CI builds.
- The generated `Cargo.nix` exposes `rootCrate.build` (single binary/root crate) and `workspaceMembers.<name>.build` (workspaces), plus overridable `features`, `crateOverrides`, and `buildRustCrateForPkgs`.
- crate2nix relies entirely on nixpkgs' `buildRustCrate`, which compiles each crate with a direct `rustc` invocation and runs `build.rs` build scripts in the `configurePhase`. This is both its greatest strength (granularity, purity) and its main source of incompatibilities.
- The two big architectural choices users must make: (1) commit `Cargo.nix` (no IFD, full build parallelism, must regenerate on dep changes) vs. use Import-From-Derivation via `tools.nix` (`appliedCargoNix`) to auto-generate at eval time (always in sync, but IFD serializes evaluation and is banned in nixpkgs); and (2) which feature set to bake into the generated file.

## Details

### 1. Purpose and motivation

**The problem.** Building Rust with Nix requires reconciling two package managers. Cargo resolves the dependency graph, downloads crates, resolves features, and drives `rustc`. Nix wants pure, sandboxed, content-addressed, cacheable derivations with no network access at build time. The Rust-on-Nix tooling landscape is essentially different answers to "how much of cargo's job do we hand to Nix, and at what granularity."

**Why per-crate derivations are desirable.** If every crate is its own derivation:
- **Caching / incremental rebuilds:** changing one dependency (or one workspace crate) invalidates only that crate's derivation and its reverse-dependencies, not the whole build. crate2nix's own docs describe this verbatim as: "Smart caching: It caches the builds of individual crates so that nix rebuilds exactly the crates that need to be rebuilt. Compare that to docker layers…"
- **Cross-project sharing:** identical crate derivations (same version, features, compiler) can be shared between projects and served from a binary cache (e.g. cachix). As the jia.je Rust-on-Nix comparison (Aug 2022) puts it, the advantage of per-dependency granularity (cargo2nix, crate2nix, nocargo) over all-dependencies-in-one (crane, naersk) is that the dependencies are shared across projects and can further be pushed to a binary cache.
- **Purity / sandboxing:** each crate is built in a sandbox with only its declared inputs; sources are fetched by Nix fetchers from pinned hashes, never at build time.

**How it differs from the alternatives (with tradeoffs):**

- **nixpkgs `buildRustPackage` (with vendored cargo deps + `cargoHash`/`cargoSha256`):** The built-in nixpkgs builder. It runs cargo wholesale in one monolithic derivation, vendoring all dependencies into a single fixed-output derivation keyed by a `cargoHash` (SRI) / older `cargoSha256`. Tradeoffs: simplest, the only option accepted for packages upstreamed into nixpkgs, but **no incremental caching** — any source or dependency change triggers a full rebuild — and the `cargoHash` must be regenerated whenever `Cargo.lock` changes (build with `lib.fakeHash`, let it fail, copy the correct hash). nixpkgs 25.05 migrated from `fetchCargoTarball` to `fetchCargoVendor`, breaking some override patterns. Good for packaging releases, painful for active development. Uses cargo internally, so feature/build-script behavior matches cargo exactly.
- **naersk:** Uses cargo to drive the whole build. Builds all dependencies in one derivation and the crate itself in another (a two-derivation model). No IFD, no code generation, no hash prefetching (relies on `Cargo.lock` hashes), sandbox-friendly. Tradeoff: coarse caching — if any dependency changes, the whole dependency blob rebuilds; less composable than crane. Widely viewed as superseded by crane for new projects.
- **crane:** Also cargo-driven and two-derivation (deps blob + crate), but designed for composability: you can have separate cached derivations for clippy, tests, coverage, the dep build, etc., all sharing the cached dependency artifacts. Tradeoff: still rebuilds all dependencies as a unit (no per-crate granularity), but is the current community favorite for ergonomics and is actively maintained (by Ivan Petkov). The Tweag comparison calls crane an improvement over naersk because "it delegates all the hard parts to Cargo."
- **cargo2nix:** Per-crate derivations like crate2nix, but uses its own custom build logic instead of `buildRustCrate`, and has flake support built-in. It has somewhat better cross-compilation than crate2nix. Tradeoff: niche, less actively maintained, with known Rust 2024-edition issues.
- **dream2nix:** A generic multi-language framework; its Rust modules are all marked experimental, and multiple sources (including juspay's rust-flake docs) warn against it for production Rust.
- **carnix (historical):** The original crate-granularity generator, widely used in nixpkgs itself and the reason `buildRustCrate` exists; unmaintained since 2019 and removed from nixpkgs. crate2nix was started after attempts to fix carnix failed.

The Tweag summary: if you have a simple app, `buildRustPackage` may be all you need; but the other tools give faster builds by splitting code and deps into separate derivations. crate2nix and cargo2nix go furthest with per-crate derivations.

### 2. Core workflow / architecture

**How `crate2nix generate` works.** The Rust binary runs an explicit pipeline (documented in the "Project Overview & Terminology" design page):
1. **cargo metadata** — calls `cargo metadata` via the `cargo_metadata` crate to obtain the exact same resolved dependency tree cargo would use, respecting `Cargo.lock`.
2. **indexing metadata** — indexes packages by package ID to join cargo's "Node" (resolve) and "Package" (manifest) information into a `metadata::IndexedMetadata`.
3. **resolving** — joins the indexed metadata into per-crate `resolve::CrateDerivation` records (all the build info a crate needs).
4. **pre-fetching** — determines each crates.io package's sha256, using hashes from `Cargo.lock` when present (since v0.6.x) and otherwise prefetching with `nix-prefetch-url`; results cached in `crate-hashes.json`.
5. **rendering** — renders everything through the `crate2nix/templates/build.nix.tera` Tera template into `Cargo.nix`.

The internal crate modules mirror these phases: `metadata`, `resolve`, `prefetch`, `render`, plus `nix_build` (invoking `nix-build`), `config` (managing `crate2nix.json`), and a `sources`/workspace module for out-of-tree sources. The tool needs `cargo` and `nix-prefetch-url` on `PATH` at generation time.

**Feature selection at generation.** By default only default-feature dependencies are included. Use `crate2nix generate --all-features` for the most general file, or `--no-default-features --features "f1 f2"` to strip it down. Note features are further resolved **at build time** in the generated Nix (see below), which lets you override them without regenerating.

**What the generated `Cargo.nix` contains.** The file is a function (historically called via `callPackage`, now recommended as `import ./Cargo.nix { inherit pkgs; }`) that returns an attribute set. Its structure:

- A top-level `crates` attribute set (marked `internal`) with **one entry per resolved crate**, keyed by package ID (just the crate name if unique, else name+version, else a fuller opaque ID). Each entry maps largely one-to-one to `buildRustCrate` arguments. A real snippet from crate2nix's own `Cargo.nix`:

```nix
"crate2nix" = rec {
  crateName = "crate2nix";
  version = "0.15.0";
  edition = "2021";
  crateBin = [
    { name = "crate2nix"; path = "src/main.rs"; requiredFeatures = [ ]; }
  ];
  src = lib.cleanSourceWith { filter = sourceFilter; src = ./.; };
  authors = [ "Peter Kolloch <info@eigenvalue.net>" ];
  dependencies = [
    { name = "anyhow"; packageId = "anyhow"; }
    { name = "cargo_metadata"; packageId = "cargo_metadata"; }
    { name = "itertools"; packageId = "itertools 0.12.1"; }
    # ...
  ];
};
```

For a crates.io crate, the entry also carries `sha256` (in nix-base32) and, importantly, may carry `buildDependencies` (for `build.rs`), `devDependencies` (used for tests only), `features` maps, `procMacro = true`, `links`, `libName`/`libPath`, `type` (e.g. `cdylib`), and `crateRenames`. The generated file's own comments note: "`dependencies`/`buildDependencies`: similar to the corresponding fields for buildRustCrate but with additional information which is used during dependency/feature resolution; `resolvedDependencies`: the selected default features reported by cargo — only included for debugging; `devDependencies` as of now not used by buildRustCrate but used to inject test dependencies."

- Convenience public attributes:
  - `rootCrate.build` — the derivation for the single root crate (only present for non-workspace/single-binary projects). `rootCrate.build.override { features = [ ... ]; }` overrides features.
  - `workspaceMembers.<crateName>.build` — the derivation for each workspace member. There is no single root crate for a workspace.
  - `allWorkspaceMembers` — (in the JSON consumer) all members linked together.
  - Debug helpers under `.debug` (explicitly unstable).
- Arguments the whole file accepts: `pkgs`, `rootFeatures` (override root feature set from the command line via `--arg rootFeatures '["default" "other"]'`), `buildRustCrateForPkgs` (to swap in a customized `buildRustCrate`, e.g. for a custom toolchain or crate overrides), and a deprecated `buildRustCrate` argument that now emits a warning.

**How it's consumed.** Typical usage:
```nix
let cargo_nix = import ./Cargo.nix { inherit pkgs; };
in cargo_nix.rootCrate.build            # single binary
# or: cargo_nix.workspaceMembers."my-crate".build   # workspace member
```
Or from the command line: `nix build -f Cargo.nix rootCrate.build` → `./result/bin/<crate>`.

**The role of `buildRustCrate`.** crate2nix generates data; `buildRustCrate` (in `pkgs/build-support/rust/build-rust-crate/`) does the actual building. Unlike `buildRustPackage`, `buildRustCrate` **does not run cargo** — it emulates cargo by invoking `rustc` directly for each crate, one crate per derivation. Implications:
- It's essentially a faithful reimplementation of cargo's compilation model in Nix + bash, so it can drift from cargo's actual behavior (edition flags, prelude changes, build-script directive handling). This is the root cause of most crate2nix incompatibilities.
- It gives Nix full control over the dependency graph, so per-crate caching and cross-project sharing work.
- `buildRustCrate` doesn't support `nix-shell` dev workflows directly (nixpkgs recommends `stdenv.mkDerivation` for dev shells).
- `buildRustCrate` was introduced in 2017 for carnix; since carnix's removal, crate2nix is essentially its only significant consumer. nixpkgs PR #373744 documents that "nixpkgs is currently in progress of removing all occurrences of Cargo.lock" (motivated by @Atemu in #327063, enabled by @TomaSajt's `rustPlatform.fetchCargoVendor` in #349360), and raises that "it may be in crate2nix's own interest to continue maintenance of buildRustCrate inside their own repository."

**How `build.rs` build scripts are handled.** Confirmed from the `buildRustCrate` source (`configure-crate.nix`), build scripts run in the **`configurePhase`**, bracketed by `preConfigure`/`postConfigure` hooks:
1. The build script is detected (via the `build` attribute or an existing `build.rs`) and compiled to a bin named `build_script_build` with `rustc --crate-type bin`, linked only against build dependencies in `target/buildDeps`.
2. It's executed with cargo environment variables exported first: `OUT_DIR=$(pwd)/target/build/<crateName>.out`, `CARGO_MANIFEST_DIR=$(pwd)`, `CARGO_MANIFEST_LINKS=<links>`, the full `CARGO_PKG_*`, `CARGO_CFG_TARGET_*`, `TARGET`, `HOST`, `PROFILE`, `NUM_JOBS`, `RUSTC`, plus `CARGO_FEATURE_<NAME>=1` per feature.
3. Its stdout is captured (`tee target/build/<crateName>.opt`) and parsed with `sed` for the `cargo:`/`cargo::` directives: `rustc-cfg=` → `--cfg`, `rustc-link-lib=`, `rustc-link-search=`, `rustc-link-arg=` → `-C link-arg`, `rustc-flags=`, and `rustc-env=` (exported as env vars). `rerun-if-changed`/`rerun-if-env-changed` are deliberately filtered out (Nix decides rebuilds by input hashing, not cargo's rerun tracking).
4. `links`-based metadata is propagated: `cargo::metadata=key=value` / `cargo:key=value` lines are turned into `DEP_<NAME>_<KEY>` (and versioned `DEP_<NAME>_<VERSION>_<KEY>`) env vars written to a `target/env` file, which downstream crates `source` when they link that dependency (matching cargo's `-sys` crate convention).

Build dependencies vs. regular dependencies are handled distinctly and per platform: regular `dependencies` are symlinked into `target/deps`; `buildDependencies` into `target/buildDeps`; the build script links against build deps only. `depsBuildBuild = [ pkgsBuildBuild.stdenv.cc ]` guarantees a build-platform C compiler for build scripts, and proc-macros/build scripts are compiled for the **build** platform (dylib extension chosen from `stdenv.buildPlatform`), while the crate itself targets `stdenv.hostPlatform` (`--target` added only when host ≠ build).

**Known build-script limitations:**
- **No network access** in the Nix sandbox — the nixpkgs Rust docs state "Since network access is not allowed in sandboxed builds, Rust crate dependencies need to be retrieved using a fetcher." Build scripts that download things fail. This is a hard sandbox constraint, not a crate2nix bug.
- **Historically, `cargo:rustc-*` directives from build scripts were ignored** by `buildRustCrate` (nixpkgs issue #119382 / crate2nix #180); current master honors them, but older nixpkgs pins may not.
- A crate only has access to **its own source directory** at build time, not sibling directories in the same workspace (crate2nix issue #17), so build scripts reading files elsewhere in the workspace break.
- Concrete failures reported: `CARGO_MANIFEST_DIR`-based metadata lookups (crate2nix #26); the `anyhow` crate whose `build.rs` overwrites `lib.rs` with a probe (nixpkgs #74071); missing native tools like `protoc` needing a crate override (crate2nix #66); glib resource compilation in `build.rs` (Discourse).

**Source fetching.** `sourceType` in `tools.nix` classifies each package's `source`: `null` → local path dependency (uses the project `src`); `registry+https://github.com/rust-lang/crates.io-index` → crates.io (fetched by hash); `git+…` → git dependency. For crates.io deps, crate2nix prefers the sha256 already recorded in `Cargo.lock` (`extract_hashes_from_lockfile` converts the hex checksum to nix-base32) and only prefetches (via `nix-prefetch-url`) when a hash is missing, caching results in `crate-hashes.json`. `tools.nix` unpacks each fetched tarball and writes a synthetic `.cargo-checksum.json` (`{"package":"<sha256>","files":{}}`) so the build looks like a normal cargo registry checkout. **Git dependencies** are supported (including submodules since 0.7 and crates in git subdirectories); **path dependencies** resolve against the local source tree. Custom/private registries were only added in v0.15.0 (PR #366).

**Workspace support.** Applied to a Cargo workspace, the generated file exposes `workspaceMembers.<name>.build` for each member (there is no `rootCrate`). Workspace support dates to v0.1.0.

**Feature-flag resolution and resolver versions.** A key design decision: **features are resolved at build time inside the generated Nix**, not baked statically, so regeneration isn't needed to change features — you override `rootFeatures` or `.override { features = [...]; }`. crate2nix's docs explicitly note "features in crate2nix are resolved at build time so that every dependency is built only with the features necessary for the specific binary," which prevents over-unification build problems. crate2nix derives its feature/target data from `cargo metadata`, so it inherits cargo's resolver behavior (v1 unifies features across the whole graph; v2/resolver="2", default in edition 2021, avoids unifying features across build-deps/proc-macros, target-specific deps for non-built targets, and dev-deps). Conditional feature selections `foo?/bar` are supported since v0.11.0. A relevant sharp edge: non-existent feature references inside `target.'cfg(...)'` sections can cause Nix evaluation failures (crate2nix #141), and target-specific features do not activate automatically (#129) — you enable them manually.

**Cross-compilation, target-specific deps, cfg().** `cfg(...)` expressions and target triples are translated into Nix expressions at generation time; support is "reasonable but incomplete" (e.g. processor-feature cfgs). Since v0.11.0 crate2nix uses nixpkgs' Rust `lib` for cfg resolution, Rust-style (not nixpkgs-style) configs for `[target."cfg(...)"]` sections, and supports custom `cfg(target_family=...)` deps; v0.11–0.14 brought several cross-compilation fixes (e.g. build-dependencies resolution when cross-compiling, #372). Cross-compilation is still considered the weakest area relative to cargo2nix, and cross-compiling projects with proc-macros remains awkward (#397).

**crateOverrides / defaultCrateOverrides.** Native (non-Rust) dependencies are handled through `buildRustCrate`'s override mechanism. nixpkgs ships `defaultCrateOverrides` (in `pkgs/build-support/rust/default-crate-overrides.nix`) with `buildInputs`/`nativeBuildInputs` for many popular crates (openssl, pkg-config-driven `-sys` crates, etc.). To patch a crate not covered, you override `buildRustCrateForPkgs`:
```nix
let
  customBuildRustCrateForPkgs = pkgs: pkgs.buildRustCrate.override {
    defaultCrateOverrides = pkgs.defaultCrateOverrides // {
      funky-things = attrs: { buildInputs = [ pkgs.openssl ]; };
    };
  };
  generatedBuild = callPackage ./Cargo.nix {
    buildRustCrateForPkgs = customBuildRustCrateForPkgs;
  };
in generatedBuild.rootCrate.build
```
Overrides aren't limited to `buildInputs` — you can add patches, `preConfigure` (runs before the build script), `postPatch`, etc., since these are ordinary `buildRustCrate`/derivation phases.

### 3. Practical usage

**Typical commands:**
```
# one-off without installing
nix run nixpkgs#crate2nix -- generate
nix build -f Cargo.nix rootCrate.build

# install
nix profile install nixpkgs#crate2nix               # from nixpkgs
nix profile install github:nix-community/crate2nix   # latest

# in the project
crate2nix generate            # creates Cargo.nix (reads Cargo.toml/Cargo.lock)
crate2nix generate --all-features
crate2nix generate --format json   # experimental: emits Cargo.json instead
```

**Flake integration.** A flake template exists: `nix flake init --template github:nix-community/crate2nix`. The `tools` flake output exposes `generatedCargoNix` and `appliedCargoNix` per system. With flake-parts:
```nix
perSystem = { system, pkgs, ... }:
  let
    cargoNix = inputs.crate2nix.tools.${system}.appliedCargoNix {
      name = "rustnix";
      src = ./.;
    };
  in {
    checks.rustnix = cargoNix.rootCrate.build.override { runTests = true; };
    packages.default = cargoNix.rootCrate.build;
  };
```
`generatedCargoNix { name; src; cargoToml?; additionalCargoNixArgs?; }` produces a folder with a `default.nix`; `appliedCargoNix` also `callPackage`s it with the provided `pkgs`. v0.15.0 added the ability to pass a selected toolchain (PR #390) so edition-2024 projects can use a newer cargo than `pkgs.cargo`.

**devenv integration.** As of July 2025 devenv wraps all of this behind `config.languages.rust.import`, which per devenv.sh's docs "takes a path to a directory containing a Cargo.toml file and returns a derivation that builds the Rust project using crate2nix." You add the input with `devenv inputs add crate2nix github:nix-community/crate2nix --follows nixpkgs` and then `myapp = config.languages.rust.import ./app {};`.

**`tools.nix` / IFD-free vs IFD.** `tools.nix` reads `Cargo.lock` directly in Nix, fetches the locked crates purely by their recorded hashes, builds a vendored directory, and then runs `crate2nix` offline inside a derivation to produce `Cargo.nix`, which is then imported via IFD. This keeps `Cargo.nix` always in sync with `Cargo.lock` without committing it. The tradeoff is IFD, which forces Nix to build the generator derivation during evaluation and can reduce/serialize build parallelism — and IFD is **disallowed inside nixpkgs**, so IFD-based projects can never be upstreamed. A known IFD limitation: `overrideAttrs` doesn't propagate to the real package (nix issue #4265 workaround), and IFD generation historically failed with git dependencies (crate2nix #348).

**Regenerating on dependency changes.** With the committed-`Cargo.nix` (manual) strategy, you must re-run `crate2nix generate` (and commit the result) whenever `Cargo.lock` changes — a repo helper `regenerate_cargo_nix.sh` exists. With the IFD strategy this is automatic.

**CI usage.** The headline CI benefit is incremental rebuilds: push per-crate derivations to a binary cache (crate2nix's own CI uses `eigenvalue.cachix.org`) so CI only rebuilds crates whose inputs changed. This is the main reason to prefer per-crate granularity for long-lived projects.

**Committing `Cargo.nix` vs IFD — the debate.** The community position: commit `Cargo.nix` for maximum build parallelism, no IFD, and nixpkgs compatibility, accepting the chore of regeneration; use IFD (`appliedCargoNix`) for convenience and guaranteed sync when you don't upstream and can tolerate reduced parallelism. crate2nix documents both as first-class "generation strategies," summarizing: Manual (`crate2nix generate`) → no IFD, full build parallelism, must regenerate when deps change; Auto (IFD) → always in sync with `Cargo.lock`, may reduce parallelism.

### 4. Codebase internals

- **Language split:** ~70% Nix, ~29% Rust, plus shell. The Rust binary does generation; the Nix (templates + `tools.nix` + generated file) does building.
- **Rust modules** (per the design docs and docs.rs): `metadata` (cargo metadata + `IndexedMetadata`), `resolve` (`CrateDerivation` join), `prefetch` (sha256 discovery, `extract_hashes_from_lockfile` + `nix_base32` conversion), `render` (Tera), `nix_build` (invoking `nix-build`), `config` (`crate2nix.json`, `GenerateConfig`/`GenerateInfo` with `use_cargo_lock_checksums`, `output`, `crate-hashes.json` path), a workspace/sources module for out-of-tree sources, and a `util`/"homeless code" module.
- **Templating:** the single Tera template `crate2nix/templates/build.nix.tera` renders the whole `Cargo.nix`. crate2nix advertises this as a feature — "the actual nix code is generated via crate2nix/templates/build.nix.tera so you can fix/improve the nix code without knowing rust if all the data is already there." Nix-level unit tests live under `templates/nix/crate2nix/tests` and are invoked by `cargo test`.
- **Repo layout:** `crate2nix/` (the Rust crate + its own meta `Cargo.nix`), `lib/` (including `build-from-json.nix` for the JSON consumer), `nix/`, `tools.nix`, `default.nix`, `flake.nix` (flake.parts-based), `templates/flake-binary`, `sample_projects`, `sample_workspace`, `docs/` (Starlight-based GitHub Pages site).
- **JSON output (experimental):** `crate2nix generate --format json` writes `Cargo.json` with all resolution (feature expansion, cfg() filtering, optional-dep activation) done in Rust, so `lib/build-from-json.nix` is a trivial data consumer avoiding "O(n×m) eval-time logic" on the Nix side — a response to eval-time performance problems on large dependency trees.

### 5. Current status (2026), history, pitfalls

**Status & maintenance.** crate2nix moved from `kolloch/crate2nix` to `nix-community/crate2nix` (≈498 stars, 118 forks at time of writing). For several years Kolloch repeatedly asked for co-maintainers ("Help needed! I don't have the resources to meaningfully advance this project"), and @andir became an additional maintainer around 0.8.0. After a long quiet period the project revived: **v0.15.0 was released 2026-01-28, announced on NixOS Discourse as "crate2nix 0.15.0 after almost 2 years."** In July 2025 devenv's Domen Kožar adopted crate2nix as the engine behind the new `languages.rust.import` function, stating "We evaluated the available tools and chose crate2nix, so you don't have to."

**Version-history highlights:**
- 0.1.0 — initial release; workspace support and target-specific deps followed.
- 0.2.x–0.3.x — git-source dependencies; `libName != crateName`; `libPath` for proc-macros.
- 0.4.0 — **dynamic (build-time) feature resolution**; renamed attributes to `rootCrate.build` / `workspaceMembers.<n>.build`.
- 0.6.x–0.7.x — use hashes from `Cargo.lock` instead of prefetching; renamed-crate support; multiple binaries; git submodule prefetch; cdylib; crates in git subdirs; experimental test running.
- 0.9.0–0.10.0 — new "calling convention" (`import` over `callPackage`); indirect optional-feature activation; `testPreRun`/`testPostRun`.
- 0.11.0 — `foo?/bar` conditional features; removed the `buildRustCrate` arg; better cross/platform cfg handling; flake.nix.
- 0.13.0 — GitHub Pages docs; `tools` exported as a flake attribute; build flakified with flake.parts.
- 0.14.0/0.14.1 (2024-06-30) — Rust 1.77 lock-file compatibility; moved sources into `/build/sources`; cross-compilation fixes; `rust.lib` → `stdenv.hostPlatform.rust`.
- 0.15.0 (2026-01-28) — private registries (#366, @P-E-Meunier); selectable toolchain in `generatedCargoNix` (#390, @bengsparks); `extraTargetFlags` for custom cfg (#416); numerous fixes (cross build-deps #372, aliased git deps #391, v1-manifest checksum parsing, git deps with wildcard workspace members #394); experimental JSON output.

**Known limitations / common pitfalls:**
- **proc-macros:** historical prelude mismatch — cargo auto-adds `--extern proc_macro` (rust-lang/cargo#7700) and dropped the need for `extern crate proc_macro`; `buildRustCrate` had to catch up (crate2nix #113), and cross-compiling projects with proc-macros remains awkward (#397).
- **build scripts:** network access blocked in sandbox; historically ignored `cargo:rustc-*` directives; workspace-sibling file access unavailable; specific crates (anyhow, protoc-based, glib) need overrides.
- **target/cfg edge cases:** non-existent feature refs in `target.'cfg(...)'` cause eval failures (#141); target-specific features don't auto-enable (#129).
- **cross-compilation:** weaker than cargo2nix, though improving.
- **custom registries:** only supported from v0.15.0.
- **file size:** generated `Cargo.nix` can be tens of thousands of lines for big projects (one reason nixpkgs won't accept it); large trees historically caused super-linear Nix instantiation (mitigated).
- **per-crate sharing in practice:** different feature-flag combinations across projects prevent deduplication, so cross-project cache sharing is more limited than the theory suggests.
- **no-std / bare-metal:** building `compiler_builtins`/`std`-less targets fails without extra setup (#126).
- **IFD:** breaks `overrideAttrs`, disallowed in nixpkgs, and can serialize evaluation.

## Recommendations

1. **Choosing a tool.** For a package you intend to upstream into nixpkgs, use `buildRustPackage` (the only accepted option). For most application/service builds where you want fast incremental Nix builds and don't need per-crate sharing, **crane** is the pragmatic, well-maintained default. **Choose crate2nix specifically when you want true per-crate derivations** — long-lived projects with large dependency trees, CI that benefits from rebuilding only changed crates, or when you want to populate a shared binary cache at crate granularity. devenv users get crate2nix automatically via `languages.rust.import`.
2. **Generation strategy.** Start by **committing `Cargo.nix`** (run `crate2nix generate`, check it in, wire a CI check or pre-commit hook / `regenerate_cargo_nix.sh` to keep it fresh). This avoids IFD, maximizes parallelism, and keeps the door open to nixpkgs. Switch to IFD (`appliedCargoNix`) only if regeneration churn becomes painful and you never plan to upstream. Threshold to flip: if `Cargo.nix` regeneration diffs dominate your PR noise and your eval time stays acceptable, move to IFD; if IFD serializes your CI builds or you hit the `overrideAttrs` limitation, move back to committed files.
3. **Handling native deps.** Before writing overrides, check whether the crate is already in `defaultCrateOverrides`. If not, add a `crateOverride` via `buildRustCrateForPkgs` with the needed `buildInputs`/`nativeBuildInputs` (openssl, pkg-config, protobuf, etc.). Keep overrides in a small shared file.
4. **Features.** Generate with the feature set you actually ship; since features resolve at build time you can still override per-build with `.override { features = [...]; }` without regenerating. Use `--all-features` only if you genuinely need the fully general file.
5. **Toolchain / editions.** On edition 2024 or a custom toolchain, pass an explicit `cargo`/toolchain (v0.15.0 `generatedCargoNix` toolchain arg, or a `rustc`/`cargo` overlay) rather than relying on `pkgs.cargo`.
6. **Watch the `buildRustCrate` dependency.** Since crate2nix is the primary consumer of `buildRustCrate` and nixpkgs (PR #373744) has floated deprecating `Cargo.lock`-based infra in favor of `rustPlatform.fetchCargoVendor`, pin a known-good nixpkgs (crate2nix tracks nixpkgs-unstable via `nix/sources.json`) and follow the nix-community repo for maintenance signals before committing a large project to it.

## Caveats

- crate2nix is only as compatible as `buildRustCrate`; because that builder reimplements cargo's compilation model rather than calling cargo, some crates that build fine under `buildRustPackage`/crane will need overrides or fail under crate2nix. Test your full dependency tree before adopting.
- The maintenance trajectory is uneven: a ~2-year gap preceded v0.15.0. The 2025 devenv adoption and the 0.15.0 burst of contributor activity are positive signals, but this is a small-team community project, not a vendor-backed product.
- Several details above (exact module names, phase mechanics) are drawn from the `buildRustCrate` source and crate2nix design docs on `master`; specific line-level behavior can change between nixpkgs revisions, and older nixpkgs pins exhibit older behavior (e.g. ignored build-script directives).
- One search result surfaced during research (an "anthropics/cargo-nix-plugin" repo) could not be corroborated as an authentic, authoritative crate2nix-related project and was excluded from this report.
- Star/fork counts and some ecosystem-comparison judgments (e.g. "crane is the community favorite," relative maintenance of cargo2nix/dream2nix) reflect secondary sources and community sentiment as of late 2025/early 2026, not hard metrics.
