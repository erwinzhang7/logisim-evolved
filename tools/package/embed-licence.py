#!/usr/bin/env python3
"""Regenerate `LicenceTextGPL3.swift` from `LICENSE.md`.

That file says "GENERATED FILE; do not hand-edit ... regenerate rather than patching here", and
until now there was nothing to regenerate it WITH. The instruction was therefore advice, and the
two copies could drift silently: §4 obliges anyone conveying the work to give recipients a copy of
the licence, and the copy a user of the application actually sees is the embedded one.

    python3 tools/package/embed-licence.py [--check]

`--check` exits non-zero if the embedded copy is stale, which is what the test suite asserts.

Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
"""
import hashlib
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LICENCE = os.path.join(REPO, "LICENSE.md")
EMBEDDED = os.path.join(REPO, "swift/Sources/LogisimUI/About/LicenceTextGPL3.swift")

# The literal is a raw multiline string, so the licence text needs no escaping; the delimiter is
# `#"""` precisely so that nothing inside it can terminate it early.
BODY = re.compile(r'(static let markdown(?:: String)? = #"""\n)(.*?)(\n"""#)', re.DOTALL)
DIGEST = re.compile(r'(static let sourceDigest = ")[0-9a-f]{64}(")')


def render(licence_text, swift_text):
    if not BODY.search(swift_text):
        raise SystemExit("could not find the licence literal in the embedded file; the pattern "
                         "and the declaration have diverged. Refusing to report success.")
    if not DIGEST.search(swift_text):
        raise SystemExit("could not find the recorded digest in the embedded file.")
    # ONE trailing blank line, which the file's own header explains: a Swift multiline literal
    # drops the final newline, and the licence ends with one.
    body = licence_text.rstrip("\n") + "\n"
    swift_text = BODY.sub(lambda m: m.group(1) + body + m.group(3), swift_text, count=1)
    digest = hashlib.sha256(licence_text.encode("utf-8")).hexdigest()
    return DIGEST.sub(lambda m: m.group(1) + digest + m.group(2), swift_text, count=1), digest


if __name__ == "__main__":
    with open(LICENCE, encoding="utf-8") as handle:
        licence = handle.read()
    with open(EMBEDDED, encoding="utf-8") as handle:
        current = handle.read()
    updated, digest = render(licence, current)
    if "--check" in sys.argv:
        if updated != current:
            print(f"{EMBEDDED} is stale: regenerate with tools/package/embed-licence.py")
            sys.exit(1)
        print(f"embedded licence matches LICENSE.md ({digest[:12]}…)")
        sys.exit(0)
    if updated == current:
        print("already up to date")
        sys.exit(0)
    with open(EMBEDDED, "w", encoding="utf-8") as handle:
        handle.write(updated)
    print(f"regenerated {os.path.relpath(EMBEDDED, REPO)}; LICENSE.md sha256 {digest}")
