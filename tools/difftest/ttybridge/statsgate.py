#!/usr/bin/env python3
"""Differential gate for `logisim-cli --tty stats`, against the 4.1.0 jar.

Same shape as tools/difftest/rig.py's simulation gate, and deliberately so — it is a second
format over the same corpus, so it inherits the same soundness assertions rather than
re-deriving weaker ones:

    # build the golden set from the jar (slow; run when the corpus changes)
    LOGISIM_CORPUS=/path/to/corpus python3 statsgate.py --regenerate

    # gate: diff the Swift CLI against golden
    LOGISIM_CORPUS=/path/to/corpus python3 statsgate.py

    # is the ORACLE itself reproducible? runs the jar twice per case and diffs it with itself
    LOGISIM_CORPUS=/path/to/corpus python3 statsgate.py --selfcheck

Exit 0 only if every selected case matches. Anything else is a red gate.

WHY `--selfcheck` EXISTS, AND WHY IT IS NOT OPTIONAL HERE
--------------------------------------------------------
`FileStatistics.compute` builds `include` as `new HashSet<>(file.getCircuits())` and iterates
it. The printed ORDER is safe (that comes from `sortCounts`, over ordered tool lists), but the
`unique` column is not obviously safe: merging one subcircuit's counts can create a zero-count
entry for another subcircuit's factory in the parent map, which decides whether that second
subcircuit is recursed into at all — and `doUniqueCounts` sums over exactly the set of circuits
that were recursed into.

rig.py already learned this lesson the expensive way: 44 of its cases vary run-to-run, the
headline number moved by 22 with no code change, and that was only found by running the jar
against itself. So the same question gets asked here BEFORE any port number is quoted, rather
than after a mysterious 3-case drift.

A CASE THAT IS ABSENT IS NOT A CASE THAT PASSES
-----------------------------------------------
`-Djava.awt.headless=true` made the jar exit 255 on every file that PLACES a SoC component, so
those cases were bucketed `jar-exit-255`, no golden was written, and they left the gated set
entirely. `pass N / fail 0` then described a set with no SoC component in it, which is how the
SoC display-name defect shipped past a green gate. Two mechanisms now stop that shape:

  * `needs_display` runs exactly those files with `-Djava.awt.headless=false` (see the long note
    beside it for the measurement, and for why "just drop the flag" was rejected), and a
    display-needing case that still fails makes `--regenerate` exit nonzero;
  * every dropped case is written to `<golden>/_dropped.json` with its bucket and reason, and
    `compare` prints corpus COVERAGE on every run, so the denominator is never invisible again.

THE CORPUS AND ITS GOLDEN OUTPUTS STAY OUT OF THIS REPO (see .gitignore): they derive from
private coursework. The path comes from LOGISIM_CORPUS.
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
# tools/difftest/ttybridge -> tools/difftest -> tools -> <repo>. THREE levels; rig.py needs two
# because it sits one directory shallower. Getting this wrong pointed --cli at
# `<repo>/tools/swift/.build/...`, which does not exist, and the gate reported **pass 0 / fail
# 1787**; an all-fail reading caused entirely by the harness. That is the thirteenth instance of
# this shape in this project, so `compare` now ABORTS on a missing binary instead of scoring it.
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
# PREFER RELEASE, for the reason rig.py records: a debug sweep does not finish.
_RELEASE_CLI = os.path.join(REPO, "swift", ".build", "release", "logisim-cli")
_DEBUG_CLI = os.path.join(REPO, "swift", ".build", "debug", "logisim-cli")
DEFAULT_CLI = _RELEASE_CLI if os.path.exists(_RELEASE_CLI) else _DEBUG_CLI

# `displayStatistics` always ends with these two rows, from gui.properties. The apostrophe is
# U+2019, not U+0027: matching on the ASCII one silently accepts nothing.
TOTAL_WITHOUT = "TOTAL (without project’s sub circuits)"
TOTAL_WITH = "TOTAL (with sub circuits)"


def corpus_dir():
    d = os.environ.get("LOGISIM_CORPUS")
    if not d or not os.path.isdir(d):
        sys.exit("set LOGISIM_CORPUS to the corpus directory (see docs/objectives.md)")
    return d


def circ_files(corpus):
    """All .circ in the corpus root and in harvested/, deduplicated — rig.py's list."""
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


def circuits_in(path):
    try:
        src = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return []
    if "<project" not in src:
        return []
    return re.findall(r'<circuit name="([^"]+)"', src)


# ── WHY ONE FAMILY OF FILES IS RUN WITHOUT `-Djava.awt.headless=true` ───────────────────────────
#
# `SocBusStateInfo.<init>` (SocBusStateInfo.java:189 in 4.1.0) builds a raw `JDialog` in its
# CONSTRUCTOR. It is reached from `SocSimulationManager.registerComponent` <- `Circuit.mutatorAdd`
# <- `XmlCircuitReader.buildCircuit`, i.e. while the .circ is being PARSED, long before anything
# asks whether there is a GUI. D17 (`Main.headless = true`) does not help: nothing on that path is
# gated by `Main.hasGui()`. So under `-Djava.awt.headless=true` the jar throws HeadlessException
# and exits 255 on any file that PLACES a SoC component.
#
# Measured, on `harvested/3.7.2__case-186.circ::main`, the exact command
# built below:
#     -Djava.awt.headless=true   -> exit 255, 0 bytes of stdout, java.awt.HeadlessException
#     -Djava.awt.headless=false  -> exit 0, 15 lines, byte-identical to the port's output
# That file is the ONLY one in the corpus that places a SoC component, and it declares two
# circuits, so the flag alone was costing exactly 2 cases: bucketed `jar-exit-255`, no golden
# written, and (until the accounting below) no trace afterwards that they had ever existed.
#
# WHY TARGETED AND NOT "JUST DROP THE FLAG":
#   * Dropping it globally would re-derive all 2097 oracle runs inside a real GraphicsEnvironment.
#     Whether `stats` bytes change is beside the point; the bytes would then DEPEND ON WHETHER
#     THE CAPTURING BOX HAD A DISPLAY, which is the exact class of hidden nondeterminism the
#     `--selfcheck` machinery above exists to eliminate. Targeting keeps 2095 of 2097 runs on the
#     identical command line they have always used.
#   * It buys nothing on a headless CI box, which is a real deployment target here. With no
#     display the JVM sets `java.awt.headless=true` ITSELF, so the SoC file throws the same
#     HeadlessException with or without the flag. The blunt fix is not a headless fix; it is a
#     "works on the author's laptop" fix that also degrades every other case.
#   * On macOS a non-headless JVM attaches to the window server (NSApplication/dock), per process,
#     across 2097 JVMs.
# The honest cost of TARGETING is that these two oracles CANNOT be minted on a headless box. That
# is a property of the jar, not of this script, so it is made LOUD rather than papered over:
# `regenerate` fails when a display-needing case is dropped, and `compare` prints corpus coverage
# on every run.
_needs_display_cache = {}


def needs_display(path):
    """True if `path` PLACES a component from a `#Soc` library.

    Declaring `<lib desc="#Soc">` is not enough — Logisim writes the full library table into
    almost every file, so 354 of the corpus files declare it and only ONE instantiates anything
    from it. Matching on the declaration would have quietly moved the whole corpus off the
    headless command line, i.e. the blunt fix wearing a targeted fix's clothes.
    """
    hit = _needs_display_cache.get(path)
    if hit is not None:
        return hit
    try:
        src = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        _needs_display_cache[path] = False
        return False
    soc_libs = set()
    for m in re.finditer(r"<lib\b[^>]*>", src):
        tag = m.group(0)
        desc = re.search(r'desc="([^"]*)"', tag)
        name = re.search(r'name="([^"]*)"', tag)
        if desc and name and desc.group(1) == "#Soc":
            soc_libs.add(name.group(1))
    placed = False
    if soc_libs:
        for m in re.finditer(r"<comp\b[^>]*>", src):
            lib = re.search(r'lib="([^"]*)"', m.group(0))
            if lib and lib.group(1) in soc_libs:
                placed = True
                break
    _needs_display_cache[path] = placed
    return placed


def golden_name(path, circuit):
    """rig.py's naming, with a .stats suffix. The sha256 of the FULL key keeps truncated
    names distinct, and the collision preflight below is what makes the digest load-bearing."""
    key = f"{os.path.abspath(path)}__{circuit}"
    safe = re.sub(r"[^A-Za-z0-9_.-]", "_", f"{os.path.basename(path)}__{circuit}")
    digest = hashlib.sha256(key.encode()).hexdigest()[:8]
    return f"{safe[:160]}__{digest}.stats"


def run_java(path, circuit, timeout):
    """One `-tty stats` run of the oracle.

    Returns the text, None on timeout, or "\\0CRASH:<rc>:<first stderr Exception line>" on a
    nonzero exit. The reason is carried out with the exit code because `jar-exit-255` on its own
    is what let an entire component family leave the corpus unremarked: two very different
    failures (a Java-side crash in the design, and this harness handing the jar a flag it cannot
    survive) were indistinguishable in the tally.

    THE EXIT CODE IS CHECKED. rig.py's headline defect was that it was not: the jar can stream
    thousands of valid lines and then die at 255, and a partial capture written as an oracle is
    unfalsifiable afterwards. `stats` output is short enough that a partial capture is less
    likely and no less poisonous.

    `headless` is per-FILE, not global — see `needs_display` above for the measurement and for
    why the blunt "drop the flag everywhere" variant was rejected.
    """
    headless = "false" if needs_display(path) else "true"
    cmd = [JAVA, f"-Djava.awt.headless={headless}", "-jar", JAR,
           "--toplevel-circuit", circuit, "-tty", "stats", os.path.basename(path)]
    try:
        p = subprocess.run(cmd, cwd=os.path.dirname(path), capture_output=True,
                           text=True, timeout=timeout)
        if p.returncode != 0:
            err = (p.stderr or "").splitlines()
            # The exception TYPE alone is not a diagnosis. `java.awt.HeadlessException` covers two
            # completely different situations in this corpus: a SoC component being registered
            # during parsing (fixable: give it a display) and `Loader.getFileFor` popping a
            # JFileChooser for a library file that is not in the corpus (NOT fixable: with a
            # display it becomes a 30s+ modal hang instead of a 3s exit). The first `com.cburch`
            # frame is what separates them, so it is carried into the ledger.
            top = next((l.strip() for l in err if "Exception" in l or "Error" in l), "")
            frame = next((l.strip() for l in err if "at com.cburch" in l), "")
            reason = f"{top} @ {frame}" if frame else top
            return f"\0CRASH:{p.returncode}:{reason}"
        return p.stdout
    except subprocess.TimeoutExpired:
        return None


def run_swift(cli, path, circuit, timeout):
    cmd = [cli, "--toplevel-circuit", circuit, "--tty", "stats", os.path.basename(path)]
    try:
        p = subprocess.run(cmd, cwd=os.path.dirname(path), capture_output=True,
                           text=True, timeout=timeout)
        return p.stdout if p.returncode == 0 else None
    except FileNotFoundError:
        return "\0NOCLI"
    except subprocess.TimeoutExpired:
        return None


def is_stats_shaped(text):
    """`displayStatistics` emits N component rows and then EXACTLY two total rows.

    This is the assertion rig.py had to learn to add, applied up front rather than after a
    corrupt baseline is found. It is also the answer to the trap this project has hit twice —
    "an entry point that writes nothing and exits 0 looks exactly like agreement". A stats run
    that produced no output cannot satisfy this, so it can never be written as an oracle and can
    never be compared equal to an equally empty port run.
    """
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines = lines[:-1]
    if len(lines) < 2:
        return False
    return (lines[-2].endswith(TOTAL_WITHOUT) and lines[-1].endswith(TOTAL_WITH))


def jobs_for(args, corpus):
    """The (file, circuit) job list, DEDUPLICATED.

    `circuits_in` is a regex over the raw XML, so a file that declares the same circuit name
    twice yields the same job twice — and `harvested/2.7.1__case-169.circ` does
    exactly that, with `<circuit name="decoder">` at lines 548 and 1179. Two identical jobs are
    not a path collision; they are one case listed twice, and there is only ever one of it to
    gate because `file.getCircuit("decoder")` can return only one circuit.

    Without this, the collision preflight below fires on that pair and the whole regeneration
    aborts before a single JVM starts. rig.py builds its job list the same way and has the same
    preflight, so `rig.py --regenerate` over the full corpus aborts today for the same reason —
    see the report; the fix there is this same `dict.fromkeys`.
    """
    jobs = [(p, c) for p in circ_files(corpus) for c in circuits_in(p)]
    jobs = list(dict.fromkeys(jobs))
    jobs = [j for j in jobs if args.pattern.search(f"{os.path.basename(j[0])}::{j[1]}")]
    if getattr(args, "cases_from", None):
        # `--cases-from` takes `--list-failures` output verbatim, so `--selfcheck` can be pointed
        # at exactly the cases that failed. A regex `--filter` cannot do this: harvested names
        # contain `.`, `+`, spaces and CJK, so building one from a failure list is its own bug.
        wanted = set()
        for line in open(args.cases_from, encoding="utf-8"):
            line = line.strip()
            if not line or "::" not in line or line.startswith("="):
                continue
            wanted.add(line)
        jobs = [j for j in jobs if f"{os.path.basename(j[0])}::{j[1]}" in wanted]
        print(f"  --cases-from: {len(wanted)} names read, {len(jobs)} matched in the corpus")
    if not jobs:
        sys.exit("no (file, circuit) pairs matched --filter/--cases-from")
    return jobs


def regenerate(args):
    corpus = corpus_dir()
    os.makedirs(args.golden, exist_ok=True)
    jobs = jobs_for(args, corpus)
    print(f"regenerating stats golden for {len(jobs)} (file, circuit) pairs")

    # Preflight: no two jobs may claim one path, case-folded because APFS is. rig.py lost an
    # oracle to exactly this and compared it against a different circuit's output for months.
    claimed, clashes = {}, []
    for path, circ in jobs:
        name = golden_name(path, circ)
        prior = claimed.get(name.lower())
        if prior is not None:
            clashes.append((prior, (path, circ), name))
        else:
            claimed[name.lower()] = (path, circ)
    if clashes:
        for (p1, c1), (p2, c2), name in clashes:
            print(f"  COLLISION {name}\n    {p1}::{c1}\n    {p2}::{c2}", file=sys.stderr)
        sys.exit(f"{len(clashes)} golden path collision(s) — refusing to generate.")

    idx_path = os.path.join(args.golden, "_inventory.json")
    old = json.load(open(idx_path)) if os.path.exists(idx_path) else {}
    jobkeys = {(os.path.basename(p), c) for p, c in jobs}
    index = {n: r for n, r in old.items() if (r["file"], r["circuit"]) not in jobkeys}
    print(f"  carrying {len(index)} untouched entries through from the existing inventory")

    doomed = {golden_name(p, c) for p, c in jobs}
    doomed |= {r["golden"] for r in old.values() if (r["file"], r["circuit"]) in jobkeys}
    for name in doomed:
        try:
            os.unlink(os.path.join(args.golden, name))
        except FileNotFoundError:
            pass

    def one(job):
        path, circ = job
        out = run_java(path, circ, args.timeout)
        if out is None:
            return job, "timeout", None, f"no output within {args.timeout}s"
        if out.startswith("\0CRASH:"):
            _, rc, reason = out.split(":", 2)
            return job, f"jar-exit-{rc}", None, reason
        if not out:
            # Cannot happen for a healthy run; recorded separately so "the jar printed nothing"
            # never lands in the golden set as agreement.
            return job, "empty", None, "jar exited 0 and printed nothing"
        if not is_stats_shaped(out):
            print(f"  MALFORMED {os.path.basename(path)}::{circ}: does not end in the two TOTAL "
                  "rows; not written", file=sys.stderr)
            return job, "malformed", None, "does not end in the two TOTAL rows"
        name = golden_name(path, circ)
        try:
            fd = os.open(os.path.join(args.golden, name),
                         os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        except FileExistsError:
            return job, "collision", None, f"golden path already claimed: {name}"
        with os.fdopen(fd, "w") as f:
            f.write(out)
        return job, "OK", {"file": os.path.basename(path), "circuit": circ,
                           "golden": name, "lines": out.count("\n"),
                           "sha256": hashlib.sha256(out.encode()).hexdigest()}, ""

    counts = {}
    dropped = []
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for job, status, rec, reason in ex.map(one, jobs):
            counts[status] = counts.get(status, 0) + 1
            if rec:
                index[rec["golden"]] = rec
            else:
                dropped.append({"file": os.path.basename(job[0]), "circuit": job[1],
                                "bucket": status, "reason": reason,
                                "needs_display": needs_display(job[0])})
    with open(idx_path, "w") as f:
        json.dump(index, f, indent=1)

    # ── THE DROP LEDGER ────────────────────────────────────────────────────────────────────────
    #
    # A case that produces no golden used to leave NO TRACE beyond a `+1` in a bucket counter that
    # scrolled past once. That is how `-Djava.awt.headless=true` removed the entire SoC component
    # family from this gate: 2 cases went to `jar-exit-255`, no golden was written, and every
    # subsequent run reported `pass N / fail 0` over a set those cases were simply not in. An
    # absent case cannot fail, so it reads as success forever.
    #
    # Merging, not overwriting: a scoped `--regenerate --filter X` must not erase what a previous
    # full sweep recorded about the cases it did not touch; otherwise the ledger itself acquires
    # the disappearing-evidence property it exists to prevent.
    drop_path = os.path.join(args.golden, "_dropped.json")
    prior = json.load(open(drop_path)).get("cases", []) if os.path.exists(drop_path) else []
    touched = {(os.path.basename(p), c) for p, c in jobs}
    ledger = [d for d in prior if (d["file"], d["circuit"]) not in touched] + dropped
    ledger.sort(key=lambda d: (d["file"], d["circuit"]))
    with open(drop_path, "w") as f:
        json.dump({"source": "statsgate.py --regenerate", "cases": ledger}, f, indent=1)

    print(f"  {counts}")
    print(f"  {len(index)} golden oracles -> {args.golden}")
    print(f"  {len(dropped)} of {len(jobs)} selected case(s) produced NO golden "
          f"({len(ledger)} total on record -> {os.path.basename(drop_path)})")

    # A display-needing case that still failed means the oracle was minted on a box that could not
    # run it: a headless CI box, most likely. That is a real limitation of the 4.1.0 jar (the
    # JDialog is built during PARSING), not something this script can route around, so it is
    # reported as a hard failure instead of being absorbed into a bucket count. This is also the
    # regression guard: if `needs_display` ever stops recognising a SoC file, these cases go back
    # to `jar-exit-255` and `--regenerate` goes RED rather than silently shrinking the set.
    display_drops = [d for d in dropped if d["needs_display"]]
    if display_drops:
        print("\n  NEEDS A DISPLAY, AND DID NOT GET ONE — these cases place a SoC component, and "
              "4.1.0\n  builds a JDialog while PARSING such a file (SocBusStateInfo.<init>). They "
              "cannot be\n  captured on a headless box; regenerate them where a window server "
              "exists:", file=sys.stderr)
        for d in display_drops:
            print(f"    {d['file']}::{d['circuit']}  [{d['bucket']}] {d['reason']}",
                  file=sys.stderr)

    rejected = sum(v for k, v in counts.items() if k in ("collision", "malformed", "empty"))
    return 1 if (rejected or display_drops) else 0


def selfcheck(args):
    """Run the jar TWICE per case and report every case that disagrees with itself.

    A case listed here can never be passed by any port, so it must be known before a port
    number is quoted. See the module docstring for why `unique` is the column at risk.
    """
    corpus = corpus_dir()
    jobs = jobs_for(args, corpus)
    print(f"self-check: running the JAR twice on {len(jobs)} (file, circuit) pairs\n")

    def one(job):
        path, circ = job
        a = run_java(path, circ, args.timeout)
        b = run_java(path, circ, args.timeout)
        if a is None or b is None or str(a).startswith("\0") or str(b).startswith("\0"):
            return job, "unusable", None
        if a != b:
            d = list(difflib.unified_diff(a.splitlines(), b.splitlines(),
                                          "run1", "run2", lineterm="", n=0))
            return job, "DIFFERS", "\n".join(d[:8])
        return job, "stable", None

    tally = {}
    unstable = []
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for job, status, detail in ex.map(one, jobs):
            tally[status] = tally.get(status, 0) + 1
            if status == "DIFFERS":
                unstable.append((job, detail))
                if len(unstable) <= args.max_fail:
                    print(f"  DIFFERS {os.path.basename(job[0])}::{job[1]}")
                    for line in (detail or "").splitlines():
                        print(f"          {line}")
    print(f"\n{'=' * 56}")
    print(f"  {tally}")
    if args.write_nondet:
        # Same role as tools/difftest/nondeterministic.json for the table gate: a MEASURED
        # exclusion list, written from runs of the jar against itself, never inferred from static
        # reachability of a random source. rig.py's headline number moved by 22 with no code
        # change until its equivalent was wired in.
        with open(args.write_nondet, "w") as f:
            json.dump({
                "source": "statsgate.py --selfcheck, 2 runs of the 4.1.0 jar per case",
                "cases": {f"{os.path.basename(p)}::{c}": "label" for (p, c), _ in unstable},
            }, f, indent=1)
        print(f"  wrote {len(unstable)} excluded case(s) -> {args.write_nondet}")
    if unstable:
        print(f"  {len(unstable)} case(s) where the 4.1.0 jar does not reproduce ITSELF. "
              "No port can pass these.")
        return 1
    print("  the oracle reproduces itself on every case — `stats` is deterministic here, so a "
          "\n  port mismatch is a port defect and nothing else.")
    return 0


def compare(args):
    corpus = corpus_dir()
    idx_path = os.path.join(args.golden, "_inventory.json")
    if not os.path.exists(idx_path):
        sys.exit(f"no golden inventory at {idx_path} — run with --regenerate first")
    index = json.load(open(idx_path))

    by_name = {}
    for p in circ_files(corpus):
        by_name.setdefault(os.path.basename(p), p)

    cases = [r for r in index.values()
             if args.pattern.search(f"{r['file']}::{r['circuit']}")]
    if not cases:
        sys.exit("no cases matched --filter")

    # PREFLIGHT, rig.py's three checks: name collisions, files named but absent, and content
    # drift against the sha256 recorded at capture time.
    collisions = {}
    for name in index:
        collisions.setdefault(name.lower(), []).append(name)
    clashing = {k: v for k, v in collisions.items() if len(v) > 1}
    present = {f for f in os.listdir(args.golden) if f.endswith(".stats")}
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

    # A MISSING BINARY IS NOT 1,787 PORT DEFECTS. Checked before any case runs, so the gate
    # cannot spend ten minutes producing a confident all-fail number about a binary that was
    # never built, which is exactly what happened on this gate's first run, from an off-by-one
    # in REPO above.
    if not os.path.exists(args.cli):
        sys.exit(f"logisim-cli not built at {args.cli}\n"
                 "  build it with: swift build -c release --product logisim-cli\n"
                 "  (refusing to report a number: every case would 'fail' for this one reason)")

    print(f"{len(cases)} cases  ·  cli={args.cli}\n")

    def one(rec):
        path = by_name.get(rec["file"])
        if not path:
            return rec, "MISSING", "corpus file not found"
        got = run_swift(args.cli, path, rec["circuit"], args.timeout)
        if got == "\0NOCLI":
            return rec, "NO-CLI", f"not built: {args.cli}"
        if got is None:
            return rec, "FAIL", "cli exited nonzero or timed out"
        want = open(os.path.join(args.golden, rec["golden"])).read()
        # THE ASSERTION THAT STOPS EMPTY==EMPTY. The golden set cannot contain an unshaped
        # capture (regenerate refuses to write one), but the PORT's output is unconstrained, so
        # it is checked here too. Without this a port that printed nothing would compare unequal
        # to a real oracle and be reported honestly, but a port that printed nothing against a
        # baseline that had somehow become empty would score OK, which is how an md5 of two
        # empty outputs once passed a case in this project.
        if not is_stats_shaped(got):
            return rec, "FAIL", "cli output does not end in the two TOTAL rows (empty or truncated)"
        if got == want:
            return rec, "PASS", ""
        d = list(difflib.unified_diff(want.splitlines(), got.splitlines(),
                                      "java", "swift", lineterm="", n=0))
        return rec, "FAIL", "\n".join(d[:8])

    # ── The MEASURED nondeterminism bucket ──────────────────────────────────────────────────
    #
    # Written by `--selfcheck --write-nondet`, from two runs of the JAR AGAINST ITSELF. Every
    # entry is a circuit whose stats output contains a `generateValidVHDLLabel` name, the same
    # random-UUID mechanism rig.py excludes 44 cases for, so it cannot pass a byte comparison
    # however correct the port is, and counting it as a failure blames the port for matching
    # upstream.
    #
    # This is loaded, not assumed: rig.py's classifier and gate were each built correctly and
    # NOTHING OWNED THE JOIN, so the exclusion file sat unread and the headline number moved by
    # 22 on its own. The count is printed below whether it is zero or not, so a silently unread
    # file shows up as `0 excluded` rather than as nothing at all.
    nondet_path = args.nondet or os.path.join(HERE, "stats-nondeterministic.json")
    nondet = {}
    if os.path.exists(nondet_path):
        nondet = json.load(open(nondet_path)).get("cases", {})
    else:
        print(f"  NOTE: no exclusion list at {nondet_path}; run --selfcheck --write-nondet")

    passed = failed = unreproducible = 0
    shown = 0
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for rec, status, detail in ex.map(one, cases):
            if status == "PASS":
                passed += 1
                continue
            key = f"{rec['file']}::{rec['circuit']}"
            if key in nondet:
                unreproducible += 1
                continue
            failed += 1
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
    print(f"  pass {passed}  ·  fail {failed}  ·  of {len(cases) - unreproducible}")
    print(f"  {unreproducible} case(s) excluded: the 4.1.0 jar does not reproduce them against"
          f"\n  itself (measured over 2 runs — see {os.path.basename(nondet_path)}).")

    # ── COVERAGE, PRINTED EVERY RUN ────────────────────────────────────────────────────────────
    #
    # `pass N / fail 0` is a statement about the golden SET, not about the corpus, and the two
    # drifted apart without a word: 310 of 2097 (file, circuit) pairs had no oracle, including
    # every case that places a SoC component. The denominator was invisible, so the SoC
    # display-name defect shipped against a gate that was green and empty on that family.
    #
    # Recomputed from the corpus here rather than trusted from a file, so it cannot go stale, and
    # printed unconditionally so that "0 uncovered" is an observation rather than an absence.
    corpus_jobs = list(dict.fromkeys(
        (os.path.basename(p), c) for p in circ_files(corpus) for c in circuits_in(p)))
    corpus_jobs = [j for j in corpus_jobs if args.pattern.search(f"{j[0]}::{j[1]}")]
    covered = {(r["file"], r["circuit"]) for r in index.values()}
    uncovered = [j for j in corpus_jobs if j not in covered]
    drop_path = os.path.join(args.golden, "_dropped.json")
    ledger = {}
    if os.path.exists(drop_path):
        ledger = {(d["file"], d["circuit"]): d
                  for d in json.load(open(drop_path)).get("cases", [])}
    unexplained = [j for j in uncovered if j not in ledger]
    print(f"  COVERAGE: {len(corpus_jobs) - len(uncovered)}/{len(corpus_jobs)} corpus "
          f"(file, circuit) pairs have a golden; {len(uncovered)} do not"
          + (f", {len(unexplained)} of them with no entry in {os.path.basename(drop_path)}"
             if uncovered else ""))
    if uncovered and args.list_uncovered:
        for j in uncovered:
            d = ledger.get(j)
            why = f"[{d['bucket']}] {d['reason']}" if d else "[UNRECORDED] never regenerated"
            print(f"    {j[0]}::{j[1]}  {why}")
    return 0 if failed == 0 else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--regenerate", action="store_true")
    ap.add_argument("--selfcheck", action="store_true",
                    help="run the JAR twice per case; report cases it cannot reproduce")
    ap.add_argument("--nondet", default=None,
                    help="path to the measured exclusion list (default: stats-nondeterministic.json"
                         " beside this script)")
    ap.add_argument("--write-nondet", default=None,
                    help="--selfcheck: write the measured exclusion list to this JSON path")
    ap.add_argument("--golden", default=os.path.join(
        os.environ.get("LOGISIM_CORPUS", "."), "golden-stats"))
    ap.add_argument("--cli", default=DEFAULT_CLI)
    ap.add_argument("--filter", default=".", help="regex over 'file::circuit'")
    ap.add_argument("--cases-from", default=None,
                    help="file of 'file::circuit' lines (i.e. --list-failures output) to scope to")
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--timeout", type=int, default=60)
    ap.add_argument("--max-fail", type=int, default=15, help="0 means unlimited")
    ap.add_argument("--list-failures", action="store_true")
    ap.add_argument("--list-uncovered", action="store_true",
                    help="list every corpus (file, circuit) pair that has no golden, with the "
                         "bucket that dropped it")
    ap.add_argument("--show-diff", action="store_true", default=True)
    args = ap.parse_args()
    if args.max_fail == 0:
        args.max_fail = 1 << 30
    args.pattern = re.compile(args.filter)
    if args.regenerate:
        return regenerate(args)
    if args.selfcheck:
        return selfcheck(args)
    return compare(args)


if __name__ == "__main__":
    sys.exit(main())
