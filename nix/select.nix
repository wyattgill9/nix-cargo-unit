# Picking one root out of a built workspace and wiring it for consumption:
# `passthru.tests` gets the crate's test cases, doctests and per-crate policy
# gates, so a selected root is a complete package rather than a bare artifact.
{lib}: let
  inherit (builtins) filter hasAttr;

  # One lookup for every selector: fail with the calling selector's name and the
  # full set of available keys, so a typo'd target name reads as a menu instead
  # of a bare missing-attribute error.
  rootOrThrow = caller: kind: roots: name:
    roots.${name}
      or (throw "${caller}: no ${kind} `${name}` in workspace; available: ${lib.concatStringsSep ", " (builtins.attrNames roots)}");

  # Per-crate policy gates. Each crate gets its own clippy and
  # unused-crate-dependency check (referencing only its own units) instead of the
  # workspace-wide aggregates, so editing one crate rebuilds only its own checks.
  # cargoAudit is lockfile-scoped (one Cargo.lock) and stays at the workspace
  # level rather than being aliased onto every crate.
  #
  # `buildWorkspace` always sets `policy`, so the flags are present; the
  # per-package maps come from the renderer and are genuinely absent when it
  # emitted none, so those stay guarded.
  policyChecksFor = workspace: packageName:
    lib.optionalAttrs (
      workspace.policy.clippy.enable && (workspace.clippyByPackage or {}) ? ${packageName}
    ) {clippy = workspace.clippyByPackage.${packageName};}
    // lib.optionalAttrs (
      workspace.policy.denyUnusedCrateDependencies
      && (workspace.unusedCrateDependenciesByPackage or {}) ? ${packageName}
    ) {unusedCrateDependencies = workspace.unusedCrateDependenciesByPackage.${packageName};};

  # Attach a selected root's tests and policy gates. Each discovered test case is
  # its own derivation; `<target>-all` is the whole harness in one, for callers
  # that want a single check.
  selectRoot = workspace: {
    rootDrv,
    packageName,
    defaultTestTargets,
    meta,
    passthru,
  }: let
    uncheckedRoot = rootDrv.passthru.unchecked or rootDrv;

    namesForPackage = attrName: fallback:
      if hasAttr attrName workspace && hasAttr packageName workspace.${attrName}
      then workspace.${attrName}.${packageName}
      else fallback;

    testTargets = namesForPackage "testTargetNamesByPackage" defaultTestTargets;
    doctestTargets = namesForPackage "doctestTargetNamesByPackage" [];

    presentTargets = targetNames: targets:
      lib.getAttrs (filter (name: targets ? ${name}) targetNames) targets;

    wholeHarnesses = prefix: targetNames: targets:
      lib.mapAttrs' (targetName: target: lib.nameValuePair "${prefix}${targetName}-all" target.all) (
        presentTargets targetNames targets
      );

    cases = prefix: targetNames: targets:
      lib.concatMapAttrs (
        targetName: target:
          lib.mapAttrs' (
            case: drv:
              lib.nameValuePair "${prefix}${targetName}-${lib.replaceStrings ["::"] ["-"] case}" drv
          ) (target.cases or {})
      ) (presentTargets targetNames targets);

    policyChecks = policyChecksFor workspace packageName;

    tests =
      {
        package = uncheckedRoot;
      }
      // wholeHarnesses "" testTargets (workspace.tests or {})
      // wholeHarnesses "doctest-" doctestTargets (workspace.doctests or {})
      // cases "" testTargets (workspace.tests or {})
      // cases "doctest-" doctestTargets (workspace.doctests or {});
  in
    rootDrv
    // {
      meta = (rootDrv.meta or {}) // meta;
      passthru =
        (rootDrv.passthru or {})
        // passthru
        // {
          tests = (rootDrv.passthru.tests or {}) // policyChecks // (passthru.tests or {}) // tests;
          inherit policyChecks;
          inherit (workspace) policy;
        };
    };
in {
  /**
  Select one binary target from a built workspace.

  Test and doctest targets are every generated target owned by `packageName`.
  `meta` is merged onto the selected derivation, so a caller can set
  `meta.mainProgram` and have `lib.getExe` resolve without guessing.
  */
  selectBinary = workspace: {
    binary,
    packageName ? binary,
    meta ? {},
    passthru ? {},
  }:
    selectRoot workspace {
      rootDrv = rootOrThrow "selectBinary" "binary" (workspace.binaries or {}) binary;
      defaultTestTargets = [binary];
      inherit
        packageName
        meta
        passthru
        ;
    };

  /**
  Select one library target from a built workspace.

  `library` is the crate's library unit key (Cargo's underscored name, e.g.
  `my_crate`); `packageName` is the Cargo package name its test targets are
  looked up by (e.g. `my-crate`).
  */
  selectLibrary = workspace: {
    library,
    packageName,
    meta ? {},
    passthru ? {},
  }:
    selectRoot workspace {
      rootDrv = rootOrThrow "selectLibrary" "library" (workspace.libraries or {}) library;
      defaultTestTargets = [packageName];
      inherit
        packageName
        meta
        passthru
        ;
    };
}
