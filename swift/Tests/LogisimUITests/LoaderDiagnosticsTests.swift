// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution, which is GPL-3.0-only. This port is a derivative work and is
// therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// Board #88, first half: what the `Loader` reports while reading a document must reach the user.
//
// ── The claim this test makes, and the one it deliberately does not ──────────────────────────
//
// `HeadlessLoaderUI` *records* into arrays. The app never read them, so every `loader.showError`
// during a load was swallowed: eleven call sites in `LibraryManager` alone (`:362`–`:462`)
// covering a malformed `file#` descriptor, an unregistered builtin, a `.jar` library, and the
// generic load failure.
//
// **It was NOT true that the app reported nothing.** `LogisimFileProjectHost.loadIssues` already
// detected `MissingLibrary` instances and named them. That was checked before this test was
// written, because board #87 was withdrawn the same day for the mirror-image mistake: a correct
// observation ("the array is never drained") carrying a wrong consequence ("therefore the user is
// told nothing"). **Verifying the mechanism is not verifying the outcome**, so these assertions
// are about what a user ends up holding, `host.issues`, and not about the array.

import Foundation
import LogisimFile
import Testing
import UniformTypeIdentifiers

@testable import LogisimUI

/// A project naming a builtin library that does not exist. `LibraryManager` reports this through
/// `loader.showError` (`FileStrings.fileBuiltinMissingError`, `LibraryManager.swift:432`); a
/// diagnostic that names *why* the descriptor failed, which the `MissingLibrary` scan cannot.
private let fileWithAnUnknownBuiltin = """
  <?xml version="1.0" encoding="UTF-8" standalone="no"?>
  <project source="4.1.0" version="1.0">
    <lib desc="#Base" name="0"/>
    <lib desc="#NoSuchLibrary" name="1"/>
    <main name="main"/>
    <circuit name="main"/>
  </project>
  """

@Suite("Board #88 — loader diagnostics reach the user")
struct LoaderDiagnosticsTests {

  @MainActor
  private func openIssues(_ source: String) throws -> [UserFacingIssue] {
    let host = try LogisimFileProjectHostFactory().openProject(
      data: Data(source.utf8), url: nil, contentType: LogisimDocumentType.circuit)
    return host.drainPendingIssues()
  }

  @Test("a diagnostic the Loader raises while reading is surfaced, not swallowed")
  @MainActor
  func loaderDiagnosticsAreSurfaced() throws {
    let issues = try openIssues(fileWithAnUnknownBuiltin)
    // "built-in library" is the LOADER's wording (`FileStrings.fileBuiltinMissingError`), and it
    // is the discriminating string. Asserting on "NoSuchLibrary" alone does NOT discriminate: the
    // MissingLibrary summary already quotes the descriptor, so that assertion passes with the
    // drain removed. Measured: with the drain there are two issues, without it one, and both
    // details contain the descriptor. A red probe caught the weak assertion; the first version of
    // this test would have passed against the code it exists to reject.
    #expect(
      issues.contains { $0.title == "While reading this file" }
        && issues.contains { ($0.detail ?? "").contains("built-in library") },
      """
      the loader's own diagnostic never reached the user. Issues actually surfaced:
      \(issues.map { "\($0.severity): \($0.title) — \($0.detail ?? "")" }.joined(separator: "\n"))
      """)
  }

  /// The half that already worked, asserted so a future change cannot quietly trade one report
  /// for the other. Both are wanted: one says *which* libraries are missing, the other says
  /// *why* reading them failed.
  @Test("the missing-library summary is still reported alongside it")
  @MainActor
  func theMissingLibrarySummarySurvives() throws {
    let issues = try openIssues(fileWithAnUnknownBuiltin)
    #expect(
      issues.contains { $0.title.contains("could not be resolved") },
      "the MissingLibrary summary disappeared; loadIssues and loaderIssues must both fire")
  }

  /// A clean file must produce no noise at all. Without this, the two assertions above would
  /// pass against a version that reported something on every open.
  @Test("a file with nothing wrong produces no loader diagnostics")
  @MainActor
  func aCleanFileIsSilent() throws {
    let clean = """
      <?xml version="1.0" encoding="UTF-8" standalone="no"?>
      <project source="4.1.0" version="1.0">
        <lib desc="#Base" name="0"/>
        <lib desc="#Wiring" name="1"/>
        <main name="main"/>
        <circuit name="main"/>
      </project>
      """
    #expect(try openIssues(clean).isEmpty)
  }
}
