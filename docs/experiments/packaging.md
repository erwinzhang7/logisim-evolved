# Packaging logisim-evolved for macOS — upstream #2699

Measured 6 September 2026 on macOS 26.6 (build 25G72), Apple silicon, from
`swift-port` at `dfa6e5afb`. Every command in this document was run; every block quoted
under "measured" is verbatim output, not a reconstruction.

Owns: `tools/package/build-app.sh`, `tools/package/notarize.sh`,
`tools/package/make-icon.swift`, `tools/package/Info.plist.in`,
`tools/package/NOTICE.md.in`.

---

## 1. Where this started, and whether the premise held

`docs/experiments/upstream-issues.md` (#2699 section) recorded, on the day before this
work: `spctl -a` rejects our binary; it is an ad-hoc signature and not a bundle. **The
premise held exactly.** Re-measured before touching anything:

```
$ codesign -dv --verbose=4 .build/arm64-apple-macosx/release/logisim-evolved-app
CodeDirectory v=20400 ... flags=0x20002(adhoc,linker-signed)
Signature=adhoc
Info.plist=not bound
TeamIdentifier=not set
Sealed Resources=none
```

Two things the audit could not have known and that this task settled:

* **A Developer ID identity does exist on this machine.** The audit's #2699 verdict
  assumed one might not. `security find-identity -v -p codesigning` returns five
  identities, of which exactly one is usable for distribution outside the App Store:

  ```
  1) 4D36D20A…  "<an unrelated local identity>"
  2) 60A73DFC…  "Apple Development: <account> (<TEAMID>)"
  3) 37EDE2B4…  "Apple Development: Created via API (<TEAMID>)"
  4) 771FBDC1…  "Apple Distribution: <Your Organisation> (<TEAMID>)"
  5) 48BBC23E…  "Developer ID Application: <Your Organisation> (<TEAMID>)"
  ```

  Only #5 is the right one, and the script matches only that string. #2 and #3 sign
  perfectly well and then fail notarisation; #4 is App Store distribution, which D10 rules
  out on three independent grounds. Picking either would fail hours later, in Apple's
  queue, which is the expensive way to find out.

* **`AboutFacts.portVersion` already reads `Bundle.main`** and falls back to `0.1.0-dev`
  when there is no bundle; with a comment saying "there is no bundle yet". There is now.
  The bundle sets `CFBundleShortVersionString = 0.1.0-dev` deliberately, keeping the
  pre-release marker rather than rounding to `0.1.0`: `AboutFacts` states in as many words
  that the port is not at parity with 4.1.0, and a bundle version that dropped `-dev`
  would quietly delete that caveat from the one window that must not make false claims.

---

## 2. What was built

```
tools/package/
  build-app.sh        assemble → sign → measure Gatekeeper → optional DMG
  notarize.sh         pre-flight → credential boundary → submit → staple → measure
  make-icon.swift     draws both .icns files from scratch, deterministically
  Info.plist.in       bundle metadata, document types, UTI declarations
  NOTICE.md.in        the GPLv3 §5 notice set that ships inside the bundle
```

`build-app.sh` needs only a clone, a Swift toolchain and the Xcode command line tools.
It writes to `.build-package/` (added to `.gitignore`), never to `/Applications`, and it
does not register anything with LaunchServices: see §5 for why that matters.

Resulting layout:

```
logisim-evolved.app/Contents/
  Info.plist
  PkgInfo
  MacOS/logisim-evolved                    (renamed from logisim-evolved-app)
  Resources/logisim-evolved.icns
  Resources/logisim-evolved-circuit.icns
  Resources/LICENSE.md
  Resources/NOTICE.md
  _CodeSignature/
```

**No `Package.swift` change was needed and none is proposed.** The manifest is not mine to
edit and the bundle does not require it: everything the packaging step consumes lives in
`tools/package/`, and nothing was added under `swift/Sources/logisim-evolved-app/`
precisely to avoid SwiftPM's "found N file(s) which are unhandled" warning, which would
have forced a `resources:` declaration in a file I do not own.

### Why the icon is code

`make-icon.swift` draws the app icon and the document icon and calls `iconutil`. D10 wants
the port's **own** icon; D12 records that upstream ships artwork whose rights are not
clean, so inheriting `support/jpackage/macos/Logisim-evolution.icns` would import that
problem as well as misrepresent the work. Drawing it in code makes it reviewable as a diff,
reproducible from a fresh clone with no design tool, and deterministic: no clock, no
locale, no system font.

The mark is a filled two-input AND gate on an indigo rounded square. Honest caveat: at
small sizes the three wires plus the D-shaped body read a little like a wall plug. Two
rounds of tuning (thinner wires, wider input spacing, taller body) improved it; it was not
taken further, because the substance of #2699 is Gatekeeper, not the glyph. If it ever
gets replaced by a designed icon, replace the drawing functions and nothing else changes.

---

## 3. Document types — and the one real defect this uncovered

D10 is explicit: *"Distinct app name, own icon, own bundle ID, and **own document UTI**;
do not claim upstream's `application/x-logisim-circuit`."*

Upstream's own declaration, read from the installed app rather than guessed
(`/Applications/Logisim-evolution.app/Contents/Info.plist`):

| key | upstream | here |
|---|---|---|
| `CFBundleIdentifier` | `com.cburch.logisim` | `app.closiq.logisim-evolved` |
| exported UTI | `com.cburch.logisim.circ` | `app.closiq.logisim-evolved.circuit` |
| MIME tag | `application/x-logisim-circuit` | **not claimed** |
| `LSIsAppleDefaultForType` | `true` | **absent** |
| `UTTypeConformsTo` | `public.data` | `public.xml` |
| `LSMinimumSystemVersion` | `10.11` | `26.0` |
| `NSMicrophoneUsageDescription` | present | absent: Buzzer plays, never records |

The exported identifier is not invented here: `LogisimDocumentType.identifier` in
`swift/Sources/LogisimUI/Seams/ProjectSeam.swift` already declared
`app.closiq.logisim-evolved.circuit`, with a comment instructing whoever built the bundle
to declare it in `Info.plist` conforming to `public.xml`. That instruction is now carried
out, and `build-app.sh` **asserts the two agree** and fails the build if they drift;
because a mismatch produces an app that opens nothing and reports no error.

The bundle also carries a `UTImportedTypeDeclarations` entry for
`com.cburch.logisim.circ`, ranked `LSHandlerRank = Alternate`. Importing is how macOS lets
an app say "I understand a type someone else owns" without claiming it. It is needed
because on any Mac that has ever had logisim-evolution installed, existing `.circ` files
are already typed with upstream's UTI:

```
$ mdls -name kMDItemContentType <any .circ file>
kMDItemContentType = "com.cburch.logisim.circ"
```

That is the CSC258 migration case exactly; a student who already has upstream installed.

### Measured: double-click works, with one condition

**The transcripts in this section predate the identifier change of 2026-09-14** and show
`rest.erwin.logisim-evolved`, which is what the run that produced them actually registered. The
bundle identifier is now `app.closiq.logisim-evolved`, matching the Developer ID the artefact is
signed with. They are left as captured rather than rewritten, because editing a measurement to
agree with a later decision is how a record stops being evidence; what they establish, that
LaunchServices registers the bundle and routes a double-click to it, does not depend on the string.

After registering the bundle, LaunchServices lists it as a handler and the app launches
under the right process name:

```
$ lsregister -dump | grep -A2 rest.erwin.logisim-evolved
identifier:      rest.erwin.logisim-evolved
executable:      Contents/MacOS/logisim-evolved
claimed UTIs:    com.cburch.logisim.circ, rest.erwin.logisim-evolved.circuit
```

With upstream installed, the file resolves to upstream's UTI and our app is offered as an
alternate handler. Opening it through our bundle:

```
$ open -b rest.erwin.logisim-evolved <any .circ file>
$ osascript -e 'tell application "System Events" to tell process "logisim-evolved" \
      to get name of every window'
About logisim-evolved
```

**No document window.** The open is silently discarded.

Controlled experiment: upstream temporarily unregistered so that a `.circ` resolves to
*our* exported UTI, then restored immediately afterwards:

```
$ lsregister -u /Applications/Logisim-evolution.app
$ open <any .circ file>
$ osascript -e '…get name of every window'
<file> – main, About logisim-evolved
```

The document opens, titled and on the `main` circuit. The variable is the file's resolved
UTI and nothing else.

> ### Defect for the LogisimUI owner, not mine to fix, so here is the exact change
>
> `CircuitDocument.readableContentTypes` lists only the port's own UTI, so SwiftUI's
> `DocumentGroup` rejects any file whose resolved content type is
> `com.cburch.logisim.circ`, and rejects it *silently*, before `DocumentRoot` runs, so the
> existing "Could Not Open This Circuit" error view never appears either. The `Info.plist`
> import makes LaunchServices route the file to us; SwiftUI then drops it on the floor.
>
> Every `.circ` on a machine that has upstream installed is in this state. That is the
> flagship migration case.
>
> `swift/Sources/LogisimUI/Seams/ProjectSeam.swift`, in `enum LogisimDocumentType`:
>
> ```swift
> /// Upstream's own UTI, declared in the bundle as an *imported* type (D10 forbids
> /// exporting it). LaunchServices routes files tagged with it to us; DocumentGroup
> /// still drops them unless they are readable here too.
> public static let upstreamCircuit: UTType =
>   UTType(importedAs: "com.cburch.logisim.circ", conformingTo: .data)
> ```
>
> then in `CircuitDocument.swift:55` and `LogisimFileProjectHost.swift:171`:
>
> ```swift
> -  public static var readableContentTypes: [UTType] { [LogisimDocumentType.circuit] }
> +  public static var readableContentTypes: [UTType] {
> +    [LogisimDocumentType.circuit, LogisimDocumentType.upstreamCircuit]
> +  }
> ```
>
> Leave `writableContentTypes` as the port's own type alone: reading upstream's files is
> required, re-tagging saved files as upstream's type is not, and D10 forbids claiming it.
>
> Two adjacent observations from the same session, also not mine: the About window opens on
> every launch even when a document was requested, and while its Open panel is up the app
> does not answer a `quit` Apple event (`AppleEvent timed out (-1712)`), so it has to be
> killed.

**The owner's machine was left exactly as found.** Our bundle was unregistered and
upstream re-verified as the sole and default `.circ` handler:

```
default handler: /Applications/Logisim-evolution.app
all handlers:
    /Applications/Logisim-evolution.app
```

---

## 4. Gatekeeper — measured

### Unsigned (`--no-sign`)

```
$ codesign -dv --verbose=4 logisim-evolved-UNSIGNED.app
Identifier=logisim-evolved-app
CodeDirectory v=20400 size=111052 flags=0x20002(adhoc,linker-signed)
Signature=adhoc
Info.plist=not bound
TeamIdentifier=not set
Sealed Resources=none

$ spctl -a -vvv --type exec logisim-evolved-UNSIGNED.app
…: code has no resources but signature indicates they must be present
```

The script renames the output `-UNSIGNED.app` and prints a boxed warning, so an unsigned
build cannot travel downstream looking shippable.

### Signed (default path)

Captured before the 2026-09-14 identifier change, so `Identifier=` below reads
`rest.erwin.logisim-evolved`; it is `app.closiq.logisim-evolved` now. Left as captured, for the
same reason as the LaunchServices transcripts above: what this shows is the hardened-runtime flag
and the Developer ID authority, neither of which depends on the identifier string.

```
$ codesign -dv --verbose=4 logisim-evolved.app
Executable=…/logisim-evolved.app/Contents/MacOS/logisim-evolved
Identifier=rest.erwin.logisim-evolved
Format=app bundle with Mach-O thin (arm64)
CodeDirectory v=20500 size=27974 flags=0x10000(runtime) hashes=867+3 location=embedded
Hash type=sha256 size=32
CDHash=905228b5f1996b0bef12f70f9a81b061797e4d3c
Signature size=8972
Authority=Developer ID Application: <Your Organisation> (<TEAMID>)
Authority=Developer ID Certification Authority
Authority=Apple Root CA
Timestamp=Sep 6, 2026 at 12:38:03 AM
Info.plist entries=20
TeamIdentifier=<TEAMID>
Runtime Version=26.5.0
Sealed Resources version=2 rules=13 files=4
Internal requirements count=1 size=188

$ codesign --verify --deep --strict --verbose=2 logisim-evolved.app
…: valid on disk
…: satisfies its Designated Requirement

$ spctl -a -vvv --type exec logisim-evolved.app
…: rejected
source=Unnotarized Developer ID
origin=Developer ID Application: <Your Organisation> (<TEAMID>)
```

Every line that was wrong before is now right, real bundle identifier, hardened runtime
(`flags=0x10000(runtime)`), sealed resources, full Apple chain, secure timestamp, and
`spctl` still says **rejected**. That is not a defect in the packaging. A Developer ID
signature alone does not clear Gatekeeper; notarisation is the load-bearing half, and the
`upstream-issues.md` control experiment already showed this on the installed Java app,
which is locally re-signed with the same certificate and also rejected.

### Signed DMG

```
$ codesign -dv --verbose=2 logisim-evolved-0.1.0-dev.dmg
Identifier=logisim-evolved-0.1.0-dev
Format=disk image
Authority=Developer ID Application: <Your Organisation> (<TEAMID>)
Timestamp=Sep 6, 2026 at 12:48:47 AM

$ spctl -a -vvv --type open --context context:primary-signature logisim-evolved-0.1.0-dev.dmg
…: rejected
source=Unnotarized Developer ID
```

6.2 MB. No embedded frameworks: `otool -L` shows the binary links only system frameworks
and `/usr/lib/swift`, so nothing needs to be copied in, re-signed, or excepted by an
entitlement. The bundle is signed with no entitlements file at all, deliberately;
requesting hardened-runtime exceptions it does not need would widen the attack surface and
slow notarisation review.

### The exact missing step

Notarisation. Nothing else. `tools/package/notarize.sh` does the whole of it and stops at
the credential boundary:

```
$ tools/package/notarize.sh .build-package/stage/logisim-evolved.app

▸ Pre-flight
  signature:  Developer ID Application: <Your Organisation> (<TEAMID>)
  hardened:   yes (0x10000(runtime))
  timestamp:  Sep 6, 2026 at 12:38:03 AM

▸ Credentials
  ╭──────────────────────────────────────────────────────────────────────────────────╮
  │  STOP; this is the credential boundary. Nothing past here can be automated for   │
  │  you, and this script will not try.                                               │
  ╰──────────────────────────────────────────────────────────────────────────────────╯
  No notarytool keychain profile named 'logisim-evolved-notary' was found.
$ echo $?
3
```

**The one command the owner must run himself,** in a real terminal, once:

```sh
xcrun notarytool store-credentials "logisim-evolved-notary" \
    --apple-id "<your Apple ID email>" \
    --team-id "<TEAMID>"
```

It then prompts for an **app-specific password**: not the Apple ID password; generate one
at <https://account.apple.com> → Sign-In and Security → App-Specific Passwords. The prompt
is interactive, so no secret reaches a command line, a file or a shell history. An App
Store Connect API key (`--key AuthKey_XXXXXXXX.p8 --key-id … --issuer …`) works instead and
is preferable if this is ever automated, being revocable per-key.

After that, everything is scripted:

```sh
tools/package/build-app.sh --dmg
tools/package/notarize.sh .build-package/logisim-evolved-0.1.0-dev.dmg
```

`notarize.sh` zips an `.app` with `ditto -c -k --keepParent` (a plain `zip -r` drops
symlinks and xattrs and gets rejected), submits with `--wait`, refuses to continue unless
Apple's status is `Accepted`, staples the ticket, and then **measures** `spctl` again rather
than declaring victory. Stapling is not optional here: it is what lets Gatekeeper clear the
app offline, which is the lecture-hall-with-bad-wifi case this whole issue is about.

Requires a paid Apple Developer Program membership on the account. The certificate exists,
so the membership almost certainly does, but that was not verified; it needs a login, and
this task does not touch credentials.

---

## 5. Honesty guards in the scripts

The failure mode that matters most here is a bundle that *looks* shippable and is not, so
each guard is deliberate rather than defensive habit:

* **Never silently unsigned.** No identity, or `--no-sign`, and the artefact is renamed
  `-UNSIGNED.app` with a boxed explanation naming the missing prerequisite.
* **Never "signed" when it is ad-hoc.** After `codesign` succeeds, the authority is read
  back out and must literally start with `Developer ID Application:`; an `Apple
  Development` or `Apple Distribution` certificate is rejected by name, because both sign
  cleanly and then fail Apple's queue.
* **Never a step that wrote nothing.** Each artefact is asserted to exist and be
  non-trivially sized: `plutil -lint` on the generated plist, `CFBundleIdentifier` read
  back, `.icns` size floor in the generator, `grep` for the GPL heading in the bundled
  licence and for the §5(a) wording in the bundled notice.
* **Gatekeeper measured on every path**, including the ones expected to fail. A script that
  only measures when it expects to pass is not measuring.
* **No LaunchServices registration.** Building must not change which app opens the user's
  `.circ` files. Registering is a separate, explicit act, and reversing it is what
  restored this machine in §3.

One bug of my own, worth recording because the shape recurs: `codesign … | grep -q` under
`set -o pipefail` reported **"no secure timestamp" on a correctly timestamped bundle**.
`grep -q` exits at the first match, `codesign` takes `SIGPIPE`, and the pipeline reports
failure. Both scripts now capture `codesign` output into a variable once and match against
that. Any `cmd | grep -q` or `cmd | head -1` under `pipefail` has this hazard.

---

## 6. D10 — the notices, and where they went

`docs/decisions.md` D10 requires: §5(a) prominent modified-version notice with a date;
§5(b) licence notice; Appropriate Legal Notices in the UI; and Corresponding Source
covering the whole build pipeline. `docs/objectives.md:553` tracks the About window
carrying the full §5 notice set.

The About window already does that job, and `AboutFacts.swift` is an exemplary single
auditable surface for it. What was missing is the copy that survives **in the bundle**;
the case §5 is actually about is a recipient who has the binary and not the repository, and
who may never launch it.

So the bundle now carries:

* `Contents/Resources/LICENSE.md`: the repository's GPL text, copied verbatim, checked for
  the `GNU GENERAL PUBLIC LICENSE` heading before the build is allowed to continue.
* `Contents/Resources/NOTICE.md`: generated from `NOTICE.md.in`: §5(a) modification notice
  with the 4 September 2026 date, both copyright lineages (Carl Burch; the
  logisim-evolution developers) with upstream's own credit list and institutions, the
  GPL-3.0-only statement including *why* there is no "or any later version", §15/§16
  no-warranty, the §6 source offer, and the D11 divergences. It also records the exact
  source revision the binary was built from.
* `NSHumanReadableCopyright` in `Info.plist`, which is what Finder's Get Info panel shows
  without launching anything: modification notice, both lineages, GPL-3.0-only, no
  warranty, and an explicit disclaimer of endorsement or affiliation.

The §6 offer states the obligation but carries no URL, matching `AboutFacts.sourceURL =
nil`: this port's repository is not public yet, and linking *upstream's* repository would
misstate where this program's Corresponding Source is. The bundled notice says so plainly;
that a binary handed over without a source link is a licence defect on the distributor.
**That is the one thing genuinely blocking distribution that is not notarisation**, and it
is not a technical step: publish the repository, then set `AboutFacts.sourceURL` and
`SOURCE_OFFER` in `build-app.sh` together.

D12 also remains open by owner decision and attaches to distribution rather than
development: worth re-reading before a public binary, since it is now one command away.

---

## 7. Homebrew cask — what the last mile needs

Out of scope today, and correctly so: a cask that points at a rejected artefact reproduces
#2699 rather than closing it. Prerequisites, in order, none of which are code:

1. **A notarised, stapled DMG at a stable public URL** with a SHA-256 that does not change
   for a given version. Upstream's cask was disabled precisely because its artefact failed
   Gatekeeper; homebrew-cask will not take a replacement with the same defect.
2. **A public source repository**, both for §6 and because `homebrew-cask` requires a
   `homepage` that is the project's own.
3. A `Casks/l/logisim-evolved.rb` with `version`, `sha256`, `url`, `name`,
   `desc`, `homepage`, `app "logisim-evolved.app"`, and a `zap trash:` listing
   `~/Library/Preferences/app.closiq.logisim-evolved.plist` and
   `~/Library/Saved Application State/app.closiq.logisim-evolved.savedState`.
4. `brew audit --cask --new` clean, then a PR to `Homebrew/homebrew-cask`. Expect them to
   ask about the relationship to the existing disabled `logisim-evolution` cask; the answer
   is that this is a different application with a different bundle ID, not a revival, and
   D10's naming rules exist so that answer is true.
5. A `livecheck` block, or the cask goes stale on the first release.

An unsigned or unnotarised cask is worse than no cask: it teaches students to run
`xattr -d com.apple.quarantine`, which is the habit #2699 exists to stop.

---

## 8. Status

| step | state |
|---|---|
| `.app` bundle with `Info.plist`, icon, document types | **done**, measured |
| reproducible build script from a clean clone | **done** |
| own bundle ID and own document UTI (D10) | **done**, asserted against the source |
| GPLv3 §5 notices inside the bundle (D10) | **done** |
| Developer ID signature, hardened runtime, timestamp | **done**, measured |
| signed DMG | **done**, measured |
| `.circ` opens by double-click | **blocked** on the `readableContentTypes` fix in §3 |
| notarisation | **blocked** on one owner-run `notarytool store-credentials` |
| `spctl -a` accepted | **not yet**; follows notarisation |
| Homebrew cask | out of scope; §7 lists what it needs |
| public source repository for the §6 offer | **not done**, and it gates distribution |

Do not tick #2699 in `upstream-issues.md` until `spctl -a -vvv` on a distributed DMG
returns `accepted`, per that document's own instruction. It does not yet. The gap between
today and that line is now exactly two things: one interactive Apple credential, and a
two-line change to `readableContentTypes`.

### Gates, measured after this work

Nothing under `swift/` changed, so no gate could regress; run anyway rather than asserted:

* `swift build -c release --product logisim-evolved-app`; 0 errors.
* `swift test --filter LogisimUITests`; **142 tests in 22 suites passed** (baseline 132/20;
  the increase is other agents' work landing on `swift-port`, not mine).
* `python3 tools/seamcheck.py`: 14 candidate seams, 14 already known, **0 new**.
* The canonical and migration gates were not re-run: they exercise `LogisimFile` and
  `LogisimKernel`, neither of which this change touches, and another agent is live in
  `LogisimFile`.
