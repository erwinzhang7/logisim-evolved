#!/usr/bin/env python3
"""Differential gate for `logisim-cli --test-vector`, against the 4.1.0 jar.

    LOGISIM_CORPUS=/path/to/corpus python3 vectorgate.py

WHY THIS ONE NEEDS A BRIDGE WHERE `statsgate.py` DOES NOT
--------------------------------------------------------
`-tty stats` runs headlessly in the shipped jar, because `Startup.parseArgs` sets
`Main.headless = true` for any `-t`/`--tty` invocation. `--test-vector` does NOT set it, takes
the GUI branch of `Startup.run()`, and dies with a HeadlessException that `Main`'s own catch
block then re-throws while trying to display it — exit 1, nothing on stdout. So there is no way
to ask the shipped entry point what the right answer is.

`TestVectorBridge.java` sets `Main.headless = true` first (D17's switch, same as
tools/valuebridge/CircBridge.java) and calls the same `ProjectActions.doOpenNoWindow` +
`Project.doTestVector` the flag would have called. That runs to completion, and its captured
stdout is the oracle.

WHAT IS COMPARED
----------------
Upstream's raw stdout, byte for byte, base64'd through the bridge protocol so the per-row
progress counter's bare carriage returns survive the trip. The pass/fail counts are printed for
readability but are NOT the comparison: a port emitting the right two numbers with different
text would pass a numeric check.

THE EXIT CODE IS DELIBERATELY *NOT* COMPARED, and that is the point of the port. Upstream
discards `doTestVector`'s return (Startup.java:1029) and then runs
`if (exitAfterStartup) System.exit(0);` unconditionally, so the jar exits 0 whether every vector
passed or every vector failed. The port exits 1 when any vector fails. That divergence is
asserted by `CliTestVectorTests`, not here.

CASES
-----
Discovered from the corpus: every `*_test.txt` / `test.txt` beside a `.circ`, paired with every
circuit in that `.circ`. Most pairings are nonsense (wrong pin names, wrong widths) and the
oracle answers rc=-1 for them — WHICH IS ITSELF WORTH GATING, because the setup-failure path is
the one a TA hits first with a mislabelled submission.
"""
import argparse
import base64
import glob
import os
import re
import subprocess
import sys

JAVA = os.environ.get("LOGISIM_JAVA", "/opt/homebrew/opt/openjdk@21/bin/java")
JAR = os.environ.get(
    "LOGISIM_JAR",
    "/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar")
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
OUT = os.path.join(HERE, "out")
DEFAULT_CLI = os.path.join(REPO, "swift", ".build", "release", "logisim-cli")


def corpus_dir():
    d = os.environ.get("LOGISIM_CORPUS")
    if not d or not os.path.isdir(d):
        sys.exit("set LOGISIM_CORPUS to the corpus directory")
    return d


def circuits_in(path):
    try:
        src = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return []
    return list(dict.fromkeys(re.findall(r'<circuit name="([^"]+)"', src)))


def discover(corpus):
    """(circ path, circuit name, vector path) for every vector file beside a .circ."""
    cases = []
    for vector in sorted(glob.glob(os.path.join(corpus, "*test*.txt"))):
        head = open(vector, encoding="utf-8", errors="replace").readline()
        if "[" not in head and len(head.split()) < 2:
            continue  # not a vector header
        for circ in sorted(glob.glob(os.path.join(corpus, "*.circ"))):
            for name in circuits_in(circ):
                cases.append((circ, name, vector))
    return cases


def build_bridge():
    src = os.path.join(HERE, "TestVectorBridge.java")
    os.makedirs(OUT, exist_ok=True)
    p = subprocess.run([JAVA.replace("/java", "/javac"), "-cp", JAR, "-d", OUT, src],
                       capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(f"could not compile TestVectorBridge.java:\n{p.stderr}")


def run_bridge(cases, timeout):
    """One JVM for every case — the bridge batches, which is D17's other reason for existing."""
    stdin = "".join(f"{c}\t{n}\t{v}\n" for c, n, v in cases)
    p = subprocess.run(
        [JAVA, "-Djava.awt.headless=true", "-cp", f"{JAR}:{OUT}",
         "com.cburch.logisim.gui.start.TestVectorBridge"],
        input=stdin, capture_output=True, text=True, timeout=timeout)
    results = {}
    for line in p.stdout.splitlines():
        parts = line.split("\t")
        if parts[0] == "OK" and len(parts) >= 7:
            results[(parts[1], parts[2])] = {
                "rc": int(parts[5]),
                "stdout": base64.b64decode(parts[6]).decode("utf-8", "replace"),
            }
        elif parts[0] == "FAIL" and len(parts) >= 4:
            results[(parts[1], parts[2])] = {"rc": None, "error": parts[3]}
    return results, p.stderr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cli", default=DEFAULT_CLI)
    ap.add_argument("--timeout", type=int, default=600)
    ap.add_argument("--max-fail", type=int, default=10)
    args = ap.parse_args()

    corpus = corpus_dir()
    if not os.path.exists(args.cli):
        sys.exit(f"logisim-cli not built at {args.cli}\n"
                 "  swift build -c release --product logisim-cli\n"
                 "  (refusing to report a number: every case would 'fail' for this one reason)")
    build_bridge()

    cases = discover(corpus)
    if not cases:
        sys.exit("no (circ, circuit, vector) cases found in the corpus")
    print(f"{len(cases)} (circ, circuit, vector) case(s)  ·  cli={args.cli}\n")

    # The bridge is keyed by (circ, circuit), so one vector file per batch.
    by_vector = {}
    for circ, name, vector in cases:
        by_vector.setdefault(vector, []).append((circ, name, vector))

    passed = failed = setup_failed = 0
    shown = 0
    # ASSERT THE ORACLE SPOKE AT ALL. A bridge that produced no lines and exited 0 would leave
    # `results` empty, every case would be reported as "no oracle", and a naive version of this
    # loop would simply have nothing to compare and print a clean zero.
    produced_any = False

    for vector, group in sorted(by_vector.items()):
        results, stderr = run_bridge(group, args.timeout)
        if not results:
            print(f"  ORACLE PRODUCED NOTHING for {os.path.basename(vector)}\n{stderr[:800]}")
            continue
        produced_any = True
        for circ, name, _ in group:
            oracle = results.get((circ, name))
            if oracle is None:
                print(f"  no oracle line for {os.path.basename(circ)}::{name}")
                continue
            # BYTES, NOT text=True. `subprocess` in text mode applies universal-newline
            # translation, which rewrites the CLI's `\r` to `\n`, and upstream's per-row
            # progress counter is `System.out.print((row + 1) + " \r")`, so every case
            # "differed" in exactly those bytes on this gate's first run while the values all
            # matched. The oracle side arrives base64'd and is therefore untranslated, so the
            # harness was comparing translated output against untranslated output and blaming
            # the port. Decode explicitly, with newline handling off.
            p = subprocess.run(
                [args.cli, "--test-vector", name, vector, circ],
                capture_output=True, timeout=args.timeout)
            got = p.stdout.decode("utf-8", "replace")
            label = f"{os.path.basename(circ)}::{name} <- {os.path.basename(vector)}"

            if oracle["rc"] is None or oracle["rc"] == -1:
                # Upstream could not set the run up (bad width, no such pin, unreadable vector).
                # The port must also refuse, with 255.
                if p.returncode == 255:
                    setup_failed += 1
                else:
                    failed += 1
                    if shown < args.max_fail:
                        shown += 1
                        print(f"  FAIL {label}\n        oracle refused the setup "
                              f"(rc={oracle['rc']}) but the CLI exited {p.returncode}")
                continue

            if got == oracle["stdout"]:
                passed += 1
            else:
                failed += 1
                if shown < args.max_fail:
                    shown += 1
                    print(f"  FAIL {label}")
                    print(f"        java : {oracle['stdout']!r}")
                    print(f"        swift: {got!r}")

    print(f"\n{'=' * 56}")
    if not produced_any:
        print("  REFUSING TO REPORT A PASS: the bridge produced no output at all, so nothing "
              "was\n  actually compared.")
        return 1
    print(f"  byte-exact {passed}  ·  fail {failed}  ·  "
          f"setup refused by both {setup_failed}")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
