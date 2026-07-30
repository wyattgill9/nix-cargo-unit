#!/usr/bin/env python3
"""Weighted critical path through the unit DAG, using measured build times.

Edges come from each derivation's own `inputDrvs`, restricted to derivations
that actually built in the profiled run -- so this is the real scheduling
constraint, not a re-derivation of the graph from unit-graph.json.

Reports, for the path: total length, and how much of it is rustc (buildPhase)
versus Nix/stdenv scaffolding (everything else). That ratio is what decides
whether cheaper derivations or fewer/earlier-unblocking derivations is the
lever, because only path time is wall clock.
"""
import json
import subprocess
import sys

SP = sys.argv[1]
run = sys.argv[2]

recs = json.load(open(f"{SP}/{run}.units.json"))
by_drv = {r["drv"]: r for r in recs}

# One batched `nix derivation show` over every built drv; --recursive would drag
# in the whole nixpkgs closure, so ask for exactly these.
out = subprocess.run(
    ["nix", "derivation", "show", *by_drv.keys()],
    capture_output=True, text=True,
).stdout
drvs = json.loads(out)["derivations"] if out else {}

# nix keys the result by basename in this version; map back to full paths.
base = {d.rsplit("/", 1)[-1]: d for d in by_drv}
deps = {d: set() for d in by_drv}
for key, obj in drvs.items():
    full = base.get(key.rsplit("/", 1)[-1])
    if full is None:
        continue
    # `nix derivation show` v4 nests edges under inputs.drvs; older versions
    # spell it inputDrvs at the top level.
    edges = (obj.get("inputs") or {}).get("drvs") or obj.get("inputDrvs") or {}
    for indrv in edges:
        cand = base.get(indrv.rsplit("/", 1)[-1])
        if cand and cand != full:
            deps[full].add(cand)


def phase_split(r):
    """(rustc_ms, scaffolding_ms) for one derivation."""
    ph = r["phases"]
    if not ph:
        return 0, r["dur"]
    build = 0
    for i, (ms, name) in enumerate(ph):
        end = ph[i + 1][0] if i + 1 < len(ph) else r["stop"]
        if name == "buildPhase":
            build += end - ms
    return build, r["dur"] - build


# Longest path by measured duration.
memo = {}


def longest(d):
    if d in memo:
        return memo[d]
    memo[d] = (0, [])  # cycle guard
    best_len, best_path = 0, []
    for p in deps[d]:
        ln, path = longest(p)
        if ln > best_len:
            best_len, best_path = ln, path
    res = (best_len + by_drv[d]["dur"], best_path + [d])
    memo[d] = res
    return res


sys.setrecursionlimit(10000)
end = max(by_drv, key=lambda d: longest(d)[0])
length, path = longest(end)

wall = json.load(open(f"{SP}/{run}.summary.json"))["wall_ms"]
total = sum(r["dur"] for r in recs)

print(f"critical path      : {length/1000:.1f} s over {len(path)} derivations")
print(f"wall clock         : {wall/1000:.1f} s   "
      f"(path = {100*length/wall:.0f}% of wall)")
print(f"sum of build time  : {total/1000:.1f} s")
print()

pb = sum(phase_split(by_drv[d])[0] for d in path)
ps = sum(phase_split(by_drv[d])[1] for d in path)
print(f"  on-path rustc (buildPhase)      : {pb/1000:>7.1f} s "
      f"({100*pb/length:.0f}% of path)")
print(f"  on-path Nix/stdenv scaffolding  : {ps/1000:>7.1f} s "
      f"({100*ps/length:.0f}% of path)")
print(f"  scaffolding per path derivation : {ps/len(path):.0f} ms")
print()

tb = sum(phase_split(r)[0] for r in recs)
ts = sum(phase_split(r)[1] for r in recs)
print(f"  total rustc (buildPhase)        : {tb/1000:>7.1f} s "
      f"({100*tb/total:.0f}% of sum)")
print(f"  total scaffolding               : {ts/1000:>7.1f} s "
      f"({100*ts/total:.0f}% of sum)")
print()
print("=== the path ===")
print(f"{'':4}{'total':>8}{'rustc':>8}{'scaffold':>10}  name")
for d in path:
    r = by_drv[d]
    b, s = phase_split(r)
    print(f"{'':4}{r['dur']/1000:>7.2f}s{b/1000:>7.2f}s{s/1000:>9.2f}s  {r['name']}")
