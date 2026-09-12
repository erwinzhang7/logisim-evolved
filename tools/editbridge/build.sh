#!/bin/sh
# Compile the edit oracle. Idempotent; safe to run from anywhere.
#
#   LOGISIM_JAR=... LOGISIM_JAVAC=... sh tools/editbridge/build.sh
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
JAR=${LOGISIM_JAR:-/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar}
JAVAC=${LOGISIM_JAVAC:-/opt/homebrew/opt/openjdk@21/bin/javac}
mkdir -p "$HERE/out"
"$JAVAC" -nowarn -cp "$JAR" -d "$HERE/out" \
  "$HERE/MemoryPreferences.java" \
  "$HERE/EditBridgeAttrTable.java" \
  "$HERE/EditBridge.java"
echo "built -> $HERE/out"
