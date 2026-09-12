#!/usr/bin/env python3
"""Run the jar's `halt`/`speed` formats on every corpus circuit that owns a `halt` pin.

This exists to answer one question with evidence instead of taste: is it worth porting
`-tty speed` and `-tty halt`?

`TtyInterface.run` sends a case to `runSimulation` only when the circuit has an output
pin labelled exactly "halt" (or when no FORMAT_TABLE bit is set, in which case the loop
has no exit condition at all and runs forever). `find_halt.py` enumerates that
population. This script then actually runs each one against the 4.1.0 jar, bounded, and
prints what the oracle does.
"""
import os
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))
import corpus  # noqa: E402

JAVA = "/opt/homebrew/opt/openjdk@21/bin/java"
JAR = ("/Applications/Logisim-evolution.app/Contents/app/"
       "logisim-evolution-4.1.0-all.jar")
CORPUS = os.environ.get("LOGISIM_CORPUS")
if not CORPUS:
    sys.exit("LOGISIM_CORPUS is unset; these six cases live in the corpus")

# Handles, not filenames: see `tools/corpus.py`. `find_halt.py` is what found them.
CASES = [
    ("2.7.1__case-162.circ", "control unit"),
    ("2.7.1__case-162.circ", "main"),
    ("2.7.2__case-056.circ", "main"),
    ("3.3.0__case-216.circ", "main"),
    ("3.6.1__case-036.circ", "control_unit"),
    ("3.6.1__case-373.circ", "ControlLogic"),
]

TIMEOUT = float(os.environ.get("TTYBRIDGE_TIMEOUT", "40"))


def classify(stderr: str) -> str:
    if "HeadlessException" in stderr and "JFileChooser" in stderr:
        return "UNLOADABLE (missing sub-library; jar pops a file chooser)"
    if "Error loading circuit file" in stderr:
        return "UNLOADABLE"
    return ""


def main():
    for handle, circ in CASES:
        path = os.path.join(CORPUS, corpus.resolve(handle, CORPUS))
        cmd = [JAVA, "-Djava.awt.headless=true", "-jar", JAR,
               "--toplevel-circuit", circ, "-tty", "halt,speed",
               os.path.basename(path)]
        label = f"{os.path.basename(path)}::{circ}"
        try:
            p = subprocess.run(cmd, cwd=os.path.dirname(path), capture_output=True,
                               text=True, timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            print(f"  TIMEOUT({TIMEOUT:g}s)  {label}")
            continue
        note = classify(p.stderr)
        out = p.stdout.strip().replace("\n", " | ")
        print(f"  exit {p.returncode:<4} {label}")
        if note:
            print(f"           {note}")
        if out:
            print(f"           stdout: {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
