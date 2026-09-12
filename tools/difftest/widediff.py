#!/usr/bin/env python3
"""Explain ONE wide-oracle mismatch in enough detail to classify it.

`widerun.py` reports the first differing line, which is enough to bucket a failure but
not to name its cause. This re-runs a single case and answers the questions that decide
what the failure IS:

  - how many of the N rows differ, not just the first;
  - whether the difference survives masking upstream's random VHDL label suffix
    (`XmlReader.generateValidVHDLLabel`, D-note in TruthTableGoldenTests) -- a header-only
    difference is upstream nondeterminism, a data difference is ours;
  - which COLUMNS differ, since a single bad column across every row is one defect and
    a scatter is another;
  - the distribution of the differing cells (E-vs-U, U-vs-value, value-vs-value).

    LOGISIM_CORPUS=... python3 widediff.py --cli ./logisim-cli \
        --file 2.7.1__case-430.circ --circuit DL

Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
"""
import argparse
import collections
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from widerun import UUID_SUFFIX, corpus_dir, load_inventory, locate  # noqa: E402


def cell_class(java, swift):
    """Name the shape of one differing cell."""
    j, s = java.strip(), swift.strip()
    if not j or not s:
        return "width/blank"
    if j == "E" and s == "U":
        return "java E -> swift U"
    if j == "U" and s == "E":
        return "java U -> swift E"
    if s == "U":
        return "java value -> swift U"
    if j == "U":
        return "java U -> swift value"
    if s == "E":
        return "java value -> swift E"
    if j == "E":
        return "java E -> swift value"
    return "different value"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cli", required=True)
    ap.add_argument("--file", required=True)
    ap.add_argument("--circuit", required=True)
    ap.add_argument("--timeout", type=int, default=1800)
    ap.add_argument("--show", type=int, default=6, help="differing rows to print")
    args = ap.parse_args()

    corpus = corpus_dir()
    index = load_inventory(corpus)
    entry = next((r for r in index.values()
                  if r["file"] == args.file and r["circuit"] == args.circuit), None)
    if not entry:
        sys.exit(f"no golden entry for {args.file}::{args.circuit}")

    path, _ = locate(entry, corpus)
    with open(os.path.join(corpus, "golden", entry["golden"]),
              encoding="utf-8", errors="replace") as f:
        expected = f.read()

    p = subprocess.run(
        [args.cli, "--toplevel-circuit", args.circuit, "--tty", "table",
         os.path.basename(path)],
        cwd=os.path.dirname(os.path.abspath(path)), capture_output=True, text=True,
        timeout=args.timeout)
    got = p.stdout
    print(f"{args.file}::{args.circuit}   exit={p.returncode}   "
          f"golden={len(expected):,}B  swift={len(got):,}B")
    if got.count("\n") <= 2:
        sys.exit("!! swift produced no table (silent zero-output success)")

    e = expected.split("\n")
    a = got.split("\n")
    print(f"lines: java={len(e)}  swift={len(a)}")
    if len(e) != len(a):
        print("!! line counts differ -- structural, not a value defect")
        return 0

    # Header, masked and unmasked.
    hdr_e, hdr_a = e[0], a[0]
    masked_e, masked_a = UUID_SUFFIX.sub("_U", hdr_e), UUID_SUFFIX.sub("_U", hdr_a)
    print(f"header identical:        {hdr_e == hdr_a}")
    print(f"header identical masked: {masked_e == masked_a}"
          f"   (suffix present: {masked_e != hdr_e})")
    if masked_e != masked_a:
        print(f"  java : {hdr_e[:160]}")
        print(f"  swift: {hdr_a[:160]}")

    body_diff = [i for i in range(1, len(e)) if e[i] != a[i]]
    print(f"differing body rows: {len(body_diff):,} of {len(e) - 1:,} "
          f"({100.0 * len(body_diff) / max(1, len(e) - 1):.1f}%)")
    if not body_diff:
        print("=> HEADER-ONLY difference. This is upstream's random VHDL label, not a port bug.")
        return 0

    # Column attribution. The tables are space-aligned, so split on runs of 2+ spaces
    # after stripping, which keeps multi-space-padded columns together.
    def cols(line):
        return re.split(r"\s+", line.strip())

    names = cols(hdr_e)
    per_col = collections.Counter()
    shapes = collections.Counter()
    for i in body_diff:
        ce, ca = cols(e[i]), cols(a[i])
        if len(ce) != len(ca):
            per_col["<column count differs>"] += 1
            continue
        for k, (x, y) in enumerate(zip(ce, ca)):
            if x != y:
                per_col[names[k] if k < len(names) else f"col{k}"] += 1
                shapes[cell_class(x, y)] += 1

    print("\ndiffering cells by column:")
    for name, count in per_col.most_common(12):
        print(f"  {count:>9,}  {name}")
    print("\ndiffering cells by shape:")
    for shape, count in shapes.most_common():
        print(f"  {count:>9,}  {shape}")

    print(f"\nfirst {args.show} differing rows:")
    for i in body_diff[:args.show]:
        print(f"  row {i}")
        print(f"    java : {e[i][:150]}")
        print(f"    swift: {a[i][:150]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
