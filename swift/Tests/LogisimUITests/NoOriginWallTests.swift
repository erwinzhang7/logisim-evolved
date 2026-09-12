// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution, which is GPL-3.0-only. This port is a derivative work and is
// therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE ORIGIN IS NOT A WALL.
//
// ── Where this came from ────────────────────────────────────────────────────────────────────
//
// Reported from real use, dragging a Pin upward with the pointer readout showing (78, −108) and
// the component refusing to follow: "there seems to be invisible limits to canvas size. this is
// the highest it will go but clearly tons of canvas left … kinda be unlimited canvas size."
//
// It was not a canvas size. It was `SelectTool.computeDxDy`'s `Math.max(dy, -bds.getY())`, which
// is upstream's own line and limits the drag delta so the selection's bounding box cannot cross
// the origin. Upstream needs it; its canvas is a `JScrollPane` over a component whose preferred
// size is the circuit bounds times the zoom, so there is genuinely nothing above the origin to
// scroll to (issue #1262). This port's camera is `(center, zoom)` and unbounded, so the quadrant
// the wall protected does not exist here.
//
// ── FOUR GUARDS, NOT ONE, AND REMOVING THEM REDDENED NOTHING ────────────────────────────────
//
// The same rule was enforced in four places: the drag clamp, `AddTool`'s placement refusal,
// `TextTool`'s label refusal, and `SelectionBase.copyComponents`' offset search. Deleting all
// four left the suite at 1,676 passing; **none of them was gated by anything**, which is the
// reason this file exists. A rule that four files enforce and no test watches is a rule that can
// be half-removed by a later edit with no signal at all.
//
// The copy search is the dangerous one and is pinned hardest below. Its comment calls it
// "byte-exact territory": the (10, 10) a duplicate appears at is *emergent* from a ring search,
// not a constant, and it had no test whatsoever. The relaxation there is `min(bds.x, 0)` rather
// than a deletion precisely so it is provably a no-op for every circuit upstream can produce,
// and `duplicateStillLandsAtTenTen` is what proves it.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import AppKit
import CoreGraphics
import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd
import Testing

@testable import LogisimUI

// MARK: - Harness

/// A project with one AND gate, a select tool and a canvas wired together; the smallest rig that
/// can actually be dragged.
@MainActor
private struct DragRig {
  let host: LogisimFileProjectHost
  let project: Project
  let circuit: Circuit
  let canvas: CircuitEditorCanvas
  let select: SelectTool
  let gate: any Component

  init(at origin: Location = Location.create(200, 200, hasToSnap: false)) throws {
    StdLibraries.registerAll()
    host = try #require(
      try LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
    project = host.project
    circuit = try #require(host.currentCircuitObject)
    let surface = try #require(host.makeRenderSurface() as? CircuitCanvasSurface)

    let component = try AndGate.factory.createComponent(
      location: origin, attributes: AndGate.factory.createAttributeSet())
    try circuit.mutatorAdd(component)
    gate = component

    select = SelectTool()
    // Off, so the move engine's connector thread never enters the picture: this file is about
    // where a component ends up, not about wire rerouting, and a background reroute would make
    // the assertions time-dependent.
    select.keepsConnectionsWhenMoving = false
    canvas = CircuitEditorCanvas(
      project: project, surface: surface, circuit: circuit, initialTool: select)
    surface.renderView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    surface.setViewport(
      CanvasViewport(
        zoom: 1, center: CGPoint(x: 200, y: 200), viewSize: CGSize(width: 800, height: 600)))
  }

  func pointer(_ phase: CanvasPointerEvent.Phase, _ x: Int, _ y: Int) {
    canvas.controller.canvasHandlePointer(
      CanvasPointerEvent(
        phase: phase,
        world: CGPoint(x: CGFloat(x), y: CGFloat(y)),
        modifiers: [],
        clickCount: 1,
        buttonNumber: 1,
        dragOriginWorld: nil))
  }

  /// A point the gate reports as inside itself. `mousePressed` branches on
  /// `Circuit.allContaining`, and a point the gate rejects starts a marquee instead of a move.
  var grabPoint: Location {
    let box = gate.bounds
    return Location.create(box.x + box.width / 2, box.y + box.height / 2, hasToSnap: false)
  }

  /// Press, drag and release, in world units. Returns where the gate ended up.
  func drag(by dx: Int, dy: Int) -> Location {
    let grab = grabPoint
    pointer(.down, grab.x, grab.y)
    pointer(.dragged, grab.x + dx, grab.y + dy)
    pointer(.up, grab.x + dx, grab.y + dy)
    return try! #require(circuit.nonWires.first).location
  }
}

// MARK: - The reported defect

@Suite("The origin is not a wall")
@MainActor
struct NoOriginWallTests {

  /// **THE DEFECT.** A gate near the origin, dragged far above and left of it, must arrive.
  @Test("a selection drags above and left of the origin")
  func aSelectionDragsPastTheOrigin() throws {
    let rig = try DragRig(at: Location.create(60, 60, hasToSnap: false))
    let start = rig.gate.location
    let landed = rig.drag(by: -200, dy: -160)

    #expect(
      landed == Location.create(start.x - 200, start.y - 160, hasToSnap: false),
      """
      the gate travelled to \(landed) instead of \
      \(Location.create(start.x - 200, start.y - 160, hasToSnap: false)). Landing short, with \
      its bounding box stopped flush against x = 0 or y = 0, is the reported defect: \
      `computeDxDy` clamping the delta to `max(delta, -bounds.origin)` so the drag stops while \
      the pointer keeps going.
      """)
    #expect(
      rig.circuit.bounds.x < 0 && rig.circuit.bounds.y < 0,
      "the circuit's bounds are \(rig.circuit.bounds), still inside the positive quadrant")
  }

  /// The calibration: an ordinary drag that never approaches the origin must be unaffected, or
  /// the test above could be passing against a `computeDxDy` that has stopped computing at all.
  @Test("an ordinary drag away from the origin is unchanged")
  func anOrdinaryDragIsUnchanged() throws {
    let rig = try DragRig()
    let start = rig.gate.location
    let landed = rig.drag(by: 50, dy: 30)
    #expect(landed == Location.create(start.x + 50, start.y + 30, hasToSnap: false))
  }

  /// The delta is still snapped to the grid, and snapping is applied to the DELTA, not the
  /// pointer, which is the half of `computeDxDy` that was never the problem and must survive the
  /// half that was.
  @Test("a drag past the origin still snaps to the grid")
  func snappingSurvivesOnTheNegativeSide() throws {
    let rig = try DragRig(at: Location.create(60, 60, hasToSnap: false))
    let landed = rig.drag(by: -203, dy: -156)
    // −203 snaps to −200, −156 snaps to −160: `CanvasGrid.snapXToGrid`'s negative branch.
    #expect(
      landed == Location.create(-140, -100, hasToSnap: false),
      "the gate landed at \(landed); the delta was not snapped on the negative side")
  }

  /// `AddTool`'s refusal. Dragging a gate above the origin but being unable to *place* one there
  /// would be worse than either choice on its own.
  @Test("a component can be placed above the origin")
  func componentsCanBePlacedAboveTheOrigin() throws {
    StdLibraries.registerAll()
    let host = try #require(
      try LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
    let circuit = try #require(host.currentCircuitObject)
    let surface = try #require(host.makeRenderSurface() as? CircuitCanvasSurface)
    let add = CanvasAddTool.canvasTool(for: AddTool(factory: AndGate.factory))
    let canvas = CircuitEditorCanvas(
      project: host.project, surface: surface, circuit: circuit, initialTool: add)

    canvas.controller.canvasHandlePointer(
      CanvasPointerEvent(
        phase: .down, world: CGPoint(x: -200, y: -140), modifiers: [], clickCount: 1,
        buttonNumber: 1, dragOriginWorld: nil))
    canvas.controller.canvasHandlePointer(
      CanvasPointerEvent(
        phase: .up, world: CGPoint(x: -200, y: -140), modifiers: [], clickCount: 1,
        buttonNumber: 1, dragOriginWorld: nil))

    let placed = try #require(
      circuit.nonWires.first,
      """
      nothing was placed at (−200, −140). That is `AddTool`'s `bds.getX() < 0` refusal, which \
      has to go with the drag clamp or the two contradict each other.
      """)
    #expect(placed.location == Location.create(-200, -140, hasToSnap: false))
    #expect(
      canvas.statusMessage == nil,
      "the placement raised \(String(describing: canvas.statusMessage)) instead of succeeding")
  }

  /// `TextTool`'s refusal, the third of the four. Its own comment justified the guard by saying a
  /// label above the origin would be "off the top-left of the sheet, where nothing can ever
  /// select it again"; true of a sheet that starts at the origin, not of a camera that can be
  /// panned there.
  ///
  /// Asserted through the *caret*, not the circuit: `createTextComponent` returns an `Adoption`
  /// and the component is only committed once text is typed, so a click alone adds nothing to
  /// the circuit either way. An open caret is what the guard used to prevent.
  @Test("the text tool opens a caret above the origin")
  func textCanBePlacedAboveTheOrigin() throws {
    StdLibraries.registerAll()
    let host = try #require(
      try LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
    let circuit = try #require(host.currentCircuitObject)
    let surface = try #require(host.makeRenderSurface() as? CircuitCanvasSurface)
    let canvas = CircuitEditorCanvas(
      project: host.project, surface: surface, circuit: circuit, initialTool: SelectTool())
    #expect(
      canvas.controller.setActiveTool(
        fromLibrary: BuiltinPlaceholderTool(id: BaseToolIds.textTool)),
      "the controller does not resolve the Text tool, so this test drives nothing")

    func click(_ x: Int, _ y: Int) {
      for phase in [CanvasPointerEvent.Phase.down, .up] {
        canvas.controller.canvasHandlePointer(
          CanvasPointerEvent(
            phase: phase, world: CGPoint(x: CGFloat(x), y: CGFloat(y)), modifiers: [],
            clickCount: 1, buttonNumber: 1, dragOriginWorld: nil))
      }
    }
    func caretIsOpen() -> Bool {
      let overlay = canvas.controller.activeTool.overlay(for: canvas)
      return !overlay.items.isEmpty || !(overlay.scene?.primitives.isEmpty ?? true)
    }

    // The calibration first: a click in the positive quadrant opens a caret, so a "no" above the
    // origin is about the coordinate and not about the tool being inert.
    click(200, 200)
    #expect(caretIsOpen(), "the Text tool opens no caret anywhere; this test gates nothing")

    click(-200, -140)
    #expect(
      caretIsOpen(),
      """
      clicking above the origin opened no caret — `createTextComponent`'s \
      `guard point.x >= 0, point.y >= 0` is back, and a label cannot be written where a \
      component can now be dragged.
      """)
  }

  // MARK: - The copy search, which is byte-exact territory

  /// **THE PIN THAT MATTERS.** The offset a duplicate appears at is emergent from a ring search,
  /// not a constant: index 0 is (0, 0) and always self-collides, so the search advances to index
  /// 1, which is (10, 10). Relaxing the search's floor must not move it.
  ///
  /// This had no test at all before the floor was touched. The floor is `min(bds.x, 0)` rather
  /// than a deletion exactly so this stays true: for a group in the non-negative quadrant that
  /// expression IS `0`, so the condition is character for character upstream's.
  @Test("duplicating a gate still offsets it by exactly (10, 10)")
  func duplicateStillLandsAtTenTen() throws {
    let rig = try DragRig()
    let original = rig.gate.location
    let copies = try rig.canvas.selection.copyComponents([rig.gate], translate: false)
    let copy = try #require(copies.first)
    #expect(
      copy.copy.location == Location.create(original.x + 10, original.y + 10, hasToSnap: false),
      """
      a duplicate landed at \(copy.copy.location) rather than 10 units down and right of \
      \(original). That offset is not a constant anywhere in the code — it is where the ring \
      search first finds a non-colliding slot — so a change here means the search order moved.
      """)
  }

  /// The other emergent offset: a copy into empty space takes index 0 and lands exactly where it
  /// came from. Both are needed; a search that always returned (10, 10) would pass the test
  /// above and be wrong.
  @Test("a copy with no collision lands exactly where it was copied from")
  func aNonCollidingCopyDoesNotMove() throws {
    let rig = try DragRig()
    let far = try AndGate.factory.createComponent(
      location: Location.create(600, 600, hasToSnap: false),
      attributes: AndGate.factory.createAttributeSet())
    // Not added to the circuit, so nothing can collide with it.
    let copies = try rig.canvas.selection.copyComponents([far], translate: false)
    #expect(try #require(copies.first).copy.location == far.location)
  }

  /// And the case the relaxation is FOR: a group already above the origin must not be dragged
  /// back to it. With upstream's literal `0` the search walks outward until the group is pushed
  /// into the positive quadrant, landing the copy nowhere near its original.
  @Test("copying a group that is above the origin keeps it there")
  func aCopyAboveTheOriginStaysAboveIt() throws {
    let rig = try DragRig()
    let high = try AndGate.factory.createComponent(
      location: Location.create(-400, -300, hasToSnap: false),
      attributes: AndGate.factory.createAttributeSet())
    let copies = try rig.canvas.selection.copyComponents([high], translate: false)
    let copy = try #require(copies.first)
    #expect(
      copy.copy.location == high.location,
      """
      the copy landed at \(copy.copy.location) instead of at \(high.location). A floor pinned to \
      the origin does not refuse this copy, it DRAGS it — the ring search keeps stepping until \
      the group clears x = 0, so a paste appears hundreds of units from the thing it copied.
      """)
  }
}
