#!/usr/bin/env python3
"""Census of the golden oracle set by table height.

Exists because the M3 gate reports a `skipped (> N rows)` line and nothing else about
those cases, so "110 skipped" was a number with no shape behind it. Before deciding
whether the cap can be raised or removed, you need to know what is actually up there:
how many oracles, how tall, and how much of the corpus's total row count they carry.

    LOGISIM_CORPUS=/path/to/corpus python3 widecensus.py
    python3 widecensus.py --cap 4096

Reads only. Writes nothing.
"""
import argparse
import json
import os
import sys


def corpus_dir():
    d = os.environ.get("LOGISIM_CORPUS")
    if not d or not os.path.isdir(d):
        sys.exit("set LOGISIM_CORPUS to the corpus directory (see docs/objectives.md)")
    return d


def load_inventory(corpus):
    path = os.path.join(corpus, "golden", "_inventory.json")
    if not os.path.exists(path):
        sys.exit(f"no golden inventory at {path} — run rig.py --regenerate first")
    with open(path) as f:
        return json.load(f)


BUCKETS = [
    (4097, 8192, "4097-8k"),
    (8192, 16384, "8k-16k"),
    (16384, 32768, "16k-32k"),
    (32768, 65536, "32k-64k"),
    (65536, 131072, "64k-128k"),
    (131072, 1 << 30, "128k+"),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cap", type=int, default=4096,
                    help="the LOGISIM_M3_MAX_ROWS value being audited")
    ap.add_argument("--json", help="write the over-cap entries here for downstream tools")
    args = ap.parse_args()

    corpus = corpus_dir()
    index = load_inventory(corpus)
    rows = sorted(r["lines"] for r in index.values())
    n = len(rows)

    over = [r for r in index.values() if r["lines"] > args.cap]
    under = n - len(over)

    print(f"golden oracles       {n}")
    print(f"total rows           {sum(rows):,}")
    print(f"median rows          {rows[n // 2]}")
    print(f"max rows             {rows[-1]:,}")
    print()
    print(f"cap = {args.cap}")
    print(f"  at or under cap    {under}")
    print(f"  over cap (SKIPPED) {len(over)}")
    print(f"  rows in the skipped set {sum(r['lines'] for r in over):,} "
          f"({100.0 * sum(r['lines'] for r in over) / sum(rows):.1f}% of all rows)")
    print()
    print("height distribution of the skipped set:")
    for lo, hi, label in BUCKETS:
        sel = [r for r in over if lo <= r["lines"] < hi]
        if sel:
            print(f"  {label:>9}  {len(sel):>4} oracles  {sum(x['lines'] for x in sel):>12,} rows")

    print()
    print("the skipped set, tallest first:")
    for r in sorted(over, key=lambda r: -r["lines"]):
        print(f"  {r['lines']:>9,}  {r['file']}::{r['circuit']}")

    if args.json:
        with open(args.json, "w") as f:
            json.dump(sorted(over, key=lambda r: -r["lines"]), f, indent=1)
        print(f"\nwrote {len(over)} entries -> {args.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
