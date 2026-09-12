#!/usr/bin/env python3
"""Bucket the migration-gate diffs so a fix can be aimed at one cause at a time.

The round-trip rig reports a pass/fail count; when the count is 0/539 that number says
nothing about *which* of several independent defects is responsible. This runs the same
migration condition (`load(f) -> save` vs `-n(f)`) over every baseline and groups the
unified diffs by their shape, so the report reads "N files differ only in <x>".

    LOGISIM_CORPUS=... python3 tools/difftest/migreport.py [--filter RE] [--show N]
"""
import argparse, collections, concurrent.futures as cf, difflib, json, os, re, subprocess, sys, tempfile

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_CLI = os.path.join(REPO, "swift", ".build", "debug", "logisim-cli")


def classify(diff_lines):
    """A coarse signature: the set of (sign, element-or-attribute name) seen."""
    sig = set()
    for line in diff_lines:
        if line.startswith(("---", "+++", "@@")):
            continue
        if not line or line[0] not in "+-":
            continue
        sign, body = line[0], line[1:].strip()
        m = re.match(r'<a name="([^"]*)"', body)
        if m:
            sig.add(f"{sign}a:{m.group(1)}")
            continue
        m = re.match(r"</?(\w+)", body)
        if m:
            tag = m.group(1)
            name = re.search(r'name="([^"]*)"', body)
            lib = re.search(r'lib="([^"]*)"', body)
            label = tag + (f"[{name.group(1)}]" if name else "")
            if lib:
                label += f" lib={lib.group(1)}"
            sig.add(f"{sign}{label}")
            continue
        sig.add(f"{sign}?{body[:24]}")
    return tuple(sorted(sig))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cli", default=DEFAULT_CLI)
    ap.add_argument("--filter", dest="pattern", default=".")
    ap.add_argument("--show", type=int, default=25)
    ap.add_argument("--sample", default=None, help="print the full diff for the first file whose signature matches this regex")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--baseline", default="migrated",
                    help="subdirectory of $LOGISIM_CORPUS/canonical holding the expected "
                         "output; use migrated_solo for the uncontaminated set")
    args = ap.parse_args()
    pattern = re.compile(args.pattern)

    corpus = os.environ.get("LOGISIM_CORPUS")
    if not corpus:
        sys.exit("set LOGISIM_CORPUS")
    root = os.path.join(corpus, "canonical")
    index = json.load(open(os.path.join(root, "_index.json")))
    cases = [(s, b) for s, b in index.items() if pattern.search(os.path.basename(s))]

    # Files upstream cannot reproduce byte-for-byte itself (see solobaseline.py): the label
    # repair appends a random UUID fragment, so two runs disagree. Excluded with a reason
    # rather than counted as failures.
    excluded = set()
    nd = os.path.join(root, args.baseline, "_nondeterministic.json")
    if os.path.exists(nd):
        excluded = set(json.load(open(nd)))
    cases = [(s, b) for s, b in cases if b not in excluded]

    tmp = tempfile.mkdtemp(prefix="migreport-")

    def one(case):
        src, base = case
        expected = os.path.join(root, args.baseline, base)
        out = os.path.join(tmp, base)
        try:
            p = subprocess.run([args.cli, "--convert", src, out],
                               capture_output=True, text=True, timeout=120)
        except Exception as exc:
            return base, ("<crash>",), str(exc)
        if p.returncode != 0 or not os.path.exists(out):
            return base, ("<no-output>",), (p.stderr or "").strip()[:200]
        got = open(out, encoding="utf-8", errors="replace").read()
        want = open(expected, encoding="utf-8", errors="replace").read()
        if got == want:
            return base, (), ""
        d = list(difflib.unified_diff(want.splitlines(), got.splitlines(),
                                      "java", "swift", lineterm="", n=0))
        return base, classify(d), "\n".join(d)

    results = []
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for r in pool.map(one, cases):
            results.append(r)

    buckets = collections.Counter()
    examples = {}
    npass = 0
    for base, sig, detail in results:
        if not sig:
            npass += 1
            continue
        buckets[sig] += 1
        examples.setdefault(sig, (base, detail))

    print(f"migration  pass {npass}  ·  fail {len(results) - npass}  ·  of {len(results)}"
          f"   ({len(excluded)} excluded: no byte-exact expectation exists)\n")
    for sig, n in buckets.most_common(args.show):
        print(f"{n:5d}  {' '.join(sig) if sig else '(identical)'}")
        print(f"        e.g. {examples[sig][0]}")
    if args.sample:
        rx = re.compile(args.sample)
        for sig, _ in buckets.most_common():
            if rx.search(" ".join(sig)):
                base, detail = examples[sig]
                print(f"\n===== full diff: {base}\n{detail}")
                break


if __name__ == "__main__":
    main()
