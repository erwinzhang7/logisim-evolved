#!/usr/bin/env python3
"""Task #16: is the PORT's codec idempotent, and where does that put it against upstream?

Upstream's converter is NOT idempotent. `canonical.py` measured it over the 541-file corpus:
519 files reach a fixed point at pass 2, 20 need pass 3, and 2 never converge at all. That is
why the CANONICAL baseline is iterated to a fixed point rather than "converted twice".

The question here is the port's own behaviour, measured the same way and on the same corpus:

    pass1 = swift --convert  f       (f = the ORIGINAL corpus file — the migration input)
    pass2 = swift --convert  pass1

    idempotent  <=>  pass2 == pass1, bytewise

A file where pass2 != pass1 is a port non-idempotence. A file where the PORT converges at
pass 2 but UPSTREAM needed pass 3 is a place where the two disagree about the fixed point;
that disagreement is reported separately, because it is not visible in either gate condition
(MIGRATION compares pass1 only; CANONICAL starts from upstream's fixed point).

    LOGISIM_CORPUS=/path/to/corpus \\
      python3 idempotence.py --cli /path/to/logisim-cli [--jobs N]

Prints a table and exits non-zero only on a harness failure, never on a finding — this is a
measurement, not a gate.
"""
import argparse, concurrent.futures, glob, hashlib, json, os, subprocess, sys


def corpus_dir():
    d = os.environ.get("LOGISIM_CORPUS")
    if not d or not os.path.isdir(d):
        sys.exit("set LOGISIM_CORPUS to the corpus directory")
    return d


def circ_files(corpus):
    """Same dedup as canonical.py: harvested/*.circ and harvested/* overlap completely."""
    seen, out = set(), []
    for pattern in ("*.circ", os.path.join("harvested", "*.circ")):
        for p in sorted(glob.glob(os.path.join(corpus, pattern))):
            rp = os.path.realpath(p)
            if rp in seen:
                continue
            seen.add(rp)
            out.append(p)
    return out


def sha(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def name_for(path):
    """Match canonical.py's flattened basename so results line up with _index.json."""
    return os.path.basename(path)


def convert(cli, src, dst, timeout):
    try:
        p = subprocess.run([cli, "--convert", src, dst],
                           capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return False, "timeout"
    except FileNotFoundError:
        sys.exit(f"not built: {cli}")
    if p.returncode != 0 or not os.path.exists(dst):
        return False, (p.stderr or p.stdout or "no output").strip().splitlines()[:1]
    return True, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cli", required=True)
    ap.add_argument("--tmp", default="/tmp/logisim-idempotence")
    ap.add_argument("--jobs", type=int, default=os.cpu_count())
    ap.add_argument("--timeout", type=int, default=120)
    ap.add_argument("--passes", type=int, default=4,
                    help="how far to iterate the non-idempotent ones")
    ap.add_argument("--json", help="write the per-file verdicts here")
    args = ap.parse_args()

    corpus = corpus_dir()
    files = circ_files(corpus)
    if not files:
        sys.exit("no corpus files found")

    d1 = os.path.join(args.tmp, "p1")
    os.makedirs(d1, exist_ok=True)
    print(f"{len(files)} corpus files  ·  cli={args.cli}\n", flush=True)

    # pass 1: the migration conversion, from the ORIGINAL file
    def do1(p):
        out = os.path.join(d1, name_for(p))
        ok, why = convert(args.cli, p, out, args.timeout)
        return p, out, ok, why

    survived, unconvertible = {}, {}
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as ex:
        for p, out, ok, why in ex.map(do1, files):
            (survived if ok else unconvertible)[p] = out if ok else why
    print(f"  pass1: {len(survived)}/{len(files)} converted "
          f"({len(unconvertible)} the port refuses to load)", flush=True)

    # iterate: pass N+1 from pass N, until the bytes stop moving
    work = dict(survived)
    stable, history = {}, {}
    for it in range(2, args.passes + 1):
        if not work:
            break
        dn = os.path.join(args.tmp, f"p{it}")
        os.makedirs(dn, exist_ok=True)

        def doN(item):
            p, cur = item
            out = os.path.join(dn, name_for(p))
            ok, why = convert(args.cli, cur, out, args.timeout)
            return p, cur, out, ok, why

        nxt = {}
        with concurrent.futures.ThreadPoolExecutor(args.jobs) as ex:
            for p, cur, out, ok, why in ex.map(doN, list(work.items())):
                if not ok:
                    unconvertible[p] = f"pass{it}: {why}"
                    continue
                if sha(cur) == sha(out):
                    stable[p] = it - 1          # converged AT the previous pass
                    history.setdefault(p, []).append(it)
                else:
                    nxt[p] = out
        print(f"  pass{it}: {len(stable)} converged, {len(nxt)} still moving", flush=True)
        work = nxt

    never = sorted(work)

    # Cross-check against upstream's own convergence data, which canonical.py already wrote.
    osc_path = os.path.join(corpus, "canonical", "_oscillating.json")
    upstream_osc = set(json.load(open(osc_path))) if os.path.exists(osc_path) else set()

    by_pass = {}
    for p, n in stable.items():
        by_pass[n] = by_pass.get(n, 0) + 1

    print(f"\n{'='*64}\n  PORT IDEMPOTENCE")
    print(f"  converged at pass 1 (idempotent: pass2 == pass1)  {by_pass.get(1, 0)}")
    for n in sorted(k for k in by_pass if k != 1):
        print(f"  converged at pass {n}{'':<32}{by_pass[n]}")
    print(f"  never converged within {args.passes} passes           {len(never)}")
    print(f"  not loadable by the port at all                  {len(unconvertible)}")

    non_idem = sorted(p for p, n in stable.items() if n != 1) + never
    if non_idem:
        print(f"\n  {len(non_idem)} NON-IDEMPOTENT file(s):")
        for p in non_idem[:40]:
            tag = "never" if p in work else f"pass{stable[p]}"
            up = "  [upstream also oscillates]" if os.path.basename(p) in upstream_osc else ""
            print(f"    {tag:<7} {os.path.basename(p)}{up}")
        if len(non_idem) > 40:
            print(f"    ... and {len(non_idem) - 40} more")
    else:
        print("\n  VERIFIED NEGATIVE: the port's codec is idempotent on every corpus file "
              "it can load.")

    print(f"\n  upstream, for comparison (canonical.py): 519 stable at pass 2, "
          f"20 need pass 3, {len(upstream_osc)} never converge")

    if unconvertible:
        print(f"\n  {len(unconvertible)} unconvertible (excluded, not counted as passing):")
        for p in sorted(unconvertible)[:15]:
            print(f"    {os.path.basename(p)}: {unconvertible[p]}")

    if args.json:
        with open(args.json, "w") as fh:
            json.dump({
                "converged_at": {os.path.basename(p): n for p, n in stable.items()},
                "never": [os.path.basename(p) for p in never],
                "unconvertible": {os.path.basename(p): str(v) for p, v in unconvertible.items()},
            }, fh, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
