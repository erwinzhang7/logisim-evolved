#!/usr/bin/env python3
"""Assert the module dependency edges that merges keep silently reverting.

WHY THIS EXISTS
---------------
`swift/Package.swift` has been reverted **three times** by branch merges, each time dropping a
dependency edge a previous merge had added, and each time the loss was found only by building.
The mechanism is not carelessness: every agent worktree is cut from a base that predates the
edge, so the branch carries an older copy of the file, and resolving its add/add conflict "in the
branch's favour" — which is correct for the branch's own new files — silently reverts the shared
one.

The edges below are not stylistic. Each was added to fix a specific failure, and losing one
reintroduces exactly that failure:

  LogisimFile -> LogisimDraw
      A circuit's `<appear>` section IS a shape model. `CircuitAppearanceReader`/`Writer` need
      `AppearanceAnchor`, `AppearancePort` and the SVG reader, which live in LogisimDraw. Without
      the edge: "cannot find type 'AppearanceAnchor' in scope".
      Safe only because LogisimDraw depends on LogisimKernel alone — geometry, not drawing — so
      the headless CLI does not acquire CoreGraphics through it. If LogisimDraw ever gains a
      LogisimRender dependency, THIS EDGE MUST BE RECONSIDERED, not merely kept.

  LogisimStd -> LogisimRender
      D6: a component paints by emitting primitives into a RenderScene. Without the edge no
      component can construct a SceneBuilder and the renderer is unreachable scaffolding.

  logisim-cli -> LogisimSoc
      `#Soc`'s factories live in LogisimSoc, which depends on LogisimStd, so
      `StdLibraries.registerAll()` cannot reach back to register them. Only an executable can, so
      the CLI must link it. Without the edge: "cannot find 'SocLibrary' in scope".

Run standalone or from tools/ci.sh. Exit 1 if any required edge is missing.
"""

from __future__ import annotations

import os
import re
import sys

MANIFEST = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "swift", "Package.swift"
)

# (target, dependency, one-line reason shown when it is missing)
REQUIRED: list[tuple[str, str, str]] = [
    ("LogisimFile", "LogisimDraw",
     "CircuitAppearanceReader/Writer need the <appear> shape model"),
    ("LogisimStd", "LogisimRender",
     "D6: components emit primitives into a RenderScene"),
    ("LogisimStd", "LogisimFile",
     "a factory reads and writes its own attributes from a .circ"),
    ("logisim-cli", "LogisimSoc",
     "only an executable can register #Soc; the arrow cannot point back"),
    ("logisim-cli", "LogisimStd",
     "the writer needs builtin defaults to tell default from user-modified"),

    # Added 2026-09-05. `HdlGeneratorLookup.registerAllBuiltins` was installed with all 40
    # component registrations and NOTHING COULD CALL IT: no shipping target linked LogisimHdl, so
    # `LogisimHdlTests` was the only place in the package that could see both modules, and a test
    # target is not a runtime.
    #
    # The bindings read real LogisimStd attributes, so the builder cannot live in LogisimHdl
    # (which must never depend on LogisimStd; that closes the cycle the per-component generators
    # need) nor in LogisimStd. `LogisimHdlWiring` exists above both, and these two edges are what
    # make the registry reachable from something that actually runs.
    ("LogisimHdlWiring", "LogisimHdl",
     "the bindings builder is the one thing that sees both Std and Hdl"),
    ("LogisimHdlWiring", "LogisimStd",
     "bindings read Comparator.modeAttr, Shifter.attrShift, StdAttr.label, Pla, MemContents"),
    ("logisim-cli", "LogisimHdlWiring",
     "a registration in one executable's main is one the other executable silently lacks"),
    ("LogisimUI", "LogisimHdlWiring",
     "the app must register HDL generators too, not just the CLI"),

    # Added 2026-09-06 after asking of EVERY module "what in the shipping app imports this".
    # Three answers were nothing at all, totalling 115 files of ported and gated functionality
    # the application could not reach -- the seam pattern at module scale, and invisible to every
    # other check because each module built, tested and passed its own gates in isolation.
    ("LogisimStd", "LogisimDraw",
     "a subcircuit's custom <appear> shape cannot be painted without the shape model"),
    ("LogisimUI", "LogisimAnalyze",
     "22 files: upstream's headline Analyze Circuit feature, reachable from nothing"),
    ("LogisimUI", "LogisimSoc",
     "82 files: the GUI could not place a single #Soc component; only the CLI linked it"),
    ("LogisimUI", "LogisimVhdl",
     "11 files: VHDL entity support, reachable from nothing"),

    # Added 2026-09-06 for board #64. `AnalyzeSyntaxChecker.hdlKeywordCheck` is a DOCUMENTED
    # divergence, not an oversight: unset, the CSV importer accepts a variable named `signal` or
    # `wire` that upstream rejects. `LogisimAnalyze` must not depend on `LogisimHdl`, so the join
    # belongs to whoever links both, and LogisimUI reached LogisimHdl only TRANSITIVELY, through
    # LogisimHdlWiring. SwiftPM allows that import, so it compiled; an edge nothing declares is
    # one the next dependency cleanup deletes without a failing build.
    ("LogisimUI", "LogisimHdl",
     "CorrectLabel.hdlCorrectLabel is the only thing that can fill AnalyzeSyntaxChecker's seam"),

    # Added 2026-09-05. There was NO app product until this date: LogisimEvolvedApp.swift was
    # complete and the manifest declared only libraries plus logisim-cli, so nothing built an app
    # bundle and the entire UI half had never been run once. Every LogisimUITests result is a
    # library-level result -- real, but not evidence the app launches. Losing this edge returns
    # the project to that state silently, because a library that compiles looks identical to a
    # program that runs.
    ("logisim-evolved-app", "LogisimUI",
     "without it there is no app bundle and the UI half is unrunnable"),
]

# Test targets whose absence is invisible: SPM SILENTLY OMITS a test target whose directory has
# no sources rather than erroring, so an unregistered suite looks exactly like a passing one.
REQUIRED_TEST_TARGETS = [
    "LogisimKernelTests", "LogisimFileTests", "LogisimStdTests",
    "LogisimRenderTests", "LogisimDrawTests", "LogisimVhdlTests",
    "LogisimAnalyzeTests", "LogisimUITests",
    # Added 2026-09-05. `LogisimHdlTests` had been declared in the manifest and NOT listed here,
    # so the one guard against SPM's silent omission did not cover it, while it holds the four
    # component families' jar oracles, the FPGA board gate and the netlist gate, which is most of
    # the HDL evidence in the project. Found by tools/gateaudit.py, which cross-checks this list
    # against the manifest rather than trusting it; a hand-maintained list of things that must exist
    # silently stops covering whatever is added after it was written.
    "LogisimHdlTests",
    # Added 2026-09-05 with the LogisimRender split. Unguarded for the length of one commit,
    # and gateaudit caught it in that window -- which is the point of cross-checking this list
    # against the manifest rather than trusting it to be maintained.
    "LogisimRenderBackendTests",
    # Added 2026-09-05. Requested by the agent that built the wiring target, which noticed that
    # without a target of its own its two suites had to test COPIES of the code rather than the
    # code -- a hand-rebuilt ROM reader closure, and a source scan standing in for a call.
    "LogisimHdlWiringTests",
    "LogisimSocTests",
]


def target_blocks(text: str) -> dict[str, str]:
    """Map each target name to the text of its declaration.

    A target's block runs from its `name:` to the start of the NEXT target declaration, rather
    than a fixed number of characters.

    The fixed window was 400 chars, and it broke the moment a target grew an explanatory comment
    between `name:` and `dependencies:` — three real edges reported MISSING while sitting in the
    file. `tools/gateaudit.py` had already flagged the window as a hazard and noted it fails
    safe (a false alarm rather than a false pass); it does, and a checker that cries wolf is one
    people learn to silence, which is the failure mode after that. Worse, the window could also
    read INTO a neighbouring target and answer an edge from the wrong dependency list — a false
    PASS, which is unrecoverable.
    """
    starts = [(m.start(), m.group(1))
              for m in re.finditer(r'name:\s*"([A-Za-z0-9_-]+)"', text)]
    blocks: dict[str, str] = {}
    for i, (pos, name) in enumerate(starts):
        end = starts[i + 1][0] if i + 1 < len(starts) else len(text)
        blocks[name] = text[pos:end]
    return blocks


def main() -> int:
    if not os.path.exists(MANIFEST):
        print(f"graphcheck: no manifest at {MANIFEST}")
        return 1
    text = open(MANIFEST, encoding="utf-8").read()
    blocks = target_blocks(text)
    missing: list[str] = []

    for target, dep, why in REQUIRED:
        block = blocks.get(target)
        if block is None:
            missing.append(f"  target {target!r} is not declared at all")
            continue
        deps = re.search(r"dependencies:\s*\[(.*?)\]", block, re.S)
        listed = deps.group(1) if deps else ""
        if f'"{dep}"' not in listed:
            missing.append(f"  {target} -> {dep}   MISSING — {why}")

    for name in REQUIRED_TEST_TARGETS:
        if f'name: "{name}"' not in text:
            missing.append(
                f"  test target {name} is not declared — SPM omits an unregistered suite"
                " silently, so it looks identical to a passing one"
            )

    print("graphcheck — module dependency edges that merges keep reverting")
    if missing:
        print()
        for m in missing:
            print(m)
        print(
            f"\n  {len(missing)} missing. This file has been reverted three times by merges;"
            "\n  every in-flight branch carries an older copy, so resolving its conflict in the"
            "\n  branch's favour silently drops whatever the previous merge added."
            "\n  Merge swift/Package.swift BY HAND, never wholesale."
        )
        return 1
    print(f"  all {len(REQUIRED)} edges and {len(REQUIRED_TEST_TARGETS)} test targets present.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
