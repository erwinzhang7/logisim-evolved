#!/usr/bin/env python3
"""Synthesize .circ fixtures exercising the migration gates no wild file covers.

577 harvested files cover gates <2.7.2 and <4.0.0 but contain ZERO files older than
2.6.3, leaving two XmlReader.considerRepairs branches untested. Those branches are
pure structural XML transforms keyed off source=, so a targeted fixture exercises
them more reliably than a random old file -- a genuine 2009 file might declare an
old version and never contain the structure the repair touches.

Fixtures are DERIVED from a known-good base file rather than hand-built. A
hand-built skeleton that is invalid in any way makes Logisim raise a modal error
dialog, which blocks forever with no output.

Each fixture asserts its transform ACTUALLY FIRED, not merely that the file loaded.
A fixture that loads without triggering its branch is a false pass, and a false pass
here is worse than no fixture at all.

These are synthesized rather than derived from private coursework, so unlike the
corpus they are safe to commit.

    python3 fixtures.py --base <a valid .circ> --out ../../tests/fixtures/migration
"""
import argparse, os, re, subprocess, sys

JAVA = os.environ.get("LOGISIM_JAVA", "/opt/homebrew/opt/openjdk@21/bin/java")
JAR = os.environ.get(
    "LOGISIM_JAR",
    "/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar")


# ---------------------------------------------------------------- transforms
def set_source(xml, version):
    return re.sub(r'(<project[^>]*?)\s*source="[^"]*"', rf'\1 source="{version}"', xml, count=1)


def drop_source(xml):
    """LogisimVersion.fromString on a non-matching string yields 0.0.0, which is
    below both gates but skips the 4.1.0-dev float repair (XmlReader.java:1076)."""
    return re.sub(r'\s*source="[^"]*"', "", xml, count=1)


def toolbar_to_pre_edit(xml):
    """Give the toolbar Select+Wiring and no Edit, the shape the <2.3.0 repair targets."""
    m = re.search(r"<toolbar>.*?</toolbar>", xml, re.S)
    if not m:
        raise SystemExit("base file has no <toolbar>")
    tb = m.group(0).replace('name="Edit Tool"', 'name="Select Tool"')
    if 'name="Select Tool"' not in tb or 'name="Wiring Tool"' not in tb:
        raise SystemExit("could not construct a Select+Wiring toolbar from the base")
    return xml[:m.start()] + tb + xml[m.end():]


def add_circuit_label_attrs(xml):
    """Circuit-level attrs whose name starts with 'label' are renamed to 'c'+name."""
    return re.sub(
        r'(<circuit name="[^"]*">)',
        r'\1\n    <a name="label" val="legacy-label"/>'
        r'\n    <a name="labelfont" val="SansSerif plain 12"/>',
        xml, count=1)


def add_legacy_library(xml):
    """#Legacy no longer exists in logisim-evolution -- that is precisely why the
    repair exists. Without it the file is unloadable, so this fixture also proves
    the repair is what makes the load succeed at all."""
    xml = re.sub(r"(\n  <main name=)", r'\n  <lib desc="#Legacy" name="99"/>\1', xml, count=1)
    return re.sub(r'(<circuit name="[^"]*">)',
                  r'\1\n    <comp lib="99" loc="(50,50)" name="Logger"/>',
                  xml, count=1)


# WHAT IS AND IS NOT SYNTHESIZABLE; established experimentally.
#
# CORRECTION. An earlier version of this comment claimed the <2.6.3 gate was
# uncoverable because "the repair corrupts a modern-structured file". That was wrong,
# and the reasoning was a measurement error: the test compared source="2.6.0" (hung)
# against source="3.6.1" (clean) and blamed the repair. In fact 2.6.0 is below the
# 2.7.2 threshold at XmlReader.java:405, which pops an unconditional modal
# "Old file format" warning, and 3.6.1 is above it. The hang was the dialog, not the
# repair; the two versions differed in a way that had nothing to do with the gate
# under test.
#
# Run HEADLESS, that dialog degrades to a log line and legacy files load fine, so both
# old gates are testable after all:
#
#   <2.3.0  via the missing-source= route. An absent source parses to 0.0.0
#           (LogisimVersion leaves 0/0/0 on a non-match), below both gates, and
#           XmlReader.java:1076 returns early so repairFloatLibrary is skipped.
#           Assertion: toolbar Select+Wiring becomes Edit.
#
#   <2.6.3  via #Legacy removal, which is destructive and therefore observable.
#           #Legacy no longer exists in logisim-evolution, so WITHOUT the repair the
#           library reference is unresolvable and the load reports
#           "library '99' not found"; WITH it, the lib and its components are stripped
#           and the file loads clean. Measured on one file with only source= varying:
#
#               source="2.6.0"  -> loads, only a WARN about the old format
#               source="3.6.1"  -> ERROR "library '99' not found [main.Logger((50,50))]"
#
#           That is a genuine discriminator: same content, opposite outcomes, and the
#           difference is exactly whether the repair ran.
#
# Verification uses headless `-tty` rather than `-n`. `-n` needs a GUI and blocks on the
# same dialog for every pre-2.7.2 file.

FIXTURES = [
    {
        "name": "gate_no_source_attr.circ",
        "gate": "<2.3.0 — toolbar Select+Wiring becomes Edit (via missing source= -> 0.0.0)",
        "build": lambda x: toolbar_to_pre_edit(drop_source(x)),
        "assert": lambda o: 'name="Edit Tool"' in o and 'name="Wiring Tool"' not in o,
        "explain": "expect Select renamed to Edit and Wiring Tool removed from the toolbar",
    },
]

# Retained as documentation of what was tried and why it fails. Enable with
# --include-blocked to re-test if a genuinely old-structured base file is ever found.
LEGACY_FIXTURES = [
    {
        "name": "gate_lt_2_6_3_legacy_headless.circ",
        "gate": "<2.6.3 — #Legacy library removal, verified headlessly",
        "build": lambda x: add_legacy_library(set_source(x, "2.6.0")),
        # The repair fired iff the load did NOT report an unresolvable library.
        "assert_load": lambda rc, err: rc == 0 and "not found" not in err,
        "control": lambda x: add_legacy_library(set_source(x, "3.6.1")),
        # Control: with the repair skipped, the SAME file must fail to resolve #Legacy.
        # Without this the assertion above would pass for a file that never had the lib.
        "assert_control": lambda rc, err: "not found" in err,
        "explain": "expect #Legacy stripped at 2.6.0, and unresolvable at 3.6.1",
    },
]

BLOCKED_FIXTURES = [
    {
        "name": "gate_lt_2_6_3_label.circ",
        "gate": "<2.6.3 — circuit label* renamed to clabel*",
        "build": lambda x: add_circuit_label_attrs(set_source(x, "2.6.0")),
        "assert": lambda o: 'name="clabel"' in o,
        "explain": "BLOCKED: the <2.6.3 repair corrupts a modern-structured base file",
    },
    {
        "name": "gate_lt_2_6_3_legacy.circ",
        "gate": "<2.6.3 — #Legacy library removal (destructive)",
        "build": lambda x: add_legacy_library(set_source(x, "2.6.0")),
        "assert": lambda o: "#Legacy" not in o and 'name="Logger"' not in o,
        "explain": "BLOCKED: same reason",
    },
]


def java_load_headless(path, timeout):
    """Load via headless `-tty`, returning (rc, stderr).

    Unlike `-n`, this works on pre-2.7.2 files: headless degrades OptionPane to a log
    line instead of a modal dialog. Load errors appear on stderr as
    "ERROR ... File Error:...", which is what makes the #Legacy repair observable.
    """
    try:
        p = subprocess.run([JAVA, "-Djava.awt.headless=true", "-jar", JAR,
                            "-tty", "table", os.path.basename(path)],
                           cwd=os.path.dirname(path) or ".",
                           capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stderr or "")
    except subprocess.TimeoutExpired:
        return None, "TIMEOUT"


def java_migrate(path, out_path, timeout):
    """`-n` is NOT headless-safe (it constructs an AWT Window), so it needs a GUI
    session. A timeout here almost always means an invalid file raised a modal
    error dialog, which blocks with no output."""
    try:
        p = subprocess.run([JAVA, "-jar", JAR, "-n", path, out_path],
                           capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stderr
    except subprocess.TimeoutExpired:
        return None, "timed out — the file probably raised a modal error dialog"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True, help="a known-good .circ to derive from")
    ap.add_argument("--out", required=True)
    ap.add_argument("--timeout", type=int, default=60)
    ap.add_argument("--include-blocked", action="store_true")
    args = ap.parse_args()

    base = open(args.base, encoding="utf-8").read()
    if "<project" not in base or "<toolbar>" not in base:
        sys.exit(f"{args.base} does not look like a usable base .circ")

    os.makedirs(args.out, exist_ok=True)
    expected = os.path.join(args.out, "expected")
    os.makedirs(expected, exist_ok=True)

    # Control: the UNMODIFIED base must convert cleanly. Without this, a fixture
    # failure could just mean the toolchain is broken.
    ctl_src = os.path.join(args.out, "_control_base.circ")
    open(ctl_src, "w").write(base)
    rc, err = java_migrate(ctl_src, os.path.join(expected, "_control_base.migrated.circ"),
                           args.timeout)
    if rc != 0:
        sys.exit(f"CONTROL FAILED on the unmodified base (rc={rc}): {err}\n"
                 "Fixture results would be meaningless; fix this first.")
    print("  ok    control: unmodified base converts cleanly\n")

    failures = 0
    fixtures = FIXTURES + (BLOCKED_FIXTURES if args.include_blocked else [])
    for f in fixtures:
        src = os.path.join(args.out, f["name"])
        open(src, "w").write(f["build"](base))
        dst = os.path.join(expected, f["name"].replace(".circ", ".migrated.circ"))
        rc, err = java_migrate(src, dst, args.timeout)
        if rc != 0 or not os.path.exists(dst):
            print(f"  FAIL  {f['name']}  rc={rc} {err.strip()[:90]}")
            failures += 1
            continue
        if f["assert"](open(dst).read()):
            print(f"  ok    {f['name']}\n        {f['gate']}")
        else:
            print(f"  FALSE-PASS  {f['name']} — loaded but the branch did NOT fire")
            print(f"        {f['explain']}")
            failures += 1

    # Headless-verified fixtures: a control/injection pair rather than an output diff.
    # The control matters; asserting only "the load succeeded" would pass for a file that
    # never contained the library the repair is supposed to strip.
    for f in LEGACY_FIXTURES:
        src = os.path.join(args.out, f["name"])
        open(src, "w").write(f["build"](base))
        rc, err = java_load_headless(src, args.timeout)

        ctl = os.path.join(args.out, f["name"].replace(".circ", "_control.circ"))
        open(ctl, "w").write(f["control"](base))
        crc, cerr = java_load_headless(ctl, args.timeout)

        fired = f["assert_load"](rc, err)
        control_ok = f["assert_control"](crc, cerr)
        if fired and control_ok:
            print(f"  ok    {f['name']}\n        {f['gate']}")
        else:
            print(f"  FAIL  {f['name']}")
            print(f"        repair fired: {fired} (rc={rc})")
            print(f"        control shows the repair is load-bearing: {control_ok} (rc={crc})")
            print(f"        {f['explain']}")
            failures += 1
        total = len(fixtures) + len(LEGACY_FIXTURES)

    total = len(fixtures) + len(LEGACY_FIXTURES)
    print(f"\n{total - failures}/{total} fixtures provably trigger their gate")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
