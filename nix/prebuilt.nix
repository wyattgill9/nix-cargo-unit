# Linking a compile unit against an already-compiled rlib instead of building it
# from source: the unit builder, and the guards that decide whether a set of
# injections is coherent with the graph it is being injected into.
{
  lib,
  pkgs,
  toolchainId,
}: let
  inherit
    (builtins)
    attrNames
    elem
    filter
    genericClosure
    hasAttr
    head
    length
    replaceStrings
    ;

  # This import's toolchain id, under a name the `mkPrebuiltLibraryUnit`
  # argument of the same name does not shadow.
  workspaceToolchainId = toolchainId;
in {
  /**
  Build a library unit derivation from already-compiled artifacts.

  The result is byte-contract-identical to a library unit the renderer would
  emit (see the library-unit builder in `src/render.rs`): `$out` carries
  `$out/lib/lib<name>-<hash>.rlib`, the matching `.rmeta`, and
  `$out/nix-support/extern-path` holding the absolute path to the `.rlib`.
  A downstream unit therefore consumes it exactly like a from-source unit:
  `-L dependency=$out/lib` and `--extern <crate>=$(cat $out/nix-support/extern-path)`.

  Pass the produced derivation through `buildWorkspace`'s `extraUnits` (keyed by
  `"<name>-<version>-<hash>"`). Because a unit's `<hash>` hashes package
  identity, target, edition, crate-types, features, profile, dependency
  identities, and the toolchain id, but never the source bytes
  (`model.rs`, `hash.rs`), a metadata-faithful stub crate yields the same
  `<hash>` as the real prebuilt, so injecting this unit links a downstream crate
  against a prebuilt rlib with no source present.

  Scope: plain `rlib` libraries only. The artifact name and `extern-path`
  hardcode `.rlib`, so a `cdylib`, `staticlib`, or `proc-macro` crate (different
  artifact extension, and proc-macros load as host dylibs) is out of scope and
  would not link.

  Trust boundary: an injected prebuilt unit BYPASSES every per-unit policy gate
  (clippy, `--deny-panics`, unused-crate-dependencies) because those gates run
  on from-source compile units, not on a copied artifact. Inject only trusted
  artifacts (e.g. a first-party SDK rlib fetched from your own store).

  Arguments:
  - `pname`: the library unit's Cargo target name (the leading component of the
    unit key), which for a default `lib` target is the underscored crate name
    (e.g. package `my-lib` has target `my_lib`). Any dashes are mapped to
    underscores for the on-disk artifact names, matching the renderer.
  - `version`: the crate version, used only to build the unit key the caller
    injects under.
  - `hash`: the source-independent unit hash. Must equal the `<hash>` the
    renderer computes for the metadata-faithful stub the downstream graph sees,
    or the downstream `--extern`/`-L` references will not resolve to this unit.
  - `rlib` / `rmeta`: paths to the compiled artifacts.
  - `toolchainId`: the toolchain id the prebuilt was compiled with. Asserted
    equal to this import's toolchain id, so a mismatch fails at eval rather than
    at link time, and recorded in `passthru.toolchainId`.
  - `depUnits`: this prebuilt's own dependency unit derivations, each built with
    `mkPrebuiltLibraryUnit` (so each carries `passthru.unitKey`). Direct deps
    that each record their own `depUnits`, or a flattened transitive list,
    inject identically. `buildWorkspace` walks this transitively and
    auto-injects every recorded unit under its own key, so the caller injects
    only the root unit. Each auto-injected key must name a unit the consumer's
    graph already references, which holds exactly when the consumer's manifest
    pins the dependency closure the prebuilt was compiled against: the unit hash
    folds in dependency hashes recursively, so a root key match implies every
    dep key matches. An explicit `extraUnits` entry for a dep key overrides the
    recorded derivation. The deps are also recorded to
    `$out/nix-support/dependency-units` for provenance.
  */
  mkPrebuiltLibraryUnit = {
    # The Cargo library TARGET name (the renderer's unit-key/rlib component),
    # not a stdenv derivation name; named `pname` so a `version` sibling does
    # not read as a `name = "<pname>-<version>"` restatement.
    pname,
    version,
    hash,
    rlib,
    rmeta,
    toolchainId,
    depUnits ? [],
  }: let
    # The renderer underscores the Cargo target name for on-disk artifacts.
    # Mirror that exactly so the rlib filename and the `extern-path` contents
    # match what a from-source unit would produce.
    libName = replaceStrings ["-"] ["_"] pname;
    depsWithoutUnitKey = filter (dep: !(dep ? passthru.unitKey)) depUnits;
  in
    assert lib.assertMsg (toolchainId == workspaceToolchainId) ''
      cargoUnit.mkPrebuiltLibraryUnit: toolchainId mismatch for `${pname}`.
        prebuilt was compiled with: ${toolchainId}
        this workspace's toolchain: ${workspaceToolchainId}
      A prebuilt rlib/rmeta only links against the toolchain that produced it.
    '';
    # This builder is rlib-only (the filename and extern-path hardcode `.rlib`).
    # Reject an artifact that is clearly not an rlib/rmeta so a
    # cdylib/staticlib/proc-macro mistake fails loud at eval, not at link.
    assert lib.assertMsg (lib.hasSuffix ".rlib" (toString rlib)) ''
      cargoUnit.mkPrebuiltLibraryUnit: `rlib` for `${pname}` must be a .rlib path; got ${toString rlib}.
      Only plain rlib libraries are supported (not cdylib/staticlib/proc-macro).
    '';
    assert lib.assertMsg (lib.hasSuffix ".rmeta" (toString rmeta)) ''
      cargoUnit.mkPrebuiltLibraryUnit: `rmeta` for `${pname}` must be a .rmeta path; got ${toString rmeta}.
    '';
    # Auto-injection keys each dep by its `passthru.unitKey`, so an entry without
    # one could never be wired into a consuming graph. Reject it at construction,
    # naming the offender, instead of at injection time.
    assert lib.assertMsg (depsWithoutUnitKey == []) ''
      cargoUnit.mkPrebuiltLibraryUnit: depUnits for `${pname}` must be prebuilt unit
      derivations carrying `passthru.unitKey` (build them with mkPrebuiltLibraryUnit); got:
        ${lib.concatMapStringsSep "\n  " (dep: dep.name or "<non-derivation>") depsWithoutUnitKey}
    '';
      pkgs.runCommand "cargo-unit-prebuilt-${pname}-${version}-${hash}"
      {
        # Surfaced for callers/tests that want to confirm the injected key
        # without reconstructing the format string. `depUnits` is what
        # `buildWorkspace` walks to auto-inject this unit's transitive deps.
        passthru = {
          unitKey = "${pname}-${version}-${hash}";
          libraryName = libName;
          inherit
            pname
            version
            hash
            toolchainId
            depUnits
            ;
        };
      }
      ''
        mkdir -p "$out/lib" "$out/nix-support"
        cp ${lib.escapeShellArg (toString rlib)} "$out/lib/lib${libName}-${hash}.rlib"
        cp ${lib.escapeShellArg (toString rmeta)} "$out/lib/lib${libName}-${hash}.rmeta"
        # Same artifact priority as the renderer's library unit (.rlib wins over .rmeta).
        printf '%s\n' "$out/lib/lib${libName}-${hash}.rlib" > "$out/nix-support/extern-path"
        ${lib.concatMapStringsSep "\n" (
            dep: ''printf '%s\n' ${lib.escapeShellArg (toString dep)} >> "$out/nix-support/dependency-units"''
          )
          depUnits}
      '';

  /**
  Expand a caller's injections into the seam `units.nix` takes, or fail naming
  every incoherent key at once.

  `unitKeys` / `libraryKeys` are the keys the graph generates from source, which
  every injection must override: a key that is absent would silently build from
  source and defeat the injection with zero signal.
  */
  resolveInjection = {
    extraUnits,
    extraLibraries,
    unitKeys,
    libraryKeys,
  }: let
    # Every injected unit plus everything reachable from one through
    # `passthru.depUnits`, deduplicated by derivation. A recorded dep whose unit
    # key the caller explicitly pinned is pruned BEFORE descending: the pinned
    # derivation (already a closure root) is the selected unit for that key, and
    # the discarded dep's own subtree must not auto-inject units or raise
    # conflicts on behalf of an artifact the graph never links.
    # Walking by drvPath rather than unitKey keeps two distinct derivations that
    # claim the same unpinned key visible to the conflict guard below instead of
    # silently dropping one of them.
    injectedClosure = map (item: item.unit) (genericClosure {
      startSet =
        lib.mapAttrsToList (_: unit: {
          key = unit.drvPath;
          inherit unit;
        })
        extraUnits;
      operator = item:
        map
        (dep: {
          key = dep.drvPath;
          unit = dep;
        })
        (
          filter (dep: !(hasAttr (dep.passthru.unitKey or "") extraUnits)) (
            item.unit.passthru.depUnits or []
          )
        );
    });

    # The closure grouped by recorded unit key. Injected units without a
    # `passthru.unitKey` (arbitrary caller-owned derivations) record no key and
    # never participate in auto-injection.
    closureByKey = lib.groupBy (unit: unit.passthru.unitKey) (
      filter (unit: unit ? passthru.unitKey) injectedClosure
    );

    # Transitive deps of the injected prebuilts, auto-injected under their own
    # recorded unit keys so a caller injects only the root unit. An explicit
    # `extraUnits` entry wins the merge below, so a caller can deliberately pin
    # one dep key to a different artifact.
    autoInjected = lib.mapAttrs (_: head) (
      lib.filterAttrs (key: _: !(hasAttr key extraUnits)) closureByKey
    );

    unknownKeyProblems = label: injected: validKeys: let
      unknown = filter (key: !(elem key validKeys)) (attrNames injected);
    in
      lib.optional (unknown != []) ''
        ${label} key(s) not present in the generated graph: ${lib.concatStringsSep ", " unknown}
        A prebuilt injection must override a unit the workspace already references; a
        missing key would silently build from source. Available ${label} keys:
          ${lib.concatStringsSep "\n  " validKeys}'';

    # Each injected unit must carry this workspace's toolchain id.
    # `mkPrebuiltLibraryUnit` records it in passthru; non-prebuilt injections
    # without that passthru are not checked (callers own those).
    toolchainProblems = label: injected: let
      mismatched =
        lib.filterAttrs (
          _: unit: (unit.passthru.toolchainId or workspaceToolchainId) != workspaceToolchainId
        )
        injected;
      render = key: unit: "${key} (compiled with ${unit.passthru.toolchainId or "?"})";
    in
      lib.optional (mismatched != {}) ''
        ${label} compiled with a toolchain other than this workspace's (${workspaceToolchainId}):
          ${lib.concatStringsSep "\n  " (lib.mapAttrsToList render mismatched)}
        A prebuilt rlib only links against, and only hashes to the same unit key as,
        the toolchain that produced it. Import nix-cargo-unit with the toolchain the
        prebuilt was compiled by.'';

    # When an explicitly injected unit records its own unit key, the caller's
    # chosen attr key must agree with it. The artifact names inside the unit
    # embed that key's hash, and auto-injection keys the unit's deps by
    # `passthru.unitKey`, so a disagreement would inject one derivation under two
    # keys.
    keyDisagreementProblems = let
      mismatched = lib.filterAttrs (key: unit: (unit.passthru.unitKey or key) != key) extraUnits;
      render = key: unit: "${key} (the unit's own passthru.unitKey is ${unit.passthru.unitKey})";
    in
      lib.optional (mismatched != {}) ''
        extraUnits key(s) that disagree with the injected unit's recorded unitKey:
          ${lib.concatStringsSep "\n  " (lib.mapAttrsToList render mismatched)}
        A prebuilt unit must be injected under its `passthru.unitKey`; the rlib and
        extern-path inside it are named for that key's hash.'';

    # Two recorded prebuilts claiming one unit key with different derivations is
    # ambiguous, and whichever the graph linked would be a silent choice. An
    # explicit `extraUnits` entry for the key resolves it (it wins the merge), so
    # only unpinned keys are problems.
    depConflictProblems = let
      conflicts =
        lib.filterAttrs (
          key: unitDrvs: length unitDrvs > 1 && !(hasAttr key extraUnits)
        )
        closureByKey;
      render = key: unitDrvs: "${key}:\n    ${lib.concatMapStringsSep "\n    " (unit: unit.drvPath) unitDrvs}";
    in
      lib.optional (conflicts != {}) ''
        conflicting prebuilt derivations recorded for the same dependency unit key:
          ${lib.concatStringsSep "\n  " (lib.mapAttrsToList render conflicts)}
        Two injected prebuilt units recorded different derivations for one transitive
        dep (`passthru.depUnits`). Pin the key in extraUnits explicitly to choose one.'';

    problems =
      unknownKeyProblems "extraUnits" extraUnits unitKeys
      ++ unknownKeyProblems "extraUnits (auto-injected depUnits)" autoInjected unitKeys
      ++ unknownKeyProblems "extraLibraries" extraLibraries libraryKeys
      ++ toolchainProblems "extraUnits" (autoInjected // extraUnits)
      ++ toolchainProblems "extraLibraries" extraLibraries
      ++ keyDisagreementProblems
      ++ depConflictProblems;
  in
    assert lib.assertMsg (problems == []) (
      "cargoUnit.buildWorkspace: invalid prebuilt-unit injection:\n"
      + lib.concatStringsSep "\n" problems
    ); {
      inherit extraLibraries;
      extraUnits = autoInjected // extraUnits;
    };
}
