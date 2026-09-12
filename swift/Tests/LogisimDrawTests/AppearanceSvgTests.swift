// AppearanceSvgTests: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// Cover for the `<circ-anchor>`/`<circ-port>` half of the `<appear>` round trip: the legacy →
// 4.1.0 conversion this seam exists to perform, the pin-matching rules that decide whether a
// port survives at all, and D13 (a hand-edited `.circ` throws; it never traps).
//
// Every expectation is the behaviour of 4.1.0's `AppearanceSvgReader`/`AppearancePort`/
// `AppearanceAnchor` on OpenJDK 21, read off the 4.1.0 tree and confirmed against the corpus:
// the migration gate compares 85 files carrying `<appear>` against the Java oracle's own output,
// and the forms asserted below are what it writes.

import Testing

@testable import LogisimDraw
@testable import LogisimKernel

// MARK: - Helpers

private func element(_ tag: String, _ pairs: [(String, String)]) -> SvgElement {
  let elt = SvgElement(tag)
  for (name, value) in pairs { elt.setAttribute(name, value) }
  return elt
}

/// `<tag a="1" b="2"/>` with the attributes in the order they serialise.
private func rendered(_ elt: SvgElement) -> String {
  let attributes = elt.attributes.map { "\($0.name)=\"\($0.value)\"" }.joined(separator: " ")
  return "<\(elt.tagName) \(attributes)/>"
}

/// Stands in for the `Pin` component a binding points at; only its identity is used.
private final class PinStandIn {}

private func pin(_ x: Int, _ y: Int, input: Bool) -> AppearancePinBinding {
  AppearancePinBinding(
    location: Location.create(x, y, hasToSnap: true), isInput: input, reference: PinStandIn())
}

// MARK: - The legacy → 4.1.0 conversion

@Suite("`<circ-port>` legacy box converts to 4.1.0's dir/pin form")
struct CircPortConversionTests {

  /// `width="8"` is radius 4, which `isInputAppearance` recognises as an input; the location is
  /// the box centre, so `x=46 width=8` is x=50.
  @Test func legacyInputBoxBecomesDirIn() throws {
    let elt = element(
      "circ-port",
      [("height", "8"), ("pin", "130,60"), ("width", "8"), ("x", "46"), ("y", "56")])
    let shape = try #require(
      try AppearanceSvgReader.createShape(elt, pins: [pin(130, 60, input: true)]))
    #expect(rendered(shape.toSvgElement()) == #"<circ-port dir="in" pin="130,60" x="50" y="60"/>"#)
  }

  /// `width="10"` is radius 5, an output.
  @Test func legacyOutputBoxBecomesDirOut() throws {
    let elt = element(
      "circ-port",
      [("height", "10"), ("pin", "170,70"), ("width", "10"), ("x", "265"), ("y", "65")])
    let shape = try #require(
      try AppearanceSvgReader.createShape(elt, pins: [pin(170, 70, input: false)]))
    #expect(
      rendered(shape.toSvgElement()) == #"<circ-port dir="out" pin="170,70" x="270" y="70"/>"#)
  }

  /// A file already in 4.1.0's form round-trips unchanged; the property the 539-file canonical
  /// gate depends on.
  @Test func modernFormIsIdempotent() throws {
    let elt = element(
      "circ-port", [("dir", "in"), ("pin", "240,100"), ("x", "90"), ("y", "180")])
    let shape = try #require(
      try AppearanceSvgReader.createShape(elt, pins: [pin(240, 100, input: true)]))
    #expect(rendered(shape.toSvgElement()) == #"<circ-port dir="in" pin="240,100" x="90" y="180"/>"#)
  }

  /// `dir` wins over the legacy width whenever it is present; `isInputPinReference` tests it
  /// first and returns without looking at `width`.
  @Test func dirBeatsWidth() throws {
    let elt = element(
      "circ-port",
      [("dir", "out"), ("height", "8"), ("pin", "10,10"), ("width", "8"), ("x", "6"), ("y", "6")])
    let shape = try #require(
      try AppearanceSvgReader.createShape(elt, pins: [pin(10, 10, input: false)]))
    #expect(rendered(shape.toSvgElement()) == #"<circ-port dir="out" pin="10,10" x="10" y="10"/>"#)
  }

  /// **Both** locations are built with `Location.create(…, true)`, whose snap is `(v / 5) * 5`:
  /// integer division, so it *truncates* toward zero rather than rounding: 14 → 10, 6 → 5.
  ///
  /// That matters twice over. The port's own `x`/`y` are snapped on the way out, and the `pin=`
  /// coordinates are snapped *before* the match, so a hand-edited `pin="14,14"` binds to the pin
  /// at `(10,10)` and is then written back as `pin="10,10"`. Emitting the parsed value instead of
  /// the bound pin's would leave the file naming a pin it is not attached to.
  @Test func coordinatesSnapToTheGrid() throws {
    let elt = element("circ-port", [("dir", "in"), ("pin", "14,14"), ("x", "6"), ("y", "6")])
    let shape = try #require(
      try AppearanceSvgReader.createShape(elt, pins: [pin(10, 10, input: true)]))
    #expect(rendered(shape.toSvgElement()) == #"<circ-port dir="in" pin="10,10" x="5" y="5"/>"#)
  }

  /// Attributes serialise in ascending UTF-16 order of name, because upstream's Xerces DOM keeps
  /// them in a binary-searched sorted list. `dir` < `pin` < `x` < `y`.
  @Test func attributesAreAlphabetical() throws {
    let elt = element("circ-port", [("dir", "in"), ("pin", "0,0"), ("x", "0"), ("y", "0")])
    let shape = try #require(try AppearanceSvgReader.createShape(elt, pins: [pin(0, 0, input: true)]))
    #expect(shape.toSvgElement().attributes.map(\.name) == ["dir", "pin", "x", "y"])
  }
}

// MARK: - Pin matching

@Suite("`<circ-port>` binds to exactly one unused pin, or is dropped")
struct CircPortMatchingTests {

  /// No pin at that location: upstream returns null and the caller reports
  /// `fileAppearanceNotFound`. The port names a pin the circuit no longer has.
  @Test func unmatchedLocationIsDropped() throws {
    let elt = element("circ-port", [("dir", "in"), ("pin", "999,999"), ("x", "0"), ("y", "0")])
    #expect(try AppearanceSvgReader.createShape(elt, pins: [pin(1, 1, input: true)]) == nil)
  }

  /// The right location but the wrong direction is also a non-match; `isInputPin == isInputRef`
  /// is part of the test, not a tie-break.
  @Test func directionMismatchIsDropped() throws {
    let elt = element("circ-port", [("dir", "out"), ("pin", "1,1"), ("x", "0"), ("y", "0")])
    #expect(try AppearanceSvgReader.createShape(elt, pins: [pin(1, 1, input: true)]) == nil)
  }

  /// `setPinIsUsed` makes the binding one-to-one: a second `<circ-port>` naming the same pin
  /// finds it already taken and is dropped.
  @Test func aPinBindsOnlyOnce() throws {
    let pins = [pin(1, 1, input: true)]
    let elt = element("circ-port", [("dir", "in"), ("pin", "1,1"), ("x", "0"), ("y", "0")])
    #expect(try AppearanceSvgReader.createShape(elt, pins: pins) != nil)
    #expect(try AppearanceSvgReader.createShape(elt, pins: pins) == nil)
  }

  /// `pin=` is trimmed before parsing (`Integer.parseInt(pinStr[0].trim())`), which is what lets
  /// the space after the comma in a hand-written file parse.
  @Test func pinCoordinatesAreTrimmed() throws {
    let elt = element("circ-port", [("dir", "in"), ("pin", " 1 , 1 "), ("x", "0"), ("y", "0")])
    #expect(try AppearanceSvgReader.createShape(elt, pins: [pin(1, 1, input: true)]) != nil)
  }
}

// MARK: - The anchor

@Suite("`<circ-anchor>` legacy box converts, and `circ-origin` is its alias")
struct CircAnchorTests {

  /// No `facing` in the legacy form, and `AppearanceAnchor`'s constructor defaults to east: so
  /// the converted element gains `facing="east"`.
  @Test func legacyBoxBecomesFacingEast() throws {
    let elt = element(
      "circ-anchor", [("height", "6"), ("width", "6"), ("x", "267"), ("y", "57")])
    let shape = try #require(try AppearanceSvgReader.createShape(elt, pins: []))
    #expect(rendered(shape.toSvgElement()) == #"<circ-anchor facing="east" x="270" y="60"/>"#)
  }

  @Test func facingIsPreserved() throws {
    let elt = element(
      "circ-anchor",
      [("facing", "north"), ("height", "6"), ("width", "6"), ("x", "117"), ("y", "197")])
    let shape = try #require(try AppearanceSvgReader.createShape(elt, pins: []))
    #expect(rendered(shape.toSvgElement()) == #"<circ-anchor facing="north" x="120" y="200"/>"#)
  }

  /// `circ-origin` is the pre-2.7 tag name for the same shape; it is read and written back as
  /// `circ-anchor`.
  @Test func circOriginIsReadAsAnAnchor() throws {
    let elt = element("circ-origin", [("facing", "west"), ("x", "40"), ("y", "40")])
    let shape = try #require(try AppearanceSvgReader.createShape(elt, pins: []))
    #expect(rendered(shape.toSvgElement()) == #"<circ-anchor facing="west" x="40" y="40"/>"#)
  }
}

// MARK: - D13

@Suite("A malformed `<appear>` throws — it never traps")
struct AppearanceD13Tests {

  /// `elt.getAttribute("pin").split(",")` on `""` gives a one-element array, and `pinStr[1]` is
  /// an ArrayIndexOutOfBoundsException upstream: a RuntimeException the caller catches as
  /// `fileAppearanceError`. Reachable from a hand-edited `.circ`, so it must throw here.
  @Test func emptyPinAttributeThrows() {
    let elt = element("circ-port", [("dir", "in"), ("pin", ""), ("x", "0"), ("y", "0")])
    #expect(throws: (any Error).self) { try AppearanceSvgReader.createShape(elt, pins: []) }
  }

  @Test func pinWithOneCoordinateThrows() {
    let elt = element("circ-port", [("dir", "in"), ("pin", "5"), ("x", "0"), ("y", "0")])
    #expect(throws: (any Error).self) { try AppearanceSvgReader.createShape(elt, pins: []) }
  }

  @Test func nonNumericPinCoordinateThrows() {
    let elt = element("circ-port", [("dir", "in"), ("pin", "a,b"), ("x", "0"), ("y", "0")])
    #expect(throws: (any Error).self) { try AppearanceSvgReader.createShape(elt, pins: []) }
  }

  /// No `dir` and no parseable `width`: `isInputPinReference` reaches `Double.parseDouble("")`.
  @Test func missingDirAndWidthThrows() {
    let elt = element("circ-port", [("height", "8"), ("pin", "1,1"), ("x", "0"), ("y", "0")])
    #expect(throws: (any Error).self) { try AppearanceSvgReader.createShape(elt, pins: []) }
  }

  /// The modern branch of `getLocation` parses **ints**, so a fractional `x` throws even though
  /// the legacy branch would have accepted it as a double.
  @Test func fractionalCoordinateInModernFormThrows() {
    let elt = element("circ-anchor", [("facing", "east"), ("x", "1.5"), ("y", "0")])
    #expect(throws: (any Error).self) { try AppearanceSvgReader.createShape(elt, pins: []) }
  }

  /// `Direction.parse` is exact and case-sensitive.
  @Test func unknownFacingThrows() {
    let elt = element("circ-anchor", [("facing", "East"), ("x", "0"), ("y", "0")])
    #expect(throws: (any Error).self) { try AppearanceSvgReader.createShape(elt, pins: []) }
  }

  /// An out-of-range legacy box still resolves to *some* location rather than trapping: the
  /// `(int) Math.round(...)` pair wraps, exactly as `SvgReader` already does for `<ellipse>`.
  @Test func hugeLegacyBoxWrapsRatherThanTrapping() throws {
    let elt = element(
      "circ-anchor", [("height", "1e30"), ("width", "1e30"), ("x", "1e30"), ("y", "1e30")])
    let shape = try #require(try AppearanceSvgReader.createShape(elt, pins: []))
    #expect(shape is AppearanceAnchor)
  }
}

// MARK: - Delegation

@Suite("Everything else falls through to the draw-model reader")
struct AppearanceDelegationTests {

  @Test func ordinaryShapesStillParse() throws {
    let elt = element(
      "rect", [("height", "40"), ("width", "30"), ("x", "50"), ("y", "55")])
    #expect(try AppearanceSvgReader.createShape(elt, pins: []) is DrawRectangle)
  }

  /// The dynamic families live above `LogisimDraw` and are resolved by the `LogisimFile` half of
  /// the seam, which keeps the element verbatim. Nil here is that hand-off, not a loss.
  @Test func visibleElementsAreNotBuiltHere() throws {
    let elt = element("visible-led", [("path", "0"), ("x", "0"), ("y", "0")])
    #expect(try AppearanceSvgReader.createShape(elt, pins: []) == nil)
  }

  @Test func unknownTagIsNotBuiltHere() throws {
    #expect(try AppearanceSvgReader.createShape(element("nonsense", []), pins: []) == nil)
  }
}
