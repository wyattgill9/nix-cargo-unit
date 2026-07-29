# Redesigning `nix-cargo-unit` for Speed: A Deep Technical Memo

## TL;DR
- The single biggest structural loss in this design is **pipelined compilation**: because a Nix derivation must fully complete before any dependent starts, you serialize on full `.rlib` codegen where Cargo/Bazel would unblock dependents on `.rmeta`. Restoring this by splitting every unit into a fast **metadata derivation** (`--emit=metadata`, frontend-only) and a **codegen derivation** (`--emit=link`) — with dependents depending only on the metadata derivations — is the highest-leverage change and is exactly what rules_rust does with `--@rules_rust//rust/settings:pipelined_compilation`.
- The second biggest problem is **per-derivation and per-source-copy fixed overhead multiplied by unit count**: `stdenv.mkDerivation` is ~2x slower than a raw `derivation` for trivial builds (10k trivial builds: ~475s vs ~318s, most of it Nix scheduling, not the build), and every `builtins.path` source scope copies and NAR-hashes a tree. At 500–5000 units these fixed costs dominate. Strip stdenv to a static builder, adopt Determinate Nix **lazy trees** (reported 3x+ eval wall-time and 20x disk reductions in some cases), and coarsen the external-dependency tier into fewer derivations.
- **Content-addressed derivations do not currently pay off at this scale** and you should stop treating them as the early-cutoff mechanism: rustc's `.rmeta` is oversensitive (any comment/format/reorder edit changes the serialized source map and file hashes, forcing transitive rebuilds), rustc byte-reproducibility is best-effort not guaranteed (and the parallel frontend is explicitly nondeterministic), and CA in Nix still has open realisation-conflict bugs. Bet instead on the upstream **"Relink don't Rebuild"** work and on shrinking input closures.

## Key Findings

1. **Pipelining is real and measurable, and this architecture throws it away.** rustc can compile against `.rmeta`-only dependencies today (`rustc libB.rs --extern libA=liblibA.rmeta` works). Cargo's pipelining wins are concentrated in release builds and deep graphs; the original evaluation thread found gains up to ~1.2x on some release builds (e.g. `cranelift-codegen` opt: 28.15s → 23.45s, 1.20x) and roughly neutral on debug. rules_rust implements this out-of-process with a metadata action + codegen action; Buck2 does the same. A derivation-per-unit model can replicate it by making each unit two derivations.

2. **Per-derivation overhead is a first-class cost here.** `stdenv.mkDerivation` costs roughly 2x a bare `derivation` for trivial builders, and a large fraction of wall time at scale is Nix *scheduling/daemon* overhead, not the builder. With thousands of units this is a structural tax. `runCommandLocal`/raw `derivation` with a static builder, `__structuredAttrs`, and disabling `fixupPhase`/`patchShebangs`/`strip` scanning per unit are the levers.

3. **Source scoping copies too much, too often.** Every `Workspace`/`WorkspaceClosure`/`VendorClosure` scope triggers a `builtins.path` copy + NAR hash. Lazy trees (Determinate Nix 3.6.7+) eliminate most of the copy cost using a virtual filesystem; upstream is following. This is a near-free win with no architecture change.

4. **rmeta oversensitivity caps early cutoff regardless of CA.** The "Relink don't Rebuild" (RDR) project goal confirms that comments, `use` reordering, formatting, and moving items between impl blocks all change `.rmeta` because the serialized source map contains per-file hashes and span/byte-offset data (bjorn3: "The crate metadata contains a serialized version of the source map, which in turn contains hashes of all source files. In addition the crate hash also has all source files as one of the inputs"). Until RDR ships (currently a blocked proof-of-concept, PR #143249), your cache-hit ceiling on workspace edits is low.

5. **Linkers are on your critical path constantly** because you relink every bin/test on any transitive rlib change. rust-lld is now the default on `x86_64-unknown-linux-gnu` as of stable 1.90.0 (released 2025-09-18); for ripgrep 13 debug on Linux, the Rust compiler-performance team reported "linking is reduced 7x, resulting in a 40% reduction in end-to-end compilation times." `wild` (v0.8.0, released 2026-01-16, Linux-only, no LTO) is faster still on Linux for non-LTO links. This is a large, low-risk win given the relink pattern.

6. **Doctests and the panic-scan double-compile are the most wasteful policy/test costs.** Rust 2024's merged doctests compile all compatible doctests into a single binary — a very large win versus compiling/running each individually. The panic-scan's second `--emit obj` derivation duplicates most of a compile that `--emit link,obj` could produce in one invocation.

7. **Alternative architectures are honest tradeoffs.** Buck2/Bazel+rules_rust give you a real incremental scheduler, remote execution, action-level caching, and native pipelining — at the cost of Nix purity and nixpkgs integration. crate2nix/cargo2nix are the closest prior art and confirm per-crate (let alone per-unit) granularity has diminishing returns because dependency-version/feature skew defeats cross-project sharing.

## Details

### 1. Where the time actually goes — a cost model

You have eight distinct "faster" axes. They do not share a bottleneck, so a single knob won't move all of them. A defensible mental model, with the evidence behind each term:

**(a) Nix evaluation.** Emitting thousands of literal `mkDerivation` attribute sets is eval-heavy: every attribute, list element, and function argument becomes a thunk, and thunks retain their environments (NixOS wiki, "Nix Evaluation Performance"). At 500–5000 units × (lib/codegen/metadata/test/doctest/clippy/panic-obj/scan) the attribute count is in the 10^4–10^5 range. You have no measurements of this today; **first action is to measure** with `nix-eval-jobs` timings and `NIX_SHOW_STATS=1`/`NIX_COUNT_CALLS=1`. The current `units.nix` being a *function* over `pkgs`/`rustToolchain`/`src` means eval is re-done per consumer unless the flake eval cache or `nix-eval-jobs` is warm.

**(b) Per-derivation fixed overhead.** From the NixOS Discourse benchmark (aameen-tulip harness), `stdenv.mkDerivation` is ~2x a raw `derivation` for trivial builders; over 10k trivial builds, `mkDerivation` ≈475s vs `derivation` ≈318s, and the author (pennae) notes "much of that seems to be spent waiting for nix to schedule stuff rather than actually running builds, average cpu load was about 10%." The fixed per-derivation costs are: daemon round-trip, sandbox namespace setup/teardown, `setup.sh` sourcing (~158ms just to *parse* on a slow machine per abathur's gut-check), `fixupPhase`/`patchShebangs`/`stripAllList` scanning, output NAR serialization + SHA-256, SQLite path registration, and reference scanning. At your unit counts this is minutes of pure overhead before any `rustc` runs.

**(c) rustc frontend vs (d) codegen vs (e) link.** The frontend (parse, macro expand, resolve, type/borrow check) is largely serial; the parallel frontend (`-Zthreads`) can cut ~20–30% under 8 cores but is nightly-only and nondeterministic (see §E). Codegen is already parallel via `codegen-units`. Link is on your critical path because you relink leaves constantly. For a debug build of ripgrep 13, "roughly half of the time is actually spent in the linker" (Rust blog, rust-lld on 1.90.0) — which is exactly the regime this design lives in.

**(f) Build scripts / C-C++.** `cc-rs` crates (`ring`, `aws-lc-sys`, `rusty_v8`) can dominate a cold build. These are opaque to rustc-level parallelism and gated by `NUM_JOBS`.

**(g) Tests.** One derivation per `#[test]` multiplies per-derivation overhead by test count; with `allowSubstitutes=false; preferLocalBuild=true` you've already recognized the narinfo-round-trip pathology, but the derivation-spawn cost remains.

**(h) Renderer runtime.** ~7800 lines of Rust doing two memoized SHA-256 hash passes over the DAG, textual `.rs` scanning, and string-splice templating. This is almost certainly not your bottleneck versus Nix, but it's cheap to speed up (§I).

**What to measure first, in order:** `-Zself-profile` on the tallest crates (where does rustc time go — frontend/codegen/LLVM); `nix build --debug` / `nix-output-monitor` for scheduler stalls; `nix-eval-jobs` wall time for eval scaling; a determinism check (build twice, diff rmeta) before betting anything on CA.

### 2. Ranked changes

#### Change 1 — Split each unit into a metadata derivation and a codegen derivation (restore pipelining). **Magnitude: large on cold/deep graphs; unmeasured in the Nix-scheduler context.**

*The change.* For every library unit, emit two derivations: `unit-<hash>-meta` running `rustc --emit=metadata` (frontend-only, produces `.rmeta`, terminates before codegen) and `unit-<hash>-lib` running `rustc --emit=link` (or `--emit=metadata,link`). A dependent unit's **metadata** derivation depends only on its dependencies' **metadata** derivations (`--extern name=….rmeta`); only **link/bin/test** derivations depend on the full rlib closure. This turns the critical path from "sum of full compiles along the longest chain" into "sum of *frontend* times along the chain + one codegen tail," which is precisely the pipelining win.

*Why it's fast.* rustc accepts rmeta-only externs (confirmed: `rustc libB.rs --extern libA=liblibA.rmeta`). The metadata derivation finishes far earlier than the rlib because metadata is produced just before LLVM/codegen. David Lattimore's "Speeding up rustc by being lazy" describes the same decomposition (emit rmeta without MIR so dependents start earlier).

*Implementation.* Touches `prepare_graph` (add a metadata node per lib unit and rewrite dependency edges: meta→meta for the frontend chain, lib-consumers→lib for linking), `identity_hash` (metadata and codegen nodes need distinct attr names but the *metadata* hash must exclude codegen-only inputs like opt-level/LTO so it stays stable — this is the subtle part), `render_driver_build_phase` (two emit modes), and `units.nix.in` (new derivation template). In the inter-unit contract, `extern-path` must resolve to `.rmeta` for meta-consumers and to the rlib/so for link-consumers.

*What breaks / risks.* (1) **`-C metadata` consistency**: both invocations must pass identical `-C metadata=<hash>` or the rmeta and rlib won't be recognized as the same crate. (2) **Generics/monomorphization and cross-crate inlining need the dependency's MIR, which lives in rmeta** — so compiling a *dependent* against rmeta-only works for type-checking and even codegen *as long as the rmeta carries MIR*; but with `-Zshare-generics` or inline-heavy code the final link may still need the producer's rlib, so keep link derivations depending on rlibs. (3) **Proc-macros must be fully built** (they're `dylib`s loaded by the compiler) — do not split them; keep proc-macro units single-derivation. (4) **LTO** pulls codegen to link time and defeats the split for release; gate the split to non-LTO profiles. (5) The extra metadata derivation adds per-derivation overhead (Change 2 mitigates), and on shallow/debug graphs pipelining is roughly neutral (original evaluation thread), so make it profile-conditional.

#### Change 2 — Replace `stdenv` with a static minimal builder for the compile/metadata/link units. **Magnitude: ~2x per-derivation fixed cost reduction; compounds across thousands of units.**

*The change.* Emit units as raw `builtins.derivation` (or `runCommandLocal`-style with `stdenvNoCC`) invoking a single static bash (or a compiled launcher) that does exactly: assemble args, run `rustc`, write `nix-support/*`. Disable everything you don't need: `dontStrip`, `dontPatchShebangs`, `dontFixup`, `noAuditTmpdir`, `__structuredAttrs = true` (pass the large `rustc_args`/`rustc_env` arrays as structured JSON instead of re-parsing bash arrays), `unsafeDiscardReferences` where the path-remap already guarantees no store refs, `preferLocalBuild = true`, `allowSubstitutes = false` for cheap leaves.

*Why it's fast.* The Discourse benchmark shows `setup.sh` sourcing and fixup phases are the bulk of the 2x gap; rustc units don't need patchShebangs or strip scanning (the artifacts are rlibs/rmeta, and you already remap paths so reference scanning finds nothing). Cuts the fixed per-unit tax roughly in half and removes bash re-parse of huge arg arrays via `__structuredAttrs`.

*Implementation.* Rewrite `units.nix.in` to a `derivation`-based template; move the fixed-order arg assembly (currently bash arrays in `render_driver_build_phase`) into `__structuredAttrs` JSON consumed by a tiny static builder. Keep `render_install_phase`'s `nix-support/extern-path` probing.

*Risks.* Lose stdenv niceties (automatic `$PATH`, hooks). You must set `PATH`/`rustc`/linker explicitly. Reference scanning still runs at the Nix level (unavoidable), but with remapping it finds nothing. Low correctness risk; high mechanical churn.

#### Change 3 — Adopt lazy trees / stop copying source per scope. **Magnitude: reported 3x+ eval wall-time and 20x disk in monorepos; near-free.**

*The change.* Require Determinate Nix (or upstream once lazy-source lands) and rewrite source roots to the `builtins.path { path = …; name = "source"; }` form the lazy-trees docs recommend (avoids the "inefficient double copy" warning). Keep the narrow-scope model (`Workspace`/`WorkspaceClosure`) — it's still correct and good for cache keys — but the *copy* is now virtual.

*Why it's fast.* Determinate reports lazy trees "reduce wall time for evaluations by 3x or more and disk usage of 20x or more in some cases," using "a virtual filesystem to gather file state prior to copying to the Nix store," plus background copying so eval doesn't block. Your design triggers many source copies (one per scope per package); this removes most of them.

*Risks.* Ties you to Determinate Nix for now (upstream `fetchToStore` lazy work is not yet at parity). Some flake-input caching regressions existed early (fixed by 3.13.2). Behavioral, not architectural.

#### Change 4 — Switch the linker to rust-lld (default) or `wild`, and cut debuginfo on the relink path. **Magnitude: link is ~50% of debug build time in the ripgrep case; rust-lld cut ripgrep's link 7x for a 40% end-to-end reduction.**

*The change.* Pass `-C linker-features=+lld` (or rely on the 1.90.0+ x86_64-linux default) or wire `wild` via `-Clink-arg=--ld-path=wild`. Set `split-debuginfo=unpacked` and consider `[profile.dev.package."*"] debug=false` / `debuginfo=line-tables-only` for the dependency tier so you're not relinking fat debug info you don't use.

*Why it's fast.* rust-lld: "when building ripgrep 13 in debug mode on Linux, roughly half of the time is actually spent in the linker," and the switch delivered "linking is reduced 7x, resulting in a 40% reduction in end-to-end compilation times" (Rust blog, 2025-09-01). `wild` 0.8.0 benchmarks (Phoronix/BigGo, 2025–2026) show it matching or beating mold on non-LTO Linux links. Because your architecture relinks bins/tests on *every* transitive rlib change, link time is paid constantly, not once.

*Risks.* `wild` is Linux-only, no LTO, still young (v0.8.0, 2026-01-16). macOS uses `ld-prime`/lld separately. Keep rust-lld as the portable default and `wild` as an opt-in for Linux CI.

#### Change 5 — Merge doctests into one binary (Rust 2024) and stop per-doctest compile/run. **Magnitude: large where doctests are numerous; doctests are notoriously the slowest test kind.**

*The change.* Use Rust 2024 merged doctests (the `parse_merge_doctests` path in nightly rustdoc; edition-2024 default) so compatible doctests compile into a single binary instead of one executable per code block. Fold the three script variants (List/RunAll/RunCase) accordingly.

*Why it's fast.* The edition guide states plainly that pre-2024 rustdoc "would compile each code block in your documentation as a separate executable... it resulted in a significant performance burden when there were a large number of documentation tests," and 2024 "will attempt to combine documentation tests into a single binary, significantly reducing the overhead." Your design compiles/runs them individually — the worst case.

*Risks.* `compile_fail` and a few other doctests can't be merged (rustdoc detects and falls back to `standalone_crate`). Global-state doctests still run in separate processes. Nightly/edition gating.

#### Change 6 — Collapse the panic-scan double compile. **Magnitude: eliminates one full extra compile per candidate unit.**

*The change.* Instead of a separate `rustc --emit obj` derivation in addition to the `--emit link` build, use a single `rustc --emit=link,obj` (or `--emit=metadata,link,obj`) invocation that produces both the rlib and the object files, then run `scanUnit` against those objects. rustc does frontend + MIR + LLVM once and just writes multiple output kinds.

*Why it's fast.* `--emit` output kinds are additive over one compilation; you pay type-check/codegen once, not twice. The relocation-based scan (`object` crate) only needs the `.o` files.

*Risks.* Object emission location/naming must be captured; `-C extra-filename` interacts with output paths. If a unit is CA and you add obj emission, its output hash changes — segregate the panic-scan build from the cache-shared build if you keep CA anywhere. Modest.

#### Change 7 — Fold clippy into the primary compile via `clippy-driver` as the compiler. **Magnitude: eliminates one extra frontend compile per candidate unit.**

*The change.* Rather than a separate `clippy-driver` derivation emitting `dep-info,metadata`, run `clippy-driver` *as* the compiler for the unit's metadata derivation (it is rustc + extra lints and produces the same `.rmeta`). Take its artifacts. This is the `RUSTC_WORKSPACE_WRAPPER` pattern Cargo uses for `cargo clippy`.

*Why it's fast.* clippy-driver *is* rustc with additional lint passes; running it once yields both the metadata and the lint results, versus compiling the frontend twice. rules_rust similarly treats clippy as an output group (`clippy_output_diagnostics`) on the same compile graph.

*Risks.* clippy's extra passes make the metadata derivation slower and its output potentially less reproducible; if you've split metadata/codegen (Change 1), attach clippy to the metadata node only. Lint-driven failures now fail the build unless you keep `--cap-lints`/error-format handling. Moderate.

#### Change 8 — Coarsen the external-dependency tier; keep per-unit only for workspace crates (hybrid). **Magnitude: fewer derivations + better cache sharing on the tier that changes rarely.**

*The change.* Build the external/crates.io dependency tier as coarser derivations (per-package, or even a single vendored-deps derivation with an internal Cargo/incremental cache), and reserve fine per-unit granularity for workspace crates where incrementality actually pays. This is the crossover the crate2nix/crane discussions identify.

*Why it's fast.* The Crane discussion (#539) and cargo2nix retrospective (Tweag) both note per-crate benefits are "overstated" for the external tier: as the #539 commenter put it, "if you have 4 rust packages each will want a different combination of: exact tokio version, exact tokio features, exact toolchain version and you won't get any sharing anyway," while the fixed per-derivation overhead is paid in full. Coarsening the rarely-changing tier cuts derivation count and NAR-hash churn without hurting incrementality (which lives in the workspace tier).

*Risks.* You lose per-unit early cutoff on dependencies — but that early cutoff is already capped by rmeta oversensitivity, so little is lost. Requires a second build path (coarse) alongside the fine one; more renderer complexity.

#### Change 9 — Shrink input closures: drop transitive `-L dependency=` where `--extern` suffices. **Magnitude: smaller `.drv` inputs → faster eval, fewer scheduler edges, better cache hits.**

*The change.* Modern rustc resolves direct dependencies through `--extern name=path`; the transitive `-L dependency=…/lib` search paths are needed only when the compiler must *find* transitively-referenced rlibs not named via `--extern` (e.g., for linking, or for `-Zshare-generics` monomorphization). Audit whether metadata/check derivations can drop transitive `-L` entirely and depend only on direct `--extern` rmeta. Link derivations still need the full rlib closure.

*Why it's fast.* Every `-L dependency=` entry is an input edge in the derivation, inflating the input closure, the `.drv`, eval time, and scheduler fan-out. Trimming to direct-`--extern`-only for the frontend/metadata pass shrinks the graph to what pipelining actually needs.

*Risks.* If a crate re-exports a transitive type used in a generic instantiated downstream, the compiler may need the transitive rmeta on the search path; test carefully. This is precisely the "sensitive only to the subset exposed via direct deps" observation in the RDR goal doc — the ideal is direct-dep-only, but rustc today is coarser. Verify per-profile.

#### Change 10 — Fix the `checkedRoots` parenthesization bug. **Magnitude: correctness prerequisite; no perf but blocks safe refactors.**

*The change.* In Nix, list elements are juxtaposition, so a bare `withPolicyChecks units."x"` written inside a `[ … ]` literal parses as **two separate list elements**, not as the function application `withPolicyChecks(units."x")`. The fix is explicit parentheses: `[ (withPolicyChecks units."x") ]`. Add an eval-level test — `nix-instantiate --parse` alone won't catch it (it's syntactically valid); you need `nix eval` on the attribute to observe the wrong element count.

*Why it matters.* Silent list-vs-application bugs corrupt `checkedRoots` membership, which can silently drop policy checks — a correctness hole that also undermines trust in any caching refactor.

### 3. A clean-sheet redesign

If I threw away the current structure, here is the architecture I'd build, in priority order of the ideas above:

**Scheduler.** Keep Nix as the *outer* hermetic layer (toolchain, source, cache) but move the *inner* fine-grained scheduling to a real incremental scheduler. Two credible variants:

- **(A) Nix-native, pipelined, dynamic-derivations.** Emit a compact **intermediate JSON** unit graph (not thousands of literal Nix attrsets) consumed by a small Nix reader via `builtins.fromJSON`, which is far lighter on the evaluator than 10^5 literal thunks. Then use **RFC 92 dynamic derivations** to generate the per-unit `.drv`s *at build time* rather than eval time — this eliminates eval scaling entirely and removes the test-discovery IFD (`testManifestDrv`), because test binaries can enumerate their own tests and emit child derivations from inside the build. **Status caveat: this is experimental and brittle.** Dynamic derivations require `nix@d904921`-era builds with `dynamic-derivations ca-derivations recursive-nix` enabled (Farid Zakaria's 2025 write-ups), the milestone (#39) is open, and `outputOf` monadic join is incomplete (#12727). I would prototype it but not ship production on it in 2026. Combine with the metadata/codegen split (Change 1) so the dynamic graph is pipelined.

- **(B) Bazel/Buck2 for scheduling, Nix for the toolchain only.** Let rules_rust (`--pipelined_compilation`) or Buck2's Rust rules do metadata/codegen splitting, action-level caching, remote execution, and dynamic deps natively; Nix supplies only the hermetic toolchain and a pinned crate universe. **Gained:** a mature incremental scheduler, RE against REAPI backends (BuildBuddy/EngFlow/NativeLink), native pipelining, better critical-path scheduling than `nix build`. **Lost:** Nix purity as the single story, nixpkgs integration, and the "one tool" simplicity. **Maturity caveat:** reindeer/rules_rust for third-party crates work but remain "awkward" (ekzhang's notes), proc-macros under remote execution have known breakage (buck2#1206, #395), and you re-specify deps per package. This is the right answer if build performance is the dominant business constraint and you can afford the migration.

My recommendation: **pursue (A)'s cheap parts immediately** (JSON intermediate + `fromJSON`, metadata/codegen split, static builder, lazy trees, linker swap, merged doctests) — these are all achievable inside the current Nix-as-scheduler model — and **run a time-boxed (B) spike** to quantify what a real scheduler + RE buys you, because that number determines whether the deeper Nix work (dynamic derivations) is worth it or whether you should migrate.

**Identity/hashing.** Replace truncated SHA-256 with **BLAKE3** for the identity hash — it's much faster and equally suitable for non-adversarial identity. But **widen the truncation**: at ~10^4 units the birthday bound on 8 bytes (64 bits) is comfortable (~10^-11 collision probability at 10^4), but if you go to 10^5–10^6 units or fold in metadata/codegen/clippy/obj variants you're inflating the population; use at least 12–16 bytes. Keep the two-pass memoized structure (toolchain-agnostic then toolchain-salted) but make the metadata-node hash exclude codegen-only profile fields so metadata stays stable across opt-level changes.

**Source scanning.** Replace the textual `include!`/`include_bytes!`/`include_str!` scanner with `memchr`/`aho-corasick` prefiltering for the common case (fast, no false-negative risk on the literal macro names), and fall back to a real lexer (`ra_ap_syntax` or `syn`/`proc-macro2`) only on files that prefilter-match, to resolve the actual path arguments precisely and stop over-approximating closures. Parallelize the directory walk with `ignore`/`jwalk` + `rayon`.

**Renderer.** `simd-json`/`sonic-rs` for the unit-graph parse, `rayon` over the DAG for the hash passes, cache `Cargo.toml` parses in a map keyed by manifest path, and replace the `{{ name }}` string-splice engine (which panics on unknown placeholders) with a typed emitter — ideally emit the JSON intermediate above rather than literal Nix.

**Testing the emitter.** Add cheap eval-level tests: `nix-instantiate --parse units.nix` (catches parse errors), and `nix eval --dry-run`/`nix eval .#units --apply builtins.attrNames` against a fixture workspace (catches the list-vs-application class like `checkedRoots`). The current "all 55 tests assert on substrings of emitted text" gap is a real risk multiplier for every refactor above.

### 4. Explicit dead ends

- **Content-addressed derivations as the early-cutoff mechanism.** Three independent reasons it doesn't pay at this scale in 2026: (1) rustc `.rmeta` is oversensitive — the RDR goal doc lists "changing a comment, reordering use statements, adding a `dbg!` statement to a non-inlinable function, formatting code, or moving item definitions from one impl block to another identical one" as all forcing rebuilds because the serialized source map carries per-file hashes and spans; (2) rustc byte-reproducibility is best-effort, not guaranteed — MCP #1005 explicitly plans a `--deterministic` flag because the parallel frontend is nondeterministic ("we propose not blocking stabilization of the parallel frontend on resolving the determinism issues, but instead provide an option that allows to request determinism"), and there's documented environment-dependent rmeta-section nondeterminism (rust#113584) that "disappeared" between 1.72 and 1.76 with no identified fix; (3) CA in Nix still has open realisation bugs (the "already have another one locally" conflict and #15969-class crashes). Your doc already found CA's benefit "capped"; the literature confirms the cap is structural until RDR ships. **Do not invest more in CA;** bet on RDR + input-closure shrinking. (If you keep CA anywhere, force single-threaded frontend, pinned `codegen-units`, and path/time normalization — necessary but not sufficient conditions per MCP #1005.)

- **Parallel frontend (`-Zthreads=N`) as a default.** ~20–30% frontend speedup under 8 cores sounds great (the WG measured "clean build... time by about 30% on average" at 8 cores/8 threads), but (a) it's nightly-only and not stabilized as of 2026 (project goal ongoing; MCP #1005 lays out the *strategy*, not a ship date), (b) it's explicitly nondeterministic, which poisons any content-addressed or reproducibility-dependent path, and (c) in a derivation-per-unit model each rustc is already one of thousands running in parallel across `max-jobs` — you get parallelism from the *graph*, so per-invocation frontend threads mostly compete for the same cores. Use it only for the few tall long-pole crates, not globally.

- **`sccache` on top of per-unit Nix caching.** Redundant: Nix already content-caches each unit's output; layering sccache adds a second cache with its own Rust caveats (it historically didn't cache incremental/some crate types well and had known pipelining interactions — the pipelining tracking issue explicitly notes "Cargo pipelining is known to break with sccache"). The one place a compilation cache helps is *inside* coarse external-tier derivations (Change 8) or inside build-script C/C++ (`ccache` for `cc-rs` crates), not for the rustc units themselves.

- **`-Zbuild-std` to "optimize" std.** It rebuilds std per config, adding enormous cold-build cost and forcing the std source remap you already handle; precompiled std is faster for virtually all cases. Only justified for `no_std`/custom-target/panic-strategy needs.

- **Maximizing `NIX_BUILD_CORES` per unit.** Most units are single-threaded rustc frontend work; handing each unit many cores wastes them. The right split for this workload is **high `max-jobs`, low `cores`** (e.g., `cores=1–2`), so the scheduler runs many single-threaded rustc processes concurrently — the opposite of the usual "few big parallel builds" tuning. The tall codegen/LTO/link units are the exception; if you can mark them (`big-parallel`-style, or with more cores) selectively, do so.

- **One derivation per `#[test]` as a general policy.** It's a win only when tests are genuinely long-pole and isolation matters; below that it's pure per-derivation overhead multiplied by test count. Prefer nextest's process-per-test model (up to ~3x faster than `cargo test`, "especially in massive workspaces where the standard runner's overhead becomes significant" per JetBrains, corroborated by nextest's own benchmarks) with `--partition hash:i/n` sharding across CI runners, and reserve per-test derivations for the specific suites where flaky isolation or caching of individual results actually pays.

### 5. Open questions / what the literature doesn't answer

- **No published numbers exist for Nix-as-scheduler pipelining.** rules_rust and Buck2 have the metadata/codegen split, but nobody has published the metadata-derivation-vs-codegen-derivation decomposition *inside Nix* at 10^3–10^4 units. The magnitude of Change 1 in your specific context is genuinely unmeasured — the reasoning (rmeta finishes before codegen; frontend chain parallelizes) is sound, but you must measure it. This is the single most important thing to prototype and benchmark.
- **Eval cost of `builtins.fromJSON` + small reader vs thousands of literal attrsets at this exact scale** is not quantified in the literature I found; the thunk-count argument favors JSON, but you should A/B it with `NIX_SHOW_STATS`.
- **Dynamic derivations' production-readiness timeline** is unknown; it's experimental, brittle, and the monadic `outputOf` join is incomplete (#12727). Whether it can carry a 10^4-unit graph in 2026 is unproven.
- **When RDR ("Relink don't Rebuild") ships and how complete it will be** is open — PR #143249 is blocked (macro hygiene, thiserror-style span dependence: bjorn3 noted "this didn't work yet due to the macro hygiene info getting destroyed"), and the Nov 2025 project-goals update had "no detailed updates available." Your workspace-edit cache-hit ceiling is gated on this, and it may be years.
- **The precise crossover unit-count** where per-derivation overhead overtakes rustc time depends on your graph's shape (frontend-heavy vs codegen-heavy crates) and hasn't been characterized for Rust workspaces specifically; the Discourse benchmark is for *trivial* builders, so it's an upper bound on the overhead *fraction*, not a direct number for real rustc units.

## Recommendations

**Stage 0 — Measure before changing anything (days).** Build twice and diff rmeta/rlib to establish whether your outputs are even byte-reproducible (gates every CA decision). Run `-Zself-profile` on the tallest crates, `nix-eval-jobs` for eval wall time, and `nix-output-monitor` to see scheduler stalls. Decision threshold: if eval is >20% of cold wall time, prioritize the JSON-intermediate/`fromJSON` refactor; if per-derivation overhead (idle CPU during scheduling) is high, prioritize the static builder.

**Stage 1 — Cheap, high-confidence wins (weeks), inside the current architecture.** (a) Adopt lazy trees + `builtins.path{name="source";}` rewrite. (b) Swap linker to rust-lld default, `wild` opt-in on Linux CI, and cut dependency-tier debuginfo. (c) Merged doctests on edition 2024. (d) Collapse the panic-scan double compile to `--emit=link,obj`. (e) Fix the `checkedRoots` paren bug and add `nix-instantiate --parse` + `nix eval` fixture tests. (f) Tune `nix.conf`: high `max-jobs`, `cores=1–2`, raised `http-connections`/`max-substitution-jobs`, and an Attic or Harmonia cache (Harmonia 3.x now reads store metadata directly from `db.sqlite`, halving narinfo latency) with a `post-build-hook` push. These are low-risk and independently shippable.

**Stage 2 — The structural bet (months).** Prototype the metadata/codegen derivation split (Change 1) on a representative workspace and **measure cold and one-crate-edit wall time**. Benchmark threshold: if it doesn't beat the current cold build by >15% on a deep release graph, keep it profile-gated to release/deep graphs only. In parallel, move to the static minimal builder (Change 2), the JSON intermediate + `fromJSON` reader, and coarsen the external tier (Change 8).

**Stage 3 — Decide the scheduler question (quarter).** Run a time-boxed Buck2/rules_rust-with-Nix-toolchain spike with remote execution against one REAPI backend. Threshold: if RE + native pipelining + action caching beats the best Nix-native result by a factor that justifies losing nixpkgs integration and Nix purity for your team, migrate the scheduler and keep Nix for the toolchain/crate universe; otherwise invest the same effort into the dynamic-derivations path once it stabilizes.

**Do not** invest further in content-addressed derivations, `-Zbuild-std`, sccache-over-Nix, or global `-Zthreads` — the evidence says these are dead ends or net-negative at this scale today.

## Caveats
- Several magnitudes here are explicitly **unmeasured in this system's context** (notably the in-Nix pipelining split); I have flagged each with the reasoning and the benchmark that would confirm it. Treat the ranking as evidence-informed hypotheses, not guarantees.
- The strongest quantitative anchors (2x stdenv overhead, ~50% link time / 7x link reduction / 40% end-to-end in ripgrep debug, 3x lazy-trees eval, up-to-3x nextest, ~20–30% parallel frontend, up-to-1.2x pipelining) come from *adjacent* benchmarks (trivial builders, ripgrep, disko, generic workspaces), not from `nix-cargo-unit` itself; the direction transfers but the exact figures will differ.
- Nightly/experimental dependencies (parallel frontend, dynamic derivations, `wild`, merged-doctest flags on non-2024 editions, `-Zembed-metadata=no` — the latter now landed in Cargo as `-Zno-embed-metadata`/`-Zembed-metadata=no`, worth adopting to shrink NAR-hashed rlibs) carry stability and reproducibility risk; pin toolchains and re-verify each on your target `rustc`.
- The rustc/Cargo/Nix landscape here is moving fast; the most time-sensitive claims (RDR status, dynamic-derivations readiness, `-Zembed-metadata` stabilization, `wild` maturity) are current only as of mid-2026 and should be re-checked before committing engineering to them.
