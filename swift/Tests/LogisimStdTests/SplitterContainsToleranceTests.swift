// SplitterContainsToleranceTests.swift: part of logisim-evolved.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// The gate for `Splitter.contains(Location)`'s HIT-TEST TOLERANCE, which nothing else can see.
//
// `Splitter.contains` (`Splitter.java:136-149`, reference tree upstream-java-4.1.0) opens with
// `super.contains(loc)`. Resolving that super call is the whole point of this file:
//
//     Splitter extends ManagedComponent extends AbstractComponent
//
// and `ManagedComponent` declares NO `contains` of its own, verified against the shipping
// 4.1.0 jar's bytecode, not the source tree (`/Applications/Logisim-evolution.app/Contents/app/
// logisim-evolution-4.1.0-all.jar`, `ManagedComponent.class` method table: `<init>`,
// `addComponentListener`, `clearManager`, `expose`, `fire*`, `get*`, `propagate`,
// `recomputeBounds`, `remove*`, `set*`, no `contains`). So `super.contains` binds to
// `AbstractComponent.java:19-23`:
//
//     final var bds = getBounds();
//     if (bds == null) return false;
//     return bds.contains(pt, 1); // <-- allowed error 1, NOT 0
//
// The port shipped `bounds.contains(point)`, whose `allowedError` defaults to 0, so a click
// landing exactly on the splitter's boundary pixel selected the splitter in 4.1.0 and missed
// here. Splitter.swift's own comment predicted this ("If `ManagedComponent.contains` turns out
// to differ, only this one guard needs revisiting").
//
// ── Why this needs a dedicated unit test ────────────────────────────────────────────────────
//
// NO EXISTING GATE COVERS IT, and none easily could: hit-test tolerance is not serialised, so
// the canonical, migration and edit-parity gates are all structurally blind to it. The defect
// is a one-pixel-wide ring around the component that only a click can reach.
//
// So the assertions below are deliberately written to pin the TOLERANCE, not the geometry. Each
// probe point is derived from `splitter.bounds` at run time (`b.x - 1`, `b.x + b.width`, …);
// the exact ring `allowedError: 1` admits and `allowedError: 0` rejects. If a future attribute
// change moves the splitter's box, these tests follow it; they only fail if the tolerance
// itself changes. The literal box is asserted once, separately, purely so a geometry drift
// reports as "the box moved" rather than as a confusing tolerance failure.
//
// ── Bounds.contains's asymmetry is load-bearing here ────────────────────────────────────────
//
// `Bounds.contains(px, py, allowedError)` (`Bounds.java:148-153`, ported verbatim at
// `LogisimKernel/Bounds.swift:153-158`) is half-open on the high side:
//
//     px >= x - e && px < x + wid + e && py >= y - e && py < y + ht + e
//
// so with `e == 0` the admitted x range is `[x, x + wid - 1]` and with `e == 1` it is
// `[x - 1, x + wid]`. The ring this file probes is therefore the four lines
// `x - 1`, `x + wid`, `y - 1`, `y + ht`, and `x - 2` / `x + wid + 1` must stay OUT, which is
// what stops the fix from being "widen it until the test passes".

import Foundation
import LogisimKernel
import Testing

@testable import LogisimStd

@Suite("Splitter.contains — hit-test tolerance (AbstractComponent's allowed error of 1)")
struct SplitterContainsToleranceTests {

  /// A default splitter: `SplitterAttributes()`'s own defaults, i.e. facing EAST, appearance
  /// LEFT, spacing 1, fanout 2: placed at a round location well away from the origin so that a
  /// sign error in a probe offset cannot accidentally land on a coincidentally-valid pixel.
  private static let origin = Location.create(100, 100, hasToSnap: true)

  private func makeSplitter() -> Splitter {
    Splitter(location: Self.origin, attributes: SplitterAttributes())
  }

  // ── 0. Geometry, asserted once so a drift reports as a drift ───────────────────────────────

  /// Not the point of the file, but pinned so that if `SplitterParameters` or
  /// `SplitterFactory.offsetBounds` ever moves the box, the failure says so directly instead of
  /// surfacing as an inexplicable tolerance failure three tests down.
  ///
  /// `SplitterParameters(attrs)` for facing EAST / appearance LEFT (`justify == -1`), `width`
  /// 20, `gap == spacing * 10 == 10`, `m == 1`: `end0X == 20`,
  /// `end0Y == -(10 + gap * (fanout - 1)) == -20`, `endToEndDeltaY == 10`.
  /// `SplitterFactory.offsetBounds` then unions `(0,0,1,1)` with `(20, -20)` and `(20, -10)`,
  /// giving `Bounds(0, -20, 21, 21)`; translated to (100, 100) that is `Bounds(100, 80, 21, 21)`.
  @Test("The default splitter's box is (100, 80, 21, 21) — geometry drift guard")
  func defaultSplitterBounds() {
    let b = makeSplitter().bounds
    #expect(b.x == 100)
    #expect(b.y == 80)
    #expect(b.width == 21)
    #expect(b.height == 21)
  }

  // ── 1. The ring: exactly on the boundary pixel, which 4.1.0 accepts ────────────────────────

  /// The right-hand boundary column, `x == b.x + b.width`. `Bounds.contains(_:0)` rejects it
  /// (`px < x + wid` fails); `Bounds.contains(_:1)` admits it.
  ///
  /// This point also clears `Splitter.contains`'s own second arm: the splitter faces EAST, so
  /// the arm is `abs(loc.x - myLoc.x) > 5 || manhattanDistanceTo(myLoc) <= 5`, and
  /// `|121 - 100| == 21 > 5`. So a `false` here can only come from the tolerance.
  @Test("A click exactly on the right boundary column selects, as 4.1.0 does")
  func rightBoundaryColumnHits() {
    let splitter = makeSplitter()
    let b = splitter.bounds
    let onBoundary = Location.create(b.x + b.width, Self.origin.y, hasToSnap: false)

    // The premise: this pixel is outside the zero-tolerance box and inside the 1-tolerance box.
    #expect(b.contains(onBoundary, 0) == false)
    #expect(b.contains(onBoundary, 1) == true)

    #expect(splitter.contains(onBoundary) == true)
  }

  /// The left-hand boundary column, `x == b.x - 1`. Here the second arm is satisfied by the
  /// OTHER disjunct, `|99 - 100| == 1`, not `> 5`, so it relies on
  /// `manhattanDistanceTo(myLoc) == 1 <= 5`. Both arms of `Splitter.contains`'s own test are
  /// therefore exercised across this file, not just the easy one.
  @Test("A click exactly on the left boundary column selects, as 4.1.0 does")
  func leftBoundaryColumnHits() {
    let splitter = makeSplitter()
    let b = splitter.bounds
    let onBoundary = Location.create(b.x - 1, Self.origin.y, hasToSnap: false)

    #expect(b.contains(onBoundary, 0) == false)
    #expect(b.contains(onBoundary, 1) == true)

    #expect(splitter.contains(onBoundary) == true)
  }

  /// The bottom boundary row, `y == b.y + b.height`, at an x far enough from the splitter's
  /// location that the facing arm passes on `abs(dx) > 5`.
  @Test("A click exactly on the bottom boundary row selects, as 4.1.0 does")
  func bottomBoundaryRowHits() {
    let splitter = makeSplitter()
    let b = splitter.bounds
    let onBoundary = Location.create(Self.origin.x + 10, b.y + b.height, hasToSnap: false)

    #expect(b.contains(onBoundary, 0) == false)
    #expect(b.contains(onBoundary, 1) == true)

    #expect(splitter.contains(onBoundary) == true)
  }

  /// The top boundary row, `y == b.y - 1`, likewise.
  @Test("A click exactly on the top boundary row selects, as 4.1.0 does")
  func topBoundaryRowHits() {
    let splitter = makeSplitter()
    let b = splitter.bounds
    let onBoundary = Location.create(Self.origin.x + 10, b.y - 1, hasToSnap: false)

    #expect(b.contains(onBoundary, 0) == false)
    #expect(b.contains(onBoundary, 1) == true)

    #expect(splitter.contains(onBoundary) == true)
  }

  // ── 2. One pixel further out still misses; the tolerance is 1, not "generous" ─────────────

  /// Without this, "widen the box until the boundary test passes" would also pass. `allowedError`
  /// is exactly 1 in `AbstractComponent`, so the second ring out must still be a miss even though
  /// its facing arm is satisfied.
  @Test("One pixel beyond the tolerance ring still misses — the error allowed is exactly 1")
  func twoPixelsOutMisses() {
    let splitter = makeSplitter()
    let b = splitter.bounds

    let farRight = Location.create(b.x + b.width + 1, Self.origin.y, hasToSnap: false)
    let farLeft = Location.create(b.x - 2, Self.origin.y, hasToSnap: false)
    let farBottom = Location.create(Self.origin.x + 10, b.y + b.height + 1, hasToSnap: false)
    let farTop = Location.create(Self.origin.x + 10, b.y - 2, hasToSnap: false)

    for point in [farRight, farLeft, farBottom, farTop] {
      #expect(b.contains(point, 1) == false)
      #expect(splitter.contains(point) == false)
    }
  }

  // ── 3. The wedge cut-out is unchanged; the box test is a guard, not the whole answer ──────

  /// `Splitter.contains`'s second arm carves the diagonal wedge near the splitter's own location
  /// out of the box. Widening the box guard must not have swallowed it. `(103, 97)` is squarely
  /// inside `Bounds(100, 80, 21, 21)` even at tolerance 0, but `|103 - 100| == 3` is not `> 5`
  /// and the Manhattan distance `3 + 3 == 6` is not `<= 5`, so 4.1.0 rejects it.
  @Test("The near-corner wedge is still excluded — the facing arm still bites")
  func wedgeCutOutStillExcluded() {
    let splitter = makeSplitter()
    let b = splitter.bounds
    let inWedge = Location.create(Self.origin.x + 3, Self.origin.y - 3, hasToSnap: false)

    #expect(b.contains(inWedge, 0) == true)  // well inside the box, at any tolerance
    #expect(splitter.contains(inWedge) == false)
  }

  /// The complementary case: a point at Manhattan distance exactly 5 from the splitter's own
  /// location IS admitted (`<= 5`), pinning the boundary of the wedge itself.
  @Test("Manhattan distance exactly 5 from the splitter's location is admitted")
  func wedgeBoundaryIncluded() {
    let splitter = makeSplitter()
    let onWedgeEdge = Location.create(Self.origin.x + 3, Self.origin.y - 2, hasToSnap: false)
    #expect(splitter.contains(onWedgeEdge) == true)
  }
}
