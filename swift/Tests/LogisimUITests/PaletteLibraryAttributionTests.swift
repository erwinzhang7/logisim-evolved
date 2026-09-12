// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution, which is GPL-3.0-only. This port is a derivative work and is
// therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// A palette tool must be attributed to the library it came from.
//
// ── Why this file exists: a fix whose probe reddened nothing ─────────────────────────────────
//
// `ProjectOutlineBuilder` resolved a palette tool's owning library with
//
//     file.libraries.first { $0.tools.contains { $0 === tool } }
//
// and reference identity can NEVER match there. `XmlReader` calls `cloneTool()` on every
// `<toolbar>` entry: unconditionally, exactly as Java does, because a toolbar entry carries its
// own attribute set, which is how the default template's two `Pin` entries differ (one is
// `facing=west, output=true`). `ComponentPaletteTests.paletteToolsAreClonesThatShareSource`
// already pins that. So `owner` was **always nil** for every palette tool, which fed
// `inLibrary: ""` into the symbol table and skipped its per-library row.
//
// Changing `===` to `sharesSource` reddened **nothing**, and a probe that reddens nothing is not
// a passing probe. The reason turned out to be that the icon work landed a name-keyed glyph
// resolver in the same wave, so the palette now gets its picture without consulting `owner` at
// all; the symptom was covered while the wrong attribution stayed. That is precisely the shape
// worth pinning: a defect whose visible consequence has been masked by an unrelated improvement
// is a defect nothing will notice when it starts mattering again.
//
// So this asserts the attribution itself rather than the icon: a palette tool must resolve the
// same library symbol as the identical tool sitting in the explorer, because they are the same
// tool. It reddens against `===` and passes against `sharesSource`.

import Foundation
import LogisimFile
import Testing
import UniformTypeIdentifiers

@testable import LogisimUI

@Suite("Palette tools are attributed to their own library")
@MainActor
struct PaletteLibraryAttributionTests {

  /// `toolbarItems` is the document's `<toolbar>`, the palette, and carries separators too, so
  /// the tools have to be unwrapped out of it.
  private func paletteTools(_ outline: ProjectOutline) -> [ToolItem] {
    outline.toolbarItems.compactMap { entry in
      if case .tool(let item) = entry { return item }
      return nil
    }
  }

  private func makeOutline() throws -> ProjectOutline {
    let host = try LogisimFileProjectHostFactory().makeEmptyProject()
    return host.outline
  }

  /// The calibration, and it is not optional: this whole file is a comparison between the palette
  /// and the explorer, so the fixture has to actually contain both, with at least one tool in
  /// common. Without this the comparison below could be over an empty set and pass vacuously.
  @Test("the default document really does offer palette tools and explorer tools")
  func theFixtureHasBothSurfaces() throws {
    let outline = try makeOutline()
    #expect(!paletteTools(outline).isEmpty, "no palette tools; every assertion here is vacuous")
    #expect(!outline.libraries.isEmpty, "no libraries; nothing to attribute a tool to")
  }

  /// **The defect.** `"square.on.circle"` is `ToolSymbols.symbol`'s last-resort fallback
  /// (`ProjectOutlineBuilder.swift:393`); the value it returns when neither the tool id nor the
  /// library id is known. A palette tool landing on it means its library was not resolved.
  ///
  /// This is asserted as "no MORE palette tools fall back than explorer tools do" rather than
  /// "none do", because a genuinely unknown tool legitimately falls back on both surfaces. What
  /// must not happen is the palette being *worse* than the explorer at naming the same tools.
  @Test("a palette tool resolves its library as well as the explorer does")
  func paletteToolsAreNotWorseAttributedThanExplorerTools() throws {
    let outline = try makeOutline()
    let fallback = "square.on.circle"

    let paletteNames = Set(paletteTools(outline).map(\.name))
    let explorerFallbacks = outline.libraries
      .flatMap(\.tools)
      .filter { paletteNames.contains($0.name) && $0.symbolName == fallback }
      .map(\.name)
    let paletteFallbacks = paletteTools(outline)
      .filter { $0.symbolName == fallback }
      .map(\.name)

    #expect(
      Set(paletteFallbacks).isSubset(of: Set(explorerFallbacks)),
      """
      these tools resolve a library symbol in the explorer but fall back to the generic glyph in \
      the palette, so the palette failed to attribute them to a library: \
      \(Set(paletteFallbacks).subtracting(Set(explorerFallbacks)).sorted())
      """)
  }
}
