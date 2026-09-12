// AnalyzeWiringTests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// CAN THE APPLICATION ACTUALLY REACH IT?
//
// `AnalyzeModelTests` proves the derivation is right. That is not what was broken. What was
// broken is that no shipping target imported `LogisimAnalyze` at all: the menu item existed,
// `.analyzeCircuit` existed in `ProjectCommand`, and `LogisimFileProjectHost.perform` dropped it
// into the `default:` arm that throws `notImplemented`. A test that constructs an
// `AnalyzerModel` by hand would have passed throughout, which is exactly the failure mode this
// suite is written against.
//
// So it starts from the same objects the *menu bar* starts from, a real
// `LogisimFileProjectHost` opened from bytes, wrapped in a real `EditorModel`, and asserts:
//
//   • `EditorModel.analyzableCircuit`, the seam the menu item reads, resolves to the host's
//     current circuit and its file, by identity;
//   • it FOLLOWS a circuit switch, so the window cannot analyse a circuit the user left;
//   • driving the presentation the way the menu item does leaves the derived table in it, with
//     values the shipped 4.1.0 jar printed;
//   • `AnalyzerWindowController` produces one window and reuses it, as `AnalyzerManager` does.
//
// The window is created but never ordered front: `show(circuit:file:)` calls `NSApp.activate()`
// and a test must not steal focus from whoever is at the keyboard.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import AppKit
import Foundation
import LogisimAnalyze
import LogisimFile
import SwiftUI
import Testing

@testable import LogisimUI

/// Two circuits, so "the analyzer follows the current circuit" is assertable at all.
///
/// Verified against the shipped 4.1.0 jar by `DeriveProbe` (see
/// `docs/experiments/analyze-wiring.md`). Literal stdout:
///
///     xor2: PIN a in (80,100) · PIN y out (240,120) · PIN b in (80,140)
///            HEADER a b | y      ROW 0 0 0 | 0   ROW 1 0 1 | 1   ROW 2 1 0 | 1   ROW 3 1 1 | 0
///            TABLE-MINIMAL y  ~a⋅b+a⋅~b
///     and2: PIN p in (80,100) · PIN r out (240,120) · PIN q in (80,140)
///            HEADER p q | r      ROW 0 0 0 | 0   ROW 1 0 1 | 0   ROW 2 1 0 | 0   ROW 3 1 1 | 1
///            TABLE-MINIMAL r  p⋅q
///
/// Note in both, the OUTPUT pin sorts second: `Analyze.getPinLabels` sorts all pins together
/// before splitting them.
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
@Suite("Analyze Circuit — the wiring the menu item uses")
struct AnalyzeWiringTests {

  private func openHost() throws -> LogisimFileProjectHost {
    LogisimFileProjectHostFactory.registerBuiltinLibrariesIfNeeded()
    return try #require(
      LogisimFileProjectHostFactory().openProject(
        data: Data(twoCircuits.utf8), url: nil, contentType: LogisimDocumentType.circuit)
        as? LogisimFileProjectHost)
  }

  @Test("the menu item's seam resolves to the host's current circuit and its file")
  func seamResolvesToTheRealCircuit() throws {
    let host = try openHost()
    let model = EditorModel(host: host)
    let target = try #require(model.analyzableCircuit)

    // Identity, not equality: this must be the very circuit the canvas is showing (D4).
    #expect(target.circuit === host.currentCircuitObject)
    #expect(target.circuit.name == "xor2")
    #expect(target.file === host.file)
  }

  @Test("the seam follows a circuit switch, so the window cannot analyse the wrong circuit")
  func seamFollowsTheCurrentCircuit() throws {
    let host = try openHost()
    let model = EditorModel(host: host)
    #expect(try #require(model.analyzableCircuit).circuit.name == "xor2")

    let other = try #require(host.outline.circuits.first { $0.name == "and2" })
    try host.perform(.setCurrentCircuit(other.id))

    let switched = try #require(model.analyzableCircuit)
    #expect(switched.circuit.name == "and2")

    // And the derivation follows it: `and2` is p⋅q, not xor.
    let presentation = AnalyzerPresentation()
    presentation.analyze(circuit: switched.circuit, file: switched.file)
    let analysis = try #require(presentation.analysis)
    #expect(analysis.model.inputs.bits == ["p", "q"])
    #expect(analysis.model.outputs.bits == ["r"])
    let column = (0..<4).map { analysis.truthTable.outputEntry(row: $0, column: 0) }
    #expect(column == [.zero, .zero, .zero, .one])
    #expect(analysis.minimalExpression(for: "r")?.toString() == "p⋅q")
  }

  @Test("driving the presentation the way the menu item does leaves the derived table in it")
  func presentationHoldsTheDerivedTable() throws {
    let host = try openHost()
    let model = EditorModel(host: host)
    let target = try #require(model.analyzableCircuit)

    let presentation = AnalyzerPresentation()
    presentation.analyze(circuit: target.circuit, file: target.file)

    let analysis = try #require(presentation.analysis)
    #expect(presentation.failure == nil)
    // `configureAnalyzer` lands on the EXPRESSION tab when `computeExpression` succeeded, and
    // only falls back to the table when it did not (`ProjectCircuitActions.java:63-86`). This
    // fixture takes the netlist path, so upstream would show the expression. The assertion read
    // `.table` until #92, because the expression tab did not exist to land on.
    #expect(presentation.tab == .expression)

    #expect(analysis.columns.map(\.label) == ["a", "y", "b"])
    #expect(analysis.model.inputs.bits == ["a", "b"])
    #expect(analysis.model.outputs.bits == ["y"])
    #expect(analysis.truthTable.rowCount == 4)

    // The jar's ROW 0..3 for `y`: 0 1 1 0.
    let column = (0..<4).map { analysis.truthTable.outputEntry(row: $0, column: 0) }
    #expect(column == [.zero, .one, .one, .zero])

    // And the minimised expression the Minimized pane shows.
    #expect(analysis.minimalExpression(for: "y")?.toString() == "~a⋅b+a⋅~b")
  }

  @Test("the analyzer window is created once and reused, as AnalyzerManager does")
  func oneWindowReused() throws {
    let host = try openHost()
    let model = EditorModel(host: host)
    let target = try #require(model.analyzableCircuit)

    // Deliberately NOT `show(...)`: that calls `NSApp.activate()`.
    let controller = AnalyzerWindowController()
    let first = controller.windowForTesting()
    let second = controller.windowForTesting()
    #expect(first === second)
    #expect(first.contentViewController != nil)
    #expect(first.title == "Combinational Analysis")

    // And the presentation the window observes really holds a derivation, rather than the
    // window being an empty shell that merely exists.
    let presentation = AnalyzerPresentation.shared
    presentation.analyze(circuit: target.circuit, file: target.file)
    let analysis = try #require(presentation.analysis)
    #expect(analysis.circuitName == "xor2")
    #expect(analysis.truthTable.rowCount == 4)
  }

  @Test("the window's view body actually evaluates over a real derivation")
  func viewBodyRendersRatherThanMerelyCompiling() throws {
    // Constructing a SwiftUI view runs none of its body: `NSHostingController(rootView:)`
    // succeeds against a view that would trap the moment it laid out. That is the same class of
    // false green as "the type is reachable", so this renders each pane offscreen and requires a
    // non-empty image back. It steals no focus; nothing is ordered front.
    let host = try openHost()
    let model = EditorModel(host: host)
    let target = try #require(model.analyzableCircuit)

    let presentation = AnalyzerPresentation()
    presentation.analyze(circuit: target.circuit, file: target.file)

    for tab in AnalyzerPresentation.Tab.allCases {
      presentation.tab = tab
      let renderer = ImageRenderer(content: AnalyzerWindowContent(presentation: presentation))
      renderer.proposedSize = ProposedViewSize(width: 720, height: 560)
      let image = try #require(renderer.nsImage, "\(tab.title) pane rendered nothing")
      #expect(image.size.width > 0 && image.size.height > 0, "\(tab.title) pane is empty")
    }
  }
}
