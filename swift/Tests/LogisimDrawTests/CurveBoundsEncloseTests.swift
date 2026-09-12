// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution, which is GPL-3.0-only. This port is a derivative work and is
// therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// A curve left of the origin used to get a bounding box that did not contain it, and a narrow one
// got no box at all.
//
// ── The defect ────────────────────────────────────────────────────────────────────────────────
//
// `CurveUtil.getBounds` (`CurveUtil.java:117-120`) builds the box as
//
//     x = (int) xMin                 w = (int) Math.ceil(xMax) - x
//
// Java's `(int)` truncates **toward zero**. That is `floor` only for non-negative values, so the
// max side rounds outward and the min side rounds *inward* the moment a minimum goes negative and
// fractional. The box stops bounding the curve, and where the span is narrow it collapses to zero.
//
// ── Why this file asserts the fixed behaviour instead of upstream's ────────────────────────────
//
// D18's second arm: unobservable in any gate, and plainly a defect. Bounds never reach a `.circ`
// (`SvgCreator.createCurve` writes only the three control points) and neither `-tty table` nor
// `-tty stats` reads geometry, so no gate can see the change. And a zero-width `Bounds` is inert in
// every consumer that mediates through it; `AbstractCanvasObject.overlaps` returns false on
// `c.width == 0`, `randomPoint(in:)` returns nil on `w <= 0`.
//
// The evidence that it is a slip rather than a decision is the mirror pairs in
// `upstreamRoundsTheMinTowardZero` below: the same shape reflected through x = 0 is handled
// correctly on one side and not the other, purely by sign. `Math.ceil` on the max is the author
// saying outward rounding was the intent.
//
// ── The oracle ────────────────────────────────────────────────────────────────────────────────
//
// Every `upstream:` number here was produced by calling `com.cburch.draw.shapes.CurveUtil.getBounds`
// directly out of `logisim-evolution-4.1.0-all.jar` on the classpath, not read off the Java source.
// They are pinned so that a later edit which "restores fidelity" has to delete an explicit row
// naming the jar rather than quietly flip a cast back.

import Foundation
import Testing

@testable import LogisimDraw
@testable import LogisimKernel

@Suite("A curve's bounds enclose the curve on both sides of the origin")
struct CurveBoundsEncloseTests {

  /// The extremum `getBounds` solves for, in closed form: at `u = -A/B` the value is `p0 - A²/B`.
  /// Derived independently of `getBounds` on purpose; checking the box against the same code that
  /// produced it would assert nothing.
  private static func extremum(_ p0: Double, _ p1: Double, _ p2: Double) -> Double? {
    let a = p1 - p0
    let b = p0 - 2 * p1 + p2
    guard b != 0 else { return nil }
    let u = -a / b
    guard u > 0, u < 1 else { return nil }
    return p0 - a * a / b
  }

  /// The real claim: every point *of the curve* lies inside the returned box. For a quadratic
  /// Bézier the extreme points of the curve are its two endpoints and, per axis, the solved
  /// extremum when `u` falls strictly inside (0, 1).
  ///
  /// **`p1` is deliberately not in these spans.** A quadratic's control point is not on the curve,
  /// the curve only interpolates `p0` and `p2`, which is exactly why `getBounds` replaces the
  /// control point's coordinate with the solved extremum instead of keeping it. Including `p1` here
  /// was the first version of this helper and it failed on every curved input, including the
  /// positive-quadrant ones the jar agrees with: a box that contained the control polygon would be
  /// strictly larger than upstream's everywhere, not just on the negative side.
  private static func expectEncloses(
    _ p0: (Double, Double), _ p1: (Double, Double), _ p2: (Double, Double),
    _ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation
  ) {
    let bounds = CurveUtil.getBounds(p0, p1, p2)
    var xs = [p0.0, p2.0]
    var ys = [p0.1, p2.1]
    if let e = extremum(p0.0, p1.0, p2.0) { xs.append(e) }
    if let e = extremum(p0.1, p1.1, p2.1) { ys.append(e) }
    let left = Double(bounds.x)
    let top = Double(bounds.y)
    let right = Double(bounds.x + bounds.width)
    let bottom = Double(bounds.y + bounds.height)
    #expect(
      xs.min()! >= left && xs.max()! <= right,
      "\(comment): x span \(xs.min()!)…\(xs.max()!) escapes box \(left)…\(right)",
      sourceLocation: sourceLocation)
    #expect(
      ys.min()! >= top && ys.max()! <= bottom,
      "\(comment): y span \(ys.min()!)…\(ys.max()!) escapes box \(top)…\(bottom)",
      sourceLocation: sourceLocation)
  }

  // MARK: The reported case

  /// The audit's curve: endpoints (100,100)/(100,120), control (99,110), dragged 200 left. Its x
  /// extremum is exactly −100.5 and its xMax is −100, so truncation gave a **zero-width** box.
  ///
  /// upstream 4.1.0, from the jar: `(-100,100): 0x20`.
  @Test("a one-unit-wide curve left of the origin still has a width")
  func aNarrowNegativeCurveKeepsItsWidth() {
    let bounds = CurveUtil.getBounds((-100.0, 100.0), (-101.0, 110.0), (-100.0, 120.0))
    #expect(bounds.width == 1, "the box collapsed to \(bounds.width) wide; 4.1.0 answers 0x20")
    #expect(bounds.x == -101, "the box starts at \(bounds.x) but the curve reaches -100.5")
    #expect(bounds.height == 20)
    #expect(bounds.y == 100)
  }

  /// The same shape reflected through x = 0, which upstream already gets right. Present so that a
  /// `getBounds` which simply widened every box by one could not satisfy the test above.
  ///
  /// upstream 4.1.0, from the jar: `(99,100): 1x20`, identical to this port.
  @Test("the positive mirror of it is untouched, and matches the jar exactly")
  func thePositiveMirrorIsUnchanged() {
    let bounds = CurveUtil.getBounds((100.0, 100.0), (99.0, 110.0), (100.0, 120.0))
    #expect(bounds.x == 99)
    #expect(bounds.y == 100)
    #expect(bounds.width == 1)
    #expect(bounds.height == 20)
  }

  /// The y direction, which takes the other branch of `getBounds` and would not be fixed by fixing
  /// x alone.
  ///
  /// upstream 4.1.0, from the jar: `(100,-100): 20x0`.
  @Test("a one-unit-tall curve above the origin still has a height")
  func aNarrowNegativeCurveKeepsItsHeight() {
    let bounds = CurveUtil.getBounds((100.0, -100.0), (110.0, -101.0), (120.0, -100.0))
    #expect(bounds.height == 1, "the box collapsed to \(bounds.height) tall; 4.1.0 answers 20x0")
    #expect(bounds.y == -101, "the box starts at \(bounds.y) but the curve reaches -100.5")
    #expect(bounds.width == 20)
    #expect(bounds.x == 100)
  }

  // MARK: The general property

  /// A box that is non-zero but still wrong: the curve reaches −105.5 and upstream's box starts at
  /// −105, leaving half a unit of curve outside it. The zero-width case is the eye-catching
  /// symptom, not the boundary of the defect.
  ///
  /// upstream 4.1.0, from the jar: `(-105,0): 5x100`.
  @Test("a wide curve left of the origin is fully inside its own box")
  func aWideNegativeCurveIsEnclosed() {
    let bounds = CurveUtil.getBounds((-100.0, 0.0), (-111.0, 50.0), (-100.0, 100.0))
    #expect(bounds.x == -106, "box starts at \(bounds.x); 4.1.0 answers -105 and the curve is -105.5")
    #expect(bounds.width == 6, "width \(bounds.width); 4.1.0 answers 5, which is half a unit short")
    Self.expectEncloses((-100.0, 0.0), (-111.0, 50.0), (-100.0, 100.0), "wide negative curve")
  }

  /// The property across all four quadrants and across the axes, so the fix is not just three
  /// hand-picked rows. A curve straddling the origin exercises one floored side and one truncated
  /// side at once.
  ///
  /// Both orientations are swept on purpose. The first version of this test used only the
  /// x-bulging family, whose `computeB(...).1` is zero, so its y extremum is never solved and the
  /// y branch of `getBounds` was never entered. It stayed green under a probe that floored x and
  /// left y truncating, which made it a weaker test than it looked. The transposed family below
  /// closes that: its `computeB(...).0` is zero instead, so between the two every combination of
  /// (solved / unsolved) × (x / y) × (positive / negative) is covered.
  @Test("the box encloses the curve wherever the curve is")
  func enclosureHoldsInEveryQuadrant() {
    for (dx, dy) in [(0, 0), (-200, 0), (0, -200), (-200, -200), (-97, 43), (43, -97)] {
      // Bulges in x: the x extremum is solved, the y extremum is degenerate.
      let p0 = (Double(100 + dx), Double(0 + dy))
      let p1 = (Double(111 + dx), Double(50 + dy))
      let p2 = (Double(100 + dx), Double(100 + dy))
      Self.expectEncloses(p0, p1, p2, "x-bulging curve offset by (\(dx), \(dy))")
      // The same shape mirrored in x, so both the min-x and max-x extrema get a turn.
      let m0 = (Double(-100 + dx), Double(0 + dy))
      let m1 = (Double(-111 + dx), Double(50 + dy))
      let m2 = (Double(-100 + dx), Double(100 + dy))
      Self.expectEncloses(m0, m1, m2, "x-mirrored curve offset by (\(dx), \(dy))")

      // Transposed: now the y extremum is the solved one, which is the branch the pair above
      // cannot reach.
      let q0 = (Double(0 + dx), Double(100 + dy))
      let q1 = (Double(50 + dx), Double(111 + dy))
      let q2 = (Double(100 + dx), Double(100 + dy))
      Self.expectEncloses(q0, q1, q2, "y-bulging curve offset by (\(dx), \(dy))")
      let n0 = (Double(0 + dx), Double(-100 + dy))
      let n1 = (Double(50 + dx), Double(-111 + dy))
      let n2 = (Double(100 + dx), Double(-100 + dy))
      Self.expectEncloses(n0, n1, n2, "y-mirrored curve offset by (\(dx), \(dy))")
    }
  }

  /// Every curve gets a usable box: the two consumers that mediate through `Bounds` both treat a
  /// zero span as "nothing here", so a collapsed box is indistinguishable from an absent shape.
  @Test("no curve on the negative side gets a degenerate box")
  func negativeCurvesAreNeverDegenerate() {
    // Sweep the control point through the whole range that makes the x extremum fractional.
    for offset in 1...12 {
      let bounds = CurveUtil.getBounds(
        (-100.0, 100.0), (Double(-100 - offset), 110.0), (-100.0, 120.0))
      #expect(bounds.width > 0, "control point -\(100 + offset) produced a zero-width box")
      #expect(bounds.height > 0, "control point -\(100 + offset) produced a zero-height box")
    }
  }

  // MARK: What upstream does, recorded rather than asserted

  /// The divergence, pinned. These are not assertions about this port; they are the jar's answers,
  /// recomputed here by the same truncating arithmetic 4.1.0 uses, so the table cannot rot.
  ///
  /// If a later change reverts `getBounds` to upstream's truncation, this test still passes (it
  /// never calls `getBounds`) while the four above fail. That is deliberate: the record of what
  /// upstream does must survive independently of which behaviour the port has chosen.
  @Test("upstream 4.1.0 truncates the minimum toward zero, and the jar rows say so")
  func upstreamRoundsTheMinTowardZero() {
    /// Java's `(int)` narrowing conversion, for the rows below.
    func javaTruncate(_ v: Double) -> Int { Int(v) }

    // Each pair is one shape and its reflection through x = 0. `trueMin` is the solved extremum.
    let rows: [(trueMin: Double, trueMax: Double, upstream: (x: Int, w: Int))] = [
      // (100,0) (111,50) (100,100), jar: (100,0): 6x100. Correct: 100…106 contains 100…105.5.
      (trueMin: 100.0, trueMax: 105.5, upstream: (x: 100, w: 6)),
      // (-100,0) (-111,50) (-100,100), jar: (-105,0): 5x100. Wrong: -105…-100 misses -105.5.
      (trueMin: -105.5, trueMax: -100.0, upstream: (x: -105, w: 5)),
      // (100,100) (99,110) (100,120), jar: (99,100): 1x20. Correct.
      (trueMin: 99.5, trueMax: 100.0, upstream: (x: 99, w: 1)),
      // (-100,100) (-101,110) (-100,120): jar: (-100,100): 0x20. Wrong, and empty.
      (trueMin: -100.5, trueMax: -100.0, upstream: (x: -100, w: 0)),
    ]

    for row in rows {
      let x = javaTruncate(row.trueMin)
      let w = javaTruncate(row.trueMax.rounded(.up)) - x
      #expect(
        x == row.upstream.x && w == row.upstream.w,
        "upstream's own arithmetic no longer reproduces the jar row for \(row)")
      // And the point of the whole file: on the negative side that box does not contain the curve.
      if row.trueMin < 0 {
        #expect(
          Double(x) > row.trueMin,
          "the jar row for \(row) was supposed to be the defective one, but it encloses")
      } else {
        #expect(Double(x) <= row.trueMin)
      }
    }
  }

  // MARK: The crash fix this change had to leave alone

  /// `FlatCurveBoundsTests` covers the NaN and saturation arms of `javaInt`. This asserts the one
  /// thing that file cannot: that flooring happens *before* the narrowing conversion, so a flat
  /// curve still reaches the NaN arm. `floor(NaN)` is NaN; had the floor been written inside
  /// `javaInt` after the NaN check, or as `Int(xMin.rounded(.down))`, a flat `<curve>` would trap
  /// again and opening the file would kill the app, which is how this was originally found.
  ///
  /// **Both axes, because they are separate conversions.** Measured: writing the x minimum as
  /// `Int(xMin.rounded(.down))` and leaving y alone dies with `Fatal error: Double value cannot be
  /// converted to Int because it is either infinite or NaN`, signal 5, the whole run gone, and a
  /// y-only flat curve does not reach it. As in `FlatCurveBoundsTests`, the assertion is "it
  /// returns": there is no wrong value to compare against, the run either continues or ends.
  @Test("a flat curve still answers instead of trapping, in both axes")
  func flooringDidNotReintroduceTheFlatCurveTrap() {
    // Three control points sharing a y: `computeB(...).1 == 0`, so the y minimum is NaN.
    let flatInY = CurveUtil.getBounds((0.0, 50.0), (50.0, 50.0), (100.0, 50.0))
    #expect(flatInY.height >= 0)
    // Three sharing an x: `computeB(...).0 == 0`, the other conversion, the other branch.
    let flatInX = CurveUtil.getBounds((50.0, 0.0), (50.0, 50.0), (50.0, 100.0))
    #expect(flatInX.width >= 0)
    // Collapsed to a point: both minima NaN at once.
    let point = CurveUtil.getBounds((10.0, 10.0), (10.0, 10.0), (10.0, 10.0))
    #expect(point.width >= 0)
    // And out of `Int32` range, where `javaInt` saturates rather than trapping. Flooring leaves an
    // out-of-range value out of range, so the saturation arm is still the one taken.
    let huge = Double(Int32.max) * 4
    let enormous = CurveUtil.getBounds((-huge, -huge), (0.0, 0.0), (huge, huge))
    _ = enormous.width
  }

  // MARK: Reachability

  /// The path the audit reported it on: a curve saved to a `.circ` and read back. `Curve.translate`
  /// moves the *cached* box (`Curve.java:219`), so a dragged curve keeps whatever box it had; the
  /// reload is what recomputes and exposes the bounds. Both ends are asserted here because "the
  /// box survives a round trip" is the user-visible claim.
  @Test("a curve left of the origin keeps its box through a save and reload")
  func theBoxSurvivesAnSvgRoundTrip() throws {
    let curve = Curve(
      end0: Location.create(-100, 100, hasToSnap: false),
      end1: Location.create(-100, 120, hasToSnap: false),
      control: Location.create(-101, 110, hasToSnap: false))
    #expect(curve.bounds.width == 1, "a freshly constructed negative curve had no width")

    let reloaded = try #require(SvgReader.createShape(curve.toSvgElement()) as? Curve)
    #expect(reloaded.bounds == curve.bounds, "the box changed across the round trip")
    #expect(reloaded.bounds.width == 1, "the reloaded curve lost its width")
    #expect(reloaded.end0 == curve.end0)
    #expect(reloaded.end1 == curve.end1)
    #expect(reloaded.control == curve.control)
  }

  /// The report's exact gesture: draw the curve where upstream gets it right, **drag** it left of
  /// the origin, save, reopen.
  ///
  /// This is the asymmetry that made the finding look like a reload bug. `Curve.translate` moves the
  /// *cached* box (`Curve.java:219`, mirrored at `Curve.swift:180`) rather than recomputing it, so
  /// the dragged curve in memory kept the correct `1x20` it was built with, and only the reload,
  /// which goes back through `getBounds`, produced `0x20`. The truncation was never about reloading;
  /// reloading was just the first thing that recomputed.
  ///
  /// Caching-and-translating is faithful to upstream and is left alone. What the fix buys is that
  /// the two paths now **agree**: measured before it, dragged-in-memory was `(-101,100): 1x20` and
  /// reloaded was `(-100,100): 0x20`.
  @Test("a curve dragged left of the origin has the same box before and after a reload")
  func draggingThenReloadingAgrees() throws {
    // Built in the positive quadrant, where upstream's box is already correct.
    let curve = Curve(
      end0: Location.create(100, 100, hasToSnap: false),
      end1: Location.create(100, 120, hasToSnap: false),
      control: Location.create(99, 110, hasToSnap: false))
    #expect(curve.bounds == Bounds.create(99, 100, 1, 20))

    curve.translate(-200, 0)
    let dragged = curve.bounds
    #expect(dragged == Bounds.create(-101, 100, 1, 20), "the translated box was \(dragged)")

    let reloaded = try #require(SvgReader.createShape(curve.toSvgElement()) as? Curve)
    #expect(
      reloaded.bounds == dragged,
      "dragged box \(dragged) but reloaded box \(reloaded.bounds) — the two paths disagree")
  }

  /// And the box is what the appearance editor's click test uses, which is why a zero-width one is
  /// not cosmetic. Asserted at the `Bounds` level because the hit test itself lives in `LogisimUI`.
  ///
  /// The claim is deliberately narrow: **some** lattice point admits a click. It is not "the
  /// endpoints are inside the box", because `Bounds.contains` is half-open: `px < x + width`,
  /// `Bounds.swift:154-159`, matching `com.cburch.logisim.data.Bounds`, so the max edge is
  /// exclusive by design and the endpoints at x = −100 sit on it. That is true of the positive
  /// mirror too (box `(99,100): 1x20`, endpoints at x = 100), so it is the convention and not this
  /// defect. The defect was that a **zero-width** box contains no point at all, at which point the
  /// shape is unreachable rather than merely awkward to hit.
  @Test("the reloaded box admits a click, where a zero-width box admitted none")
  func theBoxCanBeClicked() throws {
    let curve = Curve(
      end0: Location.create(-100, 100, hasToSnap: false),
      end1: Location.create(-100, 120, hasToSnap: false),
      control: Location.create(-101, 110, hasToSnap: false))
    let reloaded = try #require(SvgReader.createShape(curve.toSvgElement()) as? Curve)
    let box = reloaded.bounds
    #expect(box.width > 0 && box.height > 0, "box \(box) has no area, so no click can land in it")
    // The column the curve's extremum (x = -100.5) falls in.
    #expect(
      box.contains(Location.create(-101, 110, hasToSnap: false)),
      "box \(box) does not contain the column holding the curve's leftmost point")
    // Count the lattice points that hit, which is the quantity that was zero before the fix.
    var hits = 0
    for px in -105...(-95) where box.contains(Location.create(px, 110, hasToSnap: false)) {
      hits += 1
    }
    #expect(hits > 0, "no lattice point in x ∈ [-105, -95] lands in \(box)")
  }
}
