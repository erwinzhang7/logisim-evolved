#!/usr/bin/env python3
"""Regenerate tools/hdlbridge/boards-4.1.0.oracle from the shipped 4.1.0 jar.

Same shape as gen_oracle.py, but for the FPGA board model: it runs the REAL
`com.cburch.logisim.fpga.file.BoardReaderClass` over every board XML that ships
inside the jar and prints a canonical description of the resulting
`BoardInformation`. `LogisimHdlTests/BoardGateTests` diffs the Swift
`BoardReader` against it line for line.

    python3 tools/hdlbridge/gen_board_oracle.py                 # every board in the jar
    python3 tools/hdlbridge/gen_board_oracle.py TERASIC_DE0.xml # one board

Environment (same names the difftest rig uses):
    LOGISIM_JAVA    path to java   (default: Homebrew openjdk@21)
    LOGISIM_JAR     path to the 4.1.0 fat jar
"""

import os
import subprocess
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
CLASSES = os.path.join(HERE, "out")
SOURCE = os.path.join(HERE, "BoardBridge.java")
ORACLE = os.path.join(HERE, "boards-4.1.0.oracle")
MAIN = "com.cburch.logisim.fpga.file.BoardBridge"
PREFIX = "resources/logisim/boards/"

JAVA = os.environ.get("LOGISIM_JAVA", "/opt/homebrew/opt/openjdk@21/bin/java")
JAVAC = os.environ.get("LOGISIM_JAVAC", JAVA.replace("/java", "/javac"))
JAR = os.environ.get(
    "LOGISIM_JAR",
    "/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar")


def board_names(argv):
    if argv:
        return [n if n.startswith(PREFIX) else PREFIX + n for n in argv]
    with zipfile.ZipFile(JAR) as jar:
        return sorted(
            name for name in jar.namelist()
            if name.startswith(PREFIX) and name.endswith(".xml"))


def main(argv):
    if not os.path.exists(JAR):
        sys.exit(f"no jar at {JAR} — set LOGISIM_JAR")
    os.makedirs(CLASSES, exist_ok=True)
    subprocess.run([JAVAC, "-cp", JAR, "-d", CLASSES, SOURCE], check=True)

    names = board_names(argv)
    proc = subprocess.run(
        [JAVA, "-Djava.awt.headless=true", "-cp", f"{JAR}:{CLASSES}", MAIN],
        input="\n".join(names) + "\n", capture_output=True, text=True, check=True)
    with open(ORACLE, "w", encoding="utf-8") as handle:
        handle.write(proc.stdout)

    print(f"{ORACLE}: {len(names)} boards, "
          f"{proc.stdout.count('FAIL')} unreadable, "
          f"{proc.stdout.count(chr(10) + 'COMP ')} io components")


if __name__ == "__main__":
    main(sys.argv[1:])
