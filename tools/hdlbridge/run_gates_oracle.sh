#!/bin/sh
# Build and run GatesBridge against the shipped 4.1.0 jar, writing the oracle to $1.
#
# Asserts the run actually produced cases. A drivable-looking entry point that writes nothing and
# exits 0 is the worst possible oracle, and this project has already been bitten by one
# (`--test-fpga … HDLONLY`), so the TOTALS line is checked rather than assumed.
set -e

JAR=/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar
JAVA=/opt/homebrew/opt/openjdk@21/bin/java
JAVAC=/opt/homebrew/opt/openjdk@21/bin/javac
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$HERE/gates-4.1.0.oracle}
CLASSES=$(mktemp -d)

"$JAVAC" -nowarn -cp "$JAR" -d "$CLASSES" "$HERE/GatesBridge.java"
"$JAVA" -Djava.awt.headless=true -cp "$JAR:$CLASSES" \
    com.cburch.logisim.std.gates.GatesBridge > "$OUT"

totals=$(grep '^TOTALS ' "$OUT" || true)
if [ -z "$totals" ]; then
  echo "FATAL: oracle produced no TOTALS line — the run did not complete" >&2
  exit 1
fi
cases=$(echo "$totals" | sed 's/.*cases=\([0-9]*\).*/\1/')
if [ "$cases" -lt 100 ]; then
  echo "FATAL: oracle produced only $cases cases; refusing to treat that as coverage" >&2
  exit 1
fi
missing=$(grep -c '^MISSING ' "$OUT" || true)
if [ "$missing" != "0" ]; then
  echo "FATAL: $missing factories were not found in their libraries" >&2
  grep '^MISSING ' "$OUT" >&2
  exit 1
fi
echo "$totals -> $OUT"
