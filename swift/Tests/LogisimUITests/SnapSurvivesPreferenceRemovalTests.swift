// SnapSurvivesPreferenceRemovalTests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// REMOVING A CONTROL CALLED "SNAP TO THE GRID" MUST NOT REMOVE SNAPPING.
//
// The port carried an `EditorPreferences.snapToGrid` checkbox. It is being deleted, along with
// the shell machinery behind it, because 4.1.0 has no such preference and because the control
// was inert. This file is the assertion that the *behaviour* the deleted control was named
// after is still there. It is the one thing that could have gone wrong, and it is what a
// reviewer should look at first.
//
// **The first four tests were written and run BEFORE the deletion, and their assertions have not
// changed since.** That is the whole design: a test whose expectations had to be edited to keep
// passing would prove nothing. Their `#expect` bodies are byte-identical to the version that ran
// green against the preference-bearing build; the only later edits to them were the removal of a
// now-impossible helper and this paragraph, both forced by `CanvasPointerEvent` losing a field.
//
// The fifth, `explorerDropAgreesWithAClickAtTheSamePoint`, was added AFTER, and deliberately so;
// it covers a defect the deletion fixed rather than a behaviour the deletion had to preserve, so
// it could not have been green beforehand. Its own doc comment says how it was found.
//
// ── WHY A DELETED PREFERENCE COULD PLAUSIBLY HAVE TAKEN SNAPPING WITH IT ────────────────────
//
// `CanvasHostNSView.snapped(_:)` really did compute a snapped point, really was gated on the
// preference, and really was passed onward: as `CanvasPointerEvent.snappedWorld` on every
// pointer event, and as the *actual world point* on the explorer drag-and-drop path
// (`performDragOperation`). Deleting the gate is therefore not obviously a no-op from outside.
// What makes it safe is that the tool layer snaps for itself with `CanvasGrid.snapXToGrid`:
// upstream's `Canvas.snapXToGrid`, integer arithmetic, pinned against the shipped jar by
// `GridSnapParityTests`.
//
// The earlier version of this file fed each pointer event a deliberately WRONG precomputed
// `snappedWorld` (the shell's continuous rule, which answers 100 where upstream answers 110) so
// that a tool consulting it would fail here. That field no longer exists on the seam, so the
// adversarial input can no longer be constructed; the claim is now enforced by the type system
// instead, which is why the helper that built it is gone rather than kept as scaffolding.
//
// ── 4.1.0, MEASURED, NOT REMEMBERED ─────────────────────────────────────────────────────────
//
// Artifact: /Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar.
//
//   * `javap -c com.cburch.logisim.gui.main.Canvas`; `snapToGrid(java.awt.event.MouseEvent)`
//     is 33 bytecodes with NO branch: getX, getY, snapXToGrid, snapYToGrid, translatePoint,
//     return. It reads no `PrefMonitor` and consults no preference. Snapping is unconditional.
//   * `javap com.cburch.logisim.prefs.AppPreferences`; the only grid-related monitors are
//     `LAYOUT_SHOW_GRID`, `APPEARANCE_SHOW_GRID`, `GRID_BG_COLOR`, `GRID_DOT_COLOR` and
//     `GRID_ZOOMED_DOT_COLOR`. Grid *display* is a preference; grid *snapping* is not.
//   * `resources/logisim/strings/gui/gui.properties` inside the same jar: zero occurrences of
//     "snap", case-insensitive. The five "grid" strings are `zoomShowGrid` and four colour
//     labels. There is no string for a snap checkbox because there is no checkbox.
//
// ── WHAT EACH TEST BELOW IS FOR ─────────────────────────────────────────────────────────────
//
// The entry points that can put a coordinate into a saved file are covered separately, because
// they reach the snap by different call paths and a regression could take any one of them alone:
//
//   click to place  → `CanvasInteractionHandler.canvasHandlePointer` → `CanvasAddTool`
//   explorer drop   → `CanvasInteractionHandler.canvasDropTool`      → `CanvasAddTool`
//   wire drag       → `canvasHandlePointer`                          → `WiringTool`
//   AppKit drop     → `CanvasHostNSView.performDragOperation`        → the two above it
//
// The last is one level further out than the others and is the only place in the suite that
// drives the host view itself. It is separate from the `canvasDropTool` row above it for a
// reason worth keeping: that row enters BELOW the shell, so it stayed green through the very
// defect this change fixed.
//
// Every assertion is stated twice on purpose: once as "on a multiple of ten" (the property the
// deleted control was named after) and once as the exact `Location` the jar's arithmetic gives,
// so that a port snapping to the *wrong* grid line could not pass by snapping to some grid line.
//
// 104.6 is deliberate. It sits in the half-unit band [104.5, 105.0) where upstream's
// integerise-then-snap answers 110 and the naive continuous rule answers 100; see
// `GridSnapParityTests.continuousWorldRoundingIsNotUpstreamsRuleAndTheBandIsHalfAUnitWide`.
// Any point outside that band would let a wrong implementation pass.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import AppKit
import CoreGraphics
import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd
import Testing

@testable import LogisimUI

@Suite("Snapping survives the removal of the snap preference", .serialized)
struct SnapSurvivesPreferenceRemovalTests {

  @MainActor
  private func makeHost() throws -> (
    LogisimFileProjectHost, any CanvasInteractionHandler, Circuit, CircuitEditorCanvas
  ) {
    let host = try #require(
      try LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
    _ = host.makeRenderSurface()
    let handler = try #require(host.interactionHandler)
    let circuit = try #require(host.currentCircuitObject)
    let canvas = try #require(host.editorCanvas)
    canvas.setCircuit(circuit)
    return (host, handler, circuit, canvas)
  }

  /// A press/release at one world point, exactly as `CanvasHostNSView` delivers it.
  @MainActor
  private func click(_ handler: any CanvasInteractionHandler, at world: CGPoint) {
    for phase in [CanvasPointerEvent.Phase.moved, .down, .up] {
      handler.canvasHandlePointer(
        CanvasPointerEvent(
          phase: phase,
          world: world,
          modifiers: [],
          clickCount: 1,
          buttonNumber: 1,
          dragOriginWorld: nil))
    }
  }

  @MainActor
  private func drag(
    _ handler: any CanvasInteractionHandler, from start: CGPoint, to end: CGPoint
  ) {
    handler.canvasHandlePointer(
      CanvasPointerEvent(
        phase: .down, world: start, modifiers: [],
        clickCount: 1, buttonNumber: 1, dragOriginWorld: nil))
    for phase in [CanvasPointerEvent.Phase.dragged, .up] {
      handler.canvasHandlePointer(
        CanvasPointerEvent(
          phase: phase, world: end, modifiers: [],
          clickCount: 1, buttonNumber: 1, dragOriginWorld: start))
    }
  }

  private func isOnGrid(_ value: Int) -> Bool { value % 10 == 0 }

  // ── click to place ─────────────────────────────────────────────────────────────────────────

  /// The main path. A user picks a component and clicks somewhere off-grid.
  @Test("a component clicked in at an off-grid point lands on the 10-unit grid")
  @MainActor
  func clickedComponentLandsOnTheGrid() throws {
    let (_, handler, circuit, canvas) = try makeHost()
    canvas.controller.setActiveTool(CanvasAddTool(factory: AndGate.factory))

    click(handler, at: CGPoint(x: 104.6, y: 97.3))

    let placed = try #require(circuit.nonWires.first { $0.factory is AndGate })
    #expect(isOnGrid(placed.location.x), "x = \(placed.location.x) is off the 10 grid")
    #expect(isOnGrid(placed.location.y), "y = \(placed.location.y) is off the 10 grid")
    // And on the *right* grid line: 104.6 -> 105 -> 110, not the 100 the shell precomputed.
    #expect(placed.location == Location.create(110, 100, hasToSnap: false))
  }

  /// A sweep rather than a single point, so that a snap which happened to be right at 104.6 and
  /// wrong elsewhere cannot pass. Each gate goes into its own column so they cannot overlap.
  ///
  /// The tool is re-selected before every click on purpose, and that is not test scaffolding: it
  /// is what a user does. `AddTool.mouseReleased` ends with `determineNext(Project)`, upstream's
  /// `ADD_AFTER` behaviour, which switches the project back to the edit tool after a successful
  /// placement. Written without the re-selection this test placed one gate out of twelve, which
  /// is the correct behaviour and a wrong test.
  @Test("every off-grid click in a sweep lands on a multiple of ten")
  @MainActor
  func sweptClicksAllLandOnTheGrid() throws {
    let (_, handler, circuit, canvas) = try makeHost()

    // Fractional offsets straddling both the .5 integerisation threshold and the half-grid point.
    let offsets: [Double] = [0.1, 0.49, 0.5, 0.51, 0.9, 4.4, 4.5, 4.6, 5.0, 5.4, 9.5, 9.9]
    for (index, offset) in offsets.enumerated() {
      canvas.controller.setActiveTool(CanvasAddTool(factory: AndGate.factory))
      click(handler, at: CGPoint(x: Double(200 + index * 100) + offset, y: 200 + offset))
    }

    let placed = circuit.nonWires.filter { $0.factory is AndGate }
    #expect(placed.count == offsets.count, "placed \(placed.count) of \(offsets.count)")
    var offGrid: [String] = []
    for gate in placed where !isOnGrid(gate.location.x) || !isOnGrid(gate.location.y) {
      offGrid.append("\(gate.location)")
    }
    #expect(offGrid.isEmpty, "off the grid: \(offGrid)")
  }

  // ── explorer drag and drop ─────────────────────────────────────────────────────────────────

  /// The second placement path. This one is not merely advisory in the shell: before this change
  /// `performDragOperation` passed `snapped(...)`'s output as the drop point *itself*, so the
  /// shell's wrong rule was the one that decided where an explorer drop landed. Removing the
  /// function hands the raw world point through and the drop snaps like a click does.
  @Test("a tool dropped from the explorer at an off-grid point lands on the 10-unit grid")
  @MainActor
  func droppedToolLandsOnTheGrid() throws {
    let (host, handler, circuit, _) = try makeHost()
    let andEntry = try #require(
      host.handles.tools.first { ($0.value as? AddTool)?.factory is AndGate })

    handler.canvasDropTool(andEntry.key, atWorldPoint: CGPoint(x: 104.6, y: 97.3))

    let placed = try #require(circuit.nonWires.first { $0.factory is AndGate })
    #expect(isOnGrid(placed.location.x), "x = \(placed.location.x) is off the 10 grid")
    #expect(isOnGrid(placed.location.y), "y = \(placed.location.y) is off the 10 grid")
    #expect(placed.location == Location.create(110, 100, hasToSnap: false))
  }

  /// One level further out than the test above, and the only test in the repository that drives
  /// `CanvasHostNSView.performDragOperation`; the AppKit method that actually receives an
  /// explorer drop.
  ///
  /// It exists because the test above turned out to be a passing probe that measured nothing
  /// about the change being made: it calls `canvasDropTool` directly, so it stayed green whether
  /// or not the shell pre-snapped, and the shell's pre-snap was the defect. The deleted
  /// `snapped(_:)` was NOT dead on this path, its output was the drop point itself, so removing
  /// it changes where a dropped component lands, and until this test nothing in the suite would
  /// have noticed either the bug or the fix.
  ///
  /// Asserted as an EQUIVALENCE rather than a literal coordinate. The view-to-window conversion
  /// on a windowless `NSView` is AppKit's business, not this change's, so pinning a number here
  /// would pin the wrong thing; what the fix guarantees is that a drop and a click at the same
  /// place agree. Before it they disagreed by a full grid step for any point in the half-unit
  /// band [4.5, 5.0) of a cell; 104.6 dropped at 100 and clicked at 110.
  @Test("an explorer drop lands where a click at the same point lands")
  @MainActor
  func explorerDropAgreesWithAClickAtTheSamePoint() throws {
    let viewPoint = CGPoint(x: 104.6, y: 97.3)

    // Half one: the real AppKit drop path.
    let (dropHost, _, dropCircuit, dropCanvas) = try makeHost()
    let andEntry = try #require(
      dropHost.handles.tools.first { ($0.value as? AddTool)?.factory is AndGate })

    let view = CanvasHostNSView()
    view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    let shell = ShellStub(
      surface: dropCanvas.surface,
      interactionHandler: try #require(dropHost.interactionHandler))
    view.delegate = shell

    let pasteboard = NSPasteboard(name: NSPasteboard.Name("logisim.droptest.\(UUID())"))
    pasteboard.declareTypes([.logisimTool], owner: nil)
    pasteboard.setString(String(andEntry.key.rawValue), forType: .logisimTool)

    #expect(view.performDragOperation(DraggingInfoStub(point: viewPoint, board: pasteboard)))
    let dropped = try #require(dropCircuit.nonWires.first { $0.factory is AndGate }).location

    // Half two: a click at the world point that same view point maps to.
    let world = shell.viewport.viewToWorld(view.convert(viewPoint, from: nil))

    // Guard against this test quietly becoming vacuous. The two rules only disagree when the
    // world coordinate falls in the [4.5, 5.0) band of its 10-unit cell; anywhere else a drop and
    // a click would agree even with the bug present, and the assertion below would pass for the
    // wrong reason. If AppKit's windowless view conversion ever shifts, this says so.
    let cellOffset = world.x - (world.x / 10).rounded(.down) * 10
    #expect(
      cellOffset >= 4.5 && cellOffset < 5.0,
      """
      world x \(world.x) sits at cell offset \(cellOffset), outside the [4.5, 5.0) band where \
      the shell's old rule and upstream's disagree — this test could no longer detect the defect
      """)

    let (_, clickHandler, clickCircuit, clickCanvas) = try makeHost()
    clickCanvas.controller.setActiveTool(CanvasAddTool(factory: AndGate.factory))
    click(clickHandler, at: world)
    let clicked = try #require(clickCircuit.nonWires.first { $0.factory is AndGate }).location

    #expect(dropped == clicked, "drop landed at \(dropped), click at \(clicked)")
    #expect(isOnGrid(dropped.x) && isOnGrid(dropped.y), "drop landed off-grid at \(dropped)")
  }

  // ── wires ──────────────────────────────────────────────────────────────────────────────────

  /// The owner's sentence for this change was "we basically just conform it to the grid anyhow,
  /// it's not freehand wires". This is that sentence as an assertion: a wire dragged between two
  /// off-grid points has both endpoints on the grid.
  @Test("a wire dragged between off-grid points has both ends on the 10-unit grid")
  @MainActor
  func draggedWireEndsOnTheGrid() throws {
    let (_, handler, circuit, canvas) = try makeHost()
    canvas.controller.setActiveTool(WiringTool())

    drag(handler, from: CGPoint(x: 104.6, y: 97.3), to: CGPoint(x: 247.4, y: 97.3))

    let wires = circuit.wires
    #expect(!wires.isEmpty, "no wire was created, so nothing was measured")
    var offGrid: [String] = []
    for wire in wires {
      for point in [wire.end0, wire.end1] where !isOnGrid(point.x) || !isOnGrid(point.y) {
        offGrid.append("\(point)")
      }
    }
    #expect(offGrid.isEmpty, "wire endpoints off the grid: \(offGrid)")

    // The exact line, not merely "some grid line": 104.6 -> 110, 247.4 -> 250, 97.3 -> 100.
    let ends = Set(wires.flatMap { [$0.end0, $0.end1] })
    #expect(ends.contains(Location.create(110, 100, hasToSnap: false)))
    #expect(ends.contains(Location.create(250, 100, hasToSnap: false)))
  }
}

// MARK: - The two stubs `performDragOperation` needs
//
// `CanvasHostNSView` is only reachable through its delegate and an `NSDraggingInfo`, and neither
// had a test double anywhere in the suite, which is the mechanical reason the drop path had no
// coverage. Both stubs are inert: the point is to let the real `performDragOperation` run, not to
// simulate AppKit.

/// The minimum `CanvasHostDelegate` that lets a drop through: a real surface, a real interaction
/// handler, and an identity viewport. Everything else answers a default, because
/// `performDragOperation` reads only `viewport` and `interactionHandler`.
@MainActor
private final class ShellStub: CanvasHostDelegate {
  let surface: any CircuitRenderSurface
  let interactionHandler: (any CanvasInteractionHandler)?
  /// Centred away from the origin on purpose. With `center: .zero` a drop in the top-left of an
  /// 800x600 view maps to a negative world x, and `AddTool.performPlacement` refuses to place a
  /// component whose bounds would start at a negative coordinate, so the test would fail with
  /// "nothing was placed" for a reason that has nothing to do with snapping.
  var viewport = CanvasViewport(
    zoom: 1, center: CGPoint(x: 500, y: 500), viewSize: CGSize(width: 800, height: 600))
  var appearanceTemplate = CanvasAppearance()
  var zoomAnchorsAtPointer = true
  var scrollPans = true
  var invertsScrollDirection = false
  var panSensitivity: Double = 1
  var zoomSensitivity: Double = 1

  init(surface: any CircuitRenderSurface, interactionHandler: any CanvasInteractionHandler) {
    self.surface = surface
    self.interactionHandler = interactionHandler
  }

  func canvasHostDidChangeViewport() {}
  func canvasHostDidHover(_ target: CanvasHitTarget?, atWorld point: CGPoint) {}
  func canvasHostContextMenu(for target: CanvasHitTarget?) -> NSMenu { NSMenu() }
  func canvasHostDidBecomeKey() {}
  func canvasHostZoomToFit() {}
}

/// `NSDraggingInfo` is a protocol, so it can be conformed to. Only `draggingLocation` and
/// `draggingPasteboard` are ever read by the method under test; the rest of the protocol is
/// answered with whatever compiles and is never consulted.
@MainActor
private final class DraggingInfoStub: NSObject, @MainActor NSDraggingInfo {
  let draggingLocation: NSPoint
  let draggingPasteboard: NSPasteboard

  init(point: NSPoint, board: NSPasteboard) {
    self.draggingLocation = point
    self.draggingPasteboard = board
  }

  var draggingDestinationWindow: NSWindow? { nil }
  var draggingSourceOperationMask: NSDragOperation { .copy }
  var draggedImageLocation: NSPoint { draggingLocation }
  var draggedImage: NSImage? { nil }
  var draggingSource: Any? { nil }
  var draggingSequenceNumber: Int { 0 }
  var animatesToDestination: Bool = false
  var numberOfValidItemsForDrop: Int = 1
  var draggingFormation: NSDraggingFormation = .default
  var springLoadingHighlight: NSSpringLoadingHighlight { .none }
  func slideDraggedImage(to screenPoint: NSPoint) {}
  func resetSpringLoading() {}
  func enumerateDraggingItems(
    options enumOpts: NSDraggingItemEnumerationOptions,
    for view: NSView?,
    classes classArray: [AnyClass],
    searchOptions: [NSPasteboard.ReadingOptionKey: Any],
    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
  ) {}
}
