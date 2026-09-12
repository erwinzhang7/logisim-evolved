#!/usr/bin/env python3
"""Find unwired seams: things declared, called, and never given an implementation.

WHY THIS EXISTS
---------------
This is the single largest defect class in this port, by a wide margin. It has occurred
**eight** times, each found by hand, each time after the code had already shipped into the tree
and compiled cleanly:

  1. `Loader.fileReader` declared, two adaptors written, neither ever installed. Every file load
     failed with "no .circ reader is installed", which reads like a corrupt file.
  2. Four codec handlers (D8 `<comp>`, appearance, VHDL, builtin tools) declared and never
     assigned. Each silently destroyed user data on a plain open-and-save.
  3. `InstancePoker`/`PokeMouseEvent`/`PokeKeyEvent` — seven component files coded against a poke
     API that nobody was assigned to write. 78 of 173 build errors.
  4. Two value palettes (`ValuePalette`, `ValueRole`), both flat rawValue-indexed, in different
     orders, with no bridge. A FALSE wire rendered as unconnected grey.
  5. `BuiltinToolProviders` — a registry with no registrar, so every `<comp>` resolved to nothing.
  6. All 132 files of component painting: 61 `paintInstance` implementations and zero callers.
  7. Five phantom `Sim*` protocols describing classes in the same module, whose signatures had
     drifted so far that nothing could ever have conformed to them.
  8. `CircuitRenderer` itself — written, verified against real circuits, and unreferenced by the
     UI that needed it.

The common shape is always the same: **each half is individually correct, and nothing owns the
join.** It is invisible to the compiler (an unassigned Optional is legal, an unconformed protocol
is legal) and invisible to tests (nothing exercises the path). It is only visible by asking, of
each declared extension point, whether anything actually fills it in.

WHAT IT CHECKS
--------------
  A. Mutable static extension points (`static var …Factory/Handler/Provider/Sink/Seam`) that are
     referenced somewhere but have neither a default value nor any assignment.
  B. Protocols that are referenced in real code but have no conforming type anywhere.

WHAT IT DELIBERATELY DOES NOT FLAG, because each produced a false positive when this was done by
hand and a checker that cries wolf gets ignored:
  - a declaration carrying its own default (`static var x: T = { … }`) — that IS the wiring;
  - an Optional called defensively (`x?.foo()`), which degrades instead of trapping;
  - protocols with no references at all — those are dead code, a different and lesser problem;
  - anything whose declaration or call site carries a NOT-PORTED / M6 / M7 marker, i.e. a gap
    that someone has already written down. An acknowledged gap is not a seam.

Exit status is 0 when clean and 1 when anything is found, so it can gate CI.
"""

from __future__ import annotations

import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "swift", "Sources")

# A gap someone has already recorded is not an unwired seam; it is a plan.
ACKNOWLEDGED = re.compile(r"NOT[- ]PORTED|NOT PORTED|\bM6\b|\bM7\b|\bM8\b|\bM9\b|D11|deferred", re.I)

EXTENSION_POINT = re.compile(
    r"^\s*(?:public\s+|internal\s+)?static\s+var\s+"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_]*"
    r"(?:Factory|Handler|Provider|Providers|Sink|Seam|Hook|Installer))\b"
    r"(?P<rest>.*)$"
)

PROTOCOL_DECL = re.compile(r"^\s*(?:public\s+)?protocol\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)")


def swift_files() -> list[str]:
    out = []
    for base, _dirs, files in os.walk(ROOT):
        for f in files:
            if f.endswith(".swift"):
                out.append(os.path.join(base, f))
    return sorted(out)


def rel(path: str) -> str:
    return os.path.relpath(path, os.path.join(ROOT, "..", ".."))


def main() -> int:
    files = swift_files()
    blobs = {p: open(p, encoding="utf-8", errors="replace").read() for p in files}
    findings: list[str] = []

    # ---------------------------------------------------------------- A. extension points
    for path, text in blobs.items():
        lines = text.splitlines()
        for i, line in enumerate(lines):
            m = EXTENSION_POINT.match(line)
            if not m:
                continue
            name, rest = m.group("name"), m.group("rest")

            # A default value on the declaration is the wiring. Look at the declaration and the
            # two lines after it, since a closure default routinely wraps.
            window = " ".join(lines[i : i + 3])
            if "=" in rest or re.search(r"\bstatic var %s\b[^=\n]*=" % re.escape(name), window):
                continue

            context = " ".join(lines[max(0, i - 6) : i + 2])
            if ACKNOWLEDGED.search(context):
                continue

            assigned = refs = 0
            for other, blob in blobs.items():
                for ln in blob.splitlines():
                    if re.search(r"\b%s\b" % re.escape(name), ln):
                        if EXTENSION_POINT.match(ln):
                            continue
                        refs += 1
                        # `x = …`, `x[k] = …`, `x.append(…)` all count as filling it in.
                        if re.search(
                            r"\b%s\b\s*(\[[^\]]*\])?\s*=(?!=)|\b%s\b\s*\.\s*(append|insert|update)"
                            % (re.escape(name), re.escape(name)),
                            ln,
                        ):
                            assigned += 1
            # Optional called defensively degrades rather than trapping, not a live seam.
            optional = "?" in rest.split("//")[0]
            if assigned == 0 and refs > 0 and not optional:
                findings.append(
                    f"  UNWIRED  static var {name}  ({refs} references, 0 assignments, no default)\n"
                    f"           {rel(path)}:{i + 1}"
                )

    # ---------------------------------------------------------------- B. protocols
    #
    # Conformance is frequently INDIRECT, and missing that is how this check first produced 20
    # findings of which the loudest was wrong. `SimComponent` had 65 references and no apparent
    # conformer, yet simulation was passing 73.7% of its oracles: because
    # `protocol SimulatableComponent: Component, SimComponent` refines it and the concrete types
    # conform to *that*. A protocol reached through any chain of refinements is wired.
    refined_by: dict[str, set[str]] = {}
    direct: dict[str, int] = {}
    protocol_names: set[str] = set()

    for text in blobs.values():
        for ln in text.splitlines():
            m = PROTOCOL_DECL.match(ln)
            if m:
                protocol_names.add(m.group("name"))

    for text in blobs.values():
        for ln in text.splitlines():
            m = PROTOCOL_DECL.match(ln)
            if m:
                child = m.group("name")
                for parent in re.findall(r"[:,]\s*([A-Za-z_][A-Za-z0-9_]*)", ln.split("{")[0]):
                    refined_by.setdefault(parent, set()).add(child)
                continue
            # A COMMENTED conformance is not a conformance, and missing that made this checker
            # blind to four live seams: including `MemPainter`, the direct sibling of the io
            # painter seam it was written to catch. `Memory/MemPainter.swift:31` reads
            #
            #     //     extension InstancePainter: MemPainter {}
            #
            # as a header sample of the integration step somebody was supposed to perform. The
            # scan below does not strip comments, so that line registered as a real conformer
            # and `MemPainter` (55 references, nothing conforming) never appeared in the report.
            #
            # The shape is worth naming, because it is adversarial in the worst way: a file that
            # documents its own unwired seam *particularly well*: by showing the exact line
            # that would wire it; is the file most likely to be hidden from the check. The
            # better the comment, the more invisible the defect.
            #
            # This suppresses only `//`-prefixed lines. A conformance inside a `/* … */` block
            # would still fool it; no such case exists in the tree today and tracking block
            # comments would need a real lexer.
            stripped = ln.lstrip()
            if stripped.startswith("//"):
                continue
            # A concrete conformance: `struct X: P`, `final class X: A, P`, `extension X: P`.
            for p in re.findall(r"[:,]\s*([A-Za-z_][A-Za-z0-9_]*)", ln.split("{")[0]):
                if p in protocol_names and not re.search(
                    r"->\s*%s\b|\bany\s+%s\b|\[\s*%s\b" % ((re.escape(p),) * 3), ln
                ):
                    direct[p] = direct.get(p, 0) + 1

    def has_conformer(name: str, seen: set[str] | None = None) -> bool:
        """A protocol is wired if it, or anything refining it, has a concrete conformer."""
        seen = seen or set()
        if name in seen:
            return False
        seen.add(name)
        if direct.get(name, 0) > 0:
            return True
        return any(has_conformer(c, seen) for c in refined_by.get(name, ()))

    for path, text in blobs.items():
        lines = text.splitlines()
        for i, line in enumerate(lines):
            m = PROTOCOL_DECL.match(line)
            if not m:
                continue
            name = m.group("name")
            context = " ".join(lines[max(0, i - 6) : i + 2])
            if ACKNOWLEDGED.search(context):
                continue
            if has_conformer(name):
                continue

            refs = sum(
                1
                for blob in blobs.values()
                for ln in blob.splitlines()
                if re.search(r"\b%s\b" % re.escape(name), ln) and not PROTOCOL_DECL.match(ln)
            )
            # No references at all is dead code, not a seam; say nothing.
            if refs > 2:
                findings.append(
                    f"  NO CONFORMER  protocol {name}  ({refs} references, none conforming"
                    f" directly or through refinement)\n"
                    f"                {rel(path)}:{i + 1}"
                )

    print("seamcheck — declared, called, never implemented")
    print(f"  scanned {len(files)} Swift files\n")

    # ── "Scanned nothing" must not look like "found nothing" ────────────────────────────────
    #
    # tools/gateaudit.py pointed this one at an EMPTY tree. It printed "0 candidate seam(s)" and
    # exited 0: a clean pass, produced by looking at no code whatsoever. That is the exact
    # failure mode this project keeps paying for: a silent zero-output success is indistinguishable
    # from agreement, and it is how `rig.py`'s simulation mode reported 0/1392 for its entire life
    # without anyone noticing.
    #
    # A wrong ROOT is the realistic way to hit it; a moved directory, a run from the wrong cwd, a
    # renamed module. The floor is deliberately generous: the tree has ~570 Swift files, so
    # anything under 50 means the scan did not find the sources rather than that the sources
    # shrank.
    if len(files) < 50:
        print(
            f"  REFUSING TO REPORT: only {len(files)} Swift file(s) found under\n"
            f"    {os.path.abspath(ROOT)}\n"
            "  That is a broken scan, not a clean tree. Exiting nonzero so it cannot be mistaken\n"
            "  for a pass — a checker that examined nothing has not checked anything."
        )
        return 1

    # A RATCHET, not a gate.
    #
    # Most current findings are seams that someone has deliberately left open; a protocol whose
    # implementation is a later milestone, an audio sink waiting on the UI layer. Failing CI on
    # those would make the check permanently red, and a permanently red check is one people learn
    # to scroll past. What actually matters is whether the number GOES UP: a NEW unwired seam is
    # a regression, and that is worth stopping for.
    #
    # `--update-baseline` records the current set. Run it deliberately, after confirming the new
    # entries are intentional; never to silence a finding you have not read.
    baseline_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "seamcheck-baseline.txt")

    def key_of(finding: str) -> str:
        """Identity of a seam, deliberately excluding its reference count.

        The first version keyed on the whole headline, counts included, and immediately
        false-alarmed: `VhdlContentSaving` re-flagged as NEW because its reference count moved
        from 3 to 4 while the seam itself was unchanged. A ratchet that cries wolf on unrelated
        edits is one people learn to silence, which is worse than not having it.
        """
        head = finding.strip().split("\n")[0].strip()
        return re.sub(r"\s*\(\d+ references.*$", "", head)

    keys = sorted({key_of(f) for f in findings})

    if "--update-baseline" in sys.argv:
        with open(baseline_path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(keys) + ("\n" if keys else ""))
        print(f"  baseline updated: {len(keys)} known seam(s) recorded.")
        return 0

    known: set[str] = set()
    if os.path.exists(baseline_path):
        known = {ln.strip() for ln in open(baseline_path, encoding="utf-8") if ln.strip()}

    new = [f for f in findings if key_of(f) not in known]
    fixed = known - set(keys)

    for f in findings:
        marker = "NEW " if key_of(f) not in known else "    "
        print(marker + f.lstrip())

    print(f"\n  {len(findings)} candidate seam(s); {len(known)} were already known.")
    if fixed:
        print(f"  {len(fixed)} previously-known seam(s) are now wired — run --update-baseline.")
    print("  Each is a CANDIDATE, not a verdict: confirm by hand before acting. This checker")
    print("  has known false-positive shapes, and acting on an unverified finding is exactly")
    print("  how this project once dispatched work for a defect that did not exist.")

    if new:
        print(f"\n  {len(new)} NEW unwired seam(s) since the baseline — this is the regression case.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
