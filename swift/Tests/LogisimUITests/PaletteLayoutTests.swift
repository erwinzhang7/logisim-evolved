// LogisimUITests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE PALETTE'S OVERFLOW SPLIT.
//
// Layout arithmetic is normally verified by looking at it, and looking at it is exactly the
// technique this port does not have for the UI. So the split is a pure function and this is the
// gate on it.
//
// The property that matters most is the boring one: `visible + overflow` must always be the whole
// list. A greedy fit that drops the item straddling the boundary loses a tool with no error, no
// log line and no visual cue; the palette simply would not have the gate you wanted, which is
// the same symptom that started this whole thread.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import CoreGraphics
import Foundation
import Testing

@testable import LogisimUI

@Suite("Palette layout")
struct PaletteLayoutTests {

  private func tool(_ n: Int) -> ToolbarEntry {
    .tool(ToolItem(id: ToolID(rawValue: UInt64(n)), name: "T\(n)", symbolName: "circle"))
  }

  /// The default template's shape: 4 tools, sep, 2, sep, 6, sep, 2.
  private var templateShape: [ToolbarEntry] {
    var out: [ToolbarEntry] = []
    var n = 0
    func add(_ count: Int) { for _ in 0..<count { n += 1; out.append(tool(n)) } }
    add(4); out.append(.separator(out.count))
    add(2); out.append(.separator(out.count))
    add(6); out.append(.separator(out.count))
    add(2)
    return out
  }

  @Test("nothing is ever dropped, at any width")
  func splitIsTotal() {
    let entries = templateShape
    // Sweep every width from "nothing fits" to "everything fits twice over", in 1pt steps. The
    // straddling item is a different one at each width, so this covers the boundary case for all
    // 17 slots rather than for whichever one a hand-picked width happens to hit.
    for w in stride(from: CGFloat(0), through: 900, by: 1) {
      let split = PaletteLayout.split(entries, availableWidth: w)
      let recombined = split.visible + split.overflow
      #expect(
        recombined.map(\.id) == entries.map(\.id),
        "width \(w): lost or reordered entries")
    }
  }

  @Test("everything fits when there is room, and the menu does not appear")
  func noOverflowWhenWide() {
    let entries = templateShape
    let needed = entries.reduce(CGFloat.zero) { $0 + PaletteLayout.width(of: $1) }
      + PaletteLayout.rowInsets
    let split = PaletteLayout.split(entries, availableWidth: needed)

    #expect(split.visible.count == entries.count)
    #expect(!split.hasOverflow)

    // One point narrower and it must overflow; the boundary is exact, not approximate.
    #expect(PaletteLayout.split(entries, availableWidth: needed - 1).hasOverflow)
  }

  @Test("the visible strip never ends on a separator")
  func noTrailingSeparator() {
    let entries = templateShape
    for w in stride(from: CGFloat(0), through: 900, by: 1) {
      let split = PaletteLayout.split(entries, availableWidth: w)
      if case .separator = split.visible.last {
        Issue.record("width \(w): visible strip ends on a divider")
      }
    }
  }

  @Test("the overflow button's own width is reserved, so the last button is not clipped")
  func overflowButtonIsBudgeted() {
    let entries = templateShape
    for w in stride(from: CGFloat(0), through: 900, by: 1) {
      let split = PaletteLayout.split(entries, availableWidth: w)
      guard split.hasOverflow else { continue }

      // Below `minimumWidth` the insets and the menu button alone exceed the width, so there is
      // nothing to fit and everything overflows. Asserted rather than skipped; a
      // `GeometryReader` really does report 0 on the first pass and mid-resize, and "the strip
      // collapses to just the ⋯" is the intended behaviour there, not an unhandled case.
      guard w >= PaletteLayout.minimumWidth else {
        #expect(split.visible.isEmpty, "width \(w) is below the floor but kept \(split.visible.count)")
        continue
      }

      let used = split.visible.reduce(CGFloat.zero) { $0 + PaletteLayout.width(of: $1) }
        + PaletteLayout.rowInsets + PaletteLayout.overflowWidth
      // Forgetting to reserve it is the classic version of this bug: everything fits by the
      // arithmetic and the menu button pushes the last gate off the edge.
      #expect(used <= w, "width \(w): visible content plus the ⋯ button is \(used)")
    }
  }

  @Test("a narrow window keeps the leftmost tools, in file order")
  func narrowKeepsTheHead() {
    let entries = templateShape
    let split = PaletteLayout.split(entries, availableWidth: 150)

    // File order is the user's own toolbar order; packing or reordering to fit better would move
    // buttons around under the cursor as the window resizes.
    #expect(split.visible.map(\.id) == entries.prefix(split.visible.count).map(\.id))
    #expect(split.hasOverflow)
  }

  @Test("an empty toolbar produces nothing rather than an empty menu")
  func emptyIsEmpty() {
    let split = PaletteLayout.split([], availableWidth: 800)
    #expect(split.visible.isEmpty)
    #expect(!split.hasOverflow)
  }
}
