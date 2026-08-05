# `bench/` — the same workspace, two build systems

One tree under test, one directory per build system that builds it. The
comparison only means anything if both sides compile the *same* source at the
*same* revision, so the checkout is shared rather than duplicated.

| Path | What it is |
|---|---|
| `rust-analyzer/` | a **git submodule** of `rust-lang/rust-analyzer`, untouched. The workspace both sides build. |
| `nix-cargo-unit/` | this repository's bench: one Nix derivation per Cargo compilation unit. Measured; see its README. |
| `buck2/` | the buck2 bench: `reindeer buckify` over the same lockfile, one buck2 action per crate. Measured; see its README. |
| `.buckconfig`, `BUCK` | buck2's cell root and its generated package. They are here rather than in `buck2/` because a buck2 cell cannot name sources outside itself, and `rust-analyzer/` is `buck2/`'s sibling. `BUCK` is generated and gitignored. |
| `fixups/` | a symlink to `buck2/fixups/`; reindeer only looks for fixups next to the generated `BUCK`. |

Populate the shared checkout once, before running either side:

```console
$ git submodule update --init bench/rust-analyzer
```

Each bench directory is self-contained apart from that submodule, and owns its
own harness and its own results — the numbers are only comparable when they
name the same submodule revision, so each side records it.

- [`nix-cargo-unit/README.md`](nix-cargo-unit/README.md) — how to build it
- [`nix-cargo-unit/BENCH_BASE.md`](nix-cargo-unit/BENCH_BASE.md) — the baseline measurements
- [`nix-cargo-unit/PROFILE.md`](nix-cargo-unit/PROFILE.md) — the deep profile
- [`nix-cargo-unit/tools/`](nix-cargo-unit/tools/README.md) — the profiling harness (Nix-specific: it parses `nix build --log-format internal-json`)
- [`buck2/README.md`](buck2/README.md) — how to build it, and the headline numbers
- [`comparison.md`](comparison.md) — both sides measured head to head, same sitting

Both sides pin the same nixpkgs revision, and so the same rustc: the nix bench
through `nix-cargo-unit/flake.lock`, the buck2 bench through `buck2/flake.nix`,
whose devShell is the only thing deciding which `rustc` buck2's system toolchain
finds. Move them together.
