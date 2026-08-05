# `bench/buck2/` — rust-analyzer, built by buck2

The other side of the comparison. Same submodule, same revision, same rustc; a
different build system holding the graph.

| Path | What it is |
|---|---|
| `reindeer.toml` | the whole benchmark: one `reindeer buckify` config |
| `fixups/` | 34 files telling reindeer what to do with a build script, all but one of them two lines |
| `macros/reindeer.bzl` | one macro, to drop a class of rule reindeer emits that has no consumer here |
| `toolchains/BUCK` | the four toolchains buck2's rust rules reach for — three of them built by Nix |
| `toolchains/cxx.bzl` | 25 lines standing in for the one [buck2.nix] rule that no longer analyses |
| `flake.nix` | the compilers themselves, and a devShell that no longer contains any |
| `BUCK` | that flake, as a buck2 source, so a rule can name it |
| `../rust-analyzer/` | a **git submodule** of `rust-lang/rust-analyzer`, untouched — shared with the nix-cargo-unit bench |
| `../BUCK` | generated, gitignored. 464 KB, 651 rule calls |
| `../.buckconfig` | the cell root, which cannot live in this directory, plus the [buck2.nix] cell. See below |

No hand-written build file describes rust-analyzer: `reindeer buckify` reads the
submodule's `Cargo.toml` and `Cargo.lock` and emits every target, first-party
and third-party alike, into one generated package.

## Build it

The submodule has to be checked out, and everything runs inside the devShell —
which now holds only what *drives* the build, not what it compiles with:

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

## Where the compiler comes from

This is the half of the setup that reindeer has nothing to do with, and it is
the half that [tweag/buck2.nix][buck2.nix] replaces.

buck2's `system_*` toolchains name their tools by *string*. `system_rust_toolchain`
compiles with whatever `rustc` resolves to on `$PATH` when the action runs, and
`system_cxx_toolchain` links with whatever `clang` does. On a bench whose entire
claim is that both sides invoke the same compiler, that put the pin outside the
build: the devShell decided which one ran, and the action key — which is what
buck2 decides staleness from — recorded only the string `rustc`. Change the
compiler and every cached action stays valid.

It was worse than "outside the build", in fact. buck2 captures its environment
once when the daemon spawns and hands *that* to every action, so the pin was the
devShell some earlier `buck2` invocation happened to start from, and a
`buck2 killall` was needed after any change to it.

buck2.nix supplies a rule, `flake.package()`, that makes a Nix package a buck2
target: it runs `nix build path:<flake>#packages.<system>.<name>` as an action
and provides the resulting store path. Feed those to the toolchain rules and the
compiler becomes an *input to the build graph*, named by store path, the way a
source file is:

```
                 flake.package()          toolchain rule
                        │                       │
              ┌─ rustc ─┴───┐
              ├─ clippy ────┼──> toolchains//:rust ────────┐
BUCK ─────────┤             └─ [rustdoc]                   │
(filegroup    ├─ nix_cc ──> :nix_cc_tools ──> //:cxx ───────┼─> every action
 over         │                                            │
 flake.nix)   └─ python3 ────────> //:python_bootstrap ─────┘
```

The check is that the build no longer needs the shell it is run from. A clean
build of the LSP binary succeeds on a `$PATH` carrying `buck2`, `git`, `nix` and
`/usr/bin` — no `rustc`, no `cargo`, no `python3` from nixpkgs anywhere on it —
and the binary it produces links `libiconv` from the store path `flake.nix`
names:

```console
$ otool -L .../rust_analyzer | grep iconv
	/nix/store/0ky902f…-libiconv-115.100.1/lib/libiconv.2.dylib
```

Two things are still resolved by name rather than by store path, both
deliberately:

- **`genrule`** stays `system_genrule_toolchain`, which runs `/bin/sh`. Nix does
  not supply one and buck2.nix has no rule for it.
- **`BinaryUtilitiesInfo`** — `nm`, `objcopy`, `ranlib`, `strip` — is filled by
  the prelude from `$PATH` by name, below the seam any toolchain rule can reach.
  Nothing in this build invokes them; the clean build above ran on a `$PATH`
  with no `objcopy` on it at all. `toolchains/BUCK` therefore does not name them
  either, rather than implying a pin that would not hold.

[buck2.nix]: https://github.com/tweag/buck2.nix

## The pipeline

```
Cargo.lock ─┐
            ├──> reindeer buckify ──> ../BUCK ──> buck2 ──> one action per crate
Cargo.toml ─┘        (by hand)                      ^
   × 43 manifests                                   │
                                    flake.nix ──> nix build × 4
                                                (during the build)
```

One generation step, run by hand, producing one file that is checked out but not
checked in. Nothing else is generated: buck2 reads `../BUCK` like any other
package. The four `nix build` calls on the right *are* part of the build, as
ordinary actions — that is how the toolchain enters the graph, and the reason
buck2 can tell that it changed.

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
- `rust-analyzer` additionally gets `GIT_DIR = "/nonexistent"`. Its build script
  runs `git log -1` and bakes the answer into `--version`, and the directory a
  buck2 action runs in is under `buck-out/`, which is inside *this* repository —
  so what it finds is nix-cargo-unit's HEAD, not the submodule's. Nothing in the
  action key covers that, so buck2 would cache the wrong string and keep it. The
  nix bench compiles the crate with no git in reach and gets a bare
  `rust-analyzer 0.0.0`; this makes the same true here.

  The bug is older than this directory's move to buck2.nix — a Linux host, or a
  Mac with the Xcode tools, was always building a binary naming the wrong
  revision. It only became *visible* with the move, because fetching the `nix`
  cell needs `git` in the devShell, and until there was one, macOS's
  `/usr/bin/git` xcrun shim died there and the script gave up for the wrong
  reason.

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
resolves to** — `624af66`, rustc 1.97.0 — and that pin is now what the build
reads, not just what the shell offers. `toolchains/BUCK` names
`packages.<system>.rustc` from this flake, so moving the line moves the
compiler. Move it when the other bench's lock moves.

**`BUCK` here holds a `filegroup`, not a build target.** `flake.package()` takes
its flake as a *source* — buck2 materialises the named files into a directory
and evaluates `path:<that directory>`. The filegroup lists `flake.nix` and
`flake.lock` and nothing else, because a `path:` flake is copied into the store
before evaluation: anything else in this directory would be copied with it, and
the toolchain's identity would then depend on, among other things, this README.

**`toolchains/cxx.bzl` exists because buck2.nix's `nix_cxx_toolchain` does
not analyse against this prelude.** That rule builds `CxxToolchainInfo` field by
field, and the prelude bundled with buck2 `2026-07-14` has since made
`runtime_dependency_handling` a required field of it, so the rule fails before
it ever runs a compiler. buck2.nix's last commit is 2025-08-29 and its CI pins
an equally old nixpkgs, so the breakage is not visible from there.

The prelude has a seam one level below the toolchain — `cxx_tools_info_toolchain`
takes a dependency providing `CxxToolsInfo`, just the tool binaries and their
flavours, and derives the whole `CxxToolchainInfo` itself. So the local rule is
only the part that is genuinely Nix-specific, and every field neither it nor
buck2.nix names stays the prelude's problem, including whichever one it makes
required next. `prelude//toolchains/cxx/clang:path_clang_tools` is the same rule
against `$PATH`; the difference between the two is the entire point.

buck2.nix's `nix_rust_toolchain` and `nix_python_bootstrap_toolchain` are
unaffected and are used as they come.

**`system_demo_toolchains()` is not used.** It declares android, java, kotlin,
go, ocaml, haskell and erlang alongside the four that matter, and hardcodes a
`java_home` that does not exist here. `toolchains/BUCK` declares `cxx`,
`genrule`, `python_bootstrap` and `rust`, and stops.

**The prelude is the one bundled with the buck2 binary** (`[external_cells]
prelude = bundled`), not a vendored copy. It is version-matched to the binary by
construction, which is one fewer pin to move. The `nix` cell next to it is
buck2.nix, which buck2 clones and caches itself; `nix = nix` in `[cells]` is a
mount point, not a directory in this tree.

## Observed on aarch64-darwin, nixpkgs 624af66 / rustc 1.97.0

Submodule at `bec66814`, buck2 `2026-07-14`, reindeer `2026.05.04`, buck2.nix
`038b031`. Same machine as
[`../nix-cargo-unit/BENCH_BASE.md`](../nix-cargo-unit/BENCH_BASE.md) — Apple M5,
10 cores, 16 GiB. Re-measured 2026-08-05 under these toolchains.

| | |
|---|---|
| `../BUCK` | 464 KB, 13313 lines, 651 rule calls — 254 `cargo.rust_library`, 213 `http_archive`, 124 dropped aliases, 32 `cargo.rust_binary`, 28 `buildscript_run` |
| Targets after macro expansion | 796 — 254 `rust_library`, 32 `rust_binary`, 213 `http_archive`, 28 buildscript, 269 alias/transition |
| First-party | 41 libraries, 4 binaries, 3 build scripts |
| Third-party | 213 crates |
| Cold build, LSP binary | **179 s** and **218 s**, two runs — 1087 actions, 16 MiB downloaded |
| Cold build, all workspace roots | **249 s**, 1706 actions |
| No-op rebuild | 0.1 s wall, the CLI's own startup included |
| Rebuild after editing `crates/syntax/src/lib.rs` | 132 s, 181 actions |
| Toolchain, from a clean `buck-out` | 1.4 s, 4 actions |

"Cold" here is `buck2 clean`: no action cache, and no downloaded crate tarballs
either, so the 16 MiB is inside that number. The nix bench's cold is measured
with its vendor derivations already in the store, so the two colds are not quite
the same kind; the download is a couple of seconds of it.

**Every figure is worse than the one it replaces** — 152 s, 212 s, 0.01 s,
100 s — and the toolchain change is not why.

The last row is the whole of what buck2.nix adds mechanically: from an empty
`buck-out`, fetching the `nix` cell and running the four `nix build` actions is
4 actions and 1.4 s, against a warm store. It is +3 actions on a cold build of
1087, and the compilers themselves are substituted or built by Nix outside the
measurement, exactly as the other bench's toolchain is.

The rest is the machine. The old setup, restored and measured in this same
sitting, built the LSP binary cold in **188 s** — inside the 179–218 s spread of
two runs of the new one. [`../comparison.md`](../comparison.md) is the
independent check: measured earlier the same day, it puts the all-roots cold at
225.5 s with the 25.2 s crate prefetch excluded as setup, which is 250.7 s on
this table's methodology against the 249.3 s measured here. That file also
records a 21% spread between two runs of one scenario, which is the band all of
this sits in.

Correctness of the artifact under test — the same check as
`checks.aarch64-darwin.smoke` on the other side:

```console
$ RA=$(buck2 build //:rust-analyzer-0.0.0-rust-analyzer --show-simple-output 2>/dev/null)
$ $RA --version
rust-analyzer 0.0.0
$ printf 'fn main() { let x: i32 = 1; }\n' | $RA parse | head -1
SOURCE_FILE@0..30
```

## Moving the pins

There are three, and they move independently.

**The submodule.** Same as the other side, plus one command:

```console
$ git -C bench/rust-analyzer fetch origin master
$ git -C bench/rust-analyzer checkout <rev>
$ git add bench/rust-analyzer
$ (cd bench/buck2 && nix develop -c reindeer -c reindeer.toml buckify)
```

A new `Cargo.lock` re-resolves and re-emits `../BUCK` on its own. A new build
script in the dependency set makes buckify warn, naming the package; add a
`fixups/<name>/fixups.toml` saying `buildscript.run = true` or `false`.

**nixpkgs**, in `flake.nix`, which decides the compiler on both sides. It moves
when `../nix-cargo-unit/flake.lock` moves, and only then; the comparison means
nothing if the two disagree.

**buck2.nix**, in `../.buckconfig` as `[external_cell_nix] commit_hash`. Pinned
by hand because buck2 resolves that cell before any flake is read, so Nix cannot
be the one to tell it a revision. It moves on its own schedule and nothing about
the comparison depends on it — it supplies rules, not compilers. Worth moving if
upstream ever repairs `nix_cxx_toolchain`, which would delete
`toolchains/cxx.bzl`.
