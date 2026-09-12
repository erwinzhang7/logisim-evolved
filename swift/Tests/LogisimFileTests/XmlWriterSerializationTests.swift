// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution, which is GPL-3.0-only. This port is a derivative work and is
// therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// M2's pass condition is BYTE-EXACT `.circ` output, which makes the writer's "cosmetic" details
// the specification. Everything asserted here was measured against the 4.1.0 oracle rather than
// derived from the XML spec: the JDK's identity-transform serializer disagrees with the spec in
// four places, and `XmlWriter.sort` has an ordering rule that no amount of reading the DTD would
// predict.
//
// The whole-corpus gate lives in `tools/difftest`; these tests pin the individual rules so a
// regression names itself instead of showing up as one byte in a 200 kB diff.

import Foundation
import Testing

@testable import LogisimFile

// MARK: - Helpers

private func element(_ tag: String, _ attributes: (String, String)...) -> XMLElement {
  XMLElement.createElement(tag, attributes: attributes)
}

private func text(_ value: String) -> XMLNode {
  XMLNode.text(withStringValue: value) as! XMLNode
}

/// The full document as the writer would emit it, so tests can assert on real bytes including
/// the declaration and the trailing newline.
private func serialized(_ root: XMLElement) throws -> String {
  let document = XMLDocument()
  document.characterEncoding = "UTF-8"
  document.setRootElement(root)
  return String(decoding: try XmlSerializer.serialize(document), as: UTF8.self)
}

// MARK: - Framing

@Test func declarationAndTrailingNewlineMatchTheJdkSerializer() throws {
  // `ToXMLStream.startDocumentInternal` writes standalone="no" because the identity transform
  // sets it; `endDocument` adds one line separator because indenting is on and the last write
  // was not character data.
  let out = try serialized(element("project", ("version", "1.0")))
  #expect(out == "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>\n<project version=\"1.0\"/>\n")
}

@Test func rootIsNotIndentedButEveryDescendantIsTwoSpacesPerLevel() throws {
  let root = element("l0")
  var current = root
  for depth in 1...3 {
    let child = element("l\(depth)")
    current.appendChild(child)
    current = child
  }
  let out = try serialized(root)
  #expect(
    out.hasSuffix(
      """
      <l0>
        <l1>
          <l2>
            <l3/>
          </l2>
        </l1>
      </l0>

      """))
}

// MARK: - The four serializer rules

/// Rule 3. An element with no children never closes its start tag, so it is written `/>`; this
/// is why `<lib desc="#Gates" name="1"/>` is self-closing whenever every one of its tools sits at
/// its factory default.
@Test func childlessElementsSelfClose() throws {
  let root = element("project")
  root.appendChild(element("lib", ("desc", "#Gates"), ("name", "1")))
  #expect(try serialized(root).contains("<lib desc=\"#Gates\" name=\"1\"/>"))
}

/// `ToStream.characters` returns before `closeStartTag()` on a zero-length text run, leaving the
/// start tag open, so an empty text child is indistinguishable from no children at all.
@Test func anEmptyTextChildStillSelfCloses() throws {
  let root = element("project")
  let a = element("a", ("name", "x"))
  a.appendChild(text(""))
  root.appendChild(a)
  #expect(try serialized(root).contains("<a name=\"x\"/>"))
}

/// Rules 1 and 3. An element whose only child is text gets no indentation on either side of the
/// body; this is the shape every multi-line attribute value takes, RAM/ROM `contents` above all.
@Test func aLoneTextChildIsFlushAgainstBothTags() throws {
  let root = element("circuit")
  let a = element("a", ("name", "contents"))
  a.appendChild(text("addr/data: 24 32\n8c210000\n"))
  root.appendChild(a)
  root.appendChild(element("a", ("name", "dataWidth"), ("val", "32")))
  let out = try serialized(root)
  #expect(out.contains("<a name=\"contents\">addr/data: 24 32\n8c210000\n</a>"))
}

/// Rules 1 and 2 together, on the exact node upstream puts inside `<project>`. The leading `\n`
/// of the banner is dropped by `skipBeginningNewlines` and replaced by the indent; the trailing
/// one survives and becomes the blank line before the first `<lib>`.
@Test func theProjectBannerLosesItsLeadingNewlineAndKeepsItsTrailingOne() throws {
  let root = element("project", ("version", "1.0"), ("source", "4.1.0"))
  root.appendChild(
    text("\nThis file is intended to be loaded by \(BuildInfo.displayName)(\(BuildInfo.url)).\n"))
  root.appendChild(element("lib", ("desc", "#Wiring"), ("name", "0")))
  let out = try serialized(root)
  #expect(
    out.contains(
      """
      <project source="4.1.0" version="1.0">
        This file is intended to be loaded by Logisim-evolution v4.1.0(https://github.com/logisim-evolution/).

        <lib desc="#Wiring" name="0"/>
      </project>
      """))
}

/// Only *leading newlines* are skipped: not spaces, not tabs, not carriage returns. Measured
/// against the real transformer; `CharacterBuffer.addText` tests `text[start] == '\n'` and
/// nothing else.
@Test func onlyLeadingNewlinesAreSkippedFromAnIndentedTextNode() throws {
  let root = element("r")
  root.appendChild(text("\n\n \nA"))
  root.appendChild(element("post"))
  let out = try serialized(root)
  #expect(out.contains("<r>\n   \nA\n  <post/>\n</r>"))
}

/// Rule 4. Foundation preserves insertion order; Xerces sorts by qualified name, and the
/// serializer just walks the map. `version` is set before `source` in `fromLogisimFile`, and the
/// file says `source` first.
@Test func attributesAreEmittedInAscendingNameOrder() throws {
  let root = element("z", ("zz", "1"), ("Aa", "2"), ("aB", "3"), ("b", "4"), ("_x", "5"))
  #expect(try serialized(root).contains("<z Aa=\"2\" _x=\"5\" aB=\"3\" b=\"4\" zz=\"1\"/>"))
}

// MARK: - Escaping

/// Not the XML spec's minimum: `>` is escaped, `'` is not, `"` is, and tab/LF/CR become decimal
/// character references. Every entry probed against the real transformer.
@Test func attributeEscapingMatchesTheJdkTable() throws {
  #expect(try XmlSerializer.escapeAttributeValue("a<b>c&d\"e'f") == "a&lt;b&gt;c&amp;d&quot;e'f")
  #expect(try XmlSerializer.escapeAttributeValue("\t\n\r") == "&#9;&#10;&#13;")
  // C1 controls stay literal in an attribute; they do NOT in text.
  #expect(try XmlSerializer.escapeAttributeValue("\u{7F}\u{9F}") == "\u{7F}\u{9F}")
  #expect(try XmlSerializer.escapeAttributeValue("é中") == "é中")
  #expect(try XmlSerializer.escapeAttributeValue("\u{1F600}") == "&#128512;")
}

/// The asymmetries are real: `"` passes through because `outputCharacters` short-circuits it,
/// tab and LF are literal, CR is not, and C1 controls become character references here.
@Test func textEscapingMatchesTheJdkTable() throws {
  #expect(try XmlSerializer.escapeTextContent("a<b>c&d\"e'f") == "a&lt;b&gt;c&amp;d\"e'f")
  #expect(try XmlSerializer.escapeTextContent("\t\n") == "\t\n")
  #expect(try XmlSerializer.escapeTextContent("\r") == "&#13;")
  #expect(try XmlSerializer.escapeTextContent("\u{7F}\u{9F}") == "&#127;&#159;")
  #expect(try XmlSerializer.escapeTextContent("\u{1F600}") == "&#128512;")
}

/// The C0 controls XML 1.0 forbids make the real transformer throw a `SAXException`, which
/// escapes into `Loader.save`. D13 keeps that catchable rather than fatal.
@Test func xml10InvalidControlCharactersThrow() {
  for scalar in [0x00, 0x08, 0x0B, 0x0C, 0x0E, 0x1F] {
    let value = String(Unicode.Scalar(UInt32(scalar))!)
    #expect(throws: XmlWriterError.self) { try XmlSerializer.escapeTextContent(value) }
    #expect(throws: XmlWriterError.self) { try XmlSerializer.escapeAttributeValue(value) }
  }
  // Deliberately NOT rejected: the serializer's UTF-8 fast path emits these before it ever
  // consults the validity check, so being stricter than upstream would be a divergence.
  #expect(try! XmlSerializer.escapeTextContent("\u{FFFE}") == "\u{FFFE}")
}

// MARK: - Java string ordering

/// Swift's `<` on `String` orders by canonical equivalence; Java orders by UTF-16 code unit.
/// The two disagree on exactly the inputs below, and `sort` depends on Java's answer.
@Test func javaStringOrderIsUtf16CodeUnitOrder() {
  // U+1F600 is two surrogates starting 0xD83D, so Java places it BELOW U+FB03: Swift's `<`
  // compares by scalar and places it above.
  #expect(javaStringCompareTo("\u{1F600}", "\u{FB03}") < 0)
  #expect(("\u{1F600}" < "\u{FB03}") == false)
  // Decomposed "e" + U+0301 sorts BEFORE "z" (it starts with 'e'); precomposed é (U+00E9 = 233)
  // sorts AFTER it. Swift considers the two strings equal, so this is invisible to `==`.
  #expect(javaStringCompareTo("e\u{0301}", "z") < 0)
  #expect(javaStringCompareTo("\u{00E9}", "z") > 0)
  #expect("\u{00E9}" == "e\u{0301}")
  #expect(javaStringCompareTo("abc", "abcd") == -1)
  #expect(javaStringCompareTo("", "") == 0)
}

// MARK: - sort

private func childNames(_ element: XMLElement) -> [String] {
  (element.children ?? []).map { node in
    guard let e = node as? XMLElement else { return "#text" }
    let interesting = ["val", "loc", "name", "desc", "from", "x"]
    for key in interesting where e.attribute(forName: key) != nil {
      return (e.name ?? "") + ":" + (e.attribute(forName: key)!.stringValue ?? "")
    }
    return e.name ?? ""
  }
}

/// The comparator's first two keys: tag name, then the whole attribute set rendered as one
/// space-joined string. Verified identical to the real `XmlWriter.sort` driven by reflection.
@Test func circuitChildrenSortByNameThenByAttributeString() {
  let root = element("circuit", ("name", "main"))
  root.appendChild(element("wire", ("from", "(10,10)"), ("to", "(20,10)")))
  root.appendChild(element("comp", ("lib", "0"), ("loc", "(100,120)"), ("name", "Pin")))
  root.appendChild(element("a", ("name", "circuit"), ("val", "main")))
  root.appendChild(element("boardmap", ("boardname", "b")))
  root.appendChild(element("comp", ("loc", "(5,5)"), ("name", "sub")))
  root.appendChild(element("comp", ("lib", "0"), ("loc", "(1000,10)"), ("name", "Pin")))
  root.appendChild(element("comp", ("lib", "0"), ("loc", "(100,12)"), ("name", "Pin")))
  root.appendChild(element("a", ("name", "clabelfont"), ("val", "SansSerif plain 12")))
  XmlWriter.sort(root)
  #expect(
    childNames(root) == [
      "a:main", "a:SansSerif plain 12", "boardmap", "comp:(100,12)", "comp:(100,120)",
      "comp:(1000,10)", "comp:(5,5)", "wire:(10,10)",
    ])
  // Two things worth naming: `loc` is compared as TEXT, so "(100,12)" precedes "(100,120)"
  // precedes "(1000,10)"; and a `lib`-bearing comp precedes a subcircuit's `lib`-less one,
  // because "lib=" precedes "loc=".
}

/// `project`, `lib` and `toolbar` keep their order, and the exclusion is exactly one level
/// deep, so the `<a>` children of an excluded `<tool>` are still sorted.
@Test func orderBearingElementsAreNotSortedButTheirChildrenAre() {
  let root = element("project", ("version", "1.0"), ("source", "4.1.0"))
  let lib = element("lib", ("name", "1"), ("desc", "#Gates"))
  lib.appendChild(element("tool", ("name", "Zed")))
  lib.appendChild(element("tool", ("name", "Alpha")))
  let tool = element("tool", ("name", "Pin"))
  tool.appendChild(element("a", ("name", "width"), ("val", "4")))
  tool.appendChild(element("a", ("name", "appearance"), ("val", "classic")))
  lib.appendChild(tool)
  root.appendChild(lib)
  root.appendChild(element("lib", ("name", "0"), ("desc", "#Wiring")))
  let toolbar = element("toolbar")
  toolbar.appendChild(element("tool", ("lib", "7"), ("name", "Poke Tool")))
  toolbar.appendChild(element("sep"))
  toolbar.appendChild(element("tool", ("lib", "7"), ("name", "Edit Tool")))
  root.appendChild(toolbar)
  root.appendChild(element("main", ("name", "main")))
  XmlWriter.sort(root)

  #expect(childNames(root) == ["lib:1", "lib:0", "toolbar", "main:main"])
  #expect(childNames(lib) == ["tool:Zed", "tool:Alpha", "tool:Pin"])
  #expect(childNames(tool) == ["a:classic", "a:4"])
  #expect(childNames(toolbar) == ["tool:Poke Tool", "sep", "tool:Edit Tool"])
}

/// `<appear>` is the one special case: only `circ-port` children move, they move to the END, the
/// drawn shapes keep their relative order, and `sort` returns **without recursing**, so nothing
/// inside an appearance is sorted at any depth.
@Test func appearSortsOnlyCircuitPortsAndDoesNotRecurse() {
  let root = element("appear")
  root.appendChild(element("circ-port", ("height", "8"), ("pin", "160,200"), ("x", "55")))
  let polyline = element("polyline", ("fill", "none"), ("points", "1,2 3,4"))
  polyline.appendChild(element("zzz"))
  polyline.appendChild(element("aaa"))
  root.appendChild(polyline)
  root.appendChild(element("circ-port", ("height", "8"), ("pin", "160,100"), ("x", "45")))
  root.appendChild(element("rect", ("height", "40"), ("width", "50")))
  XmlWriter.sort(root)
  #expect(childNames(root) == ["polyline", "rect", "circ-port:45", "circ-port:55"])
  #expect(childNames(polyline) == ["zzz", "aaa"])
}

/// With no `circ-port` at all the section is returned untouched: including, again, no recursion.
@Test func appearWithNoPortsIsLeftCompletelyAlone() {
  let root = element("appear")
  let polyline = element("polyline", ("points", "9"))
  polyline.appendChild(element("zzz"))
  polyline.appendChild(element("aaa"))
  root.appendChild(polyline)
  root.appendChild(element("rect", ("width", "1")))
  root.appendChild(element("circle", ("r", "2")))
  XmlWriter.sort(root)
  #expect(childNames(root) == ["polyline", "rect", "circle"])
  #expect(childNames(polyline) == ["zzz", "aaa"])
}

/// `attrToString` escapes `&` first and `"` second, and nothing else; `<` passes through. It is
/// only ever a sort key, so the escaping shows up purely as ordering.
@Test func theSortKeyEscapesAmpersandThenQuoteAndNothingElse() {
  let root = element("circuit")
  root.appendChild(element("a", ("name", "x"), ("val", "a&b")))
  root.appendChild(element("a", ("name", "x"), ("val", "a\"b")))
  root.appendChild(element("a", ("name", "x"), ("val", "a<b")))
  root.appendChild(element("a", ("name", "x"), ("val", "a&amp;b")))
  XmlWriter.sort(root)
  #expect(childNames(root) == ["a:a&amp;b", "a:a&b", "a:a\"b", "a:a<b"])
}

/// `attrsToString` short-circuits at zero and one attribute. All three branches must agree, and
/// an attribute-less element sorts first because its key is the empty string.
@Test func attributeCountShortCircuitsAgreeWithTheSortingBranch() {
  let root = element("circuit")
  root.appendChild(element("comp", ("name", "b")))
  root.appendChild(element("comp"))
  root.appendChild(element("comp", ("lib", "0"), ("name", "a")))
  root.appendChild(element("comp", ("name", "a")))
  XmlWriter.sort(root)
  #expect(childNames(root) == ["comp", "comp:a", "comp:a", "comp:b"])
  #expect((root.children![1] as! XMLElement).attribute(forName: "lib") != nil)
}

/// Attribute values are compared in Java's order, which is where an astral character and a
/// decomposed accent both change the answer relative to Swift's `<`.
///
/// The comparison below goes through UTF-16 code units deliberately: Swift's `String ==` treats
/// `"\u{00E9}"` and `"e\u{0301}"` as equal, so asserting on `[String]` would pass no matter which
/// of the two came out first: a vacuous test of exactly the property under test.
@Test func sortUsesUtf16OrderForAttributeValues() {
  let root = element("circuit")
  for name in ["\u{1F600}", "\u{FB03}", "z", "\u{00E9}", "e\u{0301}"] {
    root.appendChild(element("comp", ("name", name)))
  }
  XmlWriter.sort(root)
  let produced = (root.children ?? []).map { node -> [UInt16] in
    Array(((node as! XMLElement).attribute(forName: "name")?.stringValue ?? "").utf16)
  }
  let expected = ["e\u{0301}", "z", "\u{00E9}", "\u{1F600}", "\u{FB03}"].map { Array($0.utf16) }
  #expect(produced == expected)
}

/// A text node in a sorted element sorts by `"#text"`, which precedes every tag name this writer
/// produces. Java agrees: and only by luck, because its `attrsToString(null)` would have thrown
/// had the name key not already decided the comparison.
@Test func aTextSiblingSortsByItsNodeName() {
  let root = element("circuit")
  root.appendChild(element("comp", ("name", "b")))
  root.appendChild(text("hello"))
  XmlWriter.sort(root)
  #expect(childNames(root) == ["#text", "comp:b"])
}

/// 4.1.0's `XmlWriter.stringCompare` deliberately returns `-1` when both node values are null.
/// That makes its comparator inconsistent and reverses a tied run. This odd result is intentional:
/// the port's differential gate requires the 4.1.0 writer's byte-exact order, not a repaired
/// comparator from a later upstream version.
@Test func tiedSiblingsReproduceThe410Comparator() {
  let root = element("circuit")
  for tag in ["A", "B", "C"] {
    let comp = element("comp", ("lib", "0"), ("loc", "(1,1)"), ("name", "Splitter"))
    comp.appendChild(element("a", ("name", "tag"), ("val", tag)))
    root.appendChild(comp)
  }
  root.appendChild(element("wire", ("from", "(0,0)"), ("to", "(0,10)")))
  XmlWriter.sort(root)
  let tags = (root.children ?? []).compactMap { node -> String? in
    guard let e = node as? XMLElement, e.name == "comp" else { return nil }
    return (e.children?.first as? XMLElement)?.attribute(forName: "val")?.stringValue
  }
  #expect(tags == ["C", "B", "A"])
  #expect(XmlWriter.compareNodes(root.children![0], root.children![1]) == -1)
}

// MARK: - Path relativization

/// `java.nio.file.Path.relativize`, which `Paths.get` feeds *unnormalised*, so `.` and `..`
/// inside either path are ordinary name elements, not navigation.
@Test func filePathRelativizationFollowsJavaNotUrlStandardization() throws {
  #expect(try XmlWriter.javaRelativize(base: "/a/b", target: "/a/b/c.tcl") == "c.tcl")
  #expect(try XmlWriter.javaRelativize(base: "/a/b/c", target: "/a/x/y.tcl") == "../../x/y.tcl")
  #expect(try XmlWriter.javaRelativize(base: "/a/b", target: "/a/b") == "")
  #expect(try XmlWriter.javaRelativize(base: "a/b", target: "a/c") == "../c")
  // Unnormalised: ".." is compared as a name element, never resolved.
  #expect(try XmlWriter.javaRelativize(base: "/a/b", target: "/a/../c") == "../../c")
  #expect(throws: XmlWriterError.self) {
    try XmlWriter.javaRelativize(base: "/a/b", target: "rel/c")
  }
}

// MARK: - BuildInfo

/// Three strings that are byte-visible in every saved file. Pinned to what the shipped 4.1.0
/// oracle jar reports, because a wrong one is a diff on line 2 of every file.
@Test func buildInfoCarriesTheOracleJarsStrings() {
  #expect(BuildInfo.version.description == "4.1.0")
  #expect(BuildInfo.displayName == "Logisim-evolution v4.1.0")
  #expect(BuildInfo.url == "https://github.com/logisim-evolution/")
}
