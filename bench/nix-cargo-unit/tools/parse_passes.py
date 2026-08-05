#!/usr/bin/env python3
"""Summarise -Ztime-passes logs plus the metadata/full timings.

`-Ztime-passes` entries nest, so summing every line double-counts. Only
non-overlapping top-level buckets are used:

  total                     rustc's own end-to-end figure
  finish_ongoing_codegen    wall time the main thread waits for the LLVM
                            worker pool -- the backend, as wall clock
  codegen_crate             MIR -> LLVM IR on the main thread
  link                      link_rlib / link_binary
  frontend (derived)        total - the three above

LLVM_passes and LLVM_thinlto are reported as a breakdown *inside* the backend;
they are summed across worker threads, so they can exceed the backend wall time
and must not be added to it.
"""
import json
import os
import re
import sys

SP = sys.argv[1]
LOG = f"{SP}/split"

PAT = re.compile(r"^time:\s+([0-9.]+);.*\t(\S+)\s*$")

split = {}
for line in open(f"{SP}/split_results.jsonl"):
    r = json.loads(line)
    split[r["unit"]] = r["results"]

rows = []
for unit in split:
    path = f"{LOG}/{unit}.timepasses.log"
    passes = {}
    if os.path.exists(path):
        for ln in open(path):
            m = PAT.match(ln)
            if m:
                # Later duplicates of a name are separate invocations; sum them.
                passes[m.group(2)] = passes.get(m.group(2), 0.0) + float(m.group(1))
    total = passes.get("total", 0.0)
    backend = passes.get("finish_ongoing_codegen", 0.0)
    ir = passes.get("codegen_crate", 0.0)
    link = passes.get("link", 0.0)
    frontend = total - backend - ir - link
    rows.append({
        "unit": unit,
        "full": split[unit]["full"]["best"],
        "meta": split[unit]["metadata"]["best"],
        "total": total,
        "frontend": frontend,
        "metadata_pass": passes.get("generate_crate_metadata", 0.0),
        "ir": ir,
        "backend": backend,
        "llvm_passes": passes.get("LLVM_passes", 0.0),
        "llvm_thinlto": passes.get("LLVM_thinlto", 0.0),
        "link": link,
        "typeck": passes.get("type_check_crate", 0.0),
        "borrowck": passes.get("MIR_borrow_checking", 0.0),
    })

rows.sort(key=lambda r: -(r["full"] or 0))

print("=== metadata-only vs full compile (standalone, idle machine) ===")
print(f"{'unit':<22}{'full s':>9}{'meta s':>9}{'meta %':>9}"
      f"{'unblock earlier':>17}")
for r in rows:
    if not r["full"]:
        continue
    pct = 100 * r["meta"] / r["full"]
    print(f"{r['unit']:<22}{r['full']:>9.2f}{r['meta']:>9.2f}"
          f"{pct:>8.0f}%{100-pct:>16.0f}%")
tf = sum(r["full"] for r in rows if r["full"])
tm = sum(r["meta"] for r in rows if r["meta"])
print(f"{'TOTAL':<22}{tf:>9.2f}{tm:>9.2f}{100*tm/tf:>8.0f}%{100-100*tm/tf:>16.0f}%")

print("\n=== where rustc's own time goes (-Ztime-passes, wall) ===")
print(f"{'unit':<20}{'total':>8}{'frontend':>10}{'IR gen':>8}"
      f"{'backend':>9}{'link':>7}{'backend %':>11}")
for r in rows:
    if not r["total"]:
        continue
    print(f"{r['unit']:<20}{r['total']:>8.2f}{r['frontend']:>10.2f}"
          f"{r['ir']:>8.2f}{r['backend']:>9.2f}{r['link']:>7.2f}"
          f"{100*r['backend']/r['total']:>10.0f}%")
agg = {k: sum(r[k] for r in rows) for k in
       ("total", "frontend", "ir", "backend", "link",
        "llvm_passes", "llvm_thinlto", "metadata_pass", "typeck", "borrowck")}
print(f"{'SUM':<20}{agg['total']:>8.2f}{agg['frontend']:>10.2f}"
      f"{agg['ir']:>8.2f}{agg['backend']:>9.2f}{agg['link']:>7.2f}"
      f"{100*agg['backend']/agg['total']:>10.0f}%")

print("\n=== inside the numbers (summed over these units) ===")
print(f"  frontend                      {agg['frontend']:>7.2f} s"
      f"  ({100*agg['frontend']/agg['total']:.0f}% of rustc time)")
print(f"    of which type_check_crate    {agg['typeck']:>7.2f} s")
print(f"    of which MIR_borrow_checking {agg['borrowck']:>7.2f} s")
print(f"    of which generate_crate_metadata {agg['metadata_pass']:>3.2f} s")
print(f"  IR generation                 {agg['ir']:>7.2f} s"
      f"  ({100*agg['ir']/agg['total']:.0f}%)")
print(f"  LLVM backend (wall)           {agg['backend']:>7.2f} s"
      f"  ({100*agg['backend']/agg['total']:.0f}%)")
print(f"    LLVM_passes  (thread-summed) {agg['llvm_passes']:>6.2f} s")
print(f"    LLVM_thinlto (thread-summed) {agg['llvm_thinlto']:>6.2f} s")
print(f"  link                          {agg['link']:>7.2f} s"
      f"  ({100*agg['link']/agg['total']:.1f}%)")
json.dump(rows, open(f"{SP}/passes.json", "w"), indent=1)
