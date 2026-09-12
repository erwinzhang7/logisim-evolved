// ExplorerAffordanceTests.swift: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE EXPLORER'S VISIBLE CONTROLS: that they exist, and that they send live commands.
//
// Written for a report from real use: *"how do u add more circuits and all those functions? this
// is missing a ton. and im not seeing lightmode toggle either."* Both premises were false and the
// complaint was still right:
//
//   • `ProjectCommand.addCircuit` is WIRED and had two producers, Circuit ▸ Add Circuit… (⇧⌘N)
//     and the explorer's right-click menu, and neither is visible.
//   • Light/dark has been in Settings ▸ Appearance ▸ Theme since it was moved there at this
//     owner's own request, and nothing in the main window pointed at that window.
//
// So the defect was discoverability, the fix is affordances, and this suite is the part of an
// affordance that can be measured headlessly: **which command the visible control sends, and
// whether that command is alive.** `ExplorerSidebar.actionBar` now carries a "+" and a
// `SettingsLink`, and `ExplorerAffordance` holds the two decisions behind them as values, the same
// split `CircuitRenameRequest` uses.
//
// ── WHAT IS ASSERTED ────────────────────────────────────────────────────────────────────────────
//
//   1. the "+" and the context-menu item send ONE command, structurally (one constant), and that
//      command, handed to a real `LogisimFileProjectHost`, actually adds a circuit and reports no
//      error; i.e. it is WIRED, not one of the commands pinned in `CommandSurfaceAuditTests`;
//   2. a circuit row's "Analyze Circuit…" reaches the analyzer for THAT row rather than for
//      whichever circuit happens to be current, and the derived expression proves which circuit
//      was analysed;
//   3. it no longer sends the INERT `.analyzeCircuit`: with the inertness of that command
//      measured in the same test, so the scan cannot pass vacuously;
//   4. this file contains a `SettingsLink` and never reaches `preferences.appearance`, so the
//      signpost is present and is not a second theme control. `AppearancePlacementTests`'s
//      `chromeFiles` covers the menu bar, the toolbar and the canvas overlay; the sidebar was
//      outside it.
//
// ── WHAT IS NOT, stated rather than implied ────────────────────────────────────────────────────
//
// That the "+" is *drawn*, that its `.help` tooltip appears, that `SettingsLink` opens the window,
// and that `.disabled` tracks `canPerform` on screen. No test here drives SwiftUI; there is no
// headless handle on "is this button in the bar", which is precisely why the commands were pulled
// out of the view into constants a test can hold. (3) and (4) are source scans for the same reason
// `AppearancePlacementTests` and `PreferenceConsumerTests` are: placement is a fact about files.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import AppKit
import Foundation
import LogisimAnalyze
import LogisimFile
import Testing

@testable import LogisimUI

/// Two circuits, so "the analyzer follows the *row*" is assertable at all. Same fixture and the
/// same jar-verified values as `AnalyzeWiringTests` (whose copy is file-private): `xor2` minimises
/// to `~a⋅b+a⋅~b` and `and2` to `p⋅q`, both printed by the shipped 4.1.0 jar; see
/// `docs/experiments/analyze-wiring.md`. `xor2` is `<main>`, so it is the circuit that is current
/// on open and `and2` is the one a row menu has to reach *without* being current.
private let twoCircuits = """
  <?xml version="1.0" encoding="UTF-8" standalone="no"?>
  <project source="4.1.0" version="1.0">
    <lib desc="#Wiring" name="0"/>
    <lib desc="#Gates" name="1"/>
    <main name="xor2"/>
    <options>
      <a name="gateUndefined" val="ignore"/>
      <a name="simlimit" val="1000"/>
      <a name="simrand" val="0"/>
    </options>
    <circuit name="xor2">
      <a name="circuit" val="xor2"/>
      <comp lib="0" loc="(80,100)" name="Pin">
        <a name="label" val="a"/>
      </comp>
      <comp lib="0" loc="(80,140)" name="Pin">
        <a name="label" val="b"/>
      </comp>
      <comp lib="0" loc="(240,120)" name="Pin">
        <a name="facing" val="west"/>
        <a name="label" val="y"/>
        <a name="output" val="true"/>
      </comp>
      <comp lib="1" loc="(190,120)" name="XOR Gate"/>
      <wire from="(80,100)" to="(140,100)"/>
      <wire from="(80,140)" to="(140,140)"/>
      <wire from="(190,120)" to="(240,120)"/>
    </circuit>
    <circuit name="and2">
      <a name="circuit" val="and2"/>
      <comp lib="0" loc="(80,100)" name="Pin">
        <a name="label" val="p"/>
      </comp>
      <comp lib="0" loc="(80,140)" name="Pin">
        <a name="label" val="q"/>
      </comp>
      <comp lib="0" loc="(240,120)" name="Pin">
        <a name="facing" val="west"/>
        <a name="label" val="r"/>
        <a name="output" val="true"/>
      </comp>
      <comp lib="1" loc="(190,120)" name="AND Gate"/>
      <wire from="(80,100)" to="(150,100)"/>
      <wire from="(80,140)" to="(150,140)"/>
      <wire from="(190,120)" to="(240,120)"/>
    </circuit>
  </project>
  """

@MainActor
@Suite("The explorer's visible affordances — the commands behind them")
struct ExplorerAffordanceTests {

  private func openModel() throws -> EditorModel {
    LogisimFileProjectHostFactory.registerBuiltinLibrariesIfNeeded()
    let host = try LogisimFileProjectHostFactory().openProject(
      data: Data(twoCircuits.utf8), url: nil, contentType: LogisimDocumentType.circuit)
    return EditorModel(host: host)
  }

  private func id(of name: String, in model: EditorModel) throws -> CircuitID {
    try #require(model.outline.circuits.first { $0.name == name }?.id)
  }

  // MARK: - 1. The "+" button

  /// The structural half. Two `.addCircuit` literals, one in the bar, one in the context menu,
  /// could drift apart silently, and "the button does the same thing as the right-click item" is
  /// the property the report is about, so they share one constant and this pins it.
  ///
  /// Worth nothing on its own, which is why `theAddCommandIsLiveAgainstARealHost` follows.
  @Test("the bar's + and the list's Add Circuit… are one command")
  func theAddAffordanceIsOneCommand() {
    #expect(ExplorerAffordance.addCircuit == .addCircuit)
  }

  /// The half that matters: the command the new visible button sends is *alive*. A "+" wired to
  /// one of the commands pinned in `CommandSurfaceAuditTests.expectedInert` would look identical
  /// on screen and answer "… is not implemented yet." when pressed, which would be a worse bug
  /// than the invisible menu item it replaced.
  @Test("the + button's command is enabled, adds a circuit, and reports nothing")
  func theAddCommandIsLiveAgainstARealHost() throws {
    let model = try openModel()
    let before = model.outline.circuits.count
    #expect(before == 2)
    #expect(model.canPerform(ExplorerAffordance.addCircuit))

    let issuesBefore = model.issues.count
    model.perform(ExplorerAffordance.addCircuit)

    #expect(model.outline.circuits.count == before + 1)
    // Both, because `perform` reports a refusal twice, `transientError` for the inline banner and
    // an appended issue, and the INERT signature is exactly a "… is not implemented yet." there.
    #expect(model.transientError == nil)
    #expect(model.issues.count == issuesBefore)
  }

  // MARK: - 2 and 3. Analyze, from a row rather than from the menu bar

  /// `EditorModel.analyzableCircuit` resolves the CURRENT circuit only. A row menu names a circuit
  /// that need not be current, so without preparation "Analyze Circuit…" on `and2` would open the
  /// analyzer on `xor2`: a silent wrong answer, which is worse than the inert command it
  /// replaced. The expression is the proof of which circuit was analysed: `p⋅q` is `and2`.
  @Test("Analyze on a row analyses that row, not whatever is current")
  func analyzeFromARowTargetsThatRow() throws {
    let model = try openModel()
    let xor2 = try id(of: "xor2", in: model)
    let and2 = try id(of: "and2", in: model)
    #expect(model.currentCircuit == xor2)

    // The row that is already current needs no preparation; sending a redundant
    // `.setCurrentCircuit` would be a no-op the undo stack might still see.
    #expect(ExplorerAffordance.prepareAnalysis(of: xor2, in: model) == nil)

    let prepare = try #require(ExplorerAffordance.prepareAnalysis(of: and2, in: model))
    #expect(prepare == .setCurrentCircuit(and2))
    model.perform(prepare)

    let target = try #require(model.analyzableCircuit)
    #expect(target.circuit.name == "and2")

    // Driven exactly as the menu item drives it, on a private presentation so no window opens
    // and `NSApp.activate()` never steals the keyboard.
    let presentation = AnalyzerPresentation()
    presentation.analyze(circuit: target.circuit, file: target.file)
    let analysis = try #require(presentation.analysis)
    #expect(presentation.failure == nil)
    #expect(analysis.model.inputs.bits == ["p", "q"])
    #expect(analysis.minimalExpression(for: "r")?.toString() == "p⋅q")
  }

  /// The item used to send `.analyzeCircuit` when that command still fell into the host's
  /// `notImplemented` arm: the Circuit menu's item worked, because it bypassed the command; the
  /// sidebar's item, with the same name, did not.
  ///
  /// **This test has fired, and it fired for exactly the reason it was written to fire.**
  ///
  /// It used to assert that `.analyzeCircuit` was *refused* by the host, and its own failure
  /// message read: "`.analyzeCircuit` is no longer refused by the host: delete the scan below, it
  /// is stale". A separate change wired that command in the same merge, so the assertion went red
  /// on integration and told the integrator what to do with it. That is the whole value of pinning
  /// a known-broken state by name rather than commenting on it.
  ///
  /// What it asserts now is the other side of the same coin: the command works, and the sidebar is
  /// allowed to send it. The scan that used to forbid `perform(.analyzeCircuit)` is gone with the
  /// refusal it was protecting against.
  @Test("the row's Analyze item sends a command the host actually performs")
  func analyzeSendsAWiredCommand() throws {
    let model = try openModel()
    let issuesBefore = model.issues.count

    #expect(
      model.canPerform(.analyzeCircuit),
      """
      `.analyzeCircuit` reports that it cannot be performed. If it has gone back to being refused,       the explorer's Analyze row item is a dead control again and this test is the one that says       so.
      """)

    model.perform(.analyzeCircuit)
    #expect(
      model.issues.count == issuesBefore,
      """
      performing `.analyzeCircuit` raised \(model.issues.count - issuesBefore) issue(s); the last       was \(String(describing: model.issues.last?.detail)). A command the menu offers must not       report "not implemented" when clicked.
      """)
  }

  /// The enablement rule, which is what keeps the item from being a dead control in the two cases
  /// where it cannot work. VHDL is upstream's own split: `Popups$VhdlPopup` holds only `edit` and
  /// `remove`, and a VHDL entity has no netlist to derive a table from.
  @Test("Analyze is offered for a circuit row and refused for a VHDL row")
  func canAnalyseRefusesWhatCannotBeAnalysed() throws {
    let model = try openModel()
    let and2 = try #require(model.outline.circuits.first { $0.name == "and2" })
    #expect(ExplorerAffordance.canAnalyse(and2, in: model))

    var asVhdl = and2
    asVhdl.kind = .vhdl
    #expect(!ExplorerAffordance.canAnalyse(asVhdl, in: model))
  }

  // MARK: - Circuit statistics, from a row rather than from the menu bar

  /// Same asymmetry as Analyze Circuit: the command computes statistics for the current circuit,
  /// while a row menu names a circuit that need not be current. The row therefore prepares the
  /// current circuit first. Without that, right-clicking `and2` would show the counts for `xor2`,
  /// which is a silent wrong answer rather than a visible refusal.
  @Test("Circuit Statistics on a row targets that row, not whatever is current")
  func statisticsFromARowTargetsThatRow() throws {
    let model = try openModel()
    let xor2 = try id(of: "xor2", in: model)
    let and2 = try id(of: "and2", in: model)
    #expect(model.currentCircuit == xor2)

    var reports: [CircuitStatisticsReport] = []
    model.circuitStatisticsPresenter = { reports.append($0) }

    let prepare = try #require(ExplorerAffordance.prepareAnalysis(of: and2, in: model))
    model.perform(prepare)
    model.perform(.circuitStatistics)

    let report = try #require(reports.last)
    #expect(report.circuitName == "and2")
    #expect(report.rows.contains { $0.component == "AND Gate" && $0.simpleCount == 1 })
    #expect(!report.rows.contains { $0.component == "XOR Gate" })
  }

  /// There is no headless handle on a SwiftUI context-menu item, so the source scan pins the
  /// producer itself, not merely the command's existence. The command-level tests would stay green
  /// if the row menu forgot the preparation step and showed statistics for the current circuit.
  @Test("the row's Circuit Statistics item prepares the clicked circuit before performing")
  func statisticsRowProducerPreparesBeforePerforming() throws {
    let code = try Self.codeOf(Self.sidebarFile)
    let start = try #require(code.range(of: "Button(\"Circuit Statistics…\")"))
    let tail = code[start.lowerBound...]
    let end = try #require(tail.range(of: "Divider()"))
    let block = String(tail[..<end.lowerBound])
    #expect(block.contains("prepareAnalysis(of: circuit.id, in: model)"))
    #expect(block.contains("model.perform(.circuitStatistics)"))
    #expect(block.contains("ExplorerAffordance.canShowStatistics(circuit, in: model)"))
  }

  // MARK: - 4. The signpost to Settings

  /// Both halves in one test, because either alone passes for the wrong reason: a file with no
  /// link and no theme control satisfies the second, and a file with a full duplicate radio group
  /// satisfies the first.
  ///
  /// The needles are `AppearancePlacementTests.appearanceNeedles`, repeated rather than imported
  /// so this file stands alone, exactly as `PreferenceConsumerTests` repeats its own reader.
  @Test("the sidebar points at Settings and does not duplicate the theme control")
  func theSidebarSignpostsSettingsWithoutCopyingIt() throws {
    let code = try Self.codeOf(Self.sidebarFile)

    #expect(
      code.contains("SettingsLink"),
      """
      The explorer no longer offers a way to reach Settings. Reported from real use: "im not \
      seeing lightmode toggle either" — the control is in Settings ▸ Appearance ▸ Theme and the \
      main window has to say so somewhere, because ⌘, and the application menu were not found.
      """)

    let needles = [
      "preferences.appearance", "Preferences.shared.appearance", "AppearancePreference",
    ]
    for needle in needles {
      #expect(
        !Self.hasWordBoundedHit(code, needle),
        """
        \(Self.sidebarFile) reaches the light/dark preference via `\(needle)`. The sidebar must \
        POINT AT Settings, not carry a second theme control — the owner asked for the toolbar \
        toggle to be removed, and `AppearancePlacementTests` holds the menu bar, the toolbar and \
        the canvas overlay to the same rule.
        """)
    }
  }

  /// **The gate this change shipped without, and the gate's own first two attempts failed too.**
  ///
  /// Two independent reviewers deleted the whole `+` Button from the bar and measured the suite
  /// still green. Everything else in this file tests the *command* behind the button, that it is
  /// one command, that it is enabled, that it adds a circuit, and all of that stays true of a
  /// sidebar with no button in it, which is exactly the sidebar the report was about:
  ///
  ///   > "how do u add more circuits and all those functions? this is missing a ton."
  ///
  /// The command was never missing. The *affordance* was.
  ///
  /// The first repair scanned `ExplorerSidebar.swift` for the words `actionBar` and `plus`. It
  /// reddened nothing either, and the reason is worth keeping: **a bare identifier in a source
  /// scan cannot tell a declaration from a use.** `private var actionBar` satisfies "contains
  /// actionBar" with the bar removed from `body`, and another `plus` elsewhere in the file
  /// satisfies the symbol check with the button's own symbol changed. Both probes were run and
  /// both stayed green.
  ///
  /// So the bar became a described list, `ExplorerAffordance.actionBarItems`, and this reads it.
  /// A control that exists only as view code cannot be seen without a window; a control that
  /// exists as a value can.
  @Test("the action bar offers Add Circuit as a visible control")
  func theActionBarOffersAddCircuit() {
    let commands = ExplorerAffordance.actionBarItems.compactMap { item -> ProjectCommand? in
      if case .command(let command, _, _, _) = item { return command }
      return nil
    }
    #expect(
      commands.contains(.addCircuit),
      """
      The explorer's action bar has no Add Circuit control, so adding a circuit is reachable only       by right-clicking — which is how it was when the owner asked where circuits get added.
      """)
  }

  /// The signpost is a control too, and it is the answer to the other half of the same report.
  @Test("the action bar offers a route to Settings")
  func theActionBarSignpostsSettings() {
    let hasSettings = ExplorerAffordance.actionBarItems.contains { item in
      if case .settings = item { return true }
      return false
    }
    #expect(
      hasSettings,
      """
      Nothing in the explorer points at Settings. Reported from real use: "im not seeing       lightmode toggle either" — the control is in Settings ▸ Appearance and the main window has       to say so somewhere, because ⌘, and the application menu were not found.
      """)
  }

  /// **The calibration, and it is the one that makes the two above non-vacuous.** The list must be
  /// what the view actually renders, not a description that has drifted away from it. Asserted by
  /// requiring the view to mention the list by name: a hand-written `HStack` that ignored
  /// `actionBarItems` would pass both tests above while showing nothing.
  @Test("the view renders the described list rather than a hand-written bar")
  func theViewRendersTheDescribedList() throws {
    let code = try Self.codeOf(Self.sidebarFile)
    #expect(
      code.contains("ExplorerAffordance.actionBarItems"),
      """
      `ExplorerSidebar` no longer renders `ExplorerAffordance.actionBarItems`, so the list the       tests above read is no longer the bar the user sees.
      """)
  }

  // MARK: - Reading the tree
  //
  // From `#filePath`, because `swift test` does not pin the working directory. Same approach, and
  // the same word-boundary guard, as `AppearancePlacementTests`.

  static let sidebarFile = "LogisimUI/Sidebar/ExplorerSidebar.swift"

  static var sourcesRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // LogisimUITests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // swift
      .appendingPathComponent("Sources")
  }

  /// The file's **code**, comments removed.
  ///
  /// Stripping is not fussiness, it is the difference between a gate and a decoration. This file
  /// scans `ExplorerSidebar.swift` for `SettingsLink`, and that file's comments explain the control
  /// by name: so the red probe for this change (delete the control, keep the comment) stayed
  /// GREEN until the stripper landed. Measured, not imagined. The `perform(.analyzeCircuit)` scan
  /// had the same hole in the opposite, noisier direction: prose quoting the old call would have
  /// failed a file that was correct.
  ///
  /// Line-oriented and deliberately simple: everything from the first `//` on a line to its end.
  /// That is sound for the one file scanned here, which has no `//` inside a string literal; the
  /// only string literals are labels, tooltips and SF Symbol names, and the two symbol lines with
  /// trailing `// D11`/`// D8` comments close their quote first. A file carrying a URL would need a
  /// real lexer, so `codeOf` asserts a landmark survives rather than trusting that silently.
  static func codeOf(_ relativePath: String) throws -> String {
    let text = try read(relativePath)
    let code =
      text
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { line -> String in
        guard let marker = line.range(of: "//") else { return String(line) }
        return String(line[line.startIndex..<marker.lowerBound])
      }
      .joined(separator: "\n")
    // Non-vacuity: a stripper that ate the file would make every `!contains` below pass.
    #expect(
      code.contains("struct ExplorerSidebar"),
      "comment stripping removed the code as well — every scan in this file is now vacuous")
    return code
  }

  static func read(_ relativePath: String) throws -> String {
    let url = sourcesRoot.appendingPathComponent(relativePath)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
      Issue.record("could not read \(url.path) — the scans here would pass vacuously")
      throw CocoaError(.fileNoSuchFile)
    }
    return text
  }

  /// `contains` alone would report a hit on a longer identifier that merely starts with the
  /// needle. Borrowed from `AppearancePlacementTests`, which needs it for the same reason.
  static func hasWordBoundedHit(_ text: String, _ needle: String) -> Bool {
    var searchRange = text.startIndex..<text.endIndex
    while let found = text.range(of: needle, range: searchRange) {
      if found.upperBound == text.endIndex { return true }
      let next = text[found.upperBound]
      if !(next.isLetter || next.isNumber || next == "_") { return true }
      searchRange = found.upperBound..<text.endIndex
    }
    return false
  }
}
