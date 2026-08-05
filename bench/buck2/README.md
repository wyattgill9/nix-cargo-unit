# `bench/buck2/` — rust-analyzer, built by buck2

The other side of the comparison. Same submodule, same revision, same rustc; a
different build system holding the graph.

| Path | What it is |
|---|---|
| `reindeer.toml` | the whole benchmark: one `reindeer buckify` config |
| `fixups/` | 34 two-line files telling reindeer what to do with a build script |
| `macros/reindeer.bzl` | one macro, to drop a class of rule reindeer emits that has no consumer here |
| `toolchains/BUCK` | the four system toolchains buck2's rust rules reach for |
| `flake.nix` | a devShell, and the *only* thing pinning which rustc gets used |
| `../rust-analyzer/` | a **git submodule** of `rust-lang/rust-analyzer`, untouched — shared with the nix-cargo-unit bench |
| `../BUCK` | generated, gitignored. 464 KB, 651 rule calls |
| `../.buckconfig` | the cell root, which cannot live in this directory. See below |

No hand-written build file describes rust-analyzer: `reindeer buckify` reads the
submodule's `Cargo.toml` and `Cargo.lock` and emits every target, first-party
and third-party alike, into one generated package.

## Build it

The submodule has to be checked out, and everything runs inside the devShell —
buck2's rust toolchain is *whatever `rustc` is on `$PATH`*, so the shell is not
a convenience, it is the toolchain pin:

```console
$ git submodule update --init bench/rust-analyzer
$ cd bench/buck2 && nix develop
$ reindeer -c reindeer.toml buckify        # writes ../BUCK
$ cd .. && buck2 build //:rust-analyzer-0.0.0-rust-analyzer --show-simple-output
$ ./buck-out/.../rust_analyzer --version
rust-analyzer 0.0.0
```

`buckify` is not a step you can skip and not a step you have to remember:
`../BUCK` is gitignored, so a fresh checkout has none and buck2 says so
immediately. Re-run it after moving the submodule pin, and after nothing else —
it reads the lockfile and the manifests, not the sources.

| Target | What it is |
|---|---|
| `//:rust-analyzer-0.0.0-rust-analyzer` | the LSP binary |
| `//:proc-macro-srv-cli-0.0.0-rust-analyzer-proc-macro-srv` | the proc-macro server binary |
| `//:<crate>-0.0.0` | one workspace crate's library, e.g. `//:hir-ty-0.0.0` |
| `//:<crate>-<version>` | one dependency, e.g. `//:salsa-0.27` |
| `//:<pkg>-<version>-build-script-run` | a build script's output; `[rustc_flags]` and `[out_dir]` are subtargets |
| `//...` | every target in the file — see the note below on what that includes |

The workspace-roots set, which is what `bench/nix-cargo-unit`'s `#workspace`
means, is a query rather than a target, because the generated package carries no
grouping rule:

```console
$ buck2 build $(buck2 uquery "attrregexfilter('crate_root', '^rust-analyzer/', //...)")
```

That is 41 libraries and 7 binaries — the 4 rust-analyzer produces plus the 3
build scripts. `//...` is a *superset* of it, and of anything cargo would build:
reindeer emits a target for every crate in the resolve, including ones only a
`cfg(windows)` or `cfg(target_os = "linux")` dependency can reach.

## The pipeline

```
Cargo.lock ─┐
            ├──> reindeer buckify ──> ../BUCK ──> buck2 ──> one action per crate
Cargo.toml ─┘        (by hand)
   × 43 manifests
```

One generation step, run by hand, producing one file that is checked out but not
checked in. Nothing is generated during the build; buck2 reads `../BUCK` like
any other package.

`reindeer buckify` runs `cargo metadata` against the submodule's workspace —
which resolves features, platforms and the dependency graph exactly as cargo
would — and turns each resolved package into `cargo.rust_library` /
`cargo.rust_binary` calls from `@prelude//rust:cargo_package.bzl`. Dependencies
are named by versioned target (`:salsa-0.27`), renames become `named_deps`, and
`cfg()`-conditional dependencies become a `platform = {...}` dict the prelude
macro turns into a `select()`.

The 213 third-party crates are `http_archive` targets pointing at
`static.crates.io`, checksummed from `Cargo.lock`. There is no `vendor/`
directory and `reindeer vendor` is not part of this workflow: buck2 downloads and
caches the tarballs itself.

## Why the layout looks the way it does

**`.buckconfig` and `BUCK` are in `../`, not here.** A buck2 target's sources
must live under its own package, and a cell may not name a path outside itself —
a symlink out is rejected explicitly ("expected a normalized path"). The tree
under test is `../rust-analyzer/`, this directory's *sibling*, so the only
package that can name both it and the vendored crates is one rooted at `bench/`.
Hence a cell root one level up, and a generated package next to it. Everything
that can live in this directory does, including `toolchains/`, which is its own
cell at `buck2/toolchains`.

That is a real difference between the two benches rather than an accident of
this one: nix-cargo-unit takes the source tree as a store path and needs nothing
inside or above it. Neither side writes into the submodule, and `git status`
stays clean on both.

**`../fixups` is a symlink to `fixups/`.** Reindeer resolves the fixups
directory under `third_party_dir` and nowhere else, and `third_party_dir` has to
be `bench/` for the reason above. The symlink is the whole of the workaround;
buck2 never looks at either path.

**`include_workspace_members = true`.** Reindeer's usual job is a third-party
directory, so by default it buckifies a manifest's *dependencies* and leaves the
workspace members to hand-written BUCK files. Turning this on is what makes the
generated package the whole build rather than half of it — and it is what makes
the two benches comparable, since both then describe the same compilations from
the same lockfile, with no hand-written build description on either side.

**The 34 fixups are almost all `buildscript.run = true`.** Reindeer refuses to
guess whether a build script is safe to execute, and warns per package until
told. Every one of rust-analyzer's transitive build scripts is the tame kind —
probe rustc, print `cargo:rustc-cfg` — so they all run. The exceptions:

- `inotify`, `perf-event`, `windows` and `windows-future` get
  `target_compatible_with`, so `buck2 build //...` skips them on a host they
  cannot compile on instead of failing. Only `//...` ever asks for them; nothing
  reachable from a binary does, because the `cfg()` dependency that would reach
  them resolves away first.
- `windows_x86_64_gnu` and `windows_x86_64_msvc` get `buildscript.run = false`:
  their scripts emit a link directive for an import library, and nothing here
  links against Windows.
- `proc-macro-test` is omitted entirely. It is a dev-dependency of
  `proc-macro-srv` and nothing else, so `cargo build --workspace` never compiles
  it and neither should this. It would not build anyway: its build script shells
  out to `$CARGO` to compile a proc macro out of band, and prelude sets
  `CARGO=/bin/false`, which on macOS is not a path that exists.

**`omit_alias`.** Reindeer gives every first-order dependency of every workspace
member an unversioned public alias, on the assumption — true of a third-party
directory, false of a real workspace — that a crate name identifies one version.
rust-analyzer breaks it twice, with two majors of `hashbrown` and an `ungrammar`
that resolves both from crates.io and from the in-tree `lib/ungrammar`. Since
every generated target names its dependencies by versioned target, all 124
aliases are unreferenced, and dropping them is a smaller change than
disambiguating them. See `macros/reindeer.bzl`.

**Cargo's release profile is spelled out in `toolchains/BUCK`.** buck2 has no
notion of a cargo profile: there is one toolchain-wide rustc flag list, and that
is where `-Copt-level=3 -Cdebuginfo=0 -Ccodegen-units=16 -Cdebug-assertions=no
-Coverflow-checks=no -Cpanic=unwind` goes. The nix bench builds
`profile = "release"`; without this the two are not compiling the same thing.

**`flake.nix` pins nixpkgs to the revision `../nix-cargo-unit/flake.lock`
resolves to** — `624af66`, rustc 1.97.0. `system_rust_toolchain` resolves `rustc`
from `$PATH` when the action runs, so there is no in-band pin to check: the
devShell is the pin. Move it when the other bench's lock moves.

**`system_demo_toolchains()` is not used.** It declares android, java, kotlin,
go, ocaml, haskell and erlang alongside the four that matter, and hardcodes a
`java_home` that does not exist here. `toolchains/BUCK` declares `cxx`,
`genrule`, `python_bootstrap` and `rust`, and stops.

**The prelude is the one bundled with the buck2 binary** (`[external_cells]
prelude = bundled`), not a vendored copy. It is version-matched to the binary by
construction, which is one fewer pin to move.

## Observed on aarch64-darwin, nixpkgs 624af66 / rustc 1.97.0

Submodule at `bec66814`, buck2 `2026-07-14`, reindeer `2026.05.04`. Same machine
as [`../nix-cargo-unit/BENCH_BASE.md`](../nix-cargo-unit/BENCH_BASE.md) — Apple
M5, 10 cores, 16 GiB.

| | |
|---|---|
| `../BUCK` | 464 KB, 13312 lines, 651 rule calls — 254 `cargo.rust_library`, 213 `http_archive`, 124 dropped aliases, 32 `cargo.rust_binary`, 28 `buildscript_run` |
| Targets after macro expansion | 796 — 254 `rust_library`, 32 `rust_binary`, 213 `http_archive`, 28 buildscript, 269 alias/transition |
| First-party | 41 libraries, 4 binaries, 3 build scripts |
| Third-party | 213 crates |
| Cold build, LSP binary | **152 s**, 1084 actions, 16 MiB downloaded |
| Cold build, all workspace roots | **212 s**, 1703 actions |
| No-op rebuild | 0.01 s |
| Rebuild after editing `crates/syntax/src/lib.rs` | 100 s |

"Cold" here is `buck2 clean`: no action cache, and no downloaded crate tarballs
either, so the 16 MiB is inside that number. The nix bench's cold is measured
with its vendor derivations already in the store, so the two colds are not quite
the same kind; the download is a couple of seconds of it.

Correctness of the artifact under test — the same check as
`checks.aarch64-darwin.smoke` on the other side:

```console
$ RA=$(buck2 build //:rust-analyzer-0.0.0-rust-analyzer --show-simple-output 2>/dev/null)
$ $RA --version
rust-analyzer 0.0.0
$ printf 'fn main() { let x: i32 = 1; }\n' | $RA parse | head -1
SOURCE_FILE@0..30
```

## Moving the pin

Same as the other side, plus one command:

```console
$ git -C bench/rust-analyzer fetch origin master
$ git -C bench/rust-analyzer checkout <rev>
$ git add bench/rust-analyzer
$ (cd bench/buck2 && nix develop -c reindeer -c reindeer.toml buckify)
```

A new `Cargo.lock` re-resolves and re-emits `../BUCK` on its own. A new build
script in the dependency set makes buckify warn, naming the package; add a
`fixups/<name>/fixups.toml` saying `buildscript.run = true` or `false`.
