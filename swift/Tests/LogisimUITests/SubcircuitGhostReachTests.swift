// SubcircuitGhostReachTests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// CAN THE DRAG GESTURE REACH THE SUBCIRCUIT GHOST?
//
// `docs/experiments/subcircuit-paint.md` §6.3 closed the painter and left the path to it open:
// `CircuitSubcircuitFactory.paintGhost` was written and tested, and `ToolOverlayScene` guarded
// both of its ghost entry points on `factory as? any InstanceFactory` before it would call
// anything. A subcircuit descends from `AbstractComponentFactory` in `LogisimFile`, so the cast
// failed and every subcircuit drag, from the explorer and across the canvas, fell back to
// `strokeOffsetBounds`: one `drawRect`, four sides, no symbol, no ports, no name.
//
// Measured through the real canvas, before and after the guards were widened, dragging a
// two-in/one-out subcircuit named "inner" from the file's own `AddTool`:
//
//                                              fallback | painted
//     placement ghost, overlay primitives             1 | 9
//     ghostsPainted / ghostsFellBackToBounds        0/1 | 1/0
//     strings drawn in the ghost                      0 | 4   ("inner", "a", "b", "y")
//     move ghost, overlay primitives                  1 | 9
//
// The nine are the outer box, the name plate, one stub and one label per port, and the circuit's
// name. The same subcircuit *placed* draws twelve: the ghost is the instance less exactly one
// port marker per port, because `SubcircuitFactory.paintInstance` is `paintBase` + `drawPorts`
// while `paintGhost` is `paintBase` alone. That relation is asserted, not the literal 9 alone.
//
// So this suite asserts on PRIMITIVE COUNTS and on COORDINATES out of `SceneBuilder`, never on
// "a ghost exists". The gestures are real `CanvasPointerEvent`s through
// `CanvasInteractionHandler.canvasHandlePointer`, the same entry point `CanvasHostNSView` uses,
// as `CanvasToolRoundTripTests` established.
//
// THE COORDINATE ASSERTION IS THE LOAD-BEARING ONE. `InstanceFactory.drawGhost` translates by
// the ghost's location *before* calling `paintGhost`, and this port's `InstancePainter.location`
// returns the ghost's real location where Java's returns `(0, 0)` for a ghost
// (`InstancePainter.java:169-171`). `SubcircuitPainter.paintBase` reproduces Java's reading
// explicitly to compensate. That compensation could only ever be checked by eye until this path
// existed; `ghostLandsUnderTheCursorNotTwiceTheOffset` now pins it to a measured primitive
// coordinate; remove the compensation and every primitive moves one full component away.
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

// MARK: - Harness

/// A real project, a real render surface, a real `CircuitEditorCanvas`, and a second circuit in
/// the same file so the subcircuit `AddTool` is the one the explorer would hand over.
@MainActor
private struct GhostRig {
  let host: LogisimFileProjectHost
  let project: Project
  let parent: Circuit
  let inner: Circuit
  let surface: CircuitCanvasSurface
  let canvas: CircuitEditorCanvas

  /// `inner` has two inputs and one output, so its default evolution box carries three port
  /// stubs and four pieces of text; the name plus one label per pin. Both are things a bare
  /// fallback rectangle cannot produce.
  ///
  /// **`keepsConnectionsWhenMoving` defaults to `false` here, and that is not tidiness.** With it
  /// on, the application's default, `SelectTool.handleMoveDrag` starts a `MoveGesture`, and
  /// `AvoidanceMap.markComponent` then calls `component.bounds` on the connector thread. For a
  /// subcircuit that reaches `CircuitSubcircuitFactory.offsetBounds`, which reads its `unowned`
  /// live `Circuit`: violating `ConnectorThread`'s own stated contract ("nothing below this line
  /// ever touches a live `Circuit`") and aborting the process outright once that circuit is
  /// released. Backtrace and analysis are in the handback; it is a defect in the move engine,
  /// independent of the ghost, and a suite whose green depends on losing a race is not a gate.
  /// The ghost is drawn either way, `drawConnections` gates the proposed *wires*, not the
  /// ghost, so nothing under test is skipped. `connections: true` is available for anyone
  /// reproducing the crash.
  init(tool: (any CanvasTool)? = nil, connections: Bool = false) throws {
    StdLibraries.registerAll()
    let made = try LogisimFileProjectHostFactory().makeEmptyProject()
    host = try #require(made as? LogisimFileProjectHost)
    project = host.project
    parent = try #require(host.currentCircuitObject)

    inner = try Circuit(name: "inner", defaultAppearance: CircuitAttributes.appearEvolution)
    try inner.staticAttributes.setValue(
      CircuitAttributes.appearance, CircuitAttributes.appearEvolution)
    try GhostRig.addPin(to: inner, label: "a", type: Pin.input, at: (100, 100))
    try GhostRig.addPin(to: inner, label: "b", type: Pin.input, at: (100, 140))
    try GhostRig.addPin(to: inner, label: "y", type: Pin.output, at: (300, 100))
    project.logisimFile.addCircuit(inner)

    surface = try #require(host.makeRenderSurface() as? CircuitCanvasSurface)
    let select = SelectTool()
    select.keepsConnectionsWhenMoving = connections
    canvas = CircuitEditorCanvas(
      project: project, surface: surface, circuit: parent, initialTool: tool ?? select)
  }

  private static func addPin(
    to circuit: Circuit, label: String, type: AttributeOption, at point: (Int, Int)
  ) throws {
    let attributes = Pin.factory.createAttributeSet()
    try attributes.setValue(Pin.attrType, type)
    try attributes.setValue(StdAttr.label, label)
    try circuit.mutatorAdd(
      Pin.factory.createComponent(
        location: Location.create(point.0, point.1, hasToSnap: true), attributes: attributes))
  }

  /// The `AddTool` the file itself built for `inner`, `LogisimFile.getAddTool(Circuit)`, lifted
  /// to its canvas form exactly as `CanvasToolController` does when the explorer selects it.
  var subcircuitAddTool: CanvasAddTool {
    get throws {
      let tool = try #require(project.logisimFile.addTool(for: inner))
      return CanvasAddTool.canvasTool(for: tool)
    }
  }

  var subcircuitFactory: CircuitSubcircuitFactory {
    // `Circuit.subcircuitFactory` is typed `any SubcircuitFactory`; the concrete type is the one
    // the ghost path has to satisfy, so the downcast is the point rather than a convenience.
    inner.subcircuitFactory as! CircuitSubcircuitFactory
  }

  @discardableResult
  func place(at point: (Int, Int)) throws -> any Component {
    let factory = subcircuitFactory
    let component = try factory.createComponent(
      location: Location.create(point.0, point.1, hasToSnap: true),
      attributes: factory.createAttributeSet())
    try parent.mutatorAdd(component)
    return component
  }

  func setTool(_ tool: any CanvasTool) {
    canvas.controller.setActiveTool(tool)
  }

  func pointer(
    _ phase: CanvasPointerEvent.Phase, _ x: Int, _ y: Int,
    modifiers: CanvasModifiers = [], dragOrigin: (Int, Int)? = nil
  ) {
    canvas.controller.canvasHandlePointer(
      CanvasPointerEvent(
        phase: phase,
        world: CGPoint(x: CGFloat(x), y: CGFloat(y)),
        modifiers: modifiers,
        clickCount: 1,
        buttonNumber: 1,
        dragOriginWorld: dragOrigin.map { CGPoint(x: CGFloat($0.0), y: CGFloat($0.1)) }))
  }
}

/// A point the placement actually reports as inside it; the same guard
/// `CanvasToolRoundTripTests` uses, because `SelectTool.mousePressed` branches on
/// `circuit.allContaining(point)` and a point the component rejects starts a marquee instead.
@MainActor
private func interior(of component: any Component) -> Location? {
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

private func strings(_ scene: RenderScene) -> [String] { scene.texts.map(\.string) }

// MARK: - The gate

@Suite("Subcircuit ghost — the drag reaches it", .serialized)
struct SubcircuitGhostReachTests {

  // ── 1. Placing from the explorer ──────────────────────────────────────────────────────────

  /// The measurement §6.3 pinned in the negative. Was 1 primitive, a fallback rectangle.
  @Test("dragging a subcircuit placement previews the symbol, not an empty rectangle")
  @MainActor
  func placementGhostPaintsTheSubcircuit() throws {
    let rig = try GhostRig()
    rig.setTool(try rig.subcircuitAddTool)
    rig.pointer(.moved, 300, 300)

    let result = rig.canvas.overlayResult
    #expect(
      result.ghostsPainted == 1,
      "the ghost fell back: painted \(result.ghostsPainted), fell back \(result.ghostsFellBackToBounds)")
    #expect(result.ghostsFellBackToBounds == 0)

    // Nine, itemised, because "more than one" would also pass against a painter that drew half
    // the symbol: the outer box, the inner name plate, one stub and one label per port, and the
    // circuit's name. `strokeOffsetBounds` emits exactly ONE, which is what this used to be.
    #expect(
      result.primitiveCount == 9,
      "overlay drew \(result.primitiveCount) primitives, expected 9 — a bare box is 1")

    // The same subcircuit, placed rather than dragged, through `CircuitRenderer`. The ghost is
    // the instance MINUS exactly one port MARKER per port, and that difference is upstream's:
    // `SubcircuitFactory.paintInstance` is `paintBase` + `drawPorts`, `paintGhost` is `paintBase`
    // alone (`SubcircuitFactory.java:364-385`). Asserted as a relation so it survives any change
    // to the default box's shape, which the two literals above would not.
    //
    // The difference is counted in MARKERS, not in primitives, and that distinction is not
    // pedantry: it used to be spelled `== 3` on the assumption that a marker is one primitive,
    // and it broke when `SceneBuilder.drawPinMarker` became a ring (a knocked-out hole plus a
    // stroked rim). What the test is actually claiming, the ghost is the instance less its port
    // markers, never changed, so it is now asked in a way a restyle cannot move. `role` is the
    // emitter's own answer to "is this a marker"; see `ScenePrimitive.Role`.
    try rig.place(at: (600, 600))
    let placed = CircuitSceneSource.build(circuit: rig.parent, appearance: CanvasAppearance())
    let markersOnTheInstance = placed.scene.primitives.filter { $0.role == .connectionMarker }
    let markersOnTheGhost = result.itemScene.primitives.filter { $0.role == .connectionMarker }
    #expect(markersOnTheGhost.isEmpty, "the ghost drew port markers; `paintGhost` gained a `drawPorts`")
    #expect(
      markersOnTheInstance.count == 3 * 2,
      "inner has 3 ports and a marker is a hole plus a rim; got \(markersOnTheInstance.count)")
    #expect(
      placed.scene.primitives.count - result.primitiveCount == markersOnTheInstance.count,
      """
      instance \(placed.scene.primitives.count) vs ghost \(result.primitiveCount): the ghost is \
      the instance less its \(markersOnTheInstance.count) port-marker primitives
      """)
  }

  /// **Does the ghost carry its PORTS?** A box with no stubs previews as a plain rectangle and
  /// tells the user nothing about where the thing will connect.
  ///
  /// Upstream's `SubcircuitFactory.paintGhost` does NOT call `painter.drawPorts()`, only
  /// `paintInstance` does, so the stubs must come from the appearance's own shapes. That is
  /// exactly what makes this worth measuring rather than assuming: the ports are present for a
  /// different reason than the one you would guess, and a painter that skipped the appearance
  /// shapes would still "draw a ghost".
  @Test("the placement ghost carries the port stubs and every pin label")
  @MainActor
  func placementGhostCarriesItsPorts() throws {
    let rig = try GhostRig()
    rig.setTool(try rig.subcircuitAddTool)
    rig.pointer(.moved, 300, 300)

    let scene = rig.canvas.overlayResult.itemScene
    let drawn = strings(scene)
    #expect(drawn.contains("inner"), "the circuit's name is missing: \(drawn)")
    for label in ["a", "b", "y"] {
      #expect(drawn.contains(label), "port label \(label) missing from the ghost: \(drawn)")
    }

    // The labels alone would pass against a ghost that drew three names and no stubs, so the
    // stubs are located too. `inner`'s two inputs face west and its output east, so the stub
    // geometry has to straddle the box: three shapes outside the plate, two on one side and one
    // on the other. A box with no ports has none.
    let plate = Bounds.create(300 - 210, 300 - 10, 200, 60)
    let stubs = scene.primitives.filter {
      Int($0.bounds.minX) < plate.x || Int($0.bounds.maxX) > plate.x + plate.width
    }
    #expect(stubs.count >= 3, "\(stubs.count) shapes reach outside the plate; inner has 3 ports")
    #expect(
      stubs.contains { Int($0.bounds.minX) < plate.x },
      "nothing sticks out to the west — the two input stubs are missing")
    #expect(
      stubs.contains { Int($0.bounds.maxX) > plate.x + plate.width },
      "nothing sticks out to the east — the output stub is missing")
  }

  /// The offset proof. `paintBase` compensates for `InstanceFactory.drawGhost`'s outer translate
  /// by reproducing Java's `getLocation() == (0, 0)` for a ghost; without that compensation every
  /// primitive lands at `2 * location + offset` instead of `location + offset`.
  ///
  /// Asserted against the factory's OWN `offsetBounds` rather than against literals, so the test
  /// stays honest if the default box's geometry is ever revised; the claim is "the ghost is in
  /// the frame the component would occupy", which is the claim that matters.
  @Test("the ghost lands under the cursor, not a full component away")
  @MainActor
  func ghostLandsUnderTheCursorNotTwiceTheOffset() throws {
    let rig = try GhostRig()
    let factory = rig.subcircuitFactory
    let offset = factory.offsetBounds(factory.createAttributeSet())

    let cursor = (x: 300, y: 300)
    rig.setTool(try rig.subcircuitAddTool)
    rig.pointer(.moved, cursor.x, cursor.y)

    let scene = rig.canvas.overlayResult.itemScene
    // Guarding the guard: a fallback rectangle sits in exactly this frame too, so without this
    // the whole test passes against the unfixed path and proves nothing.
    #expect(
      scene.primitives.count == 9,
      "\(scene.primitives.count) primitives — this is the fallback box, not the symbol")

    let minX = scene.primitives.map { Int($0.bounds.minX) }.min() ?? 0
    let maxX = scene.primitives.map { Int($0.bounds.maxX) }.max() ?? 0
    let minY = scene.primitives.map { Int($0.bounds.minY) }.min() ?? 0
    let maxY = scene.primitives.map { Int($0.bounds.maxY) }.max() ?? 0

    // `offsetBounds` is (-220,-10) 220x60 for this circuit, so at a cursor of (300,300) the
    // component's frame is x 80...300. The port stubs reach both edges exactly, which is why the
    // x span can be asserted to the pixel: it IS the offset frame, measured, not approximated.
    #expect(
      minX == cursor.x + offset.x && maxX == cursor.x + offset.x + offset.width,
      "ghost spans x \(minX)...\(maxX), the component's frame is \(cursor.x + offset.x)...\(cursor.x + offset.x + offset.width)"
    )
    // y carries the stroke's overhang on the outer box, so it is bounded rather than exact.
    let expectedY = Bounds.create(
      cursor.x + offset.x, cursor.y + offset.y, offset.width, offset.height
    ).expand(4)
    #expect(
      minY >= expectedY.y && maxY <= expectedY.y + expectedY.height,
      "ghost spans y \(minY)...\(maxY), expected inside \(expectedY.y)...\(expectedY.y + expectedY.height)"
    )

    // The specific failure a lost compensation produces: everything shifted by one whole
    // location, to x 300...520. Stated separately so the diagnosis is in the message rather than
    // inferred from a range, because this is the assertion that stands in for the reasoning
    // `docs/experiments/subcircuit-paint.md` §6.3 had to do blind.
    #expect(
      minX < cursor.x,
      "the ghost starts at or past the cursor — that is `paintBase` translating a second time")
  }

  // ── 2. Moving one already on the canvas ───────────────────────────────────────────────────

  /// `Selection.drawGhostsShifted`: the other of the two guards §6.3 named.
  @Test("dragging a placed subcircuit previews the symbol at the shifted position")
  @MainActor
  func moveGhostPaintsTheSubcircuit() throws {
    let rig = try GhostRig()
    let placement = try rig.place(at: (300, 300))
    let grab = try #require(interior(of: placement))

    rig.pointer(.down, grab.x, grab.y)
    rig.pointer(.dragged, grab.x + 60, grab.y + 40, dragOrigin: (grab.x, grab.y))

    let result = rig.canvas.overlayResult
    #expect(
      result.ghostsPainted == 1,
      "the move ghost fell back: painted \(result.ghostsPainted), fell back \(result.ghostsFellBackToBounds)")
    #expect(result.ghostsFellBackToBounds == 0)
    #expect(
      result.primitiveCount == 9,
      "move overlay drew \(result.primitiveCount) primitives, expected 9 — a bare box is 1")
    #expect(strings(result.itemScene).contains("inner"))
  }

  /// The move ghost has to be shifted by the drag delta *and* by nothing else. The two ways this
  /// goes wrong, no shift at all, or the shift applied twice, are one subtraction apart, so the
  /// delta is measured rather than bounded.
  @Test("the move ghost is displaced by exactly the drag delta")
  @MainActor
  func moveGhostIsDisplacedByExactlyTheDelta() throws {
    let rig = try GhostRig()
    let placement = try rig.place(at: (300, 300))
    let grab = try #require(interior(of: placement))
    let delta = (dx: 60, dy: 40)

    rig.pointer(.down, grab.x, grab.y)
    rig.pointer(.dragged, grab.x, grab.y, dragOrigin: (grab.x, grab.y))
    let atRest = rig.canvas.overlayResult.itemScene
    let restMinX = try #require(atRest.primitives.map { Int($0.bounds.minX) }.min())
    let restMinY = try #require(atRest.primitives.map { Int($0.bounds.minY) }.min())

    rig.pointer(
      .dragged, grab.x + delta.dx, grab.y + delta.dy, dragOrigin: (grab.x, grab.y))
    let shifted = rig.canvas.overlayResult.itemScene
    let shiftedMinX = try #require(shifted.primitives.map { Int($0.bounds.minX) }.min())
    let shiftedMinY = try #require(shifted.primitives.map { Int($0.bounds.minY) }.min())

    #expect(
      shifted.primitives.count == atRest.primitives.count,
      "the ghost changed shape when it moved")
    #expect(
      shiftedMinX - restMinX == delta.dx,
      "ghost moved \(shiftedMinX - restMinX) in x, drag was \(delta.dx)")
    #expect(
      shiftedMinY - restMinY == delta.dy,
      "ghost moved \(shiftedMinY - restMinY) in y, drag was \(delta.dy)")
  }

  /// **Does the ghost respect `ToolOverlay.hidden`?** A move preview that leaves the unshifted
  /// original on screen at full strength shows the component twice.
  ///
  /// Asserted through the surface's own circuit scene, not by reading the `hidden` set back:
  /// `CanvasHiddenComponentTests`' header records that the set was populated, carried and stored
  /// while nothing consulted it, and a test on the field would have passed against that.
  @Test("the moved subcircuit is hidden from the circuit scene while its ghost is up")
  @MainActor
  func theOriginalIsHiddenWhileDragging() throws {
    let rig = try GhostRig()
    let placement = try rig.place(at: (300, 300))
    let grab = try #require(interior(of: placement))

    let before = rig.surface.build
    #expect(before.paintedComponentCount == 1, "the placement did not draw to begin with")
    #expect(before.scene.primitives.count >= 10)

    rig.pointer(.down, grab.x, grab.y)
    rig.pointer(.dragged, grab.x + 60, grab.y + 40, dragOrigin: (grab.x, grab.y))

    let during = rig.surface.build
    #expect(
      during.paintedComponentCount == 0,
      "the unshifted original is still drawn under its own ghost")
    #expect(
      during.scene.primitives.count < before.scene.primitives.count,
      "hiding removed no geometry: \(during.scene.primitives.count) vs \(before.scene.primitives.count)")

    // And it comes back. A `hidden` set that is never cleared erases the component for good.
    rig.pointer(.up, grab.x + 60, grab.y + 40, dragOrigin: (grab.x, grab.y))
    #expect(rig.surface.build.paintedComponentCount == 1, "the component did not come back")
  }

  // ── 3. The guard itself ───────────────────────────────────────────────────────────────────

  /// The root cause, stated the way §6.3 stated it, now in the positive.
  ///
  /// `CircuitSubcircuitFactory` is still not an `InstanceFactory`: it descends from
  /// `AbstractComponentFactory` in `LogisimFile`, and making it one would drag the whole
  /// `Instance` machinery below `LogisimStd`. What changed is that the ghost path no longer
  /// *needs* it to be: `InstancePaintable` is all `paintGhost` requires, and
  /// `InstancePainter.setFactory` already takes an optional factory.
  @Test("the ghost path no longer requires the InstanceFactory cast that a subcircuit fails")
  @MainActor
  func theGhostPathGuardsOnPaintabilityNotOnInstanceFactory() throws {
    let rig = try GhostRig()
    // Erased to `any ComponentFactory` on purpose: that is the static type both ghost entry
    // points hold, so these are the same two runtime questions the canvas asks. Kept concrete,
    // the second cast is answered by the compiler and measures nothing.
    let factory: any ComponentFactory = rig.subcircuitFactory

    #expect(factory as? any InstanceFactory == nil, "the premise changed — reread §6.3")
    #expect(factory as? any InstancePaintable != nil)

    // Which is only interesting because the canvas reaches it anyway. Same gesture, asserted
    // beside the two casts so the pair reads as one statement.
    rig.setTool(try rig.subcircuitAddTool)
    rig.pointer(.moved, 300, 300)
    #expect(rig.canvas.overlayResult.ghostsPainted == 1)
  }

  /// The fallback is still reachable and still correct. Widening a guard is the easy way to turn
  /// "draws a box" into "draws nothing" for every factory that has no ghost of its own, so the
  /// negative case is measured beside the positive one.
  ///
  /// `SplitterFactory` is the discriminator: it is an `AbstractComponentFactory` and conforms to
  /// neither `InstanceFactory` nor `InstancePaintable`: the exact shape the widened guard now
  /// admits, minus the paintability. It must still stroke its offset box, because a component the
  /// canvas cannot draw has to drag visibly all the same.
  @Test("a factory that is not paintable at all still strokes its offset box")
  @MainActor
  func anUnpaintableFactoryStillFallsBack() throws {
    let rig = try GhostRig()
    rig.setTool(CanvasAddTool(factory: SplitterFactory.instance))
    rig.pointer(.moved, 500, 500)

    let result = rig.canvas.overlayResult
    #expect(result.ghostsPainted == 0, "a splitter has no InstancePaintable ghost to paint")
    #expect(result.ghostsFellBackToBounds == 1)
    // `strokeOffsetBounds` emits exactly one `drawRect`, and it has to be a real box.
    #expect(result.primitiveCount == 1, "the fallback drew \(result.primitiveCount) primitives")
    let box = try #require(result.itemScene.primitives.first).bounds
    #expect(box.maxX > box.minX && box.maxY > box.minY, "the fallback box is degenerate: \(box)")
  }
}
