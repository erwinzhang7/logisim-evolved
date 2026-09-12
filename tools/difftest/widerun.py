#!/usr/bin/env python3
"""Run the golden oracles the M3 unit-test gate SKIPS, and classify what they do.

`TruthTableGoldenTests` caps at `LOGISIM_M3_MAX_ROWS` = 4096 rows and reports the
remainder as `skipped (> 4096 rows)`. That is 110 of 1,392 oracles carrying 97.1% of
all corpus rows (`widecensus.py`). Skipped is not green. This runs them.

    LOGISIM_CORPUS=/path/to/corpus \
      python3 widerun.py --cli /path/to/logisim-cli --min-rows 4097

    python3 widerun.py --min-rows 4097 --max-rows 8192   # cheapest band first
    python3 widerun.py --max-rows 4096 --sample 120      # control: known-good band

Writes a JSON result to --out. Reads the corpus; writes nothing else.

── Two measurement traps this deliberately avoids ────────────────────────────────────

1. **Basename collision.** `rig.py`'s `compare()` resolves a golden entry back to a
   corpus file with `by_name.setdefault(basename(p), p)` — the FIRST file with that
   basename wins. Corpus basenames are not unique, and `rig.py`'s own `golden_name`
   comment records hitting exactly this. So `rig.py` can diff a circuit against a
   DIFFERENT file's oracle and blame the port. `TruthTableGoldenTests.locate()` fixed
   it by replaying the `sha256(abspath + "__" + circuit)[:8]` suffix that `golden_name`
   already embeds. This does the same, and reports how many entries were ambiguous.

2. **Silent zero-output success.** The CLI exits 0 having written nothing for a circuit
   with no table (`golden-13.circ::main` emits 2 bytes and exits 0). An empty stdout
   compared against a non-empty golden must be its own loud bucket, never folded into
   "mismatch" and certainly never into "pass".

Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
"""
import argparse
import concurrent.futures as cf
import hashlib
import json
import os
import re
import subprocess
import sys
import time

UUID_SUFFIX = re.compile(r"_[0-9a-f]{8}\b")


def corpus_dir():
    d = os.environ.get("LOGISIM_CORPUS")
    if not d or not os.path.isdir(d):
        sys.exit("set LOGISIM_CORPUS to the corpus directory (see docs/objectives.md)")
    return d


def load_inventory(corpus):
    path = os.path.join(corpus, "golden", "_inventory.json")
    if not os.path.exists(path):
        sys.exit(f"no golden inventory at {path}")
    with open(path) as f:
        return json.load(f)


def locate(entry, corpus):
    """Resolve a golden entry back to the exact corpus file its oracle ran on.

    Mirrors `TruthTableGoldenTests.locate`. Returns (path, was_ambiguous).
    """
    candidates = [
        p for p in (os.path.join(corpus, entry["file"]),
                    os.path.join(corpus, "harvested", entry["file"]))
        if os.path.exists(p)
    ]
    if not candidates:
        return None, False
    if len(candidates) == 1:
        return candidates[0], False

    # golden_name builds "{safe[:160]}__{digest}.table"; the digest is the last __-run.
    stem = os.path.splitext(entry["golden"])[0]
    digest = stem.split("__")[-1]
    for c in candidates:
        key = f"{os.path.abspath(c)}__{entry['circuit']}"
        if hashlib.sha256(key.encode()).hexdigest()[:8] == digest:
            return c, True
    return candidates[0], True


def differs_only_by_generated_label(expected, actual):
    """Whether the only difference is XmlReader's random 8-hex-digit VHDL label suffix.

    Mirrors `TruthTableGoldenTests.differsOnlyByGeneratedLabel`, including its strictness:
    every line after the header must be byte-identical, and a suffix must actually have
    been present on the expected side (otherwise masking nothing on both sides would let
    an unrelated header difference through).
    """
    e = expected.split("\n")
    a = actual.split("\n")
    if len(e) != len(a) or not e or not a:
        return False
    if any(x != y for x, y in zip(e[1:], a[1:])):
        return False
    norm_e = UUID_SUFFIX.sub("_UUID", e[0])
    if norm_e == e[0]:
        return False
    return norm_e == UUID_SUFFIX.sub("_UUID", a[0])


def first_difference(expected, actual):
    e = expected.split("\n")
    a = actual.split("\n")
    for i in range(max(len(e), len(a))):
        el = e[i] if i < len(e) else "<missing>"
        al = a[i] if i < len(a) else "<missing>"
        if el != al:
            return f"line {i + 1}: java={el[:70]}| swift={al[:70]}|"
    return "identical lines but unequal text (trailing newline?)"


def circuit_names(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            src = f.read()
    except OSError:
        return set(), ""
    return set(re.findall(r'<circuit name="([^"]+)"', src)), src


def is_hierarchical(path, circuit):
    """Whether `circuit` instantiates another circuit from the same file.

    Read from the XML, not the loaded model, so the attribution is independent of the
    code under test. Mirrors `TruthTableGoldenTests.isHierarchical`.
    """
    names, src = circuit_names(path)
    start = src.find(f'<circuit name="{circuit}">')
    if start < 0:
        return False
    end = src.find("</circuit>", start)
    body = src[start:end if end > 0 else len(src)]
    return any(n in names for n in re.findall(r'<comp[^>]* name="([^"]+)"', body))


def run_one(args, corpus, entry):
    path, ambiguous = locate(entry, corpus)
    rec = {
        "file": entry["file"], "circuit": entry["circuit"], "rows": entry["lines"],
        "ambiguous_basename": ambiguous,
    }
    if not path:
        rec["status"] = "NO-CORPUS-FILE"
        return rec

    golden_path = os.path.join(corpus, "golden", entry["golden"])
    try:
        with open(golden_path, encoding="utf-8", errors="replace") as f:
            expected = f.read()
    except OSError as exc:
        rec["status"] = "NO-GOLDEN"
        rec["detail"] = str(exc)
        return rec

    # Assert the oracle itself is non-trivial before trusting any comparison against it.
    if len(expected) < 3 or expected.count("\n") <= 2:
        rec["status"] = "GOLDEN-EMPTY"
        rec["detail"] = f"golden is {len(expected)} bytes"
        return rec

    cmd = [args.cli, "--toplevel-circuit", entry["circuit"], "--tty", "table",
           os.path.basename(path)]
    t0 = time.time()
    try:
        p = subprocess.run(cmd, cwd=os.path.dirname(os.path.abspath(path)),
                           capture_output=True, text=True, timeout=args.timeout)
    except subprocess.TimeoutExpired:
        rec["status"] = "TIMEOUT"
        rec["seconds"] = round(time.time() - t0, 1)
        return rec
    except FileNotFoundError:
        sys.exit(f"logisim-cli not found: {args.cli}")
    rec["seconds"] = round(time.time() - t0, 1)

    if p.returncode != 0:
        rec["status"] = "NONZERO-EXIT"
        rec["detail"] = (p.stderr or "").strip().split("\n")[0][:200]
        return rec

    got = p.stdout
    # The dangerous case: exit 0, nothing written. Never let this look like agreement.
    if got.count("\n") <= 2:
        rec["status"] = "EMPTY-OUTPUT"
        rec["detail"] = f"exit 0 but wrote {len(got)} bytes against a {len(expected)}-byte golden"
        return rec

    if got == expected:
        rec["status"] = "MATCH"
        return rec
    if differs_only_by_generated_label(expected, got):
        rec["status"] = "UUID-LABEL-ONLY"
        return rec

    rec["status"] = "MISMATCH"
    rec["detail"] = first_difference(expected, got)
    rec["hierarchical"] = is_hierarchical(path, entry["circuit"])
    rec["got_rows"] = got.count("\n")
    rec["want_rows"] = expected.count("\n")
    return rec


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cli", required=True)
    ap.add_argument("--min-rows", type=int, default=4097)
    ap.add_argument("--max-rows", type=int, default=1 << 30)
    ap.add_argument("--timeout", type=int, default=900)
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--sample", type=int, default=0, help="cap the number of cases")
    ap.add_argument("--filter", default=".", help="regex over 'file::circuit'")
    ap.add_argument("--out", default="/tmp/widerun.json")
    args = ap.parse_args()
    pattern = re.compile(args.filter)

    corpus = corpus_dir()
    index = load_inventory(corpus)
    cases = [r for r in index.values()
             if args.min_rows <= r["lines"] <= args.max_rows
             and pattern.search(f"{r['file']}::{r['circuit']}")]
    cases.sort(key=lambda r: r["lines"])          # cheapest first, so partial runs are useful
    if args.sample:
        cases = cases[:args.sample]
    if not cases:
        sys.exit("no cases selected")

    print(f"{len(cases)} cases  ·  rows {args.min_rows}..{args.max_rows}  ·  cli={args.cli}",
          flush=True)

    results = []
    t0 = time.time()
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        futures = [ex.submit(run_one, args, corpus, c) for c in cases]
        for i, fut in enumerate(cf.as_completed(futures), 1):
            rec = fut.result()
            results.append(rec)
            mark = "." if rec["status"] == "MATCH" else rec["status"][0]
            print(f"[{i}/{len(cases)}] {mark} {rec['status']:<15} {rec['rows']:>8,}r "
                  f"{rec.get('seconds', 0):>7.1f}s  {rec['file'][:52]}::{rec['circuit'][:22]}",
                  flush=True)

    tally = {}
    for r in results:
        tally[r["status"]] = tally.get(r["status"], 0) + 1

    print(f"\n{'=' * 70}")
    print(f"  {len(results)} cases in {time.time() - t0:.0f}s wall")
    for status, count in sorted(tally.items(), key=lambda kv: -kv[1]):
        print(f"    {status:<16} {count}")
    hier = sum(1 for r in results if r.get("hierarchical"))
    print(f"    of the mismatches, hierarchical: {hier}")
    amb = sum(1 for r in results if r.get("ambiguous_basename"))
    print(f"    entries whose basename was ambiguous (rig.py would misresolve): {amb}")

    with open(args.out, "w") as f:
        json.dump(results, f, indent=1)
    print(f"  wrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
