// HexCaret.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.hex.Caret, and the selection half of
// com.cburch.hex.Highlighter), https://github.com/logisim-evolution/logisim-evolution. Copyright
// by the Logisim-evolution developers. This translation is a derivative work and is therefore
// GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── What is ported and what is not ──────────────────────────────────────────────────────────
//
// `Caret` is two things welded together: a two-field cursor model (`mark`, `cursor`) with the
// clamping and selection rules in `setDot`, and an AWT `Listener` inner class that translates
// mouse/key events into calls on it. The first is real logic and is ported verbatim below,
// including `movecursor`'s eight branches; each of which has a *different* bounds condition, and
// three of which (`END`, `PAGE_DOWN`, `PAGE_UP`) are not the obvious ones.
//
// The second is a Swing-specific event plumbing whose Swift equivalent is a SwiftUI gesture and
// `onKeyPress`; it lives in `HexGridView.swift`. What survives the translation is
// `HexCaretMotion`, the enumeration of the eight motions `movecursor`'s switch accepts, so the
// view has one thing to call and this file keeps the arithmetic.
//
// `Highlighter` is not ported as a class. Its entire job is a list of coloured address ranges
// that only ever has one entry; `Caret.setDot` removes the previous highlight before adding the
// new one, and nothing else in `com.cburch.hex` or `gui.hex` ever calls `HexEditor.addHighlight`.
// So the "list" is the selection, and it is `selection` below: one range or none, derived rather
// than stored, which removes the class of bug where the highlight and the caret disagree.
// `HexEditor.addHighlight`/`removeHighlight` are public and would need the real list back if a
// caller ever appeared; there is none in 4.1.0 (verified by grep over the whole tree).

import Foundation

/// The eight `movecursor(int, boolean)` motions, which is every `KeyEvent` code `Caret.Listener`
/// passes it. Upstream's `default -> {}` arm, every other key, has no case here by construction.
public enum HexCaretMotion: Sendable, CaseIterable {
  case up
  case down
  case left
  case right
  case home
  case end
  case pageUp
  case pageDown
}

/// `com.cburch.hex.Caret`'s state: a mark and a cursor, both addresses, `-1` for "nowhere".
///
/// A struct because it is pure state with no identity; upstream's `Caret` is a class only
/// because it also owns the AWT listener and a `ChangeListener` list. The owning
/// `HexEditorModel` publishes the change instead.
public struct HexCaret: Equatable, Sendable {

  /// `Caret.mark`. Note upstream initialises it to Java's default `0`, not `-1`, while `cursor`
  /// is explicitly `-1`. So a freshly constructed caret reports `selectionExists() == false`
  /// (because the *cursor* is negative) but a mark of 0: and the first `setDot(x, keepMark:
  /// false)` overwrites it anyway. Preserved rather than "tidied" to `-1`, because `HexFrame`'s
  /// constructor calls `setDot(0, false)` immediately and the difference is observable in
  /// between.
  public private(set) var mark: Int64 = 0

  /// `Caret.cursor` / `getDot()`.
  public private(set) var dot: Int64 = -1

  public init() {}

  /// `HexEditor.selectionExists()`: `mark >= 0 && dot >= 0`. True for a one-cell "selection",
  /// which is what makes Cut and Copy enabled the moment the caret exists.
  public var selectionExists: Bool { mark >= 0 && dot >= 0 }

  /// The address range Cut/Copy/Delete operate on: `HexEditor.delete()`'s `p0`/`p1` after its
  /// swap, inclusive at both ends. `nil` when no selection exists.
  public var selection: ClosedRange<Int64>? {
    guard selectionExists else { return nil }
    return mark <= dot ? mark...dot : dot...mark
  }

  /// `Caret.setDot(long, boolean)`, minus the repaint and the `ChangeEvent` broadcast.
  ///
  /// Returns `true` when the cursor actually moved, which is the condition upstream guards its
  /// listener broadcast with; the caller uses it to decide whether to fire its own change.
  ///
  /// The clamp is upstream's exactly: a value outside `[firstOffset, lastOffset]` becomes `-1`
  /// (the caret leaves the grid) rather than saturating at an end. Passing `-1` deliberately is
  /// therefore the documented way to clear the caret, and `HexEditor.setModel` does exactly that.
  @discardableResult
  public mutating func setDot(_ value: Int64, keepMark: Bool, in bounds: ClosedRange<Int64>)
    -> Bool
  {
    var value = value
    if value < bounds.lowerBound || value > bounds.upperBound { value = -1 }
    guard dot != value else { return false }
    if !keepMark {
      mark = value
    }
    // The `else if (mark != value)` arm upstream is purely the highlight bookkeeping this port
    // derives instead (see the file header); with `keepMark` true the mark is simply left alone.
    dot = value
    return true
  }
}

/// `Caret.Listener.movecursor(int, boolean)`, where a motion lands, as a pure function.
///
/// Separated from `HexCaret` so it can be tested against a fabricated geometry without a model:
/// every branch's bounds condition is different, and three are surprising enough to be worth
/// pinning. Returns `nil` when upstream's guard for that motion fails, i.e. the caret does not
/// move at all (which is *not* the same as clamping to an end; `up` from row 0 stays put rather
/// than going to address 0).
public struct HexCaretGeometry: Sendable {
  /// `hex.getMeasures().getColumnCount()`.
  public var columns: Int
  /// `hex.getModel().getFirstOffset()`.
  public var firstOffset: Int64
  /// `hex.getModel().getLastOffset()`.
  public var lastOffset: Int64
  /// `hex.getVisibleRect().height / hex.getMeasures().getCellHeight()`, before upstream's
  /// `if (rows > 2) rows--` overlap adjustment, which `destination` applies itself.
  public var visibleRows: Int

  public init(columns: Int, firstOffset: Int64, lastOffset: Int64, visibleRows: Int) {
    self.columns = columns
    self.firstOffset = firstOffset
    self.lastOffset = lastOffset
    self.visibleRows = visibleRows
  }

  /// Where `cursor` goes for `motion`, or `nil` if upstream's guard rejects the move.
  public func destination(from cursor: Int64, motion: HexCaretMotion) -> Int64? {
    let cols = Int64(columns)
    switch motion {
    case .up:
      // `if (cursor >= cols)`. Note it is *not* `cursor - cols >= firstOffset`; for a model whose
      // first offset is nonzero the two differ, and `MemContents.getFirstOffset()` is always 0 so
      // upstream never notices.
      guard cursor >= cols else { return nil }
      return cursor - cols

    case .left:
      guard cursor >= 1 else { return nil }
      return cursor - 1

    case .down:
      guard cursor >= firstOffset, cursor <= lastOffset - cols else { return nil }
      return cursor + cols

    case .right:
      guard cursor >= firstOffset, cursor <= lastOffset - 1 else { return nil }
      return cursor + 1

    case .home:
      guard cursor >= 0 else { return nil }
      let dist = cursor % cols
      // Upstream's `if (dist == 0) setDot(0, shift)` jumps to address 0, the top of the
      // *memory*, not the start of the row, when the caret is already at a row start. That is
      // Home-then-Home meaning "go to the very beginning", and it is deliberate enough to
      // survive verbatim.
      return dist == 0 ? 0 : cursor - dist
    case .end:
      guard cursor >= 0 else { return nil }
      var dest = (cursor / cols) * cols + cols - 1
      // Symmetrically: End on a row whose last cell is already selected jumps to the last
      // address in the memory. `dest == cursor` is that test.
      if dest > lastOffset || dest == cursor { dest = lastOffset }
      return dest

    case .pageDown:
      guard cursor >= 0 else { return nil }
      var rows = Int64(visibleRows)
      if rows > 2 { rows -= 1 }
      if cursor + rows * cols <= lastOffset {
        return cursor + rows * cols
      }
      // The tail branch walks a row at a time rather than clamping, so the caret keeps its
      // column. `while (n + cols < max)`: a strict `<`, so it stops one row short of any row
      // containing `max` itself.
      var n = cursor
      while n + cols < lastOffset { n += cols }
      return n

    case .pageUp:
      var rows = Int64(visibleRows)
      if rows > 2 { rows -= 1 }
      if cursor >= rows * cols {
        return cursor - rows * cols
      } else if cursor >= cols {
        // Not "row 0, same column" by subtraction but `cursor % cols`, which is the same thing
        // only because `firstOffset` is 0.
        return cursor % cols
      }
      return nil
    }
  }
}
