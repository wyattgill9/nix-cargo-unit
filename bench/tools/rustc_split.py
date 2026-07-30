#!/usr/bin/env python3
"""Split one unit's rustc invocation into frontend vs full-codegen cost.

Each unit derivation's buildPhase is a generated bash script that assembles a
`rustc_args` array and ends in `env "${rustc_env[@]}" rustc "${rustc_args[@]}"`.
Everything it needs from the build environment is `$src` (verified: no $out, no
$NIX_BUILD_TOP), so the exact same invocation runs outside Nix with the store
deps that are already there.

Three variants per unit:
  full      --emit dep-info,metadata,link   (what the unit really does)
  metadata  --emit metadata                 (what a pipelined dependent waits on)
  selfprof  full + -Zself-profile           (frontend/backend/LLVM breakdown)

Usage: rustc_split.py <workdir> <toolchain-bin> <unit-name> <drv-path> [reps]
"""
import json
import os
import shutil
import subprocess
import sys
import time

workdir, toolbin, unit, drv = sys.argv[1:5]
reps = int(sys.argv[5]) if len(sys.argv) > 5 else 1

raw = subprocess.run(
    ["nix", "derivation", "show", drv],
    capture_output=True, text=True,
).stdout
d = list(json.loads(raw)["derivations"].values())[0]
env = d["env"]
build_phase = env["buildPhase"]
src = env["src"]

EMIT_FULL = "rustc_args+=( --emit dep-info,metadata,link )"
assert EMIT_FULL in build_phase, f"{unit}: unexpected --emit line"

variants = {
    "full": build_phase,
    "metadata": build_phase.replace(
        EMIT_FULL, "rustc_args+=( --emit metadata )"
    ),
    # `-Zself-profile` needs the measureme tooling to read; `-Ztime-passes`
    # prints the same breakdown straight to stderr, which is parseable here.
    "timepasses": build_phase.replace(
        "set -x\nenv ",
        "rustc_args+=( -Ztime-passes )\nset -x\nenv ",
    ),
}

base = os.path.join(workdir, unit)
results = {}
for name, script in variants.items():
    times = []
    ok = True
    for rep in range(reps):
        run_dir = f"{base}.{name}.{rep}"
        shutil.rmtree(run_dir, ignore_errors=True)
        os.makedirs(run_dir)
        sh = os.path.join(run_dir, "run.sh")
        with open(sh, "w") as f:
            # No `set -u`: the generated script expands `"${build_script_flags[@]}"`
            # unconditionally, which is unbound-variable under -u on this bash.
            # stdenv does not set -u either, so this matches the real build.
            f.write("set -eo pipefail\n")
            f.write(f"export src={src!r}\n".replace("'", '"'))
            f.write(f'export PATH="{toolbin}:$PATH"\n')
            # Units whose package has a build script stage its output under
            # $NIX_BUILD_TOP; unset, that resolves to / and mkdir fails.
            f.write(f'export NIX_BUILD_TOP="{run_dir}"\n')
            if name == "timepasses":
                f.write("export RUSTC_BOOTSTRAP=1\n")
            f.write(script)
        t = time.time()
        p = subprocess.run(
            ["bash", sh], cwd=run_dir, capture_output=True, text=True
        )
        el = time.time() - t
        if p.returncode != 0:
            ok = False
            with open(os.path.join(run_dir, "FAIL.log"), "w") as f:
                f.write(p.stdout + "\n---\n" + p.stderr)
            break
        if name == "timepasses":
            with open(f"{base}.timepasses.log", "w") as f:
                f.write(p.stdout + p.stderr)
        times.append(round(el, 3))
        # Keep only the last rep's artifacts; drop earlier ones to save disk.
        if rep < reps - 1:
            shutil.rmtree(run_dir, ignore_errors=True)
    results[name] = {"ok": ok, "times": times,
                     "best": min(times) if times else None}

print(json.dumps({"unit": unit, "results": results}))
