#!/usr/bin/env python3
"""Run one jar invocation under a wall-clock timeout and report exit code + streams.

macOS ships no `timeout(1)`, and `-tty speed`/`-tty halt` on a circuit with no `halt`
pin never terminate (TtyInterface.runSimulation loops `while (true)` and only leaves
on a halt pin or an oscillation). So every probe here is bounded, and a run that hits
the bound is reported as such rather than left to look like a hang in the transcript.

    python3 probe.py [--timeout N] -- <java args...>
"""
import argparse
import subprocess
import sys

JAVA = "/opt/homebrew/opt/openjdk@21/bin/java"
JAR = ("/Applications/Logisim-evolution.app/Contents/app/"
       "logisim-evolution-4.1.0-all.jar")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--timeout", type=float, default=20.0)
    ap.add_argument("--cwd", default=None)
    ap.add_argument("rest", nargs=argparse.REMAINDER)
    args = ap.parse_args()
    rest = args.rest[1:] if args.rest and args.rest[0] == "--" else args.rest
    cmd = [JAVA, "-Djava.awt.headless=true", "-jar", JAR] + rest
    try:
        p = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=args.timeout, cwd=args.cwd)
    except subprocess.TimeoutExpired as e:
        print(f"TIMEOUT after {args.timeout}s — the jar did not terminate")
        print("--- stdout (partial) ---")
        sys.stdout.write((e.stdout or b"").decode(errors="replace")[-2000:])
        print("--- stderr (partial) ---")
        sys.stdout.write((e.stderr or b"").decode(errors="replace")[-2000:])
        return 124
    print(f"EXIT={p.returncode}")
    print("--- stdout ---")
    sys.stdout.write(p.stdout)
    print("--- stderr ---")
    sys.stdout.write(p.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
