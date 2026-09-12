// LogisimUITests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// DOES THE APP'S OWN INPUT PATH REACH THE TOOL LAYER?
//
// `CanvasToolRoundTripTests` drives `CircuitEditorCanvas` directly and proves the tool layer
// works. This file starts one level out, at `host.interactionHandler`, the object
// `CanvasHostNSView` actually calls, and proves the application is wired to it.
//
// That distinction is the whole point. Before this, `CircuitEditorCanvas` was constructed only by
// tests: the app ran on an ad-hoc click/marquee handler on the host that could select and
// rubber-band and nothing else, whose `canvasHandleKey` returned `false` unconditionally so Delete
// did nothing, and whose cursor was a switch over three tool ids that answered `.arrow` for the
// other 159. Every test in the suite passed.
//
// ── ONE THING THESE CAUGHT, WHICH IS WHY THE HOST STILL ROUTES ───────────────────────────────
//
// The obvious wiring is `interactionHandler { editorCanvas?.controller }`. That regresses
// drag-and-drop: `CanvasToolController.canvasDropTool` IGNORES its `tool` argument and replays a
// press/release with whatever tool is already active, and `performDragOperation` does not select
// the dropped tool first. Only the host can resolve a `ToolID`. `dropPlacesTheDroppedTool` is the
// test that would have failed.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import CoreGraphics
import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd
import Testing

@testable import LogisimUI

@Suite("Host canvas routing", .serialized)
struct HostCanvasRoutingTests {

  @MainActor
  private func makeHost() throws -> (LogisimFileProjectHost, any CanvasInteractionHandler) {
    let host = try #require(
      try LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
    _ = host.makeRenderSurface()
    let handler = try #require(host.interactionHandler)
    return (host, handler)
  }

  /// Built exactly as `CanvasHostNSView` builds it, so this tests the shell's event and not a
  /// convenient approximation of one. It used to say "same snapping" as well; the shell no longer
  /// snaps anything: it forwards raw world points and the tools snap for themselves.
  private func event(_ phase: CanvasPointerEvent.Phase, _ x: Int, _ y: Int)
    -> CanvasPointerEvent
  {
    CanvasPointerEvent(
      phase: phase,
      world: CGPoint(x: CGFloat(x), y: CGFloat(y)),
      modifiers: [],
      clickCount: 1,
      buttonNumber: 1,
      dragOriginWorld: nil)
  }

  /// The centre of a component's BOUNDS, not its `Location`.
  ///
  /// A gate's location is its OUTPUT pin and the body extends back behind it, so clicking the
  /// location lands on the pin rather than inside the shape. Cost two failing runs before I
  /// noticed `CanvasToolRoundTripTests` uses an interior point for exactly this reason.
  private func interior(of component: any Component) -> (Int, Int) {
    let b = component.bounds
    return (b.x + b.width / 2, b.y + b.height / 2)
  }

  @Test("making a render surface builds the editing layer")
  @MainActor
  func surfaceBuildsTheCanvas() throws {
    let host = try #require(
      try LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)

    // Deliberately asserted as absent first: the canvas needs the surface, so a host that has not
    // been asked for one has no editing layer, and that is the state the CLI and every headless
    // test stay in.
    #expect(host.editorCanvas == nil)
    _ = host.makeRenderSurface()
    #expect(host.editorCanvas != nil)
  }

  @Test("a click through the host's handler reaches the tool layer's selection")
  @MainActor
  func clickReachesTheToolSelection() throws {
    let (host, handler) = try makeHost()
    let circuit = try #require(host.currentCircuitObject)
    let canvas = try #require(host.editorCanvas)

    let gate = try AndGate.factory.createComponent(
      location: Location.create(120, 100, hasToSnap: false),
      attributes: AndGate.factory.createAttributeSet())
    try circuit.mutatorAdd(gate)
    canvas.setCircuit(circuit)

    // The startup tool is Poke, which does not select -- see `startupToolMatchesTheToolbar`.
    // Pick the tool a user would pick to select something.
    try host.perform(
      .selectTool(try #require(host.handles.tools.first { $0.value.name == BaseToolIds.edit }).key))
    let hit = interior(of: gate)
    handler.canvasHandlePointer(event(.down, hit.0, hit.1))

    // The TOOL layer's selection, not the host's; this is the half that used to be unreachable.
    #expect(canvas.selection.components.contains { $0 === gate })
  }

  @Test("and the host's own selection mirrors it, so the inspector follows")
  @MainActor
  func hostSelectionMirrorsTheToolLayer() throws {
    let (host, handler) = try makeHost()
    let circuit = try #require(host.currentCircuitObject)
    let canvas = try #require(host.editorCanvas)

    let gate = try OrGate.factory.createComponent(
      location: Location.create(160, 140, hasToSnap: false),
      attributes: OrGate.factory.createAttributeSet())
    try circuit.mutatorAdd(gate)
    canvas.setCircuit(circuit)

    try host.perform(
      .selectTool(try #require(host.handles.tools.first { $0.value.name == BaseToolIds.edit }).key))
    let hit = interior(of: gate)
    handler.canvasHandlePointer(event(.down, hit.0, hit.1))

    // Without the mirror the tool layer selects and the inspector shows nothing; two models that
    // are each individually correct and never speak.
    #expect(host.selection.componentIDs == [CircuitSceneSource.identity(of: gate)])
  }

  @Test("dropping a tool places THAT tool, not whichever was active")
  @MainActor
  func dropPlacesTheDroppedTool() throws {
    let (host, handler) = try makeHost()
    let circuit = try #require(host.currentCircuitObject)
    let canvas = try #require(host.editorCanvas)
    canvas.setCircuit(circuit)

    // Two different component tools. Select the first, then drop the SECOND, which is exactly
    // what `performDragOperation` does, and it never selects before dropping.
    let tools = host.handles.tools
    let andEntry = try #require(
      tools.first { ($0.value as? AddTool)?.factory is AndGate })
    let orEntry = try #require(
      tools.first { ($0.value as? AddTool)?.factory is OrGate })

    #expect(canvas.controller.setActiveTool(fromLibrary: andEntry.value))

    let before = circuit.components.count
    handler.canvasDropTool(orEntry.key, atWorldPoint: CGPoint(x: 300, y: 200))

    #expect(circuit.components.count == before + 1)
    let placed = try #require(circuit.components.last)
    // Routing the controller directly would place an AndGate here.
    #expect(placed.factory is OrGate, "dropped an OrGate and got \(type(of: placed.factory))")
  }

  @Test("the cursor comes from the active tool, not a three-case switch")
  @MainActor
  func cursorFollowsTheActiveTool() throws {
    let (host, handler) = try makeHost()
    let canvas = try #require(host.editorCanvas)

    canvas.controller.setActiveTool(WiringTool())
    let wiring = handler.canvasCursor(atWorldPoint: .zero)
    canvas.controller.setActiveTool(PokeTool())
    let poke = handler.canvasCursor(atWorldPoint: .zero)

    #expect(wiring == WiringTool().cursor)
    #expect(poke == PokeTool().cursor)
    #expect(wiring != poke)
  }

  @Test("the canvas starts on the toolbar's first tool, as Frame.java:227 does")
  @MainActor
  func startupToolMatchesTheToolbar() throws {
    let (host, _) = try makeHost()
    let canvas = try #require(host.editorCanvas)

    // `Frame.java:227` is `project.setTool(getOptions().getToolbarData().getFirstTool())` -- the
    // first tool of the TOOLBAR, not of the library's list. The default template's toolbar opens
    // with `Poke Tool`, so 4.1.0 starts in poke mode and so does this. Checked against the
    // template rather than asserted from memory: my first guess was the Edit tool, and it was
    // wrong.
    #expect(canvas.controller.activeTool is PokeTool)
    #expect(host.activeTool.flatMap { host.handles.tools[$0]?.name } == BaseToolIds.poke)
  }

  @Test("selecting a tool in the explorer changes what the canvas uses")
  @MainActor
  func explorerToolSelectionReachesTheCanvas() throws {
    let (host, _) = try makeHost()
    let canvas = try #require(host.editorCanvas)
    let wiring = try #require(
      host.handles.tools.first { $0.value.name == BaseToolIds.wiring })

    try host.perform(.selectTool(wiring.key))

    // The failure this pins: the toolbar highlight moves and the canvas keeps the old tool: the
    // two halves of "select a tool" agreeing on the model and disagreeing on the input.
    #expect(canvas.controller.activeTool is WiringTool)
  }
}
