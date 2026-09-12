"""Self-test rig.py's regenerate() assertions. Verifies each can FIRE, per the project rule
that a probe which matches nothing looks exactly like a clean result."""
import argparse, json, os, re, shutil, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rig

TMP = tempfile.mkdtemp(prefix="rig-selftest-")
CORPUS = os.path.join(TMP, "corpus")
GOLDEN = os.path.join(TMP, "golden")
os.makedirs(CORPUS)

# A corpus file with two circuits differing only in case, the real collision shape.
open(os.path.join(CORPUS, "coll.circ"), "w").write(
    '<project>\n<circuit name="Ctrl">\n</circuit>\n<circuit name="ctrl">\n</circuit>\n</project>\n')

TABLE = {"Ctrl": "a b\n0 0\n0 1\n", "ctrl": "c d\n1 0\n1 1\n"}      # 3 lines = 2^1+1, valid
os.environ["LOGISIM_CORPUS"] = CORPUS


def args(**kw):
    a = argparse.Namespace(golden=GOLDEN, jobs=2, timeout=30, pattern=re.compile("."))
    a.__dict__.update(kw)
    return a


def run(label, expect_exit, patch_name=False, table=None):
    global GOLDEN
    real_name, real_java = rig.golden_name, rig.run_java
    if patch_name:                       # emulate the PRE-hardening naming: no digest
        rig.golden_name = lambda p, c: re.sub(r"[^A-Za-z0-9_.-]", "_",
                                              f"{os.path.basename(p)}__{c}") + ".table"
    rig.run_java = lambda p, c, t: (table or TABLE)[c]
    try:
        code = rig.regenerate(args())
    except SystemExit as e:
        code = e.code if isinstance(e.code, int) else 1
    finally:
        rig.golden_name, rig.run_java = real_name, real_java
    ok = "PASS" if code == expect_exit else "FAIL"
    print(f"  [{ok}] {label}: exit {code}, expected {expect_exit}")
    return code == expect_exit


results = []
print("A. collision detectable — digest stripped, two case-variant circuits:")
shutil.rmtree(GOLDEN, ignore_errors=True)
results.append(run("aborts before any JVM start", 1, patch_name=True))

print("B. same corpus WITH the digest — must now succeed and write two distinct files:")
shutil.rmtree(GOLDEN, ignore_errors=True)
results.append(run("digest disambiguates", 0))
idx = json.load(open(os.path.join(GOLDEN, "_inventory.json")))
files = sorted(f for f in os.listdir(GOLDEN) if f.endswith(".table"))
distinct = len({os.stat(os.path.join(GOLDEN, f)).st_ino for f in files})
print(f"    index entries {len(idx)}, files {len(files)}, distinct inodes {distinct}")
results.append(len(idx) == 2 and len(files) == 2 and distinct == 2)

print("C. truncated capture rejected — 100 lines is not 2^n+1:")
shutil.rmtree(GOLDEN, ignore_errors=True)
bad = {"Ctrl": "a b\n" + "0 0\n" * 99, "ctrl": "c d\n1 0\n1 1\n"}
results.append(run("nonzero exit, bad oracle not written", 1, table=bad))
wrote = [f for f in os.listdir(GOLDEN) if "Ctrl" in f]
print(f"    truncated oracle written? {bool(wrote)} (must be False)")
results.append(not wrote)

print("E. a crashed JVM is rejected even though its partial stdout looks like a table:")
shutil.rmtree(GOLDEN, ignore_errors=True)
# Exactly the 3.5.0__case-383.circ::truc shape: a well-formed 2^n+1 table body from a run that exited nonzero.
crashed = {"Ctrl": "\0CRASH:255", "ctrl": "c d\n1 0\n1 1\n"}
results.append(run("nonzero exit, crashed oracle not written", 1, table=crashed))
wrote = [f for f in os.listdir(GOLDEN) if "Ctrl" in f]
print(f"    crashed oracle written? {bool(wrote)} (must be False)")
results.append(not wrote)

print("D. scoped regeneration MERGES instead of replacing the index:")
shutil.rmtree(GOLDEN, ignore_errors=True)
run("seed both", 0)
before = json.load(open(os.path.join(GOLDEN, "_inventory.json")))
a = args(pattern=re.compile("::ctrl$"))
real_java = rig.run_java
rig.run_java = lambda p, c, t: TABLE[c]
rig.regenerate(a)
rig.run_java = real_java
after = json.load(open(os.path.join(GOLDEN, "_inventory.json")))
print(f"    before {len(before)} entries, after a 1-case scoped run {len(after)} entries")
results.append(len(after) == 2)

shutil.rmtree(TMP, ignore_errors=True)
print(f"\n{'ALL SELF-TESTS PASS' if all(results) else 'SELF-TEST FAILURE'}"
      f"  ({sum(results)}/{len(results)})")
sys.exit(0 if all(results) else 1)
