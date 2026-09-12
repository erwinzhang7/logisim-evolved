// LogisimUITests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// N DRAGS OF ONE COMPONENT LEAVE EXACTLY ONE COMPONENT
//
// Reported from real use with two screenshots: dragging a single Pin around "a couple of times"
// left a copy behind on each drag, ending in eight identical unlabelled pins in a neat grid
// where the file had one. The copies persisted after mouse-up, so this was never the pixel smear
// that `CanvasOverlayRepaintTests` gates (commit 70f648747); that fix made the pixels a correct
// rendering of wrong *content*.
//
// The number that separated the two hypotheses; "the model really has eight pins" versus "the
// model has one and the scene accumulated"; is `circuit.nonWires.count`, measured after each of
// three consecutive drags of one Pin:
//
//                                 broken | fixed
//     after drag 1                     1 | 1
//     after drag 2                     2 | 1
//     after drag 3                     4 | 1
//
// It is the model, and the growth is **doubling**, not +1: three drags from one pin give four
// and a fourth gives eight, which is the screenshot exactly.
//
// Why doubling. `SelectionBase.translateHelper` deliberately leaves the *originals* in `selected`
// after adding their replacements; its own doc comment says so, and says the hand-off is
// completed by `Selection.transactionDone(circuit:result:)`, which reads the transaction's
// `ReplacementMap` and swaps old objects for new. Nothing in `Sources` ever called that method.
// So after drag 1 the selection held {stale original, live copy} while the circuit held one
// component; drag 2 translated both; `CircuitMutation.replace` on the stale original removed a
// component the circuit no longer had (a no-op) and added its translated copy (not a no-op), so
// the circuit gained one. Each drag doubles the selection, and with it the circuit.
//
// That also explains the second half of the report; "the preview is ass too, completely wrong
// places". The drag ghosts are drawn from `Selection.unionSet`, so from drag 2 onward the
// preview included stale components at coordinates that were one drag out of date. One cause,
// two symptoms; the preview assertions below fail on the broken code too.
//
// The gate is deliberately written against the CIRCUIT rather than against the selection: the
// selection is the bookkeeping that was wrong, and a test that asserted on it would have been
// satisfied by a fix that only tidied the bookkeeping.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import AppKit
import CoreGraphics
import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimRenderBackend
import LogisimStd
import Testing

@testable import LogisimUI

// MARK: - Harness

/// A project, its real render surface, and a `CircuitEditorCanvas` over both.
///
/// The same shape as `CanvasToolRoundTripTests.Rig` and for the same reason: the question is
/// whether the *application's* canvas drives the tool, so the project comes from
/// `LogisimFileProjectHostFactory` rather than from hand-assembled parts.
@MainActor
private struct DragRig {
  let host: LogisimFileProjectHost
  let project: Project
  let circuit: Circuit
  let surface: CircuitCanvasSurface
  let canvas: CircuitEditorCanvas
  let tool: SelectTool

  /// `keepConnections` is the `MOVE_KEEP_CONNECT` preference. Off by default here because the
  /// reroute engine runs on its own `ConnectorThread` and `commitMove` blocks on it; the
  /// duplication is independent of it, and `repeatedDragsWithReconnectAlsoLeaveOne` below turns
  /// it back on to prove that.
  init(keepConnections: Bool = false) throws {
    let made = try LogisimFileProjectHostFactory().makeEmptyProject()
    host = try #require(made as? LogisimFileProjectHost)
    project = host.project
    circuit = try #require(host.currentCircuitObject)
    surface = try #require(host.makeRenderSurface() as? CircuitCanvasSurface)
    tool = SelectTool()
    tool.keepsConnectionsWhenMoving = keepConnections
    canvas = CircuitEditorCanvas(
      project: project, surface: surface, circuit: circuit, initialTool: tool)
  }

  @discardableResult
  func add(_ factory: any ComponentFactory, at point: (Int, Int)) throws -> any Component {
    let component = try factory.createComponent(
      location: Location.create(point.0, point.1, hasToSnap: false),
      attributes: factory.createAttributeSet())
    try circuit.mutatorAdd(component)
    return component
  }

  /// Send a gesture the way `CanvasHostNSView` does.
  func pointer(
    _ phase: CanvasPointerEvent.Phase, _ x: Int, _ y: Int,
    modifiers: CanvasModifiers = [], clickCount: Int = 1
  ) {
    canvas.controller.canvasHandlePointer(
      CanvasPointerEvent(
        phase: phase,
        world: CGPoint(x: CGFloat(x), y: CGFloat(y)),
        modifiers: modifiers,
        clickCount: clickCount,
        buttonNumber: 1,
        dragOriginWorld: nil))
  }

  /// One complete press-drag-release of whatever sits at `from`, by (dx, dy).
  ///
  /// The press point is taken from the component's live `contains` geometry rather than from a
  /// computed centre: `SelectTool.mousePressed` branches on `circuit.allContaining(point)`, and a
  /// point the component rejects silently takes the *background* arm and starts a marquee, which
  /// would leave the circuit unchanged and make this suite pass for the wrong reason.
  func drag(_ component: any Component, by delta: (Int, Int)) throws {
    let point = try #require(interiorPoint(of: component))
    pointer(.down, point.x, point.y)
    pointer(.dragged, point.x + delta.0, point.y + delta.1)
    pointer(.up, point.x + delta.0, point.y + delta.1)
  }
}

/// A point the component actually reports as inside it.
@MainActor
private func interiorPoint(of component: any Component) -> Location? {
  let box = component.bounds
  guard box.width > 0, box.height > 0 else { return nil }
  for y in stride(from: box.y, through: box.y + box.height, by: 1) {
    for x in stride(from: box.x, through: box.x + box.width, by: 1) {
      let point = Location.create(x, y, hasToSnap: false)
      if component.contains(point) { return point }
    }
  }
  return nil
}

/// The single component of a given factory in the circuit, and a failure if there is not exactly
/// one, which is the whole point of this suite.
@MainActor
private func onlyComponent(
  of factory: any ComponentFactory, in circuit: Circuit
) throws -> any Component {
  let matches = circuit.nonWires.filter { $0.factory === factory }
  #expect(matches.count == 1)
  return try #require(matches.first)
}

// MARK: - The gate

@Suite("Drag duplication", .serialized)
struct DragDuplicationTests {

  // ── 1. The reported bug, at its reported cardinality ──────────────────────────────────────

  /// The report, reproduced: a Pin, dragged three times.
  ///
  /// Three is the smallest count that distinguishes the two failure shapes. One drag is green
  /// even on the broken code, the stale original is only *created* by the first commit, so a
  /// suite that dragged once would have found nothing, which is exactly why 1,480 tests did not.
  @Test("three drags of one Pin leave exactly one Pin, at the final position")
  @MainActor
  func threeDragsOfOnePinLeaveOnePin() throws {
    let rig = try DragRig()
    let pin = try rig.add(Pin.factory, at: (100, 100))
    let origin = pin.location
    #expect(rig.circuit.nonWires.count == 1)

    var current: any Component = pin
    var expected = origin
    // Deltas are multiples of the 10-unit grid so the snap in `computeDxDy` is the identity and
    // the expected position is exact rather than approximate.
    for delta in [(40, 30), (20, -10), (-30, 40)] {
      try rig.drag(current, by: delta)
      expected = Location.create(
        expected.x + delta.0, expected.y + delta.1, hasToSnap: false)

      // The measurement. Broken: 1, 2, 4. Fixed: 1, 1, 1.
      #expect(rig.circuit.nonWires.count == 1)
      current = try onlyComponent(of: Pin.factory, in: rig.circuit)
      #expect(current.location == expected)
    }

    #expect(rig.circuit.nonWires.count == 1)
    #expect(current.location == Location.create(130, 160, hasToSnap: false))
  }

  /// The screenshot's own number. Four drags is where the doubling reaches eight.
  @Test("four drags do not produce the eight pins from the screenshot")
  @MainActor
  func fourDragsDoNotProduceEight() throws {
    let rig = try DragRig()
    let pin = try rig.add(Pin.factory, at: (200, 200))

    var current: any Component = pin
    for _ in 0..<4 {
      try rig.drag(current, by: (20, 20))
      current = try onlyComponent(of: Pin.factory, in: rig.circuit)
    }

    // Broken: 8. This is the assertion that names the report.
    #expect(rig.circuit.nonWires.count == 1)
    #expect(current.location == Location.create(280, 280, hasToSnap: false))
  }

  /// Not a Pin-specific defect: the same three drags on an AndGate.
  @Test("three drags of a gate leave exactly one gate")
  @MainActor
  func threeDragsOfAGateLeaveOneGate() throws {
    let rig = try DragRig()
    let gate = try rig.add(AndGate.factory, at: (120, 100))

    var current: any Component = gate
    for _ in 0..<3 {
      try rig.drag(current, by: (30, 0))
      current = try onlyComponent(of: AndGate.factory, in: rig.circuit)
    }

    #expect(rig.circuit.nonWires.count == 1)
    #expect(current.location == Location.create(210, 100, hasToSnap: false))
  }

  /// With `MOVE_KEEP_CONNECT` on, which routes the commit through the reroute engine and a
  /// non-nil `ReplacementMap`. A fix that only handled the no-reroute path would fail here.
  @Test("three drags with MOVE_KEEP_CONNECT on also leave exactly one")
  @MainActor
  func repeatedDragsWithReconnectAlsoLeaveOne() throws {
    let rig = try DragRig(keepConnections: true)
    let pin = try rig.add(Pin.factory, at: (300, 300))

    var current: any Component = pin
    for _ in 0..<3 {
      try rig.drag(current, by: (20, 0))
      current = try onlyComponent(of: Pin.factory, in: rig.circuit)
    }

    #expect(rig.circuit.nonWires.count == 1)
    #expect(current.location == Location.create(360, 300, hasToSnap: false))
    // A left-behind "Computing…" strip is its own reported symptom; assert the reroute path
    // still cleans up while this test is here.
    #expect(rig.canvas.statusMessage == nil)
  }

  // ── 2. The selection is the mechanism, so state it directly ───────────────────────────────

  /// The bookkeeping assertion, kept separate from the cardinality ones above.
  ///
  /// `SelectionBase.translateHelper` leaves the originals in `selected` on purpose and documents
  /// that `Selection.transactionDone` completes the swap. This is the assertion that the swap
  /// happens at all: after one drag the selection must hold exactly the one component the
  /// circuit holds: the *new* object, not the stale original beside it.
  @Test("after a drag the selection holds exactly the component the circuit holds")
  @MainActor
  func selectionIsSwappedToTheReplacement() throws {
    let rig = try DragRig()
    let pin = try rig.add(Pin.factory, at: (100, 100))

    try rig.drag(pin, by: (40, 0))

    // Broken: 2: the stale original and its replacement.
    #expect(rig.canvas.selection.components.count == 1)
    let selected = try #require(rig.canvas.selection.components.first)
    let inCircuit = try onlyComponent(of: Pin.factory, in: rig.circuit)
    #expect(selected === inCircuit)
    // And the stale original is gone from the selection, not merely outnumbered.
    #expect(!rig.canvas.selection.components.contains { $0 === pin })
    // Anchored, not floating: the replacement is in the circuit, so `transactionDone` must have
    // put it in `selected` rather than `lifted`. Getting that branch wrong would leave a
    // component that the next `clear` tries to re-add.
    #expect(rig.canvas.selection.anchoredComponents.count == 1)
    #expect(rig.canvas.selection.floatingComponents.isEmpty)
  }

  /// The reported preview symptom, "completely wrong places", as an assertion.
  ///
  /// Mid-drag the ghosts come from `Selection.unionSet` shifted by the delta. On the broken code
  /// the second drag ghosts *two* components: the live one and a stale original one drag behind,
  /// which is a preview drawn at a position the pointer never visited.
  @Test("the drag preview ghosts one component, at the pointer's delta")
  @MainActor
  func previewGhostsExactlyOneComponent() throws {
    let rig = try DragRig()
    let pin = try rig.add(Pin.factory, at: (100, 100))

    // Drag once and release, so the selection has been through a commit.
    try rig.drag(pin, by: (40, 0))
    let moved = try onlyComponent(of: Pin.factory, in: rig.circuit)

    // Now press and drag again, and look at the preview *without* releasing.
    let point = try #require(interiorPoint(of: moved))
    rig.pointer(.down, point.x, point.y)
    rig.pointer(.dragged, point.x + 30, point.y + 20)

    let ghosts = rig.canvas.selection.ghostPlacementsShifted(dx: 30, dy: 20)
    // Broken: 2.
    #expect(ghosts.count == 1)
    let ghost = try #require(ghosts.first)
    #expect(ghost.x == moved.location.x + 30)
    #expect(ghost.y == moved.location.y + 20)

    rig.pointer(.up, point.x + 30, point.y + 20)
    #expect(rig.circuit.nonWires.count == 1)
  }

  // ── 3. The scene the canvas actually builds ───────────────────────────────────────────────

  /// The other half of the report: after the drag completes, the built scene must contain the
  /// component exactly once.
  ///
  /// This is asserted against a freshly built scene rather than against a repaint count, because
  /// the pixel-level defect next door (`CanvasOverlayRepaintTests`) is already fixed and this
  /// must not re-test it. What is asked here is what the scene *contains*.
  @Test("after three drags the built scene contains the component exactly once")
  @MainActor
  func sceneContainsTheComponentOnce() throws {
    let rig = try DragRig()
    let pin = try rig.add(Pin.factory, at: (100, 100))

    var current: any Component = pin
    for _ in 0..<3 {
      try rig.drag(current, by: (20, 10))
      current = try onlyComponent(of: Pin.factory, in: rig.circuit)
    }

    // `CircuitSceneBuild.components` is what the scene was built from, in paint order, and
    // `indexByID` is how a hit maps back to one. Both are the surface's own tables, not the
    // circuit re-read: the hypothesis this rules out is a scene that accumulated independently of
    // the model.
    let build = rig.surface.build
    #expect(build.components.count == 1)
    let identity = CircuitSceneSource.identity(of: current)
    #expect(build.indexByID[identity] != nil)
    #expect(build.components.filter { $0.factory === Pin.factory }.count == 1)
    // The gesture is over, so nothing is hidden and the one component is drawn.
    #expect(build.paintedComponentCount == 1)
  }

  // ── 4. Undo still walks back the way it came ──────────────────────────────────────────────

  /// Three drags push three actions; three undos must land back on the original position with
  /// one component throughout. A fix that removed the stale original by mutating the circuit
  /// outside the transaction would pass the cardinality tests and fail here.
  @Test("three drags undo to the original position, one component at every step")
  @MainActor
  func dragsUndoCleanly() throws {
    let rig = try DragRig()
    let pin = try rig.add(Pin.factory, at: (100, 100))
    let origin = pin.location

    var current: any Component = pin
    for _ in 0..<3 {
      try rig.drag(current, by: (20, 0))
      current = try onlyComponent(of: Pin.factory, in: rig.circuit)
    }
    #expect(current.location == Location.create(160, 100, hasToSnap: false))

    for expected in [140, 120, 100] {
      #expect(rig.project.canUndo)
      try rig.project.undoAction()
      #expect(rig.circuit.nonWires.count == 1)
      let restored = try onlyComponent(of: Pin.factory, in: rig.circuit)
      #expect(restored.location == Location.create(expected, 100, hasToSnap: false))
    }
    #expect(try onlyComponent(of: Pin.factory, in: rig.circuit).location == origin)
  }

  // ── 5. The same staleness, reached through undo instead of through a second drag ──────────

  /// Undo does not go through `SelectTool.commitMove`, so the fix there cannot reach it: the
  /// reverse transaction replaces the moved component with the original and the selection is
  /// still holding the moved one.
  ///
  /// Upstream's answer is the *other* half of `Selection.MyListener`: `projectChanged`'s
  /// `UNDO_COMPLETE` arm, which replays the snapshot taken at `ACTION_START`. That half is
  /// implemented in `Selection.projectChanged` and was likewise never reached, because nothing
  /// registered the selection as a `ProjectListener`. 4.1.0's `Selection(Project, Canvas)`
  /// constructor registers `myListener` as both a `ProjectListener` and a `CircuitListener`
  /// (`javap -c com.cburch.logisim.gui.main.Selection`, offsets 40 and 48).
  ///
  /// The user-visible failure this guards is not hypothetical: after an undo the selection holds
  /// a component the circuit does not, drawn nowhere, so a press on that empty patch of canvas
  /// takes `mousePressed`'s branch 1 (`selection.componentsContaining` is non-empty) and drags
  /// a ghost, which commits as an add.
  @Test("a press on where an undone component used to be does not conjure a copy")
  @MainActor
  func draggingAfterUndoDoesNotConjureACopy() throws {
    let rig = try DragRig()
    let pin = try rig.add(Pin.factory, at: (100, 100))

    try rig.drag(pin, by: (60, 0))
    let moved = try onlyComponent(of: Pin.factory, in: rig.circuit)
    let staleSpot = try #require(interiorPoint(of: moved))

    try rig.project.undoAction()
    #expect(rig.circuit.nonWires.count == 1)
    #expect(try onlyComponent(of: Pin.factory, in: rig.circuit).location == pin.location)

    // Nothing is drawn at `staleSpot` any more; the circuit has nothing there.
    #expect(rig.circuit.allContaining(staleSpot).isEmpty)
    // So the selection must have nothing there either, or the next press drags a phantom.
    #expect(rig.canvas.selection.componentsContaining(staleSpot).isEmpty)

    rig.pointer(.down, staleSpot.x, staleSpot.y)
    rig.pointer(.dragged, staleSpot.x + 40, staleSpot.y + 40)
    rig.pointer(.up, staleSpot.x + 40, staleSpot.y + 40)

    #expect(rig.circuit.nonWires.count == 1)
  }

  /// The undo snapshot itself: after undoing a move, the selection holds the component the undo
  /// put back, not the one it took away.
  @Test("undo restores the selection to what it was before the move")
  @MainActor
  func undoRestoresTheSelection() throws {
    let rig = try DragRig()
    let pin = try rig.add(Pin.factory, at: (100, 100))

    try rig.drag(pin, by: (60, 0))
    try rig.project.undoAction()

    let inCircuit = try onlyComponent(of: Pin.factory, in: rig.circuit)
    #expect(rig.canvas.selection.components.count == 1)
    #expect(rig.canvas.selection.components.first === inCircuit)
    #expect(rig.canvas.selection.floatingComponents.isEmpty)
  }
}
