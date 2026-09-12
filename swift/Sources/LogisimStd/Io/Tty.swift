// Tty.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.io.{Tty, TtyState}),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// `TtyState` is package-private in Java and used by nothing outside `Tty.java`. It is nested here
// as `Tty.State` rather than a top-level type, for the same reason `DotMatrixBase.State` is
// nested in `DotMatrix.swift`: one file per Java class is the norm, but this slice owns exactly
// eight named files, and `State`/`TtyState` would collide at module scope with `DotMatrixBase`'s
// and `RgbVideo`'s own nested `State` types if hoisted out.
//
// ── Not ported ──────────────────────────────────────────────────────────────────────────────
//
//   * `setIcon`; UI (D9). `paintInstance`/`paintGhost` ARE ported; see the Paint section below.
//     Text is measured through `SceneBuilder`, whose `TextMeasurer` is a protocol with no UI
//     dependency, so the description-string branch and the cursor bar are both exact.
//   * `DynamicElementProvider`/`createDynamicElement` (`TtyShape`): appearance editor, M7.
//   * `getOffsetBounds`'s live `FontMetrics` measurement of `DEFAULT_FONT`'s `'W'` glyph; see
//     `columnWidth` below for the deterministic stand-in and why it cannot be exact here.
//
// ── The `TtyInterface.sendFromTty` seam ─────────────────────────────────────────────────────
//
// Upstream's `Tty.sendToStdout(InstanceState)` flips a per-`CircuitState` flag that makes
// `TtyState.add(char)` call the static `com.cburch.logisim.gui.start.TtyInterface.sendFromTty`,
// which is how `-tty` CLI sessions actually see terminal output. `TtyInterface` lives in
// `gui.start` (a CLI/driver concern, out of `LogisimStd`'s reach by D9), so this port exposes the
// same seam as a static hook `Tty.sendFromTtyHook` that `logisim-cli` is expected to install.
// `nil` by default, so a headless kernel/component test never touches process I/O.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// D13: the one Java exception `Tty`'s propagation path can throw; see `Tty.State.commit()`.
public enum TtyError: Error, CustomStringConvertible, Equatable {
  case zeroRowScrollback
  public var description: String {
    "TTY: cannot commit a row with ATTR_ROWS == 1 (zero-row scrollback buffer)"
  }
}

/// `com.cburch.logisim.std.io.Tty`.
public final class Tty: InstanceFactoryBase {

  /// `Tty._ID`.
  public static let id = "TTY"

  private static let clr = 0
  private static let ck = 1
  private static let we = 2
  private static let inPort = 3

  /// `Tty.BORDER`.
  public static let border = 6
  /// `Tty.ROW_HEIGHT`.
  public static let rowHeight = 15
  /// `Tty.COL_WIDTH`; upstream declares this but paints with a live `FontMetrics` measurement
  /// instead (see `columnWidth` below, and the file header).
  public static let colWidth = 7

  /// The seam described in the file header. `Character` rather than `Char`/`UInt8`: the port
  /// value can be any 7-bit code, and upstream passes a Java `char` through unchanged.
  nonisolated(unsafe) public static var sendFromTtyHook: ((Character) -> Void)?

  /// `Tty.getColumnCount(Object)` / `getRowCount(Object)`. Upstream's `instanceof Integer` guard
  /// exists because the attribute defaults array is untyped (`Object[]`); this port's attribute
  /// is already `Attribute<Int32>`, so the guard can never fail and is collapsed to the value
  /// itself with the same fallback upstream uses if it somehow were absent.
  private static func columnCount(_ value: Int32?) -> Int { Int(value ?? 16) }
  private static func rowCount(_ value: Int32?) -> Int { Int(value ?? 4) }

  private static let defaultBackground = ColorSpec(red: 0, green: 0, blue: 0, alpha: 64)

  /// `Tty.ATTR_COLUMNS`.
  public static let attrColumns: Attribute<Int32> = Attributes.forIntegerRange(
    "cols", start: 1, end: 120)
  /// `Tty.ATTR_ROWS`.
  public static let attrRows: Attribute<Int32> = Attributes.forIntegerRange(
    "rows", start: 1, end: 48)

  /// `Tty()`.
  public init() {
    super.init(Tty.id)
    setAttributes([
      Tty.attrRows.binding(8),
      Tty.attrColumns.binding(32),
      StdAttr.edgeTrigger.binding(StdAttr.triggerRising),
      IoLibrary.color.binding(ColorSpec(red: 0, green: 0, blue: 0)),
      IoLibrary.background.binding(Tty.defaultBackground),
    ])
    setPorts([
      Port(20, 10, .input, 1),  // CLR
      Port(0, 0, .input, 1),  // CK
      Port(10, 10, .input, 1),  // WE
      Port(0, -10, .input, 7),  // IN
    ])
  }

  // MARK: Bounds — `getOffsetBounds(AttributeSet)`
  //
  // Java measures `DEFAULT_FONT` (`"monospaced"`, PLAIN, 11pt)'s `'W'` glyph width live via
  // `Graphics.getFontMetrics()` on a throwaway 1×1 image, and the component's whole width is
  // `cols` times that. D9 keeps CoreText out of `LogisimStd`, so this cannot call CoreText,
  // but it does not have to: `TextMeasurer` is a protocol in `LogisimRender` with no UI
  // dependency of its own, and the same object the scene builder measures with answers this
  // question too.

  /// The measurer `columnWidth` consults, installed once by whatever stands up the renderer.
  ///
  /// A settable static rather than a parameter because `offsetBounds(_:)` is the chassis's
  /// signature and takes an attribute set and nothing else; the same reason `sendFromTtyHook`
  /// above is one. Left `nil` in a headless run, where the fallback below applies and the
  /// differential harness stays runnable.
  public nonisolated(unsafe) static var textMeasurer: (any TextMeasurer)?

  /// `tempGraphics.getFontMetrics().charWidth('W')`.
  ///
  /// Falls back to `Tty.COL_WIDTH` (upstream's own declared-but-unused constant, 7) when no
  /// measurer has been installed. That fallback is a genuine fidelity gap in a headless run,
  /// the box is real and non-degenerate but need not be pixel-identical, and is exact once the
  /// UI has installed a measurer, since monospaced advance is the same for every glyph.
  public static var columnWidth: Int {
    guard let measurer = textMeasurer else { return colWidth }
    return measurer.width(of: "W", font: defaultFont)
  }

  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let rows = Tty.rowCount(attributes[Tty.attrRows])
    let cols = Tty.columnCount(attributes[Tty.attrColumns])

    var width = 2 * Tty.border + cols * Tty.columnWidth
    if width < 30 { width = 30 }
    var height = 2 * Tty.border + rows * Tty.rowHeight
    if height < 30 { height = 30 }
    return Bounds.create(0, 10 - height, width, height)
  }

  // MARK: State — `TtyState`

  /// `com.cburch.logisim.std.io.TtyState`, nested, see the file header.
  public final class State: InstanceData {
    private var lastClock: Value = .unknownValue
    private var rowData: [String]
    private var colCount: Int
    private var lastRow: String = ""
    private var row: Int = 0
    private var sendStdout = false

    public init(rows: Int, cols: Int) {
      rowData = [String](repeating: "", count: max(rows - 1, 0))
      colCount = cols
      clear()
    }

    private init(
      lastClock: Value, rowData: [String], colCount: Int, lastRow: String, row: Int,
      sendStdout: Bool
    ) {
      self.lastClock = lastClock
      self.rowData = rowData
      self.colCount = colCount
      self.lastRow = lastRow
      self.row = row
      self.sendStdout = sendStdout
    }

    public func cloneData() -> any InstanceData {
      State(
        lastClock: lastClock, rowData: rowData, colCount: colCount, lastRow: lastRow, row: row,
        sendStdout: sendStdout)
    }

    /// `TtyState.add(char)`.
    public func add(_ c: Character) throws {
      if sendStdout {
        Tty.sendFromTtyHook?(c)
      }
      switch c {
      case "\u{0C}":  // control-L
        row = 0
        lastRow = ""
        rowData = [String](repeating: "", count: rowData.count)
      case "\u{08}":  // backspace
        if !lastRow.isEmpty { lastRow.removeLast() }
      case "\n", "\r":
        try commit()
      default:
        if !Tty.isISOControl(c) {
          if lastRow.count == colCount { try commit() }
          lastRow.append(c)
        }
      }
    }

    /// `TtyState.clear()`.
    public func clear() {
      rowData = [String](repeating: "", count: rowData.count)
      lastRow = ""
      row = 0
    }

    /// `TtyState.commit()`.
    ///
    /// D13: Java is `System.arraycopy(rowData, 1, rowData, 0, rowData.length - 1)` when the
    /// scrollback buffer is full. `rowData.length` is `ATTR_ROWS - 1` and is fixed size; the
    /// "full" branch shifts every row up by one (dropping the oldest) and writes `lastRow` into
    /// the newly-freed last slot, preserving the array's length throughout. When `ATTR_ROWS == 1`
    /// that length is 0, so Java's arraycopy receives length `-1` and throws
    /// `IndexOutOfBoundsException` the first time any row is ever committed (any newline, or a
    /// column overflow): reachable from an ordinary `.circ` file, so this throws rather than
    /// indexing a would-be-negative range.
    private func commit() throws {
      if row >= rowData.count {
        guard !rowData.isEmpty else { throw TtyError.zeroRowScrollback }
        rowData.removeFirst()
        rowData.append(lastRow)
      } else {
        rowData[row] = lastRow
        row += 1
      }
      lastRow = ""
    }

    /// `TtyState.getCursorColumn()`.
    public func cursorColumn() -> Int { lastRow.count }
    /// `TtyState.getCursorRow()`.
    public func cursorRow() -> Int { row }

    /// `TtyState.getRowString(int)`.
    public func rowString(_ index: Int) -> String {
      if index < row { return rowData[index] }
      if index == row { return lastRow }
      return ""
    }

    /// `TtyState.setLastClock(Value)`.
    public func setLastClock(_ newClock: Value) -> Value {
      let old = lastClock
      lastClock = newClock
      return old
    }

    /// `TtyState.setSendStdout(boolean)`.
    public func setSendStdout(_ value: Bool) { sendStdout = value }

    /// `TtyState.getNrRows()`.
    public func nrRows() -> Int { rowData.count + 1 }
    /// `TtyState.getNrCols()`.
    public func nrCols() -> Int { colCount }

    /// `TtyState.updateSize(int, int)`.
    public func updateSize(rows: Int, cols: Int) {
      let oldRows = rowData.count + 1
      if rows != oldRows {
        var newData = [String](repeating: "", count: max(rows - 1, 0))
        if rows > oldRows || row < rows - 1 {
          // Rows added, or rows removed but every filled row still fits.
          for i in 0..<min(row, newData.count) {
            newData[i] = rowData[i]
          }
        } else {
          // Rows removed, and some filled rows must go: keep the most recent `rows - 1`.
          let start = row - rows + 1
          for i in 0..<max(rows - 1, 0) {
            newData[i] = rowData[start + i]
          }
          row = rows - 1
        }
        rowData = newData
      }

      let oldCols = colCount
      if cols != oldCols {
        colCount = cols
        if cols < oldCols {
          for i in 0..<rowData.count {
            if rowData[i].count > cols {
              rowData[i] = String(rowData[i].prefix(cols))
            }
          }
          if lastRow.count > cols {
            lastRow = String(lastRow.prefix(cols))
          }
        }
      }
    }
  }

  /// `Character.isISOControl(char)`, restricted to the 7-bit range this port ever receives (the
  /// `IN` port is 1 bit wide × 7, so `in.toLongValue()` is always `0...127` when defined).
  private static func isISOControl(_ c: Character) -> Bool {
    guard let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
    return scalar.value <= 0x1F || scalar.value == 0x7F
  }

  private func ttyState(_ state: any InstanceState) -> State {
    let rows = Tty.rowCount(state.attributeValue(Tty.attrRows))
    let cols = Tty.columnCount(state.attributeValue(Tty.attrColumns))
    if let existing = state.data as? State {
      existing.updateSize(rows: rows, cols: cols)
      return existing
    }
    let fresh = State(rows: rows, cols: cols)
    state.setData(fresh)
    return fresh
  }

  // MARK: - Paint (D6)

  /// `Tty.DEFAULT_FONT`: `new Font("monospaced", Font.PLAIN, 11)`.
  ///
  /// Monospaced is load-bearing, not cosmetic: the cursor bar is positioned by measuring the
  /// prefix of the cursor's row, and the component's own width is `cols * charWidth('W')`. A
  /// proportional substitution puts the cursor in the wrong place on every row that contains a
  /// narrow character.
  public static let defaultFont = SceneFont(family: .monospaced, size: 11)

  /// The paint-path twin of `ttyState(_:)`; see `Video`'s equivalent for why it is duplicated.
  private func ttyState(painting painter: any IoInstancePainter) -> State {
    let rows = Tty.rowCount(painter.attributeValue(Tty.attrRows))
    let cols = Tty.columnCount(painter.attributeValue(Tty.attrColumns))
    if let existing = painter.data as? State {
      existing.updateSize(rows: rows, cols: cols)
      return existing
    }
    let fresh = State(rows: rows, cols: cols)
    painter.setData(fresh)
    return fresh
  }

  /// `paintGhost(InstancePainter)`, `Tty.java:143-149`.
  public func paintGhost(_ painter: any IoInstancePainter) {
    let bds = painter.bounds
    painter.withWidth(2) {
      painter.scene.drawRoundRect(bds.x, bds.y, bds.width, bds.height, 10, 10)
    }
  }

  /// `paintInstance(InstancePainter)`: `Tty.java:151-207`.
  ///
  /// ── UPSTREAM INCONSISTENCY, PRESERVED ── the background fill uses a literal corner radius of
  /// `10` while the outline drawn immediately after uses `2 * BORDER == 12`. The two rounded
  /// rectangles therefore do not share a corner curve, and a sliver of background shows outside
  /// the outline at each corner. Making them agree is a one-character change and would stop
  /// matching the reference render.
  public func paintInstance(_ painter: any IoInstancePainter) {
    let showState = painter.showState
    let g = painter.scene
    let bds = painter.bounds

    if painter.shouldDrawColor {
      g.color = .attribute(
        painter.attributeValue(IoLibrary.background, default: Tty.defaultBackground))
      g.fillRoundRect(bds.x, bds.y, bds.width, bds.height, 10, 10)
    }

    g.color = painter.componentColor
    painter.withWidth(2) {
      // `drawClock` switches to width 2 itself and back to 1 on exit, so it is inside this
      // bracket in Java only incidentally; the round-rect after it is what needs the 2.
      painter.drawClock(Tty.ck, .east)
      g.drawRoundRect(bds.x, bds.y, bds.width, bds.height, 2 * Tty.border, 2 * Tty.border)
    }
    painter.drawPort(Tty.clr)
    painter.drawPort(Tty.we)
    painter.drawPort(Tty.inPort)

    let rows = Tty.rowCount(painter.attributeValue(Tty.attrRows))
    let cols = Tty.columnCount(painter.attributeValue(Tty.attrColumns))

    if showState {
      // Java brackets this snapshot in `synchronized (state)` because its paint runs on the AWT
      // thread while `propagate` runs on the simulator thread. This port's renderer samples
      // committed state at display refresh (D7) rather than reaching into live component data,
      // so the snapshot is taken here as one contiguous read and nothing is held across the
      // emit loop.
      let state = ttyState(painting: painter)
      let rowData = (0..<rows).map { state.rowString($0) }
      let curRow = state.cursorRow()
      let curCol = state.cursorColumn()

      g.font = Tty.defaultFont
      g.color = .attribute(
        painter.attributeValue(IoLibrary.color, default: ColorSpec(red: 0, green: 0, blue: 0)))
      let fm = g.fontMetrics()
      let x = bds.x + Tty.border
      var y = bds.y + Tty.border + (Tty.rowHeight + fm.ascent) / 2
      for i in 0..<rows {
        g.drawString(rowData[i], x: x, y: y)
        if i == curRow {
          // The bar sits after the characters already typed on this row, so the prefix has to
          // be measured; the column index times a nominal advance is not the same thing once
          // the measurer is a real one.
          let prefix = String(rowData[i].prefix(curCol))
          let x0 = x + g.measuredWidth(of: prefix)
          g.drawLine(x0, y - fm.ascent, x0, y)
        }
        y += Tty.rowHeight
      }
    } else {
      // Note Java does **not** set `DEFAULT_FONT` on this branch: the description is measured
      // and drawn in whatever font the canvas had installed. Preserved.
      var str = "TTY (\(rows) rows, \(cols) cols)"
      let fm = g.fontMetrics()
      var strWidth = g.measuredWidth(of: str)
      if strWidth + Tty.border > bds.width {
        str = "TTY"
        strWidth = g.measuredWidth(of: str)
      }
      let x = bds.x + (bds.width - strWidth) / 2
      let y = bds.y + (bds.height + fm.ascent) / 2
      g.drawString(str, x: x, y: y)
    }
  }

  // MARK: InstanceFactory

  /// `propagate(InstanceState)`.
  public override func propagate(_ state: any InstanceState) throws {
    let trigger = state.attributeValue(StdAttr.edgeTrigger, default: StdAttr.triggerRising)
    let tty = ttyState(state)
    let clear = state.portValue(Tty.clr)
    let clock = state.portValue(Tty.ck)
    let enable = state.portValue(Tty.we)
    let inValue = state.portValue(Tty.inPort)

    let lastClock = tty.setLastClock(clock)
    if clear == .trueValue {
      tty.clear()
    } else if enable != .falseValue {
      let go: Bool =
        trigger == StdAttr.triggerFalling
        ? (lastClock == .trueValue && clock == .falseValue)
        : (lastClock == .falseValue && clock == .trueValue)
      if go {
        let code = inValue.isFullyDefined() ? UInt8(truncatingIfNeeded: inValue.toLongValue()) : 0x3F  // '?'
        try tty.add(Character(UnicodeScalar(code)))
      }
    }
  }

  /// `Tty.sendToStdout(InstanceState)`; flips the per-`CircuitState` flag that routes future
  /// `add(char)` calls through `sendFromTtyHook`. `logisim-cli`'s `-tty` driver calls this once
  /// it has resolved the component's own `InstanceState`.
  public func sendToStdout(_ state: any InstanceState) {
    ttyState(state).setSendStdout(true)
  }
}

/// `Tty` was the one io factory that wrote both `paintInstance` and `paintGhost` and then never
/// declared the conformance, so even after the renderer learned to dispatch to `IoPaintable` it
/// would still have drawn nothing. Every sibling in this directory has the same line; this one
/// was simply missed, and nothing could see it; an unconformed class's methods are perfectly
/// valid Swift, just unreachable.
extension Tty: IoPaintable {}
