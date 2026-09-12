// ExplorerNamesTests.swift: part of logisim-evolved.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE SIDEBAR'S OWN STRINGS, NOT THE MODEL'S
//
// The owner reported seeing "DipSwitch" in the explorer where 4.1.0 says "Dip switch". The fix
// is in `LogisimStd`, and `LogisimStdTests/DisplayNameOracleTests` gates it against the jar,
// but that suite asks *factories and tools*. It does not prove the sidebar reads them.
//
// `ProjectOutlineBuilder` is what the sidebar renders, and it has a documented history of
// exactly this gap: `Options.toolbarData` was parsed, stored, round-tripped byte-exactly by the
// M2 gate, and read by no view (`ComponentPaletteTests`' header). A model-level gate passing
// while the view shows something else is the failure mode here, so these assertions are on
// `outline.libraries[].name` and `outline.libraries[].tools[].name`, the strings that reach
// the screen, and never on the factory.
//
// The default template declares twelve visible builtin libraries including `I/O`, `TTL`,
// `Input/Output-Extra` and `FPArithmetic`, so the four families that carried the divergence are
// all present in a plain new document. Nothing has to be constructed specially.
// ═════════════════════════════════════════════════════════════════════════════════════════════
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import Foundation
import LogisimFile
import LogisimStd
import Testing

@testable import LogisimUI

@Suite("Explorer sidebar strings", .serialized)
struct ExplorerNamesTests {

  @MainActor
  private func makeOutline() throws -> ProjectOutline {
    let host = try #require(
      try LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
    return host.outline
  }

  @MainActor
  private func toolNames(_ outline: ProjectOutline, inLibraryNamed header: String) throws
    -> [String]
  {
    let all = outline.libraries.map(\.name)
    let library = try #require(
      outline.libraries.first { $0.name == header },
      Comment(
        rawValue: "the sidebar has no library header \(header.debugDescription); it has \(all)"))
    return library.tools.map(\.name)
  }

  @Test("the group headers are 4.1.0's display names, not the .circ library ids")
  @MainActor
  func libraryHeaders() throws {
    let outline = try makeOutline()
    let headers = outline.libraries.map(\.name)

    // Twelve visible libraries; `#Base` is hidden, exactly as upstream hides it.
    #expect(headers.count == 12, "sidebar shows \(headers)")

    // The two that were wrong. Both are `getDisplayName()` overrides upstream, and both differ
    // from the `_ID` the `.circ` file writes, which is why writing the id here looked right.
    #expect(headers.contains("Input/Output Extra"))
    #expect(!headers.contains("Input/Output-Extra"), "that is the _ID, not the display name")
    #expect(headers.contains("Floating Point Arithmetic"))
    #expect(!headers.contains("FP Arithmetic"), "that string is in neither 4.1.0 nor its bundle")

    // And the ones that were already right, so a blanket "use the id" or "use some table"
    // regression is visible too.
    #expect(headers.contains("Input/Output"))  // _ID is "I/O"
    #expect(headers.contains("BFH mega functions"))  // _ID is "BFH-Praktika"
    #expect(headers.contains("Gates"))  // _ID and display name agree
  }

  @Test("the component rows are display names, not _IDs")
  @MainActor
  func componentRowsUseDisplayNames() throws {
    let outline = try makeOutline()

    let io = try toolNames(outline, inLibraryNamed: "Input/Output")
    // The reported symptom, verbatim.
    #expect(io.contains("Dip switch"), "I/O shows \(io)")
    #expect(!io.contains("DipSwitch"))
    #expect(io.contains("LED Bar"))
    #expect(!io.contains("LedBar"))
    #expect(io.contains("RGB LED"))
    #expect(io.contains("LED Matrix"))
    #expect(!io.contains("DotMatrix"))
    #expect(io.contains("Port I/O"))

    let wiring = try toolNames(outline, inLibraryNamed: "Wiring")
    #expect(wiring.contains("Do not connect"))
    #expect(!wiring.contains("NoConnect"))

    let arithmetic = try toolNames(outline, inLibraryNamed: "Arithmetic")
    #expect(arithmetic.contains("Bit Adder"))
    #expect(arithmetic.contains("Bit Finder"))
    #expect(!arithmetic.contains("BitAdder"))

    let fp = try toolNames(outline, inLibraryNamed: "Floating Point Arithmetic")
    #expect(fp.contains("Floating Point Adder"))
    #expect(fp.contains("Integer to Floating Point"))
    #expect(!fp.contains("FPAdder"))

    let bfh = try toolNames(outline, inLibraryNamed: "BFH mega functions")
    #expect(bfh.contains("Binary to BCD"))
    #expect(bfh.contains("BCD to seven segment"))
    #expect(!bfh.contains("Binary_to_BCD_converter"))

    let extra = try toolNames(outline, inLibraryNamed: "Input/Output Extra")
    #expect(extra.contains("PLA"))
    #expect(!extra.contains("PlaRom"))
    // Case-only, and it is the display name that is lowercase; the `_ID` is title case.
    #expect(extra.contains("Digital oscilloscope"))
    #expect(!extra.contains("Digital Oscilloscope"))
  }

  @Test("TTL rows carry the part description, which comes from the tool and not the factory")
  @MainActor
  func ttlRowsUseTheDescription() throws {
    let outline = try makeOutline()
    let ttl = try toolNames(outline, inLibraryNamed: "TTL")

    #expect(ttl.count == 61)
    // `Ttl7400`'s own display name is the bare "7400"; only the library's FactoryDescription
    // carries the sentence. If `DescribedAddTool` were dropped, every row here would collapse
    // to a part number and this library would read as a column of digits.
    #expect(ttl.contains("7400: quad 2-input NAND gate"))
    #expect(ttl.contains("74283: 4-bit binary full adder"))
    #expect(!ttl.contains("7400"))
    #expect(!ttl.contains("74283"))
  }

  @Test("the row's underlying tool is still addressable by its _ID")
  @MainActor
  func displayNamesDoNotLeakIntoIdentity() throws {
    // The whole risk of this change is renaming something the codec keys on. `ToolItem.name` is
    // display text; the model object behind it must still answer the `.circ` token, or a
    // `<comp name="DipSwitch">` stops resolving and a saved `<tool name="7400">` stops matching.
    let host = try #require(
      try LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
    let io = try #require(host.file.libraries.first { $0.name == Builtin.ioId })
    #expect(io.tools.contains { $0.name == "DipSwitch" })
    #expect(io.tool(named: "DipSwitch") != nil)

    let ttl = try #require(host.file.libraries.first { $0.name == Builtin.ttlId })
    #expect(ttl.tool(named: "7400") != nil)
    #expect(ttl.tool(named: "7400: quad 2-input NAND gate") == nil)
  }
}
