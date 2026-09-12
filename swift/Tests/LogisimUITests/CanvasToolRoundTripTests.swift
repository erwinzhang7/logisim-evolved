// LogisimUITests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// SEAM #19: DOES A TOOL GESTURE REACH THE MODEL THROUGH THE CANVAS?
//
// `ToolCanvas` had 124 references across eleven files and zero conformers. A conformance is the
// easiest thing in this project to fake yourself out with: it compiles, `seamcheck` goes quiet,
// and nothing has been shown to happen. So none of these tests assert that a method exists or
// that a call returned. Each one drives a **real pointer gesture** through the same entry point
// the AppKit host uses, `CanvasInteractionHandler.canvasHandlePointer(CanvasPointerEvent)`,
// and then asserts on state only the conformer can produce:
//
//   * a component in `Selection` that the tool put there;
//   * a `Wire` in the `Circuit`, with the endpoints the drag described, on the undo stack;
//   * a component whose `Location` changed by the dragged delta;
//   * `repaintedRects` / `focusRequestCount`, which come from `ToolCanvas.repaint(_:)` and
//     `requestFocus()` and from nowhere else in the app;
//   * `overlayResult.primitiveCount`, which is the difference between "the overlay is wired" and
//     "the overlay is wired and draws nothing".
//
// RED/GREEN, MEASURED. `CircuitEditorCanvas` is the only `ToolCanvas` in the module, so removing
// the conformance does not fail one assertion; it fails the *build*, which is a weaker signal
// than it looks and is exactly the "it compiles" trap this suite is written against. The
// conformance was therefore broken three ways, one at a time, each leaving a green build:
//
//   (a) `setToolOverlay(_:)` reduced to `{ toolOverlay = overlay }`; the shape it would have had
//       if the overlay were recorded and never rendered, which is exactly the state `PokeTool`,
//       `WiringTool` and `SelectTool` were all in before this seam was closed:
//
//                                                     stubbed | wired
//         wiring drag, overlay primitives                   0 | 1
//         move drag, overlay primitives                     0 | 2
//         marquee drag, items drawn / primitives         0/0  | 2/4
//         one-of-every-item overlay, items drawn / prims 0/0  | 10/18
//         poke on a Register, poke-scene primitives       nil | 1
//         wire poke callout, items drawn / primitives    0/0  | 1/3
//
//       6 of 12 tests fail, 14 issues. The `Wire` still lands in the circuit with the right
//       endpoints and the drag still moves the component, the model half is untouched, which
//       is precisely why "the edit works" is not evidence that the canvas draws.
//
//   (b) `repaint(_:)` and `requestFocus()` reduced to `{}`; the two calls a canvas is most
//       likely to "implement" as no-ops because nothing visibly breaks:
//         `repaintedRects.count` after a wiring drag   0 | 1
//         `focusRequestCount` after a select press     0 | 1
//       2 issues, in 2 tests. Everything else stays green, including the overlay.
//
//   (c) `pointQueries` answered by `EmptyCircuitPointQueries` unconditionally: the canvas
//       conforming without being connected to its circuit:
//         wires in the circuit after a shortening drag   2 | 1
//         surviving wire's end0                  (100,100) | (150,100)
//         wires in the poked run                         1 | 2
//       3 issues, in 2 tests: the drag adds a second wire on top of the first instead of
//       shortening it, because `WiringTool.mouseDragged`'s `wires(at:)` finds nothing. Nothing
//       else in the suite notices, which is why this case is tested at all.
//
// Every reverted state built with zero errors and zero new warnings.
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
/// Built from `LogisimFileProjectHostFactory`, not from hand-assembled parts: the question this
/// suite asks is whether the *application's* canvas drives the tools, and a hand-built `Project`
/// would answer a different one.
@MainActor
private struct Rig {
  let host: LogisimFileProjectHost
  let project: Project
  let circuit: Circuit
  let surface: CircuitCanvasSurface
  let canvas: CircuitEditorCanvas

  init(tool: any CanvasTool) throws {
    let made = try LogisimFileProjectHostFactory().makeEmptyProject()
    host = try #require(made as? LogisimFileProjectHost)
    project = host.project
    circuit = try #require(host.currentCircuitObject)
    surface = try #require(host.makeRenderSurface() as? CircuitCanvasSurface)
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
    let world = CGPoint(x: CGFloat(x), y: CGFloat(y))
    canvas.controller.canvasHandlePointer(
      CanvasPointerEvent(
        phase: phase,
        world: world,
        modifiers: modifiers,
        clickCount: clickCount,
        buttonNumber: 1,
        dragOriginWorld: nil))
  }
}

/// A point the component actually reports as inside it.
///
/// A hardcoded centre is wrong for several factories, a gate's body is not its bounding box and
/// `Component.contains` is the exact geometry, and `SelectTool.mousePressed` branches on
/// `circuit.allContaining(point)`, so a point the component rejects silently takes the
/// background arm and the test would assert on a marquee it did not mean to start.
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

@MainActor
private func wires(in circuit: Circuit) -> [Wire] { circuit.wires }

// MARK: - The gate

@Suite("Canvas tool round trip", .serialized)
struct CanvasToolRoundTripTests {

  // ── 1. A click selects ────────────────────────────────────────────────────────────────────

  @Test("a press on a component puts it in the canvas's Selection")
  @MainActor
  func pressSelects() throws {
    let rig = try Rig(tool: SelectTool())
    let gate = try rig.add(AndGate.factory, at: (120, 100))
    let point = try #require(interiorPoint(of: gate))

    #expect(rig.canvas.selection.isEmpty)
    #expect(rig.canvas.focusRequestCount == 0)

    rig.pointer(.down, point.x, point.y)

    // The selection is the canvas's own object; `Project.selection` is a reach-through to it
    // (`Project.java:397-402`), so this is also the assertion that the project can now see a
    // selection at all, which it could not before a canvas existed.
    #expect(rig.canvas.selection.components.count == 1)
    #expect(rig.canvas.selection.components.first === gate)
    #expect(rig.project.selection === rig.canvas.selection)

    // `SelectTool.mousePressed`'s first line is `canvas.requestFocus()`. Nothing else in the
    // application calls it, so a non-zero count is proof the tool ran against this canvas.
    #expect(rig.canvas.focusRequestCount == 1)
  }

  @Test("a press on empty space starts a marquee, and the marquee is DRAWN")
  @MainActor
  func marqueeDraws() throws {
    let rig = try Rig(tool: SelectTool())
    try rig.add(AndGate.factory, at: (200, 200))

    rig.pointer(.down, 40, 40)
    #expect(rig.canvas.selection.isEmpty)
    // A press with no drag yet is a **zero-size** marquee, and upstream draws it: `SelectTool
    // .draw`'s RECT_SELECT arm clamps negative width and height to 0 and calls `drawRect` anyway
    // (`SelectTool.java:519-524`); only the *interior* fill is gated on `w > 2 && h > 2`. So one
    // primitive, not none: checked against the Java rather than assumed, because "zero here"
    // was the intuitive expectation and it is wrong.
    #expect(rig.canvas.overlayResult.primitiveCount == 1)
    #expect(rig.canvas.overlayResult.itemsDrawn == 1)

    rig.pointer(.dragged, 260, 260)

    // The rubber band plus a ghost for the gate it now crosses. Both come out of
    // `ToolOverlaySceneBuilder`; before it existed `setToolOverlay` had no implementation
    // anywhere in the module.
    #expect(rig.canvas.overlayResult.itemsDrawn >= 2)
    #expect(rig.canvas.overlayResult.primitiveCount >= 3)
    #expect(rig.canvas.overlayResult.ghostsPainted + rig.canvas.overlayResult.ghostsFellBackToBounds == 1)

    rig.pointer(.up, 260, 260)
    #expect(rig.canvas.selection.components.count == 1)
    // The gesture ended, so the overlay is empty again; a rubber band that survives the mouse
    // release is the classic overlay bug and it is one integer away here.
    #expect(rig.canvas.overlayResult.primitiveCount == 0)
  }

  // ── 2. A drag moves ───────────────────────────────────────────────────────────────────────

  @Test("a drag moves the component in the circuit, not just on screen")
  @MainActor
  func dragMoves() throws {
    let tool = SelectTool()
    // `MOVE_KEEP_CONNECT` off: the reroute engine runs on its own `ConnectorThread` and
    // `commitMove` blocks on it. `dragMovesWithReconnect` below turns it back on.
    tool.keepsConnectionsWhenMoving = false
    let rig = try Rig(tool: tool)
    let gate = try rig.add(AndGate.factory, at: (120, 100))
    let point = try #require(interiorPoint(of: gate))
    let before = gate.location

    rig.pointer(.down, point.x, point.y)
    rig.pointer(.dragged, point.x + 40, point.y + 30)
    // Mid-drag the tool draws the selection shifted. `selectionGhost` carries only the delta:
    // the components come from the canvas's `Selection`, which is the join
    // `ToolOverlaySceneBuilder.build(_:selectionComponents:appearance:)` exists to make.
    #expect(rig.canvas.overlayResult.primitiveCount > 0)

    rig.pointer(.up, point.x + 40, point.y + 30)

    // The oracle is the CIRCUIT, not the selection: `SelectionActions.translate` replaces every
    // moved component with a new object, so asserting on the selection would be asserting on the
    // bookkeeping rather than on the edit.
    let moved = rig.circuit.nonWires.filter { $0.factory === AndGate.factory }
    #expect(moved.count == 1)
    let after = try #require(moved.first).location
    #expect(after.x == before.x + 40)
    #expect(after.y == before.y + 30)

    // And it is undoable, because the tool went through `Project.doAction`.
    #expect(rig.project.canUndo)
    try rig.project.undoAction()
    let restored = try #require(rig.circuit.nonWires.first { $0.factory === AndGate.factory })
    #expect(restored.location == before)
  }

  @Test("the same drag with MOVE_KEEP_CONNECT on still lands, through the reroute engine")
  @MainActor
  func dragMovesWithReconnect() throws {
    let rig = try Rig(tool: SelectTool())
    let gate = try rig.add(AndGate.factory, at: (200, 200))
    let point = try #require(interiorPoint(of: gate))
    let before = gate.location

    rig.pointer(.down, point.x, point.y)
    rig.pointer(.dragged, point.x + 20, point.y)
    rig.pointer(.up, point.x + 20, point.y)

    let moved = try #require(rig.circuit.nonWires.first { $0.factory === AndGate.factory })
    #expect(moved.location.x == before.x + 20)
    #expect(moved.location.y == before.y)
    // `commitMove` sets `.computingMove` before blocking on the connector thread and clears it
    // when the answer arrives. A message left behind is a stuck "Computing…" strip in the app.
    #expect(rig.canvas.statusMessage == nil)
  }

  // ── 3. A wire is drawn ────────────────────────────────────────────────────────────────────

  @Test("a wiring drag adds a Wire with the endpoints the gesture described")
  @MainActor
  func wiringDragAddsAWire() throws {
    let rig = try Rig(tool: WiringTool())
    #expect(wires(in: rig.circuit).isEmpty)

    rig.pointer(.down, 100, 100)
    rig.pointer(.dragged, 160, 100)

    // The pending wire, drawn before it is committed. `WiringTool.overlay` emits exactly one
    // `.pendingWire`, and a straight run is one line.
    #expect(rig.canvas.overlayResult.itemsDrawn == 1)
    #expect(rig.canvas.overlayResult.primitiveCount == 1)
    // `WiringTool.mouseDragged` is the only caller of `ToolCanvas.repaint(Bounds)` in the app.
    #expect(!rig.canvas.repaintedRects.isEmpty)

    rig.pointer(.up, 160, 100)

    let made = wires(in: rig.circuit)
    #expect(made.count == 1)
    let wire = try #require(made.first)
    #expect(wire.end0 == Location.create(100, 100, hasToSnap: true))
    #expect(wire.end1 == Location.create(160, 100, hasToSnap: true))
    #expect(rig.project.canUndo)

    // The gesture is over, so nothing is pending.
    #expect(rig.canvas.overlayResult.primitiveCount == 0)
  }

  @Test("an L-shaped drag adds two wires meeting at the elbow")
  @MainActor
  func elbowDragAddsTwoWires() throws {
    let rig = try Rig(tool: WiringTool())

    rig.pointer(.down, 100, 100)
    // The first drag latches the direction; `WiringTool.computeMove`'s HORIZONTAL/VERTICAL
    // latch is what decides which side of the rectangle the corner sits on.
    rig.pointer(.dragged, 140, 100)
    rig.pointer(.dragged, 140, 160)
    rig.pointer(.up, 140, 160)

    let made = wires(in: rig.circuit).sorted { $0.end0.x < $1.end0.x || $0.end0.y < $1.end0.y }
    #expect(made.count == 2)
    let corner = Location.create(140, 100, hasToSnap: true)
    #expect(made.contains { $0.end0 == corner || $0.end1 == corner })
    #expect(made.allSatisfy { $0.length > 0 })
  }

  /// The `pointQueries` case, and the only test in this suite that fails if the canvas conforms
  /// but is not actually connected to its circuit. `WiringTool.mouseDragged` asks
  /// `canvas.pointQueries.wires(at:)` to decide whether the drag is *shortening* an existing wire
  /// rather than adding a new one; with an empty query it adds a second wire on top of the first.
  @Test("dragging inward from a wire's end shortens it instead of adding another")
  @MainActor
  func shortensAnExistingWire() throws {
    let rig = try Rig(tool: WiringTool())
    let existing = Wire.create(
      Location.create(100, 100, hasToSnap: true), Location.create(200, 100, hasToSnap: true))
    try rig.circuit.mutatorAdd(existing)
    #expect(wires(in: rig.circuit).count == 1)

    // Press on the wire's own end and drag *along* it, toward the middle.
    rig.pointer(.down, 100, 100)
    rig.pointer(.dragged, 150, 100)
    rig.pointer(.up, 150, 100)

    let after = wires(in: rig.circuit)
    #expect(after.count == 1)
    let wire = try #require(after.first)
    #expect(wire.end0 == Location.create(150, 100, hasToSnap: true))
    #expect(wire.end1 == Location.create(200, 100, hasToSnap: true))
  }

  // ── 4. The overlay is not merely wired ────────────────────────────────────────────────────

  @Test("every overlay item the tools emit produces at least one primitive")
  @MainActor
  func overlayDrawsSomething() throws {
    let rig = try Rig(tool: SelectTool())
    let gate = try rig.add(AndGate.factory, at: (200, 200))

    // One of each shape the six tools can emit, in one overlay, so that a case which is wired
    // but silent shows up as a gap between `items.count` and `itemsDrawn`.
    let overlay = ToolOverlay(items: [
      .pendingWire(
        start: Location.create(0, 0, hasToSnap: false),
        elbow: Location.create(40, 0, hasToSnap: false),
        end: Location.create(40, 40, hasToSnap: false)),
      .cursorDot(Location.create(10, 10, hasToSnap: false)),
      .wiringPointIndicator(Location.create(20, 20, hasToSnap: false)),
      .marquee(Bounds.create(0, 0, 100, 100)),
      .marqueeGhost(component: ComponentRef(gate)),
      .selectionGhost(dx: 10, dy: 10),
      .proposedWire(
        start: Location.create(0, 0, hasToSnap: false),
        end: Location.create(50, 0, hasToSnap: false)),
      .unsatisfiedConnection(Location.create(5, 5, hasToSnap: false), dx: 10, dy: 10),
      .placementGhost(
        factory: ComponentFactoryRef(AndGate.factory),
        at: Location.create(300, 300, hasToSnap: false),
        isCommitted: false, needsLabel: false),
      .valueCallout(at: Location.create(60, 60, hasToSnap: false), text: "0b1010"),
    ])

    // `selectionGhost` needs components from the canvas's selection, so put one there the way a
    // user would rather than reaching into `SelectionBase`.
    let point = try #require(interiorPoint(of: gate))
    rig.pointer(.down, point.x, point.y)
    rig.pointer(.up, point.x, point.y)
    #expect(rig.canvas.selection.components.count == 1)

    rig.canvas.setToolOverlay(overlay)
    let result = rig.canvas.overlayResult

    // TEN items in, TEN items drawn. A case that reaches its arm and emits nothing is the exact
    // failure mode of the whole `paintInstance`/`paintGhost`/`InstancePoker.paint` family, three
    // times over in this port's history.
    #expect(result.itemsDrawn == overlay.items.count)
    #expect(result.primitiveCount >= overlay.items.count)
    // Three ghosts: the marquee ghost, the selection ghost (one selected component), and the
    // placement ghost. Each either painted through the factory or fell back to Java's
    // offset-bounds rectangle: never neither.
    #expect(result.ghostsPainted + result.ghostsFellBackToBounds == 3)
  }

  // ── 5. The poke highlight, seam #16's handoff, measured ───────────────────────────────────

  @Test("a poke on a Register drives the component's own InstancePoker.paint")
  @MainActor
  func pokeHighlightReachesTheComponent() throws {
    let rig = try Rig(tool: PokeTool())
    let factory = try #require(
      MemoryLibrary().tools.compactMap { ($0 as? AddTool)?.factory }
        .first { ($0 as? any InstanceFactory)?.makePoker() is RegisterPoker })
    let register = try rig.add(factory, at: (200, 200))

    // The one thing the application cannot supply yet: a live `CircuitState`.
    // `Project.swift:90-105` records why, root states are built on the propagation thread and
    // handing one to the main actor would be a data race, so the canvas exposes the slot and a
    // test fills it. Without this the poke path is inert and the assertion below would be
    // measuring the absence of a simulation rather than the absence of a highlight.
    let state = FakePokeCircuitState(component: register)
    rig.canvas.circuitState = state

    let point = try #require(interiorPoint(of: register))
    rig.pointer(.down, point.x, point.y)

    // `PokeTool.overlay(for:)` → `Caret.overlayScene(context:)` → `InstancePokerCaret` →
    // `PokeOverlayRenderer.render` → `RegisterPoker.paint(any MemPainter)`. Before this seam was
    // closed the chain stopped at the first arrow: `ToolOverlay` had no `scene` field at all.
    let poke = try #require(rig.canvas.overlayResult.pokeScene)
    // `PokeHighlightSeamTests` measured `RegisterPoker` at exactly 1 primitive; the same driver
    // through the same painter must produce the same count here.
    #expect(poke.primitives.count == 1)
    #expect(rig.canvas.overlayResult.primitiveCount == 1)
  }

  @Test("poking a wire highlights its run and shows the value callout")
  @MainActor
  func pokeWireHighlightsAndAnnotates() throws {
    let rig = try Rig(tool: PokeTool())
    let a = Wire.create(
      Location.create(100, 100, hasToSnap: true), Location.create(200, 100, hasToSnap: true))
    let b = Wire.create(
      Location.create(200, 100, hasToSnap: true), Location.create(200, 200, hasToSnap: true))
    try rig.circuit.mutatorAdd(a)
    try rig.circuit.mutatorAdd(b)

    rig.canvas.circuitState = FakeWireCircuitState(
      value: try Value.createKnown(BitWidth.create(4), 10))

    rig.pointer(.down, 150, 100)

    // `canvas.setHighlightedWires(canvas.pointQueries.wireSet(containing:))`: the run, not just
    // the clicked segment. Two wires meet at (200,100), so both are in it.
    let highlighted = try #require(rig.canvas.highlightedWires)
    #expect(highlighted.count == 2)
    // The callout is a fixed shape, so it travels as a `ToolOverlayItem` and lands in the item
    // scene: a filled box, its outline, and the text run.
    #expect(rig.canvas.overlayResult.itemsDrawn == 1)
    #expect(rig.canvas.overlayResult.primitiveCount >= 3)
  }

  // ── 6. The canvas answers the project ─────────────────────────────────────────────────────

  @Test("Project.repaintCanvas reaches the canvas and re-derives the overlay")
  @MainActor
  func projectRepaintReachesTheCanvas() throws {
    let rig = try Rig(tool: SelectTool())
    let before = rig.canvas.repaintAllCount
    rig.project.repaintCanvas()
    // `Project.repaintCanvas()` fires a `.repaintRequest` project event rather than calling the
    // canvas (`Project.swift:818-820`); upstream's shape. Every tool calls it, so a canvas that
    // does not subscribe silently drops two thirds of the tool layer's repaints.
    #expect(rig.canvas.repaintAllCount > before)
  }

  @Test("Project.setErrorMessage reaches the canvas's status strip")
  @MainActor
  func projectErrorMessageReachesTheCanvas() throws {
    let rig = try Rig(tool: SelectTool())
    #expect(rig.canvas.statusMessage == nil)
    rig.project.setErrorMessage("circuit would contain itself")
    #expect(rig.canvas.statusMessage == .literal("circuit would contain itself"))
    rig.project.setErrorMessage(nil)
    #expect(rig.canvas.statusMessage == nil)
  }
}

// MARK: - Simulation-state doubles

/// The `ToolCircuitState` the application cannot supply yet; see the poke test's comment.
@MainActor
private final class FakePokeCircuitState: ToolCircuitState {
  private let component: any Component
  private let state: FakeInstanceState

  init(component: any Component) {
    self.component = component
    self.state = FakeInstanceState(component)
  }

  func value(at location: Location) -> Value? { nil }

  func instanceState(for component: any Component) -> (any InstanceState)? {
    component === self.component ? state : nil
  }
}

@MainActor
private final class FakeWireCircuitState: ToolCircuitState {
  private let value: Value
  init(value: Value) { self.value = value }
  func value(at location: Location) -> Value? { value }
  func instanceState(for component: any Component) -> (any InstanceState)? { nil }
}

/// Everything a poker's `beginPoke` and `paint` read, and nothing else.
///
/// Hand-written for the same reason `PokeHighlightSeamTests` hand-writes its own: the real
/// `InstanceStateImpl` belongs to the propagator and can only be built on the propagation thread
/// (D1), which is precisely the boundary that keeps the application's `circuitState` nil.
private final class FakeInstanceState: InstanceState {
  let component: any Component
  private var stored: (any InstanceData)?

  init(_ component: any Component) { self.component = component }

  var attributeSet: any AttributeSet { component.attributeSet }
  var factory: (any InstanceFactory)? { component.factory as? any InstanceFactory }
  var data: (any InstanceData)? { stored }
  func setData(_ value: (any InstanceData)?) { stored = value }
  func portIndex(of port: LogisimStd.Port) -> Int { -1 }
  func portValue(_ index: Int) -> Value { .unknownValue }
  func isPortConnected(_ index: Int) -> Bool { false }
  func setPort(_ index: Int, _ value: Value, _ delay: Int) {}
  var tickCount: Int { 0 }
  var isCircuitRoot: Bool { true }
  func fireInvalidated() {}
  var projectOptions: any AttributeSet { AttributeSets.empty }
}
