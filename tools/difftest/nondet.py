#!/usr/bin/env python3
"""Bucket the oracles the Java jar cannot reproduce against ITSELF.

Part of the corpus is not a stable oracle, and counting those cases as port defects permanently
blames the port for matching upstream. Two known causes, both in 4.1.0:

  * `XmlReader.generateValidVHDLLabel` repairs a label that is not a legal VHDL identifier and,
    *if it changed anything*, appends `UUID.randomUUID().toString().substring(0, 8)`
    (`XmlReader.java:717`, `:758`). A column NAME therefore changes on every run.
  * `Random.StateData.getRandomSeed` (`std/memory/Random.java:103-115`) treats seed 0, the
    default — as "use `System.currentTimeMillis()`". Column VALUES therefore change on every run.

── Why this measures instead of reasoning about reachability ───────────────────────────────────

The obvious detector is static: find every circuit that places a `Random` with `seed` absent or 0,
transitively through subcircuits, and bucket those. **That detector was written, and it is wrong.**
It flagged `3.6.0__case-458.circ::MoveCore`, which then went byte-exact once the ROM port-geometry
defect was fixed. A seed-0 `Random` on the schematic does not imply nondeterministic *output*:
whether the nondeterminism reaches a column depends on whether anything downstream of it is a
pin, which is circuit-dependent and not decidable from the placement.

So the only sound test is the one that made the original diagnosis: run the same jar over the same
bytes N times and see whether the output actually moves. That is what this does.

    python3 nondet.py --runs 5 < failing-cases.txt
    python3 nondet.py --runs 5 --filter 'cpu|alu'

Reads `file::circuit` lines on stdin (blank lines and `#` comments ignored), or takes `--filter`
over the golden inventory. Writes `nondeterministic.json` beside this script.

Classification, per case:

    stable      all N runs identical                     -> a real oracle; a mismatch is a defect
    label       differ, but identical once every `_<8 hex>` token is masked -> the UUID class
    value       differ even after masking                -> the seed-0 `Random` class

`label` and `value` are both "Java cannot reproduce this", but they are kept apart because they
need different handling: a `label` case can still be compared row-for-row with the suffix masked
out of BOTH sides, which is worth doing — requiring every other line to be byte-identical, as the
Swift suite used to, hid 8 genuine body divergences behind a random label. A `value` case cannot
be compared at all.

Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
"""
import argparse, collections, hashlib, json, os, re, subprocess, sys
import concurrent.futures as cf

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rig import JAVA, JAR, circ_files, corpus_dir, run_java  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "nondeterministic.json")

# `XmlReader` writes the suffix with dashes turned to underscores, so it is 8 lowercase hex
# characters preceded by an underscore. Anchored on a word boundary so a longer hex run is not
# partially eaten.
UUID_SUFFIX = re.compile(r"_[0-9a-f]{8}\b")


def mask(text):
    return UUID_SUFFIX.sub("_UUID", text)


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()[:12]


def classify(outputs):
    """`outputs` is a list of N captures of the same case."""
    if any(o is None for o in outputs):
        return "error", []
    raw = [digest(o) for o in outputs]
    if len(set(raw)) == 1:
        return "stable", raw
    if len({digest(mask(o)) for o in outputs}) == 1:
        return "label", raw
    return "value", raw


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--runs", type=int, default=5,
                    help="captures per case; 1 cannot detect anything (default 5)")
    ap.add_argument("--filter", default=None, help="regex over 'file::circuit'")
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--golden", default=os.path.join(
        os.environ.get("LOGISIM_CORPUS", "."), "golden"))
    ap.add_argument("--out", default=OUT)
    args = ap.parse_args()

    if args.runs < 2:
        sys.exit("--runs must be at least 2: a single capture cannot detect variation, and a run "
                 "that can only report 'stable' is worse than no run at all.")

    corpus = corpus_dir()
    by_name = {}
    for p in circ_files(corpus):
        by_name.setdefault(os.path.basename(p), p)

    # Which cases? Either an explicit list on stdin, or a filter over the inventory.
    wanted = []
    if not sys.stdin.isatty() and args.filter is None:
        for line in sys.stdin:
            line = line.strip()
            if line and not line.startswith("#") and "::" in line:
                wanted.append(line)
    if args.filter is not None:
        pattern = re.compile(args.filter)
        index = json.load(open(os.path.join(args.golden, "_inventory.json")))
        wanted = [f"{r['file']}::{r['circuit']}" for r in index.values()
                  if pattern.search(f"{r['file']}::{r['circuit']}")]
    wanted = sorted(set(wanted))
    if not wanted:
        sys.exit("no cases given — pipe 'file::circuit' lines on stdin or pass --filter")

    print(f"probing {len(wanted)} case(s) x {args.runs} runs of the 4.1.0 jar "
          f"({len(wanted) * args.runs} JVM invocations)")

    def probe(case):
        fname, circ = case.split("::", 1)
        path = by_name.get(fname)
        if not path:
            return case, "missing", []
        outs = [run_java(path, circ, args.timeout) for _ in range(args.runs)]
        # ASSERT THE ORACLE PRODUCED OUTPUT. A drivable entry point that writes nothing and exits
        # 0 looks exactly like agreement; this project has been caught by that twice.
        if any(o is None or o.startswith("\0CRASH:") or o.count("\n") <= 2 for o in outs):
            # A crashed run still streams thousands of valid-looking rows before dying, so this
            # must be checked, not assumed. `3.5.0__case-383.circ::truc` dies in `Buzzer.propagate` at a
            # different row every time and would otherwise be classified `value` -- true, but for
            # the wrong reason, and it would imply an oracle exists.
            return case, "crash", []
        return (case, *classify(outs))

    results = {}
    counts = collections.Counter()
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for case, verdict, hashes in ex.map(probe, wanted):
            counts[verdict] += 1
            results[case] = {"class": verdict, "hashes": hashes}
            if verdict != "stable":
                print(f"  {verdict:<7} {case}  {' '.join(hashes)}")

    usable = counts["stable"] + counts["label"] + counts["value"]
    if usable == 0:
        sys.exit(f"\nREFUSING TO WRITE: none of {len(wanted)} cases produced a usable capture "
                 f"({dict(counts)}). The oracle did not run, and an empty result is not evidence "
                 "of determinism — it looks exactly like it.")

    payload = {
        "generated_by": "tools/difftest/nondet.py",
        "runs": args.runs,
        "jar": JAR,
        "java": JAVA,
        "note": "Observed run-to-run variation of the 4.1.0 jar against itself. NOT derived from "
                "static reachability of a seed-0 Random -- that detector was written, flagged "
                "3.6.0__case-458.circ::MoveCore, and MoveCore then passed byte-exactly once an "
                "unrelated ROM defect was fixed. Whether nondeterminism reaches an output column "
                "is circuit-dependent, so it is measured, not inferred.",
        "counts": dict(counts),
        "cases": {k: v for k, v in sorted(results.items()) if v["class"] not in ("stable",)},
        "stable": sorted(k for k, v in results.items() if v["class"] == "stable"),
    }
    with open(args.out, "w") as f:
        json.dump(payload, f, indent=1)
    print(f"\n  {dict(counts)}\n  -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
