#!/usr/bin/env python3
"""Split the rig's failures into 'the oracle moved' and 'the port is wrong'.

`rig.py` compares bytes, so it scores three very different things as one failure:

  * the oracle carries a random `generateValidVHDLLabel` UUID in a column NAME;
  * the oracle's VALUES move run to run (seed-0 `Random`);
  * the port genuinely disagrees.

`nondet.py` answers the first two by re-running the **jar**. It cannot answer the third, and —
this is the part that has been got wrong before — a case being `label`-class does NOT excuse it.
The jar varying only in its label says nothing about whether the PORT's body matches. Section 6 of
`m3-simulation-gate.md` found exactly this: 8 real defects sat behind a random label, invisible
because the label alone was enough to make golden != port.

So this does the comparison that actually decides it: run the port, mask every `_<8 hex>` suffix
out of BOTH the golden and the port's output, and diff what is left.

    LOGISIM_CORPUS=... python3 classify.py --cli /abs/path/to/logisim-cli < failures.txt

Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
"""
import argparse, json, os, re, sys
import concurrent.futures as cf

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rig import DEFAULT_CLI, circ_files, corpus_dir, run_swift  # noqa: E402

UUID_SUFFIX = re.compile(r"_[0-9a-f]{8}\b")


def mask(t):
    return UUID_SUFFIX.sub("_UUID", t)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cli", default=DEFAULT_CLI)
    ap.add_argument("--golden", default=os.path.join(
        os.environ.get("LOGISIM_CORPUS", "."), "golden"))
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--nondet", default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "nondeterministic.json"))
    args = ap.parse_args()

    if not os.path.isabs(args.cli):
        # run_swift executes with cwd=dirname(circ), so a relative CLI path is never found and
        # EVERY case reports failure -- a 0/1391 that looks like a catastrophic regression. Cost
        # one full corpus sweep to notice.
        sys.exit(f"--cli must be an absolute path (got {args.cli!r}); run_swift runs with "
                 "cwd=dirname(circ), so a relative path silently fails every case.")

    corpus = corpus_dir()
    index = json.load(open(os.path.join(args.golden, "_inventory.json")))
    by_key = {f"{r['file']}::{r['circuit']}": r for r in index.values()}
    by_name = {}
    for p in circ_files(corpus):
        by_name.setdefault(os.path.basename(p), p)

    nd = {}
    if os.path.exists(args.nondet):
        nd = {k: v["class"] for k, v in json.load(open(args.nondet))["cases"].items()}

    cases = [ln.strip() for ln in sys.stdin if ln.strip() and "::" in ln]
    if not cases:
        sys.exit("no cases on stdin")

    def one(case):
        rec = by_key.get(case)
        if not rec:
            return case, "NOT-IN-INDEX", ""
        path = by_name.get(rec["file"])
        got = run_swift(args.cli, path, rec["circuit"], args.timeout)
        if got is None or got == "\0NOCLI":
            return case, "PORT-FAILED", ""
        want = open(os.path.join(args.golden, rec["golden"])).read()
        if got == want:
            return case, "byte-exact", ""
        if mask(want) == mask(got):
            return case, "label-only", ""
        if nd.get(case) == "value":
            return case, "oracle-unreproducible", ""
        # First genuinely differing line, with the label masked so the diagnostic is not the
        # random header.
        e, a = mask(want).split("\n"), mask(got).split("\n")
        for i in range(max(len(e), len(a))):
            el = e[i] if i < len(e) else "<missing>"
            al = a[i] if i < len(a) else "<missing>"
            if el != al:
                # Show the TAIL as well as the head. Truncating at ~52 characters made several
                # of these look like trailing-whitespace differences when the real divergence
                # (`0xUEUEUEUE` vs `0xUUUUUUUU`) sat in the last column, past the cut.
                return case, "PORT-DEFECT", (f"line {i+1}:\n             java={el[:150]}"
                                             f"\n             swft={al[:150]}")
        return case, "PORT-DEFECT", "differ only in trailing bytes"

    counts = {}
    rows = []
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for case, verdict, detail in ex.map(one, cases):
            counts[verdict] = counts.get(verdict, 0) + 1
            rows.append((verdict, case, detail))

    for verdict, case, detail in sorted(rows):
        if verdict in ("PORT-DEFECT", "PORT-FAILED", "NOT-IN-INDEX"):
            print(f"  {verdict:<10} {case}")
            if detail:
                print(f"             {detail}")
    print(f"\n  {counts}")
    print(f"  cases given {len(cases)}  ·  jar-class from {args.nondet}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
