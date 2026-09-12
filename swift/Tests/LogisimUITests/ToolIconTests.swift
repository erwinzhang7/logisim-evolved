// LogisimUITests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// DOES EVERY TOOL THE PALETTE OFFERS HAVE AN ICON OF ITS OWN?
//
// Icons are pixels and nothing here looks at a pixel. What it does assert is the thing that was
// actually broken and the thing that would break again:
//
//   * the palette's fourteen tools each resolve to an icon chosen **for that tool**, never to
//     `ToolSymbols`' fallback, which is one glyph shared by a whole library (`memorychip` for
//     all of `#Memory`, `cpu` for all forty-odd `#TTL` chips) or, at the end, `square.on.circle`;
//   * distinct tools get distinct icons, which is the same defect stated as an observable;
//   * the gates in particular resolve to transcribed 4.1.0 geometry, not to a symbol;
//   * that geometry lands inside the 16×16 box upstream draws in, and a negated gate's path is
//     not the same path as its un-negated twin.
//
// **What is deliberately NOT asserted, and why.** Nothing here renders. A test that instantiated
// `ToolIconView` and checked it was non-nil would pass against a view that drew an empty `Path`,
// which is exactly the false green this project keeps catching, so the drawing itself is
// unasserted and was checked by eye. The bound below is on *path geometry*, which is the part
// that can be wrong silently: an arc swept the wrong way produces a mirrored gate and no error.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd
import SwiftUI
import Testing

@testable import LogisimUI

@Suite("Tool icons", .serialized)
struct ToolIconTests {

  @MainActor
  private func makeHost() throws -> LogisimFileProjectHost {
    try #require(
      try LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
  }

  // MARK: - The gate

  @Test("every tool on the palette resolves to an icon of its own, none to a library fallback")
  @MainActor
  func paletteHasNoPlaceholderIcons() throws {
    let host = try makeHost()
    let tools = host.outline.toolbarItems.compactMap(\.item)

    // The default template's `<toolbar>`: 4 canvas tools, 2 Pins, 6 gates, D Flip-Flop, Register.
    #expect(tools.count == 14)

    let placeholders = tools.filter { !ToolIcons.icon(for: $0).isToolSpecific }
    #expect(
      placeholders.isEmpty,
      """
      these palette tools fall through to ToolSymbols' library/global fallback, so they show a \
      glyph that says nothing about the tool: \
      \(placeholders.map { "\($0.name) → \($0.symbolName)" })
      """)
  }

  @Test("two different palette tools never show the same icon")
  @MainActor
  func paletteIconsAreDistinct() throws {
    let host = try makeHost()

    // Keyed by name, because the template's two `Pin` entries are the SAME tool name; they
    // differ only in their attribute sets (`facing=west`, `output=true`) and `ToolItem` carries
    // neither, so the palette genuinely cannot tell them apart today. That is a real gap and it
    // is reported; it is not what this test is about, so the duplicate name is collapsed here
    // rather than silently tolerated as two colliding icons.
    var iconsByName: [String: ToolIcon] = [:]
    for tool in host.outline.toolbarItems.compactMap(\.item) {
      iconsByName[tool.name] = ToolIcons.icon(for: tool)
    }

    var seen: [ToolIcon: String] = [:]
    for (name, icon) in iconsByName.sorted(by: { $0.key < $1.key }) {
      if let other = seen[icon] {
        Issue.record("\(name) and \(other) both draw \(icon) — the palette shows them identical")
      }
      seen[icon] = name
    }
    #expect(seen.count == iconsByName.count)
  }

  @Test("the six gates on the palette draw 4.1.0's geometry, not a symbol")
  @MainActor
  func paletteGatesUseUpstreamGeometry() throws {
    let host = try makeHost()
    let tools = host.outline.toolbarItems.compactMap(\.item)

    for gate in ["NOT Gate", "AND Gate", "OR Gate", "XOR Gate", "NAND Gate", "NOR Gate"] {
      let item = try #require(tools.first { $0.name == gate }, "the palette has no \(gate)")
      let icon = ToolIcons.icon(for: item)
      if case .upstream = icon { continue }
      Issue.record("\(gate) still draws an SF Symbol (\(icon))")
    }
  }

  // MARK: - The geometry

  @Test("every transcribed glyph stays inside upstream's 16×16 icon box")
  func glyphsFitTheIconBox() {
    // The Select arrow is the one exception and it is upstream's: `SelectIcon`'s tail reaches
    // y = 17 in a 16-unit box. Transcribed rather than corrected, so the bound allows for it.
    let slack: CGFloat = 1.5

    // Every glyph, not just the ones reachable through `upstreamGlyphs`; `.dipPackage` is
    // reached by the `74…` rule and `.pin(output: true)` by nothing yet, and a glyph that only
    // the future can reach is exactly the one nobody would notice was broken.
    var glyphs: [(String, ToolGlyph)] = ToolIcons.upstreamGlyphs.map { ($0.key, $0.value) }
    glyphs.append(("TTL DIP", .dipPackage))
    glyphs.append(("Pin (output)", .pin(output: true)))
    glyphs.append(("Controlled Buffer", .buffer(negated: false, controlled: true)))

    for (name, glyph) in glyphs.sorted(by: { $0.0 < $1.0 }) {
      let geometry = glyph.geometry
      let boxes = [geometry.stroked, geometry.filled]
        .filter { !$0.isEmpty }
        .map(\.boundingRect)
      #expect(!boxes.isEmpty, "\(name) draws nothing at all")

      for box in boxes {
        #expect(
          box.minX >= -slack && box.minY >= -slack,
          "\(name) draws above/left of the icon box: \(box)")
        #expect(
          box.maxX <= ToolGlyph.canonicalSize + slack
            && box.maxY <= ToolGlyph.canonicalSize + slack,
          "\(name) draws outside the icon box: \(box)")
      }
    }
  }

  @Test("the AND nose bulges right, which is what an arc swept the wrong way would break")
  func andGateNosePointsRight() {
    // `drawCenteredArc(g, 4, 6, 4, -90, 180)` is the RIGHT half of the circle centred at (4,6),
    // i.e. (6,8)–(10,8) once the 2pt border is added. Sweep it the other way and you get a
    // mirrored gate: a defect with no error message and no other symptom.
    //
    // **The whole path's bounding box cannot see this, and the first version of this test used
    // it and passed the mutation.** `appendPins` already puts the output stub at x = 12 and the
    // input stubs at x = 0, so the box is [0, 12] whichever way the nose is swept. So look at
    // the curve elements alone: those are the two Bézier quarters of the nose and nothing else.
    var curveExtent = CGRect.null
    ToolGlyph.and(negated: false).geometry.stroked.forEach { element in
      if case .curve(let to, let control1, let control2) = element {
        for point in [to, control1, control2] {
          curveExtent = curveExtent.union(CGRect(origin: point, size: .zero))
        }
      }
    }
    #expect(!curveExtent.isNull, "the AND has no curved nose at all")
    #expect(
      curveExtent.maxX >= 9.5,
      "the AND nose only reaches x = \(curveExtent.maxX); swept right it reaches 10")
    #expect(
      curveExtent.minX >= 5.5,
      "the AND nose starts at x = \(curveExtent.minX); it is swept to the left of its centre")
  }

  @Test("a negated gate is not the same drawing as its un-negated twin")
  func negationChangesTheGlyph() {
    // The bubble and the shifted output stub are the whole difference between AND and NAND. A
    // transcription that dropped the `negate` argument would still compile, still draw a real
    // gate, and make the two buttons identical.
    let pairs: [(String, ToolGlyph, ToolGlyph)] = [
      ("AND/NAND", .and(negated: false), .and(negated: true)),
      ("OR/NOR", .or(negated: false), .or(negated: true)),
      ("XOR/XNOR", .xor(negated: false), .xor(negated: true)),
      (
        "Buffer/NOT", .buffer(negated: false, controlled: false),
        .buffer(negated: true, controlled: false)
      ),
    ]
    for (label, plain, negated) in pairs {
      let a = plain.geometry.stroked.boundingRect
      let b = negated.geometry.stroked.boundingRect
      #expect(a != b, "\(label): the negation bubble is missing — both draw \(a)")
      #expect(b.maxX > a.maxX, "\(label): the negated form should extend further right")
    }
  }

  // MARK: - The drawing, not just the data

  @Test("the glyph view actually puts ink on the canvas, at 16pt and at 64pt")
  @MainActor
  func glyphViewRendersInk() throws {
    // Everything above asserts `Path` geometry. None of it runs `ToolGlyphView.body`, so a
    // `Canvas` that stroked with a zero line width, or scaled the transform to nothing, would
    // pass every one of them and draw an empty square. This renders the view and counts
    // non-transparent pixels; the cheapest assertion that reaches the drawing code at all.
    for size in [CGFloat(16), CGFloat(64)] {
      let renderer = ImageRenderer(
        content: ToolGlyphView(glyph: .and(negated: true), size: size)
          .foregroundStyle(.black))
      renderer.scale = 2
      let image = try #require(renderer.cgImage, "the AND glyph rendered no image at \(size)pt")

      var opaque = 0
      let width = image.width
      let height = image.height
      var pixels = [UInt8](repeating: 0, count: width * height * 4)
      let space = CGColorSpaceCreateDeviceRGB()
      let context = try #require(
        CGContext(
          data: &pixels, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: space,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      for i in stride(from: 3, to: pixels.count, by: 4) where pixels[i] > 8 { opaque += 1 }

      // A NAND at 16pt is a thin outline in a 16×16 box at 2×; a few hundred pixels. The bound
      // is deliberately loose at the bottom and open at the top: the claim is "it drew a shape",
      // not "it drew this many pixels".
      #expect(opaque > 40, "the AND glyph drew only \(opaque) pixels at \(size)pt")
      #expect(opaque < width * height, "the AND glyph filled the whole box at \(size)pt")
    }
  }

  // MARK: - Tool order

  @Test("the pointer is moved in front of Poke, and nothing else moves")
  @MainActor
  func selectIsHoistedAheadOfPoke() throws {
    let host = try makeHost()
    let before = host.outline.toolbarItems
    let after = PaletteLayout.presentationOrder(before)

    func index(of name: String, in entries: [ToolbarEntry]) -> Int? {
      entries.firstIndex { if case .tool(let t) = $0 { return t.name == name }
        return false }
    }

    // The template's order is Poke, Edit, Wiring, Text: Poke first, which is what was reported
    // as confusing. `ToolSymbols.editingDisplayName` renders "Edit Tool" as "Select".
    #expect(index(of: "Poke", in: before)! < index(of: "Select", in: before)!)
    #expect(index(of: "Select", in: after)! < index(of: "Poke", in: after)!)

    // A move, not a rewrite: same multiset of entries, same count, and only the two swapped
    // slots differ from file order.
    #expect(after.count == before.count)
    let idsBefore: [UInt64] = before.compactMap(\.item).map { $0.id.rawValue }.sorted()
    let idsAfter: [UInt64] = after.compactMap(\.item).map { $0.id.rawValue }.sorted()
    #expect(idsAfter == idsBefore)
    let movedSlots = zip(before, after).filter { $0 != $1 }.count
    #expect(movedSlots == 2, "\(movedSlots) slots changed; only Poke and Select should move")
  }

  @Test("the pointer is not dragged across a separator into another toolbar section")
  func reorderDeclinesAcrossASeparator() {
    func tool(_ n: UInt64, _ name: String) -> ToolbarEntry {
      .tool(ToolItem(id: ToolID(rawValue: n), name: name, symbolName: "circle"))
    }
    // A user who has put the pointer in a different section of their own toolbar gets it left
    // where they put it; moving it would be rewriting their layout, not nudging it.
    let entries: [ToolbarEntry] = [
      tool(1, "Poke"), tool(2, "Wire"), .separator(0), tool(3, "Select"),
    ]
    #expect(PaletteLayout.presentationOrder(entries) == entries)

    // And with no separator between them it does move.
    let adjacent: [ToolbarEntry] = [tool(1, "Poke"), tool(2, "Wire"), tool(3, "Select")]
    let reordered = PaletteLayout.presentationOrder(adjacent)
    #expect(reordered.compactMap(\.item).map(\.name) == ["Select", "Poke", "Wire"])
  }

  @Test("a toolbar with no pointer, or with the pointer already first, is left alone")
  func reorderIsANoOpWhenThereIsNothingToDo() {
    func tool(_ n: UInt64, _ name: String) -> ToolbarEntry {
      .tool(ToolItem(id: ToolID(rawValue: n), name: name, symbolName: "circle"))
    }
    let noPointer: [ToolbarEntry] = [tool(1, "Poke"), tool(2, "Wire")]
    #expect(PaletteLayout.presentationOrder(noPointer) == noPointer)

    let alreadyFirst: [ToolbarEntry] = [tool(1, "Select"), tool(2, "Poke")]
    #expect(PaletteLayout.presentationOrder(alreadyFirst) == alreadyFirst)

    #expect(PaletteLayout.presentationOrder([]) == [])
  }

  // MARK: - The part that is NOT fixed, measured rather than asserted away

  @Test("the explorer's placeholder count is recorded, so it can only go down")
  @MainActor
  func explorerFallbackCountIsARatchet() throws {
    let host = try makeHost()
    let all = host.outline.libraries.flatMap(\.tools)
    let fallbacks = all.filter { !ToolIcons.icon(for: $0).isToolSpecific }

    // This is the honest number: the catalog covers the palette and the gate family, and the
    // long tail of `#TTL`, `#Plexers`, `#Arithmetic`, `#I/O` and the rest still shares one glyph
    // per library. Pinned as a ceiling rather than asserted to zero, because claiming zero here
    // would be a lie and asserting nothing would let the next symbol table regress it.
    let ceiling = ToolIconTests.explorerFallbackCeiling
    #expect(
      fallbacks.count <= ceiling,
      """
      \(fallbacks.count) of \(all.count) explorer tools draw a library-wide placeholder; \
      the recorded ceiling is \(ceiling)
      """)
    #expect(!all.isEmpty)
  }

  /// **Measured on this branch: 71 of 165.** It was 132 of 165 before the `#TTL` rule and 165 of
  /// 165 before the catalog existed. What is left is `#Plexers`, `#Arithmetic`, `#FPArithmetic`,
  /// `#I/O`, `#Input/Output-Extra`, `#Soc`, `#BFH-Praktika` and `#TCL`; each of which shares one
  /// library glyph across all its tools. 4.1.0 draws those from `PlexerIcon`, `ArithmeticIcon`,
  /// `LedIcon`, `SevenSegmentIcon` and friends, all `.class` files like the gates, so closing the
  /// gap is more transcription of the same kind and not a different technique.
  ///
  /// Lower it whenever the catalog grows; never raise it.
  static let explorerFallbackCeiling = 71
}
