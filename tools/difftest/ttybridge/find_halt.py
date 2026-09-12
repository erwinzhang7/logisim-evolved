#!/usr/bin/env python3
"""List corpus (file, circuit) pairs that own an OUTPUT pin labelled `halt`.

`TtyInterface.run` only reaches `runSimulation` — the loop that `speed` and `halt`
report on — when the circuit has an output pin named exactly "halt", or when the
format carries no FORMAT_TABLE bit. Without one, `while (true)` has no exit but an
oscillation, so a healthy circuit runs forever (measured: `-tty speed` on
golden-15.circ, killed at 15 s having printed nothing).

So the set printed here is the entire population on which `speed`/`halt` are
answerable at all. Its size is the evidence for whether those formats are worth
porting.
"""
import glob
import os
import re
import sys
import xml.etree.ElementTree as ET

CORPUS = os.environ.get("LOGISIM_CORPUS")
if not CORPUS:
    sys.exit("LOGISIM_CORPUS is unset; this enumerates the corpus and has nothing to read")


def circ_files(corpus):
    seen, out = set(), []
    for pattern in ("*.circ", os.path.join("harvested", "*.circ"),
                    os.path.join("harvested", "*")):
        for p in glob.glob(os.path.join(corpus, pattern)):
            real = os.path.realpath(p)
            if real in seen or os.path.isdir(p):
                continue
            seen.add(real)
            out.append(p)
    return sorted(out)


def main():
    hits = []
    scanned = 0
    for path in circ_files(CORPUS):
        try:
            root = ET.parse(path).getroot()
        except Exception:
            continue
        scanned += 1
        for circuit in root.iter("circuit"):
            for comp in circuit.iter("comp"):
                if comp.get("name") != "Pin":
                    continue
                attrs = {a.get("name"): a.get("val") for a in comp.iter("a")}
                if attrs.get("label") != "halt":
                    continue
                # Pin direction: 4.x writes `output="true"`; pre-4.0 writes
                # `type="output"`. Absent means input, which TtyInterface ignores
                # for halt purposes (it only scans the output list).
                is_output = (attrs.get("output") == "true"
                             or attrs.get("type") == "output")
                hits.append((path, circuit.get("name"), is_output))
    outs = [h for h in hits if h[2]]
    print(f"scanned {scanned} parseable .circ files")
    print(f"{len(hits)} pin(s) labelled 'halt'; {len(outs)} of them are OUTPUT pins")
    for path, circ, _ in outs:
        print(f"  {os.path.basename(path)}::{circ}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
