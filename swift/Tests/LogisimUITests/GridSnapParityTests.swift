// GridSnapParityTests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// WHERE A DROPPED COMPONENT LANDS, CHECKED AGAINST THE SHIPPED 4.1.0 JAR
//
// Snapping is the one piece of UI arithmetic that writes itself into the saved file: it decides
// the integers in `<comp loc="(x,y)"/>` and `<wire from=… to=…/>`. A port that snaps *almost*
// like upstream still round-trips its own files byte-exactly, so every serialisation gate in this
// repo stays green while every component sits on the wrong grid line. Nothing else here would
// notice. Hence this file.
//
// ── THE ORACLE ───────────────────────────────────────────────────────────────────────────────
//
// Every expectation below was produced by *executing* 4.1.0's bytecode: not by reading it.
// The harness reflected into the shipped jar and printed a TSV:
//
//   javac -cp /Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar …
//   java  -Djava.awt.headless=true -cp .:<that jar> Oracle
//
//     Canvas.snapXToGrid(int) / snapYToGrid(int) : com.cburch.logisim.gui.main.Canvas
//     Location.create(int, int, boolean)         : com.cburch.logisim.data.Location
//     (int) Math.round(px / zoom)                : Canvas.zoomEvent, then snapXToGrid
//
// The tables are the harness's stdout, transformed to Swift literals by script. They are NOT
// hand-typed, and they are NOT derived from `src/main/java` in this repo; that tree is upstream
// *main*, not 4.1.0, and citing it has been wrong five times.
//
// ── THE TWO SNAPS, WHICH ARE DIFFERENT FUNCTIONS ON DIFFERENT GRIDS ──────────────────────────
//
// It is easy to assume there is one. There are two, and conflating them is the whole hazard:
//
//   Canvas.snapXToGrid(x)          10-unit grid, round-half-AWAY-FROM-ZERO
//                                    x >= 0 : ((x + 5) / 10) * 10
//                                    x <  0 : -(((-x + 5) / 10) * 10)
//                                  So 5 -> 10 and -5 -> -10, but 4 -> 0 and -4 -> 0.
//
//   Location.create(x, y, true)     5-unit grid, TRUNCATE-TOWARD-ZERO
//                                    Math.round((float)(x / 5)) * 5
//                                  `x / 5` is *integer* division, so Math.round is handed an
//                                  already-integral float and is a no-op: the whole expression
//                                  collapses to (x / 5) * 5. So 9 -> 5 and -9 -> -5, never
//                                  "nearest". Verified by execution, not by reading: the jar
//                                  answers locationSnap(9) = 5, not 10.
//
// The second is upstream's, quirk and all, and this port reproduces it deliberately. It is not
// a bug to be fixed here; changing it would move every port location of every stock component.
//
// ── NEGATIVE COORDINATES ARE REACHABLE, AND ARE WHERE NAIVE ROUNDING DIVERGES ────────────────
//
// A user can drag above and left of the origin. Three separate rounding rules disagree there and
// agree everywhere else, which is exactly why this went unnoticed:
//
//   input   upstream 10-grid   Swift `(x/10).rounded()*10`   Swift `Int(x/10)*10`
//   -5      -10                -10                            0      <- truncation is wrong
//   -4        0                  0                            0
//    5       10                 10                            0
//
// and on the *world* (pre-integerisation) side:
//
//   world   upstream   `(w/10).rounded()*10`
//    4.6      10        0    <- upstream integerises FIRST (Math.round(4.6) = 5, then 5 -> 10),
//                            so its threshold is 4.5, not 5.0
//
// ── WHAT THIS FILE DOES NOT COVER ────────────────────────────────────────────────────────────
//
// `GridSnap` in LogisimRenderBackend is *not* grid snapping. It is Java2D's
// KEY_STROKE_CONTROL / VALUE_STROKE_NORMALIZE; the half-device-pixel nudge that keeps a
// 1-unit pen from smearing across two rows. It never touches a model coordinate.
// `GridSnapTests` in LogisimRenderBackendTests pins that, and nothing here weakens it.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import CoreGraphics
import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd
import Testing

@testable import LogisimUI

// MARK: - Oracle tables (stdout of the 4.1.0 jar harness, scripted into Swift)

/// `com.cburch.logisim.gui.main.Canvas.snapXToGrid(int)`, executed. The harness asserted
/// `snapXToGrid == snapYToGrid` on every row before emitting, so one column serves both.
private let canvasSnapOracle: [(input: Int, snapped: Int)] = [
  (-37, -40), (-36, -40), (-35, -40), (-34, -30), (-33, -30), (-32, -30),
  (-31, -30), (-30, -30), (-29, -30), (-28, -30), (-27, -30), (-26, -30),
  (-25, -30), (-24, -20), (-23, -20), (-22, -20), (-21, -20), (-20, -20),
  (-19, -20), (-18, -20), (-17, -20), (-16, -20), (-15, -20), (-14, -10),
  (-13, -10), (-12, -10), (-11, -10), (-10, -10), (-9, -10), (-8, -10),
  (-7, -10), (-6, -10), (-5, -10), (-4, 0), (-3, 0), (-2, 0),
  (-1, 0), (0, 0), (1, 0), (2, 0), (3, 0), (4, 0),
  (5, 10), (6, 10), (7, 10), (8, 10), (9, 10), (10, 10),
  (11, 10), (12, 10), (13, 10), (14, 10), (15, 20), (16, 20),
  (17, 20), (18, 20), (19, 20), (20, 20), (21, 20), (22, 20),
  (23, 20), (24, 20), (25, 30), (26, 30), (27, 30), (28, 30),
  (29, 30), (30, 30), (31, 30), (32, 30), (33, 30), (34, 30),
  (35, 40), (36, 40), (37, 40), (-100, -100), (-95, -100), (-91, -90),
  (-90, -90), (-89, -90), (-85, -90), (-80, -80), (-75, -80), (-55, -60),
  (-50, -50), (-45, -50), (-44, -40), (44, 40), (45, 50), (50, 50),
  (55, 60), (75, 80), (80, 80), (85, 90), (89, 90), (90, 90),
  (91, 90), (95, 100), (100, 100),
]

/// The same call at Java's `int` boundaries. `snapXToGrid` adds 5 before dividing, so a
/// coordinate within 5 of `Integer.MAX_VALUE` overflows and comes back *negative*: Java wraps,
/// it does not saturate. Swift's `Int` is 64-bit and would simply not overflow, giving a
/// different answer; `wrap32` is what makes the two agree.
private let canvasSnapOverflowOracle: [(input: Int, snapped: Int)] = [
  (2_147_483_647, -2_147_483_640),
  (-2_147_483_648, 2_147_483_640),
  (2_147_483_642, 2_147_483_640),
  (-2_147_483_643, 2_147_483_640),
  (1_073_741_824, 1_073_741_820),
  (-1_073_741_824, -1_073_741_820),
]

/// `com.cburch.logisim.data.Location.create(x, 0, true).getX()`, executed.
private let locationSnapOracle: [(input: Int, snapped: Int)] = [
  (-37, -35), (-36, -35), (-35, -35), (-34, -30), (-33, -30), (-32, -30),
  (-31, -30), (-30, -30), (-29, -25), (-28, -25), (-27, -25), (-26, -25),
  (-25, -25), (-24, -20), (-23, -20), (-22, -20), (-21, -20), (-20, -20),
  (-19, -15), (-18, -15), (-17, -15), (-16, -15), (-15, -15), (-14, -10),
  (-13, -10), (-12, -10), (-11, -10), (-10, -10), (-9, -5), (-8, -5),
  (-7, -5), (-6, -5), (-5, -5), (-4, 0), (-3, 0), (-2, 0),
  (-1, 0), (0, 0), (1, 0), (2, 0), (3, 0), (4, 0),
  (5, 5), (6, 5), (7, 5), (8, 5), (9, 5), (10, 10),
  (11, 10), (12, 10), (13, 10), (14, 10), (15, 15), (16, 15),
  (17, 15), (18, 15), (19, 15), (20, 20), (21, 20), (22, 20),
  (23, 20), (24, 20), (25, 25), (26, 25), (27, 25), (28, 25),
  (29, 25), (30, 30), (31, 30), (32, 30), (33, 30), (34, 30),
  (35, 35), (36, 35), (37, 35), (-100, -100), (-95, -95), (-91, -90),
  (-90, -90), (-89, -85), (-85, -85), (-80, -80), (-75, -75), (-55, -55),
  (-50, -50), (-45, -45), (-44, -40), (44, 40), (45, 45), (50, 50),
  (55, 55), (75, 75), (80, 80), (85, 85), (89, 85), (90, 90),
  (91, 90), (95, 95), (100, 100),
]

/// `Location.create` at the `int` boundaries. These rows are the reason the port routes through
/// `javaMathRoundOfInt` rather than trusting `(x / 5) * 5`: above 2^24 a `float` cannot hold every
/// `int`, so the widening inside `Math.round((float)(x / 5))` is lossy and the jar answers
/// `1073741840` for an input of `1073741824`: a value *larger* than the input, off the 5-grid
/// in the direction exact arithmetic would never go.
private let locationSnapOverflowOracle: [(input: Int, snapped: Int)] = [
  (2_147_483_647, -2_147_483_616),
  (-2_147_483_648, 2_147_483_616),
  (2_147_483_642, -2_147_483_616),
  (-2_147_483_643, 2_147_483_616),
  (1_073_741_824, 1_073_741_840),
  (-1_073_741_824, -1_073_741_840),
]

/// The composite the canvas actually applies to a pointer: `Canvas.zoomEvent` first, which is
/// `(int) Math.round(px / zoom)`, then `Canvas.snapXToGrid` on that integer. Columns are
/// (world value at zoom 1, the integer upstream forms, the grid coordinate it lands on).
private let worldSnapOracle: [(world: Double, asInt: Int, snapped: Int)] = [
  (-25.0, -25, -30), (-24.75, -25, -30), (-24.5, -24, -20),
  (-24.25, -24, -20), (-24.0, -24, -20), (-23.75, -24, -20),
  (-23.5, -23, -20), (-23.25, -23, -20), (-23.0, -23, -20),
  (-22.75, -23, -20), (-22.5, -22, -20), (-22.25, -22, -20),
  (-22.0, -22, -20), (-21.75, -22, -20), (-21.5, -21, -20),
  (-21.25, -21, -20), (-21.0, -21, -20), (-20.75, -21, -20),
  (-20.5, -20, -20), (-20.25, -20, -20), (-20.0, -20, -20),
  (-19.75, -20, -20), (-19.5, -19, -20), (-19.25, -19, -20),
  (-19.0, -19, -20), (-18.75, -19, -20), (-18.5, -18, -20),
  (-18.25, -18, -20), (-18.0, -18, -20), (-17.75, -18, -20),
  (-17.5, -17, -20), (-17.25, -17, -20), (-17.0, -17, -20),
  (-16.75, -17, -20), (-16.5, -16, -20), (-16.25, -16, -20),
  (-16.0, -16, -20), (-15.75, -16, -20), (-15.5, -15, -20),
  (-15.25, -15, -20), (-15.0, -15, -20), (-14.75, -15, -20),
  (-14.5, -14, -10), (-14.25, -14, -10), (-14.0, -14, -10),
  (-13.75, -14, -10), (-13.5, -13, -10), (-13.25, -13, -10),
  (-13.0, -13, -10), (-12.75, -13, -10), (-12.5, -12, -10),
  (-12.25, -12, -10), (-12.0, -12, -10), (-11.75, -12, -10),
  (-11.5, -11, -10), (-11.25, -11, -10), (-11.0, -11, -10),
  (-10.75, -11, -10), (-10.5, -10, -10), (-10.25, -10, -10),
  (-10.0, -10, -10), (-9.75, -10, -10), (-9.5, -9, -10),
  (-9.25, -9, -10), (-9.0, -9, -10), (-8.75, -9, -10),
  (-8.5, -8, -10), (-8.25, -8, -10), (-8.0, -8, -10),
  (-7.75, -8, -10), (-7.5, -7, -10), (-7.25, -7, -10),
  (-7.0, -7, -10), (-6.75, -7, -10), (-6.5, -6, -10),
  (-6.25, -6, -10), (-6.0, -6, -10), (-5.75, -6, -10),
  (-5.5, -5, -10), (-5.25, -5, -10), (-5.0, -5, -10),
  (-4.75, -5, -10), (-4.5, -4, 0), (-4.25, -4, 0),
  (-4.0, -4, 0), (-3.75, -4, 0), (-3.5, -3, 0),
  (-3.25, -3, 0), (-3.0, -3, 0), (-2.75, -3, 0),
  (-2.5, -2, 0), (-2.25, -2, 0), (-2.0, -2, 0),
  (-1.75, -2, 0), (-1.5, -1, 0), (-1.25, -1, 0),
  (-1.0, -1, 0), (-0.75, -1, 0), (-0.5, 0, 0),
  (-0.25, 0, 0), (0.0, 0, 0), (0.25, 0, 0),
  (0.5, 1, 0), (0.75, 1, 0), (1.0, 1, 0),
  (1.25, 1, 0), (1.5, 2, 0), (1.75, 2, 0),
  (2.0, 2, 0), (2.25, 2, 0), (2.5, 3, 0),
  (2.75, 3, 0), (3.0, 3, 0), (3.25, 3, 0),
  (3.5, 4, 0), (3.75, 4, 0), (4.0, 4, 0),
  (4.25, 4, 0), (4.5, 5, 10), (4.75, 5, 10),
  (5.0, 5, 10), (5.25, 5, 10), (5.5, 6, 10),
  (5.75, 6, 10), (6.0, 6, 10), (6.25, 6, 10),
  (6.5, 7, 10), (6.75, 7, 10), (7.0, 7, 10),
  (7.25, 7, 10), (7.5, 8, 10), (7.75, 8, 10),
  (8.0, 8, 10), (8.25, 8, 10), (8.5, 9, 10),
  (8.75, 9, 10), (9.0, 9, 10), (9.25, 9, 10),
  (9.5, 10, 10), (9.75, 10, 10), (10.0, 10, 10),
  (10.25, 10, 10), (10.5, 11, 10), (10.75, 11, 10),
  (11.0, 11, 10), (11.25, 11, 10), (11.5, 12, 10),
  (11.75, 12, 10), (12.0, 12, 10), (12.25, 12, 10),
  (12.5, 13, 10), (12.75, 13, 10), (13.0, 13, 10),
  (13.25, 13, 10), (13.5, 14, 10), (13.75, 14, 10),
  (14.0, 14, 10), (14.25, 14, 10), (14.5, 15, 20),
  (14.75, 15, 20), (15.0, 15, 20), (15.25, 15, 20),
  (15.5, 16, 20), (15.75, 16, 20), (16.0, 16, 20),
  (16.25, 16, 20), (16.5, 17, 20), (16.75, 17, 20),
  (17.0, 17, 20), (17.25, 17, 20), (17.5, 18, 20),
  (17.75, 18, 20), (18.0, 18, 20), (18.25, 18, 20),
  (18.5, 19, 20), (18.75, 19, 20), (19.0, 19, 20),
  (19.25, 19, 20), (19.5, 20, 20), (19.75, 20, 20),
  (20.0, 20, 20), (20.25, 20, 20), (20.5, 21, 20),
  (20.75, 21, 20), (21.0, 21, 20), (21.25, 21, 20),
  (21.5, 22, 20), (21.75, 22, 20), (22.0, 22, 20),
  (22.25, 22, 20), (22.5, 23, 20), (22.75, 23, 20),
  (23.0, 23, 20), (23.25, 23, 20), (23.5, 24, 20),
  (23.75, 24, 20), (24.0, 24, 20), (24.25, 24, 20),
  (24.5, 25, 30), (24.75, 25, 30), (25.0, 25, 30),
  (4.49, 4, 0), (4.51, 5, 10), (4.99, 5, 10),
  (5.01, 5, 10), (-4.49, -4, 0), (-4.51, -5, -10),
  (-4.99, -5, -10), (-5.01, -5, -10), (-0.49, 0, 0),
  (14.49, 14, 10), (-14.49, -14, -10),
]

// MARK: - The suite

@Suite("Grid snapping parity with 4.1.0")
struct GridSnapParityTests {

  // ── Canvas.snapXToGrid ─────────────────────────────────────────────────────────────────────

  /// The function every placement tool routes through. 105 rows straight out of the jar,
  /// spanning negatives, exact multiples of 10, and the exact half-grid points (±5, ±15, ±25,
  /// ±35, ±45, ±55, ±85, ±95) where every plausible rounding rule disagrees.
  @Test func canvasSnapXMatchesTheJarOnNegativesMultiplesAndHalfPoints() {
    var mismatches: [String] = []
    for row in canvasSnapOracle where CanvasGrid.snapXToGrid(row.input) != row.snapped {
      mismatches.append("\(row.input) -> \(CanvasGrid.snapXToGrid(row.input)), jar says \(row.snapped)")
    }
    #expect(mismatches.isEmpty, "\(mismatches.count) divergence(s): \(mismatches.prefix(12))")
  }

  /// Upstream keeps `snapYToGrid` as a separate method with an identical body. If the port ever
  /// specialises one, this catches the other going stale.
  @Test func canvasSnapYIsTheSameFunctionAsSnapX() {
    for row in canvasSnapOracle {
      #expect(CanvasGrid.snapYToGrid(row.input) == row.snapped, "y snap of \(row.input)")
    }
  }

  /// The half-grid point is the whole question, so it gets its own named test rather than
  /// hiding inside a 105-row loop. Upstream rounds it AWAY FROM ZERO in both directions;
  /// it is not round-half-even, and it is not truncation.
  @Test func theExactHalfGridPointRoundsAwayFromZeroInBothDirections() {
    #expect(CanvasGrid.snapXToGrid(5) == 10)
    #expect(CanvasGrid.snapXToGrid(-5) == -10)
    #expect(CanvasGrid.snapXToGrid(15) == 20)
    #expect(CanvasGrid.snapXToGrid(-15) == -20)
    // Round-half-to-even would give 0 and 0 here, and 20/-20 above. It does not.
    #expect(CanvasGrid.snapXToGrid(5) != 0)
    #expect(CanvasGrid.snapXToGrid(-5) != 0)
    // Truncation toward zero would give 0 for every one of these.
    #expect(CanvasGrid.snapXToGrid(-9) == -10)
    #expect(CanvasGrid.snapXToGrid(9) == 10)
    // And just below the half point it does NOT move away from zero.
    #expect(CanvasGrid.snapXToGrid(4) == 0)
    #expect(CanvasGrid.snapXToGrid(-4) == 0)
  }

  /// `snapXToGrid` adds 5 *before* dividing, so it overflows within 5 of `Integer.MAX_VALUE` and
  /// Java's `int` wraps. Swift's 64-bit `Int` would quietly not overflow and answer 2147483650;
  /// a coordinate Java cannot represent, which would then be written into a `.circ` file.
  /// Reachable only via `SelectTool.computeDxDy`, which snaps a *delta*; kept because the port's
  /// own `wrap32` calls are otherwise untested and would look like dead ceremony.
  @Test func canvasSnapWrapsAtThirtyTwoBitsLikeJavasInt() {
    for row in canvasSnapOverflowOracle {
      #expect(CanvasGrid.snapXToGrid(row.input) == row.snapped, "overflow row \(row.input)")
      #expect(CanvasGrid.snapYToGrid(row.input) == row.snapped, "overflow row \(row.input)")
    }
  }

  // ── The second copy of the same upstream function ──────────────────────────────────────────

  /// The port has `Canvas.snapXToGrid` written out twice; `CanvasGrid` for the tools and
  /// `SelectionBase` for the model-side selection move. Upstream has one method; two
  /// transcriptions can drift, and a drift here would move a *dragged* component relative to a
  /// *placed* one, which is the kind of thing you only notice by dragging.
  ///
  /// `@MainActor` because `SelectionBase`'s copy is main-actor-isolated while `CanvasGrid`'s is
  /// not, even though both are pure integer arithmetic on no state at all.
  @Test @MainActor func selectionBaseSnapAgreesWithCanvasGridAndWithTheJar() {
    for row in canvasSnapOracle {
      #expect(SelectionBase.snapXToGrid(row.input) == row.snapped, "SelectionBase x \(row.input)")
      #expect(SelectionBase.snapYToGrid(row.input) == row.snapped, "SelectionBase y \(row.input)")
    }
    for row in canvasSnapOverflowOracle {
      #expect(SelectionBase.snapXToGrid(row.input) == row.snapped, "SelectionBase x \(row.input)")
    }
  }

  // ── Location.create: the OTHER snap, on a 5 grid ──────────────────────────────────────────

  /// Not "nearest multiple of 5". Upstream's `Math.round((float)(x / 5)) * 5` does its division
  /// in `int`, so the round is a no-op and the whole thing truncates toward zero. 9 -> 5, -9 -> -5.
  /// This is upstream's quirk and the port reproduces it on purpose; the test exists so that a
  /// future "obvious cleanup" to round-to-nearest fails loudly instead of silently relocating
  /// every port of every stock component.
  @Test func locationCreateSnapsOnAFiveGridByTruncationNotRounding() {
    var mismatches: [String] = []
    for row in locationSnapOracle {
      let got = Location.create(row.input, 0, hasToSnap: true).x
      if got != row.snapped { mismatches.append("\(row.input) -> \(got), jar says \(row.snapped)") }
      // y goes through the identical branch.
      #expect(Location.create(0, row.input, hasToSnap: true).y == row.snapped)
    }
    #expect(mismatches.isEmpty, "\(mismatches.count) divergence(s): \(mismatches.prefix(12))")
  }

  /// Above 2^24 the `(float)` widening inside `Math.round` is lossy, and the jar's answer stops
  /// being a multiple of 5 in the direction exact arithmetic would produce. If the port ever
  /// "simplifies" to `(x / 5) * 5` these rows go wrong while every ordinary row stays right.
  @Test func locationCreateReproducesJavasLossyFloatWideningAtLargeCoordinates() {
    for row in locationSnapOverflowOracle {
      #expect(Location.create(row.input, 0, hasToSnap: true).x == row.snapped, "row \(row.input)")
      #expect(Location.create(0, row.input, hasToSnap: true).y == row.snapped, "row \(row.input)")
    }
    // Exact integer arithmetic would answer 1073741820 for this; Java answers 1073741840.
    #expect(Location.create(1_073_741_824, 0, hasToSnap: true).x != (1_073_741_824 / 5) * 5)
  }

  /// `hasToSnap: false` must be the identity, including for negatives and for coordinates Java's
  /// `int` cannot hold.
  @Test func locationCreateWithoutSnappingIsTheIdentity() {
    for v in [-37, -5, -4, 0, 4, 5, 37, 12_345, -12_345] {
      #expect(Location.create(v, -v, hasToSnap: false).x == v)
      #expect(Location.create(v, -v, hasToSnap: false).y == -v)
    }
  }

  // ── The composite: pointer -> saved coordinate ─────────────────────────────────────────────

  /// The whole path, end to end, against the jar: upstream integerises the pointer with
  /// `(int) Math.round(px / zoom)` (`Canvas.zoomEvent`) and only then snaps. The port's
  /// `CanvasGrid.circuitCoordinate` + `snapXToGrid` must give the same answer on every row.
  @Test func worldToGridCompositeMatchesTheJar() {
    var mismatches: [String] = []
    for row in worldSnapOracle {
      let asInt = CanvasGrid.circuitCoordinate(row.world)
      let snapped = CanvasGrid.snapXToGrid(asInt)
      if asInt != row.asInt || snapped != row.snapped {
        mismatches.append(
          "w=\(row.world) -> (\(asInt), \(snapped)), jar says (\(row.asInt), \(row.snapped))")
      }
    }
    #expect(mismatches.isEmpty, "\(mismatches.count) divergence(s): \(mismatches.prefix(12))")
  }

  /// `circuitPoint` is what `CanvasToolController` actually calls on the incoming pointer, so it
  /// gets its own row rather than being trusted to be `circuitCoordinate` twice.
  @Test func circuitPointAppliesTheSameRuleToBothAxes() {
    for row in worldSnapOracle {
      let p = CanvasGrid.circuitPoint(CGPoint(x: row.world, y: row.world))
      #expect(p.x == row.asInt && p.y == row.asInt, "circuitPoint at w=\(row.world)")
      let snapped = CanvasGrid.snapToGrid(p)
      #expect(snapped.x == row.snapped && snapped.y == row.snapped, "snapToGrid at w=\(row.world)")
    }
  }

  /// `Math.round` is `floor(v + 0.5)`, which is NOT symmetric about zero: +4.5 goes up to 5 but
  /// -4.5 goes up to -4. Swift's default `.rounded()` is `.toNearestOrAwayFromZero` and would
  /// answer -5 there, which snaps to -10 instead of 0: a whole grid step, only on the negative
  /// side, only at an exact half. That is the single most likely way this port could have gone
  /// wrong above and left of the origin.
  @Test func javaRoundIsFloorPlusHalfAndIsAsymmetricAtExactHalves() {
    #expect(CanvasGrid.circuitCoordinate(4.5) == 5)
    #expect(CanvasGrid.circuitCoordinate(-4.5) == -4)
    #expect(CanvasGrid.circuitCoordinate(-0.5) == 0)
    #expect(CanvasGrid.circuitCoordinate(-2.5) == -2)
    // Swift's own rounding disagrees on exactly these, which is why the port cannot use it.
    #expect(CanvasGrid.circuitCoordinate(-4.5) != Int((-4.5).rounded()))
    #expect(CanvasGrid.circuitCoordinate(-2.5) != Int((-2.5).rounded()))
    // Consequence at the grid: 0, not -10.
    #expect(CanvasGrid.snapXToGrid(CanvasGrid.circuitCoordinate(-4.5)) == 0)
  }

  /// The trap this file exists to nail down. Snapping the *world* value continuously,
  /// `(w / 10).rounded() * 10`, the one-liner anybody would write, puts the 0 -> 10 threshold at
  /// w = 5.0. Upstream's threshold is w = 4.5, because it integerises first. The two disagree
  /// over the half-unit band [4.5, 5.0), and agree everywhere else, so a spot check at 4.0 or
  /// 6.0 would find nothing.
  @Test func continuousWorldRoundingIsNotUpstreamsRuleAndTheBandIsHalfAUnitWide() {
    func naive(_ w: Double) -> Int { Int((w / 10).rounded()) * 10 }
    func upstream(_ w: Double) -> Int { CanvasGrid.snapXToGrid(CanvasGrid.circuitCoordinate(w)) }

    for w in [4.5, 4.6, 4.75, 4.9, 4.99] {
      #expect(upstream(w) == 10, "upstream snaps \(w) to 10")
      #expect(naive(w) == 0, "the naive rule snaps \(w) to 0")
      #expect(upstream(w) != naive(w))
    }
    // Mirror band on the negative side: (-5.0, -4.5] is where they part.
    for w in [-4.51, -4.6, -4.75, -4.9, -4.99] {
      #expect(upstream(w) == -10)
      #expect(naive(w) == 0)
    }
    // Outside the band they agree, which is why this was invisible.
    for w in [-20.0, -12.0, -6.0, 0.0, 6.0, 12.0, 20.0, 4.0, -4.0] {
      #expect(upstream(w) == naive(w), "agreement expected at \(w)")
    }
  }

  // ── Non-finite and out-of-range input ──────────────────────────────────────────────────────

  /// NaN, matched against the jar: `Math.round(NaN)` is 0, and `(int) 0` is 0.
  ///
  /// The larger point of this test is that nothing here traps. A `Double` -> `Int` conversion in
  /// Swift is a *runtime trap* when the value is out of range, and this function sits on the
  /// mouse-move path; a trap here takes the whole editor down mid-gesture, which is a strictly
  /// worse failure than any wrong coordinate.
  ///
  /// ── A MEASURED, DELIBERATELY UNASSERTED DIVERGENCE ──
  ///
  /// The port clamps out-of-range values to `Int32.min`/`Int32.max`. 4.1.0 does not: `zoomEvent`
  /// is `(int) Math.round(px / zoom)`, `Math.round(double)` returns a **long**, and long -> int
  /// narrowing *truncates to the low 32 bits* rather than saturating. Measured by running the
  /// values through JDK 21:
  ///
  ///     input           Math.round (long)        (int) of it     port
  ///     NaN             0                        0               0     agree
  ///     -Infinity       -9223372036854775808     0               0     agree
  ///     +Infinity        9223372036854775807    -1        2147483647   DIFFER
  ///     -2147483648.6   -2147483649              2147483647  -2147483648  DIFFER
  ///
  /// It is not asserted because it is not reachable: producing one of these needs a world
  /// coordinate past ±2^31 or a non-finite viewport scale, and `RenderViewport` sanitises the
  /// scale before any of this runs. Recording the numbers is worth more than pinning behaviour
  /// nothing can trigger, and pinning the port's current answer would just be a change detector
  /// that fires on the correct fix. The one-line note in `ToolGeometry.circuitCoordinate` that
  /// says Java "saturates at Integer.MIN/MAX_VALUE" describes `(int)` of a *double*, not the
  /// `(int)` of a *long* that upstream actually performs, and is wrong on that point.
  @Test func nonFiniteWorldValuesMatchTheJarWhereItMattersAndNeverTrap() {
    #expect(CanvasGrid.circuitCoordinate(.nan) == 0)  // jar: 0
    #expect(CanvasGrid.circuitCoordinate(-.infinity) == 0)  // jar: 0

    // No trap, whatever the answer, for every degenerate input and for snapping it afterwards.
    for w in [Double.nan, .infinity, -.infinity, 1e300, -1e300, 1e18, -1e18] {
      let v = CanvasGrid.circuitCoordinate(w)
      _ = CanvasGrid.snapXToGrid(v)
      _ = CanvasGrid.snapYToGrid(v)
      _ = CanvasGrid.circuitPoint(CGPoint(x: w, y: w))
    }
  }
}

// MARK: - End to end: where a dropped component actually lands
//
// Everything above is arithmetic. This last suite is the sentence about observable output: place
// an AND gate with the real `CanvasAddTool` through the real `CanvasToolController`, then read the
// `Location` the circuit ended up holding; the integer that would be written to the `.circ` file.

@Suite("A dropped component lands where 4.1.0 puts it", .serialized)
struct DroppedComponentLandingTests {

  @MainActor
  private func makeCanvas() throws -> (LogisimFileProjectHost, CircuitEditorCanvas, Circuit) {
    let host = try #require(
      try LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
    _ = host.makeRenderSurface()
    let canvas = try #require(host.editorCanvas)
    let circuit = try #require(host.currentCircuitObject)
    canvas.setCircuit(circuit)
    return (host, canvas, circuit)
  }

  /// Press-then-release at one world point.
  ///
  /// This used to take a second `claimingSnapped:` point, because `CanvasPointerEvent` carried a
  /// `snappedWorld` the shell had precomputed and a test could feed it an absurd value to prove
  /// the tool layer ignored it. That field has since been deleted from the seam; see the note
  /// below where `placementIgnoresTheShellsPrecomputedSnap` used to be.
  @MainActor
  private func drop(_ canvas: CircuitEditorCanvas, at world: CGPoint) {
    for phase in [CanvasPointerEvent.Phase.moved, .down, .up] {
      canvas.controller.canvasHandlePointer(
        CanvasPointerEvent(
          phase: phase,
          world: world,
          modifiers: [],
          clickCount: 1,
          buttonNumber: 1,
          dragOriginWorld: nil))
    }
  }

  /// The band the naive continuous rule gets wrong, driven through the whole editor.
  ///
  /// World x = 104.6. Upstream integerises first, `(int) Math.round(104.6)` is 105, and 105 is
  /// past the half-grid point, so `snapXToGrid` sends it to 110. The one-line continuous rule
  /// `(104.6 / 10).rounded() * 10` answers 100. A user dropping a gate anywhere in that half-unit
  /// band would find it a whole grid step west of the pointer.
  @Test("a gate dropped at 104.6 lands on 110, not 100")
  @MainActor
  func aDroppedGateLandsOnTheGridLine410Chooses() throws {
    let (_, canvas, circuit) = try makeCanvas()
    canvas.controller.setActiveTool(CanvasAddTool(factory: AndGate.factory))

    drop(canvas, at: CGPoint(x: 104.6, y: 104.6))

    let placed = circuit.nonWires.filter { $0.factory is AndGate }
    #expect(placed.count == 1)
    let where0 = try #require(placed.first).location
    #expect(where0 == Location.create(110, 110, hasToSnap: false))
    #expect(where0.x != 100)
  }

  // ── A TEST THAT USED TO BE HERE, AND WHY IT IS NOT ──────────────────────────────────────────
  //
  // `placementIgnoresTheShellsPrecomputedSnap` placed the same gate twice, once with an honest
  // `snappedWorld` and once with an absurd one (-9999, 7777), and asserted the two landed in the
  // same place. That was the measurement behind "the `snapToGrid` preference is inert": the
  // preference only ever changed `snappedWorld`, and `snappedWorld` changed nothing.
  //
  // It was DELETED, not moved, because its subject no longer exists. `CanvasPointerEvent` has no
  // `snappedWorld` field: the shell forwards raw world points and the tools snap for themselves.
  // There is nothing left to feed an absurd value to, so the claim is now enforced by the type
  // system rather than by an assertion, which is strictly stronger, and is why re-expressing the
  // test in some weaker form would have been worse than removing it. A test that cannot fail is
  // not evidence.
  //
  // Nothing observable went with it. What it asserted about placement, that world 104.6 lands on
  // 110, is asserted directly by the test above, and by
  // `SnapSurvivesPreferenceRemovalTests.clickedComponentLandsOnTheGrid` through the app's own
  // interaction handler.

  /// The exact half-grid point, end to end. World 105.0 integerises to 105, which is 10.5 grid
  /// cells: upstream rounds it away from zero to 110. Round-half-to-even would answer 100.
  @Test("the exact half-grid point rounds away from zero, end to end")
  @MainActor
  func theHalfGridPointGoesAwayFromZeroEndToEnd() throws {
    let (_, canvas, circuit) = try makeCanvas()
    canvas.controller.setActiveTool(CanvasAddTool(factory: AndGate.factory))

    drop(canvas, at: CGPoint(x: 105, y: 105))

    let placed = try #require(circuit.nonWires.first { $0.factory is AndGate })
    #expect(placed.location == Location.create(110, 110, hasToSnap: false))
  }
}
