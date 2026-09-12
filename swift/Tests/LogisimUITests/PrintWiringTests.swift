// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution, which is GPL-3.0-only. This port is a derivative work and is
// therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// THE JOIN between the Print machinery and the running app.
//
// `PrintTests` covers the arithmetic, layout, header, rotation, print-view, against an offscreen
// bitmap, and covers it well. None of it could be reached from the app: `Print/` was five files
// with no caller, `ProjectCommand.print` was an enum case with no producer and no consumer, and
// the File menu had no Print item. Each half was correct and nothing owned the join. That is the
// failure this project has now hit twenty-six times, so the join gets its own gate.
//
// ── What is asserted here, and the one thing that is not ────────────────────────────────────
//
// `CircuitPrintCommand.run` ends in `NSPrintOperation.run()`, which puts up a modal panel; a test
// that called it would hang the suite. So `EditorModel.printJob()` gathers the job and
// `presentPrintPanel` hands it over, and everything except that hand-off is checked below.
// The hand-off is left unasserted deliberately, for the reason `CircuitPrintOperation.swift`
// gives: a test that checks "an `NSPrintOperation` was constructed" passes against a version that
// prints a blank page, which is precisely the false green worth avoiding.

import CoreGraphics
import Foundation
import LogisimFile
import LogisimRender
import Testing
import UniformTypeIdentifiers

@testable import LogisimUI

/// Two circuits, each with drawable content. Gates rather than pins because the print-view
/// discriminator below needs a shape whose painter actually consults `isPrintView`; that is
/// asserted rather than assumed (see `theFixtureCanTellPrintViewFromScreenView`).
private let twoDrawableCircuits = """
  <?xml version="1.0" encoding="UTF-8" standalone="no"?>
  <project source="4.1.0" version="1.0">
    <lib desc="#Base" name="0"/>
    <lib desc="#Wiring" name="1"/>
    <lib desc="#Gates" name="2"/>
    <main name="alpha"/>
    <circuit name="alpha">
      <comp lib="2" loc="(120,100)" name="AND Gate"/>
      <comp lib="2" loc="(120,180)" name="OR Gate"/>
    </circuit>
    <circuit name="beta">
      <comp lib="2" loc="(140,140)" name="NOT Gate"/>
    </circuit>
  </project>
  """

@Suite("Print — the join between the Print machinery and the app")
struct PrintWiringTests {

  @MainActor
  private func makeModel() throws -> EditorModel {
    let host = try LogisimFileProjectHostFactory().openProject(
      data: Data(twoDrawableCircuits.utf8), url: nil, contentType: LogisimDocumentType.circuit)
    return EditorModel(host: host)
  }

  /// **The calibration, and it runs first on purpose.** Every print-view assertion below is a
  /// comparison between two builds of this fixture, and a fixture whose two builds are identical
  /// would make those assertions pass no matter what the wiring did. So the discriminator is
  /// checked before it is used.
  @Test("the fixture can actually tell print view from screen view")
  @MainActor
  func theFixtureCanTellPrintViewFromScreenView() throws {
    let model = try makeModel()
    let appearance = model.printJob().appearance
    let printed = model.host.printablePages(appearance: appearance, printerView: true)
    let screen = model.host.printablePages(appearance: appearance, printerView: false)

    let printedCount = printed[0].scene.primitiveCount
    let screenCount = screen[0].scene.primitiveCount
    #expect(
      printedCount != screenCount,
      """
      this fixture renders identically with and without print view (\(printedCount) primitives \
      either way), so it cannot discriminate and `printerViewReachesTheHost` below would pass \
      against a host that ignored the flag. Change the fixture, not the assertion.
      """)
  }

  /// One page per circuit, in the file's order, named; the sidebar order a user expects.
  @Test("every circuit in the file becomes a page, in order and named")
  @MainActor
  func everyCircuitBecomesAPage() throws {
    let model = try makeModel()
    let job = model.printJob()

    #expect(
      job.circuits.map(\.name) == ["alpha", "beta"],
      "pages produced: \(job.circuits.map(\.name))")
  }

  /// A page count is not a page. Two circuits that both print blank would satisfy the test above,
  /// and a blank printout is the failure a user would actually notice.
  @Test("each page carries real drawn content")
  @MainActor
  func eachPageHasContent() throws {
    let model = try makeModel()
    for page in model.printJob().circuits {
      #expect(
        !page.scene.isEmpty,
        "page \"\(page.name)\" would print blank — its scene has no primitives")
      #expect(
        page.scene.primitiveCount > 1,
        "page \"\(page.name)\" emitted \(page.scene.primitiveCount) primitive(s)")
    }
  }

  /// **The flag is threaded, not defaulted.** `printerView` decides what the renderer emits, so
  /// the model has to pass its `settings.printerView` to the host and then draw with the same
  /// value. Asserting the resulting scene matches the `true` build and differs from the `false`
  /// build catches both a model that hardcodes the flag and a host that ignores it.
  @Test("the model's printerView setting reaches the host that builds the scenes")
  @MainActor
  func printerViewReachesTheHost() throws {
    let model = try makeModel()
    let job = model.printJob()
    let asPrinted = model.host.printablePages(
      appearance: job.appearance, printerView: job.settings.printerView)
    let asScreen = model.host.printablePages(
      appearance: job.appearance, printerView: !job.settings.printerView)

    #expect(
      job.circuits[0].scene.primitiveCount == asPrinted[0].scene.primitiveCount,
      "the job's pages were not built with the job's own printerView setting")
    #expect(
      job.circuits[0].scene.primitiveCount != asScreen[0].scene.primitiveCount,
      "the job's pages match the OPPOSITE setting — the flag is inverted or ignored")
  }

  /// **Choosing File ▸ Print reaches the print machinery.** This is the assertion the whole file
  /// is for, and it is the only one that fails if `case .print: presentPrintPanel()` is deleted
  /// from `EditorModel.perform`; every other test here calls `printJob()` directly and would
  /// stay green against a menu item that did nothing.
  @Test("performing .print reaches the presenter with the pages, and reports no error")
  @MainActor
  func printCommandReachesThePresenter() throws {
    let model = try makeModel()
    var presented: PrintJob?
    model.printPresenter = { presented = $0 }

    model.perform(.print)

    let job = try #require(
      presented,
      """
      .print never reached the presenter. If `EditorModel.perform` no longer intercepts it, the \
      command falls through to `host.perform`, which throws — see `theHostHasNoPrintArm`.
      """)
    #expect(job.circuits.map(\.name) == ["alpha", "beta"])
    // The other half: intercepted means intercepted, not "thrown and swallowed". A version that
    // fell through would leave a "Command unavailable" issue behind even if it also presented.
    #expect(model.transientError == nil, "printing reported: \(model.transientError ?? "")")
    #expect(
      !model.issues.contains { $0.title == "Command unavailable" },
      "printing surfaced a Command unavailable issue: \(model.issues.map(\.title))")
  }

  /// The interception in `EditorModel.perform` is load-bearing, and this says why: the host has
  /// no `.print` arm and never will, because printing is AppKit's business and the host is the
  /// model side. If someone deletes `case .print: presentPrintPanel()`, the command falls through
  /// to `host.perform` and the menu item starts reporting "Command unavailable" instead of
  /// printing. Same tripwire shape as `PrintTests.exportImageIsInert`.
  @Test("the host itself refuses .print, so the model's interception is what makes it work")
  @MainActor
  func theHostHasNoPrintArm() throws {
    let host = try LogisimFileProjectHostFactory().openProject(
      data: Data(twoDrawableCircuits.utf8), url: nil, contentType: LogisimDocumentType.circuit)
    var thrown: Error?
    do { try host.perform(.print) } catch { thrown = error }
    let error = try #require(
      thrown, "the host grew a .print arm — printing belongs in the shell; re-decide deliberately")
    guard case ProjectHostError.notImplemented = error else {
      Issue.record("expected .notImplemented, got \(error)")
      return
    }
  }
}
