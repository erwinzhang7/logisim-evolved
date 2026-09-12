#!/usr/bin/env python3
"""Differential gate for the four `-tty table` MODIFIERS, against the 4.1.0 jar.

`binary`, `hex`, `csv` and `tabs` reshape what `-tty table` prints. `rig.py` gates the plain
table and `statsgate.py` gates `stats`; this is the third format gate and it exists for the
same reason as the other two: **a new format without oracle rows is untested scaffolding.**

    # build the golden set from the jar (slow; run when the corpus changes)
    LOGISIM_CORPUS=/path/to/corpus python3 tablefmtgate.py --regenerate

    # gate: diff the Swift CLI against golden
    LOGISIM_CORPUS=/path/to/corpus python3 tablefmtgate.py

    # is the ORACLE itself reproducible? runs the jar twice per case and diffs it with itself
    LOGISIM_CORPUS=/path/to/corpus python3 tablefmtgate.py --selfcheck

    # the two upstream behaviours this port DIVERGES from, measured rather than asserted
    python3 tablefmtgate.py --probe-divergences

Exit 0 only if every selected case matches. Anything else is a red gate.

WHAT IS BEING GATED, AND WHY IT IS NOT ONE `switch`
--------------------------------------------------
The handover note for this work said the four modifiers were "one `switch` inside
`TruthTableRun.valueFormat`". That was checked against `TtyInterface.java` before being
believed, and it is HALF right:

  * `binary` / `hex` ARE `valueFormat` (`:189-200`).
  * `csv` / `tabs` are NOT in `valueFormat` at all. They live in `displayTableRow`
    (`:158-186`) and change **two** things: the separator (`"\t"`, `","`, or `" "`) and the
    per-column format string — `"%s"` for csv and tabs versus `"%" + w + "s"` for the pretty
    form. **A csv or tabs table is therefore not padded**, and the header-row width
    computation is skipped entirely.

An implementation that only touched `valueFormat` would emit padded, space-separated rows for
`-tty table,csv` and every single row would differ. That is precisely the class of thing a
gate catches and a reading does not, which is why this file exists rather than a note saying
"looks right".

Three more facts, all MEASURED against the jar on a two-column 7-bit fixture, all reproduced:

  -tty table,binary        ->  `000 0000`   FORMAT_TABLE_BIN is `Value.toString()`, which puts
                                            a space every four bits, NOT `toBinaryString()`
  -tty table,csv,binary    ->  `0,000 0000` so a CSV field can contain a space. Safe only
                                            because nothing upstream renders a comma.
  -tty table,csv,tabs      ->  TAB          TABBED is tested first (`:160`)
  -tty table,binary,hex    ->  binary       BIN is tested first (`:190`)

CAN IT FAIL? — MEASURED, WITH TWO INJECTED DEFECTS
--------------------------------------------------
A green gate proves nothing until it has been shown to go red. Both injections were run over
the full default scope (800 oracles, 100 circuits, `--scope root`):

  injection                                              result
  ------------------------------------------------------ ---------------------------------------
  a CLI that writes nothing and exits 0                  0 pass / 8 fail on every case it ran
  a CLI that IGNORES every modifier (always plain table) 297 pass / 503 fail

The second injection is the one worth reading carefully, because it measures **how much of the
corpus can see each modifier at all**:

    table               100 pass /   0 fail   the control — correctly unaffected
    table,csv             0 / 100            every circuit discriminates: the separator is
    table,tabs            0 / 100            visible in any table with ≥2 columns
    table,csv,binary      0 / 100
    table,csv,tabs        0 / 100
    table,hex            49 /  51            needs a pin of width ≥ 2 (at width 1 `toHexString`
                                             returns `toString`, so hex == pretty)
    table,binary         74 /  26            needs a pin of width > 6 (at ≤6 pretty is already
    table,binary,hex     74 /  26            binary; the nibble space only appears above 4 bits)

So **26 of 100 root circuits can detect a broken `binary` and 51 can detect a broken `hex`.**
That is real coverage, not universal coverage, and it is the reason the Swift suite
(`CliTableFormatTests`) pins the value styles on a hand-built 7-bit fixture rather than trusting
the corpus to contain one — and the reason it asserts, explicitly, that a 1-bit fixture *cannot*
discriminate. Run `--scope all` if you want a bigger denominator for the value styles.

IS THE ORACLE REPRODUCIBLE? — asked before any port number was quoted
--------------------------------------------------------------------
`--selfcheck` over the same 856 triples, two jar runs each: **840 stable, 16 unusable
(timeouts), 0 that disagree with themselves.** `tablefmt-nondeterministic.json` is therefore
empty, and that is a measurement rather than an omission — unlike `stats`, this path has no
`generateValidVHDLLabel` randomness in it, so a mismatch here is a port defect and nothing else.

THE CORPUS AND ITS GOLDEN OUTPUTS STAY OUT OF THIS REPO (see .gitignore): they derive from
private coursework, and a golden truth table is effectively a lab solution. The path comes
from LOGISIM_CORPUS.
"""
import argparse
import concurrent.futures as cf
import difflib
import glob
import hashlib
import json
import os
import re
import subprocess
import sys

JAVA = os.environ.get("LOGISIM_JAVA", "/opt/homebrew/opt/openjdk@21/bin/java")
JAR = os.environ.get(
    "LOGISIM_JAR",
    "/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar")
HERE = os.path.dirname(os.path.abspath(__file__))
# tools/difftest/ttybridge -> tools/difftest -> tools -> <repo>. THREE levels; getting this
# wrong pointed statsgate's --cli at a path that does not exist and it reported pass 0 /
# fail 1787: an all-fail reading caused entirely by the harness.
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
_RELEASE_CLI = os.path.join(REPO, "swift", ".build", "release", "logisim-cli")
_DEBUG_CLI = os.path.join(REPO, "swift", ".build", "debug", "logisim-cli")
DEFAULT_CLI = _RELEASE_CLI if os.path.exists(_RELEASE_CLI) else _DEBUG_CLI

# The format combinations gated. Deliberately not the full power set: these are the ones that
# make a distinct DECISION observable, so a regression in any one of the four modifiers, in
# either precedence rule, or in the padding rule, turns at least one of them red.
#
#   table         the control. If this regresses, rig.py is red too and the cause is not here.
#   table,csv     the high-value one: the owner grades CSC258 and a CSV table is diffable
#                 against a solution.
#   table,tabs    the other unpadded separator
#   table,binary  the `Value.toString()` nibble spacing
#   table,hex     hex with no 0x prefix, at every width
#   table,csv,binary  a space inside a CSV field; the combination most likely to be "fixed"
#                     by someone who has not read the jar
#   table,csv,tabs    precedence: tabs wins
#   table,binary,hex  precedence: binary wins
FORMATS = [
    "table",
    "table,csv",
    "table,tabs",
    "table,binary",
    "table,hex",
    "table,csv,binary",
    "table,csv,tabs",
    "table,binary,hex",
]


def corpus_dir():
    d = os.environ.get("LOGISIM_CORPUS")
    if not d or not os.path.isdir(d):
        sys.exit("set LOGISIM_CORPUS to the corpus directory (see docs/objectives.md)")
    return d


def circ_files(corpus, scope="all"):
    """The corpus files, deduplicated — rig.py's list, with a `scope` this gate needs.

    ── Why this gate has a scope and the others do not ───────────────────────────────────────
    Eight format strings per (file, circuit) is **8× the work of the plain-table gate**, and it
    is the same simulation eight times over — only the rendering differs. Measured on this
    machine at `--jobs 8`: the full corpus regenerates at roughly 20 oracles/minute once the
    large harvested files dominate, i.e. **about nine hours** for all ~11k triples. That is not
    a gate anyone will run, and a gate nobody runs is the same as no gate.

    So the scope is named rather than improvised with a `--filter` regex nobody can reproduce:

      root   the 17 CSC258 files in the corpus root — the material this CLI actually grades,
             and the reason `csv` was asked for. 107 circuits, 856 triples, ~15 minutes.
      all    root plus `harvested/`. Correct, and what to run when the renderer changes.

    `root` is the default HERE and nowhere else. rig.py gates the plain table over `all`, so
    the simulation underneath every one of these formats is already covered corpus-wide; what
    `root` leaves unmeasured is the *rendering* of value shapes that occur only in harvested
    files. `--scope all` closes that, and the number it produces should be quoted whenever the
    renderer itself is touched.
    """
    patterns = ["*.circ"]
    if scope == "all":
        patterns += [os.path.join("harvested", "*.circ"), os.path.join("harvested", "*")]
    elif scope != "root":
        sys.exit(f"unknown --scope {scope!r}; expected 'root' or 'all'")
    seen, out = set(), []
    for pattern in patterns:
        for p in glob.glob(os.path.join(corpus, pattern)):
            real = os.path.realpath(p)
            if real in seen or os.path.isdir(p):
                continue
            seen.add(real)
            out.append(p)
    return sorted(out)


def circuits_in(path):
    try:
        src = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return []
    if "<project" not in src:
        return []
    return re.findall(r'<circuit name="([^"]+)"', src)


def golden_name(path, circuit, fmt):
    """rig.py's naming, with the format folded into both the readable part and the digest.

    The digest covers the FULL key including the format, so two formats of one case cannot
    collide, and the collision preflight below is what makes the digest load-bearing rather
    than decorative.
    """
    key = f"{os.path.abspath(path)}__{circuit}__{fmt}"
    slug = fmt.replace(",", "-")
    safe = re.sub(r"[^A-Za-z0-9_.-]", "_", f"{os.path.basename(path)}__{circuit}__{slug}")
    digest = hashlib.sha256(key.encode()).hexdigest()[:8]
    return f"{safe[:160]}__{digest}.tbl"


def run_java(path, circuit, fmt, timeout):
    """One `-tty <fmt>` run of the oracle.

    Returns the text, None on timeout, or "\\0CRASH:<rc>" on a nonzero exit.

    THE EXIT CODE IS CHECKED. rig.py's headline defect was that it was not: the jar can stream
    thousands of valid rows and then die at 255, and a partial capture written as an oracle is
    unfalsifiable afterwards.
    """
    cmd = [JAVA, "-Djava.awt.headless=true", "-jar", JAR,
           "--toplevel-circuit", circuit, "-tty", fmt, os.path.basename(path)]
    try:
        p = subprocess.run(cmd, cwd=os.path.dirname(path), capture_output=True,
                           text=True, timeout=timeout)
        if p.returncode != 0:
            return f"\0CRASH:{p.returncode}"
        return p.stdout
    except subprocess.TimeoutExpired:
        return None


def run_swift(cli, path, circuit, fmt, timeout):
    cmd = [cli, "--toplevel-circuit", circuit, "--tty", fmt, os.path.basename(path)]
    try:
        p = subprocess.run(cmd, cwd=os.path.dirname(path), capture_output=True,
                           text=True, timeout=timeout)
        return p.stdout if p.returncode == 0 else None
    except FileNotFoundError:
        return "\0NOCLI"
    except subprocess.TimeoutExpired:
        return None


def table_shape(text, fmt):
    """Describe a capture: `(rows, columns)`, or None if it is not a usable table.

    This is the assertion that stops empty==empty. It has scored a false pass in this project
    before — an md5 of two EMPTY outputs once marked a case OK — so it is applied to the jar's
    output before anything is written as an oracle, AND to the port's output before anything is
    compared equal to one.

    `columns` is recoverable only for csv and tabs, where the separator is unambiguous; for the
    pretty form it is None. The pretty form pads with spaces AND `binary` renders a value as
    `000 0000`, so a space count says nothing there — rig.py gates the pretty form
    byte-for-byte over the whole corpus anyway. Reporting the count for csv/tabs is what makes
    this a gate on the FORMAT rather than merely on non-emptiness: `compare` below requires the
    port's column count to equal the golden's, so a `table,csv` run that silently fell back to
    space separation is rejected with a message naming the cause instead of producing a
    row-by-row diff whose real cause is one missing separator.

    ── The degenerate class, which is real and is NOT a defect ───────────────────────────────
    A circuit with **no pins at all** yields `headers == []` and `inputCount == 0`, so upstream
    prints one empty header line and one empty data row: exactly `"\\n\\n"`, exit 0. Measured on
    `golden-05.circ::main`; the port produces the identical two bytes. 20 such captures exist
    in the `^lab` slice alone. They carry no information and are not written as oracles — the
    same call rig.py makes when it discards outputs of two lines or fewer.
    """
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines = lines[:-1]
    if len(lines) < 2:
        return None
    if not any(line.strip() for line in lines):
        return None                                     # the pin-less degenerate case
    sep = "\t" if "tabs" in fmt else ("," if "csv" in fmt else None)
    if sep is None:
        return (len(lines), None)
    counts = {line.count(sep) for line in lines}
    if len(counts) != 1:
        return None                                     # ragged: not a table
    return (len(lines), counts.pop() + 1)


def jobs_for(args, corpus):
    """The (file, circuit, format) job list, DEDUPLICATED on (file, circuit).

    `circuits_in` is a regex over the raw XML, so a file declaring the same circuit name twice
    yields the same pair twice — `harvested/2.7.1__case-169.circ` does exactly that.
    Two identical jobs are not a path collision; they are one case listed twice, and there is
    only ever one of it to gate because `file.getCircuit(name)` can return only one circuit.
    Without this the collision preflight aborts the whole regeneration.
    """
    pairs = [(p, c) for p in circ_files(corpus, args.scope) for c in circuits_in(p)]
    pairs = list(dict.fromkeys(pairs))
    pairs = [j for j in pairs if args.pattern.search(f"{os.path.basename(j[0])}::{j[1]}")]
    if getattr(args, "cases_from", None):
        wanted = set()
        for line in open(args.cases_from, encoding="utf-8"):
            line = line.strip()
            if not line or "::" not in line or line.startswith("="):
                continue
            wanted.add(line.rsplit("::", 1)[0] if line.count("::") > 1 else line)
        pairs = [j for j in pairs if f"{os.path.basename(j[0])}::{j[1]}" in wanted]
        print(f"  --cases-from: {len(wanted)} names read, {len(pairs)} matched in the corpus")
    jobs = [(p, c, f) for (p, c) in pairs for f in args.formats]
    if not jobs:
        sys.exit("no (file, circuit, format) triples matched --filter/--cases-from/--formats")
    return jobs


def regenerate(args):
    corpus = corpus_dir()
    os.makedirs(args.golden, exist_ok=True)
    jobs = jobs_for(args, corpus)
    print(f"regenerating table-format golden for {len(jobs)} (file, circuit, format) triples"
          f"\n  formats: {', '.join(args.formats)}")

    # Preflight: no two jobs may claim one path, case-folded because APFS is. rig.py lost an
    # oracle to exactly this and compared it against a different circuit's output for months.
    claimed, clashes = {}, []
    for path, circ, fmt in jobs:
        name = golden_name(path, circ, fmt)
        prior = claimed.get(name.lower())
        if prior is not None:
            clashes.append((prior, (path, circ, fmt), name))
        else:
            claimed[name.lower()] = (path, circ, fmt)
    if clashes:
        for a, b, name in clashes:
            print(f"  COLLISION {name}\n    {a}\n    {b}", file=sys.stderr)
        sys.exit(f"{len(clashes)} golden path collision(s) — refusing to generate.")

    idx_path = os.path.join(args.golden, "_inventory.json")
    old = json.load(open(idx_path)) if os.path.exists(idx_path) else {}
    jobkeys = {(os.path.basename(p), c, f) for p, c, f in jobs}
    index = {n: r for n, r in old.items()
             if (r["file"], r["circuit"], r["format"]) not in jobkeys}
    print(f"  carrying {len(index)} untouched entries through from the existing inventory")

    doomed = {golden_name(p, c, f) for p, c, f in jobs}
    doomed |= {r["golden"] for r in old.values()
               if (r["file"], r["circuit"], r["format"]) in jobkeys}
    for name in doomed:
        try:
            os.unlink(os.path.join(args.golden, name))
        except FileNotFoundError:
            pass

    def one(job):
        path, circ, fmt = job
        out = run_java(path, circ, fmt, args.timeout)
        if out is None:
            return job, "timeout", None
        if out.startswith("\0CRASH:"):
            return job, f"jar-exit-{out.split(':')[1]}", None
        if not out:
            # Real: `inputCount & 31 == 31` makes Java's rowCount negative and the loop runs
            # zero times, so the jar prints nothing at all and exits 0. Recorded as its own
            # status so "the jar printed nothing" can never land in the golden set as agreement.
            return job, "empty", None
        shape = table_shape(out, fmt)
        if shape is None:
            # `degenerate` is the pin-less `"\n\n"` case and is expected; a ragged capture is
            # not. They are one status here because neither may be written, but the docstring on
            # `table_shape` records the difference so the count is not read as damage.
            return job, "degenerate", None
        name = golden_name(path, circ, fmt)
        try:
            fd = os.open(os.path.join(args.golden, name),
                         os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        except FileExistsError:
            return job, "collision", None
        with os.fdopen(fd, "w") as f:
            f.write(out)
        return job, "OK", {"file": os.path.basename(path), "circuit": circ, "format": fmt,
                           "golden": name, "lines": out.count("\n"),
                           "columns": shape[1],
                           "sha256": hashlib.sha256(out.encode()).hexdigest()}

    counts = {}
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for job, status, rec in ex.map(one, jobs):
            counts[status] = counts.get(status, 0) + 1
            if rec:
                index[rec["golden"]] = rec
    with open(idx_path, "w") as f:
        json.dump(index, f, indent=1)
    print(f"  {counts}")
    print(f"  {len(index)} golden oracles -> {args.golden}")
    # `degenerate` is expected and is not a failure (see `table_shape`); a path collision is.
    return 1 if counts.get("collision") else 0


def selfcheck(args):
    """Run the jar TWICE per case and report every case that disagrees with itself.

    A case listed here can never be passed by any port, so it must be known BEFORE a port
    number is quoted. rig.py learned this the expensive way: 44 of its cases vary run to run
    and its headline number moved by 22 with no code change.
    """
    corpus = corpus_dir()
    jobs = jobs_for(args, corpus)
    print(f"self-check: running the JAR twice on {len(jobs)} triples\n")

    def one(job):
        path, circ, fmt = job
        a = run_java(path, circ, fmt, args.timeout)
        b = run_java(path, circ, fmt, args.timeout)
        if a is None or b is None or str(a).startswith("\0") or str(b).startswith("\0"):
            return job, "unusable", None
        if a != b:
            d = list(difflib.unified_diff(a.splitlines(), b.splitlines(),
                                          "run1", "run2", lineterm="", n=0))
            return job, "DIFFERS", "\n".join(d[:8])
        return job, "stable", None

    tally, unstable = {}, []
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for job, status, detail in ex.map(one, jobs):
            tally[status] = tally.get(status, 0) + 1
            if status == "DIFFERS":
                unstable.append((job, detail))
                if len(unstable) <= args.max_fail:
                    print(f"  DIFFERS {os.path.basename(job[0])}::{job[1]}::{job[2]}")
                    for line in (detail or "").splitlines():
                        print(f"          {line}")
    print(f"\n{'=' * 56}\n  {tally}")
    if args.write_nondet:
        with open(args.write_nondet, "w") as f:
            json.dump({
                "source": "tablefmtgate.py --selfcheck, 2 runs of the 4.1.0 jar per triple",
                "cases": {f"{os.path.basename(p)}::{c}::{f}": "label"
                          for (p, c, f), _ in unstable},
            }, f, indent=1)
        print(f"  wrote {len(unstable)} excluded case(s) -> {args.write_nondet}")
    if unstable:
        print(f"  {len(unstable)} case(s) where the 4.1.0 jar does not reproduce ITSELF. "
              "No port can pass these.")
        return 1
    print("  the oracle reproduces itself on every case, so a port mismatch is a port defect "
          "and nothing else.")
    return 0


def compare(args):
    corpus = corpus_dir()
    idx_path = os.path.join(args.golden, "_inventory.json")
    if not os.path.exists(idx_path):
        sys.exit(f"no golden inventory at {idx_path} — run with --regenerate first")
    index = json.load(open(idx_path))

    by_name = {}
    for p in circ_files(corpus, args.scope):
        by_name.setdefault(os.path.basename(p), p)

    cases = [r for r in index.values()
             if args.pattern.search(f"{r['file']}::{r['circuit']}")
             and r["format"] in args.formats]
    if not cases:
        sys.exit("no cases matched --filter/--formats")

    # PREFLIGHT, rig.py's three checks: name collisions, files named but absent, content drift.
    collisions = {}
    for name in index:
        collisions.setdefault(name.lower(), []).append(name)
    clashing = {k: v for k, v in collisions.items() if len(v) > 1}
    present = {f for f in os.listdir(args.golden) if f.endswith(".tbl")}
    missing = [r["golden"] for r in index.values() if r["golden"] not in present]
    stale = []
    for r in index.values():
        if r["golden"] not in present or "sha256" not in r:
            continue
        with open(os.path.join(args.golden, r["golden"]), "rb") as fh:
            if hashlib.sha256(fh.read()).hexdigest() != r["sha256"]:
                stale.append(r["golden"])

    unsound = set(missing) | set(stale)
    for names in clashing.values():
        unsound.update(names)
    if unsound:
        print(f"  EXCLUDING {len(unsound)} unsound baseline(s):")
        for names in clashing.values():
            print(f"    case collision, one file on APFS: {names}")
        for m in sorted(missing)[:5]:
            print(f"    named in the index, absent on disk: {m}")
        for s in sorted(stale)[:5]:
            print(f"    on-disk bytes do not match the captured sha256: {s}")
        cases = [r for r in cases if r["golden"] not in unsound]

    # A MISSING BINARY IS NOT N PORT DEFECTS. Checked before any case runs.
    if not os.path.exists(args.cli):
        sys.exit(f"logisim-cli not built at {args.cli}\n"
                 "  build it with: swift build -c release --product logisim-cli\n"
                 "  (refusing to report a number: every case would 'fail' for this one reason)")

    print(f"{len(cases)} cases  ·  cli={args.cli}\n")

    def one(rec):
        path = by_name.get(rec["file"])
        if not path:
            return rec, "MISSING", "corpus file not found"
        got = run_swift(args.cli, path, rec["circuit"], rec["format"], args.timeout)
        if got == "\0NOCLI":
            return rec, "NO-CLI", f"not built: {args.cli}"
        if got is None:
            return rec, "FAIL", "cli exited nonzero or timed out"
        want = open(os.path.join(args.golden, rec["golden"])).read()
        # THE ASSERTION THAT STOPS EMPTY==EMPTY, applied to the PORT's output too. The golden
        # set cannot contain an unshaped capture (regenerate refuses to write one), but the
        # port's output is unconstrained until this line.
        shape = table_shape(got, rec["format"])
        if shape is None:
            return rec, "FAIL", "cli output is not a usable table (empty, blank or ragged)"
        # And the column count must equal the golden's. This is what names the specific defect
        # of emitting a plain table for `table,csv`, one column instead of N, rather than
        # reporting every row as different and leaving the cause to be guessed.
        if rec.get("columns") is not None and shape[1] != rec["columns"]:
            return rec, "FAIL", (
                f"separator not applied: golden has {rec['columns']} columns for "
                f"'{rec['format']}', cli produced {shape[1]}")
        if got == want:
            return rec, "PASS", ""
        d = list(difflib.unified_diff(want.splitlines(), got.splitlines(),
                                      "java", "swift", lineterm="", n=0))
        return rec, "FAIL", "\n".join(d[:8])

    # The MEASURED nondeterminism bucket, written by `--selfcheck --write-nondet`. Loaded, not
    # assumed: rig.py's exclusion file sat unread and its headline number moved by 22 on its
    # own. The count is printed whether it is zero or not, so a silently unread file shows up
    # as `0 excluded` rather than as nothing at all.
    nondet_path = args.nondet or os.path.join(HERE, "tablefmt-nondeterministic.json")
    nondet = {}
    if os.path.exists(nondet_path):
        nondet = json.load(open(nondet_path)).get("cases", {})
    else:
        print(f"  NOTE: no exclusion list at {nondet_path}; run --selfcheck --write-nondet")

    per_format = {f: [0, 0] for f in args.formats}   # [pass, fail]
    passed = failed = unreproducible = 0
    shown = 0
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for rec, status, detail in ex.map(one, cases):
            key = f"{rec['file']}::{rec['circuit']}::{rec['format']}"
            if status == "PASS":
                passed += 1
                per_format[rec["format"]][0] += 1
                continue
            if key in nondet or f"{rec['file']}::{rec['circuit']}" in nondet:
                unreproducible += 1
                continue
            failed += 1
            per_format[rec["format"]][1] += 1
            if args.list_failures:
                print(key)
                continue
            if shown < args.max_fail:
                shown += 1
                print(f"  {status:<7} {key}")
                if detail and args.show_diff:
                    for line in detail.splitlines():
                        print(f"          {line}")
    if failed > shown and not args.list_failures:
        print(f"  ... and {failed - shown} more failures (raise --max-fail to see them)")
    print(f"\n{'=' * 56}")
    # PER FORMAT, not just in total. A total alone would let three modifiers carry a fourth
    # that is entirely broken, which is exactly how an unimplemented format hides.
    for fmt in args.formats:
        ok, bad = per_format[fmt]
        print(f"  {fmt:<18} pass {ok:>5}  ·  fail {bad}")
    print(f"  {'TOTAL':<18} pass {passed:>5}  ·  fail {failed}  ·  of "
          f"{len(cases) - unreproducible}")
    print(f"  {unreproducible} case(s) excluded: the 4.1.0 jar does not reproduce them against"
          f"\n  itself (measured — see {os.path.basename(nondet_path)}).")
    # A format with zero passes AND zero failures contributed nothing and must not read as
    # agreement; that is the same shape as rig.py's structurally dead simulation mode.
    inert = [f for f in args.formats if per_format[f] == [0, 0]]
    if inert:
        print(f"  {len(inert)} format(s) contributed NO cases at all: {', '.join(inert)}."
              "\n  That is not a pass; regenerate the golden set for them.")
        return 1
    return 0 if failed == 0 else 1


# ── The two divergences, measured rather than asserted ──────────────────────────────────────
#
# Both are recorded in `logisim-cli/main.swift`'s exit-code contract. They are re-measurable
# here so that a claim about upstream cannot quietly stop being true, which is the same reason
# `CliExitCodeTests.theJarAgrees` asserts upstream's exit 0 on a misspelled format.
DIVERGENCE_FIXTURE = """<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<project source="4.1.0" version="1.0">
  <lib desc="#Wiring" name="0"/>
  <lib desc="#Gates" name="1"/>
  <lib desc="#Risc-V" name="99"/>
  <main name="main"/>
  <options/>
  <mappings/>
  <toolbar/>
  <circuit name="main">
    <a name="circuit" val="main"/>
    <comp lib="0" loc="(100,110)" name="Pin"><a name="label" val="a"/></comp>
    <comp lib="0" loc="(100,130)" name="Pin"><a name="label" val="b"/></comp>
    <comp lib="0" loc="(260,120)" name="Pin">
      <a name="label" val="q"/><a name="type" val="output"/>
    </comp>
    <comp lib="1" loc="(220,120)" name="AND Gate"><a name="size" val="30"/></comp>
    <wire from="(100,110)" to="(190,110)"/>
    <wire from="(100,130)" to="(190,130)"/>
    <wire from="(220,120)" to="(260,120)"/>
  </circuit>
</project>
"""


def probe_divergences(args):
    """Re-measure the two upstream behaviours this port deliberately does NOT reproduce."""
    import tempfile
    rc = 0
    with tempfile.TemporaryDirectory() as d:
        circ = os.path.join(d, "probe.circ")
        with open(circ, "w") as f:
            f.write(DIVERGENCE_FIXTURE)

        print("── 1. a bare modifier, with no `table` ─────────────────────────────────────")
        print("   upstream: no FORMAT_TABLE bit, so `format == 0` does not fire and control")
        print("   reaches runSimulation, whose while(true) has no exit without a `halt` pin.")
        for fmt in ("csv", "tabs", "binary", "hex"):
            cmd = [JAVA, "-Djava.awt.headless=true", "-jar", JAR, "-tty", fmt, "probe.circ"]
            try:
                p = subprocess.run(cmd, cwd=d, capture_output=True, text=True,
                                   timeout=args.hang_timeout)
                print(f"   jar  -tty {fmt:<7} TERMINATED rc={p.returncode} "
                      f"stdout={len(p.stdout)}B  <- upstream may have been fixed; revisit")
                rc = 1
            except subprocess.TimeoutExpired:
                print(f"   jar  -tty {fmt:<7} still running at {args.hang_timeout}s, "
                      f"no output — hang confirmed")
            if os.path.exists(args.cli):
                p = subprocess.run([args.cli, "--tty", fmt, "probe.circ"], cwd=d,
                                   capture_output=True, text=True, timeout=60)
                ok = p.returncode == 2 and not p.stdout and p.stderr
                print(f"   port --tty {fmt:<7} rc={p.returncode} "
                      f"{'OK' if ok else 'UNEXPECTED — want rc=2, empty stdout, a message'}")
                if not ok:
                    rc = 1

        print("\n── 2. a library the build cannot resolve ───────────────────────────────────")
        print("   upstream: Loader.showError wraps any message over 60 chars in a JScrollPane,")
        print("   and OptionPane's headless arm only logs Strings, so the message is dropped.")
        print("   `The built-in library “Risc-V” is not available in this version.` is 63.")
        p = subprocess.run(
            [JAVA, "-Djava.awt.headless=true", "-jar", JAR, "-tty", "table", "probe.circ"],
            cwd=d, capture_output=True, text=True, timeout=args.timeout)
        said = "Risc-V" in (p.stderr + p.stdout)
        print(f"   jar  rc={p.returncode}  mentions the library: {said}"
              f"{'  <- upstream may have been fixed; revisit' if said else ''}")
        if said:
            rc = 1
        if os.path.exists(args.cli):
            p = subprocess.run([args.cli, "--tty", "table", "probe.circ"], cwd=d,
                               capture_output=True, text=True, timeout=60)
            ok = p.returncode == 0 and "Risc-V" in p.stderr and p.stdout
            print(f"   port rc={p.returncode}  mentions the library: "
                  f"{'Risc-V' in p.stderr}  table still printed: {bool(p.stdout)}"
                  f"  {'OK' if ok else 'UNEXPECTED'}")
            if not ok:
                rc = 1
    return rc


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--regenerate", action="store_true")
    ap.add_argument("--selfcheck", action="store_true",
                    help="run the JAR twice per case; report cases it cannot reproduce")
    ap.add_argument("--probe-divergences", action="store_true",
                    help="re-measure the two upstream behaviours the port declines to copy")
    ap.add_argument("--nondet", default=None)
    ap.add_argument("--write-nondet", default=None)
    # Defaulted AFTER parsing, per scope: the two scopes get two directories so a `root`
    # comparison can never be run against an `all` inventory. Sharing one directory would make
    # every harvested entry look like a MISSING corpus file, which is a harness fault wearing a
    # port fault's clothes; the shape this file's REPO comment already records once.
    ap.add_argument("--golden", default=None)
    ap.add_argument("--cli", default=DEFAULT_CLI)
    ap.add_argument("--scope", default="root", choices=("root", "all"),
                    help="'root' (default): the 17 CSC258 corpus-root files, ~15 min. "
                         "'all': plus harvested/, ~9 hours. See circ_files() for why this gate "
                         "has a scope and the others do not.")
    ap.add_argument("--filter", default=".", help="regex over 'file::circuit'")
    ap.add_argument("--formats", default=",".join(FORMATS),
                    help="comma-separated -tty format strings to gate; use ';' between them "
                         "since each may itself contain commas")
    ap.add_argument("--cases-from", default=None)
    ap.add_argument("--jobs", type=int, default=6)
    # 120, not 60. `golden-16.circ::FSM` has 19 input bits, 524,288 rows, and the port takes
    # 59.5 s on this machine, so at 60 s it timed out in ALL EIGHT formats and the gate reported
    # `pass 99 / fail 1` per format for a reason that had nothing to do with the port's output.
    # A timeout that lands next to the true runtime is a gate that reports port defects it has
    # not observed.
    ap.add_argument("--timeout", type=int, default=120)
    ap.add_argument("--hang-timeout", type=int, default=20,
                    help="--probe-divergences: how long to wait before calling it a hang")
    ap.add_argument("--max-fail", type=int, default=15, help="0 means unlimited")
    ap.add_argument("--list-failures", action="store_true")
    ap.add_argument("--show-diff", action="store_true", default=True)
    args = ap.parse_args()
    if args.golden is None:
        suffix = "" if args.scope == "root" else f"-{args.scope}"
        args.golden = os.path.join(
            os.environ.get("LOGISIM_CORPUS", "."), f"golden-tablefmt{suffix}")
    if args.max_fail == 0:
        args.max_fail = 1 << 30
    args.pattern = re.compile(args.filter)
    # A format string contains commas, so the LIST of them is `;`-separated. Splitting on ","
    # here would turn `table,csv` into two bogus formats and every case would fail for a
    # harness reason: the exact shape this file's REPO comment warns about.
    args.formats = [f.strip() for f in args.formats.split(";") if f.strip()] \
        if ";" in args.formats else (FORMATS if args.formats == ",".join(FORMATS)
                                     else [args.formats.strip()])
    if args.probe_divergences:
        return probe_divergences(args)
    if args.regenerate:
        return regenerate(args)
    if args.selfcheck:
        return selfcheck(args)
    return compare(args)


if __name__ == "__main__":
    sys.exit(main())
