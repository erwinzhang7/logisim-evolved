#!/usr/bin/env python3
"""Task #16, the oracle half: iterate UPSTREAM's converter to a fixed point, one JVM per pass.

`canonical.py`'s "519 stable at pass 2, 20 need pass 3, 2 never converge" is NOT a measurement
of upstream idempotence, and reading it as one is what makes task #16's premise wrong. That run
batched every file through a single JVM, and `solobaseline.py` documents why that is
contaminated: the `AddTool` objects a builtin library publishes are JVM-global statics
(`WiringLibrary.java:33`), so tool state read from file A appears in the saved form of file B.
The iteration therefore measured leak convergence, not idempotence.

This script measures idempotence the only way that is sound: **a fresh JVM for every single
conversion**, so no static state crosses either files or passes.

    pass1 = jar(f)          pass2 = jar(pass1)          pass3 = jar(pass2)   ...

    upstream idempotent on f  <=>  pass2 == pass1

Then it does the same for the port and reports, per file, whether the two agree at every pass.
Byte-for-byte agreement with upstream — including where upstream is non-idempotent — is the
condition the M2 migration gate actually measures, so disagreement is the finding, not
non-idempotence itself.

    LOGISIM_CORPUS=/path/to/corpus \\
      python3 idemoracle.py --cli /path/to/logisim-cli [--jobs 8] [--passes 4]
"""
import argparse, concurrent.futures as cf, glob, hashlib, json, os, subprocess, sys

JAVA = os.environ.get("LOGISIM_JAVA", "/opt/homebrew/opt/openjdk@21/bin/java")
JAVAC = os.environ.get("LOGISIM_JAVAC", "/opt/homebrew/opt/openjdk@21/bin/javac")
JAR = os.environ.get(
    "LOGISIM_JAR",
    "/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar")
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BRIDGE_SRC = os.path.join(REPO, "tools", "valuebridge", "CircBridge.java")


def corpus_dir():
    d = os.environ.get("LOGISIM_CORPUS")
    if not d or not os.path.isdir(d):
        sys.exit("set LOGISIM_CORPUS to the corpus directory")
    return d


def circ_files(corpus):
    seen, out = set(), []
    for pattern in ("*.circ", os.path.join("harvested", "*.circ")):
        for p in glob.glob(os.path.join(corpus, pattern)):
            rp = os.path.realpath(p)
            if rp in seen or os.path.isdir(p):
                continue
            seen.add(rp)
            out.append(p)
    return sorted(out)


def sha(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def jar_convert(classes, src, dst, timeout):
    """One JVM, one file. Statics cannot cross files OR passes."""
    try:
        p = subprocess.run(
            [JAVA, "-Djava.awt.headless=true", "-cp", f"{JAR}:{classes}",
             "com.cburch.logisim.file.CircBridge"],
            input=f"{src}\t{dst}\n", capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return False
    return p.stdout.startswith("OK\t") and os.path.exists(dst)


def cli_convert(cli, src, dst, timeout):
    try:
        p = subprocess.run([cli, "--convert", src, dst],
                           capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return False
    return p.returncode == 0 and os.path.exists(dst)


def iterate(label, convert, files, root, passes, jobs, timeout):
    """Returns {src: converged_pass_or_None}, {src: [pass1_path, pass2_path, ...]}."""
    os.makedirs(root, exist_ok=True)
    chain, dead = {}, set()

    def do(item):
        src, cur, out = item
        return src, out, convert(cur, out, timeout)

    # pass 1, from the original
    d = os.path.join(root, "p1")
    os.makedirs(d, exist_ok=True)
    jobs1 = [(p, p, os.path.join(d, os.path.basename(p))) for p in files]
    with cf.ThreadPoolExecutor(jobs) as ex:
        for src, out, ok in ex.map(do, jobs1):
            if ok:
                chain[src] = [out]
            else:
                dead.add(src)
    print(f"  [{label}] pass1: {len(chain)}/{len(files)} converted", flush=True)

    converged, work = {}, dict(chain)
    for it in range(2, passes + 1):
        if not work:
            break
        d = os.path.join(root, f"p{it}")
        os.makedirs(d, exist_ok=True)
        jobs_n = [(src, paths[-1], os.path.join(d, os.path.basename(src)))
                  for src, paths in work.items()]
        nxt = {}
        with cf.ThreadPoolExecutor(jobs) as ex:
            for src, out, ok in ex.map(do, jobs_n):
                if not ok:
                    dead.add(src)
                    continue
                chain[src].append(out)
                if sha(chain[src][-2]) == sha(out):
                    converged[src] = it - 1     # the fixed point is the pass BEFORE this one
                else:
                    nxt[src] = chain[src]
        print(f"  [{label}] pass{it}: {len(converged)} converged, {len(nxt)} moving",
              flush=True)
        work = nxt
    for src in work:
        converged[src] = None                   # never, within --passes
    return converged, chain, dead


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cli", required=True)
    ap.add_argument("--tmp", default="/tmp/logisim-idemoracle")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--passes", type=int, default=4)
    ap.add_argument("--timeout", type=int, default=180)
    ap.add_argument("--json", help="write per-file verdicts here")
    args = ap.parse_args()

    files = circ_files(corpus_dir())
    classes = os.path.join(args.tmp, "classes")
    os.makedirs(classes, exist_ok=True)
    subprocess.run([JAVAC, "-nowarn", "-cp", JAR, "-d", classes, BRIDGE_SRC], check=True)

    print(f"{len(files)} corpus files  ·  {args.passes} passes  ·  solo JVM per conversion\n",
          flush=True)

    jc, jchain, jdead = iterate(
        "jar", lambda s, d, t: jar_convert(classes, s, d, t),
        files, os.path.join(args.tmp, "jar"), args.passes, args.jobs, args.timeout)
    print()
    sc, schain, sdead = iterate(
        "swift", lambda s, d, t: cli_convert(args.cli, s, d, t),
        files, os.path.join(args.tmp, "swift"), args.passes, args.jobs, args.timeout)

    # ── Upstream's true idempotence profile ────────────────────────────────────────────────
    both = [p for p in files if p in jc and p in sc]
    def profile(conv, keys):
        d = {}
        for p in keys:
            d[conv[p]] = d.get(conv[p], 0) + 1
        return d
    jp, sp = profile(jc, both), profile(sc, both)

    print(f"\n{'='*70}\n  IDEMPOTENCE, measured solo (fresh JVM / process per conversion)")
    print(f"  files converted by BOTH: {len(both)}   "
          f"(jar-only failures {len(jdead)}, port-only failures {len(sdead)})\n")
    print(f"  {'fixed point at':<22}{'upstream 4.1.0':>16}{'swift port':>14}")
    for k in sorted((x for x in set(jp) | set(sp) if x is not None)):
        tag = "pass 1 (IDEMPOTENT)" if k == 1 else f"pass {k}"
        print(f"  {tag:<22}{jp.get(k, 0):>16}{sp.get(k, 0):>14}")
    print(f"  {'never converged':<22}{jp.get(None, 0):>16}{sp.get(None, 0):>14}")

    # ── Do the two agree, pass by pass? ────────────────────────────────────────────────────
    same_profile = [p for p in both if jc[p] == sc[p]]
    diff_profile = [p for p in both if jc[p] != sc[p]]
    byte_equal_p1, byte_equal_all = [], []
    for p in both:
        jj, ss = jchain[p], schain[p]
        n = min(len(jj), len(ss))
        eq = [sha(jj[i]) == sha(ss[i]) for i in range(n)]
        if eq and eq[0]:
            byte_equal_p1.append(p)
        if len(jj) == len(ss) and all(eq):
            byte_equal_all.append(p)

    print(f"\n  convergence profile identical to upstream:   "
          f"{len(same_profile)}/{len(both)}")
    print(f"  pass1 byte-identical to upstream:            {len(byte_equal_p1)}/{len(both)}")
    print(f"  EVERY pass byte-identical to upstream:       {len(byte_equal_all)}/{len(both)}")

    if diff_profile:
        print(f"\n  {len(diff_profile)} file(s) where the port and upstream converge "
              f"differently (jar -> swift):")
        for p in sorted(diff_profile)[:30]:
            print(f"    {str(jc[p]):>5} -> {str(sc[p]):<5}  {os.path.basename(p)}")
        if len(diff_profile) > 30:
            print(f"    ... and {len(diff_profile) - 30} more")

    if args.json:
        with open(args.json, "w") as fh:
            json.dump({
                "jar": {os.path.basename(p): jc[p] for p in both},
                "swift": {os.path.basename(p): sc[p] for p in both},
                "profile_differs": sorted(os.path.basename(p) for p in diff_profile),
                "pass1_byte_equal": sorted(os.path.basename(p) for p in byte_equal_p1),
                "all_passes_byte_equal": sorted(os.path.basename(p) for p in byte_equal_all),
            }, fh, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
