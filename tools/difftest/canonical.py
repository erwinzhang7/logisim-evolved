#!/usr/bin/env python3
"""Generate the canonical .circ forms that gate M2.

Two distinct pass conditions, both from upstream's own converter:

  MIGRATION   Swift load(f) -> save   must byte-match   convert(f)
  CANONICAL   Swift load(c) -> save   must byte-match   c, where c is the FIXED POINT

Conversion is not idempotent, and "apply it twice" is not enough. Loading a file sets tool
attribute state from the components it contains, and saving writes that state out, so each
round-trip can capture more of it. Measured over 541 corpus files:

    519 reach a fixed point at pass 2
     20 need pass 3
      2 NEVER converge

So the canonical form is computed by iterating until the output stops changing, not by a
fixed number of passes. Assuming two passes would have made 22 files fail the CANONICAL
condition against a port that was perfectly correct — Java does not reproduce its own output
there either.

The 2 non-converging files oscillate by pure REORDERING: the line multiset is identical, only
element order moves. That is non-determinism inside upstream's writer, so no byte-exact
expectation is possible for them and they are excluded with a reason rather than counted.

Uses CircBridge, NOT `-jar logisim.jar -n` (decisions.md D17).

`-n` routes through ProjectActions.doOpen, which builds a Frame and so needs a GUI. That made
it unusable here: every pre-2.7.2 file pops a modal "Old file format" warning (116 corpus
files), and every file naming a library 4.1.0 lacks pops "the built-in library X is not
available" (#MIPS Tools, #Yosys Components, #Risc-V — 39 more). Both block forever waiting for
a click from whoever is at the keyboard, and the earlier version of this script did exactly
that, twice.

CircBridge sets `Main.headless = true`, which turns every OptionPane dialog into a log line,
and loads through Loader + LogisimFile rather than the project layer. It also batches: one JVM
converts every pair, at ~0.15 s each rather than ~0.9 s. No version filter is needed any more,
so legacy files now get byte-exact goldens too — the files the migration passes exist for.

    LOGISIM_CORPUS=/path/to/corpus python3 canonical.py [--jobs N]
"""
import argparse, glob, hashlib, json, os, re, shutil, subprocess, sys

JAVA = os.environ.get("LOGISIM_JAVA", "/opt/homebrew/opt/openjdk@21/bin/java")
JAR = os.environ.get(
    "LOGISIM_JAR",
    "/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar")


def corpus_dir():
    d = os.environ.get("LOGISIM_CORPUS")
    if not d or not os.path.isdir(d):
        sys.exit("set LOGISIM_CORPUS to the corpus directory")
    return d


def circ_files(corpus):
    """Deduplicated: harvested/*.circ and harvested/* overlap completely."""
    seen, out = set(), []
    for pattern in ("*.circ", os.path.join("harvested", "*.circ"),
                    os.path.join("harvested", "*")):
        for p in glob.glob(os.path.join(corpus, pattern)):
            real = os.path.realpath(p)
            if real in seen or os.path.isdir(p):
                continue
            seen.add(real)
            out.append(p)
    return sorted(out)


DIALOG_GATE = (2, 7, 2)


def source_version(path):
    """The file's declared `source`, or None. A missing/unparseable one is 0.0.0 in Java."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            head = f.read(4096)
    except OSError:
        return None
    m = re.search(r'source="([^"]*)"', head)
    if not m:
        return (0, 0, 0)
    parts = re.match(r"(\d+)\.(\d+)\.(\d+)", m.group(1))
    return tuple(int(x) for x in parts.groups()) if parts else (0, 0, 0)


def triggers_dialog(path):
    """True if loading this file pops the modal old-format warning (XmlReader.java:405)."""
    v = source_version(path)
    return v is not None and v < DIALOG_GATE


BRIDGE_CLASSES = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                              "valuebridge", "out")


def convert_batch(pairs, timeout):
    """Convert every (src, dst) pair in ONE JVM. Returns {src: ok}."""
    if not pairs:
        return {}
    payload = "".join(f"{s}\t{d}\n" for s, d in pairs)
    try:
        p = subprocess.run(
            [JAVA, "-Djava.awt.headless=true", "-cp", f"{JAR}:{BRIDGE_CLASSES}",
             "com.cburch.logisim.file.CircBridge"],
            input=payload, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {s: False for s, _ in pairs}
    out = {}
    for line in p.stdout.splitlines():
        f = line.split("\t")
        if len(f) >= 2:
            out[f[1]] = f[0] == "OK"
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--timeout", type=int, default=1200, help="seconds for a whole batch")
    ap.add_argument("--limit", type=int, default=0, help="0 = whole corpus")
    ap.add_argument("--batch", type=int, default=100, help="files per JVM")
    ap.add_argument("--max-passes", type=int, default=8,
                    help="cap on fixed-point iterations")
    args = ap.parse_args()

    if not os.path.isdir(BRIDGE_CLASSES):
        sys.exit(f"CircBridge not built. Run:\n"
                 f"  cd ../valuebridge && javac -cp {JAR} -d out CircBridge.java")

    corpus = corpus_dir()
    out_mig = os.path.join(corpus, "canonical", "migrated")   # -n(f)
    out_can = os.path.join(corpus, "canonical", "canonical")  # -n(-n(f))
    for d in (out_mig, out_can):
        os.makedirs(d, exist_ok=True)

    files = circ_files(corpus)
    if args.limit:
        files = files[:args.limit]
    # No version filter: CircBridge sets Main.headless, so nothing pops a dialog (D17).
    print(f"{len(files)} corpus files", flush=True)

    def name_for(path):
        key = hashlib.sha256(os.path.abspath(path).encode()).hexdigest()[:12]
        return f"{os.path.basename(path)[:120]}__{key}"

    def run_pass(pairs, label):
        ok = {}
        for i in range(0, len(pairs), args.batch):
            chunk = pairs[i:i + args.batch]
            ok.update(convert_batch(chunk, args.timeout))
            done = min(i + args.batch, len(pairs))
            print(f"  {label}: {done}/{len(pairs)}", flush=True)
        return ok

    # PASS 1; original -> 4.1.0 format. This is the MIGRATION baseline.
    pass1 = [(p, os.path.join(out_mig, name_for(p))) for p in files]
    ok1 = run_pass(pass1, "pass1")
    survived = [p for p in files if ok1.get(p)]
    print(f"  pass1: {len(survived)}/{len(files)} converted", flush=True)

    # ITERATE TO A FIXED POINT for the CANONICAL baseline. Not a fixed pass count: 519 files
    # stabilise at pass 2, 20 need pass 3, and 2 never do.
    def sha(path):
        with open(path, "rb") as fh:
            return hashlib.sha256(fh.read()).hexdigest()

    work = {p: os.path.join(out_mig, name_for(p)) for p in survived}
    stable, oscillating = {}, []
    scratch = os.path.join(corpus, "canonical", "_iter")
    os.makedirs(scratch, exist_ok=True)

    for iteration in range(2, args.max_passes + 1):
        if not work:
            break
        pairs = [(cur, os.path.join(scratch, f"{iteration}__{name_for(p)}"))
                 for p, cur in work.items()]
        okn = run_pass(pairs, f"pass{iteration}")
        nxt = {}
        for p, cur in work.items():
            out = os.path.join(scratch, f"{iteration}__{name_for(p)}")
            if not okn.get(cur) or not os.path.exists(out):
                continue
            if sha(cur) == sha(out):
                stable[p] = cur          # converged: `cur` is the fixed point
            else:
                nxt[p] = out             # still moving
        print(f"  pass{iteration}: {len(stable)} stable, {len(nxt)} still moving", flush=True)
        work = nxt
    oscillating = list(work.keys())

    index = {}
    for p, fixed in stable.items():
        n = name_for(p)
        dest = os.path.join(out_can, n)
        shutil.copyfile(fixed, dest)
        index[os.path.abspath(p)] = n

    with open(os.path.join(corpus, "canonical", "_index.json"), "w") as f:
        json.dump(index, f, indent=1)
    failed = [os.path.basename(p) for p in files if not ok1.get(p)]
    with open(os.path.join(corpus, "canonical", "_failed.json"), "w") as f:
        json.dump(sorted(failed), f, indent=1)
    with open(os.path.join(corpus, "canonical", "_oscillating.json"), "w") as f:
        json.dump(sorted(os.path.basename(p) for p in oscillating), f, indent=1)

    print(f"\n{len(index)}/{len(files)} files have both forms -> {os.path.dirname(out_mig)}")
    if oscillating:
        print(f"{len(oscillating)} never reach a fixed point and are EXCLUDED from the "
              f"CANONICAL condition (see _oscillating.json). They differ only by element "
              f"ORDER between passes — identical line multiset — i.e. upstream's own writer "
              f"is non-deterministic for them, so no byte-exact expectation exists.")
    if failed:
        print(f"{len(failed)} could not be converted at all and are EXCLUDED from the gate "
              f"rather than counted as passing (see _failed.json). These are files upstream "
              f"itself cannot load — e.g. ones naming #MIPS Tools, a library 4.1.0 lacks.")


if __name__ == "__main__":
    main()
