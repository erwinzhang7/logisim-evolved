#!/bin/sh
# Generate the `toRelative` oracle rows that LibraryRelativePathTests pins, by driving the
# shipped 4.1.0 jar's own private `LibraryManager.toRelative` (see RelativeBridge.java).
#
# Writes TSV `<mainFile>\t<libraryFile>\t<currentDirectory>\t<descriptor>` to stdout.
#
#   tools/m2audit/relprobe.sh > /tmp/rel.tsv
#   LOGISIM_RELATIVE_ORACLE=/tmp/rel.tsv swift test --filter LibraryRelativePathTests
#
# The fixture is rooted at /tmp deliberately. 4.1.0 canonicalises only the FILE side and
# compares it against the raw current directory, and on macOS /tmp is a symlink into /private,
# so this tree is what makes the one-sided canonicalisation observable. A fixture anywhere
# already-canonical produces the same answer under either implementation and proves nothing.
set -eu

JAVA=${LOGISIM_JAVA:-/opt/homebrew/opt/openjdk@21/bin/java}
JAVAC=${LOGISIM_JAVAC:-/opt/homebrew/opt/openjdk@21/bin/javac}
JAR=${LOGISIM_JAR:-/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar}
SRC=$(cd "$(dirname "$0")" && pwd)
OUT=${LOGISIM_REL_CLASSES:-/tmp/m2audit-rel-classes}
ROOT=${LOGISIM_REL_FIXTURE:-/tmp/logisim-relprobe}

"$JAVAC" -nowarn -cp "$JAR" -d "$OUT" "$SRC/RelativeBridge.java"

rm -rf "$ROOT"
mkdir -p "$ROOT/proj/libs" "$ROOT/sibling"
printf 'x\n' > "$ROOT/proj/main.circ"
printf 'x\n' > "$ROOT/proj/libs/helper.circ"
printf 'x\n' > "$ROOT/sibling/other.circ"
ln -s "$ROOT/proj" "$ROOT/link"

"$JAVA" -Djava.awt.headless=true -cp "$JAR:$OUT" com.cburch.logisim.file.RelativeBridge \
  "$ROOT/proj/main.circ"          "$ROOT/proj/libs/helper.circ" \
  "$ROOT/proj/main.circ"          "$ROOT/sibling/other.circ" \
  "$ROOT/proj/main.circ"          "$ROOT/proj/not-created-yet.circ" \
  "/private$ROOT/proj/main.circ"  "$ROOT/proj/libs/helper.circ" \
  "/private$ROOT/proj/main.circ"  "/private$ROOT/sibling/other.circ" \
  "$ROOT/link/main.circ"          "$ROOT/link/libs/helper.circ" \
  "/private$ROOT/link/main.circ"  "$ROOT/link/libs/helper.circ" \
  "$ROOT/proj/./main.circ"        "$ROOT/proj/libs/../libs/helper.circ" \
  "main.circ"                     "$ROOT/proj/libs/helper.circ"
