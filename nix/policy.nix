# Build policy: the quality gates applied to a workspace (unused-dependency
# denial, panic freedom, cargo-audit, cargo-machete, clippy), the test runner
# settings, and the linker choice — declared once as module options so the
# defaults, the caller merge, and typo rejection all come from one place.
#
# This module is pure: it declares the schema, resolves a caller's partial
# policy against it, and turns a resolved policy into flags. The derivations a
# policy implies live in `checks.nix` (workspace gates) and in the renderer
# (per-unit gates).
{
  lib,
  pkgs,
}: let
  inherit (builtins) removeAttrs;

  toFlagSequence = flag:
    lib.concatMap (arg: [
      flag
      arg
    ]);

  # Pinned source revisions, kept out of the expressions so a bump is a
  # one-line JSON edit rather than an inline hash literal.
  pins = lib.importJSON ./pins.json;

  # "No policy" for a package the caller did not list under `tests.byPackage`.
  # Declared here so it is also the submodule's own defaults and the two cannot
  # drift.
  noTestPolicy = {
    skip = [];
    testThreads = null;
  };

  # The per-package test policy: what the runners are told, expressed as data
  # rather than as runner-specific argv. `test-run.nix` renders it to libtest
  # arguments and to cargo-nextest filters.
  testPolicyModule = {
    options = {
      skip = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = noTestPolicy.skip;
        description = "Test names to skip.";
      };
      testThreads = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = noTestPolicy.testThreads;
        # A string, not an int: cargo-nextest also accepts `num-cpus` here.
        description = "Concurrency for this package's harness (a count, or `num-cpus`).";
      };
    };
  };

  policyModule = {
    options = {
      denyUnusedCrateDependencies = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Fail a unit whose declared crate dependencies are unused (rustc gate).";
      };
      # Opt-in: scans each unit's objects for functions that can reach a panic.
      # Off by default because it is a best-effort gate, not a soundness proof.
      denyPanics = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Scan each unit's objects for functions that can reach a panic (best-effort).";
      };
      cargoAudit = {
        # On by default: an offline, lockfile-only runCommand (`cargo-audit audit
        # --file Cargo.lock --no-fetch --stale`) decoupled from compilation, so it
        # re-runs only when the lockfile or DB changes. Opt out on pure-build graphs.
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Run the offline, lockfile-only cargo-audit check.";
        };
        db = lib.mkOption {
          type = lib.types.package;
          # The rev + SRI pin lives in the sibling pins.json; bump by editing
          # the rev there and re-pinning.
          default = pkgs.fetchFromGitHub {
            inherit
              (pins."advisory-db")
              owner
              repo
              rev
              hash
              ;
          };
          description = "The advisory database cargo-audit checks against.";
        };
        deny = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Advisory ids/warning kinds to escalate to errors.";
        };
        ignore = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Advisory ids to ignore.";
        };
      };
      cargoMachete = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Run cargo-machete to find unused dependencies across the workspace.";
        };
        extraArgs = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Extra arguments passed to cargo-machete.";
        };
      };
      clippy = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Run clippy-driver on every compile unit.";
        };
        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.clippy;
          description = ''
            The clippy package providing clippy-driver.

            Clippy is a rustc_private binary tied to the exact rustc it was
            built against, so the clippy graph is imported with this package's
            own `toolchain` rather than the workspace toolchain. A package
            without that attribute (nixpkgs' plain `clippy`) therefore only
            works with `enable = false`.
          '';
        };
        deniedLints = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Lints denied via `-D` (escape hatch; prefer Cargo.toml `[lints]`).";
        };
        allowedLints = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Lints allowed via `-A`.";
        };
      };
      tests = {
        useNextest = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Run each test target through cargo-nextest instead of the libtest harness.";
        };
        perTestTimeout = lib.mkOption {
          type = lib.types.str;
          default = "120s";
          description = "cargo-nextest slow-timeout period after which a single test is terminated.";
        };
        byPackage = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule testPolicyModule);
          default = {};
          description = "Per-package test-runner policy, keyed by Cargo package name.";
        };
      };
      linker = {
        useMold = lib.mkOption {
          type = lib.types.bool;
          default = pkgs.stdenv.hostPlatform.isLinux;
          description = "Link with mold on Linux.";
        };
        useLld = lib.mkOption {
          type = lib.types.bool;
          default = pkgs.stdenv.hostPlatform.isDarwin;
          description = "Link with lld on macOS (the default cctools ld64 is single-threaded and slow).";
        };
        buildId = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Emit a GNU build-id note into every ELF this policy links.

            The 20-byte `.note.gnu.build-id` is the join key every symbol
            consumer looks an address up by: the debuginfod protocol, a
            separate `.debug` file, `coredumpctl debug`, a continuous
            profiler's symbol cache, and coverage symbolization.
            Neither rustc nor mold emits one unless asked, so without this a
            linked binary is unsymbolizable by anything that does not already
            know its store path.

            `sha1` over the linked output rather than `uuid`, so the note is a
            function of the bytes and a reproducible build keeps a reproducible
            build-id. 20 bytes is also the length every consumer is actually
            tested against; mold computes sha256 and truncates either way, so
            the shorter note is not the slower one.
          '';
        };
      };
    };
  };

  # Named partial policies for recurring intents, so callers reference one name
  # instead of re-spelling the same field set. Resolved against the schema like
  # any caller policy. `pureBuild` turns off every gate: for a pure build
  # artifact (a cross graph, a prebuilt-injection graph) where the native graph
  # already ran clippy/audit/machete/unused-dep over the same sources.
  policyPresets = {
    pureBuild = {
      denyUnusedCrateDependencies = false;
      cargoAudit.enable = false;
      cargoMachete.enable = false;
      clippy.enable = false;
    };
  };

  # Resolve a caller's partial policy against the schema: defaults, merge, and
  # typo rejection all come from `evalModules`.
  resolvePolicy = userPolicy:
    removeAttrs
    (lib.evalModules {
      modules = [
        policyModule
        {config = userPolicy;}
      ];
    })
    .config ["_module"];

  testPolicyFor = policy: packageName: policy.tests.byPackage.${packageName} or noTestPolicy;

  # `platform` is a rust target triple (e.g. `x86_64-unknown-linux-gnu`); the fast
  # linker is per-OS, so each branch is gated on the triple: mold for a `-linux-`
  # triple, lld for an `-apple-darwin` triple. Callers pass a resolved triple
  # (`rustflags.nix` owns that resolution), so a non-triple argument fails loudly
  # instead of defaulting.
  #
  # The lld branch uses the `-B${pkgs.lld}/bin -fuse-ld=lld` incantation a
  # Linux->darwin cross toolchain needs (the `-B` makes the clang driver resolve
  # `ld64.lld`), but applies only to a *native* darwin link: it is additionally
  # gated on a darwin build host. The cross toolchain already injects
  # `-fuse-ld=lld` via `CARGO_TARGET_<T>_LINKER`, so without this host gate a
  # future darwin-host darwin-cross would stack the flag on that wrapper.
  linkerRustcArgsForPlatform = policy: platform:
    lib.optionals (policy.linker.useMold && lib.hasInfix "-linux-" platform) [
      "-C"
      "link-arg=-fuse-ld=mold"
    ]
    # Gated on the ELF-producing triple rather than on the linker choice: both
    # mold and bfd/lld accept `--build-id` and neither emits the note by
    # default, so the flag belongs to the platform, not to `useMold`.
    ++ lib.optionals (policy.linker.buildId && lib.hasInfix "-linux-" platform) [
      "-C"
      "link-arg=-Wl,--build-id=sha1"
    ]
    ++ lib.optionals
    (policy.linker.useLld && pkgs.stdenv.hostPlatform.isDarwin && lib.hasInfix "-apple-darwin" platform)
    [
      "-C"
      "link-arg=-fuse-ld=lld"
      "-C"
      "link-arg=-B${pkgs.lld}/bin"
    ];

  linkerNativeInputs = policy:
    lib.optional policy.linker.useMold pkgs.mold
    ++ lib.optional policy.linker.useLld pkgs.lld;

  # Cargo only emits `[lints.clippy]` into the unit graph's `lint_rustflags`
  # when invoked as `cargo clippy`, not `cargo build`. Parse the workspace
  # manifest and emit the equivalent `-D|-W|-A clippy::<lint>` flags so
  # per-unit clippy sees the workspace lint policy.
  manifestClippyLintArgs = manifestPath: let
    # `clippy::cargo` group lints invoke `cargo` to read workspace metadata.
    # Per-unit clippy runs in a sandboxed build directory without a discoverable
    # Cargo.toml (the unit's source closure is package-shaped), so those lints
    # error out with "could not find Cargo.toml". Skip them here; a future
    # workspace-level cargo-clippy check is the right home.
    cargoGroupClippyLints = [
      "cargo"
      "cargo_common_metadata"
      "multiple_crate_versions"
      "negative_feature_names"
      "redundant_feature_names"
      "wildcard_dependencies"
    ];

    manifest = lib.importTOML manifestPath;

    declared = manifest.workspace.lints.clippy or manifest.lints.clippy or {};

    entryFor = name: value: {
      inherit name;
      level = value.level or value;
      priority = value.priority or 0;
    };

    entries = lib.mapAttrsToList entryFor (removeAttrs declared cargoGroupClippyLints);

    levelFlags = {
      deny = "-D";
      forbid = "-D";
      warn = "-W";
      allow = "-A";
    };

    entryFlags = entry: let
      inherit (entry) level;
      levelFlag =
        levelFlags."${level}"
              or (throw "cargoUnit: unknown clippy lint level '${level}' in ${manifestPath}");
    in [
      levelFlag
      "clippy::${entry.name}"
    ];
  in
    lib.concatMap entryFlags (lib.sortOn (entry: entry.priority) entries);

  # Every `-D`/`-W`/`-A` flag appended to a per-unit clippy-driver invocation.
  # Manifest-derived flags come first so `policy.clippy` entries land later in
  # argv and can override them: Cargo's `[lints.clippy]` is the load-bearing
  # source for most workspaces, and the policy lists are the escape hatch for
  # callers without one.
  clippyLintArgs = {
    policy,
    manifest,
  }:
    manifestClippyLintArgs manifest
    ++ toFlagSequence "-D" policy.clippy.deniedLints
    ++ toFlagSequence "-A" policy.clippy.allowedLints;

  # The renderer flags a policy implies: both gates are emitted per unit by the
  # renderer, so they are decided at render time rather than at build time.
  renderFlags = policy:
    lib.optional policy.denyUnusedCrateDependencies "--deny-unused-crate-dependencies"
    ++ lib.optional policy.denyPanics "--deny-panics";

  # cargo-audit's own `--deny`/`--ignore` argv. Lives here rather than in
  # `checks.nix` so every policy-to-flags mapping is in one file.
  cargoAuditArgs = policy:
    toFlagSequence "--deny" policy.cargoAudit.deny
    ++ toFlagSequence "--ignore" policy.cargoAudit.ignore;
in {
  inherit
    cargoAuditArgs
    clippyLintArgs
    linkerNativeInputs
    linkerRustcArgsForPlatform
    policyPresets
    renderFlags
    resolvePolicy
    testPolicyFor
    ;
}
