# The two import-from-derivation stages that turn a source tree into `units.nix`:
# cargo plans the workspace into a unit graph, then the renderer turns that graph
# into one Nix derivation per rustc unit. Kept as separate derivations so either
# can be built and inspected on its own when a planning or render problem needs
# looking at.
{
  lib,
  pkgs,
  nixCargoUnit,
  rustToolchain,
  toolchainId,
}: let
  inherit (builtins) length toString;
  inherit (lib) escapeShellArg escapeShellArgs;
in {
  /**
  The tree cargo plans in: manifests verbatim, every other file an empty stub at
  its exact relative path.

  Cargo's planning phase (`cargo build --unit-graph`) resolves the workspace from
  manifest CONTENTS (Cargo.toml, Cargo.lock, the in-tree cargo config) plus
  target discovery by file EXISTENCE (src/lib.rs, src/main.rs, src/bin/*.rs,
  tests/, benches/, build.rs); it never reads a target file's contents and runs
  no build script or proc macro. So this derivation's inputs are the manifest
  slice and the relative path list alone: a source BODY edit changes neither, and
  the whole-workspace cargo resolve never re-runs. Adding or removing files, or
  touching a manifest, re-plans — correctly.

  Relative paths must match `src` exactly, because `unitsNix` below maps the
  planned unit paths back onto the real tree.

  Symlinks are stubbed as empty regular files like everything else; a source with
  a symlinked manifest or member directory would mis-plan, and cargo fails loud
  on the unreadable manifest if one appears.
  */
  plannerSource = src: let
    srcRoot = toString src;

    # Every file in `src`, as workspace-relative paths (readDir's attr order, so
    # deterministic). Eval-time: a derivation-produced `src` is realized here,
    # which the units import forces anyway.
    filesUnder = dir:
      lib.concatLists (
        lib.mapAttrsToList (
          name: type:
            if type == "directory"
            then map (child: "${name}/${child}") (filesUnder "${dir}/${name}")
            else [name]
        ) (builtins.readDir dir)
      );

    # The files cargo's planner reads by content: package manifests, the
    # lockfile, and the workspace-level cargo config (cargo reads the config
    # chain from cwd upward plus $CARGO_HOME, and the vendor config script owns
    # the latter).
    plannerReadsContent = relPath:
      builtins.elem (baseNameOf relPath) [
        "Cargo.toml"
        "Cargo.lock"
      ]
      || relPath == ".cargo/config.toml"
      || relPath == ".cargo/config";

    # The manifest slice re-ingested from `src`: manifest files plus the full
    # directory skeleton (kept directories cost nothing and keep the filter one
    # predicate). Changes only when a manifest changes or the tree's shape does.
    manifestTree = builtins.path {
      name = "cargo-unit-planner-manifests";
      path = src;
      filter = path: type:
        type == "directory" || plannerReadsContent (lib.removePrefix (srcRoot + "/") path);
    };
  in
    pkgs.runCommand "cargo-unit-planner-src"
    {
      manifests = manifestTree;
      fileList = pkgs.writeText "cargo-unit-planner-file-list" (
        lib.concatLines (filesUnder srcRoot)
      );
    }
    ''
      cp -r "$manifests" "$out"
      chmod -R u+w "$out"
      while IFS= read -r relPath; do
        if [ ! -e "$out/$relPath" ]; then
          mkdir -p "$out/$(dirname "$relPath")"
          : > "$out/$relPath"
        fi
      done < "$fileList"
    '';

  /**
  Cargo's `--unit-graph` JSON for the vendored workspace: one cargo invocation
  per `cargoTargets` entry, run concurrently and merged into one graph.

  Runs in `plannerSource`, never `src`, so the paths in the emitted graph carry
  the stub's store prefix; `unitsNix` rewrites them.
  */
  unitGraphJson = {
    plannerSource,
    configScript,
    cargoTargets,
    profile,
    target,
    env,
    nativeBuildInputs,
  }: let
    profileArgs =
      {
        release = ["--release"];
        dev = [];
      }
          ."${profile}" or [
        "--profile"
        profile
      ];

    cargoArgs = cargoTarget:
      escapeShellArgs (
        [
          "build"
          "--unit-graph"
          "-Z"
          "unstable-options"
        ]
        ++ profileArgs
        ++ lib.optionals (target != null) [
          "--target"
          target
        ]
        ++ cargoTarget
        ++ [
          "--frozen"
          "--offline"
        ]
      );

    unitGraphFile = targetIndex: "$TMPDIR/unit-graph-${toString targetIndex}.json";
  in
    pkgs.runCommand "cargo-unit-graph.json"
    (
      {
        nativeBuildInputs =
          [
            rustToolchain
            pkgs.cacert
            nixCargoUnit
          ]
          ++ nativeBuildInputs;
        SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        # Cargo still gates `--unit-graph` behind `-Z unstable-options`.
        # This keeps the input graph generation local to the IFD planner
        # derivation instead of requiring a flake-wide Rust overlay.
        RUSTC_BOOTSTRAP = "1";
      }
      // env
    )
    ''
      ${configScript}

      cd ${plannerSource}

      pids=
      ${lib.concatStringsSep "\n" (
        lib.imap0 (targetIndex: targetArgs: ''
          (
            export CARGO_TARGET_DIR="$TMPDIR/cargo-target-${toString targetIndex}"
            cargo ${cargoArgs targetArgs} > "${unitGraphFile targetIndex}"
          ) &
          pids="$pids $!"
        '')
        cargoTargets
      )}

      for pid in $pids; do
        wait "$pid"
      done

      nix-cargo-unit merge ${lib.concatStringsSep " " (lib.genList unitGraphFile (length cargoTargets))} > "$out"
    '';

  /**
  The rendered `units.nix` for a unit graph.

  `src` is interpolated rather than `toString`-ed, and that is load-bearing: the
  two disagree whenever `src` is a bare path rather than a derivation. A flake's
  `src = ./.` interpolates to a fresh store copy of the tree but stringifies to
  the flake source itself, and a plain directory stringifies to a location
  outside the store entirely. Interpolation is the correct one: the renderer both
  strips this prefix off the rewritten graph paths and reads the tree behind it
  to include-scan file contents, and only the interpolated form is a declared,
  readable input of this derivation.
  */
  unitsNix = {
    src,
    plannerSource,
    unitGraphJson,
    vendorDir,
    cargoLock,
    renderFlags,
  }: let
    srcRoot = "${src}";
  in
    pkgs.runCommand "cargo-units.nix"
    {
      nativeBuildInputs = [nixCargoUnit];
      cargoLockForRender = cargoLock;
    }
    ''
      # The graph was planned in the content-stubbed `plannerSource`;
      # rewrite that store prefix to the real `src` so the renderer slices
      # unit paths from, and include-scans the contents of, the tree the
      # units actually compile from. Planning is content-independent, so
      # the rewritten graph is byte-identical to one planned in `src`
      # directly. `|` and `&` never appear in a store path.
      sed -e 's|${plannerSource}|${srcRoot}|g' ${unitGraphJson} > "$TMPDIR/unit-graph.json"

      nix-cargo-unit render \
        --workspace-root ${escapeShellArg srcRoot} \
        --vendor-root ${escapeShellArg vendorDir} \
        --toolchain-id ${escapeShellArg toolchainId} \
        ${escapeShellArgs renderFlags} \
        --cargo-lock "$cargoLockForRender" \
        < "$TMPDIR/unit-graph.json" \
        > "$out"
    '';
}
