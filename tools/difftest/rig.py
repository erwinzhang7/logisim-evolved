#!/usr/bin/env python3
"""Differential rig: diff logisim-cli against the Java implementation.

The Java app is the oracle. Every milestone's pass condition is expressed here,
so this must work — reporting honest failures — before logisim-cli does anything.

    # build/refresh the golden set from Java (slow; run when the corpus changes)
    LOGISIM_CORPUS=/path/to/corpus python3 rig.py --regenerate

    # gate: diff the Swift CLI against golden
    LOGISIM_CORPUS=/path/to/corpus python3 rig.py
    python3 rig.py --filter 'adder|mux'     # scope to a subset
    python3 rig.py --max-fail 5             # print N failures in full
    python3 rig.py --max-fail 0             # print them ALL (0 = unlimited)
    python3 rig.py --list-failures          # just the failing file::circuit names

Exit 0 only if every selected case matches. Anything else is a red gate.

The corpus and golden set live OUTSIDE this repo (see .gitignore): they derive
from private coursework and the golden tables are effectively lab solutions.
"""
import argparse, concurrent.futures as cf, difflib, glob, hashlib, json, os, re, subprocess, sys
import threading
import time

JAVA = os.environ.get("LOGISIM_JAVA", "/opt/homebrew/opt/openjdk@21/bin/java")
JAR = os.environ.get(
    "LOGISIM_JAR",
    "/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar")
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# PREFER RELEASE. A debug sweep reaches ~100 of 1,392 cases in 30 minutes and never finishes --
# measured, and it silently wasted a 45-minute agent run that had to be caught with `ps`. The
# default used to be debug unconditionally, and tools/ci.sh invokes this with no --cli, so CI's
# simulation gate was running the binary that cannot complete.
_RELEASE_CLI = os.path.join(REPO, "swift", ".build", "release", "logisim-cli")
_DEBUG_CLI = os.path.join(REPO, "swift", ".build", "debug", "logisim-cli")
DEFAULT_CLI = _RELEASE_CLI if os.path.exists(_RELEASE_CLI) else _DEBUG_CLI


def corpus_dir():
    d = os.environ.get("LOGISIM_CORPUS")
    if not d or not os.path.isdir(d):
        sys.exit("set LOGISIM_CORPUS to the corpus directory (see docs/objectives.md)")
    return d


def circ_files(corpus):
    """All .circ in the corpus root and in harvested/.

    Deduplicated: `harvested/*.circ` and `harvested/*` overlap completely, and
    without the dedupe every harvested file was processed twice — 4,089 pairs
    where there are 2,098, doubling the JVM invocations for identical output.
    """
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


def golden_name(path, circuit):
    """Filesystem-safe golden name.

    Truncating to 180 chars alone collides — harvested names are long and several
    circuits share a prefix, which silently overwrote 8 oracles. A short hash of
    the full key keeps truncated names distinct.
    """
    # Key on the FULL path, not the basename: two corpus files can share a basename
    # and a circuit name, which collides even with a hash of the basename key.
    key = f"{os.path.abspath(path)}__{circuit}"
    safe = re.sub(r"[^A-Za-z0-9_.-]", "_", f"{os.path.basename(path)}__{circuit}")
    digest = hashlib.sha256(key.encode()).hexdigest()[:8]
    return f"{safe[:160]}__{digest}.table"


def run_java(path, circuit, timeout):
    """Capture one `-tty table` run of the oracle.

    Returns the table, `None` on timeout, or `"\\0CRASH:<rc>"` if the JVM exited nonzero.

    **The exit code was never checked, and that is the root cause of the truncated baseline.**
    `3.5.0__case-383.circ::truc` was recorded in `docs/experiments/m3-simulation-gate.md` as "captured from
    a run that stopped part-way", i.e. as harness flakiness. It is not: the jar itself dies with

        java.lang.NullPointerException: Cannot invoke "java.lang.Thread.isAlive()"
          because "data.thread" is null
            at com.cburch.logisim.std.io.extra.Buzzer.propagate(Buzzer.java:255)
            at ...TtyInterface.doTableAnalysis(TtyInterface.java:428)

    and exits **255** having already streamed tens of thousands of valid rows to stdout. Because
    this function returned `p.stdout` regardless, a crashed run was indistinguishable from a
    complete one and its partial table was written into the golden set as an oracle.

    It also dies at a *different row each time*, 65,653 / 65,654 / 65,655 across three runs —
    so the truncation is not even stable. Healthy oracles exit 0 (verified on three), so the
    return code is a sound signal and simply had no reader.
    """
    cmd = [JAVA, "-Djava.awt.headless=true", "-jar", JAR,
           "--toplevel-circuit", circuit, "-tty", "table", os.path.basename(path)]
    try:
        p = subprocess.run(cmd, cwd=os.path.dirname(path), capture_output=True,
                           text=True, timeout=timeout)
        if p.returncode != 0:
            return f"\0CRASH:{p.returncode}"
        return p.stdout
    except subprocess.TimeoutExpired:
        return None


def run_swift(cli, path, circuit, timeout):
    """Returns the table, `"\\0TIMEOUT"`, or `None` for a nonzero exit.

    A TIMEOUT IS NOT A FAILURE AND MUST NOT BE COUNTED AS ONE. These used to both return `None`
    and the summary reported them together as "cli exited nonzero or timed out". They are not the
    same thing: a nonzero exit is a defect in the port, and a timeout is a statement about how
    busy the machine was.

    That conflation made the headline load-dependent, which was caught the direct way — three
    consecutive full runs on a box at ~3% idle scored 1,343, then 1,319, then 1,316, and the
    single "worst" file re-run serially with a 600s timeout passed 19 of 19. Twenty-seven cases
    of apparent regression, none of them real, in a gate whose whole purpose is to be believed.

    Same lesson as the nondeterminism bucket: a case the harness could not measure gets its own
    column, never the failure column.
    """
    cmd = [cli, "--toplevel-circuit", circuit, "--tty", "table", os.path.basename(path)]
    try:
        p = subprocess.run(cmd, cwd=os.path.dirname(path), capture_output=True,
                           text=True, timeout=timeout)
        # A nonzero exit is a failure, but keep stdout so the diff is informative.
        return p.stdout if p.returncode == 0 else None
    except FileNotFoundError:
        return "\0NOCLI"
    except subprocess.TimeoutExpired:
        return "\0TIMEOUT"


def is_table_shaped(lines):
    """A `-tty table` capture has `2^n + 1` lines: one header plus one row per input combination.

    This is the shape assertion that `regenerate()` lacked, and its absence is how
    `3.5.0__case-383.circ__truc.table` entered the golden set with 65,655 lines — a 262,145-line capture
    cut off part-way. The only previous guard was `out.count("\\n") <= 2`, which rejects an empty
    run and accepts a table truncated anywhere above three lines.
    """
    return lines >= 2 and bin(lines - 1).count("1") == 1


def regenerate(args):
    """Rebuild the golden set from the Java oracle.

    ── Three properties this function did not have, each of which corrupted the golden set ──────

    1. **It silently overwrote.** `golden_name` appends `sha256(abspath + "__" + circuit)[:8]`
       precisely so two circuits cannot share a path, but a plain `open(..., "w")` cannot tell a
       refresh from a collision, so the digest was never load-bearing. On APFS
       `3.0.0__case-167.circ__Ctrl.table` and `3.0.0__case-167.circ__ctrl.table` are ONE file: two threads both "succeeded", the loser's
       bytes were lost, and one oracle was compared against a different circuit's output for every
       run since. Now the job list is checked for case-folded duplicates *before any JVM starts*,
       and every write claims its path with `O_CREAT|O_EXCL`, so a collision aborts instead of
       winning a race.

    2. **It did not check the shape of what it captured.** See `is_table_shaped`.

    3. **A scoped `--filter` run destroyed the index.** `index` started empty and was written back
       wholesale, so `--regenerate --filter foo` replaced a 1,392-entry inventory with however
       many entries matched `foo`. Regenerating three bad baselines would have thrown away the
       other 1,389. Scoped runs now merge: entries outside the job set are carried through
       untouched, entries inside it are dropped and re-added only on success, and files orphaned
       by a name change are unlinked rather than left to accumulate.

    4. **An interrupted run left the set silently inconsistent.** `.table` files are written as
       each job finishes but `_inventory.json` only at the very end, so a run killed part-way
       leaves files newer than the hashes recorded for them. That is invisible for a deterministic
       oracle — a rewrite reproduces the same bytes — and it is exactly how
       `2.7.0__case-155.circ__main.table` came to hold a capture the index does not describe. It was
       found by `compare()`'s new content check, having passed both the name and shape checks.

       This ordering is kept, because the alternative (index first) is worse, but the failure mode
       is now loud rather than silent: doomed files are unlinked up front, so an interrupted run
       leaves entries **named in the index and absent on disk**, which the preflight already
       reports and excludes. Failing loudly beats a stale file that still parses.
    """
    corpus = corpus_dir()
    os.makedirs(args.golden, exist_ok=True)
    jobs = [(p, c) for p in circ_files(corpus) for c in circuits_in(p)]
    jobs = [j for j in jobs if args.pattern.search(f"{os.path.basename(j[0])}::{j[1]}")]
    if not jobs:
        sys.exit("no (file, circuit) pairs matched --filter")

    # ── A file may declare the same circuit name twice ───────────────────────────────────────
    #
    # `harvested/2.7.1__case-169.circ` has `<circuit name="decoder">` at lines 548 AND
    # 1179, so `circuits_in` yields it twice and the job list holds the pair twice. The collision
    # preflight below then reports the job as colliding WITH ITSELF and aborts the whole
    # regeneration before a single JVM starts -- which is why `rig.py --regenerate` over the full
    # corpus does not run today.
    #
    # Deduplicated rather than tolerated in the preflight, because the preflight's question is
    # "do two DIFFERENT circuits want one path", and an identical pair is not that.
    #
    # The malformed file is still worth knowing about, so it is reported rather than smoothed
    # over: which of the two blocks Java keeps is a real question about the reader and nobody
    # has asked it. It does not block regeneration, so it is a warning.
    seen: set = set()
    deduped = []
    repeats: dict = {}
    for job in jobs:
        if job in seen:
            repeats.setdefault(job, 1)
            repeats[job] += 1
            continue
        seen.add(job)
        deduped.append(job)
    if repeats:
        print(f"  note: {len(repeats)} (file, circuit) pair(s) are declared more than once in "
              "their own file;\n  regenerating each once. The duplicate declaration is a "
              "property of the corpus file:")
        for (path, circ), n in sorted(repeats.items())[:5]:
            print(f"    {os.path.basename(path)}::{circ} x{n}")
    jobs = deduped
    print(f"regenerating golden for {len(jobs)} (file, circuit) pairs")

    # ── ASSERTION 1, before any JVM starts: no two jobs may claim one path ───────────────────
    #
    # Case-folded, because the filesystem this runs on is. Checking here rather than at write
    # time means a collision is reported as a collision, with both circuit names, instead of
    # surfacing months later as an unpassable oracle.
    claimed = {}
    clashes = []
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
        sys.exit(f"{len(clashes)} golden path collision(s) — refusing to generate. Two circuits "
                 "map to one file, so one oracle would be silently lost.")

    # ── Merge, do not replace ───────────────────────────────────────────────────────────────
    idx_path = os.path.join(args.golden, "_inventory.json")
    old = {}
    if os.path.exists(idx_path):
        old = json.load(open(idx_path))
    jobkeys = {(os.path.basename(p), c) for p, c in jobs}
    index = {n: r for n, r in old.items() if (r["file"], r["circuit"]) not in jobkeys}
    print(f"  carrying {len(index)} untouched entries through from the existing inventory")

    # Clear the way for the writers: every path this run intends to produce, plus every path the
    # old index held for a key in this run's job set (which may differ, if the naming changed).
    # Doing it up front, rather than letting each writer truncate, is what lets the write below
    # use O_EXCL and still be idempotent across repeated runs.
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
            return job, "sequential/timeout", None
        if out.startswith("\0CRASH:"):
            # The jar threw. Its partial stdout is NOT an oracle, however many valid rows it
            # streamed first; see `run_java`. Writing it is what put a 65,655-line capture of a
            # 262,145-row table into the golden set.
            print(f"  JAR CRASHED {os.path.basename(path)}::{circ}: exit {out.split(':')[1]}; "
                  "no oracle exists for this case", file=sys.stderr)
            return job, "jar-crashed", None
        lines = out.count("\n")
        if lines <= 2:
            return job, "empty", None
        # ── ASSERTION 2: shape, BEFORE writing ──────────────────────────────────────────────
        if not is_table_shaped(lines):
            print(f"  TRUNCATED {os.path.basename(path)}::{circ}: {lines} lines is not 2^n+1; "
                  "not written", file=sys.stderr)
            return job, "truncated", None
        name = golden_name(path, circ)
        # ── ASSERTION 3: the path must not already exist ────────────────────────────────────
        try:
            fd = os.open(os.path.join(args.golden, name),
                         os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        except FileExistsError:
            print(f"  COLLISION {os.path.basename(path)}::{circ} -> {name} already exists; "
                  "not overwriting", file=sys.stderr)
            return job, "collision", None
        with os.fdopen(fd, "w") as f:
            f.write(out)
        return job, "OK", {"file": os.path.basename(path), "circuit": circ,
                           "golden": name, "lines": lines,
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
    rejected = sum(counts.get(k, 0) for k in ("collision", "truncated", "jar-crashed"))
    if rejected:
        print(f"  REFUSING A CLEAN EXIT: {rejected} oracle(s) rejected at capture time. The "
              "inventory is consistent, but it is missing those entries.")
    print(f"  {len(index)} golden oracles, "
          f"{sum(r['lines'] for r in index.values()):,} rows -> {args.golden}")
    return 1 if rejected else 0


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

    # ── PREFLIGHT: is the golden set itself sound? ──────────────────────────────────────────
    #
    # Two defects were found in it on 2026-09-05, both silent, both of which make a gate report a
    # confident number about the wrong thing.
    #
    # 1. CASE-INSENSITIVE NAME COLLISION. `golden_name` appends a sha256 digest precisely to stop
    #    this, but the baselines on disk predate that and carry none, so the digest branch can
    #    never fire. On APFS, `3.0.0__case-167.circ__Ctrl.table` and `3.0.0__case-167.circ__ctrl.table` are ONE file: the second
    #    regeneration overwrote the first, and one oracle has since been compared against a
    #    different circuit's output. 1,392 index entries, 1,391 files.
    #
    # 2. TRUNCATED BASELINE. A truth table has 2^n + 1 lines (header + rows). One baseline has
    #    65,656, which is not of that form, so it was cut off mid-write.
    #
    # Neither is fixed by code; they need `--regenerate`. What code can do is refuse to report a
    # number computed over a corrupt oracle set, which is what this does.
    collisions: dict[str, list[str]] = {}
    for name in index:
        collisions.setdefault(name.lower(), []).append(name)
    clashing = {k: v for k, v in collisions.items() if len(v) > 1}
    present = {f for f in os.listdir(args.golden) if f.endswith(".table")}
    missing = [r["golden"] for r in index.values() if r["golden"] not in present]
    ragged = [r for r in index.values() if r["lines"] > 2 and not is_table_shaped(r["lines"])]

    # 3. CONTENT DRIFT. The two checks above are about *names*; this one is about bytes, and it
    #    is the only one that catches a baseline whose file was replaced by something else after
    #    capture. The collision above was visible this way too, both index entries recorded the
    #    sha256 the JVM actually produced, and the surviving file matched only one of them, so
    #    this would have named the wrong oracle even if the two paths had not been case-variants.
    stale = []
    for r in index.values():
        if r["golden"] not in present or "sha256" not in r:
            continue
        with open(os.path.join(args.golden, r["golden"]), "rb") as fh:
            if hashlib.sha256(fh.read()).hexdigest() != r["sha256"]:
                stale.append(r["golden"])

    unsound = set(missing) | {r["golden"] for r in ragged} | set(stale)
    for names in clashing.values():
        unsound.update(names)

    if unsound:
        # EXCLUDED, NOT REFUSED, and the difference matters. Refusing outright would let one bad
        # baseline block every measurement, which is how a gate stops being run at all. Excluding
        # with the reason printed is the same treatment the UUID-label class already gets: a
        # documented exclusion beats both a silent skip and a blocked gate.
        print(f"  EXCLUDING {len(unsound)} unsound baseline(s) — the number below is over "
              f"{len(cases) - sum(1 for r in cases if r['golden'] in unsound)}, not {len(cases)}:")
        for names in clashing.values():
            print(f"    case collision, one file on APFS: {names}")
        for m in sorted(missing)[:5]:
            print(f"    named in the index, absent on disk: {m}")
        for r in ragged[:5]:
            print(f"    {r['lines']} lines is not 2^n+1, so truncated: {r['golden']}")
        for s in sorted(stale)[:5]:
            print(f"    on-disk bytes do not match the captured sha256: {s}")
        print("    Fix by regenerating: `golden_name` already appends a sha256 digest, and these"
              "\n    baselines predate it, which is why the collision survives.\n")
        cases = [r for r in cases if r["golden"] not in unsound]

    print(f"{len(cases)} cases  ·  cli={args.cli}")
    print(staleness_note(args.cli))

    def one(rec):
        path = by_name.get(rec["file"])
        if not path:
            return rec, "MISSING", "corpus file not found"
        got = run_swift(args.cli, path, rec["circuit"], args.timeout)
        if got == "\0NOCLI":
            return rec, "NO-CLI", f"not built: {args.cli}"
        if got == "\0TIMEOUT":
            return rec, "TIMEOUT", f"no result within {args.timeout}s"
        if got is None:
            return rec, "FAIL", "cli exited nonzero"
        want = open(os.path.join(args.golden, rec["golden"])).read()
        if got == want:
            return rec, "PASS", ""
        d = list(difflib.unified_diff(want.splitlines(), got.splitlines(),
                                      "java", "swift", lineterm="", n=0))
        return rec, "FAIL", "\n".join(d[:6])

    # ── The nondeterminism bucket, produced by tools/difftest/nondet.py ─────────────────────
    #
    # 44 cases were measured over 5 runs of the JAR AGAINST ITSELF: 43 vary only in a label
    # (`generateValidVHDLLabel` appends a random UUID), 1 varies in a value (`Random` seed 0 means
    # "use currentTimeMillis"). Those cannot pass a byte comparison no matter how correct the port
    # is, so counting them as failures blames the port for matching upstream.
    #
    # WIRING THIS IN IS WHAT MAKES THE HEADLINE NUMBER STABLE. It was measured twice within an
    # hour as 1,343 and 1,321 over the same corpus, a 22-case spread, purely because a different
    # subset of those 44 happened to differ on each run. A gate whose number moves by 22 with no
    # code change cannot detect a regression smaller than 22.
    #
    # Deliberately NOT inferred from static reachability of a seed-0 `Random`: that detector was
    # written, it flagged `3.6.0__case-458.circ::MoveCore`, and MoveCore then passed byte-exactly once
    # an unrelated ROM defect was fixed. Whether nondeterminism reaches an output column is
    # circuit-dependent, so it is measured.
    nondet_path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                               "nondeterministic.json")
    nondet: dict = {}
    if os.path.exists(nondet_path):
        nondet = json.load(open(nondet_path)).get("cases", {})

    passed = failed = unreproducible = timed_out = 0
    timeout_names: list[str] = []
    shown = 0
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for rec, status, detail in ex.map(one, cases):
            if status == "NO-CLI":
                # The same shape as the dead simulation mode: without this, a CLI that was never
                # built scores 0 pass / 1,347 fail and reads as "the port is completely broken"
                # rather than "you did not build it". `roundtrip` already exits here; this arm was
                # missing, so the two modes disagreed about the same mistake.
                sys.exit(f"logisim-cli not built: {args.cli}")
            if status == "PASS":
                passed += 1
                if args.verbose:
                    print(f"  PASS  {rec['file']}::{rec['circuit']}")
                continue
            key = f"{rec['file']}::{rec['circuit']}"
            if status == "TIMEOUT":
                # Not a failure and not a pass: the harness did not get an answer. Counted and
                # named so the run is honest about what it did not measure -- see `run_swift`.
                timed_out += 1
                timeout_names.append(key)
                continue
            if key in nondet:
                # The jar disagrees with itself here; this says nothing about the port.
                unreproducible += 1
                continue
            failed += 1
            if args.list_failures:
                print(f"{rec['file']}::{rec['circuit']}")
                continue
            if shown < args.max_fail:
                shown += 1
                print(f"  {status:<7} {rec['file']}::{rec['circuit']}  ({rec['lines']} rows)")
                if detail and args.show_diff:
                    for line in detail.splitlines():
                        print(f"          {line}")

    if failed > shown:
        print(f"  ... and {failed - shown} more failures (raise --max-fail to see them)")
    print(f"\n{'='*56}")
    denominator = len(cases) - unreproducible - timed_out
    print(f"  pass {passed}  ·  fail {failed}  ·  of {denominator}")
    if unreproducible:
        print(f"  {unreproducible} case(s) excluded: the 4.1.0 jar does not reproduce them against"
              f"\n  itself (measured over 5 runs — see tools/difftest/nondeterministic.json).")
    if timed_out:
        print(f"\n  !! {timed_out} case(s) TIMED OUT at {args.timeout}s and were NOT measured.")
        print("  This number is PROVISIONAL. A timeout is a statement about how busy the machine")
        print("  was, not about the port -- on a loaded box this gate has swung by 27 cases with")
        print("  no code change. Re-run the named cases before quoting anything:")
        print(f"    python3 tools/difftest/rig.py --jobs 1 --timeout 600 --filter '<case>'")
        for name in timeout_names[:10]:
            print(f"      {name}")
        if len(timeout_names) > 10:
            print(f"      ... and {len(timeout_names) - 10} more")
    # A timeout does not make the gate red -- it makes it unmeasured, and `--timeout` is the
    # caller's knob. Exit 2 (distinct from a real 1) so CI can tell "unmeasured" from "broken".
    if failed:
        return 1
    return 2 if timed_out else 0


# `_` followed by exactly 8 lowercase hex digits, at a token boundary -- the shape
# `UUID.randomUUID().toString().substring(0, 8)` produces.
VHDL_LABEL_SUFFIX = re.compile(r"_[0-9a-f]{8}(?![0-9a-zA-Z_])")


def mask_vhdl_labels(text):
    """Blank out `generateValidVHDLLabel`'s random suffix so both sides can be compared.

    `XmlReader.generateValidVHDLLabel` repairs a label that is not a legal VHDL identifier and,
    IF IT CHANGED ANYTHING, appends `UUID.randomUUID().toString().substring(0, 8)`
    (`XmlReader.java:717`, `:758`). So the jar does not reproduce its own output: three runs of
    `CircBridge` over `2.7.0__case-248.circ` gave `Bn_1_439aa5cc`, `Bn_1_69ad5ecb`, `Bn_1_36063c8e`.

    The golden baseline froze one of those draws, and the migration gate was scoring the port
    against it -- blaming the port for not guessing a UUID. `nondet.py` had already measured and
    documented exactly this for the SIMULATION gate; the round-trip gate never got the same
    treatment.

    MASKING, NOT EXCLUDING, and `nondet.py`'s header says why: dropping these cases outright once
    hid 8 genuine body divergences behind a random label. Everything except the suffix must still
    be byte-identical, so `Bn_1` vs `Cn_1` still fails, and -- the case that matters -- a Swift
    `generateValidVHDLLabel` that declines to repair a label Java does repair emits `Bn_1` against
    Java's `Bn_1_HASH`, which still fails. Only the eight random characters are forgiven.
    """
    return VHDL_LABEL_SUFFIX.sub("_HASH", text)


# `<a name="font" val="FAMILY STYLE SIZE"/>` and svg `font-family="FAMILY"`.
# THREE attribute names, not one. `font` was the obvious case and it is not the only one:
# `labelfont` and `clabelfont` carry the same `FontSpec` through the same codec and are written by
# the same `Font.getFamily()` call, so they lose a family name exactly the same way. Missing them
# left `3.7.1__case-539.circ` in the failure column reading as a library defect, which is what
# it was dispatched as. Found by an agent that could not edit this file and reported the diff.
FONT_ATTR = re.compile(r'(<a name="(?:font|labelfont|clabelfont)" val=")([^"]*?)( \w+ \d+"/>)')
FONT_SVG = re.compile(r'(font-family=")([^"]*)(")')


def font_families(text):
    """Every font family named in the document, in order."""
    return [m.group(2) for m in FONT_ATTR.finditer(text)] + [
        m.group(2) for m in FONT_SVG.finditer(text)
    ]


def neutralise_unresolved_fonts(want, got, source):
    """Fold ONLY the case where Java lost a family name the port kept.

    `Font.getFamily()` returns what the graphics environment resolved a request to, and both of
    upstream's write sites call it (`Attributes.java:195`, `SvgCreator.java:142`) while both read
    sites keep the requested name unvalidated. So an unavailable family is written back as
    `Dialog` and the original is destroyed. The port re-emits what it parsed.

    **Upstream's output is therefore a function of the host's installed fonts.** Measured, not
    argued: installing one font and re-running the unchanged jar over unchanged input changed the
    output. The golden baseline is not portable, which is a bigger problem than these 13 cases and
    is recorded in `docs/experiments/font-family.md`.

    THREE CONDITIONS, and the third is the one that keeps this honest:

      1. java says exactly `Dialog` -- the unresolved sentinel, not merely some other family
      2. the port says something else
      3. that something else occurs VERBATIM IN THE SOURCE FILE

    (3) is what stops the mask hiding a port defect. The port is forgiven only for re-emitting a
    family the input actually carried, so mangling `Ubuntu` to `Ubunt`, dropping a family, or
    inventing one all still fail. Style word, size and every other byte are compared literally.

    Returns the rewritten (want, got), or the originals if the rule does not apply.
    """
    if "Dialog" not in want:
        return want, got

    # EXACT family values, never a substring test. `gots[i] in source` was the first version and
    # it is wrong: "CMU Sans Seri" is a substring of "CMU Sans Serif", so a port that dropped a
    # letter from the family satisfied condition (3) and got forgiven. That is precisely the port
    # defect this condition exists to catch. Caught by a probe, not by reading it.
    source_families = set(font_families(source))

    def fold(pattern, w, g):
        wants = [m.group(2) for m in pattern.finditer(w)]
        gots = [m.group(2) for m in pattern.finditer(g)]
        if len(wants) != len(gots):
            return w, g  # different shape entirely; not this rule's business
        it = iter(range(len(wants)))
        replacements = {}
        for i in it:
            if wants[i] == "Dialog" and gots[i] != "Dialog" and gots[i] in source_families:
                replacements[i] = True
        if not replacements:
            return w, g
        counter = {"i": -1}

        def sub_got(m):
            counter["i"] += 1
            return m.group(1) + "Dialog" + m.group(3) if counter["i"] in replacements else m.group(0)

        counter["i"] = -1
        return w, pattern.sub(sub_got, g)

    for pattern in (FONT_ATTR, FONT_SVG):
        want, got = fold(pattern, want, got)
    return want, got


LIB_DECL = re.compile(r'<lib desc="([^"]*)" name="(\d+)"')
LIB_REF = re.compile(r'\blib="(\d+)"')


def resolve_lib_indices(text):
    """Rewrite every `lib="N"` to `lib="<desc>"`, using that document's own `<lib>` table.

    Library handles are POSITIONAL: `XmlWriter.fromLibrary` assigns `Integer.toString(libs.size())`
    as it walks, so dropping one library slides every later index down by one. That makes a
    textual diff of two documents useless the moment their library sets differ, even where they
    agree perfectly about what each component IS.

    Resolving the index to the library's own `desc` removes the renumbering and leaves the
    question that actually matters: do the two sides agree about which library each component
    comes from.
    """
    table = {n: desc for desc, n in LIB_DECL.findall(text)}
    # BOTH sides of the numbering: the `lib="N"` references AND the `name="N"` on the declaration
    # itself. Normalising only the references leaves `<lib desc="#Base" name="7">` against
    # `... name="9">`, which then reads as "the port lost #Base" -- the exact opposite of what
    # happened. That mistake cost 15 of 19 cases their correct classification.
    out = LIB_REF.sub(lambda m: 'lib="%s"' % table.get(m.group(1), m.group(1)), text)
    return LIB_DECL.sub(lambda m: '<lib desc="%s" name="@%s"' % (m.group(1), m.group(1)), out)


def port_is_strict_superset(want, got):
    """True when the port kept everything the jar kept, and more.

    D8 says unknown content round-trips verbatim. 4.1.0 does the opposite for a `<lib>` it cannot
    resolve: `LibraryManager.loadLibrary` reports and returns null, the name never enters
    `ReadContext.libs`, `findLibrary` throws, and `XmlCircuitReader.java:225` catches and **the
    component is simply not added**. Across the 18 files of one harvested repository the port preserves 389
    components upstream destroys.

    So the port is not failing these; it is declining to lose data, which is what D8 asks for.
    But "the port did something different" must never be enough to fold a case, so the rule is a
    STRICT SUBSET CHECK after index resolution:

      * every non-blank line the jar emitted must be present in the port's output, and
      * the port must have at least one line the jar does not.

    A port that DROPS anything upstream kept fails, which is the regression this column must stay
    able to see. Renumbering alone cannot satisfy it either, because indices are resolved first.
    """
    w = [ln.strip() for ln in resolve_lib_indices(want).splitlines() if ln.strip()]
    g = [ln.strip() for ln in resolve_lib_indices(got).splitlines() if ln.strip()]
    if not w or not g:
        return False
    from collections import Counter
    wc, gc = Counter(w), Counter(g)
    for line, n in wc.items():
        if gc[line] < n:
            return False  # the port lost something upstream kept
    return sum(gc.values()) > sum(wc.values())


def migration_baseline_dir(root):
    """Where the MIGRATION expectations live -- `migrated_solo` whenever it exists.

    THIS HAS NOW GONE WRONG TWICE, THE SAME WAY, AND IT COSTS DAYS EACH TIME
    ------------------------------------------------------------------------
    `WiringLibrary.java:33` keeps its tools in a `private static final Tool[]`, so every builtin
    library's `AddTool` attribute state is JVM-GLOBAL. `canonical.py` batches ~100 files through
    one `CircBridge` JVM, and `XmlReader.toLibrary` writes `<lib><tool>` attribute values straight
    into those statics -- so tool blocks read from file A reappear in the saved form of file B.
    A fresh `Loader` per file does NOT help; only a fresh process does. `solobaseline.py` exists
    for exactly this and writes `migrated_solo/`.

    The failure mode is the dangerous one: nothing errors. The port is byte-correct and gets
    scored against an expectation containing `<tool>` blocks the jar does not produce from that
    input, so it reads as a port defect. In the first occurrence that led to specifying and
    DISPATCHING work to fix a defect that did not exist. In the second, `canonical.py` was re-run
    and silently overwrote `migrated/` with batched output again -- migration fell 456 -> 80 and
    presented as a regression from a merge.

    Reading `migrated_solo` by preference makes a `canonical.py` re-run unable to clobber the
    expectations at all, which is the only version of this that does not depend on someone
    remembering. `migrated/` stays the fallback so a corpus predating `solobaseline.py` still
    runs -- loudly, because a silent fallback is how this hid the first time.
    """
    solo = os.path.join(root, "migrated_solo")
    if os.path.isdir(solo):
        return solo
    batched = os.path.join(root, "migrated")
    print("  ⚠  no `migrated_solo/` — scoring migration against BATCHED baselines, which are\n"
          "     contaminated by JVM-global tool state (see migration_baseline_dir). Extra\n"
          "     <tool> blocks will be blamed on the port. Run tools/difftest/solobaseline.py.\n",
          file=sys.stderr)
    return batched



def staleness_note(cli):
    """One line saying how old the binary being scored is, relative to the working tree.

    WHY: `rig.py` scores whatever binary is at `--cli`. If `swift build` failed, or was never
    run after a merge, the gate still runs and still prints a confident pass/fail — against the
    PREVIOUS build. That is the most dangerous shape a number can have here, because it looks
    exactly like a measurement: fresh output, real cases, wrong binary.

    It nearly happened on 2026-09-06. A release build printed two lines matching `error:` while
    the gate reported canonical 539/0 straight afterwards; the binary turned out to be fresh and
    the grep had miscounted, but nothing in the output could have told the difference. Checking
    an exit code is not the same as counting matches, and neither was visible from here.

    So the gate now states its own provenance and says so out loud when the binary predates the
    newest source file. Advisory, not fatal: measuring an older binary on purpose is a legitimate
    thing to do (bisecting, or comparing against a known-good build), and refusing would break it.
    """
    import glob as _glob
    if not os.path.exists(cli):
        return f"  cli MISSING: {cli} — build it before believing anything below\n"
    built = os.path.getmtime(cli)
    newest, newest_path = 0.0, None
    for root in ("swift/Sources", "swift/Tests"):
        base = os.path.join(REPO, root) if "REPO" in globals() else root
        for f in _glob.glob(os.path.join(base, "**", "*.swift"), recursive=True):
            m = os.path.getmtime(f)
            if m > newest:
                newest, newest_path = m, f
    stamp = time.strftime("%F %T", time.localtime(built))
    if newest_path and newest > built:
        age = (newest - built) / 60.0
        return (f"  cli built {stamp}  ***STALE***: {os.path.basename(newest_path)} is "
                f"{age:.0f} min newer.\n  Numbers below describe the PREVIOUS build.\n")
    return f"  cli built {stamp} (newer than every source file)\n"

def roundtrip(args):
    """M2 gate: diff the Swift codec's load->save against upstream's own converter.

    Two independent conditions, and they fail for different reasons:

      CANONICAL   load(c) -> save  ==  c,  where c = -n(-n(f))
                  Tests the reader and writer on modern-format input. A failure here is a
                  formatting or ordering bug.

      MIGRATION   load(f) -> save  ==  -n(f)
                  Tests considerRepairs on the original legacy file. A failure here is a
                  missed or wrong migration pass, which is the dangerous kind: it makes an
                  old file MIS-RENDER rather than fail, so nothing else would catch it.

    Requires `canonical.py` to have run first.
    """
    corpus = corpus_dir()
    root = os.path.join(corpus, "canonical")
    idx_path = os.path.join(root, "_index.json")
    if not os.path.exists(idx_path):
        sys.exit(f"no canonical index at {idx_path} — run canonical.py first")
    index = json.load(open(idx_path))

    cases = [(src, base) for src, base in index.items()
             if args.pattern.search(os.path.basename(src))]
    if not cases:
        sys.exit("no cases matched --filter")
    mig_dir = migration_baseline_dir(root)
    print(f"{len(cases)} files  ·  cli={args.cli}")
    print(staleness_note(args.cli))

    # Did the codec DO anything? See the verdict block for why this is recorded.
    transformed = {"count": 0}
    transformed_lock = threading.Lock()

    def one(case):
        src, base = case
        mig_expected = os.path.join(mig_dir, base)
        can_expected = os.path.join(root, "canonical", base)
        results = []
        for label, inp, expected in (("canonical", can_expected, can_expected),
                                     ("migration", src, mig_expected)):
            out = os.path.join(args.tmp, f"{label}__{base}")
            try:
                p = subprocess.run([args.cli, "--convert", inp, out],
                                   capture_output=True, text=True, timeout=args.timeout)
            except FileNotFoundError:
                return [("NO-CLI", label, base, f"not built: {args.cli}")]
            except subprocess.TimeoutExpired:
                results.append(("FAIL", label, base, "cli timed out"))
                continue
            if p.returncode != 0:
                results.append(("FAIL", label, base,
                                (p.stderr or "").strip().splitlines()[:1] or ["nonzero exit"]))
                continue
            if not os.path.exists(out):
                results.append(("FAIL", label, base, "cli wrote no output"))
                continue
            got = open(out, encoding="utf-8", errors="replace").read()
            want = open(expected, encoding="utf-8", errors="replace").read()
            # Record whether the codec CHANGED anything on this file. See the verdict block.
            if label == "migration":
                src_text = open(inp, encoding="utf-8", errors="replace").read()
                if got != src_text:
                    with transformed_lock:
                        transformed["count"] += 1
            if got == want:
                results.append(("PASS", label, base, ""))
            elif mask_vhdl_labels(got) == mask_vhdl_labels(want):
                # Differs ONLY in `generateValidVHDLLabel`'s random suffix -- see that function.
                # Reported in its own column, never folded into PASS.
                results.append(("LABEL", label, base, ""))
            else:
                # Try the font rule as well, and only on the label-masked text, so a case needing
                # both is still caught rather than falling through to FAIL.
                src_text = open(inp, encoding="utf-8", errors="replace").read()
                fw, fg = neutralise_unresolved_fonts(
                    mask_vhdl_labels(want), mask_vhdl_labels(got), src_text)
                if fw == fg:
                    results.append(("FONT", label, base, ""))
                elif label == "migration" and port_is_strict_superset(fw, fg):
                    results.append(("D8", label, base, ""))
                else:
                    d = list(difflib.unified_diff(
                        fw.splitlines(), fg.splitlines(), "java", "swift", lineterm="", n=0))
                    results.append(("FAIL", label, base, "\n".join(d[:8])))
        return results

    os.makedirs(args.tmp, exist_ok=True)
    # [pass, fail, label-only] per condition. The third slot is NOT a pass -- see
    # `mask_vhdl_labels`. It is reported on its own line so the number stays visible.
    tally = {"canonical": [0, 0, 0, 0, 0], "migration": [0, 0, 0, 0, 0]}
    # PER-LABEL print budget, not a shared one.
    #
    # This was a single `shown` counter across both conditions, and it hid a real regression.
    # Migration currently fails on every file, so it consumed the whole budget before a single
    # canonical failure could be printed: the summary said "canonical fail 19" while the output
    # above it showed only migration lines, and the 19 had to be found by converting baselines
    # by hand. A gate whose noisy column can silence its quiet one is worse than no output.
    shown = {}
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for group in ex.map(one, cases):
            for status, label, base, detail in group:
                if status == "NO-CLI":
                    sys.exit(f"logisim-cli not built: {args.cli}")
                slot = tally.setdefault(label, [0, 0, 0, 0, 0])
                slot[{"PASS": 0, "LABEL": 2, "FONT": 3, "D8": 4}.get(status, 1)] += 1
                if (status not in ("PASS", "LABEL", "FONT", "D8")
                        and shown.get(label, 0) < args.max_fail):
                    shown[label] = shown.get(label, 0) + 1
                    print(f"  FAIL [{label}] {base[:70]}")
                    if args.show_diff and detail:
                        for line in str(detail).splitlines()[:8]:
                            print(f"        {line}")

    print(f"\n{'='*60}")
    failed = 0
    label_only = 0
    font_only = 0
    d8_only = 0
    for label in ("canonical", "migration"):
        p, f, l, fo, d8 = tally.get(label, [0, 0, 0, 0, 0])
        failed += f
        label_only += l
        font_only += fo
        d8_only += d8
        line = f"  {label:<10} pass {p}  ·  fail {f}"
        if l:
            line += f"  ·  {l} vhdl-label"
        if fo:
            line += f"  ·  {fo} font-unresolved"
        if d8:
            line += f"  ·  {d8} d8-superset"
        print(line)
    if label_only:
        print(
            f"\n  {label_only} file(s) differ ONLY in `generateValidVHDLLabel`'s random 8-hex\n"
            "  suffix, which the jar does not reproduce against itself -- three CircBridge runs\n"
            "  over one file gave Bn_1_439aa5cc, Bn_1_69ad5ecb, Bn_1_36063c8e. Every other byte\n"
            "  matched, so these are counted apart rather than blamed on the port. They are NOT\n"
            "  folded into pass: see `mask_vhdl_labels` for why masking beats excluding.")
    if font_only:
        print(
            f"\n  {font_only} file(s) differ ONLY where the jar wrote `Dialog` for a family the\n"
            "  source file names and this port preserved. Font.getFamily() emits what the host's\n"
            "  graphics environment resolved the request to, so UPSTREAM'S OUTPUT DEPENDS ON THE\n"
            "  FONTS INSTALLED ON THE MACHINE -- installing one font changed the unchanged jar's\n"
            "  output over unchanged input. The golden baseline is not portable. See\n"
            "  docs/experiments/font-family.md and `neutralise_unresolved_fonts`.")
    if d8_only:
        print(
            f"\n  {d8_only} file(s) where the port kept everything the jar kept AND MORE. 4.1.0\n"
            "  DESTROYS a component whose library it cannot resolve -- LibraryManager reports and\n"
            "  returns null, and XmlCircuitReader.java:225 catches and does not add the component.\n"
            "  Across the 18 files of one harvested repository the port preserves 389 components\n  upstream deletes, and\n"
            "  dropping those libraries to match would fix ZERO files, because 13 of the 18 also\n"
            "  carry <comp> names 4.1.0 lacks. That is D8 working. A port that LOSES anything the\n"
            "  jar kept still fails -- see `port_is_strict_superset`.")

    # ── The canonical column ALONE cannot tell a working codec from cp(1) ────────────────────
    #
    # Found by tools/gateaudit.py, which substituted a stub CLI that just copies its input to its
    # output and watched this gate report **canonical pass 539 / fail 0**.
    #
    # That is not a bug in the comparison, it is inherent to the condition: a canonical file is by
    # definition a fixed point of Java's converter, so `load -> save` must return it unchanged,
    # and an identity codec returns everything unchanged. The canonical column proves the port
    # does not CORRUPT an already-canonical file. It is not evidence that the port parses one.
    #
    # The migration column is the discriminating one: the same `cp` stub scores 39/500 there,
    # because a legacy file must actually be transformed. So the honest verdict needs both, and
    # this check makes the gate say so rather than leaving a reader to infer it from a green 539.
    n_transformed = transformed["count"]
    print(f"  {'transformed':<10} {n_transformed} migration input(s) actually changed by the codec")
    if n_transformed == 0:
        print(
            "\n  REFUSING TO REPORT A PASS: the CLI changed no migration input at all, so it is\n"
            "  indistinguishable from cp(1). A green canonical column means nothing on its own —\n"
            "  every canonical file is a fixed point, so an identity codec satisfies it."
        )
        return 1
    return 0 if failed == 0 else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--regenerate", action="store_true",
                    help="rebuild the golden set from the Java oracle")
    ap.add_argument("--roundtrip", action="store_true",
                    help="M2 gate: diff Swift load->save against the canonical forms")
    ap.add_argument("--tmp", default="/tmp/logisim-roundtrip",
                    help="scratch directory for round-trip output")
    ap.add_argument("--golden", default=os.path.join(
        os.environ.get("LOGISIM_CORPUS", "."), "golden"))
    ap.add_argument("--cli", default=DEFAULT_CLI)
    ap.add_argument("--filter", default=".", help="regex over 'file::circuit'")
    # Measured on the 6P+12E M-series CI machine over all 1,391 cases: 6 workers at the old
    # 25-second timeout took 337.61s; 10 workers took 214.51s.  Raising the timeout to 60s at
    # 10 workers took 316.32s while reducing the unmeasured bucket from 31 cases to 10.
    ap.add_argument("--jobs", type=int, default=10)
    ap.add_argument("--timeout", type=int, default=60)
    # `--max-fail 0` used to mean "print NOTHING", which is the opposite of what a reader
    # reaches for when they want the whole list. It cost a full corpus sweep: an agent ran with
    # 0 to get the tally, got a bare number with no names, and had to run the entire 1,392-case
    # gate again to find out WHICH cases failed. 0 now means unlimited.
    ap.add_argument("--max-fail", type=int, default=15,
                    help="failures to print in full; 0 means unlimited")
    ap.add_argument("--list-failures", action="store_true",
                    help="print every failing 'file::circuit' one per line, and nothing else")
    ap.add_argument("--show-diff", action="store_true", default=True)
    ap.add_argument("--verbose", "-v", action="store_true")
    args = ap.parse_args()
    if args.max_fail == 0:
        args.max_fail = 1 << 30  # 0 means unlimited; see the flag's help
    args.pattern = re.compile(args.filter)
    if args.regenerate:
        return regenerate(args)
    if args.roundtrip:
        return roundtrip(args)
    return compare(args)


if __name__ == "__main__":
    sys.exit(main())
