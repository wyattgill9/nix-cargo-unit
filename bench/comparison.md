# nix-cargo-unit vs buck2 + reindeer — measured

Both benches, same submodule revision, same rustc, same machine, one sitting.
Measured 2026-08-05 after a full `nix-collect-garbage -d`.

## Answer

**buck2 wins every incremental case. nix-cargo-unit wins the cold build.**

nix-cargo-unit rebuilds *less* and still finishes *later*: on a `stdx` edit it
rebuilds 33 derivations to buck2's 206 actions and takes 29% longer. Granularity
is not what decides an incremental rebuild here — the critical chain is.

## Numbers

Wall clock, one run per cell. rust-analyzer's whole workspace-roots set.

| | nix-cargo-unit | buck2 + reindeer | winner |
|---|---:|---:|---|
| Cold build | **183.9 s** | 225.5 s | nix, 1.23× |
| No-op | 0.48 s | **0.01 s** | buck2, 48× |
| Edit `rust-analyzer` (leaf) | 24.2 s | **15.9 s** | buck2, 1.52× |
| Edit `hir-ty` (mid) | 84.8 s | **61.9 s** | buck2, 1.37× |
| Edit `stdx` (deepest, 30 rdeps) | 118.0 s | **91.1 s** | buck2, 1.29× |

What each rebuilt:

| | nix-cargo-unit | buck2 + reindeer |
|---|---:|---:|
| Cold | 321 derivations | 1529 actions |
| Edit `rust-analyzer` | 6 | 5 |
| Edit `hir-ty` | 13 | 71 |
| Edit `stdx` | 33 | 206 |

nix's counts are derivations (320 units + the `buildEnv` root), and include the
render IFD. buck2's are actions, which split each crate into rustc + link and
count build-script runs separately. The two columns are not the same unit and
are here to show *shape*, not ratio.

## Reading it

**1. Fewer rebuilds, slower rebuild.** The `stdx` edit is the clean case: nix
touches 33 things, buck2 touches 206, buck2 finishes 27 s sooner. Whatever
per-derivation tax nix pays (~175 ms × 33 ≈ 5.8 s, per `BENCH_BASE.md` §8) does
not explain a 27 s gap. The remaining candidate is pipelining — buck2 unblocks a
dependent on `.rmeta` while a Nix derivation is atomic — which is what
`research/comparison.md` §8 and `FASTER.md` Change 1 already predict. **Not
measured here.** This bench times end-to-end builds; it does not instrument the
critical chain.

**2. The cold result reversed.** `buck2/README.md` recorded 212 s cold against
`BENCH_BASE.md`'s 212.9 s — a tie. This run: 183.9 s vs 225.5 s. Both sides
moved, in opposite directions, and the buck2 side moved the wrong way despite
being handed a *cheaper* cold than before (archives pre-fetched, see below).
Neither shift is explained by anything measured here.

**3. No-op is a rout, and it is a daemon.** buck2's 0.01 s is a warm DICE daemon
answering from memory. nix's 0.48 s is flake eval plus the render IFD, from
cold eval cache. Different mechanisms, both legitimately "no-op"; the 48×
is real but tells you about process models, not build systems.

**4. Both artifacts are correct.** Each binary reports `rust-analyzer 0.0.0` and
parses to `SOURCE_FILE@0..30`. nix's closure is 91.6 MiB over 2 store paths.

## Two bugs this found

**`bench/buck2/flake.nix` was never hermetic.** Every binary target links
`-liconv`; nothing in the devShell declared it. It worked only because some
unrelated derivation kept libiconv alive in the store. The GC removed it and all
6 binary targets failed with `ld: library not found for -liconv`. Fixed by
adding `libiconv` to `buildInputs` — it must be `buildInputs`, not `packages`,
because cc-wrapper's buildInputs hook is what puts `-L` into `$NIX_LDFLAGS`.
The nix-cargo-unit side never had this: libiconv is one of the two paths in its
LSP binary's closure.

**The toolchain pin is weaker than documented.** `buck2/README.md` says the
devShell is the pin. It is really *the devShell the running daemon was spawned
from* — buck2 captures its environment at daemon start and hands that to every
action. A corrected shell with a stale daemon still builds with the old
environment. `buck2 killall` is required after any environment change.

## Caveats

1. **One run per cell.** A repeat of `edit stdx` gave 110.7 s against the
   91.1 s above — same 206 actions, **21% apart**. Treat every number here as
   ±20%, and treat the leaf/mid/deep *ordering* as the finding rather than any
   individual figure. This was a deliberate scope choice, not an oversight.
2. **Root sets differ slightly.** nix builds 46 roots (42 lib + 4 bin); buck2
   builds 48 targets (41 lib + 7 bin, counting 3 build scripts as binaries).
3. **"Cold" was equalized by hand.** `buck2 clean` deletes downloaded crate
   tarballs while the nix store keeps vendored sources, so buck2's 213
   `http_archive` targets were pre-fetched as setup (25.2 s, excluded) to mirror
   nix's warmed `vendorDir`. Without this buck2 is charged for a download nix
   already did.
4. **Setup is excluded and is not symmetric.** From an empty store nix spent
   106.1 s materializing vendor + toolchain + render; buck2 spent 1.0 s on
   `buckify` plus 25.2 s prefetching. Both sat behind ~12 min of toolchain
   download that neither build system is responsible for.
5. **aarch64-darwin, `sandbox = false`, CA off, 10 cores.** Same single
   configuration as every other number in this directory.
6. The buck2 edit figures come from a run whose per-iteration source restore
   silently failed inside the devShell (`/usr/bin/git` is an xcrun shim that
   dies there). Each scenario still edited a distinct crate whose predecessor
   was already compiled, so each delta remains one crate's fan-out, and the
   `stdx` action count reproduced exactly (206) under a corrected harness.

## Reproduce

```console
$ git submodule update --init bench/rust-analyzer
$ nix build "git+file://$PWD?submodules=1&dir=bench/nix-cargo-unit#workspace"
$ cd bench/buck2 && nix develop
$ reindeer -c reindeer.toml buckify
$ cd .. && buck2 killall
$ buck2 build $(buck2 uquery "attrregexfilter('crate_root', '^rust-analyzer/', //...)")
```

Edit scenarios append one comment line to `crates/<crate>/src/lib.rs` and
rebuild the same root set. Restore the file between runs with `cp` from a
pristine copy, not `git` — inside the devShell `/usr/bin/git` fails.
