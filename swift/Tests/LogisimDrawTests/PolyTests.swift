// PolyTests: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// D13 regression: `Poly.java`'s constructor ends in `recomputeBounds()`, which reads
// `handles[0]` with no length check. A zero-point polygon, `<polygon points=""/>`, which comes
// straight out of a `.circ` `<appear>` section, raises `ArrayIndexOutOfBoundsException` there.
// That is unchecked but catchable, and the appearance loader catches it, so the Java reports a
// load error. The Swift port indexed `hs[0]` the same way and trapped with
// "Fatal error: Index out of range", turning a malformed file into a process kill with the
// user's unsaved work in it. It must throw.

import LogisimKernel
import Testing

@testable import LogisimDraw

private func loc(_ x: Int, _ y: Int) -> Location {
  Location.create(x, y, hasToSnap: false)
}

@Test func aZeroPointPolygonThrowsInsteadOfTrapping() {
  #expect(throws: PolyError.noPoints(closed: true)) {
    _ = try Poly(closed: true, locations: [])
  }
}

@Test func aZeroPointPolylineThrowsInsteadOfTrapping() {
  #expect(throws: PolyError.noPoints(closed: false)) {
    _ = try Poly(closed: false, locations: [])
  }
}

/// The end-to-end path the bug actually arrives on: an `<appear>` element with an empty
/// `points` attribute. `parsePoints("")` legitimately yields zero locations (0 tokens is an even
/// count), so nothing upstream of `Poly` rejects it.
@Test func svgPolygonWithEmptyPointsIsALoadErrorNotACrash() {
  let element = SvgElement("polygon")
  element.setAttribute("points", "")
  element.setAttribute("stroke", "#000000")
  element.setAttribute("stroke-width", "2")
  element.setAttribute("fill", "none")

  #expect(throws: PolyError.noPoints(closed: true)) {
    _ = try SvgReader.createShape(element)
  }
}

@Test func svgPolylineWithWhitespaceOnlyPointsIsALoadErrorNotACrash() {
  let element = SvgElement("polyline")
  element.setAttribute("points", "   ")
  element.setAttribute("stroke", "#000000")

  #expect(throws: PolyError.noPoints(closed: false)) {
    _ = try SvgReader.createShape(element)
  }
}

// MARK: - Everything non-empty is untouched

/// Java accepts a one-point poly, `recomputeBounds` only needs `hs[0]` to exist, so the guard
/// must reject *empty*, not "too few to draw".
@Test func aSinglePointPolyStillBuilds() throws {
  let poly = try Poly(closed: false, locations: [loc(3, 4)])
  #expect(poly.currentHandles.count == 1)
  #expect(poly.bounds == Bounds.create(3, 4, 1, 1))
}

@Test func ordinaryPolygonBoundsAreUnchanged() throws {
  let poly = try Poly(closed: true, locations: [loc(10, 20), loc(30, 5), loc(-4, 12)])
  // x in [-4, 30], y in [5, 20]; Java's inclusive +1 on each extent.
  #expect(poly.bounds == Bounds.create(-4, 5, 35, 16))
}

@Test func translatingAPolyStillRecomputesItsBounds() throws {
  let poly = try Poly(closed: false, locations: [loc(0, 0), loc(4, 6)])
  #expect(poly.bounds == Bounds.create(0, 0, 5, 7))
  poly.translate(10, -3)
  #expect(poly.bounds == Bounds.create(10, -3, 5, 7))
}

@Test func svgPolygonWithRealPointsStillLoads() throws {
  let element = SvgElement("polygon")
  element.setAttribute("points", "10,20 30,5 -4,12")
  element.setAttribute("stroke", "#000000")
  element.setAttribute("fill", "none")

  let shape = try #require(try SvgReader.createShape(element))
  let poly = try #require(shape as? Poly)
  #expect(poly.isClosed)
  #expect(poly.currentHandles.count == 3)
}
