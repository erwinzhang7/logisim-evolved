// SvgAttributeOrderTests: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// Regression cover for the `<appear>` byte-exactness defect: `SvgElement` used to serialise
// attributes in `setAttribute` *insertion* order, which no element upstream ever emits. Upstream
// builds its document with `DocumentBuilder` and writes it with `TransformerFactory`
// (`XmlWriter.java:184`, `:198-204`), and the JDK's Xerces `NamedNodeMapImpl` keeps its nodes in
// a name-sorted list that `setNamedItem` binary-searches with `String.compareTo`. So every
// element 4.1.0 writes is alphabetical by attribute name, in UTF-16 code-unit order.
//
// The `expected` string in each corpus case below is a literal, verbatim form observed in the
// 577-file harvested corpus. Reproduce the full set with:
//
//   cd $LOGISIM_CORPUS/harvested
//   grep -h -o '<rect [^>]*>' *.circ | sed 's/="[^"]*"//g' | sort -u
//
// Not one non-alphabetical form occurs for any element kind (rect, ellipse, polygon, polyline,
// path, text, circ-anchor, circ-port). Since the corpus was written by upstream and read back by
// it, these forms are the round-trip target byte-for-byte.

import Testing

@testable import LogisimDraw
@testable import LogisimKernel

/// The attribute *names* of an element, in the order they would serialise.
private func names(_ elt: SvgElement) -> [String] { elt.attributes.map(\.name) }

/// A corpus-style shorthand: `rect fill height stroke x y`: the tag plus its value-stripped
/// attribute list, exactly what the `grep | sed | sort -u` pipeline in the header prints.
private func corpusForm(_ elt: SvgElement) -> String {
  ([elt.tagName] + names(elt)).joined(separator: " ")
}

// MARK: - SvgElement: the ordering rule itself

@Test func attributesSerialiseAlphabeticallyNotInInsertionOrder() {
  let elt = SvgElement("rect")
  // Deliberately the order `SvgCreator.createRectangular` uses, which is *not* sorted.
  elt.setAttribute("x", "10")
  elt.setAttribute("y", "20")
  elt.setAttribute("width", "30")
  elt.setAttribute("height", "40")
  elt.setAttribute("stroke", "#000000")

  #expect(names(elt) == ["height", "stroke", "width", "x", "y"])
}

@Test func orderIsIndependentOfInsertionSequence() {
  let forward = SvgElement("g")
  for n in ["a", "b", "c", "d"] { forward.setAttribute(n, "v") }
  let reverse = SvgElement("g")
  for n in ["d", "c", "b", "a"] { reverse.setAttribute(n, "v") }

  #expect(names(forward) == names(reverse))
  #expect(names(forward) == ["a", "b", "c", "d"])
}

// MARK: - SvgElement: what "alphabetical" means (UTF-16 code units, per String.compareTo)

@Test func hyphenSortsBeforeEveryLetterSoAPrefixPrecedesItsExtensions() {
  // '-' is U+002D, below every letter and digit. This is why `stroke` comes before
  // `stroke-width` and `fill` before `fill-opacity`, and it is the ordering the corpus shows.
  let elt = SvgElement("path")
  elt.setAttribute("stroke-width", "2")
  elt.setAttribute("stroke", "#000000")
  elt.setAttribute("stroke-opacity", "0.500")

  #expect(names(elt) == ["stroke", "stroke-opacity", "stroke-width"])
}

@Test func multiWordNamesLandWhereTheCorpusPutsThem() {
  let elt = SvgElement("text")
  for n in [
    "text-anchor", "font-weight", "font-family", "dominant-baseline", "font-size", "fill",
    "font-style", "fill-opacity", "y", "x",
  ] {
    elt.setAttribute(n, "v")
  }

  // 'd' < 'f'; within "f…", 'i' (U+0069) < 'o' (U+006F) puts every `fill*` before every `font*`;
  // within "font-", 'f' < 'i' < 's' < 'w' orders family/size/style/weight.
  #expect(
    names(elt) == [
      "dominant-baseline", "fill", "fill-opacity", "font-family", "font-size", "font-style",
      "font-weight", "text-anchor", "x", "y",
    ])
}

@Test func digitSuffixedCoordinatesSortAfterTheirBareForm() {
  let elt = SvgElement("line")
  for n in ["y2", "x1", "y", "x2", "y1", "x"] { elt.setAttribute(n, "0") }
  #expect(names(elt) == ["x", "x1", "x2", "y", "y1", "y2"])
}

@Test func orderingIsCodepointOrderNotLocaleCollation() {
  // Swift's `String.<` orders by Unicode canonical equivalence and would put "a" before "B";
  // `String.compareTo` compares UTF-16 units, so uppercase (U+0041…) sorts before lowercase.
  // No upstream attribute name is uppercase, but the comparator must be the Java one regardless.
  let elt = SvgElement("g")
  for n in ["b", "B", "a", "A", "_z", "Z"] { elt.setAttribute(n, "v") }
  #expect(names(elt) == ["A", "B", "Z", "_z", "a", "b"])
  #expect("A" < "a")  // sanity: this direction agrees; the "a" vs "B" case below does not.
  #expect(names(SvgElement.of(["a", "B"])) == ["B", "a"])
}

// MARK: - SvgElement: DOM mutation semantics that sorting must not disturb

@Test func setAttributeTwiceKeepsOneSlotWithTheLaterValue() {
  let elt = SvgElement("rect")
  elt.setAttribute("fill", "none")
  elt.setAttribute("x", "1")
  elt.setAttribute("fill", "#ff0000")

  #expect(names(elt) == ["fill", "x"])
  #expect(elt.getAttribute("fill") == "#ff0000")
}

@Test func removeAttributeDeletesTheSlotRatherThanEmptyingIt() {
  // `SvgCreator.populateStroke` sets `fill="none"`, then `populateFill` removes it for a black
  // fill. An emitted `fill=""` would be a byte difference against every corpus file.
  let elt = SvgElement("rect")
  elt.setAttribute("fill", "none")
  elt.setAttribute("x", "1")
  elt.removeAttribute("fill")

  #expect(names(elt) == ["x"])
  #expect(elt.hasAttribute("fill") == false)
  #expect(elt.getAttribute("fill") == "")  // Element.getAttribute: "", never nil.
}

@Test func removeOfAnAbsentAttributeIsANoOp() {
  let elt = SvgElement("rect")
  elt.setAttribute("x", "1")
  elt.removeAttribute("fill")
  #expect(names(elt) == ["x"])
}

// MARK: - SvgCreator: the emitted forms must match the corpus literally

@Test func roundRectangleMatchesTheCorpusRectForm() throws {
  let rrect = RoundRectangle(x: 10, y: 20, w: 30, h: 40)
  try rrect.setValue(DrawAttr.paintType, DrawAttr.paintStrokeFill)
  try rrect.setValue(DrawAttr.fillColor, ColorSpec(red: 0xFF, green: 0x00, blue: 0x00))
  try rrect.setValue(DrawAttr.strokeWidth, 2)
  try rrect.setValue(DrawAttr.cornerRadius, 5)

  // Observed: <rect fill height rx ry stroke stroke-width width x y/>
  #expect(corpusForm(rrect.toSvgElement()) == "rect fill height rx ry stroke stroke-width width x y")
}

@Test func blackFilledRoundRectangleMatchesTheCorpusFillLessRectForm() throws {
  // The `removeAttribute("fill")` branch. Observed: <rect height rx ry stroke width x y/>
  let rrect = RoundRectangle(x: 0, y: 0, w: 10, h: 10)
  try rrect.setValue(DrawAttr.paintType, DrawAttr.paintStrokeFill)
  try rrect.setValue(DrawAttr.fillColor, .black)
  try rrect.setValue(DrawAttr.strokeWidth, 1)
  try rrect.setValue(DrawAttr.cornerRadius, 3)

  #expect(corpusForm(rrect.toSvgElement()) == "rect height rx ry stroke width x y")
}

@Test func plainRectangleMatchesTheCorpusRectForms() throws {
  let rect = DrawRectangle(x: 1, y: 2, w: 3, h: 4)
  try rect.setValue(DrawAttr.paintType, DrawAttr.paintStrokeFill)
  try rect.setValue(DrawAttr.fillColor, ColorSpec(red: 1, green: 2, blue: 3))
  try rect.setValue(DrawAttr.strokeWidth, 3)

  // Observed: <rect fill height stroke stroke-width width x y/>
  #expect(corpusForm(rect.toSvgElement()) == "rect fill height stroke stroke-width width x y")
}

@Test func ovalMatchesTheCorpusEllipseForm() throws {
  let oval = Oval(x: 4, y: 6, w: 20, h: 10)
  try oval.setValue(DrawAttr.paintType, DrawAttr.paintStrokeFill)
  try oval.setValue(DrawAttr.fillColor, ColorSpec(red: 0x12, green: 0x34, blue: 0x56))
  try oval.setValue(DrawAttr.strokeWidth, 1)

  // Observed: <ellipse cx cy fill rx ry stroke/>
  let elt = oval.toSvgElement()
  #expect(corpusForm(elt) == "ellipse cx cy fill rx ry stroke")
  // Values must survive the reorder unchanged.
  #expect(elt.getAttribute("cx") == "14")
  #expect(elt.getAttribute("rx") == "10")
  #expect(elt.getAttribute("fill") == "#123456")
}

@Test func polygonAndPolylineMatchTheCorpusPolyForms() throws {
  func poly(closed: Bool) throws -> Poly {
    // `Poly.init` became throwing when the empty-polygon trap was fixed for D13: `<polygon
    // points=""/>` comes straight from a .circ and used to kill the process on `hs[0]`.
    let p = try Poly(
      closed: closed,
      locations: [
        Location.create(0, 0, hasToSnap: false),
        Location.create(10, 0, hasToSnap: false),
        Location.create(10, 10, hasToSnap: false),
      ])
    try p.setValue(DrawAttr.paintType, DrawAttr.paintStrokeFill)
    try p.setValue(DrawAttr.fillColor, ColorSpec(red: 9, green: 9, blue: 9))
    try p.setValue(DrawAttr.strokeWidth, 4)
    return p
  }

  // Observed: <polygon fill points stroke stroke-width/> and <polyline fill points stroke …/>
  #expect(try corpusForm(poly(closed: true).toSvgElement()) == "polygon fill points stroke stroke-width")
  #expect(
    try corpusForm(poly(closed: false).toSvgElement()) == "polyline fill points stroke stroke-width")
}

@Test func curveMatchesTheCorpusPathForm() throws {
  let curve = Curve(
    end0: Location.create(0, 0, hasToSnap: false),
    end1: Location.create(20, 0, hasToSnap: false),
    control: Location.create(10, 10, hasToSnap: false))
  try curve.setValue(DrawAttr.paintType, DrawAttr.paintStrokeFill)
  try curve.setValue(DrawAttr.fillColor, ColorSpec(red: 0xAB, green: 0xCD, blue: 0xEF))
  try curve.setValue(DrawAttr.strokeWidth, 2)

  // Observed: <path d fill stroke stroke-width/>
  let elt = curve.toSvgElement()
  #expect(corpusForm(elt) == "path d fill stroke stroke-width")
  #expect(elt.getAttribute("d") == "M0,0 Q10,10 20,0")
}

@Test func textMatchesTheCorpusTextForm() throws {
  let text = DrawText(x: 7, y: 8, text: "hi")
  try text.setValue(DrawAttr.font, FontSpec(family: "SansSerif", style: .bold, size: 12))
  try text.setValue(DrawAttr.fillColor, ColorSpec(red: 0, green: 0, blue: 0xFF))

  // Observed: <text dominant-baseline fill font-family font-size font-weight text-anchor x y>
  let elt = text.toSvgElement()
  #expect(
    corpusForm(elt) == "text dominant-baseline fill font-family font-size font-weight text-anchor x y")
  #expect(elt.textContent == "hi")
}

@Test func blackTextOmitsFillAndStillSortsCorrectly() throws {
  let text = DrawText(x: 0, y: 0, text: "x")
  try text.setValue(DrawAttr.font, FontSpec(family: "SansSerif", style: .italic, size: 12))
  try text.setValue(DrawAttr.fillColor, .black)

  // Observed: <text font-family font-size font-style text-anchor x y>; plus the
  // dominant-baseline this version always writes, which sorts to the front.
  #expect(
    corpusForm(text.toSvgElement())
      == "text dominant-baseline font-family font-size font-style text-anchor x y")
}

@Test func lineEmitsStrokeAndCoordinatesInSortedOrder() throws {
  let line = Line(x0: 1, y0: 2, x1: 3, y1: 4)
  try line.setValue(DrawAttr.strokeWidth, 2)

  // `createLine` sets x1, y1, x2, y2 in that order, then populateStroke appends stroke-width,
  // stroke and fill. Sorted, the y1/x2 pair swaps.
  let elt = line.toSvgElement()
  #expect(corpusForm(elt) == "line fill stroke stroke-width x1 x2 y1 y2")
  #expect(elt.getAttribute("x1") == "1")
  #expect(elt.getAttribute("y1") == "2")
  #expect(elt.getAttribute("x2") == "3")
  #expect(elt.getAttribute("y2") == "4")
}

@Test func opacityAttributesSortBesideTheirBaseAttribute() throws {
  let rect = DrawRectangle(x: 0, y: 0, w: 1, h: 1)
  try rect.setValue(DrawAttr.paintType, DrawAttr.paintStrokeFill)
  try rect.setValue(DrawAttr.fillColor, ColorSpec(red: 1, green: 2, blue: 3, alpha: 128))
  try rect.setValue(DrawAttr.strokeColor, ColorSpec(red: 4, green: 5, blue: 6, alpha: 64))
  try rect.setValue(DrawAttr.strokeWidth, 2)

  #expect(
    corpusForm(rect.toSvgElement())
      == "rect fill fill-opacity height stroke stroke-opacity stroke-width width x y")
}

// MARK: - helper

extension SvgElement {
  fileprivate static func of(_ names: [String]) -> SvgElement {
    let elt = SvgElement("g")
    for n in names { elt.setAttribute(n, "v") }
    return elt
  }
}
