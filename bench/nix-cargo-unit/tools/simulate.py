#!/usr/bin/env python3
"""Predict the metadata/codegen split's effect before building it.

Method: a greedy list scheduler over the measured DAG with measured
durations. It is first **validated** against the run it was derived from -- if
it cannot reproduce today's 203.6 s makespan from today's graph, its prediction
for a different graph means nothing, and the size of the miss is itself the
interesting number (it is the part of wall clock that is neither dependency
order nor job count).

Then the same scheduler runs over the pipelined graph:

  meta_i  frontend only. Depends on meta_j for every dependency j.
  code_i  full compile. Depends on meta_j for every dependency j -- NOT on
          code_j, because rustc only needs a dependency's .rmeta to
          monomorphise and codegen against it. The .rlib is needed at final
          link time only. That is the whole reason pipelining works.
  link    the workspace root; needs every code_i.

code_i redoes the frontend, so total CPU work rises -- that cost is modelled,
not waved away.
"""
import json
import subprocess
import sys
import heapq

SP = sys.argv[1]
run = sys.argv[2]
JOBS = int(sys.argv[3]) if len(sys.argv) > 3 else 10

recs = json.load(open(f"{SP}/{run}.units.json"))
by = {r["drv"]: r for r in recs}
measured_wall = json.load(open(f"{SP}/{run}.summary.json"))["wall_ms"]

out = subprocess.run(["nix", "derivation", "show", *by.keys()],
                     capture_output=True, text=True).stdout
drvs = json.loads(out)["derivations"]
base = {d.rsplit("/", 1)[-1]: d for d in by}
deps = {d: set() for d in by}
for key, obj in drvs.items():
    full = base.get(key.rsplit("/", 1)[-1])
    if full is None:
        continue
    for indrv in ((obj.get("inputs") or {}).get("drvs") or {}):
        cand = base.get(indrv.rsplit("/", 1)[-1])
        if cand and cand != full:
            deps[full].add(cand)


def phase_ms(r, want):
    ph = r["phases"]
    tot = 0
    for i, (ms, name) in enumerate(ph):
        end = ph[i + 1][0] if i + 1 < len(ph) else r["stop"]
        if name == want:
            tot += end - ms
    return tot


# Per-crate measured metadata share, else a deliberately conservative default
# (a higher share means less benefit, so this cannot flatter the result).
DEFAULT_SHARE = 0.25
share = {}
try:
    for p in json.load(open(f"{SP}/passes.json")):
        if p["full"] and p["meta"]:
            share[p["unit"]] = p["meta"] / p["full"]
except FileNotFoundError:
    pass


def crate_share(name):
    stem = name.rsplit("-", 1)[0] if "-" in name else name
    for k, v in share.items():
        if name.startswith(k + "-") or stem == k:
            return v
    return DEFAULT_SHARE


def schedule(nodes, edges, dur, jobs):
    """Greedy list scheduler. Returns makespan in ms."""
    indeg = {n: len(edges[n]) for n in nodes}
    rdeps = {n: [] for n in nodes}
    for n in nodes:
        for p in edges[n]:
            rdeps[p].append(n)
    ready = [n for n in nodes if indeg[n] == 0]
    t = 0
    running = []  # (finish_time, node)
    free = jobs
    while ready or running:
        while ready and free:
            # Longest-processing-time-first: a reasonable stand-in for Nix's
            # order, and the standard list-scheduling heuristic.
            ready.sort(key=lambda n: -dur[n])
            n = ready.pop(0)
            heapq.heappush(running, (t + dur[n], n))
            free -= 1
        if not running:
            break
        t, n = heapq.heappop(running)
        free += 1
        for m in rdeps[n]:
            indeg[m] -= 1
            if indeg[m] == 0:
                ready.append(m)
    return t


# ---- arm 1: today's graph, measured durations --------------------------------
nodes = list(by)
dur_now = {d: by[d]["dur"] for d in nodes}
sim_now = schedule(nodes, deps, dur_now, JOBS)

# ---- arm 2: pipelined graph --------------------------------------------------
# Only compile units split. Build-script compiles/runs and the buildEnv do not.
def splits(name):
    return not ("build-script" in name or name.startswith("rust-analyzer-workspace"))


pn, pe, pd = [], {}, {}
root = max(by, key=lambda d: by[d]["stop"])
for d in nodes:
    r = by[d]
    scaffold = r["dur"] - phase_ms(r, "buildPhase")
    rustc = phase_ms(r, "buildPhase")
    if splits(r["name"]) and d != root:
        m, c = d + "#meta", d + "#code"
        pn += [m, c]
        pd[m] = int(scaffold + rustc * crate_share(r["name"]))
        pd[c] = int(scaffold + rustc)
        pe[m] = set()
        pe[c] = set()
    else:
        pn.append(d)
        pd[d] = r["dur"]
        pe[d] = set()

for d in nodes:
    for p in deps[d]:
        pdep = p + "#meta" if (p + "#meta") in pd else p
        for tgt in ((d + "#meta", d + "#code") if (d + "#meta") in pd else (d,)):
            pe[tgt].add(pdep)
# The final root links, so it needs every codegen output, not just metadata.
for d in nodes:
    if (d + "#code") in pd:
        pe[root].add(d + "#code")

sim_pipe = schedule(pn, pe, pd, JOBS)

work_now = sum(dur_now.values())
work_pipe = sum(pd.values())

print(f"max-jobs = {JOBS}\n")
print("validation -- can the scheduler reproduce the run it came from?")
print(f"  measured wall clock      {measured_wall/1000:>8.1f} s")
print(f"  simulated, today's graph {sim_now/1000:>8.1f} s"
      f"   ({100*sim_now/measured_wall:.0f}% of measured)")
print(f"  unmodelled overhead      {(measured_wall-sim_now)/1000:>8.1f} s"
      f"   <- neither dependency order nor job count")
print()
print("prediction -- metadata/codegen split")
print(f"  derivations   {len(nodes):>6}  ->{len(pn):>6}"
      f"   (+{len(pn)-len(nodes)})")
print(f"  total work    {work_now/1000:>6.1f}s ->{work_pipe/1000:>6.1f}s"
      f"   (+{100*(work_pipe-work_now)/work_now:.0f}% CPU, frontend runs twice)")
print(f"  work/{JOBS} cores{work_now/JOBS/1000:>6.1f}s ->"
      f"{work_pipe/JOBS/1000:>6.1f}s   (lower bound from cores)")
print(f"  simulated wall{sim_now/1000:>6.1f}s ->{sim_pipe/1000:>6.1f}s"
      f"   ({sim_now/sim_pipe:.2f}x)")
print()
print(f"  applying the same unmodelled overhead: "
      f"{(sim_pipe + (measured_wall-sim_now))/1000:.0f} s "
      f"vs {measured_wall/1000:.0f} s measured today")
