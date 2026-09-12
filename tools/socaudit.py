#!/usr/bin/env python3
"""Measure how the `#Soc` library block survives the M2 round-trip.

Not a gate — a probe, written to answer one question with a number: of the corpus files that
declare a non-empty `<lib desc="#Soc">`, how many does the Swift codec reproduce exactly in
that region, against the Java oracle's own output for the same file?

The Java baselines already exist in $LOGISIM_CORPUS/canonical/{migrated,canonical}; this only
re-runs the Swift side and compares the `#Soc` sub-tree, so a divergence elsewhere in the file
does not mask or manufacture a SoC finding.
"""
import os
import pathlib
import re
import subprocess
import sys
import tempfile

CORPUS = pathlib.Path(os.environ["LOGISIM_CORPUS"])
CLI = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path("swift/.build/debug/logisim-cli")

SOC_BLOCK = re.compile(r'( *<lib desc="#Soc".*?(?:/>|</lib>)\n)', re.S)

discriminating = 0


def soc_block(text):
    m = SOC_BLOCK.search(text)
    return m.group(1) if m else None


def main():
    import json
    src_dir = CORPUS / "harvested"
    mig_dir = CORPUS / "canonical" / "migrated"
    if not src_dir.is_dir():
        sys.exit(f"no harvested dir at {src_dir}")
    # The oracle filenames carry a content hash; _index.json is the only mapping from a source
    # path to its baseline name. Guessing the name is how a probe reports 0/0 and looks green.
    index = {pathlib.Path(k).name: v
             for k, v in json.loads((CORPUS / "canonical" / "_index.json").read_text()).items()}

    considered = same = differ = missing_oracle = swift_failed = 0
    empty_only = 0
    examples = []

    with tempfile.TemporaryDirectory() as td:
        for src in sorted(src_dir.iterdir()):
            if src.suffix != ".circ" and not src.name.endswith("f9ca4a59bcf7"):
                pass
            if src.name not in index:
                continue
            oracle = mig_dir / index[src.name]
            text = src.read_text(errors="replace")
            block = soc_block(text)
            if block is None:
                continue
            if "<tool" not in block:
                empty_only += 1
                continue
            considered += 1
            if not oracle.exists():
                missing_oracle += 1
                continue
            out = pathlib.Path(td) / "out.circ"
            r = subprocess.run([str(CLI), "--convert", str(src), str(out)],
                               capture_output=True, text=True)
            if r.returncode != 0 or not out.exists():
                swift_failed += 1
                continue
            got = soc_block(out.read_text(errors="replace"))
            want = soc_block(oracle.read_text(errors="replace"))
            # A file whose input block ALREADY equals the oracle's is satisfied by `cp`; it
            # proves nothing about the codec. Count the discriminating ones separately, the way
            # tools/gateaudit.py separates canonical from migration.
            global discriminating
            if block != want:
                discriminating += 1
            if got == want:
                same += 1
            else:
                differ += 1
                if len(examples) < 3:
                    examples.append((src.name, want, got))

    print(f"files with an EMPTY  <lib desc=\"#Soc\">: {empty_only}")
    print(f"files with a NON-EMPTY <lib desc=\"#Soc\">: {considered}")
    print(f"  of those, input block != oracle    : {discriminating}   <- the discriminating half")
    print(f"  soc block byte-identical to oracle : {same}")
    print(f"  soc block differs                  : {differ}")
    print(f"  no java oracle for the file        : {missing_oracle}")
    print(f"  swift --convert failed             : {swift_failed}")
    for name, want, got in examples:
        print(f"\n=== {name} ===\n--- java ---\n{want}--- swift ---\n{got}")


main()
