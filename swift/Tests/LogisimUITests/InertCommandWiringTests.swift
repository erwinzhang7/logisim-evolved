// InertCommandWiringTests.swift: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE COMMANDS THAT LEFT `CommandSurfaceAuditTests.expectedInert` ON 2026-09-12.
//
// The audit next door measures the whole surface and pins the inert set by name; it cannot say
// whether a command that stopped *reporting* itself unimplemented actually does anything. That is
// this file's job, one suite per command, and each `@Test` here was red-probed by breaking the
// wiring it covers rather than by inspection; the probes and what each reddened are in the
// change's report.
//
// Two of the three wirings were **live defects rather than merely untidy enum cases**, and the
// distinction is the reason they were picked over the other thirty-one:
//
//   • `.analyzeCircuit`; `ExplorerSidebar.swift:255` sends it from a circuit's right-click menu.
//     Combinational Analysis is the single most-used feature in a first-year lab (truth table,
//     expressions, minimisation), and that click answered "Command unavailable; analyzeCircuit is
//     not implemented yet." while the identical item in the Circuit menu opened the window,
//     because that one bypassed the command.
//
//   • `.reloadLibrary`: `ExplorerSidebar.swift:313` sends it from a library's right-click menu.
//     Everything downstream of it already existed and was tested: `LibraryManager.reload`,
//     `LoadedLibrary.setBase`, `resolveChanges`, and `LibraryReplacementApply`: board #64's
//     handler, which rewrites every already-placed component to the reloaded factories and is
//     installed by `LogisimFileProjectHostFactory.installProcessSeams`. The *only* missing link
//     was the command arm, so this is a whole subsystem that no user could reach.
//
// `UnassignedSeamInstallTests` deliberately drives the replacement handler directly, and says so:
// "what is under test is the JOIN". `libraryReloadRereadsTheFileFromDisk` below is the end-to-end
// counterpart it did not attempt; a real `.circ` rewritten on disk between two reads.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimFile
import Testing
import UniformTypeIdentifiers

@testable import LogisimUI

/// Two circuits, so that "the analyzer got a circuit" can be told apart from "the analyzer got
/// *the* circuit". `alpha` is main and therefore current on open; `beta` is what a `setCurrentCircuit`
/// moves to.
private let twoCircuitProject = """
  <?xml version="1.0" encoding="UTF-8" standalone="no"?>
  <project source="4.1.0" version="1.0">
    <lib desc="#Base" name="0"/>
    <lib desc="#Wiring" name="1"/>
    <lib desc="#Gates" name="2"/>
    <main name="alpha"/>
    <circuit name="alpha">
      <comp lib="1" loc="(80,80)" name="Pin"/>
      <comp lib="2" loc="(160,80)" name="AND Gate"/>
    </circuit>
    <circuit name="beta">
      <comp lib="1" loc="(100,120)" name="Pin"/>
    </circuit>
  </project>
  """

/// A `.circ` holding one circuit, whose name is the parameter. Loaded as a *library* it contributes
/// one `AddTool` named after that circuit, which is what makes a reload observable: the tool list
/// before and after names a different circuit.
private func libraryProject(circuitNamed name: String) -> String {
  """
  <?xml version="1.0" encoding="UTF-8" standalone="no"?>
  <project source="4.1.0" version="1.0">
    <lib desc="#Base" name="0"/>
    <lib desc="#Wiring" name="1"/>
    <main name="\(name)"/>
    <circuit name="\(name)">
      <comp lib="1" loc="(60,60)" name="Pin"/>
    </circuit>
  </project>
  """
}

@MainActor
private func openTwoCircuitProject() throws -> LogisimFileProjectHost {
  LogisimFileProjectHostFactory.registerBuiltinLibrariesIfNeeded()
  return try #require(
    try LogisimFileProjectHostFactory().openProject(
      data: Data(twoCircuitProject.utf8), url: nil, contentType: LogisimDocumentType.circuit)
      as? LogisimFileProjectHost)
}

@MainActor
private func circuitID(_ model: EditorModel, named name: String) throws -> CircuitID {
  try #require(model.outline.circuits.first { $0.name == name }?.id)
}

// MARK: - Analyze Circuit

@Suite("Analyze Circuit — the command, not the menu item")
struct AnalyzeCommandTests {

  /// The assertion that matters is the payload. A probe that only checked "no issue was reported"
  /// stays green against a `perform` that swallows the command, and a probe that only checked
  /// "the presenter ran" stays green against one handed the wrong circuit, which is the failure
  /// a user would actually see, since the analyzer would then show the truth table of a circuit
  /// they were not looking at.
  @Test("analyzeCircuit hands the presenter the circuit the editor is showing")
  @MainActor
  func analyzePassesTheCurrentCircuit() throws {
    let model = EditorModel(host: try openTwoCircuitProject())
    var received: [String] = []
    model.analyzerPresenter = { circuit, _ in received.append(circuit.name) }

    model.perform(.analyzeCircuit)
    #expect(received == ["alpha"], "the main circuit is current on open and must be the one analysed")

    // Move the editor and analyse again. Without this the test would pass against a presenter
    // wired to `file.circuits.first` rather than to the current circuit.
    model.perform(.setCurrentCircuit(try circuitID(model, named: "beta")))
    model.perform(.analyzeCircuit)
    #expect(received == ["alpha", "beta"])
  }

  /// `CircuitAnalysis` needs the `LogisimFile` as well as the `Circuit`, for `<options>`:
  /// `simrand` and `simlimit` have to match what the canvas simulates with or the analyzer's
  /// table can disagree with the canvas on an oscillating circuit (`EditorModel+Analyze.swift`).
  /// Handing over a *different* file, a freshly made one, say, would be a silent wrong answer,
  /// so the identity is checked rather than the mere presence.
  @Test("the file handed over is the document's own file, by identity")
  @MainActor
  func analyzePassesTheDocumentsFile() throws {
    let host = try openTwoCircuitProject()
    let model = EditorModel(host: host)
    var receivedFile: LogisimFile?
    model.analyzerPresenter = { _, file in receivedFile = file }

    model.perform(.analyzeCircuit)
    #expect(receivedFile === host.file)
  }

  /// The defect itself, stated as a test: the command used to reach
  /// `LogisimFileProjectHost.perform`'s `default:` arm, and `EditorModel.perform` turns a throw
  /// into a `UserFacingIssue` banner. So an inert `.analyzeCircuit` is visible as an issue, and
  /// this is what reddens if the interception is removed.
  @Test("no ‘Command unavailable’ issue is raised, and the item is enabled")
  @MainActor
  func analyzeReportsNothingAndIsEnabled() throws {
    let model = EditorModel(host: try openTwoCircuitProject())
    model.analyzerPresenter = { _, _ in }

    #expect(model.canPerform(.analyzeCircuit), "the menu item's `.disabled` reads this")
    let before = model.issues.count
    model.perform(.analyzeCircuit)
    #expect(model.issues.count == before)
    #expect(model.transientError == nil)
  }
}

// MARK: - Layout / Appearance

@Suite("The three view-mode commands")
struct ViewModeCommandTests {

  /// `MenuProject`'s `projectEditCircuitLayoutItem` / `projectEditCircuitAppearanceItem` /
  /// `projectToggleCircuitAppearanceItem`, whose upstream handlers call
  /// `frame.setEditorView(Frame.EDIT_LAYOUT | EDIT_APPEARANCE)`.
  ///
  /// Each command is driven from the state it is NOT idempotent in, `.editLayout` from
  /// `.appearance` rather than from the default `.layout`, because an `.editLayout` arm that did
  /// nothing at all would pass a test that started where it was meant to end up.
  @Test("each command lands the centre view where upstream's setEditorView would")
  @MainActor
  func viewCommandsSwitchTheCentreView() throws {
    let model = EditorModel(host: try openTwoCircuitProject())
    #expect(model.centreView == .layout)

    model.perform(.editAppearance)
    #expect(model.centreView == .appearance)

    model.perform(.editLayout)
    #expect(model.centreView == .layout)

    // The toggle both ways. One direction only would pass against `centreView = .appearance`.
    model.perform(.toggleLayoutAppearance)
    #expect(model.centreView == .appearance)
    model.perform(.toggleLayoutAppearance)
    #expect(model.centreView == .layout)

    #expect(model.issues.isEmpty, "a view switch is shell state and must not report anything")
  }

  /// `computeEnabled()` ties EDIT_LAYOUT to `view.equals("appearance")` and EDIT_APPEARANCE to
  /// `view.equals("layout")`, and gives TOGGLE_APPEARANCE a literal `true`. So each named item is
  /// enabled only from the *other* editor, and this is what `AppCommands`' two new `.disabled`
  /// modifiers read.
  ///
  /// Driven in both states, because a `canPerform` that answered a constant, `true`, which is
  /// what it answered before, or `false`, passes a test that checks only one of them.
  @Test("Edit Layout and Edit Appearance are each enabled only from the other editor")
  @MainActor
  func viewCommandEnablementMatchesComputeEnabled() throws {
    let model = EditorModel(host: try openTwoCircuitProject())

    #expect(model.centreView == .layout)
    #expect(!model.canPerform(.editLayout), "already in layout — 4.1.0 greys this")
    #expect(model.canPerform(.editAppearance))
    #expect(model.canPerform(.toggleLayoutAppearance), "upstream passes this a literal true")

    model.perform(.editAppearance)
    #expect(model.canPerform(.editLayout))
    #expect(!model.canPerform(.editAppearance), "already in appearance — 4.1.0 greys this")
    #expect(model.canPerform(.toggleLayoutAppearance))
  }

  /// The HDL view is the third `CentreView` case and neither command names it, so a toggle from
  /// `.hdl` has to pick a side. Upstream compares against `"appearance"`, not against `"layout"`,
  /// so anything that is not the appearance editor, the HDL card included, toggles *to*
  /// appearance. The expression this replaced tested `== .layout` and sent HDL the other way.
  ///
  /// **LATENT, and labelled as such rather than presented as a fixed live bug**: nothing in the
  /// shipping shell assigns `centreView = .hdl`, so no click reaches this today. It is pinned
  /// because it is the one branch of the toggle a user cannot currently walk into, which is
  /// exactly the branch that rots.
  @Test("toggling out of the HDL view goes to appearance, as upstream's comparison does")
  @MainActor
  func toggleFromHdlGoesToAppearance() throws {
    let model = EditorModel(host: try openTwoCircuitProject())
    model.centreView = .hdl
    model.perform(.toggleLayoutAppearance)
    #expect(model.centreView == .appearance)
  }
}

// MARK: - Circuit Statistics

@Suite("Circuit Statistics — the command, not the table view")
struct CircuitStatisticsCommandTests {

  private func row(_ report: CircuitStatisticsReport, named name: String) throws
    -> CircuitStatisticsRow
  {
    try #require(
      report.rows.first { $0.component == name },
      "expected \(name), got rows: \(report.rows.map(\.component))")
  }

  /// The test asserts the payload rather than just "no issue was raised". A command arm that
  /// swallowed `.circuitStatistics` would look quiet and still show the student no counts; a
  /// command wired to the wrong circuit would be worse, because it would show a plausible table
  /// for the wrong work.
  @Test("circuitStatistics hands the presenter the current circuit's FileStatistics report")
  @MainActor
  func statisticsPassesTheCurrentCircuitReport() throws {
    let model = EditorModel(host: try openTwoCircuitProject())
    var reports: [CircuitStatisticsReport] = []
    model.circuitStatisticsPresenter = { reports.append($0) }

    #expect(model.canPerform(.circuitStatistics))
    let issuesBefore = model.issues.count
    model.perform(.circuitStatistics)

    #expect(model.issues.count == issuesBefore)
    #expect(model.transientError == nil)
    let alpha = try #require(reports.last)
    #expect(alpha.circuitName == "alpha")
    #expect(try row(alpha, named: "Pin").library == "Wiring")
    #expect(try row(alpha, named: "AND Gate").library == "Gates")
    #expect(try row(alpha, named: "Pin").simpleCount == 1)
    #expect(try row(alpha, named: "AND Gate").uniqueCount == 1)
    #expect(try row(alpha, named: CircuitStatisticsReport.totalWithoutSubcircuitsLabel).simpleCount == 2)
    #expect(try row(alpha, named: CircuitStatisticsReport.totalWithSubcircuitsLabel).recursiveCount == 2)

    model.perform(.setCurrentCircuit(try circuitID(model, named: "beta")))
    model.perform(.circuitStatistics)
    let beta = try #require(reports.last)
    #expect(beta.circuitName == "beta")
    #expect(try row(beta, named: "Pin").simpleCount == 1)
    #expect(try row(beta, named: CircuitStatisticsReport.totalWithoutSubcircuitsLabel).simpleCount == 1)
    #expect(try row(beta, named: CircuitStatisticsReport.totalWithSubcircuitsLabel).uniqueCount == 1)
  }
}

// MARK: - Load Library

@Suite("Load Library — refused until the undoable load action exists")
struct LoadLibraryCommandRefusalTests {

  @Test("loadBuiltinLibrary and loadLogisimLibrary are disabled with actionable bypass errors")
  @MainActor
  func libraryLoadCommandsAreHonestlyRefused() throws {
    let host = try openTwoCircuitProject()

    #expect(!host.canPerform(.loadBuiltinLibrary))
    #expect(!host.canPerform(.loadLogisimLibrary))

    for command in [ProjectCommand.loadBuiltinLibrary, .loadLogisimLibrary] {
      #expect(throws: ProjectHostError.self) { try host.perform(command) }
      do {
        try host.perform(command)
      } catch {
        let message = error.localizedDescription
        #expect(
          message.contains("LoadLibraries"),
          "the refusal must name the missing undoable action; got: \(message)")
        #expect(
          message.contains("chooser") || message.contains(".circ file importer"),
          "the refusal must name the missing user-facing half; got: \(message)")
      }
    }
  }

  /// There is no headless SwiftUI API for menu disabled state, so this is a source gate like
  /// `ExplorerAffordanceTests`: comments are stripped and both producers must read `canPerform`
  /// for both commands. A host-level refusal alone would still leave a clickable item that reports
  /// an error after the click, which is exactly the shape this pair is leaving behind.
  @Test("both library-load producers read canPerform instead of leaving live no-op buttons")
  func libraryLoadProducersAreDisabled() throws {
    let appCommands = try Self.codeOf("LogisimUI/App/AppCommands.swift")
    let explorer = try Self.codeOf("LogisimUI/Sidebar/ExplorerSidebar.swift")

    for source in [appCommands, explorer] {
      #expect(source.contains("canPerform(.loadBuiltinLibrary)"))
      #expect(source.contains("canPerform(.loadLogisimLibrary)"))
    }
  }

  private static func codeOf(_ relativePath: String) throws -> String {
    let url =
      URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Sources")
      .appendingPathComponent(relativePath)
    let text = try String(contentsOf: url, encoding: .utf8)
    return text
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { line -> String in
        guard let marker = line.range(of: "//") else { return String(line) }
        return String(line[line.startIndex..<marker.lowerBound])
      }
      .joined(separator: "\n")
  }
}

// MARK: - Reload Library

@Suite("Reload Library — end to end, against a file that changed on disk", .serialized)
struct LibraryReloadCommandTests {

  /// `.serialized` and a per-test directory: `LibraryManager` is a process-wide singleton keyed by
  /// descriptor, so two tests loading libraries at the same path would share its cache.
  private func makeTemporaryDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("logisim-reload-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Load a `.circ` as a library and make the host's outline see it.
  ///
  /// The refresh goes through `.setCurrentCircuit(currentCircuit)`, which rebuilds the outline and
  /// has no other effect once `adopt` early-returns on the circuit already being current. It is
  /// here because **nothing in the shell loads a library yet**: `loadLogisimLibrary` and
  /// `loadBuiltinLibrary` now refuse honestly until upstream's undoable unit,
  /// `LogisimFileActions.LoadLibraries`, is ported next to its five siblings. When it lands, this
  /// helper becomes `host.perform(.loadLogisimLibrary)` and the two halves of the library family
  /// meet.
  @MainActor
  private func attachLibrary(at url: URL, to host: LogisimFileProjectHost) throws -> LibraryID {
    let library = try #require(
      host.file.loader.loadLogisimLibrary(url) as? LoadedLibrary,
      "the loader could not read the library fixture — the rest of this test would be vacuous")
    host.file.addLibrary(library)
    try host.perform(.setCurrentCircuit(try #require(host.currentCircuit)))
    return try #require(
      host.outline.libraries.first { $0.name == library.displayName }?.id,
      "the library is in the file but not in the outline")
  }

  /// The whole point of a reload: the `.circ` behind a loaded library changed, and the project
  /// picks the change up without being reopened. Asserted on the *tool list*, because that is
  /// what the explorer draws and what a placement would use; a reload that swapped the
  /// `LoadedLibrary`'s base and left the outline stale is the failure worth catching.
  @Test("reloading re-reads the library file and the new contents reach the outline")
  @MainActor
  func libraryReloadRereadsTheFileFromDisk() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("shared.circ")
    try Data(libraryProject(circuitNamed: "before_reload").utf8).write(to: url)

    let host = try openTwoCircuitProject()
    let id = try attachLibrary(at: url, to: host)
    #expect(host.outline.libraries.first { $0.id == id }?.tools.map(\.name) == ["before_reload"])

    // The lab hands out an updated `shared.circ`; the student overwrites theirs and reloads.
    try Data(libraryProject(circuitNamed: "after_reload").utf8).write(to: url)
    #expect(host.canPerform(.reloadLibrary(id)), "a LoadedLibrary is reloadable in 4.1.0")
    try host.perform(.reloadLibrary(id))

    #expect(host.outline.libraries.first { $0.id == id }?.tools.map(\.name) == ["after_reload"])
    #expect(
      host.drainPendingIssues().isEmpty,
      "a reload that succeeded must not also report a loader error")
  }

  /// `Popups$LibraryPopup`'s constructor: `reload.setEnabled(canUnload && lib instanceof
  /// LoadedLibrary)`. A built-in has no descriptor to re-read, so 4.1.0 greys the item.
  ///
  /// Both halves are asserted, and the second is not redundant: `ExplorerSidebar.swift:313`
  /// attaches no `.disabled` to its Reload Library item, so the click still arrives at the host
  /// and D13 requires it to say what is wrong rather than no-op or trap.
  @Test("a built-in library is refused, and refused with a reason a user can act on")
  @MainActor
  func builtinLibraryIsRefused() throws {
    let host = try openTwoCircuitProject()
    let id = try #require(host.outline.libraries.first?.id)
    #expect(!host.canPerform(.reloadLibrary(id)))

    #expect(throws: ProjectHostError.self) { try host.perform(.reloadLibrary(id)) }
    do {
      try host.perform(.reloadLibrary(id))
    } catch {
      let message = error.localizedDescription
      #expect(
        message.contains("built in") && message.contains(".circ"),
        "the refusal has to name why and what would work instead; got: \(message)")
    }
  }

  /// A reload whose file has gone away. `LibraryManager.reload` reports through
  /// `loader.showError` and returns void, so without the drain in the command arm this is
  /// indistinguishable from success; the library would simply keep its old contents and the user
  /// would be told nothing.
  @Test("a reload that fails is reported rather than silently keeping the old contents")
  @MainActor
  func failedReloadIsReported() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("vanishes.circ")
    try Data(libraryProject(circuitNamed: "still_here").utf8).write(to: url)

    let host = try openTwoCircuitProject()
    let id = try attachLibrary(at: url, to: host)
    _ = host.drainPendingIssues()
    try FileManager.default.removeItem(at: url)

    try host.perform(.reloadLibrary(id))
    #expect(
      !host.drainPendingIssues().isEmpty,
      "the loader's own diagnostic was recorded and dropped, which is a silent failure")
  }
}
