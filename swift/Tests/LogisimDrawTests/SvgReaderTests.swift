// SvgReaderTests: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// Regression cover for three confirmed `SvgReader` defects. Every expectation below is the
// *measured* output of the 4.1.0 reference semantics on OpenJDK 21 (the runtime bundled with
// the 4.1.0 app), not a reading of the source:
//
//   (int) Math.round(1e30)                     == -1
//   (int) Math.round(-1e30)                    == 0
//   (int) Math.round(4.5e18)                   == 1900150784
//   Math.round(-2.5)                           == -2      ((-2.5).rounded() is -3)
//   Math.round(-0.5)                           == 0       ((-0.5).rounded() is -1)
//   Math.round(0.49999999999999994)            == 0       (floor(a+0.5) would give 1)
//   new Color(0, 0, 0, -1)                     -> IllegalArgumentException
//   Pattern.compile("[ ,\n\r\t]+").split(" 1,2") -> ["", "1", "2"]   (leading empty KEPT)
//   new Location[3 / 2]                        -> length 1           (odd token DROPPED)
//
// The first three used to *trap* the process (`Int(_: Double)` on an out-of-range value), which
// is the D13 failure mode: a hand-edited `<appear>` section in a `.circ` turned a load error
// into a crash with the user's unsaved work in it.

import Testing

@testable import LogisimDraw
@testable import LogisimKernel

// MARK: - Helpers

private func ellipse(cx: String, cy: String, rx: String, ry: String) -> SvgElement {
  let elt = SvgElement("ellipse")
  elt.setAttribute("cx", cx)
  elt.setAttribute("cy", cy)
  elt.setAttribute("rx", rx)
  elt.setAttribute("ry", ry)
  return elt
}

/// With no `stroke` attribute the shared post-processing picks `PAINT_FILL`, and `Rectangular`
/// then returns its raw bounds unexpanded, so these are exactly `Oval(x, y, w, h)`.
private func ovalBounds(cx: String, cy: String, rx: String, ry: String) throws -> Bounds {
  let shape = try #require(try SvgReader.createShape(ellipse(cx: cx, cy: cy, rx: rx, ry: ry)))
  let oval = try #require(shape as? Oval)
  return oval.bounds
}

private func poly(_ tag: String, points: String) throws -> Poly {
  let elt = SvgElement(tag)
  elt.setAttribute("points", points)
  let shape = try #require(try SvgReader.createShape(elt))
  return try #require(shape as? Poly)
}

private func locations(_ p: Poly) -> [(Int, Int)] {
  p.currentHandles.map { ($0.x, $0.y) }
}

// MARK: - Defect 1 — `(int) Math.round(double)` saturates then WRAPS; it must not trap

@Test func ovalWithHugeCentreWrapsInsteadOfTrapping() throws {
  // The literal repro from the review. `Int((1e30).rounded())` traps with "Double value cannot
  // be converted to Int because the result would be greater than Int.max". Java saturates
  // Math.round to Long.MAX_VALUE and the (int) cast narrows it by wrapping to -1.
  let bds = try ovalBounds(cx: "1e30", cy: "0", rx: "0", ry: "0")
  #expect(bds.x == -1)
  #expect(bds.y == 0)
  #expect(bds.width == 0)
  #expect(bds.height == 0)
}

@Test func ovalWithHugeNegativeCentreWrapsToZero() throws {
  // Math.round(-1e30) saturates to Long.MIN_VALUE, whose low 32 bits are all zero.
  let bds = try ovalBounds(cx: "-1e30", cy: "0", rx: "0", ry: "0")
  #expect(bds.x == 0)
}

@Test func ovalWrapIsNotAClamp() throws {
  // The distinguishing case: clamping to Int32.max would give 2147483647 here. Java wraps, and
  // the resulting coordinate is stored on the shape, so the difference is observable.
  let bds = try ovalBounds(cx: "4.5e18", cy: "0", rx: "0", ry: "0")
  #expect(bds.x == 1_900_150_784)
}

@Test func ovalWithHugeRadiusWrapsWidthAndHeight() throws {
  // rx * 2 overflows too: the second trapping expression in the original code.
  let bds = try ovalBounds(cx: "0", cy: "0", rx: "1e30", ry: "1e30")
  #expect(bds.x == 0)
  #expect(bds.y == 0)
  #expect(bds.width == -1)
  #expect(bds.height == -1)
}

@Test func ovalWithNonFiniteCoordinates() throws {
  // Double.parseDouble accepts "Infinity" and "NaN"; Math.round then saturates / returns 0.
  let inf = try ovalBounds(cx: "Infinity", cy: "-Infinity", rx: "0", ry: "0")
  #expect(inf.x == -1)
  #expect(inf.y == 0)

  let nan = try ovalBounds(cx: "NaN", cy: "0", rx: "0", ry: "0")
  #expect(nan.x == 0)
}

@Test func opacityOutOfRangeThrowsRatherThanTrappingOrClamping() throws {
  // `(int) Math.round(1e30 * 255)` is -1, and `new Color(0,0,0,-1)` throws a *catchable*
  // IllegalArgumentException. The old code trapped in `Int((value * 255).rounded())`; before
  // that it clamped, which silently turned upstream's rejection into alpha 255.
  #expect(throws: SvgParseError.colorOutOfRange(component: "Alpha")) {
    _ = try SvgReader.getColor("#000000", "1e30")
  }
  #expect(throws: SvgParseError.colorOutOfRange(component: "Alpha")) {
    _ = try SvgReader.getColor("#000000", "-0.5")  // Math.round(-127.5) == -127
  }
}

@Test func colorOutOfRangeCarriesJavasMessage() {
  #expect(
    SvgParseError.colorOutOfRange(component: "Alpha").description
      == "Color parameter outside of expected range: Alpha")
}

@Test func opacityThatWrapsBackIntoRangeIsAccepted() throws {
  // 1.684300900392157e7 * 255 is exactly 2^32, so the (int) cast wraps to 0 and Color accepts
  // it. A clamp would give 255 and a range check on the *long* would reject it; Java does
  // neither. This pins "wrap", not "saturate", as the narrowing rule.
  #expect(1.684300900392157e7 * 255 == 4_294_967_296.0)
  let color = try SvgReader.getColor("#000000", "1.684300900392157E7")
  #expect(color.alpha == 0)
}

@Test func ordinaryOpacitiesAreUnchanged() throws {
  #expect(try SvgReader.getColor("#ff0000", "").alpha == 255)
  #expect(try SvgReader.getColor("#ff0000", "1").alpha == 255)
  #expect(try SvgReader.getColor("#ff0000", "0").alpha == 0)
  #expect(try SvgReader.getColor("#ff0000", "0.5").alpha == 128)  // Math.round(127.5) == 128
  #expect(try SvgReader.getColor("#ff0000", "0.003").alpha == 1)
  // The comma-retry path still works, and still range-checks afterwards.
  #expect(try SvgReader.getColor("#ff0000", "0,5").alpha == 128)
  #expect(try SvgReader.getColor("#010203", "").red == 1)
  #expect(try SvgReader.getColor("#010203", "").green == 2)
  #expect(try SvgReader.getColor("#010203", "").blue == 3)
  #expect(throws: SvgParseError.malformedNumber("abc")) {
    _ = try SvgReader.getColor("#ff0000", "abc")
  }
}

// MARK: - Defect 2 — Math.round rounds ties toward +infinity, `.rounded()` rounds away from 0

@Test func ovalOnAnExactNegativeHalfRoundsTowardPositiveInfinity() throws {
  // The literal repro from the review. `Double.rounded()` is toNearestOrAwayFromZero, giving
  // (-3, -1) 1x1. Java: (int)Math.round(-2.5) == -2 and (int)Math.round(-0.5) == 0.
  let bds = try ovalBounds(cx: "-2", cy: "0", rx: "0.5", ry: "0.5")
  #expect(bds.x == -2)
  #expect(bds.y == 0)
  #expect(bds.width == 1)
  #expect(bds.height == 1)
}

@Test func ovalOnAnotherNegativeHalf() throws {
  // Math.round(-1.5) == -1, (-1.5).rounded() == -2.
  let bds = try ovalBounds(cx: "-1.5", cy: "-1.5", rx: "0", ry: "0")
  #expect(bds.x == -1)
  #expect(bds.y == -1)
}

@Test func ovalOnAPositiveHalfIsUnaffected() throws {
  // Positive halves agree between the two rules; this guards against "fixing" it the other way.
  let bds = try ovalBounds(cx: "2.5", cy: "0", rx: "0", ry: "0")
  #expect(bds.x == 3)
}

@Test func roundIsNotFloorOfXPlusHalf() throws {
  // JDK-6430675: `a + 0.5` can itself round up to the next representable double, so the
  // pre-Java-7 `(long) Math.floor(a + 0.5)` formula gives 1 here where Math.round gives 0.
  let bds = try ovalBounds(cx: "0.49999999999999994", cy: "0", rx: "0", ry: "0")
  #expect(bds.x == 0)
}

// MARK: - Defect 3 — parsePoints truncates on an odd token count and keeps a leading empty

@Test func polygonWithAnUnpairedTrailingTokenLoadsAsAShorterPoly() throws {
  // `new Location[toks.length / 2]` sizes by integer division, so "3" is silently dropped.
  // The port used to reject this outright, meaning a file that opens in Logisim did not open
  // here.
  let p = try poly("polygon", points: "1,2 3")
  #expect(locations(p).count == 1)
  #expect(locations(p)[0] == (1, 2))
}

@Test func polylineWithAnUnpairedTrailingTokenLoadsAsAShorterPoly() throws {
  let p = try poly("polyline", points: "1,2 3,4 5")
  #expect(locations(p).map { [$0.0, $0.1] } == [[1, 2], [3, 4]])
}

@Test func leadingSeparatorProducesAnEmptyTokenAndThereforeFails() throws {
  // Java's Pattern.split keeps a leading empty token for a non-zero-width match at index 0
  // (only *trailing* empties are stripped at limit 0). So " 1,2" is ["", "1", "2"], the single
  // pair read is ("", "1"), and Integer.parseInt("") throws NumberFormatException. Splitting
  // with omittingEmptySubsequences parsed this cleanly instead: accepting a file upstream
  // rejects, which is a divergence in the other direction.
  #expect(throws: SvgParseError.malformedNumber("")) {
    _ = try poly("polygon", points: " 1,2")
  }
  #expect(throws: SvgParseError.malformedNumber("")) {
    _ = try poly("polyline", points: "\t1,2 3,4")
  }
}

@Test func trailingAndRepeatedSeparatorsAreStripped() throws {
  // Runs collapse (the `+`) and trailing empties are removed, so these are all two points.
  // NB `"1,2\r\n3,4"` is the load-bearing one: `"\r\n"` is a SINGLE Swift `Character` (a
  // grapheme cluster) equal to neither "\r" nor "\n", so a Character-based separator test does
  // not split it and then throws on `For input string: "4\r\n"`. Java matches UTF-16 code
  // units and sees two separators.
  for points in [
    "1,2 3,4", "1,2 3,4 ", "1,2  3,4", "1,2\n3,4", "1,2,3,4", "1,2 3,4\r\n",
    "1,2\r\n3,4", "1,2\t3,4", "1,2\r\n\r\n3,4",
  ] {
    let p = try poly("polygon", points: points)
    #expect(locations(p).map { [$0.0, $0.1] } == [[1, 2], [3, 4]], "points=\(points)")
  }
  // A CRLF at the *start* is still two separators, hence still one leading empty token.
  #expect(throws: SvgParseError.malformedNumber("")) {
    _ = try poly("polygon", points: "\r\n1,2")
  }
}

@Test func aLeadingSeparatorRunStillYieldsExactlyOneEmptyToken() throws {
  // "  1  2  3  " splits to ["", "1", "2", "3"] in Java: four tokens, so one pair, ("", "1").
  #expect(throws: SvgParseError.malformedNumber("")) {
    _ = try poly("polygon", points: "  1  2  3  ")
  }
}

@Test func negativeCoordinatesStillParse() throws {
  let p = try poly("polyline", points: "-1,-2 -3,4")
  #expect(locations(p).map { [$0.0, $0.1] } == [[-1, -2], [-3, 4]])
}

// MARK: - Guard: the rest of the reader is untouched

@Test func unrelatedShapesStillRoundTripThroughTheReader() throws {
  let rect = SvgElement("rect")
  rect.setAttribute("x", "10")
  rect.setAttribute("y", "20")
  rect.setAttribute("width", "30")
  rect.setAttribute("height", "40")
  let shape = try #require(try SvgReader.createShape(rect))
  #expect(shape.bounds.x == 10)
  #expect(shape.bounds.y == 20)
  #expect(shape.bounds.width == 30)
  #expect(shape.bounds.height == 40)

  let path = SvgElement("path")
  path.setAttribute("d", "M1,2 Q3,4 5,6")
  let curve = try #require(try SvgReader.createShape(path) as? Curve)
  #expect(curve.end0 == Location.create(1, 2, hasToSnap: false))
  #expect(curve.control == Location.create(3, 4, hasToSnap: false))
  #expect(curve.end1 == Location.create(5, 6, hasToSnap: false))

  let ellipseElt = ellipse(cx: "50", cy: "60", rx: "10", ry: "5")
  let oval = try #require(try SvgReader.createShape(ellipseElt) as? Oval)
  #expect(oval.bounds.x == 40)
  #expect(oval.bounds.y == 55)
  #expect(oval.bounds.width == 20)
  #expect(oval.bounds.height == 10)
}
