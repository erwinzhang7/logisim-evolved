#!/bin/bash
#
# notarize.sh: submit a signed logisim-evolved artefact to Apple, then staple it.
#
# Part of logisim-evolved. Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
#
# ══════════════════════════════════════════════════════════════════════════════════════
# WHERE THE CREDENTIAL BOUNDARY IS, AND WHY IT IS HERE
#
# `build-app.sh` gets an artefact all the way to "Developer ID signed, hardened runtime,
# secure timestamp". `spctl` still rejects that, with `source=Unnotarized Developer ID`;
# a Developer ID signature alone does not clear Gatekeeper. Notarisation is the other half,
# and it is the half that needs an Apple account credential.
#
# THIS SCRIPT NEVER ASKS FOR, READS, STORES OR TRANSMITS A CREDENTIAL. It looks for a
# keychain profile that the owner created himself, with a command this script prints but
# does not run. If no profile exists it stops and tells him exactly what to type. That
# boundary is deliberate: a packaging script is the wrong place to be handling an Apple ID
# password, and `notarytool store-credentials` already does it properly, once, into the
# keychain.
#
# Usage:
#   tools/package/notarize.sh <path-to.app|.dmg|.zip> [--profile NAME]
#   tools/package/notarize.sh <artefact> --verify-only    # pre-flight + Gatekeeper, no submission
#
# Default profile name: logisim-evolved-notary
# ══════════════════════════════════════════════════════════════════════════════════════

set -euo pipefail

PROFILE="logisim-evolved-notary"
VERIFY_ONLY="no"
TEAM_ID="${LOGISIM_TEAM_ID:?set LOGISIM_TEAM_ID to your Apple Developer Team ID}"
# Read from the environment rather than written here. A Team ID is not a secret, but it is the
# maintainer's identity and a public repository has no use for it: anyone signing their own
# build needs their own.
ARTEFACT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --verify-only) VERIFY_ONLY="yes"; shift ;;
    -h|--help) sed -n '/^# Usage:/,/^# ═*$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) ARTEFACT="$1"; shift ;;
  esac
done

say()  { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }
die()  { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[[ -n "$ARTEFACT" ]] || die "usage: notarize.sh <path-to.app|.dmg|.zip> [--profile NAME]"
[[ -e "$ARTEFACT" ]] || die "$ARTEFACT does not exist"

# ── 1. Refuse to submit something that will be rejected ───────────────────────────────
#
# Apple's rejections arrive minutes to hours later as a JSON log, and every one of these
# conditions is checkable in a second here. Checking first is the difference between a
# typo and a wasted afternoon.

say "Pre-flight"

# Captured ONCE into a variable, deliberately. Piping `codesign` straight into `grep -q`
# looks equivalent and is not: under `set -o pipefail`, grep exits at the first match,
# codesign takes SIGPIPE, and the pipeline reports failure on a bundle that is perfectly
# fine. That cost a false "no secure timestamp" on a correctly timestamped bundle here.
CS_INFO="$(codesign -dv --verbose=4 "$ARTEFACT" 2>&1 || true)"
field() { printf '%s\n' "$CS_INFO" | sed -n "s/^$1=//p" | sed -n 1p; }

AUTHORITY="$(field Authority)"
case "$AUTHORITY" in
  "Developer ID Application: "*) note "signature:  $AUTHORITY" ;;
  "") die "$ARTEFACT is not signed at all. Run tools/package/build-app.sh first." ;;
  *)  die "signed by '$AUTHORITY'; notarisation requires a Developer ID Application certificate." ;;
esac

# The hardened runtime is a property of EXECUTABLE CODE, not of a signed container, so this check
# applies to a bundle and not to a disk image. Requiring it of a `.dmg` refuses artefacts Apple
# accepts: measured against `ClosiqSync-1.0.1.dmg`, notarised and stapled by this same team on
# 2026-09-02, whose signature reads `flags=0x0(none)`. This script's usage line has advertised
# `.dmg` since it was written while its pre-flight rejected every one of them.
#
# What Apple actually requires is the hardened runtime on the executables INSIDE, which is checked
# when the .app itself is notarised, and this project notarises the app before wrapping it.
FLAGS="$(printf '%s\n' "$CS_INFO" | sed -n 's/^CodeDirectory .*flags=\([^ ]*\).*/\1/p' | sed -n 1p)"
case "$ARTEFACT" in
  *.dmg)
    note "hardened:   n/a for a disk image (flags=$FLAGS); the app inside carries it"
    # A DMG wrapping an un-notarised app would sail through here and fail at Apple, so check the
    # PAYLOAD. The first version of this ran `stapler validate` against the DMG itself, which has
    # no ticket yet before its own submission, and so reported "payload: NOT stapled" for a payload
    # that was correctly stapled. A check whose label does not match what it measures is worse than
    # no check. Mount read-only and look at the app.
    DMG_MOUNT="$(hdiutil attach -nobrowse -readonly "$ARTEFACT" 2>/dev/null \
      | sed -n 's:.*\(/Volumes/.*\):\1:p' | sed -n 1p)"
    if [[ -n "$DMG_MOUNT" ]]; then
      PAYLOAD="$(find "$DMG_MOUNT" -maxdepth 1 -name '*.app' -print -quit 2>/dev/null)"
      if [[ -z "$PAYLOAD" ]]; then
        note "payload:    no .app at the top level of the image"
      elif xcrun stapler validate "$PAYLOAD" >/dev/null 2>&1; then
        note "payload:    $(basename "$PAYLOAD") is stapled"
      else
        note "payload:    $(basename "$PAYLOAD") is NOT stapled — notarise the .app first"
      fi
      hdiutil detach "$DMG_MOUNT" >/dev/null 2>&1 || true
    else
      note "payload:    could not mount the image to check it"
    fi
    ;;
  *)
    case "$FLAGS" in
      *runtime*) note "hardened:   yes ($FLAGS)" ;;
      *) die "the hardened runtime is not enabled ($FLAGS). Apple will reject this. Re-sign with --options runtime." ;;
    esac
    ;;
esac

TIMESTAMP="$(field Timestamp)"
[[ -n "$TIMESTAMP" ]] \
  || die "no secure timestamp. Apple will reject this. Re-sign with --timestamp (needs network)."
note "timestamp:  $TIMESTAMP"

# ── 2. The credential boundary ────────────────────────────────────────────────────────

SUBMISSION_ID="(not submitted)"
if [[ "$VERIFY_ONLY" == "yes" ]]; then
  say "Verify only"
  note "skipping credentials, submission and stapling; measuring what is already on disk"
else

say "Credentials"

if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  note "keychain profile '$PROFILE' is present."
else
  cat <<EOF

  ╭──────────────────────────────────────────────────────────────────────────────────╮
  │  STOP — this is the credential boundary. Nothing past here can be automated for   │
  │  you, and this script will not try.                                               │
  ╰──────────────────────────────────────────────────────────────────────────────────╯

  No notarytool keychain profile named '$PROFILE' was found.

  Notarisation needs an Apple credential that only you can supply. Create the profile
  ONCE, by hand, in a real terminal — it will prompt for the password interactively and
  store it in your login keychain, so no secret is ever passed on a command line, written
  to a file, or recorded in a shell history:

      xcrun notarytool store-credentials "$PROFILE" \\
          --apple-id "<your Apple ID email>" \\
          --team-id "$TEAM_ID"

  It will then ask for an APP-SPECIFIC PASSWORD — not your Apple ID password. Generate one
  at https://account.apple.com → Sign-In and Security → App-Specific Passwords.

  (The alternative is an App Store Connect API key, which avoids the Apple ID entirely:
       xcrun notarytool store-credentials "$PROFILE" \\
           --key <path/to/AuthKey_XXXXXXXX.p8> --key-id <KEY_ID> --issuer <ISSUER_UUID>
   Prefer this if you ever automate it in CI, since it is revocable per-key.)

  Then re-run:  tools/package/notarize.sh "$ARTEFACT"

EOF
  exit 3
fi

# ── 3. Submit ─────────────────────────────────────────────────────────────────────────
#
# An .app cannot be uploaded directly; notarytool takes a zip, a dmg or a pkg. A plain
# `zip -r` would drop symlinks and extended attributes and produce a bundle Apple rejects,
# so use ditto's PKZip mode, which is what Apple documents.

SUBMISSION="$ARTEFACT"
TEMP_ZIP=""
if [[ "$ARTEFACT" == *.app ]]; then
  TEMP_ZIP="$(dirname "$ARTEFACT")/$(basename "$ARTEFACT" .app)-notarize.zip"
  say "Zipping the bundle for upload"
  rm -f "$TEMP_ZIP"
  /usr/bin/ditto -c -k --keepParent "$ARTEFACT" "$TEMP_ZIP"
  [[ -s "$TEMP_ZIP" ]] || die "ditto reported success but wrote no archive"
  note "$TEMP_ZIP ($(du -h "$TEMP_ZIP" | cut -f1))"
  SUBMISSION="$TEMP_ZIP"
fi

say "Submitting to Apple (this typically takes 1–15 minutes)"
notarytool_log="$(dirname "$ARTEFACT")/notarytool.json"
if ! xcrun notarytool submit "$SUBMISSION" --keychain-profile "$PROFILE" --wait \
       --output-format json > "$notarytool_log"; then
  cat "$notarytool_log" >&2
  die "notarytool submit failed — see $notarytool_log"
fi
cat "$notarytool_log"

STATUS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' \
  "$notarytool_log")"
SUBMISSION_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' \
  "$notarytool_log")"

if [[ "$STATUS" != "Accepted" ]]; then
  echo
  note "Apple's status is '$STATUS'. The reason is in the submission log:"
  note "    xcrun notarytool log $SUBMISSION_ID --keychain-profile $PROFILE"
  die "not notarised."
fi
note "Apple accepted submission $SUBMISSION_ID"
[[ -n "$TEMP_ZIP" ]] && rm -f "$TEMP_ZIP"

# ── 4. Staple ─────────────────────────────────────────────────────────────────────────
#
# Acceptance is recorded on Apple's servers; stapling writes the ticket into the artefact
# so Gatekeeper clears it OFFLINE. That is not a nicety here; the target user is a student
# in a lecture hall on bad wifi, which is precisely the case an unstapled build fails.

say "Stapling the ticket"
xcrun stapler staple "$ARTEFACT" | sed 's/^/  /'
xcrun stapler validate "$ARTEFACT" | sed 's/^/  /'

fi   # end of the submit-and-staple path

# ── 5. Measure, do not assert ─────────────────────────────────────────────────────────

say "Gatekeeper — measured, verbatim"
echo

# `--type exec` asks "is this an executable I should allow to run", and a disk image is not one:
# it answers `rejected (the code is valid but does not seem to be an app)` for a perfectly good,
# notarised, stapled DMG. This step reported exactly that and told the operator DO NOT SHIP on an
# artefact Apple had just accepted. A disk image is assessed as something being OPENED, through its
# primary signature, which is what the macOS-signing playbook prescribes.
#
# Same category error as the hardened-runtime check above, and both were invisible until the .dmg
# path was actually exercised, which suggests it never had been.
case "$ARTEFACT" in
  *.dmg) SPCTL_ARGS=(--assess --type open --context context:primary-signature -vv) ;;
  *)     SPCTL_ARGS=(-a -vvv --type exec) ;;
esac
echo "\$ spctl ${SPCTL_ARGS[*]} $(basename "$ARTEFACT")"
SPCTL_OUT="$(spctl "${SPCTL_ARGS[@]}" "$ARTEFACT" 2>&1 || true)"
echo "$SPCTL_OUT" | sed 's/^/  /'
echo
if echo "$SPCTL_OUT" | grep -q "accepted"; then
  printf '\033[1;32m  GATEKEEPER: accepted.\033[0m Upstream #2699 is closed for this artefact.\n'
  printf '  Verify on a machine that has never seen this build before shipping it — the\n'
  printf '  building Mac has provenance the recipient does not.\n'
else
  printf '\033[1;31m  GATEKEEPER: still rejected after notarisation and stapling.\033[0m\n'
  printf '  Do not ship. Read the log: xcrun notarytool log %s --keychain-profile %s\n' \
    "$SUBMISSION_ID" "$PROFILE"
  exit 1
fi
