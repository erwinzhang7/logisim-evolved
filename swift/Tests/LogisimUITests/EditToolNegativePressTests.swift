// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution, which is GPL-3.0-only. This port is a derivative work and is
// therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// A NEGATIVE COORDINATE IS A COORDINATE, NOT "NOTHING HAPPENED".
//
// ── Where this came from ────────────────────────────────────────────────────────────────────
//
// D19 removed the origin wall, so a circuit can now live left of and above the origin. That made
// live two sentinels in `EditTool` that had been harmless for as long as no pointer could reach a
// negative coordinate. Both are upstream's own idiom, and upstream is right to use it: its canvas
// is a `JScrollPane` viewport over a content-sized component, so `MouseEvent.getX()` is a pixel
// offset inside that component and is never negative. This port's camera is `(center, zoom)` and
// tools are handed *world* coordinates, which are signed.
//
//   * `isClick` (`EditTool.java:231-245`) read `pressX < 0` as "there was no press". A press at
//     x = −100 therefore could never be a click, and **clicking a wire left of the origin
//     selected nothing at all**; the click-to-select replay (`EditTool.java:393-400`) is what
//     selects a wire, and it only runs for a click.
//   * `updateLocation(Canvas, KeyEvent)` (`EditTool.java:485-492`) read `lastRawX < 0` as "the
//     pointer position is not known yet". With the pointer left of the origin the wiring
//     indicator therefore stopped tracking: neither the Option override nor a circuit or
//     selection change could recompute it, so it froze wherever it last was.
//
// ── What these tests assert, and why in this shape ──────────────────────────────────────────
//
// Through the real `CanvasToolController`, selecting the Edit tool the way the toolbar does
// (`setActiveTool(fromLibrary:)` on the published `Edit Tool` id), because the defect is about the
// default tool and a directly-constructed `EditTool` would not prove the user can reach it.
//
// Every negative-side test is paired with the same gesture translated into the positive quadrant.
// That pairing is the point: a sentinel bug and a tool that has stopped working entirely look
// identical from the negative side alone.
//
// ── WHAT EACH PROBE REDDENED, MEASURED ──────────────────────────────────────────────────────
//
//   * `press.x >= 0` put back in `isClick` → "clicking a wire left of the origin selects it",
//     and only that. 0 components at (−100, −100), 1 at (100, 100).
//   * `point.x >= 0` put back in `updateLocationFromKey` → the two negative-side indicator tests,
//     and only those. Both calibrations stayed green, which is what says the sentinel and not the
//     indicator is what moved.
//   * The `lastComputedPoint == snappedPoint` comparison neutered, so the "already computed"
//     short-circuit always fires → three tests in this file and **nothing else in the 1,700-test
//     suite**. The wiring-decision recompute has no other gate anywhere, which is why the
//     indicator tests are here at all rather than just the click one.
//   * The third sentinel restored exactly as it was, `lastX = -1`, `Integer.MIN_VALUE` on press,
//     `lastY` left alone, → all 1,700 tests still pass. That site is **latent**, not merely
//     untested: `lastX` is only ever compared against a snapped coordinate and `snapXToGrid`
//     returns a multiple of 10, so a literal −1 cannot collide with one. It was converted with
//     the other two because the idiom is the defect, and no test here claims otherwise.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import AppKit
import CoreGraphics
import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd
import Testing

@testable import LogisimUI

// MARK: - Rig

/// A project holding one horizontal wire, with the **Edit tool** active: the default tool, and
/// the only one that routes a gesture between selecting and wiring.
@MainActor
private struct EditRig {
  let circuit: Circuit
  let canvas: CircuitEditorCanvas
  let editTool: EditTool
  let wire: Wire

  /// `middle` is the wire's midpoint, which is a grid intersection and is deliberately *not* an
  /// endpoint: `isWiringPoint` sends a press there to the wiring tool, and it is the click replay
  /// that turns that into a selection.
  let middle: Location

  init(wireCentredOn centre: Location) throws {
    StdLibraries.registerAll()
    let host = try #require(
      try LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
    circuit = try #require(host.currentCircuitObject)
    let surface = try #require(host.makeRenderSurface() as? CircuitCanvasSurface)

    middle = centre
    let created = Wire.create(
      Location.create(centre.x - 20, centre.y, hasToSnap: false),
      Location.create(centre.x + 20, centre.y, hasToSnap: false))
    try circuit.mutatorAdd(created)
    wire = created

    canvas = CircuitEditorCanvas(
      project: host.project, surface: surface, circuit: circuit, initialTool: SelectTool())
    surface.renderView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    surface.setViewport(
      CanvasViewport(
        zoom: 1, center: CGPoint(x: CGFloat(centre.x), y: CGFloat(centre.y)),
        viewSize: CGSize(width: 800, height: 600)))

    // The toolbar's own path, so this drives the instance a user would be driving.
    #expect(
      canvas.controller.setActiveTool(fromLibrary: BuiltinPlaceholderTool(id: BaseToolIds.edit)),
      "the controller does not resolve the Edit tool, so this test drives nothing")
    editTool = try #require(
      canvas.controller.activeTool as? EditTool,
      "the active tool is \(type(of: canvas.controller.activeTool)), not the Edit tool")
  }

  func pointer(_ phase: CanvasPointerEvent.Phase, _ x: Int, _ y: Int, option: Bool = false) {
    canvas.controller.canvasHandlePointer(
      CanvasPointerEvent(
        phase: phase,
        world: CGPoint(x: CGFloat(x), y: CGFloat(y)),
        modifiers: option ? .option : [],
        clickCount: 1,
        buttonNumber: 1,
        dragOriginWorld: nil))
  }

  /// A press and a release at the same point: a click, by `isClick`'s 2-unit test.
  func click(_ x: Int, _ y: Int) {
    pointer(.down, x, y)
    pointer(.up, x, y)
  }

  /// Option down / up, which is what `.wiringOverrideModifierChanged` is.
  func optionKey(_ phase: CanvasKeyEvent.Phase) {
    _ = canvas.controller.canvasHandleKey(
      CanvasKeyEvent(
        phase: phase, characters: "", keyCode: AppleKeyCodes.option,
        modifiers: phase == .down ? .option : [], isRepeat: false))
  }

  /// Where the Edit tool says it would draw its wiring-point circle, or nil for "nowhere".
  var indicator: Location? {
    for item in editTool.overlay(for: canvas).items {
      if case let .wiringPointIndicator(location) = item { return location }
    }
    return nil
  }
}

// MARK: - Tests

@Suite("EditTool does not read a negative coordinate as no coordinate")
@MainActor
struct EditToolNegativePressTests {

  /// **THE DEFECT.** Clicking the middle of an unselected wire selects it, on either side of the
  /// origin. Measured before the fix: 0 components selected at (−100, −100), 1 at (100, 100).
  @Test("clicking a wire left of the origin selects it")
  func aWireLeftOfTheOriginIsSelectable() throws {
    let rig = try EditRig(wireCentredOn: Location.create(-100, -100, hasToSnap: false))
    rig.click(rig.middle.x, rig.middle.y)

    #expect(
      rig.canvas.selection.components.count == 1,
      """
      clicking (\(rig.middle.x), \(rig.middle.y)) selected \
      \(rig.canvas.selection.components.count) components instead of 1. The press goes to the \
      WIRING tool — a wire's middle is a wiring point — and it is `isClick` that retracts it and \
      replays it into the select tool. With `pressX < 0` meaning "no press", a negative press \
      coordinate is never a click, so nothing is ever selected left of the origin.
      """)
    #expect(
      rig.canvas.selection.components.first.map { ComponentRef($0) } == ComponentRef(rig.wire))
  }

  /// The calibration. Without it the test above could pass against a click replay that has
  /// stopped replaying everywhere, or a wire that is not a wiring point in the first place.
  @Test("clicking a wire right of the origin still selects it")
  func aWireRightOfTheOriginIsStillSelectable() throws {
    let rig = try EditRig(wireCentredOn: Location.create(100, 100, hasToSnap: false))
    rig.click(rig.middle.x, rig.middle.y)
    #expect(rig.canvas.selection.components.count == 1)
    #expect(
      rig.canvas.selection.components.first.map { ComponentRef($0) } == ComponentRef(rig.wire))
  }

  /// `isClick`'s side effect, which is the half of it that must survive: once the pointer has
  /// moved more than 2 units the gesture stops being a click *for good*, so a drag out of a
  /// wiring point draws a wire rather than selecting the thing under the press. Negative
  /// coordinates must not turn a drag into a click any more than they may turn a click into a
  /// drag.
  @Test("dragging out of a wiring point left of the origin draws a wire, it does not select")
  func aDragLeftOfTheOriginIsNotAClick() throws {
    let rig = try EditRig(wireCentredOn: Location.create(-100, -100, hasToSnap: false))
    let wiresBefore = rig.circuit.wires.count

    rig.pointer(.down, rig.middle.x, rig.middle.y)
    rig.pointer(.dragged, rig.middle.x, rig.middle.y - 40)
    rig.pointer(.up, rig.middle.x, rig.middle.y - 40)

    #expect(
      rig.canvas.selection.isEmpty,
      """
      a 40-unit drag selected \(rig.canvas.selection.components.count) components. It was \
      replayed as a click, which means `isClick`'s "more than 2 units away and never a click \
      again" reset stopped working.
      """)
    #expect(
      rig.circuit.wires.count > wiresBefore,
      "the drag drew no wire; the circuit still has \(rig.circuit.wires.count) wires")
  }

  /// The second sentinel, `updateLocation(Canvas, KeyEvent)`'s `lastRawX >= 0`.
  ///
  /// Holding Option **swaps** `isWiringPoint`'s answers, so the middle of an already-selected
  /// wire, normally a select target, so no indicator, becomes a wiring point and the indicator
  /// appears. That recompute happens without the mouse moving, from the last known pointer
  /// position, and a negative one used to read as "no pointer position".
  @Test("the Option override updates the wiring indicator left of the origin")
  func theOverrideModifierIsHonouredLeftOfTheOrigin() throws {
    let rig = try EditRig(wireCentredOn: Location.create(-100, -100, hasToSnap: false))
    rig.canvas.selection.add(rig.wire)
    rig.pointer(.moved, rig.middle.x, rig.middle.y)
    #expect(
      rig.indicator == nil,
      "the middle of a SELECTED wire is a select target, yet the indicator is already showing")

    rig.optionKey(.down)
    #expect(
      rig.indicator == rig.middle,
      """
      Option did not move the indicator to \(rig.middle) — it is \
      \(String(describing: rig.indicator)). `updateLocationFromKey` returned early because \
      `lastRawX` was negative, so the key never reached `updateLocation` at all.
      """)

    rig.optionKey(.up)
    #expect(
      rig.indicator == nil,
      "releasing Option left the indicator at \(String(describing: rig.indicator))")
  }

  /// Its calibration, in the positive quadrant.
  @Test("the Option override updates the wiring indicator right of the origin")
  func theOverrideModifierIsHonouredRightOfTheOrigin() throws {
    let rig = try EditRig(wireCentredOn: Location.create(100, 100, hasToSnap: false))
    rig.canvas.selection.add(rig.wire)
    rig.pointer(.moved, rig.middle.x, rig.middle.y)
    #expect(rig.indicator == nil)
    rig.optionKey(.down)
    #expect(rig.indicator == rig.middle)
    rig.optionKey(.up)
    #expect(rig.indicator == nil)
  }

  /// The other caller of the same guard: `EditTool.Listener`. A circuit change throws the cache
  /// away and recomputes at the last pointer position, which is what makes the indicator vanish
  /// when the wire under it is deleted. Left of the origin the recompute was skipped, leaving a
  /// wiring circle drawn over bare canvas.
  @Test("deleting the wire under the pointer clears the indicator left of the origin")
  func aCircuitChangeRecomputesLeftOfTheOrigin() throws {
    let rig = try EditRig(wireCentredOn: Location.create(-100, -100, hasToSnap: false))
    rig.pointer(.moved, rig.middle.x, rig.middle.y)
    #expect(
      rig.indicator == rig.middle,
      "the middle of an unselected wire is a wiring point, yet no indicator showed")

    try rig.circuit.mutatorRemove(rig.wire)
    #expect(
      rig.indicator == nil,
      """
      the wire is gone and the indicator is still at \(String(describing: rig.indicator)). \
      `invalidate` cleared the cache and then `updateLocationFromKey` refused to recompute \
      because the pointer's x was negative.
      """)
  }

  /// Its calibration.
  @Test("deleting the wire under the pointer clears the indicator right of the origin")
  func aCircuitChangeRecomputesRightOfTheOrigin() throws {
    let rig = try EditRig(wireCentredOn: Location.create(100, 100, hasToSnap: false))
    rig.pointer(.moved, rig.middle.x, rig.middle.y)
    #expect(rig.indicator == rig.middle)
    try rig.circuit.mutatorRemove(rig.wire)
    #expect(rig.indicator == nil)
  }
}
