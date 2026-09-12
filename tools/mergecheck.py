#!/usr/bin/env python3
"""Pre-merge collision check for concurrently-developed branches.

WHY THIS EXISTS
---------------
This project merges branches produced by several agents working at the same time. Two classes of
collision have actually bitten, and neither is caught by git: a merge of two branches that each
compile perfectly can fail to build, or fail to LINK, purely because of what the other one named.

  1. **Duplicate basenames.** Swift flattens object files per module, so two files sharing a
     basename anywhere in one module fail to link. Hit twice — `Switch`/`Slider`/`Buzzer`, then
     `ReplacementMap` — both times caused by a slice list that assigned the same file to two
     agents. Checking this by hand is where the "compare file SETS, not diffs" rule came from: a
     `git diff` between mis-based branches reports nothing useful.

  2. **Duplicate top-level TYPE names.** Two agents on branches cut from the same commit each
     ported `com.cburch.logisim.fpga.data.LedArrayDriving` — one for the board reader, one for the
     LED-array generators. Neither could see the other. The basename check passed, because the
     FILES were named differently (`FpgaPinAttributes.swift` and
     `LedArrayGenericHdlGeneratorFactory.swift`); the build failed with "invalid redeclaration"
     only after both had been merged.

     That second case is the reason this file exists rather than a shell one-liner. A basename
     check feels like it covers "two agents made the same thing", and it does not.

WHAT IT DOES NOT CHECK, deliberately
------------------------------------
Type names are collected with a regex over `public/internal` declarations, not by parsing Swift.
It will miss types declared inside `#if` blocks and will report a false positive for two
same-named types in genuinely different modules — which is legal. The module is inferred from the
`Sources/<Module>/` path component and collisions are only reported WITHIN a module, which
removes most of that. It is a pre-merge smoke check, not a compiler; a finding is a prompt to
look, exactly like `seamcheck.py`.

USAGE
-----
    tools/mergecheck.py <base-ref> <branch> [<branch> ...]

Reports, per branch, what it adds that collides with the base, and — the case that actually bit —
what any two branches add that collides with EACH OTHER. Exit 1 if anything collides.
"""

from __future__ import annotations

import collections
import re
import subprocess
import sys

# `public struct Foo`, `final class Bar`, `enum Baz`, `actor Qux`, `protocol P`, `typealias T`.
#
# Anchored at column 0 on purpose: only a TOP-LEVEL declaration can collide. `^\s*` also matched
# nested types, and `enum Kind` inside two different parents is perfectly legal; that alone
# produced 16 collisions on a branch that built with zero errors. The dict-valued index used to
# hide this by collapsing the pair; making the index a list exposed it, which is the honest
# outcome, since the same collapse was hiding real duplicates.
DECL = re.compile(
    r"^(?:@[\w.]+\s+)*"
    r"(?:public\s+|internal\s+|package\s+)?"
    r"(?:final\s+|indirect\s+)?"
    r"(?:struct|class|enum|actor|protocol|typealias)\s+"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)"
)


def run(*args: str) -> str:
    return subprocess.run(
        ["git", *args], capture_output=True, text=True, check=True
    ).stdout


def source_files(ref: str) -> list[str]:
    out = run("ls-tree", "-r", "--name-only", ref, "--", "swift/Sources")
    return [p for p in out.splitlines() if p.endswith(".swift")]


def changed_files(base: str, ref: str) -> set[str]:
    """Files the branch itself touched, relative to where it forked from `base`.

    This is the difference between a branch's CHANGES and its tree STATE, and the whole
    correctness of the type check below turns on it. A file the branch never modified is
    resolved by git to the base's version, so a declaration the branch merely inherited
    cannot survive into the merged result and is not a collision no matter what it says.
    """
    mb = run("merge-base", base, ref).strip()
    out = run("diff", "--name-only", mb, ref, "--", "swift/Sources")
    return {p for p in out.splitlines() if p.endswith(".swift")}


def module_of(path: str) -> str:
    parts = path.split("/")
    return parts[parts.index("Sources") + 1] if "Sources" in parts else "?"


def types_in(ref: str, path: str) -> list[str]:
    try:
        body = run("show", f"{ref}:{path}")
    except subprocess.CalledProcessError:
        return []
    names = []
    for line in body.splitlines():
        m = DECL.match(line)
        if m:
            names.append(m.group("name"))
    return names


def index(ref: str) -> tuple[dict[str, str], dict[tuple[str, str], list[str]]]:
    """(module, basename) -> path, and (module, typename) -> [path, ...].

    The type map holds a LIST, not a path. It used to hold a path, which silently collapsed the
    single most important case this tool exists to find: one module, two files, the same type,
    which is a hard `invalid redeclaration` at build time. Two declarations wrote the same key and
    whichever sorted last won, so if the survivor happened to match the base's path the pair
    vanished without a word. A probe that duplicated `Project` in `LogisimUI` was reported clean.
    """
    basenames: dict[str, str] = {}
    typenames: dict[tuple[str, str], list[str]] = collections.defaultdict(list)
    for path in source_files(ref):
        mod = module_of(path)
        basenames[f"{mod}/{path.rsplit('/', 1)[-1]}"] = path
        for t in types_in(ref, path):
            typenames[(mod, t)].append(path)
    return basenames, dict(typenames)


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    base, branches = sys.argv[1], sys.argv[2:]

    base_bn, base_tn = index(base)
    added_bn: dict[str, list[tuple[str, str]]] = collections.defaultdict(list)
    added_tn: dict[tuple[str, str], list[tuple[str, str]]] = collections.defaultdict(list)
    problems: list[str] = []

    print(f"mergecheck — {len(branches)} branch(es) against {base}\n")

    for br in branches:
        bn, tn = index(br)
        branch_paths = set(source_files(br))
        branch_edits = changed_files(base, br)
        new_files = {k: v for k, v in bn.items() if k not in base_bn}
        for key, path in new_files.items():
            added_bn[key].append((br, path))
        for key, paths in tn.items():
            # Duplicated on the branch by itself. This does not need a merge to break anything,
            # the branch does not build, so it is reported before any base comparison and the
            # base's opinion is irrelevant.
            if len(paths) > 1:
                problems.append(
                    f"  {br}: type {key[1]!r} in module {key[0]} is declared "
                    f"{len(paths)} TIMES on the branch itself — this does not build\n"
                    + "".join(f"      {p}\n" for p in paths).rstrip()
                )
                continue
            path = paths[0]
            base_paths = base_tn.get(key, [])
            if base_paths and path not in base_paths:
                # A MOVED type is not a duplicated one. If the base's copy no longer exists on the
                # branch, the branch renamed the file and there is exactly one declaration in the
                # merged result.
                #
                # Without this, a legitimate refactor is a wall of false alarms: splitting
                # `LogisimRender` into a pure half and a backend moved 14 files and this reported
                # 33 collisions, none of them real. The tool's own docstring says a checker that
                # cries wolf is one people learn to silence; that applies to this checker too.
                surviving = [b for b in base_paths if b in branch_paths]
                if not surviving:
                    continue
                # The symmetric case, and the one that actually produced a false alarm: the BASE
                # moved the type and the branch is simply stale. The branch still carries the old
                # file only because it never advanced, so `path` here is inherited, not authored;
                # git resolves it to the base's version and the branch's copy never exists.
                #
                # Discriminate on authorship, not presence. A branch that did not touch the file
                # declaring its side of the pair cannot be the one duplicating anything.
                #
                # Caught on worktree-wf_ae7dfaf9-113-1, which changed 12 files, none of them under
                # LogisimHdl, and was reported as duplicating `LedArrayDrivingMode`; a type the
                # HDL agent had moved on swift-port hours earlier. Resolving that "collision" by
                # hand would have deleted a live declaration.
                if path not in branch_edits:
                    continue
                problems.append(
                    f"  {br}: type {key[1]!r} in module {key[0]} is declared TWICE after merge\n"
                    f"      branch: {path}\n"
                    + "".join(
                        f"      {base}: {b}  (still present on branch)\n" for b in surviving
                    ).rstrip()
                )
            if not base_paths:
                added_tn[key].append((br, path))
        print(f"  {br}: +{len(new_files)} file(s)")

    for key, owners in added_bn.items():
        if len(owners) > 1:
            problems.append(
                f"  BASENAME {key} added by {len(owners)} branches — Swift flattens object files\n"
                + "".join(f"      {b}: {p}\n" for b, p in owners).rstrip()
            )

    for key, owners in added_tn.items():
        if len({p for _, p in owners}) > 1:
            problems.append(
                f"  TYPE {key[1]!r} in module {key[0]} declared by {len(owners)} branches"
                f" — 'invalid redeclaration' after merge\n"
                + "".join(f"      {b}: {p}\n" for b, p in owners).rstrip()
            )

    if problems:
        print(f"\n{len(problems)} collision(s):\n")
        print("\n".join(problems))
        print(
            "\n  Resolve BEFORE merging. Renaming one side is usually right; if both are ports of"
            "\n  the same upstream class, say so in a comment on each and record the duplication"
            "\n  rather than leaving it for the next reader to rediscover."
        )
        return 1

    print("\n  no basename or type-name collisions.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
