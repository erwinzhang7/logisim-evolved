#!/bin/bash
#
# build-app.sh: assemble, sign and verify logisim-evolved.app.
#
# Part of logisim-evolved. Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
#
# ══════════════════════════════════════════════════════════════════════════════════════
# WHY THIS SCRIPT EXISTS
#
# Upstream issue #2699: the macOS build fails Gatekeeper, and the Homebrew cask was
# disabled over it. Upstream cannot fix it; they have said in the issue that they have no
# paid Apple Developer account. D10 records that this port is meant to, and closing #2699 is
# a large part of why the port exists: macOS installs of logisim-evolution are a known pain
# point for the CSC258 students this is for.
#
# `swift build --product logisim-evolved-app` produces a bare Mach-O with an ad-hoc
# signature. It runs, but `spctl -a` rejects it, it has no Info.plist of ours, no bundle ID,
# no icon, and no way to open a `.circ` by double-click. This script is the missing half.
#
# ══════════════════════════════════════════════════════════════════════════════════════
# THE HONESTY RULE, and it is the reason for most of the code below
#
# The one thing this script must never do is emit a bundle that *looks* shippable but is
# not. Three ways that happens, all guarded against here:
#
#   1. Silently producing an unsigned bundle when no identity is found. Instead: the run is
#      labelled UNSIGNED in its own output, the bundle is named so you cannot mistake it,
#      and the exact missing prerequisite is printed.
#   2. Reporting "signed" when only the ad-hoc signature SwiftPM already applied is present.
#      Guarded by reading the authority back out of `codesign -dv` and comparing.
#   3. Reporting success from a step that wrote nothing. Every artefact is asserted to exist
#      and to be non-trivially sized before the next step runs.
#
# Gatekeeper acceptance is *measured*, not asserted, at the end of every run: including
# runs where it is expected to fail. "It builds" is not the gate.
#
# ══════════════════════════════════════════════════════════════════════════════════════
# USAGE
#
#   tools/package/build-app.sh                     # build, sign if possible, verify
#   tools/package/build-app.sh --no-sign           # deliberately unsigned; still verifies
#   tools/package/build-app.sh --identity "NAME"   # pick a specific codesigning identity
#   tools/package/build-app.sh --dmg               # also produce a distributable disk image
#   tools/package/build-app.sh --configuration debug
#   tools/package/build-app.sh --output DIR        # default: <repo>/.build-package
#
# Requires only a clone, a Swift toolchain and the Xcode command line tools. It does not
# need network access unless signing (`--timestamp` contacts Apple's timestamp server).
#
# NOTARISATION IS NOT DONE HERE. It needs Apple ID credentials this script deliberately
# never touches; run `tools/package/notarize.sh` afterwards, which prints exactly what the
# owner must supply. See docs/experiments/packaging.md.
# ══════════════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────────────

APP_NAME="logisim-evolved"
BUNDLE_ID="app.closiq.logisim-evolved"
SWIFT_PRODUCT="logisim-evolved-app"

# D10 pins the port's version reporting to AboutFacts. `-dev` is deliberate: AboutFacts
# says in as many words that the port is not at parity with 4.1.0, and shipping a bare
# "0.1.0" would delete that caveat from the About window.
SHORT_VERSION="0.1.0-dev"

CONFIGURATION="release"
WANT_SIGN="auto"      # auto | yes | no
WANT_DMG="no"
IDENTITY=""
OUTPUT_DIR=""

# ── Argument parsing ──────────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration) CONFIGURATION="$2"; shift 2 ;;
    --identity)      IDENTITY="$2"; WANT_SIGN="yes"; shift 2 ;;
    --output)        OUTPUT_DIR="$2"; shift 2 ;;
    --sign)          WANT_SIGN="yes"; shift ;;
    --no-sign)       WANT_SIGN="no"; shift ;;
    --dmg)           WANT_DMG="yes"; shift ;;
    -h|--help)       sed -n '/^# USAGE$/,/^# ═*$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "build-app.sh: unknown option '$1'" >&2; exit 2 ;;
  esac
done

# ── Paths ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Fail loudly rather than assembling a bundle out of whatever happens to be nearby. This is
# a fork of logisim-evolution, so a checkout can look right while sitting on the Java tree.
[[ -f "$REPO_ROOT/swift/Package.swift" ]] || {
  echo "build-app.sh: $REPO_ROOT/swift/Package.swift is missing — wrong tree?" >&2; exit 1; }
[[ -f "$REPO_ROOT/LICENSE.md" ]] || {
  echo "build-app.sh: $REPO_ROOT/LICENSE.md is missing; GPLv3 §5 needs it in the bundle" >&2
  exit 1; }

OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/.build-package}"
STAGE_DIR="$OUTPUT_DIR/stage"

# CFBundleVersion has to be monotonic and numeric-ish. The commit count is both, it is
# derived rather than remembered, and it maps back to an exact revision.
if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  BUILD_VERSION="$(git -C "$REPO_ROOT" rev-list --count HEAD)"
  REVISION="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
  git -C "$REPO_ROOT" diff --quiet HEAD 2>/dev/null || REVISION="$REVISION-dirty"
else
  BUILD_VERSION="0"
  REVISION="unknown"
fi

say()  { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }
die()  { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ── 1. Build the executable ───────────────────────────────────────────────────────────

say "Building $SWIFT_PRODUCT ($CONFIGURATION)"
swift build --package-path "$REPO_ROOT/swift" -c "$CONFIGURATION" --product "$SWIFT_PRODUCT"

BIN_DIR="$(swift build --package-path "$REPO_ROOT/swift" -c "$CONFIGURATION" --show-bin-path)"
EXECUTABLE="$BIN_DIR/$SWIFT_PRODUCT"
[[ -x "$EXECUTABLE" ]] || die "swift build reported success but $EXECUTABLE is not there"
note "$(file -b "$EXECUTABLE")"

# ── 2. Assemble the bundle ────────────────────────────────────────────────────────────

say "Assembling $APP_NAME.app"
APP="$STAGE_DIR/$APP_NAME.app"
rm -rf "$STAGE_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Named `logisim-evolved`, not `logisim-evolved-app`: the `-app` suffix names a SwiftPM
# product, and would otherwise be the process name in Activity Monitor and crash reports.
cp "$EXECUTABLE" "$APP/Contents/MacOS/$APP_NAME"
chmod 755 "$APP/Contents/MacOS/$APP_NAME"

printf 'APPL????' > "$APP/Contents/PkgInfo"

# ── 3. Icons ──────────────────────────────────────────────────────────────────────────
#
# Drawn from scratch by make-icon.swift; D10 requires the port's own icon and D12 warns off
# inheriting upstream's artwork. See that file for why it is code and not a committed blob.

say "Drawing icons"
swift "$SCRIPT_DIR/make-icon.swift" "$APP/Contents/Resources"
for icns in "$APP_NAME.icns" "$APP_NAME-circuit.icns"; do
  [[ -s "$APP/Contents/Resources/$icns" ]] || die "make-icon.swift did not write $icns"
done

# ── 4. Info.plist ─────────────────────────────────────────────────────────────────────

say "Writing Info.plist"

# GPLv3 §5 on the surface Finder shows without launching the app.
COPYRIGHT="A modified version of logisim-evolution, begun 4 September 2026. \
Copyright © 2001–2024 Logisim-evolution developers; original Logisim by Carl Burch, \
Hendrix College. Swift/macOS translation © 2026 Closiq Inc. Licensed GPL-3.0-only, \
with ABSOLUTELY NO WARRANTY. Not endorsed by or affiliated with logisim-evolution."

python3 - "$SCRIPT_DIR/Info.plist.in" "$APP/Contents/Info.plist" <<PY
import sys, html
src, dst = sys.argv[1], sys.argv[2]
subs = {
    "@SHORT_VERSION@": "$SHORT_VERSION",
    "@BUILD_VERSION@": "$BUILD_VERSION",
    "@COPYRIGHT@": html.escape("""$COPYRIGHT""".strip()),
}
text = open(src, encoding="utf-8").read()
for token, value in subs.items():
    if token not in text:
        sys.exit(f"Info.plist.in no longer contains {token}")
    text = text.replace(token, value)
open(dst, "w", encoding="utf-8").write(text)
PY

# Assert the oracle produced output: a template substitution that quietly wrote an empty or
# malformed file is indistinguishable from success until Finder refuses to launch the app.
plutil -lint "$APP/Contents/Info.plist" >/dev/null || die "generated Info.plist is malformed"
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")" == "$BUNDLE_ID" ]] \
  || die "Info.plist CFBundleIdentifier is not $BUNDLE_ID"
note "CFBundleIdentifier      $BUNDLE_ID"
note "CFBundleShortVersion    $SHORT_VERSION"
note "CFBundleVersion         $BUILD_VERSION   (revision $REVISION)"

# The exported UTI in the plist and the one compiled into LogisimDocumentType must agree, or
# DocumentGroup resolves nothing and .circ files open into a void with no error shown.
PLIST_UTI="$(plutil -extract UTExportedTypeDeclarations.0.UTTypeIdentifier raw -o - \
  "$APP/Contents/Info.plist")"
SOURCE_UTI="$(sed -n 's/.*static let identifier = "\(.*\)"/\1/p' \
  "$REPO_ROOT/swift/Sources/LogisimUI/Seams/ProjectSeam.swift" | head -1)"
[[ -n "$SOURCE_UTI" ]] || die "could not read LogisimDocumentType.identifier from ProjectSeam.swift"
[[ "$PLIST_UTI" == "$SOURCE_UTI" ]] || die \
  "UTI drift: Info.plist says '$PLIST_UTI', LogisimDocumentType.identifier says '$SOURCE_UTI'"
note "document UTI            $PLIST_UTI   (matches LogisimDocumentType)"

# ── 5. GPLv3 §5 notices ───────────────────────────────────────────────────────────────
#
# The About window carries the full notice set already (AboutFacts). These are the copies
# that survive in the bundle itself, which is what §5 is actually about; a recipient who
# has the binary and not the repository.

say "Installing legal notices"
cp "$REPO_ROOT/LICENSE.md" "$APP/Contents/Resources/LICENSE.md"

# §6: "published alongside every binary". There is no public repository URL yet, AboutFacts
# records the same gap, with sourceURL = nil, so the offer states the obligation instead of
# linking somewhere wrong. Pointing at *upstream's* repository would misstate where this
# program's Corresponding Source is, which is the one lie a §6 offer must not tell.
SOURCE_OFFER="The complete corresponding source for this program, including the whole build \
pipeline, is published alongside every binary as GPLv3 section 6 requires. It is a separate \
repository from logisim-evolution's. **This build predates that repository being public**; \
if you received this binary without a source link, that is a licence defect — ask the \
distributor, who is obliged to supply it."

python3 - "$SCRIPT_DIR/NOTICE.md.in" "$APP/Contents/Resources/NOTICE.md" <<PY
import sys
src, dst = sys.argv[1], sys.argv[2]
subs = {
    "@SHORT_VERSION@": "$SHORT_VERSION",
    "@BUILD_VERSION@": "$BUILD_VERSION",
    "@REVISION@": "$REVISION",
    "@SOURCE_OFFER@": """$SOURCE_OFFER""".strip(),
}
text = open(src, encoding="utf-8").read()
for token, value in subs.items():
    if token not in text:
        sys.exit(f"NOTICE.md.in no longer contains {token}")
    text = text.replace(token, value)
open(dst, "w", encoding="utf-8").write(text)
PY

for required in LICENSE.md NOTICE.md; do
  [[ -s "$APP/Contents/Resources/$required" ]] || die "$required did not reach the bundle"
done
grep -q "GNU GENERAL PUBLIC LICENSE" "$APP/Contents/Resources/LICENSE.md" \
  || die "bundled LICENSE.md does not look like the GPL"
grep -q "modified version" "$APP/Contents/Resources/NOTICE.md" \
  || die "bundled NOTICE.md is missing the §5(a) modification notice"
note "LICENSE.md, NOTICE.md   installed in Contents/Resources"

# ── 6. Signing ────────────────────────────────────────────────────────────────────────
#
# Notarisation requires a Developer ID Application certificate, the hardened runtime, and a
# secure timestamp. Anything less will be *accepted by codesign* and *rejected by Apple*,
# hours later, which is the expensive failure mode. So the requirements are enforced here.

say "Signing"

if [[ "$WANT_SIGN" != "no" && -z "$IDENTITY" ]]; then
  # Match only Developer ID Application. An "Apple Development" certificate signs fine and
  # then fails notarisation, and "Apple Distribution" is for the App Store, which D10 rules
  # out on three independent grounds. Picking either would be a trap.
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | sed -n 1p)"
fi

SIGNED="no"
SIGN_NOTE=""

if [[ "$WANT_SIGN" == "no" ]]; then
  SIGN_NOTE="--no-sign was requested."
elif [[ -z "$IDENTITY" ]]; then
  SIGN_NOTE="No 'Developer ID Application' identity is in the keychain."
else
  note "identity: $IDENTITY"
  # --options runtime  : the hardened runtime. Notarisation refuses anything without it.
  # --timestamp        : a secure timestamp from Apple. Needs network; also required.
  # No entitlements file: `otool -L` shows this binary links nothing but system frameworks
  # and /usr/lib/swift, so it needs no hardened-runtime exception. Adding entitlements it
  # does not need would widen the attack surface and slow notarisation review.
  if codesign --force --sign "$IDENTITY" --options runtime --timestamp \
       --identifier "$BUNDLE_ID" "$APP" 2>&1 | sed 's/^/  /'; then
    SIGNED="yes"
  else
    SIGN_NOTE="codesign failed (see above; --timestamp needs network access)."
  fi
fi

if [[ "$SIGNED" == "yes" ]]; then
  # Guard against reporting "signed" when what is actually present is SwiftPM's own ad-hoc
  # signature. Read the authority back out rather than trusting codesign's exit status.
  # Captured whole, then matched; not piped into `grep -q`/`head`. Under `set -o pipefail`
  # an early-exiting reader SIGPIPEs codesign and the pipeline reports failure on a
  # perfectly good bundle. notarize.sh was bitten by exactly that.
  CS_INFO="$(codesign -dv --verbose=4 "$APP" 2>&1 || true)"
  AUTHORITY="$(printf '%s\n' "$CS_INFO" | sed -n 's/^Authority=//p' | sed -n 1p)"
  case "$AUTHORITY" in
    "Developer ID Application: "*) note "verified authority: $AUTHORITY" ;;
    "") die "codesign succeeded but the bundle has no signing authority — ad-hoc?" ;;
    *)  die "signed by '$AUTHORITY', which is not a Developer ID Application certificate" ;;
  esac
else
  cat <<EOF

  ╭──────────────────────────────────────────────────────────────────────────────────╮
  │  THIS BUNDLE IS NOT SIGNED.                                                      │
  │                                                                                  │
  │  $(printf '%-80s' "$SIGN_NOTE")│
  │                                                                                  │
  │  It will run on the machine that built it and NOWHERE ELSE without the user       │
  │  right-clicking → Open, or clearing the quarantine flag by hand. That is the      │
  │  exact experience upstream issue #2699 is about. Do not distribute it.            │
  │                                                                                  │
  │  To sign, you need a Developer ID Application certificate from a paid Apple       │
  │  Developer Program membership, installed in the login keychain. Check with:       │
  │      security find-identity -v -p codesigning                                     │
  ╰──────────────────────────────────────────────────────────────────────────────────╯
EOF
  # Rename so an unsigned build cannot be mistaken for a shippable one further downstream.
  mv "$APP" "$STAGE_DIR/$APP_NAME-UNSIGNED.app"
  APP="$STAGE_DIR/$APP_NAME-UNSIGNED.app"
fi

# ── 7. Measure Gatekeeper ─────────────────────────────────────────────────────────────
#
# Always run, on every path, including the ones expected to fail. A packaging script that
# only measures when it expects to pass is not measuring.

say "Gatekeeper and signature — measured, verbatim"

echo
echo "\$ codesign -dv --verbose=4 $(basename "$APP")"
codesign -dv --verbose=4 "$APP" 2>&1 | sed 's/^/  /' || true

echo
echo "\$ codesign --verify --deep --strict --verbose=2 $(basename "$APP")"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /' || true

echo
echo "\$ spctl -a -vvv --type exec $(basename "$APP")"
SPCTL_OUT="$(spctl -a -vvv --type exec "$APP" 2>&1 || true)"
echo "$SPCTL_OUT" | sed 's/^/  /'

echo
if echo "$SPCTL_OUT" | grep -q "accepted"; then
  printf '\033[1;32m  GATEKEEPER: accepted.\033[0m #2699 is closable on this artefact.\n'
elif echo "$SPCTL_OUT" | grep -q "Unnotarized Developer ID"; then
  printf '\033[1;33m  GATEKEEPER: rejected — signed but NOT NOTARISED.\033[0m\n'
  printf '  A Developer ID signature alone does not clear Gatekeeper; notarisation is the\n'
  printf '  load-bearing half. Missing step: submit to Apple with notarytool, then staple.\n'
  printf '  Run tools/package/notarize.sh — it needs credentials this script never touches.\n'
else
  printf '\033[1;31m  GATEKEEPER: rejected.\033[0m Missing step: a Developer ID signature.\n'
fi

# ── 8. Optional disk image ────────────────────────────────────────────────────────────
#
# D10 ships a DMG. It is what gets notarised and stapled: stapling an .app works, but a
# .app moved out of a zip loses nothing whereas a DMG carries the staple to the user
# offline, which is the case that matters for a lecture hall with bad wifi.

if [[ "$WANT_DMG" == "yes" ]]; then
  say "Building disk image"
  DMG="$OUTPUT_DIR/$(basename "$APP" .app)-$SHORT_VERSION.dmg"
  rm -f "$DMG"
  ln -sf /Applications "$STAGE_DIR/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE_DIR" -ov -format UDZO \
    -fs HFS+ "$DMG" | sed 's/^/  /'
  [[ -s "$DMG" ]] || die "hdiutil reported success but wrote no image"
  if [[ "$SIGNED" == "yes" ]]; then
    codesign --force --sign "$IDENTITY" --timestamp "$DMG"
    note "disk image signed"
  fi
  note "$DMG ($(du -h "$DMG" | cut -f1))"
fi

say "Done"
note "$APP"
[[ "$SIGNED" == "yes" ]] || note "Unsigned — see the box above."
