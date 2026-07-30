# `buildWorkspace`: the whole pipeline, wired. Cargo.lock becomes a vendor tree,
# the vendored workspace is planned into a unit graph, the graph is rendered into
# `units.nix`, and importing that yields one derivation per rustc unit.
#
# Every decision this file makes is a composition of the surrounding modules;
# none of the mechanisms live here.
{
  lib,
  pkgs,
  nixCargoUnit,
  rustToolchain,
  hostTriple,
  checks,
  graph,
  policyLib,
  prebuilt,
  rustflags,
  testRun,
  vendor,
}: let
  inherit (builtins) attrNames length toString;
in
  /**
  Build a Rust workspace as one Nix derivation per Cargo rustc unit.

  Every generated unit gets a scoped source input: workspace crates receive
  their own package root, registry and git crates their own vendored package
  directory. A source edit in `crates/api` does not change the Nix input for
  `crates/worker`, `itoa`, or `ryu`; a `Cargo.lock` update for one transitive
  crate leaves unrelated vendored crate derivations alone.

  Roots are consumed lazily. `binaries.<name>`, `libraries.<name>` and
  `targetSets.<set>.*` each reference one rustc unit derivation, so selecting a
  subset of roots never builds the others. Two exceptions, both shared-IFD
  discovery: `tests.<target>.cases` builds every test binary in the graph, and
  `doctests.<target>.cases` covers every doctest target.

  Two `buildWorkspace` calls that differ only in `cargoTargets` yield
  byte-identical root derivations and cost one extra plan plus render; create a
  separate workspace only when unit identity changes (profile, target, policy,
  env, rustc args).

  `env` and `extraRustcArgs` fold into every unit, so a value or native-library
  flag for one crate busts the whole dependency closure. Scope them with
  `packageBuildEnv.<package>` and `packageRustcArgs.<package>` instead.

  # Arguments

  Sources and identity
  - `src`: the tree units compile from.
  - `workspaceRoot`: the real checkout root package scopes are carved from. Pass
    `./.` for a local workspace so `src` can stay a filtered build input;
    fetched or patched sources pass `src`.
  - `cargoLock`: defaults to `<src>/Cargo.lock`.
  - `outputHashes`: git dependency hashes, keyed by the exact `Cargo.lock` source
    string (including the locked rev), so a multi-package git repo shares one
    tree hash without losing package identity.
  - `sourceOverrides`: replace a git source's fetched tree, keyed the same way.
  - `pname`: names the workspace-level policy check derivations.

  What cargo plans
  - `cargoTargets`: one entry per cargo invocation, merged into one graph, e.g.
    `[ [ "--workspace" ] [ "--workspace" "--tests" ] ]`. Include `--benches` or
    `--bench <name>` to expose `[[bench]]` roots under `benchmarks` and
    `benchmarkPlan`.
  - `cargoTargetNames`: names for `targetSets`; defaults to list indices.
    Top-level `binaries`/`libraries` dedupe by Cargo target name with the first
    `cargoTargets` entry winning, so a crate that roots under several entries
    must be selected through `targetSets.<set>`.
  - `profile`, `target`: both fold into every unit hash.

  Build inputs and flags
  - `env`, `nativeBuildInputs`, `cargoExtraConfig`: workspace-wide.
  - `extraRustcArgs`, `extraRustcArgsForPlatform`, `packageRustcArgs`.
  - `extraLinkRustcArgsForPlatform`: applied only to units that link.
  - `cargoConfigRustflags`: apply the rustflags a normal `cargo build` would read
    from `<workspaceRoot>/.cargo/config.toml`, which this pipeline otherwise
    ignores (it assembles rustc args itself instead of going through cargo).
    Resolved per target triple with cargo precedence; `cfg(...)` sections and
    `[env]` are not honored. Off by default.
  - `packageBuildEnv`: per-package build env.
  - `contentAddressed`: emit CA-derivation attributes on units. Needs the
    `ca-derivations` experimental feature.

  Policy and tests
  - `policy`: the quality gates, linker choice and test-runner settings. See
    `policy.nix`; `policyPresets` names the recurring combinations.
  - `testRunPrelude`, `packageTestInputs`, `packageTestEnv`: test-run wiring.

  Prebuilt injection
  - `extraUnits`, `extraLibraries`: link against already-compiled artifacts. See
    `mkPrebuiltLibraryUnit`.

  # Result

  The rendered graph's own attributes — `units`, `roots`, `packages`,
  `binaries`, `libraries`, `benchmarks`, `tests`, `doctests`, `targetSets`,
  `sourceAudit`, `policyChecks`, `testPlan`, `benchmarkPlan`, `coverageReport`,
  `makeCoverageReport`, `compareTangoBenchmarks`, `clippyByPackage`,
  `unusedCrateDependenciesByPackage` — extended with:

  - `testChecksByTarget` / `testChecksAll`: the policy-selected runner per test
    target, and one aggregate over all of them.
  - `policy`: the resolved policy, so a selector can read the gates back.
  - `plannerSource`, `unitGraphJson`, `unitsNix`, `vendorDir`,
    `cargoConfigScript`: the pipeline's intermediate stages, buildable on their
    own. `unitGraphJson`'s paths carry the planner stub's store prefix, not
    `src`'s.

  Coverage: build with `extraRustcArgs = [ "-Cinstrument-coverage" ]` and consume
  `coverageReport`'s `$out/lcov.info`. The toolchain must provide matching
  `llvm-cov` and `llvm-profdata`, or pass explicit tool paths to
  `makeCoverageReport`.
  */
  {
    src,
    workspaceRoot ?
      throw ''
        cargoUnit.buildWorkspace requires workspaceRoot = ./path/to/workspace.
        Use workspaceRoot for the real checkout root that package-shaped sources can be carved from.
        Fetched or patched sources pass workspaceRoot = src.
      '',
    pname ? "cargo-unit-workspace",
    cargoLock ? src + "/Cargo.lock",
    outputHashes ? {},
    sourceOverrides ? {},
    policy ? {},
    profile ? "release",
    target ? null,
    cargoTargets ? [["--workspace"]],
    cargoTargetNames ? null,
    contentAddressed ? true,
    env ? {},
    nativeBuildInputs ? [],
    cargoExtraConfig ? "",
    extraRustcArgs ? [],
    extraRustcArgsForPlatform ? _platform: [],
    extraLinkRustcArgsForPlatform ? _platform: [],
    cargoConfigRustflags ? false,
    packageBuildEnv ? {},
    packageRustcArgs ? {},
    packageTestEnv ? {},
    packageTestInputs ? {},
    testRunPrelude ? "",
    extraUnits ? {},
    extraLibraries ? {},
  }: let
    resolvedPolicy = policyLib.resolvePolicy policy;

    # Lazy: a consumer that only wants `unitGraphJson` never forces the fetches.
    inherit
      (vendor.mkVendor {
        inherit cargoLock outputHashes sourceOverrides;
      })
      vendorDir
      vendorSources
      ;

    configScript = vendor.configScript {inherit cargoExtraConfig cargoLock vendorDir;};

    plannerSource = graph.plannerSource src;

    unitGraphJson = graph.unitGraphJson {
      inherit
        plannerSource
        configScript
        cargoTargets
        profile
        target
        env
        nativeBuildInputs
        ;
    };

    unitsNix = graph.unitsNix {
      inherit
        src
        plannerSource
        unitGraphJson
        vendorDir
        cargoLock
        ;
      renderFlags =
        lib.optional contentAddressed "--content-addressed"
        ++ policyLib.renderFlags resolvedPolicy;
    };

    platformArgs = rustflags.forWorkspace {
      policy = resolvedPolicy;
      inherit workspaceRoot cargoConfigRustflags;
      compileArgsForPlatform = extraRustcArgsForPlatform;
      linkArgsForPlatform = extraLinkRustcArgsForPlatform;
    };

    clippyEnabled = resolvedPolicy.clippy.enable;

    # Import the rendered `units.nix`. `toolchain` is a parameter only because
    # the clippy graph needs clippy's own rustc; `seam` is the prebuilt
    # injection.
    importUnits = {
      toolchain,
      seam,
    }:
      import unitsNix (
        {
          inherit
            pkgs
            src
            vendorDir
            vendorSources
            workspaceRoot
            extraRustcArgs
            packageBuildEnv
            packageRustcArgs
            packageTestEnv
            packageTestInputs
            testRunPrelude
            clippyEnabled
            ;
          rustToolchain = toolchain;
          # Scanner for the opt-in panic-freedom policy. The rendered check
          # asserts this is non-null when `policy.denyPanics` is set.
          cargoUnit = nixCargoUnit;
          extraEnv = env;
          extraNativeBuildInputs = nativeBuildInputs ++ policyLib.linkerNativeInputs resolvedPolicy;
          # `clippy-driver` ships in the clippy package; `rustToolchain` only
          # guarantees rustc + cargo. Adding the resolved clippy package keeps
          # version drift impossible because the toolchain pins the rustc that
          # `clippy-driver` links against.
          extraClippyNativeBuildInputs = lib.optional clippyEnabled resolvedPolicy.clippy.package;
          extraClippyLintArgs = policyLib.clippyLintArgs {
            policy = resolvedPolicy;
            manifest = src + "/Cargo.toml";
          };
          extraRustcArgsForPlatform = platformArgs.compile;
          extraLinkRustcArgsForPlatform = platformArgs.link;
          testArgsByPackage = testRun.libtestArgsByPackage resolvedPolicy;
          extraPolicyChecks = checks.workspaceChecks {
            inherit
              pname
              src
              cargoLock
              vendorDir
              cargoExtraConfig
              env
              nativeBuildInputs
              ;
            policy = resolvedPolicy;
          };
        }
        // seam
      );

    noSeam = {
      extraUnits = {};
      extraLibraries = {};
    };

    # The from-source graph, used to validate the injection keys. Its `units` and
    # `libraries` are only forced when there is an injection to validate.
    fromSource = importUnits {
      toolchain = rustToolchain;
      seam = noSeam;
    };

    units = importUnits {
      toolchain = rustToolchain;
      seam = prebuilt.resolveInjection {
        inherit extraUnits extraLibraries;
        unitKeys = attrNames fromSource.units;
        libraryKeys = attrNames fromSource.libraries;
      };
    };

    # Clippy is a rustc_private binary tied to its own pinned rustc, so its graph
    # is imported with that exact toolchain: every dependency rlib it reads must
    # come from the same rustc ABI. The build and test graph keeps the workspace
    # toolchain and its prebuilt injections.
    clippyUnits = importUnits {
      toolchain = resolvedPolicy.clippy.package.toolchain;
      seam = noSeam;
    };

    targetSetNames =
      if cargoTargetNames == null
      then lib.genList toString (length cargoTargets)
      else
        assert lib.assertMsg (
          length cargoTargetNames == length cargoTargets
        ) "cargoUnit.buildWorkspace requires cargoTargetNames to match cargoTargets length"; cargoTargetNames;

    testChecks = testRun.testChecks {
      tests = units.tests or {};
      policy = resolvedPolicy;
      targetTriple =
        if target == null
        then hostTriple
        else target;
      inherit
        testRunPrelude
        packageTestInputs
        packageTestEnv
        ;
    };
  in
    assert lib.assertMsg (cargoTargets != []) "cargoUnit.buildWorkspace requires at least one cargoTargets entry";
      units
      // lib.optionalAttrs clippyEnabled {inherit (clippyUnits) clippyByPackage;}
      // {
        inherit
          plannerSource
          unitGraphJson
          unitsNix
          vendorDir
          ;
        policy = resolvedPolicy;
        cargoConfigScript = configScript;
        targetSets = lib.listToAttrs (lib.zipListsWith lib.nameValuePair targetSetNames units.targetSets);
        testChecksByTarget = testChecks.byTarget;
        testChecksAll = testChecks.all;
      }
