#!/usr/bin/env python3
"""M7's pass condition: scripted interaction sequences whose saved .circ byte-matches Java.

Every other subsystem in this port is gated against the 4.1.0 jar — the codec byte-exactly over
541 corpus files, simulation byte-exactly over 1,347 truth tables, HDL and stats likewise.
**Editing was the one subsystem with no parity gate at all.** It is tested piecemeal and well
(`Tests/LogisimUITests/WireRepairComponentTests.swift` drives real `.down`/`.dragged`/`.up`
events into `CanvasInteractionHandler`), but nothing proved that a *sequence* of edits produces
the file Java would produce. A GUI that looks right and writes subtly different .circ files is
exactly what this exists to catch.

    # 1. build the oracle (once, and after any change to tools/editbridge)
    sh tools/editbridge/build.sh

    # 2. generate the Java baselines
    python3 tools/difftest/editparity.py --regenerate

    # 3. gate: diff the Swift editor against them
    swift test --filter EditParity          # from swift/, the same comparison in-process
    python3 tools/difftest/editparity.py    # or here, against a saved Swift run

Exit 0 only if every script matches. Anything else is a red gate.

**The authoritative gate is the Swift test**, because it is what `swift test` and CI run. It
carries the `knownDivergences` table — the divergences this gate has already found and reported,
each with the exact defect — and marks exactly those as known issues, so that they still print
their diff and still fail if they ever start passing. This script has no such table on purpose: it
is the raw comparison, and it exits nonzero for every mismatch including the known ones. If the
two disagree on a count, that is the table, not a bug.

── HOW THE TWO SIDES ARE DRIVEN ────────────────────────────────────────────────────────────────

Java: `tools/editbridge/EditBridge.java`. Loads the seed with the real `Loader`, builds a real
`Project` and `Canvas`, and dispatches each scripted gesture to the real `Tool` — `AddTool`,
`WiringTool`, `EditTool` (which owns `SelectTool`) — so the edits land through
`CircuitMutation` / `Project.doAction` / `CircuitTransaction` exactly as a click would. Its header
documents the three places headlessness had to be bought and what each cost.

Swift: `swift/Tests/LogisimUITests/EditParityTests.swift`. Same script, same seed, driven through
`CircuitEditorCanvas` and `CanvasInteractionHandler` — the shipping editor, not the model. That
constraint is the whole point: a test that called `circuit.mutatorAdd` would pass against exactly
the version worth rejecting.

── MASKING ─────────────────────────────────────────────────────────────────────────────────────

The same discipline as `rig.py`, and **no new forgiveness**. Two classes of the jar's own
non-determinism are known and are masked on BOTH sides so a real body divergence still fails:

  * `XmlReader.generateValidVHDLLabel`'s random 8-hex UUID suffix.
  * `Font.getFamily()` resolving an unavailable family to whatever the host has.

Neither can arise from these scripts — the seed names no font and no illegal VHDL label, and the
placed components carry no labels — so if either mask ever fires here it is reported loudly rather
than folded into the pass count. A diff that is not one of these classes is a failure, full stop.

Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
"""
import argparse
import difflib
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
BRIDGE = os.path.join(REPO, "tools", "editbridge")
SCRIPTS = os.path.join(BRIDGE, "scripts")
SEED = os.path.join(BRIDGE, "fixtures", "seed.circ")
GOLDEN = os.path.join(BRIDGE, "golden")

JAVA = os.environ.get("LOGISIM_JAVA", "/opt/homebrew/opt/openjdk@21/bin/java")
JAR = os.environ.get(
    "LOGISIM_JAR",
    "/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar")


def scripts():
    return sorted(
        os.path.join(SCRIPTS, n) for n in os.listdir(SCRIPTS) if n.endswith(".script"))


def run_bridge(pairs, timeout=600):
    """Apply every (script, out) pair in ONE JVM. Returns {script: (ok, detail)}.

    ONE JVM IS SAFE HERE, AND THAT IS NOT OBVIOUS — it is the opposite of the migration gate,
    where batching files through a single `CircBridge` JVM silently contaminated baselines twice
    (`WiringLibrary.java:33` holds a `private static final Tool[]`, so tool state is JVM-global;
    hence `rig.py` scores against `canonical/migrated_solo/`). Someone will reasonably assume the
    same hazard applies here. Measured 2026-09-06, two ways, and it does not:

      * every script regenerated ALONE in its own JVM produced output byte-identical to the
        batched run, for all 15 scripts;
      * and the adverse ordering was forced deliberately: `10-tool-attributes`, the one script
        that exists to WRITE tool attributes, run FIRST and then `01-place-gate` in the same JVM.
        `01` still matched its solo baseline exactly.

    The reason is structural rather than lucky: EditBridge calls `loader.openLogisimFile(seed)`
    per pair, so every script gets its own `LogisimFile` and its own `AddTool` instances, and the
    tool attribute sets a script mutates die with it. The alphabetical ordering that currently
    puts script 10 last is therefore NOT what is protecting this.

    If that per-pair reload is ever hoisted out of the loop to save time, this property dies
    silently and the gate starts scoring scripts against a contaminated JVM. Re-run the two
    measurements above before believing any speedup here.
    """
    classes = os.path.join(BRIDGE, "out")
    if not os.path.isdir(classes):
        sys.exit(f"EditBridge is not built. Run:\n  sh {os.path.join(BRIDGE, 'build.sh')}")
    payload = "".join(f"{s}\t{SEED}\t{d}\n" for s, d in pairs)
    proc = subprocess.run(
        [JAVA,
         "-Djava.awt.headless=true",
         # See MemoryPreferences: keeps the oracle off the developer's real Logisim settings,
         # in both directions.
         "-Djava.util.prefs.PreferencesFactory=MemoryPreferences$Factory",
         "-cp", f"{JAR}:{classes}",
         "com.cburch.logisim.file.EditBridge"],
        input=payload, capture_output=True, text=True, timeout=timeout)
    results = {}
    for line in proc.stdout.splitlines():
        f = line.split("\t")
        if len(f) >= 2:
            results[f[1]] = (f[0] == "OK", f[2] if len(f) > 2 else "")
    # A bridge that writes nothing and exits 0 looks exactly like agreement. This project has
    # been caught by that twice (rig.py's header, nondet.py's `crash` bucket), so the absence of
    # a reply line is an error, not a pass.
    for script, _ in pairs:
        results.setdefault(script, (False, f"no reply from the bridge; stderr: {proc.stderr[-400:]}"))
    return results


# ── Masking, identical to rig.py's rules ────────────────────────────────────────────────────

VHDL_LABEL_SUFFIX = re.compile(r"_[0-9a-f]{8}(?![0-9a-zA-Z_])")
FONT_ATTR = re.compile(r'(<a name="(?:font|labelfont|clabelfont)" val=")([^"]*?)( \w+ \d+"/>)')


def mask(text):
    """Returns (masked, [classes that actually fired])."""
    fired = []
    if VHDL_LABEL_SUFFIX.search(text):
        fired.append("vhdl-label")
        text = VHDL_LABEL_SUFFIX.sub("_HASH", text)
    if FONT_ATTR.search(text):
        fired.append("font")
        text = FONT_ATTR.sub(r"\1FAMILY\3", text)
    return text, fired


def compare(want_path, got_path):
    want = open(want_path, encoding="utf-8").read()
    got = open(got_path, encoding="utf-8").read()
    if want == got:
        return True, [], ""
    mwant, fw = mask(want)
    mgot, fg = mask(got)
    fired = sorted(set(fw) | set(fg))
    if mwant == mgot:
        return True, fired, ""
    diff = "\n".join(
        difflib.unified_diff(
            want.splitlines(), got.splitlines(),
            fromfile="java-4.1.0", tofile="swift-port", lineterm="", n=2))
    return False, fired, diff


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--regenerate", action="store_true",
                    help="(re)build the Java baselines in tools/editbridge/golden")
    ap.add_argument("--swift-out", default=None,
                    help="directory of Swift-produced .circ files, one per script, named "
                         "<script-stem>.circ. Compares them against the baselines.")
    ap.add_argument("--filter", default=None, help="regex over the script name")
    args = ap.parse_args()

    selected = scripts()
    if args.filter:
        pattern = re.compile(args.filter)
        selected = [s for s in selected if pattern.search(os.path.basename(s))]
    if not selected:
        sys.exit("no scripts selected")

    os.makedirs(GOLDEN, exist_ok=True)

    if args.regenerate:
        pairs = [(s, os.path.join(GOLDEN, os.path.basename(s)[:-7] + ".circ")) for s in selected]
        results = run_bridge(pairs)
        bad = [(s, d) for s, (ok, d) in results.items() if not ok]
        for s, detail in bad:
            print(f"  FAIL {os.path.basename(s)}: {detail}")
        print(f"{len(selected) - len(bad)}/{len(selected)} baselines written -> {GOLDEN}")
        return 1 if bad else 0

    if not args.swift_out:
        sys.exit("nothing to compare: pass --swift-out DIR, or --regenerate to build baselines.\n"
                 "The in-process comparison lives in "
                 "swift/Tests/LogisimUITests/EditParityTests.swift.")

    passed, failed, masked = 0, [], []
    for script in selected:
        stem = os.path.basename(script)[:-7]
        want = os.path.join(GOLDEN, stem + ".circ")
        got = os.path.join(args.swift_out, stem + ".circ")
        if not os.path.exists(want):
            failed.append((stem, "no baseline; run --regenerate"))
            continue
        if not os.path.exists(got):
            failed.append((stem, "the Swift side produced no file"))
            continue
        ok, fired, diff = compare(want, got)
        if fired:
            masked.append((stem, fired))
        if ok:
            passed += 1
        else:
            failed.append((stem, diff))

    for stem, detail in failed:
        print(f"\n══ {stem} ═══════════════════════════════════════════════")
        print(detail)
    if masked:
        print("\nMASKS FIRED — investigate, these scripts should not be able to trigger them:")
        for stem, fired in masked:
            print(f"  {stem}: {', '.join(fired)}")
    print(f"\n{passed}/{len(selected)} scripts byte-match 4.1.0")
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
