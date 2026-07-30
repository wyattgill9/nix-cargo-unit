#!/usr/bin/env python3
"""Run a nix build and record per-derivation start/stop wall-clock.

`--log-format internal-json` carries no timestamps of its own, so each event is
stamped on arrival. That makes the numbers arrival-time approximations of the
daemon's own transitions -- fine at the ~100ms granularity we care about, and
the same method NEXT.md sec.9 used, so the figures are comparable.

Emits:
  <prefix>.events.jsonl   every stamped internal-json event
  <prefix>.builds.tsv     drv, start_ms, stop_ms, duration_ms  (one row per build)
  <prefix>.summary.json   wall clock, sum of build time, parallelism
"""
import json
import os
import subprocess
import sys
import time

ACT_BUILD = 105

prefix = sys.argv[1]
cmd = sys.argv[2:]

t0 = time.time()
proc = subprocess.Popen(
    cmd,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    text=True,
    bufsize=1,
    env=os.environ,
)

# id -> (drv, start_ms).  Nix reuses ids across a run, so a start always
# overwrites and a stop always pops.
open_builds = {}
rows = []
events = []
other = []

with open(prefix + ".events.jsonl", "w") as ev:
    for line in proc.stdout:
        now_ms = int((time.time() - t0) * 1000)
        if not line.startswith("@nix "):
            other.append(line.rstrip("\n"))
            continue
        try:
            msg = json.loads(line[5:])
        except json.JSONDecodeError:
            continue
        msg["_ms"] = now_ms
        ev.write(json.dumps(msg) + "\n")
        action = msg.get("action")
        if action == "start" and msg.get("type") == ACT_BUILD:
            fields = msg.get("fields") or []
            drv = fields[0] if fields else "?"
            open_builds[msg["id"]] = (drv, now_ms)
        elif action == "stop":
            got = open_builds.pop(msg.get("id"), None)
            if got:
                drv, start = got
                rows.append((drv, start, now_ms, now_ms - start))

rc = proc.wait()
wall_ms = int((time.time() - t0) * 1000)

# Anything still open when the build ended (shouldn't happen on success).
for bid, (drv, start) in open_builds.items():
    rows.append((drv, start, wall_ms, wall_ms - start))

rows.sort(key=lambda r: r[1])
with open(prefix + ".builds.tsv", "w") as f:
    f.write("drv\tstart_ms\tstop_ms\tduration_ms\n")
    for drv, s, e, d in rows:
        f.write(f"{drv}\t{s}\t{e}\t{d}\n")

sum_ms = sum(r[3] for r in rows)
summary = {
    "returncode": rc,
    "wall_ms": wall_ms,
    "builds": len(rows),
    "sum_build_ms": sum_ms,
    "avg_parallelism": round(sum_ms / wall_ms, 2) if wall_ms else 0,
    "cmd": cmd,
}
with open(prefix + ".summary.json", "w") as f:
    json.dump(summary, f, indent=2)

if rc != 0:
    with open(prefix + ".stderr.txt", "w") as f:
        f.write("\n".join(other))

print(json.dumps(summary, indent=2))
sys.exit(rc)
