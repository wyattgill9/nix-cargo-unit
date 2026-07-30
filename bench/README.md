# `bench/` — rust-analyzer, one Cargo unit at a time

Two things carry the benchmark:

| Path | What it is |
|---|---|
| `flake.nix` | the whole benchmark: one `cargoUnit.buildWorkspace` call |
| `rust-analyzer/` | a **git submodule** of `rust-lang/rust-analyzer`, untouched |

No generator script, no checked-in generated Nix, no patch against the
submodule, and no step you have to remember to re-run. The flake takes
rust-analyzer's `Cargo.lock` and source tree and produces one Nix derivation per
Cargo compilation unit.

## Build it

The submodule has to be checked out, and the flakeref has to carry it:

```console
$ git submodule update --init bench/rust-analyzer
$ nix build "git+file://$PWD?submodules=1&dir=bench"
$ ./result/bin/rust-analyzer --version
rust-analyzer 0.0.0
```

`nix build ./bench` resolves to a plain `git+file://` fetch of this repository,
and Nix's git fetcher skips gitlinks unless asked for them — so `rust-analyzer/`
arrives empty. `flake.nix` checks for that and fails with the two commands
above rather than letting cargo report a missing manifest a hundred lines later.

`nix build "path:$PWD/bench"` does copy the submodule (a `path:` fetch is a
verbatim directory copy), but then the `path:..` input resolves against the
standalone store copy instead of the repository root, so it is not a way out.

| Attribute | What it is |
|---|---|
| `#default`, `#workspace` | every workspace root merged into one tree |
| `#rust-analyzer` | the LSP binary alone |
| `#rust-analyzer-proc-macro-srv` | the proc-macro server binary |
| `#plannerSource`, `#unitGraphJson`, `#unitsNix`, `#vendorDir`, `#rustToolchain` | pipeline stages, for looking at a planning or render problem directly |
| `#units.'"syntax-0.0.0-<hash>"'` | a single compilation unit |
| `#packages`, `#binaries`, `#libraries`, `#targetSets` | the rendered per-package / per-target sets |
| `checks.<system>.smoke` | runs `--version` and `parse` against the built binary |

The flat derivations sit in `packages.<system>`; the nested sets sit in
`legacyPackages.<system>`, which is where `nix build .#<attr>` falls through
to, so every spelling above works as written while `nix flake show` and
`nix flake check` stay well-formed.

## The flake

`flake.nix` is one call. The pipeline is `../nix`'s, not this file's:

```nix
cargoUnit = nix-cargo-unit.lib.mkCargoUnit {
  inherit pkgs rustToolchain;
};

graph = cargoUnit.buildWorkspace {
  pname = "rust-analyzer";
  src = ./rust-analyzer;
  workspaceRoot = ./rust-analyzer;
  profile = "release";
  policy = cargoUnit.policyPresets.pureBuild;
  contentAddressed = false;
};
```

`mkCargoUnit` is `../nix`, and it needs only the two things the flake cannot
decide for a consumer: which nixpkgs, and which Rust toolchain. It builds the
renderer binary from that `pkgs` itself (`../nix/package.nix`), so nothing here
indexes an input by system. Behind it, `../nix/workspace.nix` composes
`vendor.nix` (Cargo.lock → package-shaped vendor tree), `policy.nix` (the
quality gates, the linker choice and the test-runner settings) and `graph.nix`
(the two IFD stages):

```
Cargo.lock ──> vendorDir ─┐
                          ├─> cargo build --unit-graph ──> unitGraphJson
src ──> plannerSource ────┘                                     │
                                nix-cargo-unit render ──────> unitsNix
                                                                │ IFD
                                              one derivation per compile unit
```

1. **Vendor** (`nix/vendor.nix`). Each external crate in `Cargo.lock` becomes
   its own derivation — a `fetchurl` of the `.crate` tarball, unpacked, plus a
   `.cargo-checksum.json`. A unit therefore depends on its own tarball, not on
   the whole vendor tree; `vendorDir` is the aggregate `linkFarm` for the two
   consumers that need a directory. rust-analyzer's lockfile is all registry
   crates, so no `outputHashes` entries are needed.
2. **Plan.** `cargo build --workspace --unit-graph` runs offline. Nothing is
   compiled; cargo only resolves features and enumerates units.
3. **Render.** `nix-cargo-unit render` turns that JSON into a Nix function.
4. **Build.** The function is imported (import-from-derivation) and applied, and
   Nix schedules the units.

## Why the flake looks the way it does

**The pipeline is not spelled out here.** The previous version of this bench
open-coded vendoring, the `cargo --unit-graph` invocation and the `render` call
in its own `flake.nix`. All three now come from `../nix`, so the bench measures
the API consumers actually get, and a change to vendoring or policy shows up
here without an edit.

**Planning runs in a stub tree, not in `src`.** `buildWorkspace` derives a
`plannerSource` from `src`: manifests verbatim, every other file an empty stub
at its exact relative path. Cargo's planner reads manifests by content and
targets by existence, so the emitted graph is identical — but a source *body*
edit no longer re-runs the whole-workspace resolve, only the cheap render IFD.
Adding or removing a file, or touching a manifest, still re-plans.

**`src` and `workspaceRoot` are the same tree.** rust-analyzer's checkout root
is its Cargo workspace root. Cargo plans against it, the renderer records
relatives against it, and the rendered units take it as `workspaceRoot`. Local
`pkg_id`s collapse to `path#<name>@<version>` in unit hashes (../README.md §5.2), so
the store path itself never reaches a hash.

**`rustc.unwrapped`, not `rustc`.** nixpkgs' `rustc` is a wrapper that forwards
`$NIX_RUSTFLAGS` and ships `bin/` alone; the rendered units reference
`${rustToolchain}/lib/rustlib`, which lives in the unwrapped derivation.

This toolchain carries no `rust-src`, so the std
`--remap-path-prefix .../lib/rustlib/src/rust=/rustc` that every unit emits is a
no-op here — without that component installed, `rustc` leaves std paths as the
virtual `/rustc/<commit>/...` they were compiled against, which is the outcome
the remap is reaching for anyway.

**No nightly toolchain input.** Cargo still gates `--unit-graph` behind
`-Z unstable-options`, but the planner IFD sets `RUSTC_BOOTSTRAP=1` itself, so
the stable nixpkgs toolchain is enough and this flake needs no fenix or
rust-overlay input.

**The toolchain id is the toolchain's store path basename.** `mkCargoUnit`
derives it, and the renderer salts every unit hash with it, so a nixpkgs bump
that moves rustc invalidates the graph rather than silently reusing artifacts
built by a different compiler.

**`policyPresets.pureBuild`.** This is a build benchmark; the point is the shape
and the wall clock of the unit graph, not gating upstream's tree. The preset
turns off unused-crate-dependency denial, cargo-audit, cargo-machete and
per-unit clippy in one name. Two of those would fail for reasons unrelated to
cargo-unit — rust-analyzer does not build under `-D unused_crate_dependencies`,
and its advisory surface is upstream's to carry. Per-unit clippy additionally
reads `policy.clippy.package.toolchain`, which the nixpkgs `clippy` derivation
does not carry; that seam is for fenix / rust-overlay toolchains.

**`contentAddressed = false`.** `buildWorkspace` defaults it on, and CA units
need the `ca-derivations` experimental feature, which stock Nix does not enable.
Turn it back on to measure early cutoff (../README.md §9).

**`buildEnv` with `pathsToLink`, not `symlinkJoin`, for `#workspace`.** Every
unit output carries a `nix-support/extern-path`, the pointer the renderer uses
to wire one unit's rlib into the next. Joined naively they all collide, and none
of them means anything in a merged tree.

## Observed on aarch64-darwin, nixpkgs 624af66 / rustc 1.97.0

Submodule at `bec66814`, `--workspace --profile release`:

- **320 units**, **46 roots** (4 binaries — `rust-analyzer`,
  `rust-analyzer-proc-macro-srv`, `ungrammar2json`, `xtask` — and 42 libraries).
  The rendered `units.nix` is 2.6 MB and never touches the source tree.
- The toolchain id salting every unit hash is the `symlinkJoin`'s store path
  basename, `<hash>-cargo-unit-rust-toolchain-1.97.0`.
- `#rust-analyzer` is 48 MB with a runtime closure of **2 store paths,
  91.6 MiB** (itself plus `libiconv`) — no source or toolchain derivation is
  pinned, which is what the per-unit `--remap-path-prefix` is for.
- `checks.aarch64-darwin.smoke` passes: the linked binary reports
  `rust-analyzer 0.0.0` and parses to a `SOURCE_FILE@0..30` tree.
- Editing `flake.nix` moves neither `plannerSource` nor `unitsNix`, so nothing
  re-plans, re-renders or rebuilds: `src` is the submodule tree, and the flake
  is not in it. The previous bench had the flake *inside* `workspaceSrc`, which
  cost ~30 s of re-planning on every edit to it.
- Editing a source *body* inside the submodule leaves `plannerSource` byte-for-byte
  identical and moves only `unitsNix`, so the whole-workspace cargo resolve is
  skipped and just the render IFD re-runs. (Measured: a comment appended to
  `crates/syntax/src/lib.rs` changed `cargo-units.nix.drv` and left
  `cargo-unit-planner-src.drv` alone.)

## Moving the pin

The submodule tracks `master`:

```console
$ git -C bench/rust-analyzer fetch origin master
$ git -C bench/rust-analyzer checkout <rev>
$ git add bench/rust-analyzer
```

or `git submodule update --remote bench/rust-analyzer` to take the current tip.
A new `Cargo.lock` re-vendors, re-plans and re-renders on its own; there is no
generator to re-run.
