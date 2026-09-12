#!/usr/bin/env python3
"""Assert that every corpus citation in the tracked tree IS an anonymous handle.

WHY THIS EXISTS
---------------
The corpus is coursework, harvested one directory per student repository, so a filename identifies
a person even when the file itself is absent. The tree therefore cites corpus files by handle
(`3.3.0__case-269.circ`, `golden-07.circ`) and keeps the handle-to-filename map beside the corpus:
see `tools/corpus.py`.

Three successive scans for leftover names each missed the same shape, and the reason is worth
recording, because it is the reason this script is a whitelist and not another blacklist.

Every one of those scans looked for names. The name it could not see was a citation the prose had
already ABBREVIATED:

    3.7.2__nobody...gadget.circ              an ellipsis where the second `__` should be
    nobody...widget_part2.circ                the version prefix dropped entirely
    harvested/3.7.2__nobody_..._sprocket...  an ellipsis in the middle of the owner
    `harvested/3.7.2__nobody_SomeRepo__gadget  split across two wrapped comment lines, so no
    /// .circ`                               single line contains the filename at all

(Those four are FABRICATED, with the shape of the real ones and none of the identity. An
illustration of a leak must not be one: the first version of this file used the real names in its
examples and its fixtures, and this check flagged its own source, correctly.)

A pattern written for `VERSION__owner_repo__file.circ` matches none of them, and a list of known
owner names always omits the one owner nobody remembered. So this inverts the question: find
everything that LOOKS like a corpus citation and require it to be exactly a handle. A new
abbreviation, a new owner, a new way of wrapping a comment: all of them fail this, because none of
them is `3.3.0__case-269.circ`.

    python3 tools/corpuscheck.py            # exit 1 and print every citation that is not a handle

Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
"""
import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Join wrapped comment continuations first, or a name split over two lines reads as two tokens and
# neither half looks like anything. This is the fourth shape in the list above.
CONTINUATION = re.compile(r"\n[ \t]*(?:///|//|#|\*)[ \t]*")

# Deliberately WIDER than the handle grammar: a version-ish prefix with a `__`, a `harvested/`
# path, or any `.circ` carrying a `__`. Over-matching here costs a line of allow-list; under-
# matching costs a student's username on the internet.
CITATION = re.compile(
    r"(?:\d+\.\d+\.\d+|…|\.\.\.)[A-Za-z0-9_.…-]*__[^\s`'\"|)]*"
    r"|harvested/[^\s`'\"|)]+"
    r"|[A-Za-z0-9_.…-]*__[A-Za-z0-9_.…-]*\.circ"
    # An owner fragment, an ellipsis, then a bare filename and no `__` anywhere:
    # `nobody...widget_part2.circ`. The selftest caught this one missing, which is the whole
    # argument for having a selftest. `(?<![/\w])` keeps elided PATHS out of it, because
    # `/private/var/folders/…/shared.circ` is not a corpus citation.
    r"|(?<![/\w])[A-Za-z0-9_-]+(?:…|\.\.\.)[A-Za-z0-9_.-]*\.circ")

HANDLE = r"(?:\d+\.\d+\.\d+__case-\d{3}|golden-\d{2})\.circ"
ALLOWED = [
    re.compile(rf"^(?:harvested/)?{HANDLE}$"),
    # `file::circuit`, the key the differential gates gate on.
    re.compile(rf"^(?:harvested/)?(?:…|\.\.\.)?{HANDLE}::[\w.-]+$"),
    # `<circ>__<circuit>.table`, a golden truth-table filename: a handle plus a suffix.
    re.compile(rf"^(?:harvested/)?{HANDLE}__[\w.-]+$"),
    # A handle whose tail the prose elided, which is anonymous already.
    re.compile(rf"^(?:harvested/)?{HANDLE}__(?:…|\.\.\.)$"),
    # Globs over the corpus layout. A directory name is not a citation.
    re.compile(r"^harvested/\*(?:\.circ)?$"),
    re.compile(r"^harvested/$"),
]


def offenders(repo=REPO):
    listing = subprocess.run(["git", "-C", repo, "ls-files", "-z"], capture_output=True,
                             text=True, check=True).stdout
    files = [name for name in listing.split("\0") if name]
    for name in files:
        # Upstream's own Java tree, present in the fork and never published. Not ours to rewrite.
        if name.startswith("src/"):
            continue
        # This file cannot be scanned by itself: its patterns and its selftest fixtures are
        # citation-shaped by construction, so it would always flag. Skipping it is only safe
        # because every name in it is fabricated, which `--selftest` is what keeps honest.
        if os.path.abspath(os.path.join(repo, name)) == os.path.abspath(__file__):
            continue
        try:
            with open(os.path.join(repo, name), encoding="utf-8") as handle:
                text = handle.read()
        except (UnicodeDecodeError, IsADirectoryError, FileNotFoundError):
            continue
        for match in CITATION.finditer(CONTINUATION.sub(" ", text)):
            token = match.group(0).rstrip(".,;:")
            if not any(rule.match(token) for rule in ALLOWED):
                yield name, token


# The four shapes that actually got through a hand scan, plus the forms that must NOT trip. A gate
# never shown to fail is a hypothesis, so this runs the machinery rather than trusting it.
SELFTEST_REJECT = [
    "3.7.2__nobody…gadget.circ",
    "nobody...widget_part2.circ",
    "harvested/3.7.2__nobody_…_sprocket__gadget.circ",
    "transcribed from `harvested/3.7.2__nobody_SomeRepo__gadget\n/// .circ`, the only corpus file",
    "3.3.0__nobody_SomeCourse__widget_part2.circ",
    "2.7.0__nobody_SomeRepo__同步計數器.circ",
]
SELFTEST_ACCEPT = [
    "3.3.0__case-269.circ",
    "harvested/3.3.0__case-269.circ",
    "golden-07.circ",
    "3.0.0__case-167.circ::Ctrl",
    "3.0.0__case-167.circ__Ctrl.table",
    "harvested/*.circ",
]


def fixtures_are_invented(corpus=None):
    """Fail if any illustrative string in THIS file matches a real corpus name.

    This file is the one the scan skips, and that skip is justified purely by every example in it
    being fabricated. A promise is not a check: the first two attempts at these fixtures both used
    real names, the second having fabricated the OWNER and kept the real FILENAME. So when a corpus
    is present, verify the claim instead of asserting it. Absent a corpus there is nothing to
    compare against, and that is reported rather than passed over.
    """
    corpus = corpus or os.environ.get("LOGISIM_CORPUS")
    if not corpus:
        # Not a failure: a public clone has no corpus and never will. Say so, so that a green run
        # here is not read as having checked something it could not.
        print("  note: no LOGISIM_CORPUS, so this file's own fixtures were NOT verified against "
              "the corpus. Run with it set to check them.")
        return []
    manifest = os.path.join(corpus, "handles.json")
    if not os.path.exists(manifest):
        # A configured corpus that cannot answer IS a failure, per `tools/corpus.py`: the whole
        # point of that contract is that "nothing to compare against" must never read as "nothing
        # wrong".
        return [f"{manifest} is missing, so a corpus is configured but cannot be checked against"]
    with open(manifest, encoding="utf-8") as handle:
        paths = json.load(handle).values()
    mine = open(os.path.abspath(__file__), encoding="utf-8").read().lower()
    bad = []
    for path in paths:
        base = os.path.basename(path)
        for fragment in {base, base.removesuffix(".circ")}:
            # Three characters would match half the English language; a real filename stem is
            # longer than that, and the owner/repo middle is checked as part of the basename.
            if len(fragment) > 3 and fragment.lower() in mine:
                bad.append("a real corpus name appears in this file's own examples "
                           "(not quoted here); replace it with an invented one")
    return sorted(set(bad))


def enumeration_reaches_every_tracked_file():
    """Fail unless `offenders()` actually reads awkwardly-named tracked files.

    The selftest below exercises the PATTERNS. It said nothing about enumeration, and enumeration
    had a hole: `git ls-files` was parsed with `.split()`, so a tracked path containing a space
    became several nonexistent paths whose `FileNotFoundError` the read guard then swallowed. A
    file the scan never opens is as good as a pattern that never matches.

    So this builds a throwaway repository with the same citation in an ordinary file and in a file
    whose name contains a space, and requires both to be reported.
    """
    import tempfile

    citation = "3.7.2__someowner_somerepo__leak.circ"
    with tempfile.TemporaryDirectory() as scratch:
        for name in ("ordinary.md", "a file with spaces.md"):
            with open(os.path.join(scratch, name), "w", encoding="utf-8") as handle:
                handle.write(f"cited: {citation}\n")
        quiet = {"capture_output": True, "check": True}
        subprocess.run(["git", "-C", scratch, "init", "-q"], **quiet)
        subprocess.run(["git", "-C", scratch, "add", "-A"], **quiet)
        subprocess.run(["git", "-C", scratch, "-c", "user.email=t@t", "-c", "user.name=t",
                        "commit", "-qm", "fixture"], **quiet)
        seen = {name for name, _ in offenders(scratch)}
    missing = {"ordinary.md", "a file with spaces.md"} - seen
    return [f"offenders() never read {name!r}, so it would not have found a leak there"
            for name in sorted(missing)]


def selftest():
    """Exit non-zero unless every known leak is caught and every legitimate form is passed."""
    failures = fixtures_are_invented() + enumeration_reaches_every_tracked_file()
    for sample in SELFTEST_REJECT:
        joined = CONTINUATION.sub(" ", sample)
        caught = any(
            not any(rule.match(m.group(0).rstrip(".,;:")) for rule in ALLOWED)
            for m in CITATION.finditer(joined))
        if not caught:
            failures.append(f"NOT CAUGHT (this is a leak the checker would pass): {sample!r}")
    for sample in SELFTEST_ACCEPT:
        for m in CITATION.finditer(sample):
            token = m.group(0).rstrip(".,;:")
            if not any(rule.match(token) for rule in ALLOWED):
                failures.append(f"false positive on a legitimate citation: {token!r}")
    for line in failures:
        print(f"  {line}")
    if failures:
        print(f"\n{len(failures)} selftest failure(s): the checker itself is wrong.")
        return 1
    print(f"selftest: {len(SELFTEST_REJECT)} known leaks caught, "
          f"{len(SELFTEST_ACCEPT)} legitimate forms passed")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    bad = list(offenders())
    for name, token in bad:
        print(f"  {name}: {token}")
    if bad:
        print(f"\n{len(bad)} corpus citation(s) are not anonymous handles. Each one is a filename "
              f"from a student repository.\nResolve them through `tools/corpus.py` and cite the "
              f"handle instead; do not widen the allow-list to make this pass.")
        sys.exit(1)
    print("every corpus citation is an anonymous handle")
