#!/usr/bin/env python3
"""Prove that each gate in tools/ can actually fail, and can actually pass.

WHY THIS EXISTS
---------------
`tools/difftest/rig.py`'s simulation mode reported **0 pass / 1392 fail for its entire
existence** and nobody noticed. The CLI accepted `--toplevel-circuit` only AFTER the
subcommand while rig.py passes it BEFORE, so every case exited 2 on "unknown command"
and scored as a failure. It hid because an all-fail rig was the DOCUMENTED EXPECTATION
until M3 landed, and by then the quoted figure came from a different harness.

The lesson generalises. Of every gate you have to ask four questions, and only two of
them are about bugs:

    can it FAIL?   Inject a deliberate defect; the gate must go red.
                   A gate never shown to fail is a hypothesis, not a gate.
    can it PASS?   The mirror case, and the one that killed rig.py.
    does it SKIP?  A skip that prints like a pass is the worst of the three.
    has it MOVED?  A number that never changes cannot be told apart from one that is
                   not wired at all.

`tools/ci.sh`'s leak-detector step already does this properly -- it runs a clean canary
that must come back green and a cycle-injected canary that must come back red, and
refuses to trust the `leaks` run if either half misbehaves. That is the standard. This
applies it to the rest.

HOW IT WORKS
------------
Every mutation is applied inside a scratch copy under --scratch (default a fresh
mkdtemp). **The repository is never modified.** Each probe declares the exit status it
expects, so a probe that "fails" here means the GATE is wrong, not the code.

    python3 tools/gateaudit.py                    # every probe
    python3 tools/gateaudit.py --only graphcheck
    python3 tools/gateaudit.py --list

Exit 0 only if every probe behaved as specified.

Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

sys.path.insert(0, os.path.join(REPO, "tools"))
import corpus as corpus_handles  # noqa: E402


def set_repo(path):
    """Point the audit at a checkout other than the one holding this script.

    Needed because an agent worktree may hold `tools/` without `swift/`, and because the
    probes must be free to read a tree they are forbidden to modify. Nothing here writes
    to REPO -- every mutation lands in --scratch.
    """
    global REPO
    REPO = os.path.abspath(path)


# --------------------------------------------------------------------------- helpers

class Result:
    def __init__(self, gate, probe, expect, got, detail=""):
        self.gate, self.probe = gate, probe
        self.expect, self.got, self.detail = expect, got, detail

    @property
    def unavailable(self):
        """A probe that could not run at all. Not a pass, and never counted as one.

        The audit's own thesis is that a skip printing like a pass is the worst of the three
        outcomes. It then grew a skip path of its own that appended `expected zero, got 0`, so
        two unrun probe groups summed into "2 probes, 0 did not behave as specified".
        """
        return self.expect == "unavailable"

    @property
    def ok(self):
        if self.expect == "unavailable":
            return True
        if self.expect == "zero":
            return self.got == 0
        if self.expect == "nonzero":
            return self.got != 0
        # An exact code. `two` is rig.py's "did not reach a verdict" -- neither green nor a
        # regression -- and `nonzero` would accept a plain red for it, which is the distinction
        # the exit code exists to draw.
        if self.expect.isdigit():
            return self.got == int(self.expect)
        if self.expect == "two":
            return self.got == 2
        return False


def run(cmd, cwd=None, env=None, timeout=1800):
    e = dict(os.environ)
    if env:
        e.update({k: v for k, v in env.items() if v is not None})
        for k, v in env.items():
            if v is None:
                e.pop(k, None)
    p = subprocess.run(cmd, cwd=cwd, env=e, capture_output=True, text=True, timeout=timeout)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def write_stub_cli(path, mode):
    """A fake logisim-cli, for probing what a gate does with a broken tool.

    `mode` is one of:
      silent   -- exit 0, write nothing at all. The "silent zero-output success" that
                  the project's own notes call the worst possible oracle.
      copy     -- exit 0, copy input to output verbatim. An identity codec: it does no
                  parsing, no migration and no re-serialisation whatsoever.
      empty    -- exit 0, write a zero-byte output file.
      hang     -- never exit. Probes the TIMEOUT bucket, which must report the case as
                  UNMEASURED rather than failed.
      relabel  -- copy, but rewrite every `_<8 hex>` VHDL suffix to a fixed value. The
                  label mask should forgive this and the gate stay green.
      mangle   -- copy, but corrupt a byte that is NOT a random label and NOT a font
                  family. Neither mask may forgive it.
      badfont  -- copy, but replace a font family with one the source never names. The
                  font mask's third condition must refuse to forgive it.
      dropcomp -- copy, but DELETE a component. Probes the d8-superset column, which
                  forgives the port keeping MORE than the jar and must never forgive it
                  keeping less.
    """
    script = f"""#!/usr/bin/env python3
import sys, shutil, re, time
MODE = {mode!r}
if MODE == "hang":
    time.sleep(100000)
a = sys.argv[1:]
if "--convert" in a:
    i = a.index("--convert")
    src, dst = a[i + 1], a[i + 2]
    if MODE == "copy":
        shutil.copyfile(src, dst)
    elif MODE == "empty":
        open(dst, "w").close()
    elif MODE == "relabel":
        t = open(src, encoding="utf-8", errors="replace").read()
        open(dst, "w", encoding="utf-8").write(
            re.sub(r"_[0-9a-f]{{8}}(?![0-9a-zA-Z_])", "_deadbeef", t))
    elif MODE == "mangle":
        t = open(src, encoding="utf-8", errors="replace").read()
        open(dst, "w", encoding="utf-8").write(t.replace('name="facing"', 'name="facung"', 1))
    elif MODE == "dropcomp":
        t = open(src, encoding="utf-8", errors="replace").read()
        open(dst, "w", encoding="utf-8").write(re.sub(r"\\n\\s*<comp [^>]*/>", "", t, count=1))
    elif MODE == "badfont":
        t = open(src, encoding="utf-8", errors="replace").read()
        open(dst, "w", encoding="utf-8").write(
            re.sub(r'(<a name="font" val=")[^"]*?( \\w+ \\d+"/>)',
                   r"\\1NoSuchFamilyEverXYZ\\2", t, count=1))
    # MODE == "silent": write nothing
sys.exit(0)
"""
    with open(path, "w") as f:
        f.write(script)
    os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)

    # THE STUB MUST AT LEAST PARSE, and this check exists because it once did not.
    #
    # A `dropcomp` branch was added whose regex contained `\n` inside a NON-raw f-string, so the
    # escape was interpreted while generating the file and broke the string literal across lines.
    # Every mode was then a SyntaxError, the stub exited 1 in 0.16s, and it never even reached the
    # `hang` sleep on line 4.
    #
    # Three of the five probes still reported [ok], because "expected nonzero" cannot tell "the
    # gate correctly failed" from "the harness never ran". Only the one probe asserting an EXACT
    # exit code caught it. That is the lesson worth keeping about probe design, and this assertion
    # is the cheap half of the fix.
    try:
        compile(script, path, "exec")
    except SyntaxError as exc:
        raise AssertionError(
            f"the {mode!r} stub CLI does not parse ({exc}); every probe using it would exit "
            "nonzero for the wrong reason") from exc


# --------------------------------------------------------------------------- probes

def probe_graphcheck(scratch, results):
    """graphcheck asserts Package.swift dependency edges."""
    gate = "graphcheck.py"
    root = os.path.join(scratch, "graphcheck")
    os.makedirs(os.path.join(root, "tools"), exist_ok=True)
    os.makedirs(os.path.join(root, "swift"), exist_ok=True)
    shutil.copyfile(os.path.join(REPO, "tools", "graphcheck.py"),
                    os.path.join(root, "tools", "graphcheck.py"))
    manifest = os.path.join(root, "swift", "Package.swift")
    shutil.copyfile(os.path.join(REPO, "swift", "Package.swift"), manifest)
    original = open(manifest, encoding="utf-8").read()
    script = os.path.join(root, "tools", "graphcheck.py")

    # CONTROL; the real manifest must pass.
    rc, out = run([sys.executable, script])
    results.append(Result(gate, "control (unmodified manifest)", "zero", rc, out.strip()[-200:]))

    # INJECTION 1; drop a required dependency edge.
    #
    # Target the dependency LIST, not the first textual occurrence of the module name.
    # The first `"LogisimRender"` in the manifest is a `.library(...)` product
    # declaration; rewriting that renames a product and leaves every dependency edge
    # intact, so the checker is right to stay green. Getting this wrong first time is
    # the whole reason this file exists: an injection that does not inject proves
    # nothing, and reads exactly like a dead gate.
    mutated = _drop_dep(original, "LogisimStd", "LogisimRender")
    if mutated is None:
        results.append(Result(gate, "inject: drop LogisimStd -> LogisimRender", "nonzero", 0,
                              "could not apply mutation — manifest shape changed"))
    else:
        open(manifest, "w").write(mutated)
        rc, out = run([sys.executable, script])
        results.append(Result(gate, "inject: drop LogisimStd -> LogisimRender", "nonzero", rc,
                              _last_finding(out)))
        open(manifest, "w").write(original)

    # INJECTION 2; delete a required TEST target. SPM omits an unregistered suite
    # silently, so this is the failure the checker exists for.
    mutated = original.replace('"LogisimDrawTests"', '"LogisimDrawTestsXX"', 1)
    if mutated == original:
        results.append(Result(gate, "inject: unregister a test target", "nonzero", 0,
                              "could not apply mutation"))
    else:
        open(manifest, "w").write(mutated)
        rc, out = run([sys.executable, script])
        results.append(Result(gate, "inject: unregister a test target", "nonzero", rc,
                              _last_finding(out)))
        open(manifest, "w").write(original)

    # PROBE 3: the 400-character window.
    #
    # `target_blocks` slices a FIXED 400 characters after each `name:` match and calls
    # that the target's declaration. Two things follow, and the second is the dangerous
    # one:
    #   * if a target's own dependency list sits more than 400 chars after its name, the
    #     edge reads as missing, a false alarm, which fails safe;
    #   * if the window runs past the end of this target into the NEXT one, the regex can
    #     satisfy the edge from a NEIGHBOUR's dependency list, a false pass, which is the
    #     shape that keeps killing gates in this project.
    #
    # Inject a comment between `name: "LogisimStd"` and its `dependencies:` so LogisimStd's
    # real list falls outside the window, leaving the next target's list as the only one
    # reachable. LogisimStd is followed by a target that also depends on LogisimKernel, so
    # a false pass is observable.
    m = re.search(r'(name:\s*"LogisimStd",\s*\n)', original)
    if not m:
        results.append(Result(gate, "probe: 400-char window", "nonzero", 0,
                              "could not apply mutation"))
    else:
        pad = "      // " + "x" * 430 + "\n"
        mutated = original[:m.end()] + pad + original[m.end():]
        open(manifest, "w").write(mutated)
        rc, out = run([sys.executable, script])
        # RE-SPECIFIED 2026-09-05. This probe used to expect NONZERO, because graphcheck read a
        # fixed 400-char window after each `name:` and a long comment pushed `dependencies:` out
        # of range -- reporting real edges as MISSING. That is a false alarm, which the probe
        # accepted as "fails safe".
        #
        # It is no longer acceptable and no longer true: graphcheck now reads to the next target
        # declaration, so a comment of any length between `name:` and `dependencies:` must NOT
        # produce a finding. The expectation is therefore ZERO, and a nonzero result means the
        # window regressed. Three real edges were reported missing by the old behaviour, which is
        # how it was caught -- a checker that cries wolf is one people learn to silence.
        results.append(Result(
            gate, "probe: a long comment between name: and dependencies: is parsed correctly",
            "zero", rc,
            "zero = the block is delimited by the NEXT target, not a byte count. nonzero = the "
            "fixed-window parser is back and real edges read as MISSING. "
            + _last_finding(out)))
        open(manifest, "w").write(original)

    probe_graphcheck_coverage(scratch, results)


def probe_graphcheck_coverage(scratch, results):
    """Does graphcheck's REQUIRED_TEST_TARGETS still cover every declared test target?

    graphcheck exists because SPM silently omits an unregistered test target, so a suite
    that vanishes in a merge looks exactly like a passing one. That protection is a
    HAND-MAINTAINED list, which means it has the same failure mode one level up: a test
    target added after the list was written is not protected by it, and nothing says so.
    """
    gate = "graphcheck.py"
    manifest = open(os.path.join(REPO, "swift", "Package.swift"), encoding="utf-8").read()
    declared = set(re.findall(r'\.testTarget\(\s*\n?\s*name:\s*"([^"]+)"', manifest))
    src = open(os.path.join(REPO, "tools", "graphcheck.py"), encoding="utf-8").read()
    m = re.search(r"REQUIRED_TEST_TARGETS\s*=\s*\[(.*?)\]", src, re.S)
    required = set(re.findall(r'"([^"]+)"', m.group(1))) if m else set()

    unguarded = sorted(declared - required)
    stale = sorted(required - declared)
    detail = (f"{len(declared)} test targets declared, {len(required)} in the required list. "
              + (f"UNGUARDED: {', '.join(unguarded)}. " if unguarded else "")
              + (f"listed but not declared: {', '.join(stale)}." if stale else ""))
    results.append(Result(gate, "probe: required-test-target list covers the manifest",
                          "zero", 0 if not unguarded else 1, detail))


def _drop_dep(manifest_text, target, dep):
    """Remove `dep` from `target`'s dependency list only. Returns None if not applicable.

    Anchors on the target's `name:` and edits the FIRST `dependencies: [...]` after it,
    so a same-named `.library(...)` product elsewhere in the file is left alone.
    """
    # A module name appears several times in a manifest -- as a `.library` product, as a
    # `.target` declaration, and inside other targets' dependency lists. Walk every
    # occurrence and take the first one whose FOLLOWING dependency list actually contains
    # `dep`; that is the target declaration. Taking `re.search`'s first hit lands on the
    # `.library(name: ...)` line and edits the wrong list (or none), which reports as a
    # dead gate when the gate is fine.
    for m in re.finditer(r'name:\s*"%s"' % re.escape(target), manifest_text):
        d = re.compile(r"dependencies:\s*\[(.*?)\]", re.S).search(manifest_text, m.end())
        if not d:
            continue
        listed = d.group(1)
        if f'"{dep}"' not in listed:
            continue
        trimmed = re.sub(r'"%s"\s*,\s*' % re.escape(dep), "", listed)
        if trimmed == listed:
            trimmed = re.sub(r',?\s*"%s"' % re.escape(dep), "", listed)
        return manifest_text[:d.start(1)] + trimmed + manifest_text[d.end(1):]
    return None


def _last_finding(out):
    lines = [ln.strip() for ln in out.strip().splitlines() if ln.strip()]
    for ln in lines:
        if "MISSING" in ln or "not declared" in ln:
            return ln[:160]
    return lines[-1][:160] if lines else ""


def probe_seamcheck(scratch, results):
    """seamcheck finds declared-called-never-implemented seams. It is a RATCHET:
    it fails only on a seam that is not in seamcheck-baseline.txt."""
    gate = "seamcheck.py"
    root = os.path.join(scratch, "seamcheck")
    os.makedirs(os.path.join(root, "tools"), exist_ok=True)
    for f in ("seamcheck.py", "seamcheck-baseline.txt"):
        shutil.copyfile(os.path.join(REPO, "tools", f), os.path.join(root, "tools", f))
    shutil.copytree(os.path.join(REPO, "swift", "Sources"),
                    os.path.join(root, "swift", "Sources"))
    script = os.path.join(root, "tools", "seamcheck.py")

    # CONTROL; the tree as it stands must be at or under baseline.
    rc, out = run([sys.executable, script])
    results.append(Result(gate, "control (tree as-is, against baseline)", "zero", rc,
                          _seam_tail(out)))

    # INJECTION 1; a brand-new protocol with references and no conformer. This is
    # defect shape B, the one that hid MemPainter.
    inject_dir = os.path.join(root, "swift", "Sources", "LogisimKernel")
    seam_file = os.path.join(inject_dir, "ZZGateAuditSeam.swift")
    with open(seam_file, "w") as f:
        f.write(
            "// gateaudit injection: a protocol that is referenced and has no conformer.\n"
            "public protocol GateAuditCanaryPainter {\n"
            "  func paintCanary()\n"
            "}\n"
            "public enum GateAuditCanaryUse {\n"
            "  public static func a(_ x: any GateAuditCanaryPainter) { x.paintCanary() }\n"
            "  public static func b(_ x: any GateAuditCanaryPainter) { x.paintCanary() }\n"
            "  public static func c(_ x: any GateAuditCanaryPainter) { x.paintCanary() }\n"
            "  public static func d(_ x: any GateAuditCanaryPainter) { x.paintCanary() }\n"
            "}\n")
    rc, out = run([sys.executable, script])
    results.append(Result(gate, "inject: protocol with refs and no conformer", "nonzero", rc,
                          _seam_tail(out)))
    os.remove(seam_file)

    # INJECTION 2: an unwired mutable static extension point. Defect shape A.
    with open(seam_file, "w") as f:
        f.write(
            "// gateaudit injection: an extension point nothing ever assigns.\n"
            "public enum GateAuditRegistry {\n"
            "  public static var gateAuditCanaryHandler: ((Int) -> Void)!\n"
            "}\n"
            "public enum GateAuditRegistryUse {\n"
            "  public static func go() { GateAuditRegistry.gateAuditCanaryHandler(1) }\n"
            "  public static func go2() { GateAuditRegistry.gateAuditCanaryHandler(2) }\n"
            "}\n")
    rc, out = run([sys.executable, script])
    results.append(Result(gate, "inject: unassigned static extension point", "nonzero", rc,
                          _seam_tail(out)))
    os.remove(seam_file)

    # PROBE 3; does the ratchet notice a seam being FIXED? A one-sided ratchet that
    # silently tolerates a shrinking baseline cannot tell "fixed" from "no longer scanned".
    baseline = os.path.join(root, "tools", "seamcheck-baseline.txt")
    known = [ln.strip() for ln in open(baseline, encoding="utf-8") if ln.strip()]
    with open(baseline, "w") as f:
        f.write("\n".join(known + ["  NO CONFORMER  protocol GateAuditNeverExisted"]) + "\n")
    rc, out = run([sys.executable, script])
    results.append(Result(
        gate, "probe: baseline entry that no longer exists", "zero", rc,
        "exit 0 is correct (a fixed seam must not fail CI), but the run must SAY so: "
        + ("reports it" if "now wired" in out else "!! SILENT — no 'now wired' line")))

    # PROBE 4: the empty-tree case. If ROOT resolves to nothing, does it pass green?
    empty = os.path.join(scratch, "seamcheck-empty")
    os.makedirs(os.path.join(empty, "tools"), exist_ok=True)
    os.makedirs(os.path.join(empty, "swift", "Sources"), exist_ok=True)
    for f in ("seamcheck.py", "seamcheck-baseline.txt"):
        shutil.copyfile(os.path.join(REPO, "tools", f), os.path.join(empty, "tools", f))
    rc, out = run([sys.executable, os.path.join(empty, "tools", "seamcheck.py")])
    results.append(Result(
        gate, "probe: zero source files scanned", "nonzero", rc,
        "a scan of an EMPTY tree reports " + _seam_tail(out) +
        " -- exit 0 here means 'scanned nothing' is indistinguishable from 'found nothing'"))


def _seam_tail(out):
    for ln in out.splitlines():
        if "candidate seam" in ln:
            return ln.strip()[:160]
    return (out.strip().splitlines() or [""])[-1][:160]


def probe_roundtrip(scratch, results, corpus):
    """rig.py --roundtrip: the M2 canonical and migration conditions."""
    gate = "rig.py --roundtrip"
    if not corpus:
        results.append(Result(gate, "could not run: LOGISIM_CORPUS unset", "unavailable", 0,
                              "cannot probe without the corpus"))
        return
    rig = os.path.join(REPO, "tools", "difftest", "rig.py")
    if not os.path.exists(os.path.join(corpus, "canonical", "_index.json")):
        results.append(Result(gate, "could not run: no canonical baselines", "unavailable", 0, ""))
        return

    # Probe with stub CLIs. These do not touch the repo or the corpus; output goes to
    # a scratch --tmp.
    for mode, note in (
        ("silent", "exit 0, writes NOTHING"),
        ("empty", "exit 0, writes a zero-byte file"),
        ("copy", "exit 0, copies input to output verbatim (identity codec)"),
    ):
        stub = os.path.join(scratch, f"stub-{mode}")
        write_stub_cli(stub, mode)
        tmp = os.path.join(scratch, f"rt-{mode}")
        rc, out = run([sys.executable, rig, "--roundtrip", "--cli", stub, "--tmp", tmp,
                       "--max-fail", "1", "--jobs", "6"],
                      env={"LOGISIM_CORPUS": corpus})
        tallies = dict(re.findall(r"(canonical|migration)\s+pass (\d+)\s+.\s+fail (\d+)",
                                  out) and
                       [(m[0], (int(m[1]), int(m[2])))
                        for m in re.findall(
                            r"(canonical|migration)\s+pass (\d+)\s+\S\s+fail (\d+)", out)])
        detail = f"stub CLI {note} -> {tallies or out.strip()[-160:]}"
        # A stub that does no codec work at all must not be able to pass EITHER condition.
        results.append(Result(gate, f"inject: {mode} stub CLI", "nonzero", rc, detail))
        if mode == "copy" and tallies.get("canonical", (0, 1))[1] == 0:
            # The canonical CONDITION cannot be made to fail here, and that is not a bug to fix:
            # a canonical file is a fixed point of Java's converter, so `load -> save` must return
            # it unchanged, and an identity codec returns everything unchanged. Demanding that the
            # column go red would be demanding that the port corrupt a file it was handed.
            #
            # What IS achievable, and what this now checks, is that the GATE AS A WHOLE refuses.
            # rig.py counts how many migration inputs the codec actually transformed and exits
            # nonzero when that count is zero, precisely so a `cp` cannot be reported as a pass on
            # the strength of a green canonical column.
            #
            # Recorded rather than deleted because the underlying fact still matters when reading
            # the numbers: **canonical 539/0 is the weaker half of the M2 evidence.** It proves the
            # port does not corrupt an already-canonical file. The migration column is what proves
            # it parses one.
            verdict = "ok" if rc != 0 else "BAD"
            results.append(Result(
                gate,
                "canonical alone cannot fail on `cp` — gate must refuse via the transform count",
                "nonzero", rc,
                f"canonical pass {tallies['canonical'][0]} fail 0 with a byte-copy CLI "
                f"(inherent: canonical files are fixed points). Whole-gate exit was {rc}; "
                f"{'refused, as intended' if verdict == 'ok' else 'REPORTED A PASS — the transform-count guard is not working'}"))


def probe_simulation(scratch, results, corpus, cli):
    """rig.py default mode: the simulation gate that was structurally dead."""
    gate = "rig.py (simulation)"
    if not corpus:
        results.append(Result(gate, "could not run: LOGISIM_CORPUS unset", "unavailable", 0, ""))
        return
    rig = os.path.join(REPO, "tools", "difftest", "rig.py")
    try:
        known_good = corpus_handles.basename("golden-03.circ", corpus) + "::"
    except LookupError as why:
        results.append(Result(
            gate, "the corpus manifest resolves this gate's known-good case", "zero", 1,
            f"MISCALIBRATED: {why}. A corpus is configured, so this is not a skip: the probes "
            f"below did not run and nothing about this gate has been checked."))
        return

    # CAN IT PASS? -- the question that killed it. Run a narrow filter of cases known
    # to match and require a green result.
    if cli:
        rc, out = run([sys.executable, rig, "--cli", cli, "--filter", known_good,
                       "--jobs", "4"], env={"LOGISIM_CORPUS": corpus})
        results.append(Result(gate, "can it PASS (known-good filter)", "zero", rc,
                              _rig_tail(out)))

    # CAN IT FAIL? -- a stub CLI that writes nothing must be scored red, never green.
    stub = os.path.join(scratch, "stub-silent-sim")
    write_stub_cli(stub, "silent")
    rc, out = run([sys.executable, rig, "--cli", stub, "--filter", known_good,
                   "--jobs", "4", "--max-fail", "1"], env={"LOGISIM_CORPUS": corpus})
    results.append(Result(gate, "inject: CLI writes nothing, exits 0", "nonzero", rc,
                          _rig_tail(out)))

    # DOES IT MISRESOLVE? -- compare() maps a golden entry back to a corpus file by
    # BASENAME, first match wins. Count how many inventory basenames are ambiguous.
    idx = os.path.join(corpus, "golden", "_inventory.json")
    if os.path.exists(idx):
        index = json.load(open(idx))
        seen = {}
        for r in index.values():
            seen.setdefault(r["file"], set()).add(r["golden"].split("__")[-1])
        dupes = 0
        for name in seen:
            hits = [p for p in (os.path.join(corpus, name),
                                os.path.join(corpus, "harvested", name))
                    if os.path.exists(p)]
            if len(hits) > 1:
                dupes += 1
        results.append(Result(
            gate, "probe: basename ambiguity in compare()", "zero", 0 if dupes == 0 else 1,
            f"{dupes} inventory basenames resolve to more than one corpus path; "
            "rig.py's by_name.setdefault takes the FIRST, so each would be diffed "
            "against another file's oracle"))


def probe_gate_excuses(scratch, results, corpus, cli):
    """The three ways a gate is now allowed to say "not a failure", and whether each over-fires.

    Three columns were added to `rig.py` in one day: a TIMEOUT bucket, a random-VHDL-label mask
    and an unresolved-font mask. Each exists because a real case was being blamed on the port, and
    each is a new way for the gate to stay green while something is wrong. A mask that folds too
    much is strictly worse than the failures it was built to explain, because it is silent.

    This audit's own question is "can it fail, can it pass, does it skip silently". Adding three
    skip mechanisms without probing them would leave that question unanswered for exactly the
    newest and least-exercised code in the gate.
    """
    gate = "rig.py (the excuse columns)"
    if not corpus:
        results.append(Result(gate, "could not run: LOGISIM_CORPUS unset", "unavailable", 0, ""))
        return
    rig = os.path.join(REPO, "tools", "difftest", "rig.py")
    env = {"LOGISIM_CORPUS": corpus}
    tmp = os.path.join(scratch, "excuse-tmp")
    try:
        known_good = corpus_handles.basename("golden-03.circ", corpus) + "::"
        label_case = corpus_handles.basename("2.7.0__case-248.circ", corpus)
    except LookupError as why:
        results.append(Result(
            gate, "the corpus manifest resolves this gate's cases", "zero", 1,
            f"MISCALIBRATED: {why}. A corpus is configured, so this is not a skip."))
        return

    # ── TIMEOUT must be UNMEASURED (exit 2), never a pass and never a failure ────────────────
    stub = os.path.join(scratch, "stub-hang")
    write_stub_cli(stub, "hang")
    rc, out = run([sys.executable, rig, "--cli", stub, "--filter", known_good,
                   "--jobs", "2", "--timeout", "2"], env=env)
    results.append(Result(
        gate, "inject: CLI hangs -> must be UNMEASURED (exit 2), not pass and not fail",
        "two", rc, _rig_tail(out)))

    # ── The label mask must FIRE, on real data, with the real CLI ────────────────────────────
    #
    # NOT via a stub. The first version of this probe used a copy-based stub that rewrote only the
    # label suffixes and expected a green migration column -- and that cannot work whatever the
    # mask does, because the migration condition compares `load(f) -> save` against `-n(f)` and a
    # copy of the INPUT is not the migrated form. (The audit's own notes say the copy stub scores
    # 39/500 on migration for exactly this reason.) The probe was wrong, not the gate.
    #
    # `2.7.0__case-248.circ` is a measured member of the label set: three CircBridge runs over it
    # gave Bn_1_439aa5cc / Bn_1_69ad5ecb / Bn_1_36063c8e. With the real CLI it must come out
    # GREEN and be counted in the label column, not the pass column.
    if cli:
        rc, out = run([sys.executable, rig, "--roundtrip", "--cli", cli, "--tmp", tmp,
                       "--filter", label_case, "--jobs", "2"], env=env)
        counted = "vhdl-label" in out
        results.append(Result(
            gate, "the label mask FIRES on a known label-only case, and is counted apart",
            "zero", rc if counted else (rc or 1),
            _rig_tail(out) + ("" if counted else
                              "  -- and it was NOT reported in the vhdl-label column")))

    # ── ...and must NOT forgive a byte that is not a label ───────────────────────────────────
    stub = os.path.join(scratch, "stub-mangle")
    write_stub_cli(stub, "mangle")
    rc, out = run([sys.executable, rig, "--roundtrip", "--cli", stub, "--tmp", tmp,
                   "--filter", label_case, "--jobs", "2"], env=env)
    results.append(Result(
        gate, "inject: a NON-label byte corrupted -> no mask may forgive it",
        "nonzero", rc, _rig_tail(out)))

    # ── The d8-superset column must never forgive the port keeping LESS ──────────────────────
    #
    # That column folds 19 migration cases on the argument that 4.1.0 DESTROYS components whose
    # library it cannot resolve while the port keeps them -- D8 working. The rule is a strict
    # subset check after library indices are resolved, and the whole load-bearing half of it is
    # that a port which drops anything the jar kept still fails. A column that folded "the two
    # differ somehow" would turn a 19-case explanation into a 19-case blindfold.
    stub = os.path.join(scratch, "stub-dropcomp")
    write_stub_cli(stub, "dropcomp")
    rc, out = run([sys.executable, rig, "--roundtrip", "--cli", stub, "--tmp", tmp,
                   "--filter", label_case, "--jobs", "2"], env=env)
    results.append(Result(
        gate, "inject: a component DELETED -> d8-superset must not forgive it",
        "nonzero", rc, _rig_tail(out)))

    # ── The font mask's third condition: a family the source never names is not forgiven ─────
    #
    # This is the condition I got wrong on the first attempt -- it was a substring test, so a
    # port that dropped a letter from "CMU Sans Serif" was forgiven. The unit probes cover the
    # rule; this covers it end to end, through the real gate.
    stub = os.path.join(scratch, "stub-badfont")
    write_stub_cli(stub, "badfont")
    rc, out = run([sys.executable, rig, "--roundtrip", "--cli", stub, "--tmp", tmp,
                   "--filter", label_case, "--jobs", "2"], env=env)
    results.append(Result(
        gate, "inject: invented font family not in the source -> must NOT be forgiven",
        "nonzero", rc, _rig_tail(out)))


def _rig_tail(out):
    for ln in reversed(out.strip().splitlines()):
        if "pass" in ln and "fail" in ln:
            return ln.strip()[:160]
    return (out.strip().splitlines() or [""])[-1][:160]


def probe_m3_gate(scratch, results, corpus, package_dir):
    """TruthTableGoldenTests: the M3 ratchet. Probed by running the real suite."""
    gate = "TruthTableGoldenTests"
    if not package_dir or not os.path.exists(os.path.join(package_dir, "Package.swift")):
        results.append(Result(gate, "could not run: no --package-dir", "unavailable", 0,
                              "pass --package-dir to a scratch copy of swift/ to probe this"))
        return

    filt = ["--filter", "TruthTableGolden"]

    # PROBE 1; the silent skip. With LOGISIM_CORPUS unset the suite prints a line and
    # RETURNS, which the test runner scores as a pass. The corpus is never committed, so
    # this is the DEFAULT state for every checkout but the author's.
    rc, out = run(["swift", "test"] + filt, cwd=package_dir,
                  env={"LOGISIM_CORPUS": None}, timeout=3600)
    # This probe used to require a NONZERO exit, on the reasoning that a gate which compares
    # nothing must not be green. The suite now carries `.enabled(if:)`, so the runner reports the
    # case as SKIPPED and exits 0, which is the repair rather than the defect; requiring nonzero
    # would mark the fix BAD. So what is required now is the skip being VISIBLE: a pass with no
    # notice is still the bad outcome, and that is what is asserted.
    announced = "skipped" in out.lower()
    results.append(Result(
        gate, "probe: LOGISIM_CORPUS unset -> the runner must SAY it skipped", "zero",
        0 if announced else 1,
        "reported as skipped, so a green run cannot be read as having compared anything"
        if announced
        else "exit 0 with NO skip notice: the M3 gate reports GREEN having compared nothing"))

    # PROBE 2; can it FAIL? Drive the row cap down so the match count falls under the
    # recorded floor. This uses only the documented override; no source is edited.
    rc, out = run(["swift", "test"] + filt, cwd=package_dir,
                  env={"LOGISIM_CORPUS": corpus, "LOGISIM_M3_MAX_ROWS": "8"}, timeout=7200)
    results.append(Result(
        gate, "inject: LOGISIM_M3_MAX_ROWS=8 (match count collapses)", "nonzero", rc,
        _m3_tail(out)))


def _m3_tail(out):
    keep = []
    for ln in out.splitlines():
        s = ln.strip()
        if s.startswith(("golden oracles", "skipped", "attempted", "byte-exact")):
            keep.append(s)
    return " | ".join(keep)[:200]


# --------------------------------------------------------------------------- driver

PROBES = {
    "excuses": probe_gate_excuses,
    "graphcheck": probe_graphcheck,
    "seamcheck": probe_seamcheck,
    "roundtrip": probe_roundtrip,
    "simulation": probe_simulation,
    "m3": probe_m3_gate,
}


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", action="append", choices=sorted(PROBES), default=None)
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--scratch", default=None)
    ap.add_argument("--cli", default=None, help="a real logisim-cli, for the can-it-pass probes")
    ap.add_argument("--package-dir", default=None,
                    help="a SCRATCH copy of swift/ to run the M3 suite in; never the repo's")
    ap.add_argument("--repo", default=None,
                    help="checkout to READ gates and sources from (default: this script's)")
    args = ap.parse_args()

    if args.repo:
        set_repo(args.repo)

    if args.list:
        for name in sorted(PROBES):
            print(name)
        return 0

    scratch = args.scratch or tempfile.mkdtemp(prefix="gateaudit-")
    os.makedirs(scratch, exist_ok=True)
    corpus = os.environ.get("LOGISIM_CORPUS")
    if corpus and not os.path.isdir(corpus):
        corpus = None

    # Resolve --cli against the CALLER's cwd, once, before any probe runs.
    #
    # The probes run the gates from other directories, so a relative path silently becomes "not
    # built" -- and now that rig.py aborts on a missing binary (rather than scoring every case as
    # a failure), that presents as the "can it PASS" probe failing, which reads like a gate defect
    # and is a path defect. A tool whose answer depends on the caller's cwd is a tool that will
    # mislead someone.
    if args.cli:
        args.cli = os.path.abspath(args.cli)
        if not os.path.exists(args.cli):
            sys.exit(f"--cli does not exist: {args.cli}\n"
                     "  build it with: swift build -c release --product logisim-cli")

    selected = args.only or sorted(PROBES)
    results: list[Result] = []
    for name in selected:
        fn = PROBES[name]
        print(f"\n== {name} ==", flush=True)
        try:
            if name in ("roundtrip",):
                fn(scratch, results, corpus)
            elif name in ("simulation", "excuses"):
                fn(scratch, results, corpus, args.cli)
            elif name == "m3":
                fn(scratch, results, corpus, args.package_dir)
            else:
                fn(scratch, results)
        except Exception as exc:  # a probe that explodes is itself a finding
            results.append(Result(name, "probe raised", "zero", 1, f"{type(exc).__name__}: {exc}"))
        for r in results:
            if r.gate.startswith(name) or name in r.gate:
                pass
        print(f"   {len([r for r in results])} results so far", flush=True)

    print("\n" + "=" * 78)
    print("  GATE AUDIT — can each gate fail, can it pass, does it skip silently")
    print("=" * 78)
    bad = 0
    current = None
    unavailable = 0
    for r in results:
        if r.gate != current:
            current = r.gate
            print(f"\n  {current}")
        verdict = "skip" if r.unavailable else ("ok  " if r.ok else "BAD ")
        if not r.ok:
            bad += 1
        if r.unavailable:
            unavailable += 1
        print(f"    [{verdict}] {r.probe}")
        if not r.unavailable:
            print(f"             expected {r.expect} exit, got {r.got}")
        if r.detail:
            print(f"             {r.detail}")

    print("\n" + "-" * 78)
    ran = len(results) - unavailable
    print(f"  {ran} probes ran, {bad} did not behave as specified")
    if unavailable:
        print(f"  {unavailable} probe group(s) COULD NOT RUN and prove nothing; see [skip] above")
    print(f"  scratch: {scratch}")
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
