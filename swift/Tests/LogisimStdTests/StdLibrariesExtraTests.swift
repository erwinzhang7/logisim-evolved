// Tests for `LogisimStd/StdLibrariesExtra.swift`: the `#TCL`, `#HDL-IP` and `#BFH-Praktika`
// libraries.
//
// These assert the two things a differential gate would only tell you about indirectly:
//
//   1. **The `_ID` strings.** A wrong character does not error. It makes one tool silently
//      unresolvable in every file that names it, which is D8's verbatim path: lossless, and
//      not what the oracle writes. There is no failing test to lead you to it, so the strings
//      are pinned here against the Java `_ID` constants.
//
//   2. **`HdlContentAttribute.parse`'s template substitution**, which is what makes 177 corpus
//      files round-trip. It is not "store the string": a value that differs from the parse
//      baseline only in line endings comes back as the BASELINE, and then equals the factory
//      default and is dropped on save. 90 of those 177 files are CRLF copies of an LF
//      template, so getting this wrong costs half the win and the gate reports it as an
//      undifferentiated count.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import Foundation
import LogisimFile
import LogisimKernel
import Testing

@testable import LogisimStd

@Suite("StdLibrariesExtra — #TCL, #HDL-IP, #BFH-Praktika")
struct StdLibrariesExtraTests {

  // MARK: Identity

  @Test("library ids match the Java `_ID` constants")
  func libraryIds() {
    #expect(TclLibrary.libraryId == "TCL")
    #expect(HdlLibrary.libraryId == "HDL-IP")
    #expect(BfhLibrary.libraryId == "BFH-Praktika")

    // The three ids `Builtin` declares, reached from the other side: a mismatch between these
    // and the library classes would register the tools under a key no `<lib desc=…>` uses.
    #expect(Builtin.tclId == TclLibrary.libraryId)
    #expect(Builtin.hdlId == HdlLibrary.libraryId)
    #expect(Builtin.bfhId == BfhLibrary.libraryId)
  }

  @Test("tool names and order match `FactoryDescription[] DESCRIPTIONS`")
  func toolNames() {
    #expect(TclLibrary().tools.map(\.name) == ["TclConsoleReds", "TclGeneric"])
    #expect(HdlLibrary().tools.map(\.name) == ["VHDL Entity", "BLIFCircuit"])
    #expect(
      BfhLibrary().tools.map(\.name) == [
        "Binary_to_BCD_converter", "BCD_to_7_Segment_decoder",
      ])
  }

  @Test("every tool carries an attribute set")
  func toolsCarryAttributes() {
    // Load-bearing: `XmlReader` only routes a `<tool>`'s `<a>` children into a tool that has
    // one, and `XmlWriter.fromLibrary` skips a tool that has none. A tool without an attribute
    // set resolves by name and still loses every attribute; the exact failure this whole file
    // set exists to remove.
    for library: Library in [TclLibrary(), HdlLibrary(), BfhLibrary()] {
      for tool in library.tools {
        #expect(tool.attributeSet != nil, "\(library.name).\(tool.name) has no attribute set")
      }
    }
  }

  // MARK: The content attribute

  @Test("`HdlContent.compare` is line-ending-insensitive and nothing else")
  func contentComparison() {
    #expect(hdlContentMatches("a\nb\n", "a\r\nb\r\n"))
    #expect(hdlContentMatches("a\nb\n", "a\rb\r"))
    #expect(hdlContentMatches("a\nb", "a\nb"))
    // Not whitespace-insensitive: Java replaces the separators with a single space and
    // compares the results verbatim.
    #expect(!hdlContentMatches("a\nb", "a\n b"))
    #expect(!hdlContentMatches("a\nb", "a\nB"))
    // "\r\n" is ONE separator, so it must flatten to one space, not two.
    #expect(hdlContentMatches("a\r\nb", "a\nb"))
    #expect(!hdlContentMatches("a\r\nb", "a\n\nb"))
  }

  @Test("a CRLF copy of the template parses back to the template")
  func crlfTemplateCollapses() throws {
    let crlf = vhdlEntityTemplate.replacingOccurrences(of: "\n", with: "\r\n")
    #expect(crlf != vhdlEntityTemplate)
    #expect(try vhdlEntityContentAttribute.parse(crlf) == vhdlEntityTemplate)
  }

  @Test("content that genuinely differs is kept verbatim")
  func differingContentIsKept() throws {
    let custom = "entity Foo is\nend Foo;\n"
    #expect(try vhdlEntityContentAttribute.parse(custom) == custom)
    // Including its line endings, since only a baseline match substitutes.
    let customCrlf = "entity Foo is\r\nend Foo;\r\n"
    #expect(try vhdlEntityContentAttribute.parse(customCrlf) == customCrlf)
  }

  /// The asymmetry that is easy to "tidy" and must not be.
  ///
  /// `TclGeneric.ContentAttribute.parse` builds a plain `VhdlContentComponent`, the **VHDL**
  /// template, while `TclGenericAttributes`' default is a `TclVhdlEntityContent`, the **TCL**
  /// one. So the TCL entity template does NOT match TclGeneric's parse baseline and survives
  /// parse unchanged; it is the attribute *default* that then makes the writer drop it.
  @Test("TclGeneric's parse baseline is the VHDL template, not the TCL one")
  func tclParseBaselineIsVhdlTemplate() throws {
    #expect(tclEntityTemplate != vhdlEntityTemplate)
    #expect(try tclGenericContentAttribute.parse(tclEntityTemplate) == tclEntityTemplate)

    let crlfTcl = tclEntityTemplate.replacingOccurrences(of: "\n", with: "\r\n")
    // A CRLF copy of the TCL template does not match the VHDL baseline either, so it is kept
    // verbatim, which is exactly what the oracle writes back for those 90 corpus files.
    #expect(try tclGenericContentAttribute.parse(crlfTcl) == crlfTcl)

    // …whereas a CRLF copy of the VHDL template does collapse.
    let crlfVhdl = vhdlEntityTemplate.replacingOccurrences(of: "\n", with: "\r\n")
    #expect(try tclGenericContentAttribute.parse(crlfVhdl) == vhdlEntityTemplate)
  }

  @Test("the templates are the Java resources, trailing newline included")
  func templateShape() {
    // Byte-for-byte checks against the resource files live in the generator that produced
    // them; these pin the two properties that break silently. `loadTemplate()` appends
    // `System.lineSeparator()` after every line, so each template ends with one.
    #expect(tclEntityTemplate.hasSuffix("end TCL_Generic;\n"))
    #expect(vhdlEntityTemplate.hasSuffix("end type_architecture;\n"))
    #expect(tclEntityTemplate.hasPrefix("library ieee;\n"))
    #expect(vhdlEntityTemplate.hasPrefix("----"))
    #expect(blifCircuitTemplate.hasPrefix("# A subset of BLIF is supported.\n"))
    // The TCL template contains a literal tab. Any "tidy the whitespace" edit breaks the
    // template match for all 177 files, and the gate reports it only as a count.
    #expect(tclEntityTemplate.contains("\t"))
  }

  // MARK: Attribute defaults

  @Test("the factory default for `content` is each component's own template")
  func contentDefaults() {
    let version = BuildInfo.version
    let tclGeneric = TclGeneric()
    #expect(
      tclGeneric.defaultValue(of: tclGenericContentAttribute, version: version)
        == tclEntityTemplate)

    let vhdl = VhdlEntityComponent()
    #expect(
      vhdl.defaultValue(of: vhdlEntityContentAttribute, version: version) == vhdlEntityTemplate)

    let blif = BlifCircuitComponent()
    #expect(
      blif.defaultValue(of: blifCircuitContentAttribute, version: version)
        == blifCircuitTemplate)
  }

  @Test("`vhdlSimName` is hidden and unsaved, so no `<tool>` can ever carry it")
  func simNameIsNotSaved() {
    #expect(vhdlSimNameAttribute.isHidden)
    #expect(!vhdlSimNameAttribute.isToSave)
  }

  @Test("VHDL and BLIF default `labelvisible` to false, unlike most components")
  func labelVisibilityDefaults() {
    // Transcribed from `VhdlEntityAttributes`/`BlifCircuitAttributes`' field initialiser
    // (`private Boolean labelVisible = false;`), which differs from the usual `true`.
    let version = BuildInfo.version
    #expect(
      VhdlEntityComponent().defaultValue(of: StdAttr.labelVisibility, version: version) == false)
    #expect(
      BlifCircuitComponent().defaultValue(of: StdAttr.labelVisibility, version: version) == false)
  }

  // MARK: BFH, the one library that is ported whole

  @Test("BinToBcd digit count and bounds follow the bit width")
  func binToBcdGeometry() {
    let factory = BinToBcd()
    let attributes = factory.createAttributeSet()
    // Default width 9 → 1 << 9 = 512 → log10(512) + 1 = 3 digits.
    #expect(factory.ports(attributes).count == 4)
    #expect(factory.offsetBounds(attributes) == Bounds.create(-30, -20, 180, 40))

    try? attributes.setRawValue(BinToBcd.binBits, BinToBcd.binBits.encode(BitWidth.known(13)))
    // 1 << 13 = 8192 → log10 + 1 = 4 digits.
    #expect(factory.ports(attributes).count == 5)
    #expect(factory.offsetBounds(attributes) == Bounds.create(-30, -20, 240, 40))
  }

  @Test("BcdToSevenSegmentDisplay has the eight fixed ports Java declares")
  func bcdPorts() {
    let factory = BcdToSevenSegmentDisplay()
    let ports = factory.ports(factory.createAttributeSet())
    #expect(ports.count == 8)
    // BCD_IN is the last one and is the only input, four bits wide.
    #expect(ports[7].type == .input)
    #expect(ports[7].fixedBitWidth == BitWidth.known(4))
    #expect(ports.prefix(7).allSatisfy { $0.type == .output })
    #expect(factory.offsetBounds(factory.createAttributeSet()) == Bounds.create(-10, -20, 50, 100))
  }

  // MARK: Registration

  @Test("registerAll installs all three, keyed by the ids `Builtin` declares")
  func registration() {
    // `BuiltinToolProviders` is process-global and every test target links into ONE test binary,
    // so clearing it here clears it for whatever else is running.
    //
    // The `defer` below always restored it, and that was still not enough: between the
    // `removeAll()` and the restore, a concurrent suite resolving a component legitimately saw an
    // empty registry. That is what made `BuiltinRegistrationTests` fail with I/O, TTL, Plexers
    // and Input/Output-Extra at 0 tools while the earlier half of the list resolved; a failure
    // that reproduced only in the full suite and passed in isolation, which is the signature of
    // shared state rather than a defect in either test.
    //
    // Running the whole thing inside `transaction` holds the registry lock across the clear, the
    // assertions and the restore, so no reader can observe the window.
    //
    // ── AND THAT WAS STILL NOT ENOUGH, FOR A SECOND AND UNRELATED REASON ─────────────────────
    //
    // The restore was `registerAll()` on the two lists THIS module can import, which is strictly
    // less than what the clear destroyed. `#Soc` lives in `LogisimSoc`, which `LogisimStd`
    // cannot import, as the assertion at the bottom of this test says out loud, so `#Soc` was
    // gone for the rest of the process. `LogisimUI` registers it exactly once behind a one-shot
    // guard, so nothing ever put it back, and `SocRegistrationTests` loaded all four components
    // as D8 placeholders in a full run while passing under `--filter`.
    //
    // Holding the lock does not help with that: the loss outlives the window. The window and the
    // loss are two different bugs with the same symptom, which is why fixing the first left a
    // residue that looked like the same failure.
    //
    // `withRegistryCleared` snapshots and puts back exactly what was there, so the restore is
    // correct no matter which module calls it, and it still holds the lock throughout.
    //
    // This does invoke provider closures, `tools(forLibraryId:)` calls one to count its tools,
    // which `transaction`'s own comment says to avoid. That guidance is about not stalling every
    // reader while a large library is constructed; here the three providers build two tools
    // each. It cannot deadlock: the lock is recursive and it is the same thread throughout.
    BuiltinToolProviders.withRegistryCleared {
      #expect(BuiltinToolProviders.tools(forLibraryId: Builtin.tclId).isEmpty)
      StdLibrariesExtra.registerAll()
      #expect(BuiltinToolProviders.tools(forLibraryId: Builtin.tclId).count == 2)
      #expect(BuiltinToolProviders.tools(forLibraryId: Builtin.hdlId).count == 2)
      #expect(BuiltinToolProviders.tools(forLibraryId: Builtin.bfhId).count == 2)

      // `#Soc` is deliberately NOT here: it lives in `LogisimSoc`, which this module cannot
      // import. See the hand-off note in `StdLibrariesExtra.swift`.
      #expect(BuiltinToolProviders.tools(forLibraryId: Builtin.socId).isEmpty)
    }
  }

  @Test("clearing the registry restores registrations THIS module cannot name")
  func clearedRegistryRestoresForeignRegistrations() {
    // The discriminating test for the bug above, and the reason it is not simply "the registry is
    // non-empty afterwards"; the old lossy restore satisfied that easily. What it could not do
    // is put back a library whose registration lives in a module `LogisimStd` cannot import.
    //
    // `#Soc` is the real instance and cannot be used here for exactly that reason, so this stands
    // a sentinel in its place: an id registered from outside any `registerAll()` list, which no
    // restore written in terms of those lists can reconstruct. Against the previous
    // `removeAll()` + `StdLibraries.registerAll()` + `StdLibrariesExtra.registerAll()` shape,
    // this is red.
    // The sentinel PUBLISHES a tool, because registered-and-empty is indistinguishable from
    // absent: `tools(forLibraryId:)` answers `[]` for both, so a sentinel with no tools would
    // make the final assertion vacuous.
    let sentinelId = "#SentinelNotInAnyRegisterAllList"
    let marker = AddTool(factory: Pin.factory)
    BuiltinToolProviders.register(libraryId: sentinelId) { [marker] }
    // Left registered-but-empty rather than removed: there is no `unregister`, and `removeAll`
    // is the very footgun this test exists to prevent. An id publishing nothing is inert;
    // `Builtin.allLibraryIds` is a hardcoded list, not derived from the provider table, so
    // nothing enumerates its way to the sentinel.
    defer { BuiltinToolProviders.register(libraryId: sentinelId) { [] } }

    #expect(BuiltinToolProviders.tools(forLibraryId: sentinelId).count == 1)

    BuiltinToolProviders.withRegistryCleared {
      #expect(
        BuiltinToolProviders.tools(forLibraryId: sentinelId).isEmpty,
        "the clear did not actually clear, so the restore assertion below proves nothing")
    }

    #expect(
      BuiltinToolProviders.tools(forLibraryId: sentinelId).count == 1,
      """
      a registration this module cannot re-create did not survive the clear. That is the \
      `#Soc` defect: the restore can only reach registrations it can import.
      """)
  }
}
