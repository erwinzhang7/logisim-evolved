// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution, which is GPL-3.0-only. This port is a derivative work and is
// therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// A CIRCUIT ABOVE AND LEFT OF THE ORIGIN WORKS EVERYWHERE ELSE.
//
// ── Why this file exists before the change that needs it ────────────────────────────────────
//
// `SelectTool.computeDxDy` clamps a drag so the selection's bounding box can never go negative
// (`dy = max(mouseDelta, -bounds.y)`), which is upstream's own line and is what the owner hit:
// "there seems to be invisible limits to canvas size. this is the highest it will go but clearly
// tons of canvas left." Removing that clamp is one line. Whether the REST of the app survives
// what it lets in is the actual question, and it is not answerable by reading the diff.
//
// So this traces the consequence first, in both directions, over the paths a component at
// negative coordinates has to survive: the grid, the file round-trip, hit testing, zoom-to-fit,
// and image export. It is deliberately a separate file from the change, because if any of these
// had failed, the change would have been the wrong thing to do and this would still have been
// worth keeping as the record of why.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import CoreGraphics
import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimStd
import Testing

@testable import LogisimUI

/// One AND gate placed above and left of the origin; a document a user could only produce once
/// the drag clamp is gone, written by hand so the file half can be tested on its own.
private let gateAboveTheOrigin = """
  <?xml version="1.0" encoding="UTF-8" standalone="no"?>
  <project source="4.1.0" version="1.0">
    <lib desc="#Base" name="0"/>
    <lib desc="#Gates" name="1"/>
    <main name="main"/>
    <circuit name="main">
      <comp lib="1" loc="(-200,-140)" name="AND Gate"/>
    </circuit>
  </project>
  """

@Suite("Negative coordinates survive the whole pipeline")
@MainActor
struct NegativeCoordinateTraceTests {

  /// A gate placed well above and left of the origin.
  private func circuitAboveTheOrigin() throws -> (Circuit, any Component) {
    StdLibraries.registerAll()
    let circuit = try Circuit(name: "negative")
    let gate = try AndGate.factory.createComponent(
      location: Location.create(-200, -140, hasToSnap: false),
      attributes: AndGate.factory.createAttributeSet())
    try circuit.mutatorAdd(gate)
    return (circuit, gate)
  }

  /// The grid is the first thing a drag touches, and Java's `Math.round` is `floor(x + 0.5)`,
  /// which disagrees with Swift's default rounding on every negative half-integer.
  /// `ToolGeometry` already says so in a comment; this is that comment as an assertion.
  @Test("snapping lands on the grid on the negative side too")
  func snappingWorksBelowZero() {
    #expect(CanvasGrid.snapXToGrid(-204) == -200)
    #expect(CanvasGrid.snapXToGrid(-206) == -210)
    #expect(CanvasGrid.snapYToGrid(-1) == 0)
    // The sign-symmetric pair, so a "fix" that special-cased negatives by flooring cannot pass.
    #expect(CanvasGrid.snapXToGrid(204) == 200)
    #expect(CanvasGrid.snapXToGrid(206) == 210)
  }

  /// The file format, through the app's own save path. A component the user can place but
  /// cannot save is worse than one they cannot place.
  ///
  /// Driven from a document rather than from a hand-built `LogisimFile`, because a circuit
  /// assembled in a test has no `<lib>` entries and `XmlWriter.fromTool` silently drops every
  /// component whose library it cannot name, which looks exactly like a negative-coordinate
  /// failure and is not one. (Measured: the first version of this test wrote an empty
  /// `<circuit>` element and I nearly filed it as a defect.)
  @Test("a component above the origin round-trips through .circ")
  func negativeLocationsRoundTrip() throws {
    let host = try #require(
      LogisimFileProjectHostFactory().openProject(
        data: Data(gateAboveTheOrigin.utf8), url: nil, contentType: LogisimDocumentType.circuit)
        as? LogisimFileProjectHost)

    // The READ half: the parser accepted a negative location and did not clamp it.
    let circuit = try #require(host.currentCircuitObject)
    let gate = try #require(circuit.nonWires.first)
    #expect(
      gate.location == Location.create(-200, -140, hasToSnap: false),
      "the loaded gate sits at \(gate.location), not where the file put it")

    // The WRITE half.
    let data = try host.serialize()
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(
      text.contains("loc=\"(-200,-140)\""),
      "the negative location was not written back as Java writes it; got:\n\(text)")
  }

  /// Hit testing runs through `SpatialIndex`, which buckets world coordinates. A bucket index
  /// derived with `/` rather than a flooring divide puts everything in (-10, -10)…(9, 9) into
  /// the same cell as the origin, which is a correctness bug that only shows up above the axis.
  @Test("a component above the origin can still be clicked")
  func negativeComponentsAreHitTestable() throws {
    let (circuit, gate) = try circuitAboveTheOrigin()
    let surface = CircuitCanvasSurface()
    surface.setCircuit(circuit)

    let box = gate.bounds
    let centre = CGPoint(
      x: CGFloat(box.x) + CGFloat(box.width) / 2, y: CGFloat(box.y) + CGFloat(box.height) / 2)
    let hit = try #require(
      surface.hitTest(worldPoint: centre, tolerance: 2),
      "clicking the middle of a gate at \(box) found nothing")
    #expect(hit.id == CircuitSceneSource.identity(of: gate))

    // And the converse, so the test is not passing because hit testing answers "yes" everywhere.
    #expect(surface.hitTest(worldPoint: CGPoint(x: 900, y: 900), tolerance: 2) == nil)
  }

  /// Zoom-to-fit reads `contentBounds`. If that were clamped at the origin, fitting a circuit
  /// above it would centre the camera on empty space.
  @Test("zoom-to-fit frames a circuit that sits above the origin")
  func zoomToFitFollowsTheContent() throws {
    let (circuit, _) = try circuitAboveTheOrigin()
    let surface = CircuitCanvasSurface()
    surface.setCircuit(circuit)

    let content = surface.contentBounds
    #expect(
      content.midX < 0 && content.midY < 0,
      "contentBounds is \(content); it has been clamped to the positive quadrant")

    var viewport = CanvasViewport(viewSize: CGSize(width: 800, height: 600))
    viewport.fit(content)
    #expect(viewport.visibleWorldRect.contains(content), "the fit does not contain the content")
  }

  /// **The owner's other ask, and it already holds**: "when we save photo or smth, wrap to like a
  /// certain distance from actual elements". Export is `circuit.bounds.expand(5)`, which is
  /// upstream's own rule and is origin-independent, so an image of a circuit above the axis is
  /// cropped to the circuit, not to the quadrant.
  @Test("an exported image is cropped to the content, wherever the content is")
  func exportWrapsTheContentNotTheOrigin() throws {
    let (circuit, gate) = try circuitAboveTheOrigin()
    let scene = try #require(
      CircuitExportImageScene.build(
        circuit: circuit, appearance: CanvasAppearance(), printerView: false))

    let box = gate.bounds
    let margin = CGFloat(CircuitExportImage.margin)
    #expect(scene.bounds.minX == CGFloat(box.x) - margin, "export box: \(scene.bounds)")
    #expect(scene.bounds.minY == CGFloat(box.y) - margin, "export box: \(scene.bounds)")
    #expect(scene.bounds.width == CGFloat(box.width) + margin * 2)
    #expect(scene.bounds.height == CGFloat(box.height) + margin * 2)
    #expect(
      scene.paintedComponentCount == 1,
      "the gate was not painted into the export scene at all")
  }
}
