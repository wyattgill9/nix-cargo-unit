# Building this workspace with `nix-cargo-unit`

`flake.nix` is the only file here that is not upstream rust-analyzer, and it is
the whole story: it takes `Cargo.lock` and this source tree and produces one Nix
derivation per Cargo compilation unit. There is no generator script, no checked-in
generated Nix, and no step you have to remember to re-run. Nothing under
`crates/`, `lib/` or `xtask/` is touched.

## Build it

From the repository root:

```console
$ nix build "path:$PWD?dir=bench/rust-analyzer"
$ ./result/bin/rust-analyzer --version
rust-analyzer 0.0.0
```

Once `bench/` is tracked by git, `nix build ./bench/rust-analyzer` works too and
is the nicer spelling. What does *not* work is `nix build "path:$PWD"` from
inside this directory: that makes a standalone store copy of this directory
alone, and the `path:../..` input then resolves to `/nix`. The flake needs to be
fetched from the repository tree so that `../..` is the `nix-cargo-unit` root.

| Attribute | What it is |
|---|---|
| `#default`, `#workspace` | every workspace root in one tree — 4 binaries, 125 libraries |
| `#rust-analyzer` | the LSP binary alone |
| `#units.'"syntax-0.0.0-<hash>"'` | a single compilation unit |
| `#packages`, `#binaries`, `#libraries` | the rendered per-package / per-target sets |
| `#unitGraph`, `#unitsNix`, `#vendorDir`, `#rustToolchain` | pipeline stages, for looking at a planning or render problem directly |
| `checks.<system>.smoke` | runs `--version` and `parse` against the built binary |

## The pipeline

Everything is a derivation, evaluated on demand:

```
Cargo.lock ──> vendorDir ──┬─> cargo build --workspace --unit-graph ──> unitGraph
                           └─> nix-cargo-unit render ─────────────────> units.nix
                                                                          │ IFD
                                                        one derivation per compile unit
```

1. **Vendor.** Each external crate in `Cargo.lock` becomes its own derivation
   (`fetchurl` of the `.crate` tarball, unpacked, plus a `.cargo-checksum.json`).
   A unit therefore depends on its own tarball, not on a 383 MB vendor tree.
   `vendorDir` merges them for the two consumers that need a directory.
2. **Plan.** `cargo build --workspace --unit-graph` runs offline against
   `vendorDir`. Nothing is compiled; cargo only resolves features and enumerates
   units.
3. **Render.** `nix-cargo-unit render` turns that JSON into a Nix function.
4. **Build.** The function is imported (import-from-derivation) and applied, and
   Nix schedules the 320 units.

Because every stage is a derivation, changing `Cargo.lock`, the profile, or
nixpkgs re-plans and re-renders automatically. The cost is that the first
evaluation blocks on steps 1–3.

## Why the pieces look the way they do

**The vendor set is built from `Cargo.lock`, not by `cargo vendor`.** The
renderer keys external units by `"<Cargo.lock source>#<name>@<version>"`
(README §6.2), which is exactly what the lockfile spells.

**`vendorDir` is real files** — not a `linkFarm`, not `cp -rs`. The renderer
walks the tree when it scopes a source closure and rejects a symlink that escapes
`--vendor-root` ("points outside source boundary"). Steps 2 and 3 also have to
agree on the layout, because a vendored unit's source root is the first path
component of its `src_path` under `--vendor-root` — which is why one `vendorDir`
is handed to both.

**`workspaceSrc` is one store path used three times**: cargo plans in it, the
renderer records relatives against it as `--workspace-root`, and the rendered
units take it as `workspaceRoot`. Local `pkg_id`s collapse to
`path#<name>@<version>` in unit hashes (README §5.2), so the store path itself
never reaches a hash.

**`rustc.unwrapped`, not `rustc`.** nixpkgs' `rustc` is a wrapper that forwards
`$NIX_RUSTFLAGS` and ships `bin/` alone; the rendered units reference
`${rustToolchain}/lib/rustlib`, which lives in the unwrapped derivation.

This toolchain carries no `rust-src`, so the std
`--remap-path-prefix .../lib/rustlib/src/rust=/rustc` that every unit emits is a
no-op here — without that component installed, `rustc` leaves std paths as the
virtual `/rustc/<commit>/...` they were compiled against, which is the outcome
the remap is reaching for anyway.

**`--toolchain-id rustc-<version>`** salts every unit hash, so a nixpkgs bump
that moves rustc invalidates the graph rather than silently reusing artifacts
built by a different compiler.

**`buildEnv` with `pathsToLink`, not `symlinkJoin`, for `#workspace`.** Every
unit output carries a `nix-support/extern-path`, the pointer the renderer uses to
wire one unit's rlib into the next. Joined naively they all collide, and none of
them means anything in a merged tree.

## Observed on aarch64-darwin, nixpkgs 26.11 / rustc 1.97.0

- 320 units for `--workspace --profile release`; the rendered `units.nix` is
  2.6 MB and never touches the source tree.
- Editing `flake.nix` (or anything else in this directory) changes
  `workspaceSrc`, so planning and rendering re-run — about 30 s — before the
  cached units are reused. The unit hashes themselves do not move: the same
  `#rust-analyzer` store path comes back out.
- `#workspace` is 4 binaries and 125 libraries.
- `#rust-analyzer` is ~49 MB with a runtime closure of **2 store paths,
  90.5 MiB** (itself plus `libiconv`) — no source or toolchain derivation is
  pinned, which is what the per-unit `--remap-path-prefix` is for.
- `analysis-stats` over this workspace runs to completion against the built
  binary.
