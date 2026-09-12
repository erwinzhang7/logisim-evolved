// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution, which is GPL-3.0-only. This port is a derivative work and is
// therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// A project name taken from the filesystem must be NFC, because that is what Java produces.
//
// ── The defect ───────────────────────────────────────────────────────────────────────────────
//
// APFS returns filenames DECOMPOSED. `й` (U+0439) comes back as `и` + U+0306, not as one scalar.
// Java's macOS `sun.nio.fs` provider composes to NFC when it turns a path into a `String`;
// Foundation hands back the raw bytes. So for any file whose name carries a composable character,
// `Loader.projectName(of:)` produced a string that was byte-different from Java's and visually
// identical to it.
//
// That was SIX of the `-tty stats` gate's failures, across two files, and they presented as a diff
// with no visible change at all:
//
//     - 8   8  sum   Цифровой проект 8b
//     + 8   8  sum   Цифровой проект 8b
//
// Measured before the fix: the two lines compared unequal as-is and equal after normalising both
// to NFC. The counts and the column formatting had always been right.
//
// ── Why this test exists when the gate already covers it ─────────────────────────────────────
//
// `statsgate` proves it end to end, and it went 1731/6 → 1737/0. But it needs the 593-file corpus
// and a release build, so it does not run on a laptop without `LOGISIM_CORPUS`, and those six
// failures sat unnoticed for exactly that reason; they were recorded in the baseline as part of
// a ratio and nothing re-measured them. This runs in the ordinary suite with no corpus at all.
//
// ── EVERY ASSERTION HERE COMPARES UTF-8 BYTES, AND THAT IS THE WHOLE TRICK ───────────────────
//
// **Swift's `String ==` is canonically insensitive**: an NFC string and its NFD form compare
// EQUAL. So `name == expected` cannot see this defect at all, and the first version of this file
// failed its own calibration for that reason, which was the useful part, because it is also why
// 1,500 Swift tests never caught the bug while a byte-level diff of the CLI's stdout did. Anything
// that leaves the process, a file, a pipe, a golden comparison, is bytes, and bytes are where
// the two forms differ.

import Foundation
import Testing

@testable import LogisimFile

@Suite("Project names are composed, as Java's are")
struct ProjectNameNormalisationTests {

  /// The calibration, and it is not optional: if the fixture's name has no composable character,
  /// NFC and NFD are the same string and every assertion below passes trivially. `й` decomposes;
  /// `компаратор` does not, which is why an earlier probe using that word found nothing.
  @Test("the fixture name really does differ between NFC and NFD")
  func theFixtureDiscriminates() {
    let composed = "Цифровой"
    #expect(
      Array(composed.precomposedStringWithCanonicalMapping.utf8)
        != Array(composed.decomposedStringWithCanonicalMapping.utf8),
      """
      this name has the same BYTES in both normal forms, so it cannot detect the defect. Use a \
      name containing a composable character such as й (U+0439 = и + U+0306). Note the \
      comparison is on `.utf8` — comparing the Strings directly answers "equal" for canonically \
      equivalent forms and would make this test vacuous.
      """)
  }

  /// **The defect.** A decomposed name, which is what the filesystem hands back, must come out
  /// composed, matching what Java's `toProjectName` produces for the same file.
  @Test("a decomposed filename yields a composed project name")
  func decomposedFilenameIsComposed() {
    let decomposed = "Цифровой компаратор 8b.circ".decomposedStringWithCanonicalMapping
    let url = URL(fileURLWithPath: "/tmp").appendingPathComponent(decomposed)

    let name = Loader.projectName(of: url)

    #expect(
      Array(name.utf8) == Array(name.precomposedStringWithCanonicalMapping.utf8),
      """
      the project name came back decomposed. It renders identically to Java's and its BYTES \
      differ — six -tty stats cases failed exactly this way, with a diff showing no visible \
      difference.
      """)
    #expect(
      Array(name.utf8) == Array("Цифровой компаратор 8b".precomposedStringWithCanonicalMapping.utf8),
      "the name changed beyond normalisation: \(name)")
  }

  /// The extension is still stripped, so the normalisation cannot be "fixed" by returning the
  /// whole filename.
  @Test("the .circ extension is still removed")
  func extensionIsStillStripped() {
    let url = URL(fileURLWithPath: "/tmp/plain.circ")
    #expect(Loader.projectName(of: url) == "plain")
  }

  /// A name that is already composed must pass through untouched: normalising is idempotent, and
  /// a fix that mangled ASCII would be worse than the bug.
  @Test("an ASCII name is unchanged")
  func asciiIsUnchanged() {
    let url = URL(fileURLWithPath: "/tmp/counter_part2.circ")
    #expect(Loader.projectName(of: url) == "counter_part2")
  }

  /// A file with no `.circ` suffix keeps its whole name, and is normalised too; the guard clause
  /// returns early, so it is a separate path and could have been missed.
  @Test("a name without the extension is normalised on the early-return path as well")
  func nonCircNameIsAlsoNormalised() {
    let decomposed = "Цифровой.txt".decomposedStringWithCanonicalMapping
    let url = URL(fileURLWithPath: "/tmp").appendingPathComponent(decomposed)
    let name = Loader.projectName(of: url)
    #expect(
      Array(name.utf8) == Array(name.precomposedStringWithCanonicalMapping.utf8),
      "the early return path skips composing")
  }
}
