# The workspace-level policy gates: an offline lockfile audit and an
# unused-dependency sweep, each a derivation independent of compilation so it
# re-runs only when its own inputs move.
#
# Clippy and unused-crate-dependency denial are deliberately absent: the
# renderer emits those per compile unit, so a whole-workspace `cargo clippy`
# would duplicate them and make one source edit invalidate every crate's check.
{
  lib,
  pkgs,
  policyLib,
  rustToolchain,
  vendor,
}: let
  cargoAudit = {
    pname,
    cargoLock,
    policy,
  }:
    pkgs.runCommand "${pname}-cargo-audit"
    {
      nativeBuildInputs = [pkgs.cargo-audit];
      # Stage the lockfile through a derivation input so its store path
      # is realized in every builder's sandbox, not just the one that
      # evaluated the expression.
      lockFile = cargoLock;
    }
    ''
      export CARGO_HOME="$TMPDIR/cargo-home"
      mkdir -p "$CARGO_HOME"
      cp "$lockFile" "$TMPDIR/Cargo.lock"
      cd "$TMPDIR"

      cargo-audit audit \
        --file Cargo.lock \
        --db ${lib.escapeShellArg policy.cargoAudit.db} \
        --no-fetch \
        --stale \
        ${lib.escapeShellArgs (policyLib.cargoAuditArgs policy)}

      mkdir -p "$out"
    '';

  cargoMachete = {
    pname,
    src,
    configScript,
    policy,
    env,
    nativeBuildInputs,
  }:
    pkgs.runCommand "${pname}-cargo-machete"
    (
      {
        nativeBuildInputs =
          [
            rustToolchain
            pkgs.cacert
            pkgs.cargo-machete
          ]
          ++ nativeBuildInputs;
        SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        CARGO_NET_OFFLINE = "true";
      }
      // env
    )
    ''
      ${configScript}

      cd ${src}

      cargo-machete \
        --with-metadata --skip-target-dir \
        ${lib.escapeShellArgs policy.cargoMachete.extraArgs} \
        .

      mkdir -p "$out"
    '';
in {
  # The gate set for one workspace. Each entry is lazy and present only when its
  # policy flag is on, so a caller that disables a gate never forces its
  # derivation.
  workspaceChecks = {
    pname,
    src,
    cargoLock,
    vendorDir,
    cargoExtraConfig,
    policy,
    env,
    nativeBuildInputs,
  }: let
    configScript = vendor.configScript {inherit cargoExtraConfig cargoLock vendorDir;};
  in
    lib.optionalAttrs policy.cargoAudit.enable {
      cargoAudit = cargoAudit {inherit pname cargoLock policy;};
    }
    // lib.optionalAttrs policy.cargoMachete.enable {
      cargoMachete = cargoMachete {
        inherit
          pname
          src
          configScript
          policy
          env
          nativeBuildInputs
          ;
      };
    };
}
