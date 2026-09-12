// FillableCanvasObject.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/draw/shapes/FillableCanvasObject.java. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore licensed GPL-3.0-only.
// See LICENSE.md.

import LogisimKernel

extension ColorSpec {
  static let black = ColorSpec(red: 0, green: 0, blue: 0)
  static let white = ColorSpec(red: 255, green: 255, blue: 255)
}

/// `com.cburch.draw.shapes.FillableCanvasObject`: package-private abstract base for
/// `Rectangular`, `Poly`, and `Curve`. `open` here (rather than `internal`) only because Swift
/// access control has no direct "package-private across files in one module + `open` for
/// subclassing" combination; nothing outside `LogisimDraw` is expected to subclass it.
open class FillableCanvasObject: AbstractCanvasObject {
  private var paintType: AttributeOption = DrawAttr.paintStroke
  private var strokeWidthValue: Int32 = 1
  private var strokeColorValue: ColorSpec = .black
  private var fillColorValue: ColorSpec = .white

  public func getPaintType() -> AttributeOption { paintType }
  public func getStrokeWidth() -> Int32 { strokeWidthValue }

  open override func rawValue(_ attribute: AnyAttribute) -> AttributeValue? {
    if attribute === DrawAttr.paintType { return .option(paintType) }
    if attribute === DrawAttr.strokeColor { return .color(strokeColorValue) }
    if attribute === DrawAttr.fillColor { return .color(fillColorValue) }
    if attribute === DrawAttr.strokeWidth { return .integer(strokeWidthValue) }
    return nil
  }

  open override func setRawValue(_ attribute: AnyAttribute, _ value: AttributeValue?) throws {
    if attribute === DrawAttr.paintType {
      guard case .option(let option)? = value else { return }
      paintType = option
      fireAttributeListChanged()
    } else if attribute === DrawAttr.strokeColor {
      guard case .color(let color)? = value else { return }
      strokeColorValue = color
    } else if attribute === DrawAttr.fillColor {
      guard case .color(let color)? = value else { return }
      fillColorValue = color
    } else if attribute === DrawAttr.strokeWidth {
      guard case .integer(let width)? = value else { return }
      strokeWidthValue = width
    }
    // Unrecognised attribute: silent no-op, matching Java's `updateValue` if/else chain with
    // no `else` clause.
  }

  open func matchesFillable(_ other: FillableCanvasObject) -> Bool {
    var ret = self.paintType == other.paintType
    if ret, self.paintType != DrawAttr.paintFill {
      ret = ret && self.strokeWidthValue == other.strokeWidthValue
        && self.strokeColorValue == other.strokeColorValue
    }
    if ret, self.paintType != DrawAttr.paintStroke {
      ret = ret && self.fillColorValue == other.fillColorValue
    }
    return ret
  }

  open func matchesHashCodeFillable() -> Int {
    var ret = paintType.hashValue
    if paintType != DrawAttr.paintFill {
      ret = ret &* 31 &+ Int(strokeWidthValue)
      ret = ret &* 31 &+ strokeColorValue.hashValue
    } else {
      ret = ret &* 31 &* 31
    }
    if paintType != DrawAttr.paintStroke {
      ret = ret &* 31 &+ fillColorValue.hashValue
    } else {
      ret = ret &* 31
    }
    return ret
  }

  /// Copies the fillable fields into a freshly-constructed sibling. Concrete leaf classes call
  /// this from their own `cloned()` after constructing the bare geometry, playing the role of
  /// Java's `Object.clone()` shallow field copy for this slice of state.
  public func copyFillableFields(into other: FillableCanvasObject) {
    other.paintType = paintType
    other.strokeWidthValue = strokeWidthValue
    other.strokeColorValue = strokeColorValue
    other.fillColorValue = fillColorValue
  }
}
