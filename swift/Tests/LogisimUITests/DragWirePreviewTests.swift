// DragWirePreviewTests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16), disassembled from
// /Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// "ON THE DRAG, THE WIRES FLICKER BETWEEN LAST POSITION AND WHERE IT SHOULD BE"
//
// Reported from real use. Dragging a component that has wires attached makes the attached wires
// alternate between two pictures, frame to frame.
//
// THE TWO PICTURES, AND WHY THEY ALTERNATE. `SelectTool` asks the move engine for a rerouted
// preview through `MoveGesture.findResult(dx:dy:)`, which is a **pure cache lookup**; it answers
// nil for every delta the background `ConnectorThread` has not finished computing. Two separate
// call sites branch on that nil, and they move together:
//
//   * `overlay(for:)` draws the proposed wires only on a hit;
//   * `hiddenComponents(for:)` hides the wires the reroute would remove only on a hit.
//
// So a hit frame draws "where it should be" (old wires suppressed, rerouted wires painted) and a
// miss frame draws "last position" (old wires back, nothing painted). That is not a smear, it is
// a clean two-state flip; exactly the word "flicker" in the report.
//
// The alternation is driven by grid snap. `computeDxDy` snaps the *delta*, so a pointer crossing
// the canvas emits many events per grid step: most repeat the previous delta and hit the cache,
// and every grid crossing is a fresh delta that misses it. `measureFlicker` below drives exactly
// that pattern and records the per-frame counts.
//
// WHAT UPSTREAM 4.1.0 DOES: CHECKED IN THE BYTECODE, NOT ASSUMED. In
// `com.cburch.logisim.tools.SelectTool.draw`, offset 71 calls `MoveGesture.findResult`, and
// offsets 76-78 are `aload 7; ifnull 286`; a null jumps clean past every `drawLine` and every
// `fillOval`. `getHiddenComponents` does the same at offsets 59-66: `ifnull 97`, which returns
// just the selection and leaves the removals on screen. And `MoveGesture.findResult` really is
// only `monitorenter; HashMap.get; monitorexit; areturn` (offsets 11-33): no wait, no fallback.
//
// So **upstream blanks the preview too**, and holding the last result is a deliberate
// DIVERGENCE, not parity. What hides it upstream is the paint rate: `CanvasPaintCoordinator`'s
// `REPAINT_TIMESPANS` is `{47, 53, 49, 51, 50, 47, 53, 50, 48, 52}` milliseconds, a jittered
// ~20 fps ceiling, so a miss usually resolves inside a frame that is never painted. This port
// repaints per event, so every miss is a frame the user sees.
//
// THE SECOND DEFECT, WHICH IS PORT-ONLY. When the connector finally answers,
// `SelectTool`'s listener called `clearComputingMessage`, whose `canvas.repaintAll()` invalidates
// the view but does **not** rebuild `ToolOverlay`; that only happens on a pointer/key event or a
// `.repaintRequest`. Upstream's `Canvas.repaint()` re-enters `Tool.draw` during paint, so the
// fresh result appears immediately there. Here it stayed invisible until the user moved again,
// which both lengthens every blank frame and leaves a paused drag showing a stale preview
// forever. The `Project.repaintCanvas()` in `SelectTool.makeMoveListener` is the parity fix;
// `previewOutlivesAPausedDrag` gates it.
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

/// A gate with a wire running out of every one of its ends, which is the smallest circuit for
/// which the move engine has anything to reroute: `MoveGesture.computeConnections` only records a
/// connection at a point where the moving selection touches a component that is **staying put**.
@MainActor
private struct PreviewRig {
  let host: LogisimFileProjectHost
  let project: Project
  let circuit: Circuit
  let surface: CircuitCanvasSurface
  let canvas: CircuitEditorCanvas
  let select: SelectTool
  let gate: any Component

  /// `tailLength` is generous on purpose. A drag that runs the gate all the way to the far end of
  /// its tail produces a reroute with **no** removals, a legitimate result that hides only the
  /// selection, and `removalsStayHiddenMidDrag` would then have to tell that apart from the bug.
  /// Long tails keep every reroute in the run a genuine replacement.
  init(tailLength: Int = 200) throws {
    StdLibraries.registerAll()
    let made = try LogisimFileProjectHostFactory().makeEmptyProject()
    host = try #require(made as? LogisimFileProjectHost)
    project = host.project
    circuit = try #require(host.currentCircuitObject)
    surface = try #require(host.makeRenderSurface() as? CircuitCanvasSurface)

    let component = try AndGate.factory.createComponent(
      location: Location.create(200, 200, hasToSnap: false),
      attributes: AndGate.factory.createAttributeSet())
    try circuit.mutatorAdd(component)
    gate = component

    // A straight tail off each end, pointing away from the gate's own anchor so the wires never
    // run through the body. These are the wires the report is about.
    for end in component.ends {
      let point = end.location
      let sign = point.x <= component.location.x ? -1 : 1
      try circuit.mutatorAdd(
        Wire.create(point, Location.create(point.x + sign * tailLength, point.y, hasToSnap: false)))
    }

    select = SelectTool()
    select.keepsConnectionsWhenMoving = true
    canvas = CircuitEditorCanvas(
      project: project, surface: surface, circuit: circuit, initialTool: select)
    surface.renderView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    surface.setViewport(
      CanvasViewport(
        zoom: 1.0, center: CGPoint(x: 300, y: 250),
        viewSize: CGSize(width: 800, height: 600)))
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

  /// A point the gate itself reports as inside it: `mousePressed` branches on
  /// `Circuit.allContaining`, and a point the gate rejects starts a marquee instead of a move.
  var grabPoint: Location {
    let box = gate.bounds
    for dy in stride(from: 0, through: box.height, by: 1) {
      for dx in stride(from: 0, through: box.width, by: 1) {
        let point = Location.create(box.x + dx, box.y + dy, hasToSnap: false)
        if gate.contains(point) { return point }
      }
    }
    return gate.location
  }

  /// One sampled frame: what the tool asked for, and what the canvas ended up holding.
  var sample: Frame {
    let overlay = canvas.toolOverlay
    var proposed = 0
    var ghostDelta = (dx: 0, dy: 0)
    for item in overlay.items {
      switch item {
      case .proposedWire: proposed += 1
      case .selectionGhost(let dx, let dy): ghostDelta = (dx, dy)
      default: break
      }
    }
    let fresh =
      select.moveGesture?.findResult(dx: select.currentDx, dy: select.currentDy) != nil
    return Frame(
      dx: ghostDelta.dx, dy: ghostDelta.dy, cacheHit: fresh, proposedWires: proposed,
      hidden: overlay.hiddenComponents.count)
  }

  /// Yields to the connector thread until it has answered for the delta the pointer is sitting
  /// at, re-issuing the *same* drag event each time round.
  ///
  /// The re-issue is not padding. `ConnectorThread` is one global thread with a **single**
  /// pending slot and latest-wins semantics, so a request can be dropped outright by any other
  /// drag: another test running in parallel, or the next frame of this one. Polling `findResult`
  /// without re-enqueuing therefore waits forever on a request nobody is going to compute. A real
  /// mouse re-enqueues constantly, because a hand holding still still jitters.
  @discardableResult
  func settle(at point: (Int, Int), upTo seconds: Double = 10.0) async -> Bool {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while Date() < deadline {
      if sample.cacheHit { return true }
      try? await Task.sleep(nanoseconds: 2_000_000)
      pointer(.dragged, point.0, point.1)
    }
    return sample.cacheHit
  }
}

private struct Frame {
  var dx: Int
  var dy: Int
  var cacheHit: Bool
  var proposedWires: Int
  var hidden: Int
}

private func table(_ label: String, _ frames: [Frame]) -> String {
  var lines = ["[\(label)]  delta      findResult  proposedWires  hidden"]
  for frame in frames {
    lines.append(
      "          (\(frame.dx),\(frame.dy))".padding(toLength: 22, withPad: " ", startingAt: 0)
        + (frame.cacheHit ? "hit " : "MISS")
        + "        \(frame.proposedWires)"
        + "              \(frame.hidden)")
  }
  return lines.joined(separator: "\n")
}

// MARK: - The measurement

/// Drives one press plus a run of drags and samples every frame.
///
/// Two knobs, and both matter to what the table shows.
///
/// The pointer advances in **2-unit steps** on a 10-unit grid, which is what a real mouse does:
/// four frames out of five repeat the previous snapped delta and hit the cache, and every fifth
/// crosses a grid line and misses it.
///
/// `pacingMillis` is the gap between events. At the default 8 ms, a 120 Hz mouse, the connector
/// gets to answer most deltas, so the run *alternates*: a fresh delta blanks the preview and the
/// repeats behind it bring it back. That is the picture the report describes. At 0 the events
/// outrun the connector completely and every frame after the first is blank, which is the same
/// defect with the throttle removed.
///
/// The one wait is `settle`, before any frame is recorded: without a first answer there is
/// nothing to hold, so a run that never got one would prove nothing either way.
@MainActor
private func measureFlicker(steps: Int = 14, pacingMillis: UInt64 = 8) async throws -> [Frame] {
  let rig = try PreviewRig()
  let grab = rig.grabPoint
  rig.pointer(.down, grab.x, grab.y)

  rig.pointer(.dragged, grab.x + 12, grab.y)
  let warmedUp = await rig.settle(at: (grab.x + 12, grab.y))
  try #require(warmedUp, "the connector never answered even one request; nothing below can hold")
  // One more event at the same place, so the first recorded frame is one the overlay was rebuilt
  // for *after* the answer landed rather than in the same microsecond.
  rig.pointer(.dragged, grab.x + 12, grab.y)

  var frames: [Frame] = [rig.sample]
  for step in 1...steps {
    if pacingMillis > 0 {
      try? await Task.sleep(nanoseconds: pacingMillis * 1_000_000)
    }
    rig.pointer(.dragged, grab.x + 12 + 2 * step, grab.y)
    frames.append(rig.sample)
  }
  rig.pointer(.up, grab.x + 12 + 2 * steps, grab.y)
  return frames
}

/// `.serialized` because `ConnectorThread` is a **process-wide singleton with one pending slot**.
/// Two of these tests dragging at once do not merely slow each other down, they delete each
/// other's requests, and a starved rig measures nothing.
@Suite("Drag wire preview — the flicker", .serialized)
struct DragWirePreviewTests {

  /// **The measurement the fix is built on.** Fails loudly if the rig stops exercising the thing
  /// it claims to: no reroute at all, or a drag that never misses the cache, would make every
  /// assertion below vacuous.
  @Test("the drag really does reroute, and really does miss the connector cache")
  @MainActor
  func theRigExercisesTheCache() async throws {
    let frames = try await measureFlicker()
    let report = table("flicker", frames)

    #expect(
      frames.contains { $0.cacheHit },
      "no frame hit the connector cache — the rig is not exercising the move engine.\n\(report)")
    #expect(
      frames.contains { !$0.cacheHit },
      """
      every frame hit the connector cache, so this run cannot say anything about a miss. \
      Slow the pointer down or enlarge the circuit.
      \(report)
      """)
  }

  /// **The gate.** Once the connector has produced one answer for this gesture, no later frame of
  /// the same drag may fall back to drawing nothing.
  ///
  /// Race-free in the passing direction: the preview is non-empty whether the frame hit the cache
  /// or fell back to the held result. Pre-fix it is red at every missed frame, and
  /// `theRigExercisesTheCache` is what guarantees there are some.
  @Test("the preview never blanks once the connector has answered once")
  @MainActor
  func previewNeverBlanksMidDrag() async throws {
    let frames = try await measureFlicker()
    let blank = frames.filter { $0.proposedWires == 0 }
    #expect(
      blank.isEmpty,
      """
      \(blank.count) of \(frames.count) frames drew no proposed wire — that is the flicker.
      \(table("flicker", frames))
      """)
  }

  /// The other half of the same flip. A miss used to un-hide the wires the reroute removes, so
  /// the blank frames were not merely empty; they put the *old* wires back, which is what makes
  /// the report say "between last position and where it should be" rather than "blinks out".
  @Test("the wires being replaced stay hidden across a missed frame")
  @MainActor
  func removalsStayHiddenMidDrag() async throws {
    let frames = try await measureFlicker()
    let report = table("flicker", frames)

    // The precondition, asserted rather than assumed: every reroute in this run replaces a wire,
    // so "hides only the selection" can only mean the preview was dropped. A reroute with no
    // removals is a real thing, see `PreviewRig.tailLength`, and it would make the claim below
    // ambiguous, so it fails here, loudly, as a rig fault.
    try #require(
      frames.filter(\.cacheHit).allSatisfy { $0.hidden >= 2 },
      "rig: a computed reroute removed no wire, so `hidden == 1` is no longer diagnostic.\n\(report)"
    )

    let dropped = frames.filter { $0.hidden < 2 }
    #expect(
      dropped.isEmpty,
      """
      \(dropped.count) of \(frames.count) frames hid only the selection, so the wires the reroute \
      replaces flicked back into view — this is the "last position" half of the report.
      \(report)
      """)
  }

  /// The same claim with the throttle off. A pointer that outruns the connector entirely, a big
  /// circuit, a slow machine, a fast hand, must degrade to "the preview lags", never to "the
  /// preview is gone".
  @Test("the preview survives a burst of deltas the connector never catches up with")
  @MainActor
  func previewNeverBlanksUnderABurst() async throws {
    let frames = try await measureFlicker(steps: 24, pacingMillis: 0)
    let blank = frames.filter { $0.proposedWires == 0 }
    #expect(
      blank.isEmpty,
      """
      \(blank.count) of \(frames.count) frames drew no proposed wire.
      \(table("burst", frames))
      """)
  }

  /// Defect two, and it is this port's alone: the connector's answer landed in the cache but
  /// nothing rebuilt the overlay, so a drag the user pauses kept showing the previous frame.
  /// Measured without touching the pointer after the wait; only `.repaintRequest` may deliver it.
  @Test("a paused drag picks up the answer the connector finished while it was still")
  @MainActor
  func previewOutlivesAPausedDrag() async throws {
    let rig = try PreviewRig()
    let grab = rig.grabPoint
    rig.pointer(.down, grab.x, grab.y)
    // One event, at a delta nothing has computed yet, and then no more events at all: this is a
    // drag the user has paused. `forceRequest` jumps `ConnectorThread`'s queue, so the answer
    // exists whatever else the process is dragging; the only question is whether it reaches the
    // canvas without another pointer event.
    rig.pointer(.dragged, grab.x + 37, grab.y + 23)
    let gesture = try #require(rig.select.moveGesture)
    _ = gesture.forceRequest(dx: rig.select.currentDx, dy: rig.select.currentDy)

    let deadline = Date(timeIntervalSinceNow: 3.0)
    while Date() < deadline, rig.canvas.toolOverlay.items.allSatisfy({ !$0.isProposedWire }) {
      try? await Task.sleep(nanoseconds: 5_000_000)
    }

    #expect(
      rig.canvas.toolOverlay.items.contains { $0.isProposedWire },
      """
      the overlay still holds no proposed wire three seconds after a single drag event. The \
      connector's result never reached the canvas, because `repaintAll` redraws the overlay the \
      last event built rather than rebuilding it.
      """)
    rig.pointer(.up, grab.x + 37, grab.y + 23)
  }
}

// MARK: - Clearing

/// The held preview is the tool remembering something across frames, and a preview that outlives
/// its drag is a worse bug than the flicker it replaces. Three things must make it forget.
@Suite("Drag wire preview — what clears the held result", .serialized)
struct DragWirePreviewClearingTests {

  /// Drags to a delta, waits for a real result, and hands back the rig mid-gesture, so there is
  /// something held for each test below to demand the removal of.
  @MainActor
  private static func armed() async throws -> (rig: PreviewRig, grab: Location, to: (Int, Int)) {
    let rig = try PreviewRig()
    let grab = rig.grabPoint
    let to = (grab.x + 20, grab.y + 10)
    rig.pointer(.down, grab.x, grab.y)
    rig.pointer(.dragged, to.0, to.1)
    let warmedUp = await rig.settle(at: to)
    try #require(warmedUp, "the rig never got a first result to hold")
    try #require(rig.select.isHoldingPreviewForTesting, "nothing was held to begin with")
    return (rig, grab, to)
  }

  /// Released **back where the drag started**, so the delta is zero.
  ///
  /// This shape is deliberate and it took a red probe to find. Releasing after a real move is not
  /// a test of `mouseReleased`'s clear at all: the commit translates the selection, that fires
  /// `selectionChanged`, and *that* clear does the work; deleting the line in `mouseReleased`
  /// reddens nothing. A zero-delta release skips `commitMove` entirely, so nothing else can fire,
  /// and it is a real gesture: dragging something and putting it back.
  @Test("releasing the mouse drops it, even when the drag committed nothing")
  @MainActor
  func releaseClears() async throws {
    let (rig, grab, _) = try await Self.armed()
    rig.pointer(.dragged, grab.x, grab.y)
    rig.pointer(.up, grab.x, grab.y)
    #expect(rig.select.moveGesture == nil)
    #expect(!rig.select.isHoldingPreviewForTesting)
    #expect(!rig.canvas.toolOverlay.items.contains { $0.isProposedWire })
  }

  /// The ordinary case, which the clear above happens not to be the only guard for; see its
  /// note. Gated separately so that removing either guard leaves the other's claim standing.
  @Test("a drag that really moves something drops it too")
  @MainActor
  func committedReleaseClears() async throws {
    let (rig, _, to) = try await Self.armed()
    rig.pointer(.up, to.0, to.1)
    #expect(rig.select.moveGesture == nil)
    #expect(!rig.select.isHoldingPreviewForTesting)
    #expect(!rig.canvas.toolOverlay.items.contains { $0.isProposedWire })
  }

  @Test("switching tools drops it")
  @MainActor
  func deselectClears() async throws {
    let (rig, _, _) = try await Self.armed()
    rig.select.deselect(rig.canvas)
    #expect(rig.select.moveGesture == nil)
    #expect(!rig.select.isHoldingPreviewForTesting)
    #expect(rig.select.overlay(for: rig.canvas).items.allSatisfy { !$0.isProposedWire })
  }

  @Test("changing the selection drops it")
  @MainActor
  func selectionChangeClears() async throws {
    let (rig, _, _) = try await Self.armed()
    rig.select.selectionChanged(rig.canvas.selection)
    #expect(!rig.select.isHoldingPreviewForTesting)
  }

  /// The next drag must start from nothing. `mousePressed` clears the box, and `previewResult`
  /// keys on gesture identity as well, so even a clear that was missed could not put the previous
  /// drag's reroute on screen under a new one.
  @Test("a held result cannot leak into the next drag")
  @MainActor
  func heldResultIsKeyedToItsGesture() async throws {
    let (rig, _, to) = try await Self.armed()
    // Held strongly for the duration, so `heldPreviewGestureForTesting` reporting nil below means
    // "nothing is held", not "the gesture was deallocated".
    let first = try #require(rig.select.moveGesture)
    rig.pointer(.up, to.0, to.1)

    let moved = rig.grabPoint
    rig.pointer(.down, moved.x, moved.y)
    #expect(!rig.select.isHoldingPreviewForTesting)
    rig.pointer(.dragged, moved.x + 3, moved.y + 3)
    if let second = rig.select.moveGesture {
      #expect(second !== first, "the second press reused the first drag's gesture")
    }
    #expect(
      rig.select.heldPreviewGestureForTesting !== first,
      "the second drag is holding the first drag's reroute")
    rig.pointer(.up, moved.x + 3, moved.y + 3)
    _ = first
  }
}

extension ToolOverlayItem {
  fileprivate var isProposedWire: Bool {
    if case .proposedWire = self { return true }
    return false
  }
}
