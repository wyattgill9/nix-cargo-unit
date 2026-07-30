# Running the test targets a unit graph exposes. `policy.tests` says how; this
# module renders that policy into the two runners' argv and builds the check
# derivations.
#
# The libtest path is the harness binary the renderer already emits per target;
# the nextest path re-runs that same binary under cargo-nextest, which needs
# cargo metadata that no cargo ever produced here — `nix-cargo-unit
# nextest-metadata` synthesizes it from the target's identity.
{
  lib,
  pkgs,
  nixCargoUnit,
  policyLib,
  rustToolchain,
}: let
  inherit (builtins) attrNames;
  inherit (lib) escapeShellArg;

  libtestArgs = testPolicy:
    lib.concatMap (testName: [
      "--skip"
      testName
    ])
    testPolicy.skip
    ++ lib.optionals (testPolicy.testThreads != null) [
      "--test-threads"
      testPolicy.testThreads
    ];

  nextestFilter = testPolicy:
    lib.optionalString (testPolicy.skip != [])
    "-E ${escapeShellArg "not (${lib.concatMapStringsSep " | " (testName: "test(~${testName})") testPolicy.skip})"}";

  # Nix builders can attach cargo-nextest to a pseudo-terminal without carrying
  # the usual CI environment. Force the plain reporter path so progress redraws
  # cannot stall dispatcher handoffs.
  nonInteractiveEnv = {
    NEXTEST_HIDE_PROGRESS_BAR = "true";
    NEXTEST_NO_INPUT_HANDLER = "true";
    NEXTEST_SHOW_PROGRESS = "none";
  };
in {
  # The libtest args for each package that has test policy, in the shape
  # `units.nix` takes them. Packages without policy are absent, which the
  # template reads as "no extra args".
  libtestArgsByPackage = policy: lib.mapAttrs (_packageName: libtestArgs) policy.tests.byPackage;

  /**
  The policy-selected check for every test target in the graph, plus one
  aggregate that depends on all of them.

  `tests` is the renderer's `tests` set: `<target>.all` is the whole harness and
  `<target>.binary` the libtest executable nextest drives.
  */
  testChecks = {
    tests,
    policy,
    targetTriple,
    testRunPrelude,
    packageTestInputs,
    packageTestEnv,
  }: let
    rustLibDir = "${rustToolchain}/lib/rustlib/${targetTriple}/lib";

    nextestConfigFile = pkgs.writeText "cargo-unit-nextest.toml" ''
      [profile.default]
      retries = 0
      slow-timeout = { period = "${policy.tests.perTestTimeout}", terminate-after = 1 }
    '';

    nextestForTarget = targetName: entry: let
      inherit (entry) packageName;
      packageEnv = packageTestEnv.${packageName} or {};
      testPolicy = policyLib.testPolicyFor policy packageName;
    in
      pkgs.runCommand "cargo-unit-nextest-${targetName}"
      (
        packageEnv
        // nonInteractiveEnv
        // {
          __structuredAttrs = true;
          strictDeps = true;
          nativeBuildInputs =
            [
              pkgs.cargo-nextest
              pkgs.coreutils
              nixCargoUnit
            ]
            ++ (packageTestInputs.${packageName} or []);
        }
      )
      ''
        ${testRunPrelude}

        workspace_root="$TMPDIR/nextest-ws"
        mkdir -p "$workspace_root/src" "$workspace_root/target"
        cat > "$workspace_root/Cargo.toml" <<EOF
        [package]
        name = ${escapeShellArg packageName}
        version = "0.0.0"
        edition = ${escapeShellArg entry.edition}
        [lib]
        EOF
        : > "$workspace_root/src/lib.rs"

        test_binary="$(readlink -f ${escapeShellArg entry.binary})"
        if [ ! -x "$test_binary" ]; then
          echo >&2 "error: cargo-unit test binary missing or not executable: $test_binary"
          exit 1
        fi

        nix-cargo-unit nextest-metadata \
          --workspace-root "$workspace_root" \
          --target-name ${escapeShellArg targetName} \
          --package-name ${escapeShellArg packageName} \
          --edition ${escapeShellArg entry.edition} \
          --test-binary "$test_binary" \
          --target-triple ${escapeShellArg targetTriple} \
          --rust-libdir ${escapeShellArg rustLibDir} \
          --cargo-metadata "$workspace_root/cargo-metadata.json" \
          --binaries-metadata "$workspace_root/binaries-metadata.json"

        ${lib.concatStringsSep "\n" (map (name: "export ${name}") (attrNames packageEnv))}
        ${lib.concatStringsSep "\n" (map (name: "export ${name}") (attrNames nonInteractiveEnv))}

        cargo-nextest nextest run \
          --config-file ${nextestConfigFile} \
          --cargo-metadata "$workspace_root/cargo-metadata.json" \
          --binaries-metadata "$workspace_root/binaries-metadata.json" \
          --workspace-remap "$workspace_root" \
          --no-fail-fast \
          --no-tests=pass \
          --test-threads ${
          if testPolicy.testThreads != null
          then testPolicy.testThreads
          else ''"''${NIX_BUILD_CORES:-1}"''
        } \
          ${nextestFilter testPolicy}

        mkdir -p "$out"
        echo "ran ${targetName} test target" > "$out/result"
      '';

    byTarget =
      if policy.tests.useNextest
      then lib.mapAttrs nextestForTarget tests
      else lib.mapAttrs (_targetName: target: target.all) tests;
  in {
    inherit byTarget;

    all =
      pkgs.runCommand "cargo-unit-test-targets"
      {
        __structuredAttrs = true;
        strictDeps = true;
        deps = builtins.attrValues byTarget;
      }
      ''
        set -euo pipefail
        target_names=(${lib.escapeShellArgs (attrNames byTarget)})
        mkdir -p "$out"
        printf '%s\n' "''${target_names[@]}" > "$out/test-targets"
        echo "ran ''${#target_names[@]} cargo-unit test targets" > "$out/result"
      '';
  };
}
