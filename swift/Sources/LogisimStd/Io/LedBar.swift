// LedBar.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.io.LedBar),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// `LedBar extends DotMatrixBase` exactly as `DotMatrix` does; see `DotMatrix.swift`'s file header
// for why the shared base lives there rather than in a `DotMatrixBase.swift` this slice does not
// own a slot for.
//
// ── Not ported ──────────────────────────────────────────────────────────────────────────────
//
//   * `DynamicElementProvider`/`createDynamicElement` (`LedBarShape`): appearance editor, M7.
//   * `setIcon`; UI (D9). Painting itself is inherited from `DotMatrixBase`; see below.
//   * `StdAttr.MAPINFO`: omitted from `DotMatrixBase`'s attribute template; see
//     `SevenSegment.swift`'s file header for why.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.io.LedBar`: a one-row LED cluster ("bar graph") built on the same
/// grid engine as `DotMatrix`.
public final class LedBar: DotMatrixBase {

  /// `LedBar._ID`.
  public static let id = "LedBar"

  /// `LedBar.ATTR_MATRIX_ROWS`. Hidden permanently below (`setHidden(true)` in the Java
  /// constructor); a bar graph's row count is fixed at 1 and not user-editable.
  public static let attrMatrixRows: Attribute<BitWidth> = Attributes.forBitWidth(
    "matrixrows", min: 1, max: Int32(BitWidth.maxWidth))
  /// `LedBar.ATTR_MATRIX_COLS`: the number of segments. Not hidden.
  public static let attrMatrixCols: Attribute<BitWidth> = Attributes.forBitWidth(
    "matrixcols", min: 1, max: Int32(BitWidth.maxWidth))

  /// `LedBar.ATTR_DOT_SHAPE`: a single-choice option list (padded square only). Hidden
  /// permanently, same reasoning as `ATTR_MATRIX_ROWS`.
  ///
  /// **Named `ledBarDotShape`, not `attrDotShape`, purely to avoid a Swift collision.** Java
  /// declares `LedBar.ATTR_DOT_SHAPE` alongside an inherited `DotMatrixBase.ATTR_DOT_SHAPE` and
  /// they are different objects with different choice lists. In Swift a `static let` in a
  /// subclass that shadows a base's `static let` is read as an override attempt, and a stored
  /// property cannot override; "cannot override with a stored property 'attrDotShape'".
  /// Renaming keeps them as two distinct instances, which is what upstream has and what
  /// correctness requires: attribute comparison here is reference identity (`===`), mirroring
  /// Java, so collapsing them into one would silently change which choice list applies.
  public static let ledBarDotShape: Attribute<AttributeOption> = Attributes.forOption(
    "dotshape", choices: [DotMatrixBase.shapePaddedSquare])

  public static let inputOneWire = AttributeOption(value: "row")
  public static let inputSeparated = AttributeOption(value: "column")

  /// `LedBar.ATTR_INPUT_TYPE`. Renamed for the same reason as `ledBarDotShape` above; note the
  /// option tokens differ from the base's, so these genuinely must be separate attributes.
  public static let ledBarInputType: Attribute<AttributeOption> = Attributes.forOption(
    "inputtype", choices: [inputSeparated, inputOneWire])

  public override var attributeRows: Attribute<BitWidth> { LedBar.attrMatrixRows }
  public override var attributeColumns: Attribute<BitWidth> { LedBar.attrMatrixCols }
  public override var attributeShape: Attribute<AttributeOption> { LedBar.ledBarDotShape }
  public override var defaultShape: AttributeOption { DotMatrixBase.shapePaddedSquare }
  public override var attributeInputType: Attribute<AttributeOption> { LedBar.ledBarInputType }
  public override var attributeItemColumn: AttributeOption { LedBar.inputSeparated }
  public override var attributeItemRow: AttributeOption { LedBar.inputOneWire }
  public override var attributeItemSelect: AttributeOption { DotMatrixBase.inputSelect }

  /// `LedBar()`: `super(_ID, …, 8, 1, …)`: 8 columns (segments), 1 row.
  public init() {
    super.init(name: LedBar.id, displayName: "LED Bar", cols: 8, rows: 1)
    // `ATTR_DOT_SHAPE.setHidden(true); ATTR_MATRIX_ROWS.setHidden(true);`: mutating `isHidden`
    // in place, exactly as upstream mutates the shared `Attribute` object post-construction.
    LedBar.ledBarDotShape.isHidden = true
    LedBar.attrMatrixRows.isHidden = true
    scaleY = 3
    drawBorder = false
  }
}

// MARK: - Paint (D6)
//
// The whole glyph is `DotMatrixBase.paintInstance` (see `DotMatrix.swift`); a bar differs only
// in the three data members set above, one row, `scaleY = 3`, and no border, plus a shape
// attribute whose only choice is the padded square.
//
// One consequence worth stating because it looks like a port bug and is not: `drawBorder ==
// false` means an unlit LedBar is a bare DARK_GRAY strip with padded-square segments on it and
// **no outline at all**. That is upstream's appearance.

extension LedBar: IoPaintable {}
