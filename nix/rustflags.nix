# Every source of rustc arguments a compile unit gets beyond the ones cargo's
# unit graph already carries, composed into the two per-platform hooks
# `units.nix` calls.
#
# Assembling them here is the only route: `cargo build --unit-graph` does NOT
# carry rustflags. Each unit records dependencies, features, mode, pkg_id,
# platform, profile and target only, because cargo resolves config rustflags at
# compile time and applies them when it invokes rustc — which cargo-unit
# bypasses by invoking rustc per unit from the graph. So there is nothing in the
# graph to pick up automatically.
{
  lib,
  policyLib,
  hostTriple,
}: let
  # The rustc args a normal `cargo build` would read from a `.cargo/config.toml`,
  # following cargo precedence: `target.<triple>.rustflags` wins outright over
  # `build.rustflags` (cargo does not merge the two). Flags may be a TOML array
  # or a single whitespace-separated string. `cfg(...)` target sections and the
  # `[env]` table are NOT honored (cargo evaluates those against the full target
  # cfg set, which this static parse does not reproduce). A `configPath` that
  # does not exist yields no flags, so callers may pass the path unconditionally.
  fromCargoConfig = configPath: platform: let
    config = lib.importTOML configPath;
    normalize = flags:
      if builtins.isList flags
      then flags
      else builtins.filter (flag: flag != "") (lib.splitString " " flags);
    chosen = config.target.${platform}.rustflags or config.build.rustflags or null;
  in
    # Lazy: the `&&` short-circuits, so `config` (hence `importTOML`) is only
    # forced when the file exists and carries rustflags.
    if builtins.pathExists configPath && chosen != null
    then normalize chosen
    else [];
in {
  # The two hooks for one workspace.
  #
  # `compile` lands on every unit's rustc invocation; `link` only on the ones
  # that link. Both are called with the unit's platform, which the renderer
  # leaves `null` for a unit built without `--target` — build scripts, proc
  # macros, and every unit of a native build. That sentinel is resolved to the
  # host triple once, here, so the linker policy, the cargo-config lookup and
  # the caller's own hooks are all handed a real triple and none of them has to
  # special-case it.
  forWorkspace = {
    policy,
    workspaceRoot,
    cargoConfigRustflags,
    # The caller's own per-platform hooks, appended last so explicit caller args
    # win over both the policy's and the cargo config's.
    compileArgsForPlatform,
    linkArgsForPlatform,
  }: let
    resolvePlatform = platform:
      if platform == null
      then hostTriple
      else platform;

    cargoConfigArgs = platform:
      lib.optionals cargoConfigRustflags (
        fromCargoConfig (workspaceRoot + "/.cargo/config.toml") platform
      );
  in {
    compile = platform: let
      triple = resolvePlatform platform;
    in
      compileArgsForPlatform triple ++ cargoConfigArgs triple;

    link = platform: let
      triple = resolvePlatform platform;
    in
      policyLib.linkerRustcArgsForPlatform policy triple ++ linkArgsForPlatform triple;
  };
}
