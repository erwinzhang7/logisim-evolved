#!/usr/bin/env python3
"""Regenerate the MIGRATION baselines with one JVM per file.

WHY THIS EXISTS — the batched baselines are contaminated, and it is upstream's bug
================================================================================

`canonical.py` feeds every corpus file through a single `CircBridge` JVM. It takes the
documented precaution of building a fresh `Loader` per file, and that is not enough:

    WiringLibrary.java:33   private static final Tool[] ADD_TOOLS = { new AddTool(...), ... }

The `AddTool` objects a builtin library publishes are **static**, JVM-global singletons,
shared by every `WiringLibrary` instance in the process. `XmlReader.toLibrary` writes the
`<lib><tool>` attribute values straight into them, and `XmlWriter.fromLibrary` writes back
every attribute that differs from the factory default. So tool state read from file A appears
in the saved form of file B. Every builtin library is built this way, not just `#Wiring`.

Measured, same jar, same two files, the only difference being whether one JVM or two:

    solo:              <lib desc="#Wiring"><tool name="Pin"/></lib>
    after the second file:    <lib desc="#Wiring"><tool name="Pin"/><tool name="Probe" facing=north/>
                                            <tool name="Pull Resistor" facing=north/>
                                            <tool name="Clock" facing=north/></lib>

Neither Probe, Pull Resistor nor Clock appears anywhere in the second file. The tool blocks
came from the first one.

This matters only for the MIGRATION condition. The canonical baselines are the fixed point of
repeated conversion, so whatever leaked is present in the canonical *input* too and the
condition stays self-consistent. The migration condition compares against the raw source, where
it is not, so the leaked blocks read as port defects — they were diagnosed as exactly that
("three missing <tool> blocks, 23 of 25 files") before this script existed.

One JVM per file costs ~1.2 s of startup each; separate processes share no statics, so unlike
`-n` (D17) this parallelises safely.

    LOGISIM_CORPUS=/path/to/corpus python3 solobaseline.py [--jobs 8]

Writes `$LOGISIM_CORPUS/canonical/migrated_solo/`, keyed by the same baseline names as
`_index.json`, plus `_leaked.json` listing the files whose batched baseline differed.
"""
import argparse, concurrent.futures as cf, json, os, subprocess, sys, tempfile

JAVA = os.environ.get("LOGISIM_JAVA", "/opt/homebrew/opt/openjdk@21/bin/java")
JAVAC = os.environ.get("LOGISIM_JAVAC", "/opt/homebrew/opt/openjdk@21/bin/javac")
JAR = os.environ.get(
    "LOGISIM_JAR",
    "/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar")
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BRIDGE_SRC = os.path.join(REPO, "tools", "valuebridge", "CircBridge.java")


def build_bridge(outdir):
    os.makedirs(outdir, exist_ok=True)
    subprocess.run([JAVAC, "-nowarn", "-cp", JAR, "-d", outdir, BRIDGE_SRC], check=True)
    return outdir


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--filter", default=None)
    args = ap.parse_args()

    corpus = os.environ.get("LOGISIM_CORPUS")
    if not corpus or not os.path.isdir(corpus):
        sys.exit("set LOGISIM_CORPUS")
    root = os.path.join(corpus, "canonical")
    index = json.load(open(os.path.join(root, "_index.json")))
    cases = list(index.items())
    if args.filter:
        import re
        rx = re.compile(args.filter)
        cases = [c for c in cases if rx.search(os.path.basename(c[0]))]

    classes = build_bridge(os.path.join(tempfile.gettempdir(), "circbridge-classes"))
    dest = os.path.join(root, "migrated_solo")
    os.makedirs(dest, exist_ok=True)
    cp = f"{JAR}:{classes}"

    def convert(src, out):
        p = subprocess.run(
            [JAVA, "-Djava.awt.headless=true", "-cp", cp, "com.cburch.logisim.file.CircBridge"],
            input=f"{src}\t{out}\n", capture_output=True, text=True, timeout=300)
        return any(line.startswith("OK\t") for line in p.stdout.splitlines())

    def one(case):
        # Converted TWICE, into different files, to separate "the port is wrong" from "no
        # byte-exact expectation exists". `XmlReader`'s label repair appends
        # `UUID.randomUUID().toString().substring(0, 8)` to any label that is not a valid VHDL
        # identifier, so a file carrying one converts differently every run; upstream cannot
        # reproduce its own output either. Verified directly: two solo runs of the same 2.7.0
        # file gave `Bn_1_0d85e8fb` and `Bn_1_e75327b0`.
        #
        # Such a file must be EXCLUDED with a reason, not counted as a failure. Counting it
        # makes the gate unreachable and hides how close the port actually is.
        src, base = case
        out = os.path.join(dest, base)
        probe = os.path.join(dest, "_probe_" + base)
        ok = convert(src, out)
        deterministic = True
        if ok and convert(src, probe):
            deterministic = open(out, "rb").read() == open(probe, "rb").read()
        if os.path.exists(probe):
            os.remove(probe)
        return base, ok, deterministic

    done = failed = 0
    nondeterministic = []
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for base, ok, deterministic in pool.map(one, cases):
            done += 1
            if not ok:
                failed += 1
                print(f"  FAIL {base}")
            elif not deterministic:
                nondeterministic.append(base)
            if done % 50 == 0:
                print(f"  {done}/{len(cases)}")
    json.dump(nondeterministic, open(os.path.join(dest, "_nondeterministic.json"), "w"), indent=1)
    print(f"{len(nondeterministic)} files have NO byte-exact expectation "
          f"(upstream's own output differs between two runs)")

    # Which batched baselines the leak actually corrupted.
    leaked = []
    for _, base in cases:
        a = os.path.join(root, "migrated", base)
        b = os.path.join(dest, base)
        if not os.path.exists(a) or not os.path.exists(b):
            continue
        if open(a, "rb").read() != open(b, "rb").read():
            leaked.append(base)
    json.dump(leaked, open(os.path.join(dest, "_leaked.json"), "w"), indent=1)
    print(f"\n{done} converted, {failed} failed")
    print(f"{len(leaked)} of {len(cases)} batched baselines differ from the solo one "
          f"(i.e. were contaminated)")


if __name__ == "__main__":
    main()
