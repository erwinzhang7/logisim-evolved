// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution, which is GPL-3.0-only. This port is a derivative work and is
// therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// A flat `<curve>` in a `.circ` used to kill the app outright.
//
// ── The crash ────────────────────────────────────────────────────────────────────────────────
//
// `CurveUtil.getBounds` solves for the curve's extremum with `u = -A / B`, where
// `B = 2 * (p0 - 2*p1 + p2)`. When the three control points share a coordinate, a *flat* curve,
// which is a perfectly ordinary thing to draw and to save, that expression is `2 * (v - 2v + v)`,
// which is **zero**. `u` is then NaN, `uu` is NaN, and `Int(NaN)` is a **runtime trap in Swift**.
// Not an exception, not a wrong answer: the process dies. Opening the file was enough.
//
// Java does not crash here, and not by luck: JLS 5.1.3 defines a narrowing conversion of NaN to
// be 0, and of an out-of-range value to saturate. The jar answers `(83, 0): 117x100` for exactly
// this shape. So the port had a crash where upstream had a defined answer, which is the worst
// possible direction for a divergence to run.
//
// It was found by an agent writing a test for something else entirely, not by any gate; the
// appearance editor's shapes had no bounds coverage for degenerate control points. That is the
// lesson worth keeping: this was reachable from a plain saved file, and nothing in 1,470 tests
// touched it.

import Foundation
import Testing

@testable import LogisimDraw

@Suite("A flat curve has bounds instead of trapping")
struct FlatCurveBoundsTests {

  /// The calibration: an ordinary curved curve must still work, or a `getBounds` that returned a
  /// constant would satisfy every assertion below.
  @Test("a normal curve still computes real bounds")
  func aCurvedCurveStillWorks() {
    let bounds = CurveUtil.getBounds((0.0, 0.0), (50.0, 100.0), (100.0, 0.0))
    #expect(bounds.width > 0, "a genuinely curved curve produced no width")
    #expect(bounds.height > 0, "a genuinely curved curve produced no height")
  }

  /// **The crash, in the y direction.** All three control points share y, so `B.1 == 0`.
  /// Before the fix this trapped and took the process with it, so there is no "wrong value" to
  /// assert against; the test either returns or the run dies.
  @Test("three control points sharing a y do not trap")
  func aHorizontallyFlatCurveDoesNotTrap() {
    let bounds = CurveUtil.getBounds((0.0, 50.0), (50.0, 50.0), (100.0, 50.0))
    #expect(bounds.width >= 0)
    #expect(bounds.height >= 0)
  }

  /// The same degeneracy in x, which takes the other branch. Asserted separately because the two
  /// branches are independent code paths and fixing one would not fix the other.
  @Test("three control points sharing an x do not trap")
  func aVerticallyFlatCurveDoesNotTrap() {
    let bounds = CurveUtil.getBounds((50.0, 0.0), (50.0, 50.0), (50.0, 100.0))
    #expect(bounds.width >= 0)
    #expect(bounds.height >= 0)
  }

  /// A wholly degenerate curve, every control point identical, which makes BOTH branches NaN at
  /// once. This is what an accidental click-without-drag saves.
  @Test("a curve collapsed to a single point does not trap")
  func aDegenerateCurveDoesNotTrap() {
    let bounds = CurveUtil.getBounds((10.0, 10.0), (10.0, 10.0), (10.0, 10.0))
    #expect(bounds.width >= 0)
    #expect(bounds.height >= 0)
  }

  /// Coordinates past `Int32` saturate rather than trapping, matching Java's narrowing conversion.
  /// Separate from the NaN case on purpose: clamping only NaN would leave this trap in place, and
  /// a `.circ` is free to carry an absurd coordinate.
  ///
  /// **The assertion is "it returns", and deliberately says nothing about the value.** The first
  /// version of this test asserted `width >= 0` and failed with `width → -1`. That was the test
  /// being wrong, not the fix: after saturation the span is `Int32.max - Int32.min`, and
  /// `Bounds.create` wraps it to `Int32` exactly as Java's `int` arithmetic does. Pinning a
  /// particular wrapped number here without an oracle row for it would be inventing an
  /// expectation; the claim this file exists to make is that a saved file cannot kill the
  /// process, and that claim is fully carried by reaching the next line.
  @Test("an out-of-range coordinate saturates instead of trapping")
  func anEnormousCurveDoesNotTrap() {
    let huge = Double(Int32.max) * 4
    let bounds = CurveUtil.getBounds((-huge, -huge), (0.0, 0.0), (huge, huge))
    _ = bounds.width
    _ = bounds.height
  }
}
