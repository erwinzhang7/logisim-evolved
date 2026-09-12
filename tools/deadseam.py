#!/usr/bin/env python3
"""Closure seams that are declared and read but never assigned in Sources.

WHY THIS EXISTS — `seamcheck.py` cannot see this shape
======================================================
`seamcheck.py` finds a protocol with no conformer. That caught seams #9 to #24. But the two most
recent instances were a DIFFERENT shape and both were found by hand, one of them by an agent
rather than by any check:

  * **seam #22, `CircuitTransaction.wireRepair`**: declared, called once in `execute`, assigned
    nowhere. The editor therefore never repaired wires: drop a component onto a wire and it was
    not connected, because `CircuitPoints.add(Wire)` records only the two endpoints and a segment
    drawn *through* a port is not connected until `doSplits` cuts it there.
  * **seam #25, `CircuitTransaction.appearanceHook`**: same, and the file's own comment states
    the consequence: "a renamed circuit will keep drawing its old default box".

There is no protocol and no conformer here, so `seamcheck.py` is structurally blind to it. Every
hop exists, every name is plausible, and the last one is missing — the pattern this project has
now paid for 25 times.

WHAT IT REPORTS, AND WHY "ASSIGNED ONLY IN TESTS" IS ITS OWN BUCKET
------------------------------------------------------------------
Three buckets, because they are three different bugs:

  NEVER ASSIGNED      The seam is inert. Whatever it was installed for does not happen.
  ONLY IN TESTS       Worse in one specific way: the suite is green and the PRODUCT is unwired.
                      A test that assigns the seam itself and then checks the seam fired is a
                      test of the seam. That exact mistake is recorded twice in objectives.md,
                      so it gets its own line rather than being folded into "fine".
  ASSIGNED            Reported only under --verbose. This is the healthy state.

CALIBRATION — this script is checked against known answers, not trusted
----------------------------------------------------------------------
`--selftest` asserts the two seams whose status is established:
    wireRepair       must be ASSIGNED    (seam #22, installed 2026-09-06)
    appearanceHook   must be UNASSIGNED  (seam #25, open at the time of writing)
If a future change makes those wrong, fix the expectation deliberately — do not delete the
check. A seam checker that cannot be shown to discriminate is the thing it exists to prevent.

USAGE
    tools/deadseam.py [--verbose] [--selftest]

Exit 0 always: a report, not a gate. Same reasoning as `seamcheck.py`: every
finding is a CANDIDATE. A seam may be legitimately optional (a test hook, a platform injection
point that defaults to nil on purpose). Acting on an unverified finding is exactly how this
project once dispatched work for a defect that did not exist.
"""
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(REPO, "swift", "Sources")
TESTS = os.path.join(REPO, "swift", "Tests")

# `static var name: (...)?` / `nonisolated(unsafe) public static var name: (...)?`
# The closing `?` is what makes it a seam rather than a stored function: it has a nil state,
# which is the state this script is about.
#
# ── `static` IS OPTIONAL, AND THAT ONE WORD WAS A THREE-MONTH BLIND SPOT ─────────────────────
#
# This required `static` until 2026-09-06, while the header printed "N optional closure seam(s)
# declared in Sources; every seam that is read is also assigned", which reads as total coverage.
# It was never total: instance-level seams were not merely unreported, they were never CONSIDERED,
# so the reassuring line was computed over 12 of the 29 seams that exist.
#
# Widening it took the count from 12 to 29 and surfaced four seams that are read on a path a user
# can reach and assigned by nothing:
#
#     Circuit.diagnosticReporter          every model-layer diagnostic goes nowhere
#     CircuitWires.onError                propagation errors dropped silently
#     AddTool.matrixPlacement             the matrix PREVIEW draws, the click places one component
#     Project.viewComponentAttributesHook poking a component shows no attributes
#
# The first was found by hand during unrelated work, which is what prompted looking here at all.
# The lesson is the script's own: a checker's scope is a claim, and an unstated scope reads as
# "everything". The header now names what it covers.
DECL = re.compile(
    r"^\s*(?:nonisolated\(unsafe\)\s+)?(?:public\s+|internal\s+|private\s+)?"
    r"(?:private\(set\)\s+)?(?:static\s+)?var\s+"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*:\s*\(.*->.*\)\?"
)
# `->` is REQUIRED, and only became so when `static` stopped being. `\(.*\)\?` alone also matches
# an optional TUPLE: `var binaryOperands: (Expression, Expression)?`. Those are rare on `static`
# vars and common on instance vars, so dropping `static` without adding `->` took the count from
# 12 to 85 and the unassigned list from 0 to 20, nearly all of them optional tuples. Measured:
# with `->` the counts are 29 and 4. A widened checker that floods is a checker that gets ignored.

# The nearest `var NAME` at or above a line; i.e. which property's accessor body a hit sits in.
ENCLOSING_VAR = re.compile(r"(?:^|\s)(?:static\s+)?var\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*:")


def swift_files(root):
    for base, _, names in os.walk(root):
        for n in names:
            if n.endswith(".swift"):
                yield os.path.join(base, n)


def declarations():
    """{name: (file, line)} for every optional closure seam declared in Sources."""
    found = {}
    for path in swift_files(SOURCES):
        with open(path, encoding="utf-8", errors="replace") as fh:
            for i, line in enumerate(fh, 1):
                m = DECL.match(line)
                if m:
                    found[m.group("name")] = (os.path.relpath(path, REPO), i)
    return found


def assignment_sites(name, root, declared_at):
    """Files that ASSIGN the seam, excluding its own declaration and accessor plumbing.

    The accessors are the reason this is not a plain `name =` grep. A seam behind a lock reads

        public static var appearanceHook: (...)? {
          get { seams.withLock { $0.appearanceHook } }
          set { seams.withLock { $0.appearanceHook = newValue } }
        }

    and that `$0.appearanceHook = newValue` is the property FORWARDING to storage, not a caller
    installing a handler. Counting it would mark every locked seam as assigned and make the whole
    script silently useless -- which is the failure mode it is checking others for. So an
    assignment whose right-hand side is `newValue` is skipped, as is any hit inside the
    declaring file's own accessor block.
    """
    # A preceding `.` MUST be allowed. These are `static var`s, so every real call site is
    # qualified -- `CircuitTransaction.wireRepair = { … }`. An earlier version of this script
    # excluded a leading dot to avoid matching unrelated members, which excluded exactly the
    # sites it exists to find. See `read_sites` for how that slipped through the selftest.
    pattern = re.compile(
        r"(?<![A-Za-z0-9_])" + re.escape(name) + r"\s*=\s*(?P<rhs>[^=].*)$")
    sites = []
    for path in swift_files(root):
        rel = os.path.relpath(path, REPO)
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.readlines()
        for i, line in enumerate(lines, 1):
            if "==" in line:
                continue
            m = pattern.search(line)
            if not m:
                continue
            # The declaration line itself is never an assignment.
            if rel == declared_at[0] and i == declared_at[1]:
                continue
            rhs = m.group("rhs").strip()
            if rhs.startswith("newValue"):
                # `x = newValue` is the setter FORWARDING to storage. Whether that counts depends
                # entirely on WHOSE setter it is, and conflating the two is what hid four live
                # seams:
                #
                #   var appearanceHook: (...)? {          <- seam under test
                #     set { seams.withLock { $0.appearanceHook = newValue } }   NOT an assignment;
                #   }                                        it is the property reaching storage
                #
                #   var circuitSwitchHook: (...)? {       <- a DIFFERENT property
                #     set { seams.withLock { $0.circuitSwitch = newValue } }    IS an assignment
                #   }                                        of the storage field `circuitSwitch`
                #
                # So: skip only when the enclosing property is the seam itself. The old rule
                # skipped every `= newValue` unconditionally, plus anything within twelve lines of
                # the declaration: and a storage struct declares its fields next to the accessors
                # that write them, so both rules fired and the field looked unassigned.
                enclosing = None
                for j in range(i - 1, max(0, i - 60), -1):
                    em = ENCLOSING_VAR.search(lines[j - 1])
                    if em:
                        enclosing = em.group("name")
                        break
                if enclosing == name:
                    continue
            sites.append(f"{rel}:{i}")
    return sites


def read_sites(name):
    """Is the seam actually CONSULTED? A seam nobody reads is dead code, not a missing join."""
    # ── A READ IS ANY MENTION THAT IS NOT AN ASSIGNMENT ─────────────────────────────────────
    #
    # This started as `name?(`, the optional-call form, and that is only ONE of the ways a seam
    # is consumed. The commonest way in this codebase is to bind it first:
    #
    #     guard let make = LogisimFileSeams.makeVhdlEntity else { return }   LogisimFile.swift:545
    #     if let inUse = LogisimFileSeams.projectNameInUse, inUse(candidate)  LogisimFile.swift:189
    #     guard let measurer = textMeasurer else { return colWidth }         Tty.swift:127
    #     guard let factory = TelnetServer.transportFactory else { … }       TelnetServer.swift:147
    #     guard let handler = VhdlContentReader.handler else { … }           XmlReader.swift:680
    #
    # None of those match `?(`, so the "declared but never CONSULTED" bucket reported **all five
    # as dead when every one is read**. That bucket was the only one with no selftest anchor,
    # which is exactly why the error survived three rounds of fixing this file; an uncalibrated
    # mode is an unchecked mode, and I had written that sentence about the other modes while this
    # one sat uncalibrated.
    #
    # The rule now matches `write_only_collections`, which had it right from the start: count every
    # mention, subtract the assignments and the declaration, and what remains is a read.
    mention = re.compile(r"(?<![A-Za-z0-9_])" + re.escape(name) + r"(?![A-Za-z0-9_])")
    assignment = re.compile(r"(?<![A-Za-z0-9_])" + re.escape(name) + r"\s*=(?!=)")
    hits = []
    for path in swift_files(SOURCES):
        rel = os.path.relpath(path, REPO)
        with open(path, encoding="utf-8", errors="replace") as fh:
            for i, line in enumerate(fh, 1):
                stripped = line.lstrip()
                # Comments name seams constantly in this tree; they are not consumers.
                if stripped.startswith(("//", "///", "*")):
                    continue
                if not mention.search(line):
                    continue
                # `name = …` is a write, not a read. Note this does NOT exclude
                # `guard let x = Type.name`, where the name sits on the RIGHT of the `=` and is
                # followed by `else`, which is precisely the form that was being missed.
                if assignment.search(line):
                    continue
                # The declaration itself: `var name: T?` / `let name: T`.
                if re.search(r"\b(?:var|let)\s+" + re.escape(name) + r"\s*:", line):
                    continue
                hits.append(f"{rel}:{i}")
    return hits


# `var name: [T] = []` / `= [:]`; a stored collection that starts empty. `let` is excluded:
# a constant collection cannot be appended to, so it cannot have this defect.
COLLECTION_DECL = re.compile(
    r"^\s*(?:public\s+|internal\s+|private\s+)?(?:private\(set\)\s+)?"
    r"(?:public\s+|internal\s+|private\s+)?(?:private\(set\)\s+)?"
    r"var\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*:\s*(?:\[[^\]]+\]|Set<[^>]+>)\s*=\s*(?:\[\]|\[:\])"
)

# The ways a collection is WRITTEN. Anything else that names it counts as a read.
MUTATORS = ("append", "insert", "removeAll", "remove", "removeLast", "removeFirst", "formUnion")


def write_only_collections(min_name_length=12):
    """Collections that are appended to and never read — the OTHER half of seam #25.

    `CircuitMutator.appearanceRecomputeRequests` is the canonical instance: `.append(circuit)` at
    :202, declared at :210, and no reader anywhere. The transaction dutifully records which
    circuits need their appearance recomputed and then drops the list on the floor, so a renamed
    circuit keeps drawing its old default box. That is the same failure as an unassigned closure
    seam wearing different clothes: the work is done and the last hop is missing.

    `min_name_length` exists because short names (`items`, `rows`) collide across files and this
    scans all of Sources for reads -- a distinctive name is what makes cross-file read detection
    trustworthy. Short ones are skipped rather than reported unreliably; a checker that cries
    wolf is one people learn to silence.
    """
    decls = {}
    for path in swift_files(SOURCES):
        with open(path, encoding="utf-8", errors="replace") as fh:
            for i, line in enumerate(fh, 1):
                m = COLLECTION_DECL.match(line)
                if m and len(m.group("name")) >= min_name_length:
                    decls[m.group("name")] = (os.path.relpath(path, REPO), i)

    out = []
    for name, (dfile, dline) in sorted(decls.items()):
        word = re.compile(r"(?<![A-Za-z0-9_])" + re.escape(name) + r"(?![A-Za-z0-9_])")
        writes, reads = [], []
        for path in swift_files(SOURCES):
            rel = os.path.relpath(path, REPO)
            with open(path, encoding="utf-8", errors="replace") as fh:
                for i, line in enumerate(fh, 1):
                    # ── COMMENTS ARE NOT READS, AND THIS COST A RED SELFTEST ──────────────
                    #
                    # Any mention counted as a read, including one inside a doc comment. On
                    # 2026-09-09 a comment was added to `CircuitSceneView` praising this very
                    # idiom -- "Counters, not booleans" -- and it NAMED `repaintedRects`. That
                    # one mention made the collection look read, flipped the positive anchor,
                    # and turned `--selftest` red. Found by an external audit of the gates, not
                    # by anyone running the tool.
                    #
                    # The failure direction is the dangerous one: a stray mention makes a
                    # write-only collection look USED, so the mode goes quiet rather than
                    # loud. `constructed_only_by_tests` and `static_funcs_called_only_by_tests`
                    # take the same shape and are worth the same treatment if they ever anchor
                    # on a name that appears in prose.
                    code = line.split("//", 1)[0]
                    if not word.search(code):
                        continue
                    line = code
                    if rel == dfile and i == dline:
                        continue  # the declaration itself
                    after = line.split(name, 1)[1] if name in line else ""
                    mutating = any(
                        re.match(r"\s*\.\s*" + mu + r"\s*\(", after) for mu in MUTATORS
                    ) or re.match(r"\s*(?:\+|-)?=", after)
                    # ── A MUTATION WHOSE RESULT IS CONSUMED IS A READ ──────────────────────
                    #
                    # Swift's `Set.insert` returns `(inserted:memberAfterInsert:)` and `remove`
                    # returns an optional, and using those is the single most common way this
                    # codebase reads a set:
                    #
                    #     if seenConnections.insert(connection).inserted { … }
                    #     if pullIdentities.remove(ObjectIdentifier(comp)) != nil { … }
                    #
                    # Counting those as write-only produced three false positives on the first
                    # run -- `seenConnections`, `pullIdentities`, `bundleIdentities` -- every one
                    # of them a perfectly wired membership test. A checker whose novel section is
                    # mostly noise is one people learn to silence, which this file's own
                    # header says about a report that cries wolf.
                    if mutating and (
                        re.search(r"\)\s*\.\s*[A-Za-z_]", after)          # .insert(x).inserted
                        or re.search(r"\)\s*(?:!=|==|\?\?)", after)       # .remove(x) != nil
                        or re.match(r"\s*(?:if|guard|while|let|var|return)\b", line.strip())
                    ):
                        mutating = False
                    (writes if mutating else reads).append(f"{rel}:{i}")

        # Reads from TESTS are tracked separately. A `private(set)` collection that only the
        # suite inspects is deliberate test observability, not a missing join -- `repaintedRects`
        # is exactly that, and reporting it beside a real seam would be wrong.
        test_reads = []
        for path in swift_files(TESTS):
            rel = os.path.relpath(path, REPO)
            with open(path, encoding="utf-8", errors="replace") as fh:
                for i, line in enumerate(fh, 1):
                    if word.search(line):
                        test_reads.append(f"{rel}:{i}")

        if writes and not reads:
            out.append({
                "name": name, "declared": f"{dfile}:{dline}",
                "writes": writes, "test_reads": test_reads,
            })
    return out


# `public final class Foo` / `final class Foo` / `public struct Foo` …
TYPE_DECL = re.compile(
    r"^\s*(?:public\s+|internal\s+)?(?:final\s+)?(?:class|struct)\s+"
    r"(?P<name>[A-Z][A-Za-z0-9_]*)\b"
)

# ── THERE IS DELIBERATELY NO "not a construction" PREFIX RULE ────────────────────────────────
#
# The first version had one, to exclude type annotations and conformances, and it began with
# `:\s*$`; "the text before the name ends in a colon". That is a type annotation (`let x: Foo`)
# and it is ALSO every labelled argument in Swift:
#
#     AddTool(factory: BitSelector()), <- PlexersLibrary.swift:83
#
# so the rule silently discarded the real construction of `BitSelector`, `Multiplexer`,
# `Demultiplexer` and every other factory built through a labelled initialiser, and the check
# reported 20 types as "built by nothing in the product" when most were built normally.
#
# The rule was also unnecessary, which is the part worth remembering. `sites()` already requires
# the name to be followed by `(`, and none of the contexts the rule was guarding against can be:
# `let x: Foo(`, `-> Foo(`, `as Foo(`, `extension Foo(` and `class Foo(` are not Swift. A
# leading `.` is already excluded by the lookbehind. So the trailing paren does the whole job and
# the prefix rule could only ever subtract correct answers.


def constructed_only_by_tests(min_name_length=10):
    """Types that exist, are correct, and that NOTHING in the shipped product ever builds.

    This is the third shape of the same defect, and it is the one that produced **seam #17**:
    `SocCircuitBinder` was written correctly, tested thoroughly, and constructed by nothing
    outside `LogisimSocTests`. So `Circuit.mutatorAdd` never registered anything with
    `SocSimulationManager` in any runtime that actually existed -- the seam was closed in the
    model and unreachable from the product. `Netlist.standalone` was the same story from the
    other end: it built an owner that died on the same line.

    Neither `seamcheck.py` (protocol with no conformer) nor the two checks above (a closure or a
    collection with a missing join) can see it. Here the conformer exists AND the seam is
    assigned -- there is simply no caller in Sources.

    Only reports types that ARE constructed in Tests. A type constructed nowhere at all is dead
    code, a different and much less interesting problem. `min_name_length` is the same
    cross-file-name-collision guard `write_only_collections` uses and for the same reason.
    """
    decls = {}
    for path in swift_files(SOURCES):
        with open(path, encoding="utf-8", errors="replace") as fh:
            for i, line in enumerate(fh, 1):
                m = TYPE_DECL.match(line)
                if m and len(m.group("name")) >= min_name_length:
                    decls.setdefault(m.group("name"), (os.path.relpath(path, REPO), i))

    def sites(name, root):
        call = re.compile(r"(?<![A-Za-z0-9_.])" + re.escape(name) + r"\s*\(")
        hits = []
        for path in swift_files(root):
            rel = os.path.relpath(path, REPO)
            with open(path, encoding="utf-8", errors="replace") as fh:
                for i, line in enumerate(fh, 1):
                    if call.search(line):
                        hits.append(f"{rel}:{i}")
        return hits

    out = []
    for name, (dfile, dline) in sorted(decls.items()):
        src = [s for s in sites(name, SOURCES) if not s.startswith(f"{dfile}:{dline}")]
        if src:
            continue
        tst = sites(name, TESTS)
        if tst:
            out.append({
                "name": name, "declared": f"{dfile}:{dline}", "tests": tst,
            })
    return out


# `public static func name(`; the namespace-style entry point this project uses for a derivation
# or a pass. Instance methods are deliberately excluded: see the witness note in the docstring.
STATIC_FUNC_DECL = re.compile(
    r"^\s*(?:public\s+|internal\s+)?static\s+func\s+(?P<name>[a-z][A-Za-z0-9_]*)\s*[(<]"
)


def static_funcs_called_only_by_tests(min_name_length=8):
    """`public static func`s defined in Sources and called only from Tests.

    The FOURTH shape, and the one that produced **seam #26**. `CircuitAnalysis.deriveExpressions`
    was defined once in Sources and called zero times there — four times from
    `AnalyzeDerivedExpressionTests` and nowhere else — so the Analyze window never took upstream's
    netlist-expression path despite a complete four-layer stack beneath it. It is not a closure
    seam (nothing to assign), not a collection, and not a type construction, so all three checks
    above are blind to it.

    ── WHY ONLY `static func`, AND WHY THAT IS A REAL LIMIT ──────────────────────────────────
    Instance methods are excluded because of PROTOCOL WITNESSES: a method that satisfies a
    protocol requirement is called through the protocol, so its own name never appears at the
    call site and a name-based search says "called only by tests" with total confidence and no
    truth behind it. That is the failure mode this file has already produced three times in one
    session, and here it would be invisible rather than merely wrong.

    `static func` is not immune — a static protocol requirement exists — but it is rare in this
    tree, and the namespace-enum style (`CircuitAnalysis.analyze`, `TruthTableRun.pinColumns`) is
    exactly where derivations and passes live. So the check is deliberately narrow and honest
    about it, rather than broad and unfalsifiable.
    """
    decls = {}
    for path in swift_files(SOURCES):
        with open(path, encoding="utf-8", errors="replace") as fh:
            for i, line in enumerate(fh, 1):
                m = STATIC_FUNC_DECL.match(line)
                if m and len(m.group("name")) >= min_name_length:
                    decls.setdefault(m.group("name"), (os.path.relpath(path, REPO), i))

    def calls(name, root, skip=None):
        call = re.compile(r"(?<![A-Za-z0-9_])" + re.escape(name) + r"\s*\(")
        hits = []
        for path in swift_files(root):
            rel = os.path.relpath(path, REPO)
            with open(path, encoding="utf-8", errors="replace") as fh:
                for i, line in enumerate(fh, 1):
                    if skip and rel == skip[0] and i == skip[1]:
                        continue
                    stripped = line.lstrip()
                    # The declaration itself, wherever it is, and doc comments naming the symbol.
                    if stripped.startswith(("///", "//", "*")) or " func " in line:
                        continue
                    if call.search(line):
                        hits.append(f"{rel}:{i}")
        return hits

    out = []
    for name, where in sorted(decls.items()):
        if calls(name, SOURCES, skip=where):
            continue
        tst = calls(name, TESTS)
        if tst:
            out.append({"name": name, "declared": f"{where[0]}:{where[1]}", "tests": tst})
    return out


def classify():
    out = []
    for name, where in sorted(declarations().items()):
        src = assignment_sites(name, SOURCES, where)
        tst = assignment_sites(name, TESTS, where)
        out.append({
            "name": name, "declared": f"{where[0]}:{where[1]}",
            "sources": src, "tests": tst, "reads": read_sites(name),
        })
    return out


def main() -> int:
    verbose = "--verbose" in sys.argv
    rows = classify()

    if "--selftest" in sys.argv:
        by = {r["name"]: r for r in rows}
        ok = True
        # BOTH halves. Asserting only `assigned` let a version ship that found zero reads for
        # every static seam -- see the note in `read_sites`.
        expectations = (
            # name,             assigned, read
            ("wireRepair",      True,     True),   # seam #22, installed 2026-09-06
            ("appearanceHook",  True,     True),   # seam #25, installed 2026-09-06 — WAS False
            # WAS `False`: board #64 installed it on 2026-09-06, so this flipped, deliberately.
            #
            # THE GAP NOTED HERE IS NOW CLOSED, and the way it closed is worth keeping.
            #
            # This used to say: "with every seam now wired, there is no live instance of an
            # unassigned seam to anchor the positive direction on… this mode is currently
            # certified in one direction only: the exact weakness that let all four modes of this
            # script ship broken." That was true of the seams the script could SEE, and the reason
            # it could not see any unassigned one is that it only ever looked at `static var`.
            # Instance seams were never considered, and four of them were unassigned the whole
            # time. A mode certified in one direction because the other direction was invisible is
            # the strongest form of the weakness that comment describes.
            ("toolChangeHook",  True,     True),
            # The positive direction, at last: an instance seam, read on a reachable path, that
            # nothing in Sources assigns. It is assigned in TESTS, which is what made it invisible
            # to every other check: the suite is green and the product is unwired.
            # When board #99 installs it, flip this to True rather than deleting it.
            ("diagnosticReporter", False,  True),
            # The storage half of a lock-protected seam: `circuitSwitch` is the field that
            # `circuitSwitchHook`'s setter writes (`Project.swift:892`, `$0.circuitSwitch =
            # newValue`). It IS assigned, and it is assigned by exactly the kind of line the old
            # blanket "skip every `= newValue`" rule threw away, so with that rule restored this
            # anchor reads assigned=False and fails.
            #
            # It exists because the precision fix was otherwise pinned by NOTHING: reverting to
            # the blanket skip passed the whole selftest, which is a green probe, which is not a
            # passing probe. Found by mutating the script and watching it stay green.
            ("circuitSwitch",   True,     True),
        )
        # The `->` requirement in DECL, pinned from the other side. Without it the same widening
        # also matches optional TUPLES, which took the seam count from 29 to 85 and the unassigned
        # list from 4 to 20; a flood that would have made the whole report unreadable.
        if "binaryOperands" in by:
            print("  SELFTEST binaryOperands: matched as a closure seam, but it is an optional "
                  "TUPLE — DECL lost its `->` requirement — MISCLASSIFIED")
            ok = False
        else:
            print("  SELFTEST binaryOperands: correctly not a seam (optional tuple, not a "
                  "closure) — ok")
        for name, expect_assigned, expect_read in expectations:
            r = by.get(name)
            if r is None:
                print(f"  SELFTEST: {name} is not declared any more — update the expectation")
                ok = False
                continue
            got_a, got_r = bool(r["sources"]), bool(r["reads"])
            good = got_a == expect_assigned and got_r == expect_read
            ok = ok and good
            print(f"  SELFTEST {name}: expected assigned={expect_assigned} read={expect_read}, "
                  f"got assigned={got_a} read={got_r} — {'ok' if good else 'MISCLASSIFIED'}")
        # The write-only half needs its own anchor, for the same reason: a mode nobody calibrates
        # is a mode nobody has checked. `appearanceRecomputeRequests` is appended to at
        # CircuitMutator.swift:202 and read nowhere -- seam #25's other half.
        #
        # WHEN SEAM #25 IS FIXED THIS EXPECTATION MUST FLIP to False, deliberately. Do not delete
        # the check: an uncalibrated checker is the thing this file exists to prevent.
        rows = write_only_collections()
        names = {r["name"] for r in rows}

        # Seam #25 LANDED on 2026-09-06, so this flipped from True; `CircuitTransaction.execute`
        # now drains the queue into the `appearanceRecompute` seam. Kept as the NEGATIVE anchor
        # rather than deleted: it is the one collection whose correct state is known for certain,
        # and if the drain is ever removed this fails before the report can call it healthy.
        got = "appearanceRecomputeRequests" in names
        good = got is False
        ok = ok and good
        print(f"  SELFTEST appearanceRecomputeRequests: expected write-only=False, got {got} — "
              f"{'ok' if good else 'MISCLASSIFIED (was the seam #25 drain removed?)'}")

        # POSITIVE anchor for the same machinery. With #25 landed there is no genuinely dead
        # collection left in the tree, so anchoring "something is detected" needs a real instance
        # that is detected and then bucketed aside: `repaintedRects` is written in Sources, read
        # nowhere in Sources, and read by the suite. That exercises the detection AND the
        # test-observability split, which is the half that produced a false positive first time.
        #
        # Saying this out loud because the alternative is worse: dropping the positive direction
        # when the last instance is fixed leaves the mode certified in one direction only, which
        # is exactly how all four modes here shipped broken.
        observed = [r for r in rows if r["name"] == "repaintedRects" and r["test_reads"]]
        good = len(observed) == 1
        ok = ok and good
        print(f"  SELFTEST repaintedRects: expected detected-and-test-observed=True, "
              f"got {len(observed) == 1} — {'ok' if good else 'MISCLASSIFIED'}")

        # Third mode, both directions. `SocCircuitBinder` is the historical instance, seam #17,
        # constructed by nothing outside LogisimSocTests until 2026-09-06, and is now built in
        # `LogisimFileProjectHost`, so it must NOT be flagged. `NominalTextMeasurer` is a genuine
        # test double and must be.
        built = {r["name"] for r in constructed_only_by_tests()}
        for name, expect_flagged in (("SocCircuitBinder", False), ("NominalTextMeasurer", True)):
            got = name in built
            good = got == expect_flagged
            ok = ok and good
            print(f"  SELFTEST {name}: expected test-only={expect_flagged}, got {got} — "
                  f"{'ok' if good else 'MISCLASSIFIED'}")

        # Fourth mode. `deriveExpressions` is the historical instance, seam #26, called only from
        # AnalyzeDerivedExpressionTests until 2026-09-06, and `analyze` calls it now, so it must
        # NOT be flagged. `encodeJpeg` is ported ahead of its consumer and must be.
        funcs = {r["name"] for r in static_funcs_called_only_by_tests()}
        for name, expect_flagged in (("deriveExpressions", False), ("encodeJpeg", True)):
            got = name in funcs
            good = got == expect_flagged
            ok = ok and good
            print(f"  SELFTEST {name}: expected test-only={expect_flagged}, got {got} — "
                  f"{'ok' if good else 'MISCLASSIFIED'}")

        print("\n  selftest passed\n" if ok else "\n  SELFTEST FAILED\n")
        return 0

    dead = [r for r in rows if not r["sources"] and r["reads"]]
    tests_only = [r for r in rows if not r["sources"] and r["tests"] and r["reads"]]
    unread = [r for r in rows if not r["reads"]]

    print(f"deadseam — {len(rows)} optional closure seam(s) declared in Sources\n")

    if dead:
        print(f"  {len(dead)} seam(s) READ but NEVER ASSIGNED in Sources — the join is missing:\n")
        for r in dead:
            tag = "  (assigned in Tests only — suite green, product unwired)" if r["tests"] else ""
            print(f"    {r['name']}{tag}")
            print(f"      declared  {r['declared']}")
            for s in r["reads"][:3]:
                print(f"      read      {s}")
            for s in r["tests"][:2]:
                print(f"      test-only {s}")
            print()
    else:
        print("  every seam that is read is also assigned somewhere in Sources.\n")

    if unread:
        print(f"  {len(unread)} declared seam(s) are never CONSULTED (dead declaration, not a")
        print("  missing join — different problem, listed quietly):")
        for r in unread:
            print(f"    {r['name']}  {r['declared']}")
        print()

    write_only = write_only_collections()
    dead_collections = [r for r in write_only if not r["test_reads"]]
    observed_by_tests = [r for r in write_only if r["test_reads"]]

    if dead_collections:
        print(f"  {len(dead_collections)} collection(s) WRITTEN and never READ — the same missing")
        print("  join wearing different clothes (this is the other half of seam #25):\n")
        for r in dead_collections:
            print(f"    {r['name']}")
            print(f"      declared  {r['declared']}")
            for s in r["writes"][:3]:
                print(f"      written   {s}")
            print()

    if observed_by_tests:
        print(f"  {len(observed_by_tests)} collection(s) written, unread in Sources, but READ BY")
        print("  TESTS — deliberate test observability, listed quietly rather than as a seam:")
        for r in observed_by_tests:
            print(f"    {r['name']:32} {r['declared']}")
        print()

    test_built = constructed_only_by_tests()
    if test_built:
        print(f"  {len(test_built)} type(s) constructed ONLY BY TESTS — the shape that produced")
        print("  seam #17: correct, tested, and built by nothing in the shipped product:\n")
        for r in test_built:
            print(f"    {r['name']}")
            print(f"      declared    {r['declared']}")
            for s in r["tests"][:2]:
                print(f"      built by    {s}")
            print()

    # ── OFF BY DEFAULT, AND THE BASE RATE IS WHY ────────────────────────────────────────────
    #
    # This mode describes seam #26 exactly, so it is worth having. It is NOT worth having in the
    # default report: it finds 27, and the first three checked by hand were all explained by
    # design; `compareNodes` is a deliberate test-facing duplicate of the private
    # `compareNodesConsistently` that `sorted(by:)` actually uses, and `driveString` /
    # `constrainedDriveMode` are ported for fidelity ahead of the UI that will call them.
    #
    # The base rate here is structurally different from the other three modes. **This port
    # deliberately ports functions before their consumers**, so "defined in Sources, called only
    # by tests" is the normal condition of a port in progress rather than an anomaly. Printing 27
    # such lines beside the closure mode's 7, of which 6 were real, would bury the signal in
    # the noise, which is the exact failure this file keeps warning about in other people's
    # checks. So: available when hunting a specific area, silent otherwise.
    if "--test-only-funcs" in sys.argv:
        test_called = static_funcs_called_only_by_tests()
        print(f"  {len(test_called)} static func(s) called ONLY BY TESTS — seam #26's shape.")
        print("  EXPECT A LOW HIT RATE: porting a function ahead of its consumer is normal here,")
        print("  so most of these are fidelity, not defects. Read each one's header.\n")
        for r in test_called:
            print(f"    {r['name']}")
            print(f"      declared    {r['declared']}")
            for s in r["tests"][:2]:
                print(f"      called by   {s}")
            print()

    if verbose:
        print("  assigned in Sources (healthy):")
        for r in rows:
            if r["sources"]:
                print(f"    {r['name']:22} <- {r['sources'][0]}")
        print()

    print("  Every line above is a CANDIDATE, not a verdict. A seam may be optional on purpose\n"
          "  (a test hook, a platform injection point that defaults to nil). Confirm by hand:\n"
          "  acting on an unverified finding is how this project once dispatched work for a\n"
          "  defect that did not exist.")
    if tests_only:
        print(f"\n  Note {len(tests_only)} seam(s) assigned ONLY in Tests. That is the shape that\n"
              "  keeps a suite green while the shipped product has no wiring at all.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
