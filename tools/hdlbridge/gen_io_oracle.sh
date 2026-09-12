#!/bin/sh
# Regenerate tools/hdlbridge/io-4.1.0.oracle by driving the real 4.1.0 classes in the shipped jar.
#
# Run from the repository root:   sh tools/hdlbridge/gen_io_oracle.sh
#
# The oracle is committed, so `swift test` needs neither a JVM nor the jar; this script only has
# to be re-run when IoBridge.java changes.
set -eu

JAVA=${JAVA:-/opt/homebrew/opt/openjdk@21/bin/java}
JAVAC=${JAVAC:-/opt/homebrew/opt/openjdk@21/bin/javac}
JAR=${LOGISIM_JAR:-/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar}
OUT=tools/hdlbridge/io-4.1.0.oracle
CLASSES=$(mktemp -d)

"$JAVAC" -nowarn -cp "$JAR" -d "$CLASSES" tools/hdlbridge/IoBridge.java
"$JAVA" -Djava.awt.headless=true -cp "$JAR:$CLASSES" com.cburch.logisim.std.io.IoBridge > "$OUT"

# A silent zero-output success looks exactly like a pass; refuse to accept one.
CASES=$(grep -c '^CASE' "$OUT" || true)
if [ "$CASES" -lt 100 ]; then
  echo "FATAL: oracle has only $CASES cases — the bridge produced (almost) nothing" >&2
  exit 2
fi
echo "$OUT: $CASES cases"
rm -rf "$CLASSES"
