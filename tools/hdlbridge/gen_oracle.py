#!/usr/bin/env python3
"""Regenerate tools/hdlbridge/netlist-4.1.0.oracle from the shipped 4.1.0 jar.

The oracle is what `LogisimHdlTests/NetlistGateTests` compares the Swift `Netlist`
against, line for line — including net ids, which become `s_LOGISIM_NET_<id>` in
generated HDL. It is checked in because the corpus is private and the jar is not a
build dependency; regenerate it whenever NetlistBridge.java changes or the corpus
grows.

    python3 tools/hdlbridge/gen_oracle.py            # whole harvested corpus
    python3 tools/hdlbridge/gen_oracle.py a.circ b.circ

Environment (same names the difftest rig uses):
    LOGISIM_JAVA    path to java            (default: Homebrew openjdk@21)
    LOGISIM_JAR     path to the 4.1.0 fat jar
    LOGISIM_CORPUS  corpus root; harvested/ underneath it is the default input set
"""

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CLASSES = os.path.join(HERE, "out")
SOURCE = os.path.join(HERE, "NetlistBridge.java")
ORACLE = os.path.join(HERE, "netlist-4.1.0.oracle")
MAIN = "com.cburch.logisim.fpga.designrulecheck.NetlistBridge"

JAVA = os.environ.get("LOGISIM_JAVA", "/opt/homebrew/opt/openjdk@21/bin/java")
JAVAC = os.environ.get("LOGISIM_JAVAC", JAVA.replace("/java", "/javac"))
JAR = os.environ.get(
    "LOGISIM_JAR",
    "/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar")


# A hand-written fixture, checked in beside this script, reaching three paths of
# Netlist.constructHierarchyTree that NO harvested circuit reaches: a subcircuit that itself
# contains bubbles, the same subcircuit instantiated twice (the only way to reach
# enumerateGlobalBubbleTree), and two levels of nesting. Measured on the harvested corpus: 0 of
# 153 DRC-passing circuits has any of the three, so without this the whole recursive half of the
# bubble tree is transcribed and never compared.
#
# Requested with an explicit circuit name because the bridge otherwise takes the FIRST circuit in
# the file, and `top` is deliberately last; the Swift reader has a known forward-reference
# defect (see NetlistGateTests.knownDivergences), so a fixture that leaned on forward references
# would be measuring that instead.
FIXTURE = (os.path.join(HERE, "bubbletree-fixture.circ"), "top")


def inputs(argv):
    if argv:
        return list(argv)
    root = os.environ.get("LOGISIM_CORPUS")
    if not root:
        sys.exit("set LOGISIM_CORPUS, or pass .circ paths explicitly")
    harvested = os.path.join(root, "harvested")
    paths = sorted(
        os.path.join(harvested, name)
        for name in os.listdir(harvested)
        if name.endswith(".circ"))
    return paths + ["\t".join(FIXTURE)]


def main(argv):
    if not os.path.exists(JAR):
        sys.exit(f"no jar at {JAR} — set LOGISIM_JAR")
    os.makedirs(CLASSES, exist_ok=True)
    subprocess.run([JAVAC, "-cp", JAR, "-d", CLASSES, SOURCE], check=True)

    paths = inputs(argv)
    # One JVM for the whole corpus: loading a LogisimFile costs ~0.9 s of startup, and
    # NetlistBridge is a stdin loop precisely so that is paid once.
    proc = subprocess.run(
        [JAVA, "-Djava.awt.headless=true", "-cp", f"{JAR}:{CLASSES}", MAIN],
        input="\n".join(paths) + "\n", capture_output=True, text=True, check=True)
    with open(ORACLE, "w", encoding="utf-8") as handle:
        handle.write(proc.stdout)

    passed = proc.stdout.count("\nDRC 0\n")
    failed = sum(proc.stdout.count(f"\nDRC {n}\n") for n in (1, 2, 3))
    print(f"{ORACLE}: {len(paths)} circuits, {passed} DRC-passing, {failed} not, "
          f"{proc.stdout.count('FAIL')} unloadable")


if __name__ == "__main__":
    main(sys.argv[1:])
