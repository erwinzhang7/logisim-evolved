// XmlReaderMigrationTests.swift: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Gates on `XmlReader.considerRepairs` and the label-repair pass: the two halves of the reader
// that depend on nothing but the DOM, and therefore the two that can be checked here rather
// than through the full differential rig.
//
// Each case asserts the transform *fired* and what it produced, not merely that the document
// still loads. A migration pass that silently does nothing is the failure mode these exist to
// catch: `docs/objectives.md` records that the `<2.3.0` fixture only became useful once it
// asserted the toolbar actually changed.

import Foundation
import Testing

@testable import LogisimFile

private func parse(_ xml: String) throws -> (XMLDocument, XMLElement) {
  let doc = try XMLDocument(
    data: Data(xml.utf8), options: [.nodeLoadExternalEntitiesNever])
  return (doc, doc.rootElement()!)
}

private func repaired(_ xml: String) throws -> XMLElement {
  let (doc, root) = try parse(xml)
  let reader = XmlReader(loader: Loader(), file: nil)
  try reader.considerRepairs(doc, root)
  return root
}

/// The `<lib>` children as `"name=desc"` strings: enough to assert order, which several
/// repairs depend on. Strings rather than tuples because Swift tuples are not `Equatable`.
private func libs(_ root: XMLElement) -> [String] {
  XmlIterator.forChildElements(root, "lib").map {
    "\($0.getAttribute("name"))=\($0.getAttribute("desc"))"
  }
}

private func libDescs(_ root: XMLElement) -> [String] {
  XmlIterator.forChildElements(root, "lib").map { $0.getAttribute("desc") }
}

private func libNames(_ root: XMLElement) -> [String] {
  XmlIterator.forChildElements(root, "lib").map { $0.getAttribute("name") }
}

private func toolNames(_ parent: XMLElement) -> [String] {
  XmlIterator.forChildElements(parent, "tool").map { $0.getAttribute("name") }
}

/// The `<a>` children as `"name=val"` strings, in document order.
private func attributePairs(_ parent: XMLElement) -> [String] {
  XmlIterator.forChildElements(parent, "a").map {
    "\($0.getAttribute("name"))=\($0.getAttribute("val"))"
  }
}

private func attributeNames(_ parent: XMLElement) -> [String] {
  XmlIterator.forChildElements(parent, "a").map { $0.getAttribute("name") }
}

// MARK: - < 2.3.0 toolbar repair

@Test func toolbarRepairReplacesSelectAndWiringWithEdit() throws {
  // Exactly the shape `tools/difftest/fixtures.py` synthesises: no `source=` at all, which
  // `LogisimVersion.fromString("")` turns into 0.0.0, below the gate.
  let root = try repaired(
    """
    <project>
      <!-- A real pre-2.3 project has library declarations. Without one, the subsequent
           pre-2.6.3 wiring repair dereferences Java's null lastLibElt and cannot complete. -->
      <lib name="0" desc="#Wiring"/>
      <toolbar>
        <tool name="Poke Tool"/>
        <tool name="Select Tool"/>
        <tool name="Wiring Tool"/>
        <tool name="Text Tool"/>
      </toolbar>
    </project>
    """)
  let toolbar = XmlIterator.forChildElements(root, "toolbar")[0]
  #expect(toolNames(toolbar) == ["Poke Tool", "Edit Tool", "Text Tool"])
}

@Test func toolbarRepairIsSkippedWhenEditToolAlreadyPresent() throws {
  let root = try repaired(
    """
    <project>
      <!-- Keep the fixture valid through the later pre-2.6.3 repair; this test isolates the
           toolbar guard, while Java's wiring repair requires at least one library. -->
      <lib name="0" desc="#Wiring"/>
      <toolbar>
        <tool name="Select Tool"/>
        <tool name="Wiring Tool"/>
        <tool name="Edit Tool"/>
      </toolbar>
    </project>
    """)
  let toolbar = XmlIterator.forChildElements(root, "toolbar")[0]
  #expect(toolNames(toolbar) == ["Select Tool", "Wiring Tool", "Edit Tool"])
}

@Test func toolbarRepairIsSkippedForAModernFile() throws {
  let root = try repaired(
    """
    <project source="3.6.1">
      <toolbar>
        <tool name="Select Tool"/>
        <tool name="Wiring Tool"/>
      </toolbar>
    </project>
    """)
  let toolbar = XmlIterator.forChildElements(root, "toolbar")[0]
  #expect(toolNames(toolbar) == ["Select Tool", "Wiring Tool"])
}

// MARK: - < 2.6.3 (UNVERIFIED against a real file — these pin the port, not the oracle)

@Test func circuitLabelAttributesAreRenamedWithACPrefix() throws {
  let root = try repaired(
    """
    <project source="2.6.0">
      <lib name="0" desc="#Base"/>
      <circuit name="main">
        <a name="label" val="hi"/>
        <a name="labelfont" val="SansSerif plain 12"/>
        <a name="circuit" val="main"/>
      </circuit>
    </project>
    """)
  let circuit = XmlIterator.forChildElements(root, "circuit")[0]
  #expect(
    attributeNames(circuit) == ["clabel", "clabelfont", "circuit"])
}

@Test func wiringLibraryRepairSplitsBaseAndRelocatesTools() throws {
  let root = try repaired(
    """
    <project source="2.6.0">
      <lib name="0" desc="#Base">
        <tool name="Poke Tool"/>
        <tool name="Pin"/>
        <tool name="Tunnel"/>
      </lib>
      <lib name="1" desc="#Gates">
        <tool name="Constant"/>
        <tool name="AND Gate"/>
      </lib>
      <circuit name="main">
        <comp lib="0" name="Pin" loc="(10,10)"/>
        <comp lib="0" name="Poke Tool" loc="(20,20)"/>
        <comp lib="1" name="Constant" loc="(30,30)"/>
      </circuit>
    </project>
    """)

  // `#Base` is renamed in place to `#Wiring`, keeping handle "0"; a fresh `#Base` takes the
  // next free numeric handle and is inserted after the last <lib>.
  #expect(libDescs(root) == ["#Wiring", "#Gates", "#Base"])
  #expect(libNames(root) == ["0", "1", "2"])

  let wiring = XmlIterator.forChildElements(root, "lib")[0]
  let gates = XmlIterator.forChildElements(root, "lib")[1]
  let newBase = XmlIterator.forChildElements(root, "lib")[2]

  // 4.1.0's first relocateTools call tests only whether a source-name key exists in labelMap,
  // not whether that key maps to this destination. It therefore moves Pin and Tunnel to the new
  // #Base along with Poke; the following oldBase→wiring call is skipped because src === dest.
  // This surprising call-order bug is part of the pinned migration behavior.
  #expect(toolNames(newBase) == ["Poke Tool", "Pin", "Tunnel"])
  #expect(toolNames(wiring) == ["Constant"])
  #expect(toolNames(gates) == ["AND Gate"])

  // Every reference is repointed by the label map.
  let comps = XmlIterator.forChildElements(
    XmlIterator.forChildElements(root, "circuit")[0], "comp")
  #expect(comps.map { $0.getAttribute("lib") } == ["0", "2", "0"])
}

@Test func wiringLibraryRepairCreatesWiringWhenThereIsNoBase() throws {
  let root = try repaired(
    """
    <project source="2.6.0">
      <lib name="0" desc="#Gates">
        <tool name="Constant"/>
      </lib>
    </project>
    """)
  #expect(libs(root) == ["0=#Gates", "1=#Wiring"])
  // With no old #Base there is no new #Base either, so only the Gates→Wiring Constant move
  // is in the label map.
  #expect(toolNames(XmlIterator.forChildElements(root, "lib")[1]) == ["Constant"])
}

@Test func wiringLibraryRepairIsSkippedWhenWiringAlreadyExists() throws {
  let root = try repaired(
    """
    <project source="2.6.0">
      <lib name="0" desc="#Base"/>
      <lib name="1" desc="#Wiring"/>
    </project>
    """)
  #expect(libs(root) == ["0=#Base", "1=#Wiring"])
}

@Test func legacyLibraryAndItsComponentsAreDeleted() throws {
  let root = try repaired(
    """
    <project source="2.6.0">
      <lib name="0" desc="#Wiring"/>
      <lib name="1" desc="#Legacy">
        <tool name="Logger"/>
      </lib>
      <circuit name="main">
        <comp lib="1" name="Logger" loc="(10,10)"/>
        <comp lib="0" name="Pin" loc="(20,20)"/>
      </circuit>
    </project>
    """)
  #expect(libs(root) == ["0=#Wiring"])
  let comps = XmlIterator.forChildElements(
    XmlIterator.forChildElements(root, "circuit")[0], "comp")
  #expect(comps.map { $0.getAttribute("name") } == ["Pin"])
  // A `<message>` is appended so the user is told the data was dropped.
  let messages = XmlIterator.forChildElements(root, "message")
  #expect(messages.count == 1)
  #expect(messages[0].getAttribute("value").hasPrefix("Some components have been deleted"))
}

@Test func legacyLibraryWithNoComponentsAddsNoMessage() throws {
  let root = try repaired(
    """
    <project source="2.6.0">
      <lib name="0" desc="#Wiring"/>
      <lib name="1" desc="#Legacy"/>
      <circuit name="main"/>
    </project>
    """)
  #expect(libs(root) == ["0=#Wiring"])
  #expect(XmlIterator.forChildElements(root, "message").isEmpty)
}

// MARK: - Pin attribute consolidation (ungated)

@Test func obsoletePinAttributesBecomeTypeAndBehavior() throws {
  let root = try repaired(
    """
    <project source="3.7.2">
      <lib name="0" desc="#Wiring"/>
      <circuit name="main">
        <comp lib="0" name="Pin" loc="(10,10)">
          <a name="width" val="8"/>
          <a name="output" val="true"/>
          <a name="tristate" val="true"/>
        </comp>
        <comp lib="0" name="Pin" loc="(20,20)">
          <a name="pull" val="down"/>
        </comp>
      </circuit>
    </project>
    """)
  let comps = XmlIterator.forChildElements(
    XmlIterator.forChildElements(root, "circuit")[0], "comp")
  #expect(
    attributePairs(comps[0]) == ["width=8", "type=output", "behavior=tristate"])
  // `output` absent → no `type` is written at all; `pull=down` wins over a missing tristate.
  #expect(attributePairs(comps[1]) == ["behavior=pulldown"])
}

@Test func pinConversionIsSkippedWithoutAWiringLibrary() throws {
  // No `#Wiring` declaration, so `findLibNameByDesc` returns null and Java's
  // `!lib.equals(null)` guard makes every element bail out: including a `<comp>` with no
  // `lib` at all, which a naive `lib == ""` translation would wrongly convert.
  let root = try repaired(
    """
    <project source="3.7.2">
      <lib name="0" desc="#Gates"/>
      <circuit name="main">
        <comp name="Pin" loc="(10,10)"><a name="output" val="true"/></comp>
      </circuit>
    </project>
    """)
  let comp = XmlIterator.forChildElements(
    XmlIterator.forChildElements(root, "circuit")[0], "comp")[0]
  #expect(attributePairs(comp) == ["output=true"])
}

@Test func pinConversionAppliesToToolsAndIsCaseInsensitive() throws {
  let root = try repaired(
    """
    <project source="3.7.2">
      <lib name="0" desc="#Wiring">
        <!-- Java tests the tool element's own lib attribute; nesting under a library does not
             imply it. A serialized library tool reference therefore carries lib="0". -->
        <tool lib="0" name="Pin">
          <a name="OUTPUT" val="TRUE"/>
          <a name="Pull" val="UP"/>
        </tool>
      </lib>
    </project>
    """)
  let tool = XmlIterator.forChildElements(XmlIterator.forChildElements(root, "lib")[0], "tool")[0]
  #expect(attributePairs(tool) == ["type=output", "behavior=pullup"])
}

@Test func existingTypeAndBehaviorAreLeftAlone() throws {
  let root = try repaired(
    """
    <project source="4.1.0">
      <lib name="0" desc="#Wiring"/>
      <circuit name="main">
        <comp lib="0" name="Pin" loc="(10,10)">
          <a name="type" val="input"/>
          <a name="behavior" val="simple"/>
        </comp>
      </circuit>
    </project>
    """)
  let comp = XmlIterator.forChildElements(
    XmlIterator.forChildElements(root, "circuit")[0], "comp")[0]
  #expect(attributePairs(comp) == ["type=input", "behavior=simple"])
}

// MARK: - The `== 0.0.0` early return

@Test func versionZeroRunsTheOldGatesButSkipsTheFloatRepair() throws {
  // The subtle, reachable path: a missing `source=` is 0.0.0, which is below 2.3.0 and 2.6.3
  // (so those repairs fire) and *equal* to 0.0.0 (so `repairFloatLibrary` is skipped).
  let root = try repaired(
    """
    <project>
      <toolbar>
        <tool name="Select Tool"/>
        <tool name="Wiring Tool"/>
      </toolbar>
      <lib name="0" desc="#Arithmetic">
        <tool name="FP Adder"/>
      </lib>
    </project>
    """)
  #expect(toolNames(XmlIterator.forChildElements(root, "toolbar")[0]) == ["Edit Tool"])
  #expect(libDescs(root).contains("#FPArithmetic") == false)
}

// MARK: - < 4.1.0-dev float-library split

@Test func floatLibraryRepairMovesFPToolsIntoANewLibrary() throws {
  let root = try repaired(
    """
    <project source="4.0.0">
      <lib name="0" desc="#Base"/>
      <lib name="1" desc="#Arithmetic">
        <tool name="Adder"/>
        <tool name="FP Adder"/>
        <tool name="IntToFP"/>
      </lib>
      <lib name="2" desc="#Gates"/>
      <circuit name="main">
        <comp lib="1" name="FP Adder" loc="(10,10)"/>
        <comp lib="1" name="Adder" loc="(20,20)"/>
      </circuit>
    </project>
    """)
  // Inserted immediately after #Arithmetic.
  #expect(libDescs(root) == ["#Base", "#Arithmetic", "#FPArithmetic", "#Gates"])
  let arithmetic = XmlIterator.forChildElements(root, "lib")[1]
  let float = XmlIterator.forChildElements(root, "lib")[2]
  #expect(toolNames(arithmetic) == ["Adder"])
  #expect(toolNames(float) == ["FP Adder", "IntToFP"])

  let comps = XmlIterator.forChildElements(
    XmlIterator.forChildElements(root, "circuit")[0], "comp")
  #expect(comps.map { $0.getAttribute("lib") } == ["float", "1"])
}

@Test func floatLibraryRepairReproducesUpstreamsPrecedenceBug() throws {
  // `A && B || C`; a component named exactly `IntToFP` is repointed at `float` no matter
  // which library it came from. This is a bug upstream; matching it is the whole point.
  let root = try repaired(
    """
    <project source="4.0.0">
      <lib name="1" desc="#Arithmetic"/>
      <lib name="7" desc="file#mylib.circ"/>
      <circuit name="main">
        <comp lib="7" name="IntToFP" loc="(10,10)"/>
        <comp lib="7" name="FP Adder" loc="(20,20)"/>
      </circuit>
    </project>
    """)
  let comps = XmlIterator.forChildElements(
    XmlIterator.forChildElements(root, "circuit")[0], "comp")
  #expect(comps[0].getAttribute("lib") == "float")
  // …while an `FP*` component from another library is correctly left alone.
  #expect(comps[1].getAttribute("lib") == "7")
}

@Test func floatLibraryIsAppendedWhenArithmeticIsTheLastChild() throws {
  let root = try repaired(
    """
    <project source="4.0.0">
      <lib name="0" desc="#Base"/>
      <lib name="1" desc="#Arithmetic"/>
    </project>
    """)
  #expect(libDescs(root) == ["#Base", "#Arithmetic", "#FPArithmetic"])
}

@Test func floatLibraryRepairIsSkippedAtAndAfterFourOneZero() throws {
  for source in ["4.1.0", "4.1.0-dev", "4.2.0"] {
    let root = try repaired(
      """
      <project source="\(source)">
        <lib name="1" desc="#Arithmetic"><tool name="FP Adder"/></lib>
      </project>
      """)
    // `4.1.0-dev` is *equal* to the `4.1.0dev` gate, not below it, so it too is skipped;
    // the suffix rule makes a suffixed version older than the same stable one, and the
    // separator is ignored in the comparison.
    #expect(libDescs(root) == ["#Arithmetic"], "source=\(source)")
  }
}

@Test func floatLibraryRepairFiresJustBelowTheGate() throws {
  let root = try repaired(
    """
    <project source="4.0.9">
      <lib name="1" desc="#Arithmetic"><tool name="FP Adder"/></lib>
    </project>
    """)
  #expect(libDescs(root) == ["#Arithmetic", "#FPArithmetic"])
}

// MARK: - Label repair (ensureLogisimCompatibility)

@Test func validLabelsAreLeftUntouched() throws {
  let (_, root) = try parse(
    """
    <project source="4.1.0">
      <circuit name="main">
        <a name="label" val="counter_a"/>
        <comp lib="0" name="Pin" loc="(10,10)"><a name="label" val="clk"/></comp>
      </circuit>
    </project>
    """)
  XmlReader.ensureLogisimCompatibility(root)
  let circuit = XmlIterator.forChildElements(root, "circuit")[0]
  #expect(circuit.getAttribute("name") == "main")
  #expect(attributePairs(circuit) == ["label=counter_a"])
}

@Test func invalidCircuitNamesAreRewrittenEverywhereTheyAppear() throws {
  XmlReader.labelSuffixProvider = { "deadbeef" }
  defer { XmlReader.labelSuffixProvider = { String(UUID().uuidString.lowercased().prefix(8)) } }

  let (_, root) = try parse(
    """
    <project source="2.7.0">
      <circuit name="my circuit">
        <a name="circuit" val="my circuit"/>
      </circuit>
      <circuit name="top">
        <a name="circuit" val="top"/>
        <comp name="my circuit" loc="(10,10)"/>
        <comp lib="0" name="Pin" loc="(20,20)"/>
      </circuit>
    </project>
    """)
  XmlReader.ensureLogisimCompatibility(root)

  let expected = "my_circuit_deadbeef"
  let circuits = XmlIterator.forChildElements(root, "circuit")
  #expect(circuits[0].getAttribute("name") == expected)
  #expect(attributePairs(circuits[0]) == ["circuit=" + expected])
  // The placement in the other circuit is repointed; the Pin, which has a `lib`, is not.
  let comps = XmlIterator.forChildElements(circuits[1], "comp")
  #expect(comps[0].getAttribute("name") == expected)
  #expect(comps[1].getAttribute("name") == "Pin")
}

@Test func toolbarAndLibraryToolLabelsAreBlanked() throws {
  let (_, root) = try parse(
    """
    <project source="2.7.0">
      <toolbar><tool name="Pin"><a name="label" val="stray"/></tool></toolbar>
      <lib name="0" desc="#Wiring"><tool name="Pin"><a name="label" val="stray"/></tool></lib>
    </project>
    """)
  XmlReader.ensureLogisimCompatibility(root)
  let toolbarTool = XmlIterator.forChildElements(
    XmlIterator.forChildElements(root, "toolbar")[0], "tool")[0]
  let libTool = XmlIterator.forChildElements(
    XmlIterator.forChildElements(root, "lib")[0], "tool")[0]
  #expect(attributePairs(toolbarTool) == ["label="])
  #expect(attributePairs(libTool) == ["label="])
}

@Test func generateValidVHDLLabelMatchesJava() throws {
  let suffix = "12ab34cd"
  // Trimming alone appends no suffix.
  #expect(XmlReader.generateValidVHDLLabel("  ok  ", suffix) == "ok")
  // Leading digit → "L_" prefix, and the change earns a suffix.
  #expect(XmlReader.generateValidVHDLLabel("1abc", suffix) == "L_1abc_12ab34cd")
  // `!` and `~` become "NOT_", non-word characters become "_", runs collapse, a trailing
  // underscore is dropped.
  #expect(XmlReader.generateValidVHDLLabel("a!b", suffix) == "aNOT_b_12ab34cd")
  #expect(XmlReader.generateValidVHDLLabel("a  b", suffix) == "a_b_12ab34cd")
  #expect(XmlReader.generateValidVHDLLabel("ab__", suffix) == "ab_12ab34cd")
  // Empty becomes "L_", which collapses to "L" once the trailing underscore is stripped.
  #expect(XmlReader.generateValidVHDLLabel("   ", suffix) == "L_12ab34cd")
  // Non-ASCII becomes an underscore, then Java's `_+` pass collapses it with the existing one.
  #expect(XmlReader.generateValidVHDLLabel("café", suffix) == "caf_12ab34cd")
}

@Test func labelVHDLInvalidAgreesWithVhdlContent() throws {
  #expect(VhdlLabels.labelVHDLInvalid("ok") == false)
  #expect(VhdlLabels.labelVHDLInvalid("Ok_1") == false)
  #expect(VhdlLabels.labelVHDLInvalid("1ok"))          // must start with a letter
  #expect(VhdlLabels.labelVHDLInvalid("ok_"))          // trailing underscore
  #expect(VhdlLabels.labelVHDLInvalid("o__k"))         // doubled underscore
  #expect(VhdlLabels.labelVHDLInvalid("café"))         // `\w` is ASCII-only
  #expect(VhdlLabels.labelVHDLInvalid("entity"))       // reserved word
  #expect(VhdlLabels.labelVHDLInvalid("ENTITY"))       // …case-insensitively
  #expect(VhdlLabels.labelVHDLInvalid("entityx") == false)
  // XmlReader's own copy omits the keyword check; upstream never calls it, but the two must
  // not be conflated.
  #expect(XmlReader.labelVHDLInvalid("entity") == false)
}

// MARK: - Supporting parsers

@Test func inputEventModifiersRoundTrip() throws {
  let mods = try InputEventUtil.fromString("Ctrl Shift Button1")
  #expect(InputEventUtil.toString(mods) == "Ctrl Shift Button1")
  #expect(throws: InputEventUtil.ParseError.self) {
    _ = try InputEventUtil.fromString("Meta")
  }
  #expect(try InputEventUtil.fromString("") == 0)
}

@Test func javaUnsignedParsersMatchJava() throws {
  #expect(javaParseUnsignedInt32("4294967295") == -1)
  #expect(javaParseUnsignedInt32("4294967296") == nil)
  #expect(javaParseUnsignedInt32("-1") == nil)
  #expect(javaParseUnsignedInt64("18446744073709551615") == -1)
  #expect(javaParseInt64("-9223372036854775808") == Int64.min)
  #expect(javaParseInt64("9223372036854775808") == nil)
}

@Test func javaPathsGetJoinsWithoutTreatingLaterSegmentsAsAbsolute() throws {
  #expect(javaPathsGet("/a/b", "/c") == "/a/b/c")
  #expect(javaPathsGet("", "x.hex") == "x.hex")
  #expect(javaPathsGet("/a//b", "c") == "/a/b/c")
  #expect(javaPathsGet("/a/b", "") == "/a/b")
  // `.` and `..` are *not* normalised by `Paths.get`.
  #expect(javaPathsGet("/a/b", "../c") == "/a/b/../c")
}

@Test func boardMapEntriesParseIntoCircuitMapInfo() throws {
  let (_, root) = try parse(
    """
    <boardmap boardname="Basys3">
      <mc key="a" open="1"/>
      <mc key="b" vconst="255"/>
      <mc key="c" valx="1" valy="2" valw="3" valh="4"/>
      <mc key="d" map="10,20"/>
      <mc key="e" pmap="u,open,1_2_3,42"/>
      <mc key="f"/>
    </boardmap>
    """)
  let reader = XmlReader(loader: Loader(), file: nil)
  let context = XmlReader.ReadContext(
    file: LogisimFile.createEmpty(loader: reader.loader), loader: reader.loader,
    srcFilePath: nil)
  let circuit = try Circuit(name: "main")
  let map = context.loadMap(root, "Basys3", circuit)

  #expect(Set(map.keys) == ["a", "b", "c", "d", "e"])
  #expect(map["a"]?.rect == nil && map["a"]?.constValue == nil)
  #expect(map["b"]?.constValue == 255)
  #expect(map["c"]?.rect == BoardRectangle(x: 1, y: 2, width: 3, height: 4))
  #expect(map["d"]?.rect == BoardRectangle(x: 10, y: 20, width: 1, height: 1))
  #expect(map["d"]?.isOldMapFormat == false)
  #expect(map["e"]?.pinMaps?.count == 4)
  #expect(map["e"]?.pinMaps?[0] as? CircuitMapInfo == nil)
  #expect(map["e"]?.pinMaps?[3]?.constValue == 42)
  // The `<boardmap>` element is also handed to the circuit verbatim, so the writer can
  // re-emit it without the FPGA data model.
  #expect(circuit.boardMapElement(forBoard: "Basys3") != nil)
  #expect(circuit.getMapInfo("Basys3").count == 5)
}
