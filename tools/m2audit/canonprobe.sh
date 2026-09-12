#!/bin/sh
# Generate the getCanonicalPath oracle rows that LibraryRelativePathTests pins.
#
# Writes a TSV of `<input>\t<java getCanonicalPath>` to stdout, over a path set chosen to hit
# every branch of the JDK's canonicalize(): whole-path realpath, longest-existing-prefix +
# re-appended tail, `.`/`..` collapse in the tail, a symlinked directory, a leading `..`, and a
# relative path (which is resolved against user.dir, so the JVM must be started from the same
# directory the Swift test runs in for that row to be comparable, hence it is fenced off below).
#
#   tools/m2audit/canonprobe.sh > /tmp/canon.tsv
#   LOGISIM_CANON_ORACLE=/tmp/canon.tsv swift test --filter LibraryRelativePathTests
#
# The fixture tree is created here, under /tmp on purpose: on macOS /tmp is a symlink into
# /private, and that is the whole reason this method cannot be `resolvingSymlinksInPath()`.
set -eu

JAVA=${LOGISIM_JAVA:-/opt/homebrew/opt/openjdk@21/bin/java}
JAVAC=${LOGISIM_JAVAC:-/opt/homebrew/opt/openjdk@21/bin/javac}
SRC=$(cd "$(dirname "$0")" && pwd)
OUT=${LOGISIM_CANON_CLASSES:-/tmp/m2audit-canon-classes}
ROOT=${LOGISIM_CANON_FIXTURE:-/tmp/logisim-canonprobe}

"$JAVAC" -nowarn -d "$OUT" "$SRC/CanonBridge.java"

rm -rf "$ROOT"
mkdir -p "$ROOT/proj/libs"
printf 'x\n' > "$ROOT/proj/main.circ"
printf 'x\n' > "$ROOT/proj/libs/helper.circ"
ln -s "$ROOT/proj" "$ROOT/link"

"$JAVA" -cp "$OUT" CanonBridge \
  /tmp \
  /var \
  / \
  /.. \
  /../nonexistent-xyzzy \
  /nonexistent-xyzzy/deeper/still \
  "$ROOT" \
  "$ROOT/proj/libs/helper.circ" \
  "$ROOT/proj/not-created-yet.circ" \
  "$ROOT/proj/./libs/../libs/helper.circ" \
  "$ROOT/proj/libs/../../proj/libs/helper.circ" \
  "$ROOT/link/libs/helper.circ" \
  "$ROOT/link/../link/libs/helper.circ" \
  "$ROOT/proj/libs/helper.circ/../helper.circ" \
  "$ROOT/proj//libs///helper.circ" \
  "$ROOT/proj/libs/" \
  "$ROOT/../$(basename "$ROOT")/proj/libs/helper.circ"
