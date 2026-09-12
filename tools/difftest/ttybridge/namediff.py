#!/usr/bin/env python3
"""Enumerate every `getDisplayName()` the port renders differently from the 4.1.0 jar.

`statsgate.py` reported 105 failing cases; eyeballing four diffs suggested they were all one
class, and "suggested" is not a measurement. This walks EVERY failing case, aligns the two
outputs row by row, and reports the distinct (java, swift) name pairs with the number of cases
each appears in — so the claim "it is one class" is either confirmed with a list or refuted by a
row that does not fit.

The rows are `<unique>\\t<recursive>\\t<name padded>\\t<library>`. Alignment is by (unique,
recursive, library) position, i.e. by row index, since the row ORDER is `sortCounts` and is not
in question here — only the name column is.

    LOGISIM_CORPUS=... python3 namediff.py

── WHAT IT FOUND, AND WHAT IS LEFT ─────────────────────────────────────────────────────────

The 105 were 12 component names and 1 library name, all of them `getDisplayName()` answering
the `_ID`. Fixed; the gate reads **1,728 / 7 of 1,735**. Note this script diagnoses only the
subset the CORPUS happens to contain — the port had 46 wrong factory names and 5 wrong library
names in total, and the exhaustive check is `tools/valuebridge/NameBridge.java` plus
`LogisimStdTests/DisplayNameOracleTests`, which walk the whole builtin set out of the jar.

The 7 that remain are NOT name defects and this script says so:

  * 6 cases across two Cyrillic-named corpus files, where the library column differs only by
    Unicode normalisation — macOS hands back NFD from the filesystem, the jar has NFC, so `й`
    arrives as `и` + U+0306. Bucketed separately below; see the comment at the branch.
  * 1 case (`3.7.2__case-278.circ::main`) where the port omits a whole subcircuit row,
    `Sigmoid_Activation_Function`, and both totals are one lower. A counting defect, unrelated.
"""
import collections
import concurrent.futures as cf
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
    if not CORPUS:
        sys.exit("set LOGISIM_CORPUS")
    if not os.path.exists(CLI):
        sys.exit(f"logisim-cli not built at {CLI}")
    golden_dir = os.path.join(CORPUS, "golden-stats")
    index = json.load(open(os.path.join(golden_dir, "_inventory.json")))

    by_name = {}
    for pattern in ("*.circ", os.path.join("harvested", "*.circ"),
                    os.path.join("harvested", "*")):
        for p in glob.glob(os.path.join(CORPUS, pattern)):
            if not os.path.isdir(p):
                by_name.setdefault(os.path.basename(p), p)

    nondet_path = os.path.join(HERE, "stats-nondeterministic.json")
    nondet = set()
    if os.path.exists(nondet_path):
        nondet = set(json.load(open(nondet_path)).get("cases", {}))

    def one(rec):
        key = f"{rec['file']}::{rec['circuit']}"
        if key in nondet:
            return None
        path = by_name.get(rec["file"])
        if not path:
            return None
        try:
            p = subprocess.run(
                [CLI, "--toplevel-circuit", rec["circuit"], "--tty", "stats",
                 os.path.basename(path)],
                cwd=os.path.dirname(path), capture_output=True, text=True, timeout=60)
        except subprocess.TimeoutExpired:
            return None
        if p.returncode != 0:
            return (key, "CLI-FAILED", None)
        want = open(os.path.join(golden_dir, rec["golden"])).read()
        if p.stdout == want:
            return None
        return (key, want, p.stdout)

    pairs = collections.Counter()
    padding_only = [0]
    normalisation_only = [0]
    other = []
    cases = list(index.values())
    with cf.ThreadPoolExecutor(max_workers=8) as ex:
        for result in ex.map(one, cases):
            if result is None:
                continue
            key, want, got = result
            if got is None:
                other.append((key, "the CLI exited nonzero"))
                continue
            a = want.rstrip("\n").split("\n")
            b = got.rstrip("\n").split("\n")
            if len(a) != len(b):
                other.append((key, f"row COUNT differs: java {len(a)} vs swift {len(b)}"))
                continue
            for ra, rb in zip(a, b):
                if ra == rb:
                    continue
                fa = ra.split("\t")
                fb = rb.split("\t")
                if len(fa) != 4 or len(fb) != 4:
                    other.append((key, f"java {ra!r} vs swift {rb!r}"))
                    continue
                name_a, name_b = fa[2].rstrip(), fb[2].rstrip()
                if fa[0] == fb[0] and fa[1] == fb[1] and fa[3] == fb[3]:
                    if name_a != name_b:
                        pairs[("component", name_a, name_b)] += 1
                    else:
                        # PADDING ONLY. `maxName` is the widest display name in the whole table,
                        # so ONE divergent name re-pads every other row. Counting these as name
                        # differences is what made the first run of this script report 89 pairs
                        # of which most had java == swift: a real result buried in its own
                        # consequences.
                        padding_only[0] += 1
                elif fa[0] == fb[0] and fa[1] == fb[1] and name_a == name_b:
                    # A library column that differs ONLY by Unicode normalisation is not a
                    # display-name defect and must not be reported as one. Two of the corpus
                    # files have Cyrillic names, and macOS hands back NFD from the filesystem
                    # while the jar's own reader gives NFC, so `й` arrives as `и` + U+0306.
                    # The first version of this script printed those as
                    #   `java <name> -> swift <name>`
                    # with the two sides looking IDENTICAL on screen: 12 of the 15 reported
                    # rows were real and 3 were this, and nothing in the output said which.
                    if unicodedata.normalize("NFC", fa[3]) == unicodedata.normalize("NFC", fb[3]):
                        normalisation_only[0] += 1
                    else:
                        pairs[("library", fa[3], fb[3])] += 1
                else:
                    other.append((key, f"java {ra!r} vs swift {rb!r}"))

    print(f"{len(pairs)} distinct GENUINE (java, swift) name divergences:\n")
    width = max((len(j) for _, j, _ in pairs), default=0)
    for (kind, j, s), n in sorted(pairs.items(), key=lambda kv: (kv[0][0], -kv[1])):
        print(f"  {n:>4}x  {kind:<9}  java {j:<{width}}  ->  swift {s}")
    print(f"\n  {normalisation_only[0]} further row(s) differ ONLY by Unicode normalisation")
    print("  (NFD from the macOS filesystem vs NFC from the jar) — a filename-encoding issue,")
    print("  not a display-name one, and the two sides look identical when printed.")
    print(f"\n  {padding_only[0]} further row(s) differ in PADDING ONLY — one divergent name")
    print("  re-pads every row in its table, because maxName is the widest name in the table.")
    print(f"\n{len(other)} row(s) NOT explained by a name-column difference:")
    for key, why in other[:40]:
        print(f"  {key}: {why}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
