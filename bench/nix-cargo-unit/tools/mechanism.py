#!/usr/bin/env python3
"""Does per-derivation scaffolding scale with the input closure?

If it does, a trivial-derivation probe (tiny closure) systematically
underestimates it, which is the difference between BENCH_BASE.md sec.8 and what
the phase timings in the real build show. Two candidate mechanisms:

  pre-phase  stdenv sourcing setup.sh and running findInputs over buildInputs,
             which walks each input's propagated-build-inputs transitively
  fixupPhase patchShebangs and friends walking the produced output tree

So: correlate pre-phase against direct buildInputs count, and fixupPhase
against output NAR size.
"""
import json
import re
import statistics
import subprocess
import sys

SP = sys.argv[1]
run = sys.argv[2]
recs = json.load(open(f"{SP}/{run}.units.json"))

out = subprocess.run(
    ["nix", "derivation", "show", *[r["drv"] for r in recs]],
    capture_output=True, text=True,
).stdout
drvs = json.loads(out)["derivations"]
by_base = {k.rsplit("/", 1)[-1]: v for k, v in drvs.items()}


def phases(r):
    """{phase: ms} plus 'pre' for time before the first phase marker."""
    ph = r["phases"]
    d = {}
    if not ph:
        return d
    d["pre"] = ph[0][0] - r["start"]
    for i, (ms, name) in enumerate(ph):
        end = ph[i + 1][0] if i + 1 < len(ph) else r["stop"]
        d[name] = d.get(name, 0) + (end - ms)
    return d


rows = []
for r in recs:
    o = by_base.get(r["drv"].rsplit("/", 1)[-1])
    if not o:
        continue
    env = o["env"]
    n_build_inputs = len((env.get("buildInputs") or "").split())
    n_input_drvs = len(((o.get("inputs") or {}).get("drvs") or {}))
    p = phases(r)
    if "pre" not in p:
        continue
    rows.append({
        "name": r["name"],
        "n_build_inputs": n_build_inputs,
        "n_input_drvs": n_input_drvs,
        "pre": p["pre"],
        "fixup": p.get("fixupPhase", 0),
        "build": p.get("buildPhase", 0),
        "install": p.get("installPhase", 0),
        "dur": r["dur"],
    })


def corr(xs, ys):
    n = len(xs)
    mx, my = statistics.mean(xs), statistics.mean(ys)
    num = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    dx = sum((x - mx) ** 2 for x in xs) ** 0.5
    dy = sum((y - my) ** 2 for y in ys) ** 0.5
    return num / (dx * dy) if dx and dy else 0.0


print(f"derivations analysed: {len(rows)}\n")
bi = [r["n_build_inputs"] for r in rows]
pre = [r["pre"] for r in rows]
print(f"corr(direct buildInputs, pre-phase ms)  = {corr(bi, pre):+.3f}")
print(f"corr(total inputDrvs,   pre-phase ms)  = "
      f"{corr([r['n_input_drvs'] for r in rows], pre):+.3f}")
print(f"corr(buildPhase ms,     fixupPhase ms) = "
      f"{corr([r['build'] for r in rows], [r['fixup'] for r in rows]):+.3f}")
print()

# Bucket by input count to show the slope in wall-clock terms.
buckets = [(0, 5), (5, 20), (20, 50), (50, 120), (120, 1000)]
print(f"{'direct buildInputs':<20}{'n':>5}{'pre-phase ms':>14}"
      f"{'fixup ms':>10}{'buildPhase ms':>15}")
for lo, hi in buckets:
    sel = [r for r in rows if lo <= r["n_build_inputs"] < hi]
    if not sel:
        continue
    print(f"{f'{lo}-{hi-1}':<20}{len(sel):>5}"
          f"{statistics.median(r['pre'] for r in sel):>14.0f}"
          f"{statistics.median(r['fixup'] for r in sel):>10.0f}"
          f"{statistics.median(r['build'] for r in sel):>15.0f}")

print()
tot = sum(r["dur"] for r in rows)
for k in ("pre", "fixup", "install", "build"):
    s = sum(r[k] for r in rows)
    print(f"  {k:<10}{s/1000:>8.1f} s  ({100*s/tot:>4.1f}% of summed build time)"
          f"   median {statistics.median(r[k] for r in rows):.0f} ms")

json.dump(rows, open(f"{SP}/{run}.mechanism.json", "w"), indent=1)
