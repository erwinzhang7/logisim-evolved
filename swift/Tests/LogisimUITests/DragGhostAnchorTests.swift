// DragGhostAnchorTests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16), disassembled from
// /Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// WHERE DOES THE MOVE GHOST ACTUALLY LAND?
//
// Reported from real use: "the location is wrong. it shows up to the right of the actual
// location", about the drag preview. Two readings had to be told apart before anything could be
// fixed, because they call for opposite responses:
//
//   (a) the ghost is offset from WHERE THE COMPONENT LANDS, a bug;
//   (b) the ghost is offset from THE CURSOR because the drag preserves the grab offset, which
//       is what upstream does, and not a bug at all.
//
// This suite measures (a) directly, in world units, out of the real overlay scene: the ghost's
// painted bounds against the dropped component's bounds. Nothing here reads the cursor to decide
// whether the ghost is "right"; the pointer is recorded only so the (b) reading is a number too.
//
// THE ANSWER WAS (a), and by a mile. AndGate placed at (200,150), grabbed at (150,125),
// dragged +30/+20:
//
//     ghost painted bounds     x 408...462   y 312...368
//     component after the drop x 180...230   y 145...195
//     pointer at capture              (180, 145)
//     offset                        +228        +167
//
// The offset is neither constant nor proportional to zoom: it is exactly the component's own
// post-drop LOCATION (230, 170), less the two-unit pen overhang. The ghost was landing at
// `2 * location + offsetBounds`. Near the origin it looks almost right; far from it the preview
// is a whole component-position away, which is the "completely wrong places" the report started
// as.
//
// THE ANCHOR, IN 4.1.0. `Selection.drawGhostsShifted` calls
// `factory.drawGhost(context, colour, loc.getX() + dx, loc.getY() + dy, attrs)`, and
// `InstanceFactory.drawGhost` is
//
//     g.setColor(color); g.translate(x, y); painter.setFactory(this, attrs);
//     paintGhost(painter); g.translate(-x, -y);
//
// ; `setFactory` takes NO location, and `InstancePainter.getLocation()` is
// `comp == null ? Location.create(0, 0, false) : comp.getLocation()`. So during `paintGhost`
// upstream's painter reports the ORIGIN, every ghost paints in offset coordinates, and the one
// outer translate is what puts it on the canvas.
//
// This port's `InstancePainter.setFactory(_:_:at:)` stores a real ghost location and
// `InstancePainter.location` hands it back, while `ToolOverlayScene.paint` still pushed the
// outer translate. Every `paintGhost` that positions itself from `painter.location`,
// `AbstractGate.paintBase` (every gate), `NotGate`, `Buffer`, `Pin`, `Clock`, `Probe`, the TTL
// chips, was translated twice. Only `SubcircuitPainter.paintBase` carried a compensation, and
// its own comment predicted this exact failure for everyone else.
//
// WHAT IS ASSERTED, AND WHY IN THIS SHAPE. The claim gated is "the ghost occupies the frame the
// component will occupy", stated against the component's own measured bounds rather than
// literals, at two zooms, for three factories, and for a grab both away from and exactly at the
// component's own anchor; the last because grabbing at the anchor is the case that HIDES an
// anchor bug in a hand test.
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

@MainActor
private struct AnchorRig {
  let host: LogisimFileProjectHost
  let project: Project
  let circuit: Circuit
  let surface: CircuitCanvasSurface
  let canvas: CircuitEditorCanvas

  /// `keepsConnectionsWhenMoving: false` for the reason `SubcircuitGhostReachTests` records:
  /// the move engine's `AvoidanceMap` touches live model objects off the main actor. The ghost
  /// is drawn either way; `drawConnections` gates the proposed *wires*, not the ghost.
  init(zoom: Double = 1.0, connections: Bool = false) throws {
    StdLibraries.registerAll()
    let made = try LogisimFileProjectHostFactory().makeEmptyProject()
    host = try #require(made as? LogisimFileProjectHost)
    project = host.project
    circuit = try #require(host.currentCircuitObject)
    surface = try #require(host.makeRenderSurface() as? CircuitCanvasSurface)
    let select = SelectTool()
    select.keepsConnectionsWhenMoving = connections
    canvas = CircuitEditorCanvas(
      project: project, surface: surface, circuit: circuit, initialTool: select)
    surface.renderView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    surface.setViewport(
      CanvasViewport(
        zoom: zoom, center: CGPoint(x: 300, y: 250),
        viewSize: CGSize(width: 800, height: 600)))
  }

  @discardableResult
  func add(_ factory: any ComponentFactory, at point: (Int, Int)) throws -> any Component {
    let component = try factory.createComponent(
      location: Location.create(point.0, point.1, hasToSnap: false),
      attributes: factory.createAttributeSet())
    try circuit.mutatorAdd(component)
    return component
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

  /// The union of every primitive the overlay emitted, in **world** units; the units the
  /// circuit itself is in, because `CircuitSceneView.drawToolOverlay` renders this scene through
  /// the identical `RenderViewport` the schematic used.
  var overlayWorldBounds: SceneBounds? {
    let scene = canvas.overlayResult.itemScene
    guard !scene.primitives.isEmpty else { return nil }
    var box = SceneBounds.empty
    for primitive in scene.primitives { box.formUnion(primitive.bounds) }
    return box.isEmpty ? nil : box
  }

  /// World → view for the frame the canvas would actually draw, so a world-unit offset can be
  /// restated in the view pixels the report was made in.
  var worldToView: CGAffineTransform {
    (surface.renderView as? CircuitSceneView)?.worldToView ?? .identity
  }
}

/// Every point the component itself reports as inside it: `SelectTool.mousePressed` branches on
/// `circuit.allContaining(point)`, and a point the component rejects starts a marquee instead.
@MainActor
private func interiorPoints(of component: any Component) -> [Location] {
  let box = component.bounds
  guard box.width > 0, box.height > 0 else { return [] }
  var found: [Location] = []
  for y in stride(from: box.y, through: box.y + box.height, by: 1) {
    for x in stride(from: box.x, through: box.x + box.width, by: 1) {
      let point = Location.create(x, y, hasToSnap: false)
      if component.contains(point) { found.append(point) }
    }
  }
  return found
}

/// The interior point farthest from the component's own anchor. Grabbing *at* the anchor is the
/// case that hides an anchor bug, so the default grab must not be it.
@MainActor
private func grabAwayFromAnchor(_ component: any Component) -> Location? {
  let origin = component.location
  return interiorPoints(of: component).max {
    abs($0.x - origin.x) + abs($0.y - origin.y) < abs($1.x - origin.x) + abs($1.y - origin.y)
  }
}

private func describe(_ bounds: Bounds) -> String {
  "x \(bounds.x)...\(bounds.x + bounds.width), y \(bounds.y)...\(bounds.y + bounds.height)"
}

private func describe(_ bounds: SceneBounds) -> String {
  "x \(bounds.minX)...\(bounds.maxX), y \(bounds.minY)...\(bounds.maxY)"
}

// MARK: - One measured drag

@MainActor
private struct DragMeasurement {
  var label: String
  var zoom: Double
  var grab: Location
  var pointer: Location
  var ghost: SceneBounds
  var before: Bounds
  var after: Bounds

  var offsetX: Int { Int(ghost.minX) - after.x }
  var offsetY: Int { Int(ghost.minY) - after.y }

  var report: String {
    """
    [ghost anchor] \(label) @ zoom \(zoom)
      grab (\(grab.x),\(grab.y))  pointer (\(pointer.x),\(pointer.y))
      1. ghost painted bounds  : \(describe(ghost))
      2. component after drop  : \(describe(after))
      3. component before drag : \(describe(before))
         committed delta       : (\(after.x - before.x),\(after.y - before.y))
         ghost minus component : (\(offsetX),\(offsetY))
    """
  }
}

/// Drives one real press/drag/release through `CanvasInteractionHandler.canvasHandlePointer`,
/// the same entry point `CanvasHostNSView` uses, capturing the overlay at the drag and the
/// component's geometry on both sides of the drop.
@MainActor
private func measureDrag(
  _ label: String,
  factory: any ComponentFactory,
  at place: (Int, Int),
  delta: (Int, Int) = (30, 20),
  zoom: Double = 1.0,
  grabAtAnchor: Bool = false
) throws -> DragMeasurement {
  let rig = try AnchorRig(zoom: zoom)
  let component = try rig.add(factory, at: place)
  let before = component.bounds

  let grab: Location
  if grabAtAnchor {
    let anchor = component.location
    try #require(
      component.contains(anchor),
      "\(label) does not report its own anchor as inside it; pick another grab")
    grab = anchor
  } else {
    grab = try #require(grabAwayFromAnchor(component), "\(label) has no interior point")
  }

  let target = (x: grab.x + delta.0, y: grab.y + delta.1)
  rig.pointer(.down, grab.x, grab.y)
  rig.pointer(.dragged, target.x, target.y, dragOrigin: (grab.x, grab.y))
  let ghost = try #require(rig.overlayWorldBounds, "\(label): the move drew no overlay at all")

  rig.pointer(.up, target.x, target.y, dragOrigin: (grab.x, grab.y))
  let dropped = try #require(
    rig.circuit.nonWires.first { $0.factory === factory },
    "\(label): the component did not survive the drag")

  return DragMeasurement(
    label: label, zoom: zoom, grab: grab,
    pointer: Location.create(target.x, target.y, hasToSnap: false),
    ghost: ghost, before: before, after: dropped.bounds)
}

/// A ghost is strokes, so it overhangs the component's box by up to a pen width. Four world
/// units is generous for a 2-unit pen and two orders tighter than the failure being gated, which
/// displaced the whole ghost by a full component location (228, 167 in the header's run).
private let penSlack = 4

@MainActor
private func expectGhostSitsOnTheComponent(_ m: DragMeasurement) {
  print(m.report)
  #expect(
    abs(Int(m.ghost.minX) - m.after.x) <= penSlack,
    "\(m.label): ghost x \(m.ghost.minX) vs component x \(m.after.x) — offset \(m.offsetX)")
  #expect(
    abs(Int(m.ghost.minY) - m.after.y) <= penSlack,
    "\(m.label): ghost y \(m.ghost.minY) vs component y \(m.after.y) — offset \(m.offsetY)")
  #expect(
    abs(Int(m.ghost.maxX) - (m.after.x + m.after.width)) <= penSlack,
    "\(m.label): ghost right \(m.ghost.maxX) vs component right \(m.after.x + m.after.width)")
  #expect(
    abs(Int(m.ghost.maxY) - (m.after.y + m.after.height)) <= penSlack,
    "\(m.label): ghost bottom \(m.ghost.maxY) vs component bottom \(m.after.y + m.after.height)")
}

// MARK: - The gate

@Suite("Move ghost — is it anchored where the component lands?", .serialized)
struct DragGhostAnchorTests {

  // ── 1. The three numbers ──────────────────────────────────────────────────────────────────

  /// THE MEASUREMENT the whole investigation turned on, in world units:
  ///   1. the ghost's painted bounds, out of the real overlay scene;
  ///   2. the component's bounds after the drop;
  ///   3. the pointer's world position at the moment the ghost was captured.
  @Test("the ghost's painted bounds equal the dropped component's bounds")
  @MainActor
  func ghostBoundsEqualTheDroppedComponentsBounds() throws {
    let m = try measureDrag("AndGate", factory: AndGate.factory, at: (200, 150))
    // The delta actually committed; what the ghost was previewing.
    #expect(m.after.x - m.before.x == 30 && m.after.y - m.before.y == 20)
    expectGhostSitsOnTheComponent(m)
  }

  // ── 2. The zoom question the screenshot raised ────────────────────────────────────────────

  /// The report's screenshot was at 94.3%, not 100%. An offset constant in *view* pixels but
  /// variable in world units, or the reverse, localises the cause, so both are measured.
  ///
  /// The overlay is built in world coordinates and `CircuitSceneView.drawToolOverlay` renders it
  /// through the same `RenderViewport` as the schematic, so the world-space geometry must be
  /// **identical** at the two zooms. Asserting the two scenes are equal is what makes "the
  /// camera is not involved" a measurement rather than an inference from reading `draw`.
  @Test("the ghost is anchored identically at 100% and at 94.3% zoom")
  @MainActor
  func zoomDoesNotMoveTheGhostInWorldSpace() throws {
    let full = try measureDrag("AndGate", factory: AndGate.factory, at: (200, 150), zoom: 1.0)
    let odd = try measureDrag("AndGate", factory: AndGate.factory, at: (200, 150), zoom: 0.943)

    expectGhostSitsOnTheComponent(full)
    expectGhostSitsOnTheComponent(odd)

    #expect(
      full.ghost == odd.ghost,
      "world-space ghost moved with the camera: 100% \(describe(full.ghost)) vs 94.3% \(describe(odd.ghost))"
    )
    #expect(full.after == odd.after, "the drop itself moved with the camera")
  }

  // ── 3. The grab that hides an anchor bug ──────────────────────────────────────────────────

  /// Grabbing a component exactly at its own anchor makes a "ghost is at `2 * location`" bug and
  /// a "ghost follows the cursor" bug produce different pictures but the same *feel*, so the
  /// suite pins both grabs. The delta is what the ghost previews either way, and it must not
  /// depend on where inside the component the press landed.
  @Test("the anchor holds whether the grab is at the component's origin or far from it")
  @MainActor
  func grabPositionDoesNotMoveTheGhost() throws {
    let away = try measureDrag("AndGate far grab", factory: AndGate.factory, at: (200, 150))
    let atAnchor = try measureDrag(
      "AndGate anchor grab", factory: AndGate.factory, at: (200, 150), grabAtAnchor: true)

    expectGhostSitsOnTheComponent(away)
    expectGhostSitsOnTheComponent(atAnchor)
    #expect(
      away.ghost == atAnchor.ghost,
      "the ghost moved with the grab point: far \(describe(away.ghost)) vs anchor \(describe(atAnchor.ghost))"
    )
  }

  // ── 4. Not one painter's accident ─────────────────────────────────────────────────────────

  /// `AbstractGate`, `NotGate` and `Pin` reach `painter.location` by three different routes:
  /// `paintBase` through the shared gate body, `NotGate`'s own `paintBase`, and `Pin.paintGhost`
  /// reading `loc` directly to place its two shapes. One factory would gate one of them.
  @Test("the anchor holds for a gate, an inverter and a pin")
  @MainActor
  func theAnchorHoldsAcrossPainters() throws {
    expectGhostSitsOnTheComponent(
      try measureDrag("AndGate", factory: AndGate.factory, at: (200, 150)))
    expectGhostSitsOnTheComponent(
      try measureDrag("NotGate", factory: NotGate.factory, at: (240, 180)))
    expectGhostSitsOnTheComponent(
      try measureDrag("Pin", factory: Pin.factory, at: (260, 120)))
  }

  // ── 5. The other entry point into the same painter ────────────────────────────────────────

  /// `ToolOverlaySceneBuilder.drawFactoryGhost`, `AddTool`'s pending placement, reaches the
  /// same `paint` and carried the same double translate. `SubcircuitGhostReachTests` covers this
  /// entry point only for a subcircuit, and `SubcircuitPainter` is the one painter that had the
  /// compensation, so that suite stayed green throughout and this path was never gated for
  /// anything else. Measured against the factory's own `offsetBounds`, so it is the frame the
  /// component would occupy rather than a literal.
  @Test("the placement ghost lands where the component would be placed")
  @MainActor
  func placementGhostLandsUnderTheCursor() throws {
    let rig = try AnchorRig()
    let factory = AndGate.factory
    let offset = factory.offsetBounds(factory.createAttributeSet())
    rig.canvas.controller.setActiveTool(CanvasAddTool(factory: factory))

    let cursor = (x: 320, y: 240)
    rig.pointer(.moved, cursor.x, cursor.y)
    let ghost = try #require(rig.overlayWorldBounds, "the placement drew no overlay at all")

    let frame = Bounds.create(
      cursor.x + offset.x, cursor.y + offset.y, offset.width, offset.height)
    print(
      """
      [ghost anchor] AndGate placement @ cursor (\(cursor.x),\(cursor.y))
        1. ghost painted bounds : \(describe(ghost))
        2. component frame      : \(describe(frame))
           ghost minus frame    : (\(Int(ghost.minX) - frame.x),\(Int(ghost.minY) - frame.y))
      """)

    #expect(
      abs(Int(ghost.minX) - frame.x) <= penSlack,
      "placement ghost x \(ghost.minX) vs frame x \(frame.x)")
    #expect(
      abs(Int(ghost.minY) - frame.y) <= penSlack,
      "placement ghost y \(ghost.minY) vs frame y \(frame.y)")
    #expect(
      abs(Int(ghost.maxX) - (frame.x + frame.width)) <= penSlack,
      "placement ghost right \(ghost.maxX) vs frame right \(frame.x + frame.width)")
    #expect(
      abs(Int(ghost.maxY) - (frame.y + frame.height)) <= penSlack,
      "placement ghost bottom \(ghost.maxY) vs frame bottom \(frame.y + frame.height)")
  }

  // ── 6. The offset's signature ─────────────────────────────────────────────────────────────

  /// The diagnosis, kept as a test because it is what tells the three candidate causes apart.
  /// A double translate displaces the ghost by *the component's own location*, so the error
  /// GROWS as the component moves away from the origin while zoom and grab stay fixed. A
  /// constant offset, or one proportional to zoom, or one equal to a component dimension, would
  /// each fail this differently.
  @Test("moving the same component farther from the origin does not grow the error")
  @MainActor
  func theErrorDoesNotTrackDistanceFromTheOrigin() throws {
    let near = try measureDrag("AndGate near origin", factory: AndGate.factory, at: (100, 80))
    let far = try measureDrag("AndGate far from origin", factory: AndGate.factory, at: (600, 420))
    print(near.report)
    print(far.report)
    #expect(
      near.offsetX == far.offsetX && near.offsetY == far.offsetY,
      "the ghost's error tracks the component's location — near (\(near.offsetX),\(near.offsetY)) vs far (\(far.offsetX),\(far.offsetY)); that is a second translate by `painter.location`"
    )
    expectGhostSitsOnTheComponent(near)
    expectGhostSitsOnTheComponent(far)
  }
}
