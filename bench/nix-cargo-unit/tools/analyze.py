#!/usr/bin/env python3
"""Attribute a profiled nix build, per derivation and per stdenv phase.

Nix re-announces a queued build's `actBuild` (type 105) activity under a fresh
id every time the goal is re-created, so "min start to max stop over all
activities naming this drv" measures queue latency, not build time -- which is
how a tiny crate like unicode_ident comes out at 39 s. The activity that
actually ran is the one that emitted build output: `{"action":"result",
"type":101}` (resBuildLogLine) is tagged with the running build's activity id,
and `type:104` (resSetPhase) marks each stdenv phase transition within it.

So: an activity counts as a real build iff it emitted a log line, and its phase
timeline comes from its own resSetPhase events.
"""
import collections
import json
import re
import sys

ACT_BUILD = 105
RES_BUILD_LOG_LINE = 101
RES_SET_PHASE = 104

SP = sys.argv[1]
run = sys.argv[2]
wall_ms = json.load(open(f"{SP}/{run}.summary.json"))["wall_ms"]

# id -> record for every actBuild activity
acts = {}
for line in open(f"{SP}/{run}.events.jsonl"):
    m = json.loads(line)
    action, t, ms = m.get("action"), m.get("type"), m["_ms"]
    if action == "start" and t == ACT_BUILD:
        f = m.get("fields") or []
        acts[m["id"]] = {
            "drv": f[0] if f else "?",
            "start": ms, "stop": None,
            "loglines": 0, "phases": [],
        }
    elif action == "stop":
        a = acts.get(m["id"])
        if a and a["stop"] is None:
            a["stop"] = ms
    elif action == "result":
        a = acts.get(m.get("id"))
        if not a:
            continue
        if t == RES_BUILD_LOG_LINE:
            a["loglines"] += 1
        elif t == RES_SET_PHASE:
            f = m.get("fields") or []
            if f:
                a["phases"].append((ms, f[0]))

# A real build emitted output. Keep the longest such activity per drv (there is
# normally exactly one).
real = {}
for a in acts.values():
    if a["loglines"] == 0 or a["stop"] is None:
        continue
    a["dur"] = a["stop"] - a["start"]
    prev = real.get(a["drv"])
    if prev is None or a["dur"] > prev["dur"]:
        real[a["drv"]] = a

recs = []
for drv, a in real.items():
    name = re.sub(r"^/nix/store/[a-z0-9]{32}-", "", drv).removesuffix(".drv")
    recs.append({"name": name, "drv": drv, "start": a["start"],
                 "stop": a["stop"], "dur": a["dur"], "phases": a["phases"]})
recs.sort(key=lambda r: r["start"])
json.dump(recs, open(f"{SP}/{run}.units.json", "w"), indent=1)

total = sum(r["dur"] for r in recs)


def kind(n):
    if "build-script-build" in n:
        return "build-script compile"
    if "build-script-output" in n or "build-script-run" in n:
        return "build-script run"
    if n.startswith("cargo-unit-graph"):
        return "plan (IFD)"
    if n.startswith("cargo-units.nix"):
        return "render (IFD)"
    if "rust-toolchain" in n:
        return "toolchain join"
    if n.startswith("rust-analyzer-workspace"):
        return "workspace buildEnv"
    return "compile unit"


print(f"derivations that really built : {len(recs)}")
print(f"wall clock                    : {wall_ms/1000:.1f} s")
print(f"sum of build time             : {total/1000:.1f} s")
print(f"avg parallelism               : {total/wall_ms:.2f}x")
print()
agg = collections.defaultdict(lambda: [0, 0.0])
for r in recs:
    k = kind(r["name"])
    agg[k][0] += 1
    agg[k][1] += r["dur"] / 1000
print(f"{'kind':<22}{'count':>6}{'seconds':>10}{'share':>8}")
for k, (c, s) in sorted(agg.items(), key=lambda kv: -kv[1][1]):
    print(f"{k:<22}{c:>6}{s:>10.1f}{100*s/(total/1000):>7.1f}%")

print("\n=== 15 costliest ===")
for r in sorted(recs, key=lambda r: -r["dur"])[:15]:
    print(f"  {r['dur']/1000:>7.2f}s  {r['name']}")

# ---- Per-phase attribution -------------------------------------------------
# resSetPhase marks the *start* of each phase; the phase ends when the next one
# starts, and the last one ends when the build stops. Time before the first
# phase marker is stdenv coming up (setup.sh sourcing, findInputs, env setup).
phase_tot = collections.Counter()
phase_n = collections.Counter()
pre_phase = 0.0
post_wrap = 0.0
for r in recs:
    ph = r["phases"]
    if not ph:
        continue
    pre_phase += (ph[0][0] - r["start"]) / 1000
    for i, (ms, name) in enumerate(ph):
        end = ph[i + 1][0] if i + 1 < len(ph) else r["stop"]
        phase_tot[name] += (end - ms) / 1000
        phase_n[name] += 1

print("\n=== where a derivation's own wall time goes, summed over all builds ===")
print(f"{'phase':<34}{'builds':>7}{'seconds':>10}{'share':>8}")
print(f"{'(pre-phase: stdenv startup)':<34}{len(recs):>7}{pre_phase:>10.1f}"
      f"{100*pre_phase/(total/1000):>7.1f}%")
for name, s in sorted(phase_tot.items(), key=lambda kv: -kv[1]):
    print(f"{name:<34}{phase_n[name]:>7}{s:>10.1f}{100*s/(total/1000):>7.1f}%")
accounted = pre_phase + sum(phase_tot.values())
print(f"{'(unaccounted)':<34}{'':>7}{total/1000-accounted:>10.1f}"
      f"{100*(total/1000-accounted)/(total/1000):>7.1f}%")

# ---- Concurrency over time -------------------------------------------------
edges = []
for r in recs:
    edges.append((r["start"], 1))
    edges.append((r["stop"], -1))
edges.sort()
cur = 0
last = 0
hist = collections.Counter()
for ms, d in edges:
    if ms > last:
        hist[cur] += ms - last
        last = ms
    cur += d
print("\n=== concurrent builds over wall clock ===")
print(f"{'concurrent':>10}{'seconds':>10}{'share of wall':>15}")
for k in sorted(hist):
    print(f"{k:>10}{hist[k]/1000:>10.1f}{100*hist[k]/wall_ms:>14.1f}%")
busy = sum(v for k, v in hist.items() if k > 0)
print(f"\nwall clock with >=1 build running: {busy/1000:.1f} s "
      f"({100*busy/wall_ms:.1f}%)")
idle = sum(v for k, v in hist.items() if k <= 1)
print(f"wall clock with <=1 build running: {idle/1000:.1f} s "
      f"({100*idle/wall_ms:.1f}%)  <- unparallelisable drain")
