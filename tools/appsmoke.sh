#!/bin/bash
# appsmoke.sh; does the SHIPPED artifact actually put a window on the screen?
#
# WHY THIS EXISTS
# ---------------
# Every other gate in this project measures the library targets. Nothing measured the one thing
# a user does first: double-click the app and see a window. `swift test` cannot answer it;
# `DocumentGroup` is a SwiftUI scene, and a scene that never materialises fails no unit test.
#
# WHY IT USES CGWindowList AND NOT System Events
# ----------------------------------------------
# This is the whole point of the script, and it cost an hour to learn.
#
# Asked through System Events / the accessibility API, the running app reports **zero windows**:
#
#     osascript -e 'tell application "System Events" to tell process "logisim-evolved-app" \
#                   to get count of windows'      ->  0
#
# while the same app, at the same moment, has two on-screen windows:
#
#     CGWindowListCopyWindowInfo(.optionOnScreenOnly, …)
#       ->  pid 36689 · win 11955 · owner=logisim-evolved · 1152x739 at (180,137) · layer 0
#
# Accessibility inspection of another process needs that process to be granted Accessibility
# permission, and an ad-hoc-signed development bundle is not. The menu bar still enumerates
# fine, which is what makes it convincing: you get a full File/Edit/View/…/Help listing next to
# "windows: 0" and conclude the app launched but drew nothing. It did draw.
#
# So the accessibility answer is not a weaker signal, it is a WRONG one, and it is wrong in the
# direction that manufactures a regression. That is the same shape as the two measurement
# failures already recorded in objectives.md; the contaminated migration baseline and the
# "hung" test suite that was merely slow. All three: a plausible instrument, a definite-looking
# reading, and a conclusion about the port that the port had nothing to do with.
#
# CGWindowList needs no permission for geometry and ownership, which is all this asks for.
#
# USAGE
#     tools/appsmoke.sh [path/to/file.circ]
#
# Exit 0 if the app puts at least one on-screen layer-0 window up, 1 otherwise. Builds the
# bundle first via tools/package/build-app.sh unless APPSMOKE_SKIP_BUILD is set.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO/.build-package/stage/logisim-evolved.app"
BIN="$APP/Contents/MacOS/logisim-evolved"
WAIT="${APPSMOKE_WAIT:-10}"
DOC="${1:-}"

if [ -z "${APPSMOKE_SKIP_BUILD:-}" ]; then
  echo "▸ building the bundle"
  bash "$REPO/tools/package/build-app.sh" >/dev/null 2>&1
fi

if [ ! -x "$BIN" ]; then
  echo "  no bundle at $APP — run tools/package/build-app.sh" >&2
  exit 1
fi

# Launch the BUNDLE, not the bare binary. An unbundled binary has no Info.plist, so its document
# types are undeclared and any conclusion drawn from it says nothing about the shipped artifact.
if [ -n "$DOC" ]; then open -a "$APP" "$DOC"; else open -a "$APP"; fi
sleep "$WAIT"

PID="$(pgrep -f "logisim-evolved.app/Contents/MacOS" | head -1)"
if [ -z "$PID" ]; then
  echo "  FAIL: the app is not running $WAIT s after launch" >&2
  exit 1
fi

QUERY="$(mktemp -t appsmoke).swift"
cat > "$QUERY" <<'SWIFT'
import CoreGraphics
import Foundation

let wanted = Int(CommandLine.arguments[1]) ?? -1
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
  print("could not read the window list"); exit(2)
}
var shown = 0
for w in list {
  guard w[kCGWindowOwnerPID as String] as? Int == wanted else { continue }
  // layer 0 is a normal window. Menu-bar extras and panels live above it, and counting those
  // would let an app with no document window still pass.
  guard w[kCGWindowLayer as String] as? Int == 0 else { continue }
  let b = (w[kCGWindowBounds as String] as? [String: CGFloat]) ?? [:]
  let width = Int(b["Width"] ?? 0), height = Int(b["Height"] ?? 0)
  // A zero-area window is not a window a user can see.
  guard width > 0, height > 0 else { continue }
  shown += 1
  print("    window \(w[kCGWindowNumber as String] ?? "?") · \(width)x\(height) "
        + "at (\(Int(b["X"] ?? 0)),\(Int(b["Y"] ?? 0)))")
}
print("  on-screen layer-0 windows: \(shown)")
exit(shown > 0 ? 0 : 1)
SWIFT

swift "$QUERY" "$PID"
RESULT=$?
rm -f "$QUERY"

kill "$PID" 2>/dev/null

if [ $RESULT -eq 0 ]; then
  echo "  OK: the app shows a window${DOC:+ for $(basename "$DOC")}"
else
  echo "  FAIL: the app is running but shows no window — check DocumentGroup and the" >&2
  echo "        readable/writable content types before suspecting anything else." >&2
fi
exit $RESULT
