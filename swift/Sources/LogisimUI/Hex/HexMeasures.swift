// HexMeasures.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.hex.Measures),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Why this is a value type and upstream's is not ──────────────────────────────────────────
//
// `Measures` holds a back-reference to the `HexEditor` it lays out and mutates it in place:
// `computeCellSize` calls `hex.setPreferredSize`/`hex.revalidate`, `widthChanged` calls
// `hex.repaint`, and `recompute()` reaches back for `hex.getGraphics()` to obtain a
// `FontMetrics`. That circularity is what makes the class untestable in Java; you cannot ask it
// where address 0x2a lands without first realising a Swing component on a display.
//
// Every *number* it computes is a pure function of five inputs: the model's last offset, the
// model's value width, three font measurements, and the view's pixel width. So this is a struct
// built from exactly those five, and the arithmetic below, `toX`, `toY`, `toAddress`,
// `baseAddress`, the column-count ladder, is transcribed operation for operation, including
// upstream's integer division and its two *different* spacer fudge factors (`(spacerWidth + 2)/4`
// in `toAddress` versus `(spacerWidth + 3)/4` in `widthChanged`; they are not a typo this port is
// entitled to normalise, and rounding them the same way moves the hit-test by a pixel at some
// font sizes).
//
// Integer pixels, not `CGFloat`, for the same reason: upstream's `int` division truncates, and
// `toAddress` is a hit test whose result changes if the intermediate is a double. The view layer
// measures the font once, rounds, and hands the three integers in.

import Foundation

/// The three font measurements `Measures.computeCellSize` takes from a `FontMetrics`.
///
/// Upstream's fallback branch (`fm == null`) uses 8/6/16; the numbers a `Measures` reports
/// before the component has ever been painted, which `Measures.guessed` then records so the real
/// metrics can replace them. `.guessed` below is that branch, kept because a `HexMeasures` built
/// before any layout pass has to answer `columnCount` with *something*, and upstream's answer is
/// 16 columns at those sizes.
public struct HexFontMetrics: Equatable, Sendable {
  /// `charWidth`: the widest of the sixteen hex digits, not the font's average advance.
  public var charWidth: Int
  /// `spaceWidth`, `fm.stringWidth(" ")`.
  public var spaceWidth: Int
  /// `lineHeight`, `fm.getHeight()`.
  public var lineHeight: Int
  /// `Measures.guessed`: no `Graphics` has been seen yet, so the numbers above are the
  /// hard-coded fallbacks and the column count is pinned at 16 regardless of the view's width.
  public var guessed: Bool

  public init(charWidth: Int, spaceWidth: Int, lineHeight: Int, guessed: Bool = false) {
    self.charWidth = charWidth
    self.spaceWidth = spaceWidth
    self.lineHeight = lineHeight
    self.guessed = guessed
  }

  /// The `fm == null` arm of `computeCellSize`: `charWidth = 8`, `spaceWidth = 6`,
  /// `lineHeight = font.getSize()` (16 when the font is also null).
  public static let guessedDefault = HexFontMetrics(
    charWidth: 8, spaceWidth: 6, lineHeight: 16, guessed: true)
}

/// `com.cburch.hex.Measures`: the address ↔ pixel map for one hex-editor grid.
public struct HexMeasures: Equatable, Sendable {

  /// `headerChars`: hex digits in an address label.
  public let labelChars: Int
  /// `cellChars`: hex digits in one memory word.
  public let cellChars: Int
  /// `headerWidth`.
  public let labelWidth: Int
  /// `spacerWidth`.
  public let spacerWidth: Int
  /// `cellWidth`.
  public let cellWidth: Int
  /// `cellHeight`.
  public let cellHeight: Int
  /// `cols`.
  public let columnCount: Int
  /// `baseX`.
  public let baseX: Int

  /// `model.getFirstOffset()` / `getLastOffset()`, carried so `toAddress` can clamp.
  public let firstOffset: Int64
  public let lastOffset: Int64

  /// The preferred size `computeCellSize` writes back into the component, clamped to
  /// `Integer.MAX_VALUE` in height exactly as upstream clamps it.
  public let preferredWidth: Int
  public let preferredHeight: Int

  /// `new Measures(hex)` followed by `computeCellSize(g)` and `widthChanged()`, for a model whose
  /// address range is `firstOffset...lastOffset` and whose words are `valueWidth` bits wide.
  ///
  /// `viewWidth` is `hex.getWidth()`. Pass `0` for "not laid out yet"; the guessed-metrics arm
  /// then pins 16 columns, which is what upstream's `guessed || cellWidth < 0` branch does.
  public init(
    firstOffset: Int64,
    lastOffset: Int64,
    valueWidth: Int,
    metrics: HexFontMetrics,
    viewWidth: Int
  ) {
    self.firstOffset = firstOffset
    self.lastOffset = lastOffset

    // `computeCellSize`, character-count half. Upstream's loop is `while (addrEnd > (1L <<
    // logSize)) logSize++`, a strict `>`: so a last offset of exactly `2^n` yields `logSize = n`,
    // not `n + 1`. Preserved: the off-by-one it looks like is what sizes a 256-word memory's
    // labels at two digits rather than three.
    var logSize = 0
    while lastOffset > (Int64(1) << Int64(logSize)) { logSize += 1 }
    let labelChars = (logSize + 3) / 4
    let cellChars = (valueWidth + 3) / 4
    self.labelChars = labelChars
    self.cellChars = cellChars

    self.labelWidth = labelChars * metrics.charWidth + metrics.spaceWidth
    self.spacerWidth = metrics.spaceWidth
    let cellWidth = cellChars * metrics.charWidth + metrics.spaceWidth
    self.cellWidth = cellWidth
    self.cellHeight = metrics.lineHeight

    // `widthChanged()`. Note the fudge factor is `(spacerWidth + 3) / 4` here and
    // `(spacerWidth + 2) / 4` in `toAddress`. Both are transcribed as written.
    let cols: Int
    let layoutWidth: Int
    if metrics.guessed || cellWidth < 0 {
      cols = 16
      // Upstream reads back `hex.getPreferredSize().width`, which at this point is the width
      // computed from the *previous* column count: 1 on the very first pass, since the
      // constructor initialises `cols = 1`. Reproducing that transient is pointless: it exists
      // only because Java's `Measures` is a mutable object mid-construction. The stable value it
      // converges to for 16 columns is what is used here.
      layoutWidth = labelChars * metrics.charWidth + metrics.spaceWidth
        + 16 * cellWidth + (16 / 4) * metrics.spaceWidth
    } else {
      layoutWidth = viewWidth
      let ret = (viewWidth - labelWidth) / (cellWidth + (metrics.spaceWidth + 3) / 4)
      cols = ret >= 16 ? 16 : (ret >= 8 ? 8 : 4)
    }
    self.columnCount = cols

    let lineWidth = labelWidth + cols * cellWidth + ((cols / 4) - 1) * metrics.spaceWidth
    self.baseX = labelWidth + max(0, (layoutWidth - lineWidth) / 2)

    // `computeCellSize`, preferred-size half; computed after `cols` is known, which is the
    // net effect of upstream's `computeCellSize → widthChanged → recompute → computeCellSize`
    // convergence loop.
    self.preferredWidth = labelWidth + cols * cellWidth + (cols / 4) * metrics.spaceWidth
    let addr0 = firstOffset - (firstOffset % Int64(cols))
    let rows = ((lastOffset - addr0 + 1) + Int64(cols) - 1) / Int64(cols)
    let height = rows * Int64(metrics.lineHeight)
    self.preferredHeight = height > Int64(Int32.max) ? Int(Int32.max) : Int(height)
  }

  /// `getBaseAddress(HexModel)`; the first address of the row address 0 sits in.
  public var baseAddress: Int64 {
    firstOffset - (firstOffset % Int64(columnCount))
  }

  /// `getValuesX()`.
  public var valuesX: Int { baseX + spacerWidth }

  /// `getValuesWidth()`.
  public var valuesWidth: Int { ((columnCount - 1) / 4) * spacerWidth + columnCount * cellWidth }

  /// The number of grid rows: `(lastOffset - baseAddress + 1 + cols - 1) / cols`, the same
  /// division `computeCellSize` uses for the preferred height.
  public var rowCount: Int {
    let rows = ((lastOffset - baseAddress + 1) + Int64(columnCount) - 1) / Int64(columnCount)
    return rows > Int64(Int.max) ? Int.max : Int(rows)
  }

  /// `toX(long)`.
  public func x(of address: Int64) -> Int {
    let col = Int(address % Int64(columnCount))
    return baseX + (1 + (col / 4)) * spacerWidth + col * cellWidth
  }

  /// `toY(long)`.
  public func y(of address: Int64) -> Int {
    let row = (address - baseAddress) / Int64(columnCount)
    let ret = row * Int64(cellHeight)
    return ret < Int64(Int32.max) ? Int(ret) : Int(Int32.max)
  }

  /// `toAddress(int, int)`.
  ///
  /// Upstream returns `Integer.MIN_VALUE` when the model is null; there is no null model here,
  /// a `HexMeasures` is only ever built from one, so that arm has no counterpart.
  public func address(atX x: Int, y: Int) -> Int64 {
    // Guard `cellHeight == 0`: upstream cannot reach it (a `FontMetrics` height is never zero and
    // the guessed fallback is 16), but a caller here could hand in a zero metric and Java's
    // `y / cellHeight` would throw ArithmeticException where Swift traps. D13: a division trap is
    // not an acceptable outcome for a hit test, so clamp to row 0.
    let row = cellHeight > 0 ? Int64(y / cellHeight) : 0
    let base = baseAddress + row * Int64(columnCount)
    var offs = (x - baseX) / (cellWidth + (spacerWidth + 2) / 4)
    if offs < 0 { offs = 0 }
    if offs >= columnCount { offs = columnCount - 1 }

    var ret = base + Int64(offs)
    if ret > lastOffset { ret = lastOffset }
    if ret < firstOffset { ret = firstOffset }
    return ret
  }
}
