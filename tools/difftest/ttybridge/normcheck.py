#!/usr/bin/env python3
"""Is the remaining Cyrillic-filename divergence a Unicode NORMALISATION difference?

`namediff.py` reports two `library` divergences whose java and swift strings PRINT IDENTICALLY:

    9x  library  java 3.7.1__case-538.circ ...  ->  swift 3.7.1__case-538.circ ...

Two strings that look the same and compare unequal is either a normalisation difference or an
invisible codepoint, and guessing which is exactly the kind of thing this project has been
burned by. This prints the codepoints of the differing run so the answer is read, not inferred.
"""
import glob
import json
import os
import subprocess
import sys
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
CLI = os.environ.get("LOGISIM_CLI",
                     os.path.join(REPO, "swift", ".build", "release", "logisim-cli"))
CORPUS = os.environ.get("LOGISIM_CORPUS")


def main():
    golden_dir = os.path.join(CORPUS, "golden-stats")
    index = json.load(open(os.path.join(golden_dir, "_inventory.json")))
    by_name = {}
    for pattern in ("*.circ", os.path.join("harvested", "*.circ"),
                    os.path.join("harvested", "*")):
        for p in glob.glob(os.path.join(CORPUS, pattern)):
            if not os.path.isdir(p):
                by_name.setdefault(os.path.basename(p), p)

    reported = 0
    for rec in index.values():
        # Only files whose NAME carries non-ASCII can show this.
        if all(ord(ch) < 128 for ch in rec["file"]):
            continue
        path = by_name.get(rec["file"])
        if not path:
            continue
        p = subprocess.run(
            [CLI, "--toplevel-circuit", rec["circuit"], "--tty", "stats",
             os.path.basename(path)],
            cwd=os.path.dirname(path), capture_output=True, text=True, timeout=60)
        if p.returncode != 0:
            continue
        want = open(os.path.join(golden_dir, rec["golden"])).read()
        if p.stdout == want:
            continue
        for ra, rb in zip(want.rstrip("\n").split("\n"), p.stdout.rstrip("\n").split("\n")):
            if ra == rb:
                continue
            fa, fb = ra.split("\t"), rb.split("\t")
            if len(fa) != 4 or len(fb) != 4 or fa[3] == fb[3]:
                continue
            a, b = fa[3], fb[3]
            print(f"{rec['file']}::{rec['circuit']}")
            print(f"  java  NFC={unicodedata.is_normalized('NFC', a)} "
                  f"NFD={unicodedata.is_normalized('NFD', a)} len={len(a)}")
            print(f"  swift NFC={unicodedata.is_normalized('NFC', b)} "
                  f"NFD={unicodedata.is_normalized('NFD', b)} len={len(b)}")
            print(f"  NFC(java) == NFC(swift): "
                  f"{unicodedata.normalize('NFC', a) == unicodedata.normalize('NFC', b)}")
            # The first differing codepoint, named.
            for i, (ca, cb) in enumerate(zip(a, b)):
                if ca != cb:
                    print(f"  first difference at {i}: "
                          f"java U+{ord(ca):04X} {unicodedata.name(ca, '?')} | "
                          f"swift U+{ord(cb):04X} {unicodedata.name(cb, '?')}")
                    break
            reported += 1
            break
        if reported >= 4:
            break
    if reported == 0:
        print("no non-ASCII library-name divergence found")
    return 0


if __name__ == "__main__":
    sys.exit(main())
