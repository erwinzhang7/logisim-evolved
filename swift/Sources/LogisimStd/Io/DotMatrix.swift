// DotMatrix.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.io.{DotMatrix, DotMatrixBase}),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Why `DotMatrixBase` lives in this file ──────────────────────────────────────────────────
//
// Upstream's real logic is in the *abstract* `DotMatrixBase` (495 lines); `DotMatrix.java` itself
// is ~50 lines of hook overrides. `LedBar` (`LedBar.swift`, a file this slice also owns) extends
// the same base. File ownership for this slice is exactly eight named files, there is no ninth
// file for a shared base, so `DotMatrixBase` is embedded here, as an `open class` that `DotMatrix`
// (below) and `LedBar` (`LedBar.swift`) both subclass, preserving the inheritance chain rather
// than flattening it into two independent copies. If a `DotMatrixBase.swift` is ever carved out,
// this type moves there unchanged.
//
// ── Not ported ──────────────────────────────────────────────────────────────────────────────
//
//   * `setIcon`; UI (D9). `paintInstance` and `drawCircle`/`drawSquare`/`drawPaddedSquare` ARE
//     ported; see the Paint section on `DotMatrixBase`.
//   * `DynamicElementProvider`/`createDynamicElement` (`DotMatrixShape`): appearance editor, M7.
//   * `StdAttr.MAPINFO`: omitted; see `SevenSegment.swift`'s file header for why.
//   * `// TODO repropagate when rows/cols change`: upstream's own TODO, left exactly as a TODO.
//
// Needs `StdAttr.labelLocation`: see `SevenSegment.swift`'s file header; same gap, same fix.
// Also needs `std/wiring`'s `DurationAttribute`, which this slice does not own; `ATTR_PERSIST`
// below reimplements its exact codec (`Integer.parseInt`, not the wide-parse-then-truncate
// `Attributes.forIntegerRange` uses) rather than depending on an unported type.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

// MARK: - DotMatrixBase

/// `com.cburch.logisim.std.io.DotMatrixBase`: the shared LED-grid engine behind `DotMatrix`
/// (this file) and `LedBar` (`LedBar.swift`).
open class DotMatrixBase: InstanceFactoryBase {

  // MARK: State — `DotMatrixBase.State`

  /// `DotMatrixBase.State`, nested to avoid a top-level name collision with `Tty.State` /
  /// `RgbVideo.State` in this module (Java keeps all three at package scope; D4/D3 give Swift
  /// no equivalent "package" grouping without one file per type, which ownership forbids here).
  public final class State: InstanceData {
    public var rows: Int
    public var cols: Int
    public var grid: [Value]
    /// Java `long[] persistTo`: the tick at which a persisted TRUE reverts to whatever the
    /// grid cell actually holds. Kept as `Int` (this port's `tickCount` currency) rather than
    /// `Int64`; see `updateSize` for the one place Java's `int + int -> long` widening matters.
    public var persistTo: [Int]

    public init(rows: Int, cols: Int, curClock: Int) {
      self.rows = -1
      self.cols = -1
      self.grid = []
      self.persistTo = []
      updateSize(rows: rows, cols: cols, curClock: curClock)
    }

    private init(rows: Int, cols: Int, grid: [Value], persistTo: [Int]) {
      self.rows = rows
      self.cols = cols
      self.grid = grid
      self.persistTo = persistTo
    }

    public func cloneData() -> any InstanceData {
      State(rows: rows, cols: cols, grid: grid, persistTo: persistTo)
    }

    /// `State.get(int, int, long)`.
    public func get(row: Int, col: Int, curTick: Int) -> Value {
      let index = row * cols + col
      var result = grid[index]
      if result == .falseValue, persistTo[index] - curTick >= 0 {
        result = .trueValue
      }
      return result
    }

    /// `State.setColumn(int, Value, long)`.
    public func setColumn(index: Int, colVector: Value, persist: Int) {
      var gridLoc = (rows - 1) * cols + index
      let stride = -cols
      let vals = colVector.getAll()
      for val in vals {
        if grid[gridLoc] == .trueValue { persistTo[gridLoc] = persist - 1 }
        grid[gridLoc] = val
        if val == .trueValue { persistTo[gridLoc] = persist }
        gridLoc += stride
      }
    }

    /// `State.setRow(int, Value, long)`.
    public func setRow(index: Int, rowVector: Value, persist: Int) {
      var gridLoc = (index + 1) * cols - 1
      let stride = -1
      let vals = rowVector.getAll()
      for val in vals {
        if grid[gridLoc] == .trueValue { persistTo[gridLoc] = persist - 1 }
        grid[gridLoc] = val
        if val == .trueValue { persistTo[gridLoc] = persist }
        gridLoc += stride
      }
    }

    /// `State.setSelect(Value, Value, long)`.
    public func setSelect(rowVector: Value, colVector: Value, persist: Int) {
      let rowVals = rowVector.getAll()
      let colVals = colVector.getAll()
      var gridLoc = 0
      var i = rowVals.count - 1
      while i >= 0 {
        let wholeRow = rowVals[i]
        if wholeRow == .trueValue {
          var j = colVals.count - 1
          while j >= 0 {
            let val = colVals[colVals.count - 1 - j]
            if grid[gridLoc] == .trueValue { persistTo[gridLoc] = persist - 1 }
            grid[gridLoc] = val
            if val == .trueValue { persistTo[gridLoc] = persist }
            gridLoc += 1
            j -= 1
          }
        } else {
          // Java: `if (wholeRow != Value.FALSE) wholeRow = Value.ERROR;`
          let fillValue: Value = wholeRow == .falseValue ? .falseValue : .errorValue
          var j = colVals.count - 1
          while j >= 0 {
            if grid[gridLoc] == .trueValue { persistTo[gridLoc] = persist - 1 }
            grid[gridLoc] = fillValue
            gridLoc += 1
            j -= 1
          }
        }
        i -= 1
      }
    }

    /// `State.updateSize(int, int, long)`.
    public func updateSize(rows: Int, cols: Int, curClock: Int) {
      guard self.rows != rows || self.cols != cols else { return }
      self.rows = rows
      self.cols = cols
      let length = rows * cols
      grid = [Value](repeating: .unknownValue, count: max(length, 0))
      persistTo = [Int](repeating: curClock - 1, count: max(length, 0))
    }
  }

  // MARK: Shared attribute identities

  public static let inputSelect = AttributeOption(value: "select")
  public static let inputColumn = AttributeOption(value: "column")
  public static let inputRow = AttributeOption(value: "row")

  public static let shapeCircle = AttributeOption(value: "circle")
  public static let shapeSquare = AttributeOption(value: "square")
  public static let shapePaddedSquare = AttributeOption(value: "clusterSegment")

  public static let attrInputType: Attribute<AttributeOption> = Attributes.forOption(
    "inputtype", choices: [inputColumn, inputRow, inputSelect])

  public static let attrDotShape: Attribute<AttributeOption> = Attributes.forOption(
    "dotshape", choices: [shapeCircle, shapeSquare, shapePaddedSquare])

  /// `DotMatrixBase.ATTR_PERSIST`: a `DurationAttribute("persist", 0, Int32.max, true)`. See
  /// the file header for why this is reimplemented rather than depending on `std/wiring`.
  /// `DurationAttribute.parse` is strict `Integer.parseInt`, unlike `Attributes.forIntegerRange`'s
  /// wide-parse-then-truncate.
  public static let attrPersist: Attribute<Int32> = Attribute(
    name: "persist",
    codec: AttributeCodec(
      parse: { text in
        let value = try AttributeTextFormat.parseSigned(text, radix: 10, bits: 32)
        if value < 0 {
          throw AttributeParseError.numberFormat("duration must be at least 0")
        }
        return Int32(value)
      },
      toStandardString: { AttributeTextFormat.standardScrub(String($0)) },
      encode: { .integer($0) },
      decode: { if case .integer(let v) = $0 { return v } else { return nil } }))

  /// `DotMatrixBase.getLabels(int, int)`. FPGA board-mapping labels; kept as pure data (see
  /// `SevenSegment.swift`'s file header for why `MAPINFO` itself is not ported).
  public static func labels(rows: Int, cols: Int) -> [String] {
    var result: [String] = []
    for r in 0..<max(rows, 0) {
      for c in 0..<max(cols, 0) {
        result.append("Row\(r)Col\(c)")
      }
    }
    return result
  }

  // MARK: Subclass hooks — Java's abstract methods
  //
  // Java expresses these as abstract methods `DotMatrix`/`LedBar` override. Swift protocols
  // can't carry the storage `InstanceFactoryBase` needs, so they are `open` computed properties
  // instead, matching the `open class` shape this whole chassis already uses (see
  // `InstanceFactory.swift`'s header on why `InstanceFactoryBase` is a class, not a protocol).
  // Trapping on the base's own accessor mirrors D13's "abstract-method stub" carve-out: no
  // `.circ` file can reach a `DotMatrixBase` that isn't `DotMatrix` or `LedBar`.

  open var attributeRows: Attribute<BitWidth> {
    fatalError("DotMatrixBase subclasses must override attributeRows")
  }
  open var attributeColumns: Attribute<BitWidth> {
    fatalError("DotMatrixBase subclasses must override attributeColumns")
  }
  open var attributeShape: Attribute<AttributeOption> {
    fatalError("DotMatrixBase subclasses must override attributeShape")
  }
  open var defaultShape: AttributeOption {
    fatalError("DotMatrixBase subclasses must override defaultShape")
  }
  open var attributeInputType: Attribute<AttributeOption> {
    fatalError("DotMatrixBase subclasses must override attributeInputType")
  }
  open var attributeItemColumn: AttributeOption {
    fatalError("DotMatrixBase subclasses must override attributeItemColumn")
  }
  open var attributeItemRow: AttributeOption {
    fatalError("DotMatrixBase subclasses must override attributeItemRow")
  }
  open var attributeItemSelect: AttributeOption {
    fatalError("DotMatrixBase subclasses must override attributeItemSelect")
  }

  // MARK: Instance configuration — `setDrawBorder`/`setScaleX`/`setScaleY` (PAINT-only, kept as
  // plain data since `LedBar` sets non-default values that the geometry below depends on).

  public var drawBorder = true
  public var scaleX = 1
  public var scaleY = 1

  /// `DotMatrixBase(String, StringGetter, int cols, int rows, HdlGeneratorFactory)`. Parameter
  /// order is `(cols, rows)`, matching upstream exactly (`DotMatrix()` passes `(5, 7)`: 5
  /// columns, 7 rows; `LedBar()` passes `(8, 1)`).
  ///
  /// `displayName` is threaded through rather than derived from `name`: upstream's two
  /// subclasses pass *different* getters (`S.getter("dotMatrixComponent")` = "LED Matrix",
  /// `S.getter("ioLedBarComponent")` = "LED Bar"), and neither equals its `_ID`.
  public init(name: String, displayName: String, cols: Int, rows: Int) {
    // `super(name, displayName, generator, true)`; the trailing `true` is `requiresLabel`.
    super.init(name, displayName: displayName, requiresLabel: true)
    // Attribute identities below are resolved through the `open` accessors overridden by
    // `DotMatrix`/`LedBar`. That dispatch is safe here even though this is still inside a
    // designated initializer: Swift's two-phase init makes `self` fully valid (and overridable
    // members dynamically dispatched to the most-derived override) once the `super.init` call
    // above returns, and neither subclass has stored properties of its own to race against:
    // both express their overrides as pure computed properties over already-existing statics.
    setAttributes([
      attributeInputType.binding(attributeItemColumn),
      attributeColumns.binding(BitWidth.known(cols)),
      attributeRows.binding(BitWidth.known(rows)),
      StdAttr.selectLocation.binding(StdAttr.selectBottomLeft),
      IoLibrary.onColor.binding(ColorSpec(red: 0, green: 255, blue: 0)),  // Color.GREEN
      IoLibrary.offColor.binding(ColorSpec(red: 128, green: 128, blue: 128)),  // Color.gray
      DotMatrixBase.attrPersist.binding(0),
      attributeShape.binding(defaultShape),
      StdAttr.label.binding(""),
      StdAttr.labelLocation.binding(.north),
      StdAttr.labelFont.binding(StdAttr.defaultLabelFont),
      StdAttr.labelColor.binding(StdAttr.defaultLabelColor),
      StdAttr.labelVisibility.binding(true),
    ])
  }

  // MARK: Bounds — `getOffsetBounds(AttributeSet)`

  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let input = attributes[attributeInputType, default: attributeItemColumn]
    let cols = attributes[attributeColumns, default: BitWidth.known(1)].width
    let rows = attributes[attributeRows, default: BitWidth.known(1)].width
    if input == attributeItemColumn {
      return Bounds.create(-5 * scaleX, -10 * scaleY * rows, 10 * scaleX * cols, 10 * scaleY * rows)
    } else if input == attributeItemRow {
      return Bounds.create(0, -5 * scaleY, 10 * scaleX * cols, 10 * scaleY * rows)
    } else {
      // input == attributeItemSelect
      if rows == 1 {
        return Bounds.create(0, -5 * scaleY, 10 * scaleX * cols, 10 * scaleY * rows)
      }
      return Bounds.create(0, -5 * scaleY * rows + 5, 10 * scaleX * cols, 10 * scaleY * rows)
    }
  }

  // MARK: Ports — `updatePorts(Instance)`

  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    let input = attributes[attributeInputType, default: attributeItemColumn]
    let cols = attributes[attributeColumns, default: BitWidth.known(1)].width
    let rows = attributes[attributeRows, default: BitWidth.known(1)].width
    let selectLoc = attributes[StdAttr.selectLocation, default: StdAttr.selectBottomLeft]

    if input == attributeItemColumn {
      return (0..<cols).map { i in
        Port(10 * i, selectLoc == StdAttr.selectBottomLeft ? 0 : rows * -10 * scaleY, .input, rows)
      }
    } else if input == attributeItemRow {
      return (0..<rows).map { i in
        Port(selectLoc == StdAttr.selectBottomLeft ? 0 : cols * 10, 10 * i, .input, cols)
      }
    } else {
      // input == attributeItemSelect
      if rows <= 1 {
        return [
          Port(0, 0, .input, cols),
          Port(10 * cols, 0, .input, rows),
        ]
      }
      let dx = selectLoc == StdAttr.selectBottomLeft ? 0 : cols * 10
      return [
        Port(dx, 0, .input, cols),
        Port(dx, 10, .input, rows),
      ]
    }
  }

  // MARK: State access — `getState(InstanceState)`

  private func gridState(_ state: any InstanceState) -> State {
    let rows = state.attributeValue(attributeRows, default: BitWidth.known(1)).width
    let cols = state.attributeValue(attributeColumns, default: BitWidth.known(1)).width
    let clock = state.tickCount
    if let existing = state.data as? State {
      existing.updateSize(rows: rows, cols: cols, curClock: clock)
      return existing
    }
    let fresh = State(rows: rows, cols: cols, curClock: clock)
    state.setData(fresh)
    return fresh
  }

  // MARK: Paint (D6) — `paintInstance(InstancePainter)`

  /// `getState(InstanceState)` reached from the paint path.
  ///
  /// Java gets this for free because `InstancePainter implements InstanceState`; here the two
  /// are separate protocols (see `IoPainter.swift`), so the same three lines are spelled twice.
  /// The `setData` on the paint path is upstream's and is load-bearing: a matrix that has never
  /// propagated is painted from a state object created *by the painter*.
  private func gridState(painting painter: any IoInstancePainter) -> State {
    let rows = painter.attributeValue(attributeRows, default: BitWidth.known(1)).width
    let cols = painter.attributeValue(attributeColumns, default: BitWidth.known(1)).width
    let clock = painter.tickCount
    if let existing = painter.data as? State {
      existing.updateSize(rows: rows, cols: cols, curClock: clock)
      return existing
    }
    let fresh = State(rows: rows, cols: cols, curClock: clock)
    painter.setData(fresh)
    return fresh
  }

  /// `drawCircle(Graphics, int, int)`: `DotMatrixBase.java:353-355`.
  ///
  /// **The scale multiplies the absolute coordinate, not the offset**, so at `scaleY != 1` the
  /// circle lands nowhere near its cell. That is upstream's arithmetic verbatim and it is
  /// visible: `LedBar` has `scaleY == 3`, and it is the only component that both scales and
  /// reaches `drawCircle` (through the `!showState` preview branch). Writing the "obviously
  /// intended" `x + 1 * scaleX` here would make the port disagree with the reference on every
  /// LedBar in the corpus, so it is left exactly as Java has it.
  private func drawCircle(_ g: SceneBuilder, _ x: Int, _ y: Int) {
    g.fillOval((x + 1) * scaleX, (y + 1) * scaleY, 8 * scaleX, 8 * scaleY)
  }

  /// `drawSquare(Graphics, int, int)`.
  private func drawSquare(_ g: SceneBuilder, _ x: Int, _ y: Int) {
    g.fillRect(x, y, 10 * scaleX, 10 * scaleY)
  }

  /// `drawPaddedSquare(Graphics, int, int)`: 2 units of padding on each side, applied before
  /// the scale, so the lit area is `6 * scale` on a `10 * scale` pitch.
  private func drawPaddedSquare(_ g: SceneBuilder, _ x: Int, _ y: Int) {
    let paddingX = 2
    let paddingY = 2
    g.fillRect(
      x + paddingX * scaleX,
      y + paddingY * scaleY,
      (10 - 2 * paddingX) * scaleX,
      (10 - 2 * paddingY) * scaleY)
  }

  /// `paintInstance(InstancePainter)`, `DotMatrixBase.java:371-432`.
  public func paintInstance(_ painter: any IoInstancePainter) {
    let onColor = painter.attributeValue(IoLibrary.onColor, default: DotMatrixBase.defaultOnColor)
    let offColor = painter.attributeValue(IoLibrary.offColor, default: DotMatrixBase.defaultOffColor)
    let shape = painter.attributeValue(attributeShape, default: defaultShape)

    let data = gridState(painting: painter)
    let ticks = painter.tickCount
    let bounds = painter.bounds
    let showState = painter.showState
    let g = painter.scene

    let rows = data.rows
    let cols = data.cols

    // Ports first, deliberately: upstream's comment is "If user wants port dots to be hug it
    // would normally cover the component so we draw ports first, then happily paint over it."
    // Emitting them after the grid would leave a dot on top of every edge LED.
    painter.drawPorts()

    g.color = .darkGray
    g.fillRect(bounds.x, bounds.y, cols * 10 * scaleX, rows * 10 * scaleY)

    for j in 0..<max(rows, 0) {
      for i in 0..<max(cols, 0) {
        let x = bounds.x + 10 * i * scaleX
        let y = bounds.y + 10 * j * scaleY

        if !showState {
          g.color = .gray
          drawCircle(g, x, y)
          continue
        }

        let val = data.get(row: j, col: i, curTick: ticks)
        // TRUE and FALSE take the user's attribute colours; anything else, UNKNOWN, ERROR, a
        // width mismatch, takes the *value palette's* error colour, which is a render-time
        // theme entry rather than an attribute (D9). Two different colour sources in one
        // expression, and mixing them up is invisible until a circuit actually runs.
        if val == .trueValue {
          g.color = .attribute(onColor)
        } else if val == .falseValue {
          g.color = .attribute(offColor)
        } else {
          g.color = .palette(.error)
        }

        if shape == DotMatrixBase.shapeSquare {
          drawSquare(g, x, y)
        } else if shape == DotMatrixBase.shapePaddedSquare {
          drawPaddedSquare(g, x, y)
        } else {
          // SHAPE_CIRCLE is the default.
          drawCircle(g, x, y)
        }
      }
    }

    if drawBorder {
      g.color = .darkGray
      painter.withWidth(2) {
        g.drawRect(bounds.x, bounds.y, bounds.width, bounds.height)
      }
    }
    painter.drawLabel()
  }

  /// The attribute-template defaults: `Color.GREEN` and `Color.gray`.
  static let defaultOnColor = ColorSpec(red: 0, green: 255, blue: 0)
  static let defaultOffColor = ColorSpec(red: 128, green: 128, blue: 128)

  // MARK: InstanceFactory

  /// `propagate(InstanceState)`.
  ///
  /// D13: upstream's `else` branch is `throw new RuntimeException("Unexpected matrix type: " +
  /// type)`, reachable only if a subclass's `attributeInputType` choices and its
  /// `attributeItem{Column,Row,Select}` values disagree: not reachable from a `.circ` file for
  /// either shipped subclass, but kept as a throw (not a trap) since the attribute value itself
  /// does come from a `.circ` file.
  public override func propagate(_ state: any InstanceState) throws {
    let type = state.attributeValue(attributeInputType, default: attributeItemColumn)
    let rows = state.attributeValue(attributeRows, default: BitWidth.known(1)).width
    let cols = state.attributeValue(attributeColumns, default: BitWidth.known(1)).width
    let clock = state.tickCount
    // Java: `final long clock = state.getTickCount();`; note `clock` is declared `long`, so
    // `getTickCount()`'s `int` result is widened to `long` *before* the following addition, not
    // after. `long persist = clock + state.getAttributeValue(ATTR_PERSIST);` therefore adds an
    // `int` to an already-`long` operand, which Java promotes to `long` arithmetic throughout;
    // there is no 32-bit wraparound to reproduce here (unlike `Value`'s genuine int-typed sums).
    // Swift's `Int` is already 64-bit, so a plain addition matches exactly; do not route this
    // through `wrap32`, which would truncate a case Java never truncates.
    let persistAttr = state.attributeValue(DotMatrixBase.attrPersist, default: 0)
    let persist = clock + Int(persistAttr)

    let data = gridState(state)
    if type == attributeItemRow {
      for i in 0..<rows {
        data.setRow(index: i, rowVector: state.portValue(i), persist: persist)
      }
    } else if type == attributeItemColumn {
      for i in 0..<cols {
        data.setColumn(index: i, colVector: state.portValue(i), persist: persist)
      }
    } else if type == attributeItemSelect {
      data.setSelect(rowVector: state.portValue(1), colVector: state.portValue(0), persist: persist)
    } else {
      throw ComponentError.unsupportedAttributeValue(factory: name, attribute: "inputtype")
    }
  }
}

// MARK: - Label (board #78)

extension DotMatrixBase: InstanceLabelProvider {

  /// `Instance.computeLabelTextField(Instance.AVOID_LEFT)`: `DotMatrixBase.java:285`, re-run at
  /// `:335`/`:342`.
  ///
  /// Declared on the **base**, not on each concrete factory, because upstream installs it from
  /// `DotMatrixBase.configureNewInstance` and both `DotMatrix` and `LedBar` inherit that method
  /// unchanged. Conforming the base is the faithful shape and leaves `LedBar.swift` untouched.
  public func labelPlacement(_ painter: InstancePainter) -> LabelPlacement? {
    LabelPlacement.computed(painter, avoid: .left)
  }
}

// MARK: - DotMatrix

/// `com.cburch.logisim.std.io.DotMatrix`: a 5×7 (default) LED dot-matrix display.
public final class DotMatrix: DotMatrixBase {

  /// `DotMatrix._ID`.
  public static let id = "DotMatrix"

  /// `DotMatrix.ATTR_MATRIX_COLS`.
  public static let attrMatrixCols: Attribute<BitWidth> = Attributes.forBitWidth(
    "matrixcols", min: 1, max: Int32(BitWidth.maxWidth))
  /// `DotMatrix.ATTR_MATRIX_ROWS`.
  public static let attrMatrixRows: Attribute<BitWidth> = Attributes.forBitWidth(
    "matrixrows", min: 1, max: Int32(BitWidth.maxWidth))

  public override var attributeRows: Attribute<BitWidth> { DotMatrix.attrMatrixRows }
  public override var attributeColumns: Attribute<BitWidth> { DotMatrix.attrMatrixCols }
  public override var attributeShape: Attribute<AttributeOption> { DotMatrixBase.attrDotShape }
  public override var defaultShape: AttributeOption { DotMatrixBase.shapeSquare }
  public override var attributeInputType: Attribute<AttributeOption> { DotMatrixBase.attrInputType }
  public override var attributeItemColumn: AttributeOption { DotMatrixBase.inputColumn }
  public override var attributeItemRow: AttributeOption { DotMatrixBase.inputRow }
  public override var attributeItemSelect: AttributeOption { DotMatrixBase.inputSelect }

  /// `DotMatrix()`, `super(_ID, …, 5, 7, …)`: 5 columns, 7 rows.
  public init() {
    super.init(name: DotMatrix.id, displayName: "LED Matrix", cols: 5, rows: 7)
  }
}

// MARK: - Paint conformance
//
// `paintInstance` is implemented once on `DotMatrixBase`, exactly as upstream has it; this only
// announces the conformance for the concrete factory. `LedBar` declares its own in `LedBar.swift`
// and inherits the same implementation.

extension DotMatrix: IoPaintable {}
