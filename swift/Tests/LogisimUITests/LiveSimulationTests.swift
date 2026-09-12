// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution, which is GPL-3.0-only. This port is a derivative work and is
// therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE CANVAS IS CONNECTED TO THE RUNNING SIMULATION.
//
// ── Where this came from ────────────────────────────────────────────────────────────────────
//
// Reported from real use: "poke tool seems to not do jack actually." It did not, and the reason
// was larger than the poke tool: nothing in the shipping application ever crossed from the
// propagation thread to the canvas. Two facts, one cause, both measured before anything changed:
//
//   * `CircuitEditorCanvas.circuitState` was assigned in exactly two places in the repository and
//     both were test files. In the app it was permanently `nil`, so `PokeTool` handed every
//     component's poker a nil state.
//   * `CircuitSceneSource.paintContext` hard-coded `showState: false`, so the schematic always
//     rendered unpowered no matter what the simulator was doing.
//
// The simulator itself was never broken: `SimulationEngine` ticks and propagates, and the
// propagation kernel passes the jar-oracle `-tty table` gates. It was running with no window.
//
// ── Why these tests go through the real host ────────────────────────────────────────────────
//
// Because the defect was *only* visible there. Every existing poke test assigns
// `canvas.circuitState` itself, which is precisely the assignment the app was missing, so the
// whole poke path was covered by tests that could not fail for the one reason it was broken.
// `theAppsOwnCanvasHasASimulationState` below is the assertion those tests could not make.
//
// ── Threading ───────────────────────────────────────────────────────────────────────────────
//
// `.serialized`, and every wait is on the engine's own published counter rather than a sleep.
// Propagation happens on the clock thread (D1) and a request posted from the main actor completes
// asynchronously; there is no completion handler to await and inventing one would change the
// design to suit the test.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import AppKit
import CoreGraphics
import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimStd
import Testing

@testable import LogisimUI

// MARK: - Rig

/// A real host, a real canvas, and an input Pin wired to an output Pin.
///
/// The smallest circuit with something to watch: poking the input must change what the output
/// reads, and both are ordinary components a student places from the toolbar.
@MainActor
private struct LiveRig {
  let host: LogisimFileProjectHost
  let circuit: Circuit
  let surface: CircuitCanvasSurface
  let canvas: CircuitEditorCanvas
  let input: any Component
  let output: any Component

  init() throws {
    StdLibraries.registerAll()
    let madeHost = try #require(
      try LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
    let madeCircuit = try #require(madeHost.currentCircuitObject)

    func pin(_ type: AttributeOption, _ x: Int, _ y: Int) throws -> any Component {
      let attributes = Pin.factory.createAttributeSet()
      try attributes.setValue(Pin.attrType, type)
      let component = try Pin.factory.createComponent(
        location: Location.create(x, y, hasToSnap: false), attributes: attributes)
      try madeCircuit.mutatorAdd(component)
      return component
    }

    let madeInput = try pin(Pin.input, 100, 100)
    let madeOutput = try pin(Pin.output, 200, 100)
    try madeCircuit.mutatorAdd(
      Wire.create(
        Location.create(100, 100, hasToSnap: false),
        Location.create(200, 100, hasToSnap: false)))

    // `makeRenderSurface` is where the host joins the engine to the canvas and the surface. Going
    // through it rather than constructing the pieces is the whole point of this file.
    let madeSurface = try #require(madeHost.makeRenderSurface() as? CircuitCanvasSurface)
    let madeCanvas = try #require(madeHost.editorCanvas)
    madeSurface.renderView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    madeSurface.setViewport(
      CanvasViewport(
        zoom: 1, center: CGPoint(x: 150, y: 100), viewSize: CGSize(width: 800, height: 600)))

    host = madeHost
    circuit = madeCircuit
    input = madeInput
    output = madeOutput
    surface = madeSurface
    canvas = madeCanvas
  }

  /// Wait until the propagation thread has completed at least one more request.
  @discardableResult
  func settle(timeout: TimeInterval = 3) -> Bool {
    let before = host.engine.snapshot.propagationCount
    host.engine.post(.propagate)
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
      if host.engine.snapshot.propagationCount > before { return true }
      usleep(2000)
    }
    return host.engine.snapshot.propagationCount > before
  }

  /// The value the live simulation currently holds at a point, read the way the poke tool reads
  /// it: through `canvas.circuitState`, which is the seam under test.
  func value(at x: Int, _ y: Int) -> Value? {
    canvas.circuitState?.value(at: Location.create(x, y, hasToSnap: false))
  }

  func pointer(_ phase: CanvasPointerEvent.Phase, _ x: Int, _ y: Int) {
    canvas.controller.canvasHandlePointer(
      CanvasPointerEvent(
        phase: phase, world: CGPoint(x: CGFloat(x), y: CGFloat(y)), modifiers: [],
        clickCount: 1, buttonNumber: 1, dragOriginWorld: nil))
  }

  /// Select the poke tool the way the explorer does, then click a point the component agrees is
  /// inside it.
  ///
  /// The point is found by asking the component rather than written as a literal. A Pin's anchor
  /// is its *port*, on the boundary of its body, and `PokeTool.mousePressed` branches on
  /// `Circuit.allContaining`, so clicking the component's own location lands on the edge, is
  /// rejected, and the poke silently does nothing. Measured: that was this file's first failure.
  @discardableResult
  func poke(_ component: any Component) -> Bool {
    let resolved = canvas.controller.setActiveTool(
      fromLibrary: BuiltinPlaceholderTool(id: BaseToolIds.poke))
    guard resolved, let point = insidePoint(of: component) else { return false }
    pointer(.down, point.x, point.y)
    pointer(.up, point.x, point.y)
    return true
  }

  /// A point the component reports as its own.
  func insidePoint(of component: any Component) -> Location? {
    let box = component.bounds
    for dy in stride(from: 0, through: box.height, by: 1) {
      for dx in stride(from: 0, through: box.width, by: 1) {
        let point = Location.create(box.x + dx, box.y + dy, hasToSnap: false)
        if component.contains(point) { return point }
      }
    }
    return nil
  }
}

// MARK: - Tests

@Suite("The canvas is connected to the running simulation", .serialized)
@MainActor
struct LiveSimulationTests {

  /// **THE SEAM.** The app's own canvas must have a simulation state. Every other poke test in
  /// this suite assigns one itself, which is exactly the assignment the application was missing,
  /// so this is the assertion none of them could make.
  @Test("the app's own canvas has a simulation state")
  func theAppsOwnCanvasHasASimulationState() throws {
    let rig = try LiveRig()
    #expect(
      rig.canvas.circuitState != nil,
      """
      `CircuitEditorCanvas.circuitState` is nil in a canvas built by the real host. That is the \
      reported defect: `PokeTool` builds every `ComponentUserEvent` with `state: nil`, hands each \
      poker nothing, and clicking an input does nothing at all.
      """)
  }

  /// The engine reaches a live root state at all; the calibration for everything below. The
  /// state is built lazily inside the first `handleTick`, on the propagation thread, so a rig
  /// that never settles has nothing to read and every value assertion would be vacuously nil.
  @Test("the propagation thread builds a root state for the open circuit")
  func theEngineReachesALiveState() throws {
    let rig = try LiveRig()
    #expect(rig.settle(), "the propagation thread never completed a request")
    #expect(
      rig.value(at: 100, 100) != nil,
      "there is no live state behind the canvas, so nothing below is measuring a simulation")
  }

  /// **THE DEFECT, END TO END.** Poke the input pin; the value it drives must change, and the
  /// change must reach the far end of the wire.
  ///
  /// This was disabled for a day with the note *"the poke reaches intendedValue but
  /// `Pin.propagate`'s setPort never lands"*. **That diagnosis was wrong and the real cause was
  /// four layers lower**: `setPort` did land, `Propagator` queued the event and `stepInternal`
  /// drained it, and then `CircuitWires.propagate` discarded the value because the simulation's
  /// connectivity map had never been told these components existed. `SimulatedCircuit` loaded its
  /// wire map once in `init` and nothing kept it in step, so everything drawn after the document
  /// opened was invisible to it, which is every component in a circuit a student is building.
  /// See that file's header.
  ///
  /// The lesson worth keeping: the symptom was "a poke does nothing", and four of the five seams
  /// between the click and the wire were genuinely broken and genuinely had to be fixed, and
  /// fixing all four still changed nothing on screen. Only the fifth was load-bearing.
  @Test("poking an input pin changes the value it drives")

  func pokingAnInputPinDrivesTheWire() throws {
    let rig = try LiveRig()
    #expect(rig.settle())
    let before = rig.value(at: 100, 100)

    #expect(rig.poke(rig.input), "the poke tool did not resolve, or the Pin claims no point")
    #expect(rig.settle())
    let after = rig.value(at: 100, 100)

    #expect(
      after != before,
      """
      the input pin still reads \(String(describing: after)) after being poked. Either the poker \
      never ran (a nil `circuitState`) or its change never reached the propagation thread.
      """)
    #expect(
      rig.value(at: 200, 100) == after,
      """
      the poke changed the input to \(String(describing: after)) but the far end of the wire \
      reads \(String(describing: rig.value(at: 200, 100))). The value was set but never \
      propagated — `simulationDidChange` is what asks the propagation thread to settle again.
      """)
  }

  /// **The visible half.** A propagation that changes a value and nothing else must change what
  /// the canvas draws. If it does not, the simulation is running and invisible, which is the
  /// state the app shipped in.
  @Test("a poke changes what the canvas paints")
  func aPokeChangesTheScene() throws {
    let rig = try LiveRig()
    #expect(rig.settle())
    let before = sceneFingerprint(rig.surface.build.scene)

    #expect(rig.poke(rig.input), "the poke tool did not resolve, or the Pin claims no point")
    #expect(rig.settle())
    let after = sceneFingerprint(rig.surface.build.scene)

    #expect(
      after != before,
      """
      the scene is byte-identical before and after a poke that changed the circuit's values. \
      Either the paint context is still the unpowered `StaticPaintContext` — `showState: false`, \
      every port reading NIL — or the propagation never invalidated the geometry key.
      """)
  }

  /// The calibration for the test above, and it is not optional: a settle that changes *nothing*
  /// must leave the scene alone. Without this, "the scene changed" would also be satisfied by a
  /// canvas that rebuilds differently every frame, which would look identical here and be a
  /// rendering bug.
  @Test("settling without poking leaves the scene unchanged")
  func anIdleSettleDoesNotChangeTheScene() throws {
    let rig = try LiveRig()
    #expect(rig.settle())
    let first = sceneFingerprint(rig.surface.build.scene)
    #expect(rig.settle())
    #expect(
      sceneFingerprint(rig.surface.build.scene) == first,
      "the scene changed across a propagation that changed no values")
  }

  /// The unpowered path must still work: a surface with no simulation behind it is what every
  /// test rig and every offscreen export uses, and it must keep painting.
  @Test("a surface with no simulation still paints the unpowered schematic")
  func anUnsimulatedSurfaceStillPaints() throws {
    StdLibraries.registerAll()
    let circuit = try Circuit(name: "unpowered")
    try circuit.mutatorAdd(
      Pin.factory.createComponent(
        location: Location.create(100, 100, hasToSnap: false),
        attributes: Pin.factory.createAttributeSet()))

    let surface = CircuitCanvasSurface()
    surface.setCircuit(circuit)
    #expect(surface.simulationAccess == nil, "this rig was meant to have no simulation")
    #expect(
      surface.build.scene.primitives.count > 0,
      "a surface with no simulation drew nothing at all")
  }
}

// MARK: - Support

/// Everything about a scene that a value change can move, flattened to something comparable.
///
/// Not `primitives.count`: a lit LED and a dark one are the same number of primitives in
/// different colours, so a count is exactly the summary that cannot see what these tests are
/// about. The colour slot is the field that carries a wire's logic value.
@MainActor
private func sceneFingerprint(_ scene: RenderScene) -> String {
  scene.primitives
    .map { "\($0.kind.rawValue):\($0.color):\($0.a),\($0.b),\($0.c),\($0.d)" }
    .joined(separator: "|")
}
