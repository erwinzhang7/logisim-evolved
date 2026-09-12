// LogisimUITests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// IS THE DOCUMENT'S OWN TOOLBAR ACTUALLY SHOWN?
//
// `Options.toolbarData` was parsed by the codec, stored, round-tripped byte-exactly by the M2
// gate, and read by no view. The window rendered `ProjectOutline.editingTools`, which is
// `#Base`'s five canvas tools, so the app showed five buttons where the default template
// declares seventeen entries. It looked like a deliberate minimal design and was a dropped hop.
//
// These assert on the CONTENTS of `outline.toolbarItems`, in file order, against the template's
// actual `<toolbar>` block. A test that only checked "non-empty" would pass against a palette
// showing `#Base`'s five all over again.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd
import Testing

@testable import LogisimUI

@Suite("Component palette", .serialized)
struct ComponentPaletteTests {

  @MainActor
  private func makeHost() throws -> LogisimFileProjectHost {
    try #require(
      try LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
  }

  @Test("the palette is the document's toolbar, not the base library")
  @MainActor
  func paletteComesFromToolbarData() throws {
    let host = try makeHost()
    let entries = host.outline.toolbarItems

    // The default template's `<toolbar>`: 4 canvas tools, sep, 2 Pins, sep, 6 gates, sep,
    // D Flip-Flop, Register. Seventeen slots including the three separators.
    #expect(entries.count == host.file.options.toolbarData.toolbarContents.count)
    #expect(entries.count == 17)

    // And it is strictly bigger than what was being shown before.
    #expect(entries.compactMap(\.item).count > host.outline.editingTools.count)
  }

  @Test("the gates are there, in file order, with separators preserved")
  @MainActor
  func gatesArePresentInOrder() throws {
    let host = try makeHost()
    let names = host.outline.toolbarItems.compactMap(\.item).map(\.name)

    // The six gates the template puts on the toolbar. Asserted by name and in order, because the
    // symptom reported from the running app was specifically that the gates were missing.
    let gates = ["NOT Gate", "AND Gate", "OR Gate", "XOR Gate", "NAND Gate", "NOR Gate"]
    for gate in gates {
      #expect(names.contains(gate), "the palette has no \(gate); it has \(names)")
    }
    let indices = gates.compactMap { names.firstIndex(of: $0) }
    #expect(indices == indices.sorted(), "gates are out of file order: \(names)")

    // Separators survive as slots rather than being flattened away, three in the template.
    let separators = host.outline.toolbarItems.filter { if case .separator = $0 { return true }
      return false }
    #expect(separators.count == 3)
  }

  @Test("a palette entry is a CLONE of the library tool, and shares its source")
  @MainActor
  func paletteToolsAreClonesThatShareSource() throws {
    let host = try makeHost()

    // My first version of this asserted the palette's ids were a subset of the explorer's, and it
    // failed: only 4 of 14 overlapped. That expectation was wrong, not the code.
    // `XmlReader` calls `tool.cloneTool()` unconditionally for every `<toolbar>` entry, exactly as
    // Java does, because a toolbar entry carries its OWN attribute set, which is precisely how
    // the default template's two `Pin` entries differ (one is `facing=west, output=true`). Sharing
    // the library's object would make configuring a toolbar button edit the library.
    //
    // The real invariant is `AddTool.sharesSource`: a different object, same factory.
    let toolbar = host.file.options.toolbarData.toolbarContents.compactMap { $0 }
    let libraryTools = host.file.libraries.flatMap(\.tools)

    var checked = 0
    for entry in toolbar {
      guard entry is AddTool else { continue }  // `#Base`'s placeholders are not cloned per se
      let source = libraryTools.first { $0.sharesSource(entry) }
      #expect(source != nil, "palette entry \(entry.name) shares its source with no library tool")
      // A clone, not the same object: otherwise editing the button edits the library.
      if let source { #expect(source !== entry, "\(entry.name) is the library's own object") }
      checked += 1
    }
    // The 4 canvas tools are placeholders and the rest are AddTools: 2 pins + 6 gates + 2 memory.
    #expect(checked == 10, "expected 10 AddTool entries on the toolbar, saw \(checked)")
  }

  @Test("selecting a palette gate puts the canvas on that tool")
  @MainActor
  func selectingAPaletteGateChangesTheCanvasTool() throws {
    let host = try makeHost()
    _ = host.makeRenderSurface()
    let canvas = try #require(host.editorCanvas)

    let andGate = try #require(
      host.outline.toolbarItems.compactMap(\.item).first { $0.name == "AND Gate" })
    try host.perform(.selectTool(andGate.id))

    // The whole point of the palette: a click here has to reach the tool layer, not just move a
    // highlight. `CanvasAddTool` is what `upgrade` produces for an `AddTool`.
    #expect(canvas.controller.activeTool is CanvasAddTool)
    #expect(host.activeTool == andGate.id)
  }
}
