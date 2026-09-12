#!/usr/bin/env python3
"""Resolve an anonymous corpus handle to the file it stands for.

WHY HANDLES EXIST
-----------------
The differential gates run against a corpus of real circuits: one half harvested from public
student repositories, one half the author's own course lab files. Neither half is publishable. The
harvested half is keyed by repository owner, so a filename identifies a person even when the file
itself is absent, and the lab files' golden truth tables are effectively lab solutions.

So the tracked tree cites corpus files by handle, and the handle-to-filename map ships with the
corpus rather than with the port:

    3.3.0__case-269.circ   a harvested file, the number stable across the whole repository
    golden-07.circ         one of the author's course lab files
    $LOGISIM_CORPUS/handles.json   {handle: path relative to the corpus root}

The format version survives in a harvested handle because the corpus spans six `.circ` format
generations and several measurements turn on which generation a file came from. The owner and the
repository do not survive at all.

THREE OUTCOMES, AND THEY ARE NOT THE SAME
-----------------------------------------
    no `LOGISIM_CORPUS`        the gate does not apply. Skip, and print that it skipped.
    corpus, but no manifest    MISCALIBRATED. A corpus predating the handle scheme cannot resolve
                               a handle, and a gate that quietly treats that as "nothing to do"
                               is the failure mode `gateaudit.py` exists to catch. Raise.
    corpus and manifest        resolve, or raise naming the handle.

Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
"""
import json
import os

MANIFEST = "handles.json"


def root():
    """The corpus root, or None when the gate does not apply."""
    return os.environ.get("LOGISIM_CORPUS") or None


def manifest(corpus=None):
    """{handle: path relative to the corpus root}. Raises if the corpus carries no manifest."""
    corpus = corpus or root()
    if not corpus:
        raise LookupError("LOGISIM_CORPUS is unset; there is no corpus to resolve against")
    path = os.path.join(corpus, MANIFEST)
    if not os.path.exists(path):
        raise LookupError(
            f"{path} is missing. The tracked tree cites corpus files by handle, so a corpus "
            f"without a manifest cannot resolve any of them. Regenerate it beside the corpus; "
            f"do not fall back to guessing, because a gate that silently resolves nothing "
            f"reports green while checking zero cases.")
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def resolve(handle, corpus=None):
    """The path of `handle` relative to the corpus root: a name under `harvested/`."""
    table = manifest(corpus)
    if handle not in table:
        raise LookupError(f"{handle} is not in the corpus manifest")
    return table[handle]


def basename(handle, corpus=None):
    """Just the filename, which is what the gates pass to `--filter`."""
    return os.path.basename(resolve(handle, corpus))
