// AppearanceSnapParityTests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// DRAGGING A SHAPE IN THE APPEARANCE EDITOR, CHECKED AGAINST THE SHIPPED 4.1.0 JAR
//
// `GridSnapParityTests` proved the MAIN CANVAS matches 4.1.0 exactly. This file is the other
// canvas, and it is a different function on purpose: the appearance editor is where a user draws
// a subcircuit's symbol, a mux trapezoid, a curve, a label bar, and upstream leaves placement
// FREE there so a symbol that looks right can be drawn, offering snapping on demand through a
// modifier. Reading the schematic canvas's rule into this one is the trap; four things were
// wrong here and three of them were that trap.
//
// Like its sibling, every expectation was produced by *executing* 4.1.0's bytecode, not by
// reading it.
//
// ── THE ORACLE ───────────────────────────────────────────────────────────────────────────────
//
//   javac -cp /Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar …
//   java  -Djava.awt.headless=true -cp .:<that jar> Oracle
//
// The harness reflected `com.cburch.draw.tools.SelectTool.setMouse(Canvas,int,int,int)` onto a
// real `com.cburch.logisim.gui.appear.AppearanceCanvas` holding a real `Selection` of a real
// `com.cburch.draw.shapes.Rectangle`, drove the MOVE_ALL branch, and read back the delta
// upstream handed to `Selection.setMovingDelta`. Real handles, real min-handle scan, real
// `Canvas.snapX`. The tables below are that harness's stdout.
//
// ── THE FOUR THINGS THE PORT HAD WRONG ───────────────────────────────────────────────────────
//
//                     4.1.0 (executed)                              port before
//   default           NO snap                                       snapped
//   modifier          CTRL_DOWN_MASK (128) *enables*                Option *disabled*
//   what is snapped   the destination: snapX(minHandleX + dx) - …   the delta
//   rounding          Math.round on each endpoint, then snapX       one `.rounded()` on the delta
//
// ── ONE CORRECTION TO THE AUDIT THAT PROMPTED THIS WORK ──────────────────────────────────────
//
// The audit's fourth row read "`floor(v+0.5)` vs Swift `.rounded()`" and placed it at the grid
// snap. Measured, that is the wrong location. `AppearanceCanvas.snapX` is `((v + 5) / 10) * 10`
// in `int`, which is round-half-AWAY-FROM-ZERO, and Swift's default `.rounded()` is
// `.toNearestOrAwayFromZero`, the same rule. On every reachable value the port's old grid snap
// already agreed. A red probe substituting the one-liner for `CanvasGrid.snapXToGrid` reddened
// nothing, which is how this was caught.
//
// The divergence is real but sits one step earlier, at the *pointer integerisation*: upstream
// does `(int) Math.round(px / zoom)` per endpoint, `Math.round` is `floor(v + 0.5)`, and that is
// NOT Swift's `.rounded()`: they part on every negative half-integer. The old code rounded the
// continuous *difference* once, which is a different function again. Both are pinned below, and
// `theSnapWrapsAtThirtyTwoBitsWhereADoubleBasedRuleWouldNot` covers the one place the two grid
// rules genuinely differ.
//
// ── WHY DESTINATION-VS-DELTA IS THE SUBSTANTIVE ONE ──────────────────────────────────────────
//
// It is a defect independent of which modifier means what, and the case that exposes it is a
// shape that STARTS off grid; a shape starting on grid gives the same answer under both rules,
// so a test placed at (100,100) would be vacuous and is not written here.
//
// Snapping the delta preserves an existing offset forever: a rectangle at x=103 dragged by 13
// moves by snap(13)=10 to 113, then to 123, then to 133: off grid at every step, and no drag
// can ever recover it. Snapping the destination sends 103+13=116 to 120 and moves by 17, which
// lands it. `anOffGridShapeCanNeverReachTheGridUnderDeltaSnapping` is that sentence as a test.
//
// ── A MEASURED, DELIBERATELY UNASSERTED GAP ──────────────────────────────────────────────────
//
// `setMouse` also reads `SHIFT_DOWN_MASK` (64) and constrains the drag to one axis:
// `if (Math.abs(dx) > Math.abs(dy)) dy = 0; else dx = 0;`, applied AFTER the snap. Executed:
//
//     rect     drag      mods        upstream
//     100,100  (13, 7)   64          (13, 0)
//     100,100  ( 7,13)   64          ( 0, 13)     ties go to dx = 0
//     103,107  (13, 7)   64|128      (17, 0)     snap first, then constrain
//
// The port does not implement it, so the rows are recorded and NOT asserted: pinning today's
// answer would build a change detector that fires on the correct fix. Shift is currently bound
// to "extend the selection" on press in `AppearanceCanvasNSView.mouseDown`, which is also
// upstream's meaning for shift-on-press, so the two do not conflict, but adding a second
// meaning to a gesture is a decision, not a transcription, and it is named here instead.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import AppKit
import CoreGraphics
import Foundation
import LogisimDraw
import LogisimKernel
import Testing

@testable import LogisimUI

// MARK: - Oracle table (stdout of the 4.1.0 jar harness)

/// One row of the harness: a `Rectangle(rectX, rectY, 30, 20)` is the whole selection, the press
/// was at `(startX, startY)` and the pointer is at `(mouseX, mouseY)`, both already in model
/// coordinates. `mods` is a `java.awt.event.InputEvent` extended-modifier mask, executed from
/// the jar as SHIFT=64, CTRL=128, META=256, ALT=512.
private struct MoveAllRow {
  let rectX: Int
  let rectY: Int
  let startX: Int
  let startY: Int
  let mouseX: Int
  let mouseY: Int
  let mods: Int
  let dx: Int
  let dy: Int
}

private let ctrl = 128
private let alt = 512

/// Rows the port must reproduce. Shift rows are excluded on purpose, see the header.
private let moveAllOracle: [MoveAllRow] = [
  // On-grid shape: free by default, snapped under Ctrl, untouched by Alt.
  MoveAllRow(rectX: 100, rectY: 100, startX: 0, startY: 0, mouseX: 13, mouseY: 7, mods: 0,
             dx: 13, dy: 7),
  MoveAllRow(rectX: 100, rectY: 100, startX: 0, startY: 0, mouseX: 13, mouseY: 7, mods: 128,
             dx: 10, dy: 10),
  MoveAllRow(rectX: 100, rectY: 100, startX: 0, startY: 0, mouseX: 13, mouseY: 7, mods: 512,
             dx: 13, dy: 7),
  // Off-grid shape (103,107): the case that separates destination-snap from delta-snap.
  MoveAllRow(rectX: 103, rectY: 107, startX: 0, startY: 0, mouseX: 13, mouseY: 7, mods: 0,
             dx: 13, dy: 7),
  MoveAllRow(rectX: 103, rectY: 107, startX: 0, startY: 0, mouseX: 13, mouseY: 7, mods: 128,
             dx: 17, dy: 3),
  MoveAllRow(rectX: 103, rectY: 107, startX: 0, startY: 0, mouseX: 0, mouseY: 0, mods: 128,
             dx: -3, dy: 3),
  MoveAllRow(rectX: 103, rectY: 107, startX: 0, startY: 0, mouseX: 1, mouseY: 1, mods: 128,
             dx: -3, dy: 3),
  MoveAllRow(rectX: 103, rectY: 107, startX: 0, startY: 0, mouseX: 4, mouseY: 4, mods: 128,
             dx: 7, dy: 3),
  MoveAllRow(rectX: 103, rectY: 107, startX: 0, startY: 0, mouseX: 5, mouseY: 5, mods: 128,
             dx: 7, dy: 3),
  MoveAllRow(rectX: 103, rectY: 107, startX: 0, startY: 0, mouseX: 7, mouseY: 7, mods: 128,
             dx: 7, dy: 3),
  MoveAllRow(rectX: 103, rectY: 107, startX: 0, startY: 0, mouseX: -3, mouseY: -7, mods: 128,
             dx: -3, dy: -7),
  // Negative shape origin, where every plausible rounding rule disagrees.
  MoveAllRow(rectX: -103, rectY: -107, startX: 0, startY: 0, mouseX: 13, mouseY: 7, mods: 128,
             dx: 13, dy: 7),
  MoveAllRow(rectX: -103, rectY: -107, startX: 0, startY: 0, mouseX: -13, mouseY: -7, mods: 128,
             dx: -17, dy: -3),
  // Exact half-grid destinations, both signs.
  MoveAllRow(rectX: 0, rectY: 0, startX: 0, startY: 0, mouseX: 5, mouseY: 5, mods: 128,
             dx: 10, dy: 10),
  MoveAllRow(rectX: 0, rectY: 0, startX: 0, startY: 0, mouseX: -5, mouseY: -5, mods: 128,
             dx: -10, dy: -10),
  MoveAllRow(rectX: 0, rectY: 0, startX: 0, startY: 0, mouseX: 4, mouseY: 4, mods: 128,
             dx: 0, dy: 0),
  MoveAllRow(rectX: 0, rectY: 0, startX: 0, startY: 0, mouseX: -4, mouseY: -4, mods: 128,
             dx: 0, dy: 0),
  // Tiny unmodified drags stay exactly as given once the gesture is effective.
  MoveAllRow(rectX: 100, rectY: 100, startX: 0, startY: 0, mouseX: 1, mouseY: 1, mods: 0,
             dx: 1, dy: 1),
  MoveAllRow(rectX: 100, rectY: 100, startX: 0, startY: 0, mouseX: 2, mouseY: 0, mods: 0,
             dx: 2, dy: 0),
]

/// `SelectTool.dragEffective` against `DRAG_TOLERANCE`, executed. The harness pressed at (0,0)
/// with `dragEffective` false and moved the pointer to (n, 0).
private let dragToleranceOracle: [(n: Int, effective: Bool)] = [
  (0, false), (1, false), (2, false), (3, true), (4, true),
]

/// `canvas.snapX(origin + dx) - origin` at Java's `int` boundaries, evaluated by the JVM in real
/// `int` arithmetic with `snapX` supplied by the shipped 4.1.0 `AppearanceCanvas`.
///
/// These rows exist because of a **green red-probe**. Replacing `CanvasGrid.snapXToGrid` with the
/// one-liner `Int((Double(v) / 10).rounded()) * 10` reddened nothing: Swift's default `.rounded()`
/// is `.toNearestOrAwayFromZero`, and `((v + 5) / 10) * 10` is round-half-away-from-zero too, so
/// the two agree on every ordinary value. The brief's fourth divergence; "`floor(v+0.5)` vs
/// Swift `.rounded()`"; is real but is located at the *pointer integerisation*, not at the grid
/// snap; see `endpointsAreIntegerisedSeparatelyBeforeSubtracting`.
///
/// Where the two grid rules do part is the 32-bit boundary, because `snapX` adds 5 *before*
/// dividing and Java's `int` wraps while `Double` does not. Unreachable without a shape at ±2^31
/// ; kept for the same reason `GridSnapParityTests` keeps its overflow rows: the port's `wrap32`
/// calls are otherwise untested and would read as dead ceremony. Every expectation is upstream's
/// own answer, so this is parity, not a change detector.
private let boundaryOracle: [(origin: Int, dx: Int, snappedDx: Int)] = [
  (2_147_483_640, 7, 16),
  (2_147_483_647, 1, -7),
  (2_147_483_647, 0, 9),
  (2_147_483_640, 12, 0),
  (-2_147_483_648, -1, 8),
  (-2_147_483_648, -7, -8),
  (-2_147_483_643, -9, 3),
  (1_073_741_824, 3, 6),
  (-1_073_741_824, -3, -6),
  (2_000_000_000, 200_000_000, 199_999_996),
]

// MARK: - Driving the port

/// The port's `setMouse`, given one oracle row. `Rectangle`'s handles are its four corners, so
/// the min-handle scan sees `(rectX, rectY)`: exactly what the jar's scan saw.
@MainActor
private func portDelta(_ row: MoveAllRow) -> (dx: Int, dy: Int) {
  let rect = DrawRectangle(x: row.rectX, y: row.rectY, w: 30, h: 20)
  return AppearanceCanvasNSView.movingDelta(
    start: ToolPoint(x: row.startX, y: row.startY),
    end: ToolPoint(x: row.mouseX, y: row.mouseY),
    snapping: (row.mods & ctrl) != 0,
    selectionOrigin: AppearanceCanvasNSView.selectionOrigin(of: [rect]))
}

// MARK: - The suite

@Suite("Appearance-editor drag parity with 4.1.0")
struct AppearanceSnapParityTests {

  // ── The owner's decision, stated as a test ───────────────────────────────────────────────

  /// The headline. 4.1.0 does not snap in the appearance editor unless asked, and a port that
  /// snaps here cannot draw a symbol that is not a multiple of 10 on every side.
  @Test @MainActor func draggingWithNoModifierDoesNotSnapAtAll() {
    let origin = ToolPoint(x: 100, y: 100)
    for (mx, my) in [(13, 7), (1, 1), (4, 4), (5, 5), (9, 2), (-7, -3), (-5, 5)] {
      let d = AppearanceCanvasNSView.movingDelta(
        start: ToolPoint(x: 0, y: 0), end: ToolPoint(x: mx, y: my),
        snapping: false, selectionOrigin: origin)
      #expect(d.dx == mx && d.dy == my, "free drag of (\(mx),\(my)) must be exactly itself")
    }
  }

  /// The modifier, both halves: Control turns snapping ON (it is not an escape hatch), and
  /// Option, which the port used to treat as the escape, is not read at all.
  @Test @MainActor func controlEnablesSnappingAndOptionIsNotAModifierHere() {
    let onGrid = MoveAllRow(rectX: 100, rectY: 100, startX: 0, startY: 0, mouseX: 13, mouseY: 7,
                            mods: 0, dx: 13, dy: 7)

    // No modifier: free.
    #expect(portDelta(onGrid) == (13, 7))

    // Alt/Option: still free. The jar answers identically to no modifier.
    let withAlt = MoveAllRow(rectX: 100, rectY: 100, startX: 0, startY: 0, mouseX: 13, mouseY: 7,
                             mods: alt, dx: 13, dy: 7)
    #expect(portDelta(withAlt) == (13, 7))

    // Control: snapped. 100+13 = 113 -> 110, so dx = 10; 100+7 = 107 -> 110, so dy = 10.
    let withCtrl = MoveAllRow(rectX: 100, rectY: 100, startX: 0, startY: 0, mouseX: 13, mouseY: 7,
                              mods: ctrl, dx: 10, dy: 10)
    #expect(portDelta(withCtrl) == (10, 10))

    // And the two disagree, which is what makes the modifier observable at all.
    #expect(portDelta(onGrid) != portDelta(withCtrl))
  }

  // ── Destination, not delta ───────────────────────────────────────────────────────────────

  /// The substantive bug, on the only case that can see it: a shape that starts OFF grid.
  ///
  /// Rectangle at x=103, dragged right by 13 with Control held. Upstream snaps the
  /// *destination*, 103+13 = 116, which snaps to 120, and moves by 17, landing the shape on
  /// the grid line. Snapping the *delta* would move by snap(13) = 10 to 113, still off grid.
  @Test @MainActor func snappingTheDestinationLandsAnOffGridShapeOnTheGrid() {
    let row = MoveAllRow(rectX: 103, rectY: 107, startX: 0, startY: 0, mouseX: 13, mouseY: 7,
                         mods: ctrl, dx: 17, dy: 3)
    let d = portDelta(row)
    #expect(d == (17, 3), "jar says (17, 3)")

    // The shape ends ON the grid. That is the observable consequence.
    #expect(CanvasGrid.snapXToGrid(103 + d.dx) == 103 + d.dx)
    #expect(CanvasGrid.snapYToGrid(107 + d.dy) == 107 + d.dy)

    // The rule the port used to apply, spelled out, so the contrast is in the file.
    let deltaSnapped = (CanvasGrid.snapXToGrid(13), CanvasGrid.snapYToGrid(7))
    #expect(deltaSnapped == (10, 10))
    #expect(d != deltaSnapped)
    #expect(CanvasGrid.snapXToGrid(103 + deltaSnapped.0) != 103 + deltaSnapped.0)
  }

  /// Why it matters beyond one drag: under delta-snapping an off-grid shape is off grid
  /// *forever*, because the delta is always a multiple of 10 and the offset never changes.
  /// Under upstream's rule one drag is enough.
  @Test @MainActor func anOffGridShapeCanNeverReachTheGridUnderDeltaSnapping() {
    var deltaRuleX = 103
    for step in [13, 7, 22, -31, 5, 44] {
      deltaRuleX += CanvasGrid.snapXToGrid(step)
      #expect(deltaRuleX % 10 == 3, "delta-snapping preserves the 3-unit offset at every step")
      #expect(CanvasGrid.snapXToGrid(deltaRuleX) != deltaRuleX)
    }

    // Upstream's rule, from the same start, on the very first drag.
    let d = AppearanceCanvasNSView.movingDelta(
      start: ToolPoint(x: 0, y: 0), end: ToolPoint(x: 13, y: 0),
      snapping: true, selectionOrigin: ToolPoint(x: 103, y: 0))
    #expect(CanvasGrid.snapXToGrid(103 + d.dx) == 103 + d.dx)
  }

  /// Control held with the pointer barely moved pulls an off-grid shape ONTO the grid rather
  /// than leaving it where it is; the delta is non-zero even though the drag is not.
  @Test @MainActor func controlWithNoPointerMovementStillPullsTheShapeOntoTheGrid() {
    let d = AppearanceCanvasNSView.movingDelta(
      start: ToolPoint(x: 0, y: 0), end: ToolPoint(x: 0, y: 0),
      snapping: true, selectionOrigin: ToolPoint(x: 103, y: 107))
    #expect(d == (-3, 3), "jar says (-3, 3)")
    #expect(103 + d.dx == 100)
    #expect(107 + d.dy == 110)
  }

  // ── Rounding ─────────────────────────────────────────────────────────────────────────────

  /// `AppearanceCanvas.snapX` was executed against `com.cburch.logisim.gui.main.Canvas
  /// .snapXToGrid` over every input in [-400, 400] and is the same function, so this reuses
  /// `CanvasGrid` rather than growing a second rule. These rows are the ones where Swift's own
  /// `.rounded()`, what the port used, gives a different grid line.
  @Test @MainActor func roundingIsUpstreamsAwayFromZeroRuleNotSwiftsRounded() {
    // Destination exactly on a half-grid point, both signs: away from zero, never to even.
    #expect(AppearanceCanvasNSView.movingDelta(
      start: ToolPoint(x: 0, y: 0), end: ToolPoint(x: 5, y: 5),
      snapping: true, selectionOrigin: ToolPoint(x: 0, y: 0)) == (10, 10))
    #expect(AppearanceCanvasNSView.movingDelta(
      start: ToolPoint(x: 0, y: 0), end: ToolPoint(x: -5, y: -5),
      snapping: true, selectionOrigin: ToolPoint(x: 0, y: 0)) == (-10, -10))
    // Just inside the half point it does not move away from zero.
    #expect(AppearanceCanvasNSView.movingDelta(
      start: ToolPoint(x: 0, y: 0), end: ToolPoint(x: 4, y: -4),
      snapping: true, selectionOrigin: ToolPoint(x: 0, y: 0)) == (0, 0))

    // The old rule, written out: `Int((Double(raw) / 10).rounded()) * 10` on the delta. It is
    // round-half-away-from-zero on the *delta*, so at -5 it agrees by luck and at 103 it does
    // not agree at all. The point is that it is a different function of a different argument.
    func oldPortRule(_ raw: Int) -> Int { Int((Double(raw) / 10).rounded()) * 10 }
    #expect(oldPortRule(13) == 10)
    #expect(AppearanceCanvasNSView.movingDelta(
      start: ToolPoint(x: 0, y: 0), end: ToolPoint(x: 13, y: 0),
      snapping: true, selectionOrigin: ToolPoint(x: 103, y: 0)).dx != oldPortRule(13))
  }

  /// The 32-bit boundary, which is the only place `CanvasGrid.snapXToGrid` and the one-line
  /// `Int((Double(v) / 10).rounded()) * 10` disagree; `snapX` adds 5 before dividing, so Java's
  /// `int` wraps where `Double` sails past. Without these rows, swapping the port's snap for that
  /// one-liner passes every other test in this file.
  @Test @MainActor func theSnapWrapsAtThirtyTwoBitsWhereADoubleBasedRuleWouldNot() {
    var mismatches: [String] = []
    for row in boundaryOracle {
      let got = AppearanceCanvasNSView.movingDelta(
        start: ToolPoint(x: 0, y: 0), end: ToolPoint(x: row.dx, y: row.dx),
        snapping: true, selectionOrigin: ToolPoint(x: row.origin, y: row.origin))
      if got.dx != row.snappedDx || got.dy != row.snappedDx {
        mismatches.append(
          "origin=\(row.origin) dx=\(row.dx) -> (\(got.dx),\(got.dy)),"
            + " jar says \(row.snappedDx)")
      }
      // The rule the green probe substituted, so the contrast is recorded rather than asserted
      // from memory. It differs on most of these rows and agrees on the rest.
      let doubleRule = Int(((Double(row.origin) + Double(row.dx)) / 10).rounded()) * 10 - row.origin
      if row.origin == 1_073_741_824 || row.origin == -1_073_741_824 {
        #expect(doubleRule == row.snappedDx, "these two rows agree, which is why spot checks miss")
      } else {
        #expect(doubleRule != row.snappedDx, "row \(row.origin) must distinguish the rules")
      }
    }
    #expect(mismatches.isEmpty, "\(mismatches.count) divergence(s): \(mismatches.prefix(8))")
  }

  /// `setMouse`'s raw delta is `newEnd.getX() - dragStart.getX()` in Java `int`, so it wraps.
  /// Swift's `Int` is 64-bit and would answer 4294967295 where Java answers -1. Executed against
  /// the jar's `Location.create(x, 0, false).getX()`; unreachable for the same reason as the
  /// boundary rows above, and kept for the same reason: a third `wrap32` in the port that
  /// nothing else exercises. Found by a red probe that dropped it and reddened nothing.
  @Test @MainActor func theRawDeltaWrapsAtThirtyTwoBitsLikeJavasInt() {
    let rows: [(end: Int, start: Int, dx: Int)] = [
      (2_147_483_647, -2_147_483_648, -1),
      (-2_147_483_648, 2_147_483_647, 1),
      (2_147_483_647, -1, -2_147_483_648),
      (-2_147_483_648, 1, 2_147_483_647),
      (2_000_000_000, -2_000_000_000, -294_967_296),
    ]
    for row in rows {
      let got = AppearanceCanvasNSView.movingDelta(
        start: ToolPoint(x: row.start, y: row.start), end: ToolPoint(x: row.end, y: row.end),
        snapping: false, selectionOrigin: ToolPoint(x: 0, y: 0))
      #expect(got.dx == row.dx, "end=\(row.end) start=\(row.start)")
      #expect(got.dy == row.dx, "end=\(row.end) start=\(row.start)")
      // Swift's own subtraction disagrees on every one of these.
      #expect(row.end - row.start != row.dx)
    }
  }

  /// The two endpoints are integerised separately with Java's `Math.round` and only then
  /// subtracted (`repairEvent` -> `Location.create(x, y, false)`). Rounding the continuous
  /// difference instead disagrees whenever the two fractions straddle a half, which is why
  /// `movingDelta` takes two `ToolPoint`s rather than one delta.
  @Test @MainActor func endpointsAreIntegerisedSeparatelyBeforeSubtracting() {
    let pressWorld = 0.6
    let releaseWorld = 10.4
    let upstream = CanvasGrid.circuitCoordinate(releaseWorld)
      - CanvasGrid.circuitCoordinate(pressWorld)
    #expect(upstream == 9, "round(10.4) - round(0.6) = 10 - 1")

    let naive = Int((releaseWorld - pressWorld).rounded())
    #expect(naive == 10, "rounding the continuous difference gives 10")
    #expect(upstream != naive)

    // And Java's round is floor(v + 0.5), so it is asymmetric at exact negative halves.
    #expect(CanvasGrid.circuitCoordinate(-4.5) == -4)
    #expect(CanvasGrid.circuitCoordinate(-4.5) != Int((-4.5).rounded()))
  }

  // ── The min-handle scan ──────────────────────────────────────────────────────────────────

  /// Upstream scans `CanvasObject.getHandles(null)` and takes the minimum, not the bounding
  /// box. For a `Curve` whose control point sits outside the drawn curve the two differ, and
  /// using bounds would snap the shape to a different grid line.
  ///
  /// The control point here is at x = 40 while the tight Bezier bounds start at x = 83; the
  /// jar agrees (`Curve(…).getBounds()` on the same three points answers `(83,60): 117x40`),
  /// so a bounds-based origin would be 43 units wrong on this shape alone.
  @Test @MainActor func selectionOriginIsTheMinimumHandleNotTheBoundingBox() {
    let curve = Curve(
      end0: Location.create(100, 100, hasToSnap: false),
      end1: Location.create(200, 100, hasToSnap: false),
      control: Location.create(40, 20, hasToSnap: false))

    let origin = AppearanceCanvasNSView.selectionOrigin(of: [curve])
    #expect(origin.x == 40, "the control handle is the leftmost handle")
    #expect(origin.y == 20, "and the topmost")
    #expect(curve.bounds.x == 83, "the drawn curve never reaches its control point")
    #expect(origin.x != curve.bounds.x, "so the two rules genuinely differ")
  }

  /// Several shapes: the minimum is taken across the whole selection, and x and y are minimised
  /// independently; they may come from different shapes.
  @Test @MainActor func theOriginIsMinimisedPerAxisAcrossTheWholeSelection() {
    let a = DrawRectangle(x: 40, y: 300, w: 10, h: 10)
    let b = DrawRectangle(x: 300, y: 20, w: 10, h: 10)
    let origin = AppearanceCanvasNSView.selectionOrigin(of: [a, b])
    #expect(origin.x == 40 && origin.y == 20)
  }

  /// Upstream seeds both minima with `Integer.MAX_VALUE` and never guards the empty case. The
  /// port must reproduce the seed and, more importantly, must not trap on the arithmetic that
  /// follows; this sits on the mouse path, where a trap is worse than any wrong coordinate.
  @Test @MainActor func anEmptySelectionSeedsWithIntegerMaxValueAndDoesNotTrap() {
    let origin = AppearanceCanvasNSView.selectionOrigin(of: [])
    #expect(origin.x == Int(Int32.max) && origin.y == Int(Int32.max))
    for snapping in [true, false] {
      _ = AppearanceCanvasNSView.movingDelta(
        start: ToolPoint(x: 0, y: 0), end: ToolPoint(x: 13, y: 7),
        snapping: snapping, selectionOrigin: origin)
    }
  }

  // ── The tolerance that free placement makes load-bearing ─────────────────────────────────

  /// `SelectTool.DRAG_TOLERANCE`. While the port snapped by default a 1-unit tremor rounded to
  /// a delta of 0 and was invisible; with placement free it would commit a 1-unit move. This is
  /// upstream's guard, and removing default snapping is what makes it matter.
  @Test @MainActor func pressJitterInsideTheDragToleranceMovesNothing() {
    for row in dragToleranceOracle {
      #expect(
        AppearanceCanvasNSView.dragBeatsTolerance(dx: row.n, dy: 0) == row.effective,
        "|\(row.n)| + 0 vs DRAG_TOLERANCE=2")
    }
    // It is the sum of the absolute values, not either one alone, and it is strict.
    #expect(AppearanceCanvasNSView.dragBeatsTolerance(dx: 2, dy: 0) == false)
    #expect(AppearanceCanvasNSView.dragBeatsTolerance(dx: 1, dy: 1) == false)
    #expect(AppearanceCanvasNSView.dragBeatsTolerance(dx: 2, dy: 1) == true)
    #expect(AppearanceCanvasNSView.dragBeatsTolerance(dx: -2, dy: -1) == true)
    #expect(AppearanceCanvasNSView.dragTolerance == 2)
  }

  // ── The whole table ──────────────────────────────────────────────────────────────────────

  /// Every non-shift row the harness emitted, replayed through the port in one loop so a
  /// divergence is reported with its input rather than as an opaque failed assertion.
  @Test @MainActor func theWholeJarTableReplays() {
    var mismatches: [String] = []
    for row in moveAllOracle {
      let got = portDelta(row)
      if got.dx != row.dx || got.dy != row.dy {
        mismatches.append(
          "rect(\(row.rectX),\(row.rectY)) drag(\(row.mouseX),\(row.mouseY)) mods=\(row.mods)"
            + " -> (\(got.dx),\(got.dy)), jar says (\(row.dx),\(row.dy))")
      }
    }
    #expect(mismatches.isEmpty, "\(mismatches.count) divergence(s): \(mismatches.prefix(8))")
  }
}

// MARK: - The real event path
//
// Everything above is arithmetic on `ToolPoint`s. This last suite drives the actual
// `NSResponder` overrides the user's mouse reaches, because that is where the modifier is read
// and where the tolerance latch lives; the two halves of the owner's decision that the
// arithmetic tests cannot see. It needs no window: an `AppearanceCanvasNSView` with a frame and
// a synthetic `NSEvent` is enough.

@MainActor
private final class RecordingDelegate: AppearanceCanvasDelegate {
  var dragging: [(dx: Int, dy: Int)] = []
  var committed: [(dx: Int, dy: Int)] = []
  func appearanceCanvasDidClick(_ shape: CanvasObject?, extending: Bool) {}
  func appearanceCanvasIsDragging(dx: Int, dy: Int) { dragging.append((dx, dy)) }
  func appearanceCanvasDidDrag(dx: Int, dy: Int) { committed.append((dx, dy)) }
}

@MainActor
private func makeView(shapeAt origin: (x: Int, y: Int))
  -> (view: AppearanceCanvasNSView, recorder: RecordingDelegate)
{
  let view = AppearanceCanvasNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
  var build = AppearanceSceneBuild()
  build.shapes = [DrawRectangle(x: origin.x, y: origin.y, w: 30, h: 20)]
  build.bounds = [CGRect(x: origin.x, y: origin.y, width: 30, height: 20)]
  view.build = build
  view.selectedIndices = [0]
  let recorder = RecordingDelegate()
  view.delegate = recorder
  return (view, recorder)
}

private func mouseEvent(
  _ type: NSEvent.EventType, at point: CGPoint, mods: NSEvent.ModifierFlags
) -> NSEvent {
  NSEvent.mouseEvent(
    with: type, location: point, modifierFlags: mods, timestamp: 0, windowNumber: 0,
    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
}

/// The raw integer delta between two window points, derived the way the view derives it, so the
/// assertions below can say "unsnapped" without re-running the code under test.
@MainActor
private func rawDelta(_ view: AppearanceCanvasNSView, from press: CGPoint, to drag: CGPoint)
  -> (dx: Int, dy: Int)
{
  let p = view.worldPoint(view.convert(press, from: nil))
  let d = view.worldPoint(view.convert(drag, from: nil))
  return (
    CanvasGrid.circuitCoordinate(d.x) - CanvasGrid.circuitCoordinate(p.x),
    CanvasGrid.circuitCoordinate(d.y) - CanvasGrid.circuitCoordinate(p.y)
  )
}

@Suite("Appearance-editor drag parity, through the real event path")
struct AppearanceSnapEventPathTests {

  private static let press = CGPoint(x: 50, y: 50)
  private static let drag = CGPoint(x: 63, y: 57)

  /// The owner's decision at the surface a user touches: no modifier and Option both leave the
  /// shape exactly where the pointer put it. Option was the port's old "disable snapping"
  /// modifier; upstream never reads `ALT_DOWN_MASK` in this branch, so it must be inert, which
  /// is only observable if the unmodified case is *already* unsnapped.
  @Test @MainActor func noModifierAndOptionBothPlaceFreely() throws {
    for mods in [NSEvent.ModifierFlags(), .option] as [NSEvent.ModifierFlags] {
      let (view, recorder) = makeView(shapeAt: (x: 103, y: 107))
      let raw = rawDelta(view, from: Self.press, to: Self.drag)

      view.mouseDown(with: mouseEvent(.leftMouseDown, at: Self.press, mods: mods))
      view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: Self.drag, mods: mods))

      let got = try #require(recorder.dragging.last)
      #expect(got.dx == raw.dx && got.dy == raw.dy, "mods=\(mods.rawValue) must not snap")
      // And the shape stays off grid, which is the whole point of a free-placement canvas.
      #expect(CanvasGrid.snapXToGrid(103 + raw.dx) != 103 + raw.dx)
    }
  }

  /// Control is the modifier, and it *enables*. The delta must differ from the free one and
  /// must land the shape on a grid line.
  @Test @MainActor func controlSnapsTheDestinationOntoTheGrid() throws {
    let (view, recorder) = makeView(shapeAt: (x: 103, y: 107))
    let raw = rawDelta(view, from: Self.press, to: Self.drag)

    view.mouseDown(with: mouseEvent(.leftMouseDown, at: Self.press, mods: .control))
    view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: Self.drag, mods: .control))

    let got = try #require(recorder.dragging.last)
    #expect(got.dx != raw.dx || got.dy != raw.dy, "Control must change the answer")
    #expect(CanvasGrid.snapXToGrid(103 + got.dx) == 103 + got.dx)
    #expect(CanvasGrid.snapYToGrid(107 + got.dy) == 107 + got.dy)
  }

  /// `DRAG_TOLERANCE`: a press with a tremor inside it moves nothing and commits nothing. With
  /// the port's old always-snap behaviour this was masked, a 1-unit delta rounded to 0, so it
  /// only becomes load-bearing now that placement is free.
  @Test @MainActor func aTremorInsideTheToleranceNeitherPreviewsNorCommits() {
    let (view, recorder) = makeView(shapeAt: (x: 103, y: 107))
    let jitter = CGPoint(x: Self.press.x + 1, y: Self.press.y + 1)

    view.mouseDown(with: mouseEvent(.leftMouseDown, at: Self.press, mods: []))
    view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: jitter, mods: []))
    view.mouseUp(with: mouseEvent(.leftMouseUp, at: jitter, mods: []))

    #expect(recorder.dragging.isEmpty, "|1| + |1| does not beat DRAG_TOLERANCE = 2")
    #expect(recorder.committed.isEmpty, "and mouseReleased commits nothing while ineffective")
  }

  /// Once the tolerance is beaten the gesture latches effective for the rest of the drag, so
  /// coming back near the press point still reports: upstream never un-latches `dragEffective`.
  @Test @MainActor func onceEffectiveTheGestureStaysEffective() {
    let (view, recorder) = makeView(shapeAt: (x: 103, y: 107))
    view.mouseDown(with: mouseEvent(.leftMouseDown, at: Self.press, mods: []))
    view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: Self.drag, mods: []))
    #expect(recorder.dragging.count == 1)

    let backNearStart = CGPoint(x: Self.press.x + 1, y: Self.press.y)
    view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: backNearStart, mods: []))
    #expect(recorder.dragging.count == 2, "still latched")
    #expect(recorder.dragging.last?.dx == rawDelta(view, from: Self.press, to: backNearStart).dx)
  }

  /// `mouseReleased` re-runs `setMouse` on the release event rather than reusing the last
  /// preview, so the modifier state at release is what gets committed. Press and drag free,
  /// release with Control: the committed delta is the snapped one.
  @Test @MainActor func theModifierAtReleaseIsWhatGetsCommitted() throws {
    let (view, recorder) = makeView(shapeAt: (x: 103, y: 107))
    let raw = rawDelta(view, from: Self.press, to: Self.drag)

    view.mouseDown(with: mouseEvent(.leftMouseDown, at: Self.press, mods: []))
    view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: Self.drag, mods: []))
    #expect(recorder.dragging.last?.dx == raw.dx)

    view.mouseUp(with: mouseEvent(.leftMouseUp, at: Self.drag, mods: .control))
    let done = try #require(recorder.committed.last)
    #expect(done.dx != raw.dx, "the release modifier re-snapped it")
    #expect(CanvasGrid.snapXToGrid(103 + done.dx) == 103 + done.dx)
  }

  /// Java's `Math.round` is `floor(v + 0.5)`; Swift's `.rounded()` is away-from-zero. They part
  /// on every negative half-integer, and a pointer on a Retina display genuinely lands on one;
  /// `NSEvent.locationInWindow` is a `CGFloat`, not an integer.
  ///
  /// This test exists because of a **green red-probe**: substituting `Int(w.x.rounded())` for
  /// `CanvasGrid.circuitCoordinate` in the event path passed everything else in this file, since
  /// the default camera maps integer view points to integer world points, where the two rules
  /// agree. The `#require`s below fail loudly rather than going vacuous if the camera changes.
  @Test @MainActor func aNegativeHalfIntegerPointerFollowsJavasRoundNotSwifts() throws {
    let (view, recorder) = makeView(shapeAt: (x: 103, y: 107))
    let pressPoint = CGPoint(x: 50, y: 50)
    let dragPoint = CGPoint(x: 70.5, y: 50)

    // Preconditions: one endpoint integral, the other a NEGATIVE half-integer.
    let pressWorld = view.worldPoint(view.convert(pressPoint, from: nil)).x
    let dragWorld = view.worldPoint(view.convert(dragPoint, from: nil)).x
    try #require(pressWorld.truncatingRemainder(dividingBy: 1) == 0, "press is integral")
    try #require(dragWorld < 0, "and the drag point is left of the origin")
    try #require(
      dragWorld.truncatingRemainder(dividingBy: 1).magnitude == 0.5, "on a half-integer")

    // The two rules disagree here, which is the whole reason the test can see anything.
    let javaRule = CanvasGrid.circuitCoordinate(dragWorld) - CanvasGrid.circuitCoordinate(pressWorld)
    let swiftRule = Int(dragWorld.rounded()) - Int(pressWorld.rounded())
    #expect(javaRule != swiftRule, "floor(v+0.5) vs away-from-zero must differ at \(dragWorld)")

    view.mouseDown(with: mouseEvent(.leftMouseDown, at: pressPoint, mods: []))
    view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: dragPoint, mods: []))

    let got = try #require(recorder.dragging.last)
    #expect(got.dx == javaRule, "the port must follow Math.round, not Swift's rounding")
    #expect(got.dx != swiftRule)
  }

  /// A press and release with no drag at all commits nothing; `dragEffective` never latched.
  /// This is what keeps a plain click on a shape from becoming an undo entry.
  @Test @MainActor func aPlainClickCommitsNothing() {
    let (view, recorder) = makeView(shapeAt: (x: 103, y: 107))
    view.mouseDown(with: mouseEvent(.leftMouseDown, at: Self.press, mods: []))
    view.mouseUp(with: mouseEvent(.leftMouseUp, at: Self.press, mods: []))
    #expect(recorder.committed.isEmpty)

    // Even with Control held, which would otherwise produce a non-zero pull onto the grid.
    let (view2, recorder2) = makeView(shapeAt: (x: 103, y: 107))
    view2.mouseDown(with: mouseEvent(.leftMouseDown, at: Self.press, mods: .control))
    view2.mouseUp(with: mouseEvent(.leftMouseUp, at: Self.press, mods: .control))
    #expect(recorder2.committed.isEmpty)
  }
}
