// TunnelAttributes.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.wiring.TunnelAttributes),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Tunnel connectivity is NOT decided here ─────────────────────────────────────────────────
//
// This file only carries the four saved attributes (`FACING`, `WIDTH`, `LABEL`, `LABEL_FONT`)
// plus the label-position geometry `configureLabel()` derives from `FACING`. The actual "join
// nets by label" behaviour, case-sensitive, `String.trim()`-equivalent matching, lives in
// `CircuitWires.connectTunnels` (`LogisimKernel/Propagation/CircuitWires.swift`, owned by the M3
// Simulation workflow, not this slice), which already reads `wireTunnelLabel` **untrimmed** and
// trims it itself with `javaTrim`; see that file's `connectTunnels` doc comment. `label` here is
// therefore stored and compared byte-for-byte as typed; no whitespace handling happens in this
// file, matching `TunnelAttributes.java` exactly (it stores the raw string Java's `Attribute<
// String>` gives it, untouched).

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.wiring.TunnelAttributes`.
public final class TunnelAttributes: AbstractAttributeSet {

  /// `TunnelAttributes.ATTRIBUTES`.
  private static let attributeList: [AnyAttribute] = [
    StdAttr.facing, StdAttr.width, StdAttr.label, StdAttr.labelFont,
  ]

  // MARK: - Stored state

  /// `TunnelAttributes.facing`. Default `WEST`; note this differs from most facing-attribute
  /// components (`StdAttr.facing`'s own codec has no default; each component picks its own).
  var facing: Direction = .west

  /// `TunnelAttributes.width`.
  var width: BitWidth = .one

  /// `TunnelAttributes.label`.
  var label: String = ""

  /// `TunnelAttributes.labelFont`.
  var labelFont: FontSpec = StdAttr.defaultLabelFont

  /// `TunnelAttributes.offsetBounds`; `nil` is Java's `null`-as-"not yet computed" cache state.
  var offsetBounds: Bounds?

  /// `TunnelAttributes.labelX` / `labelY` / `labelHAlign` / `labelVAlign`, all derived from
  /// `facing` by `configureLabel()`. `labelHAlign`/`labelVAlign` reproduce
  /// `TextField.H_LEFT`/`H_RIGHT`/`H_CENTER` and `V_TOP`/`V_BOTTOM`/`V_CENTER_OVERALL` as raw
  /// `Int`s (all of which are themselves aliases of `GraphicsUtil`'s: see
  /// `SplitterParameters.swift`'s header for the exact values and why a shared alignment type is
  /// not available yet).
  var labelX: Int = 0
  var labelY: Int = 0
  var labelHAlign: Int = 0
  var labelVAlign: Int = 0

  public override init() {
    super.init()
    configureLabel()
  }

  /// `TunnelAttributes.configureLabel()` (`TunnelAttributes.java:47-79`).
  private func configureLabel() {
    let margin = Tunnel.arrowMargin
    switch facing {
    case .north:
      labelX = 0
      labelY = margin
      labelHAlign = Tunnel.hCenter
      labelVAlign = Tunnel.vTop
    case .south:
      labelX = 0
      labelY = -margin
      labelHAlign = Tunnel.hCenter
      labelVAlign = Tunnel.vBottom
    case .east:
      labelX = -margin
      labelY = 0
      labelHAlign = Tunnel.hRight
      labelVAlign = Tunnel.vCenterOverall
    case .west:
      labelX = margin
      labelY = 0
      labelHAlign = Tunnel.hLeft
      labelVAlign = Tunnel.vCenterOverall
    }
  }

  /// `TunnelAttributes.setOffsetBounds(Bounds)`; returns whether the cache actually changed, as
  /// Java's does (used only internally here; the ghost-painting caller that reads the return
  /// value in Java is M6/not ported).
  @discardableResult
  func setOffsetBoundsCache(_ value: Bounds?) -> Bool {
    let same = offsetBounds == value
    if !same { offsetBounds = value }
    return !same
  }

  // MARK: - AbstractAttributeSet

  public override var attributes: [AnyAttribute] { TunnelAttributes.attributeList }

  public override func rawValue(_ attribute: AnyAttribute) -> AttributeValue? {
    if attribute === StdAttr.facing { return StdAttr.facing.encode(facing) }
    if attribute === StdAttr.width { return StdAttr.width.encode(width) }
    if attribute === StdAttr.label { return StdAttr.label.encode(label) }
    if attribute === StdAttr.labelFont { return StdAttr.labelFont.encode(labelFont) }
    return nil
  }

  /// `TunnelAttributes.setValue(Attribute<V>, V)` (`TunnelAttributes.java:144-162`).
  public override func setRawValue(_ attribute: AnyAttribute, _ newValue: AttributeValue?) throws {
    var oldValue: AttributeValue?
    if attribute === StdAttr.facing {
      guard let decoded = newValue.flatMap(StdAttr.facing.decode) else {
        throw ComponentError.unsupportedAttributeValue(
          factory: Tunnel.id, attribute: attribute.name)
      }
      facing = decoded
      configureLabel()
    } else if attribute === StdAttr.width {
      guard let decoded = newValue.flatMap(StdAttr.width.decode) else {
        throw ComponentError.unsupportedAttributeValue(
          factory: Tunnel.id, attribute: attribute.name)
      }
      width = decoded
    } else if attribute === StdAttr.label {
      guard let decoded = newValue.flatMap(StdAttr.label.decode) else {
        throw ComponentError.unsupportedAttributeValue(
          factory: Tunnel.id, attribute: attribute.name)
      }
      // Java passes the OLD label as `oldvalue` here; the one attribute among the four that
      // does. Preserved.
      oldValue = StdAttr.label.encode(label)
      label = decoded
    } else if attribute === StdAttr.labelFont {
      guard let decoded = newValue.flatMap(StdAttr.labelFont.decode) else {
        throw ComponentError.unsupportedAttributeValue(
          factory: Tunnel.id, attribute: attribute.name)
      }
      labelFont = decoded
    } else {
      throw AttributeSetError.attributeAbsent(name: attribute.name)
    }
    // Java clears the bounds cache unconditionally after every successful write, including WIDTH
    // and LABEL_FONT changes that do not actually move the label position. Preserved.
    offsetBounds = nil
    fireAttributeValueChanged(attribute, value: newValue, oldValue: oldValue)
  }

  public override func makeCopyInstance() -> AbstractAttributeSet {
    TunnelAttributes()
  }

  /// `TunnelAttributes.copyInto` (`:81-84`) is empty in Java, but see `PATTERNS.md` §5 and
  /// `ConstantAttributes`'s header: Java's `clone()` calls `Object.clone()` FIRST, which already
  /// copies every field, so the empty body is not "nothing to copy", it is "nothing *left* to
  /// copy". `makeCopyInstance()` here starts from a blank `TunnelAttributes()`, so every field
  /// genuinely must be copied, or a copied tunnel would silently reset to `WEST`/width-1/no
  /// label/default font.
  public override func copyInto(_ destination: AbstractAttributeSet) {
    guard let destination = destination as? TunnelAttributes else { return }
    destination.facing = facing
    destination.width = width
    destination.label = label
    destination.labelFont = labelFont
    destination.offsetBounds = offsetBounds
    destination.labelX = labelX
    destination.labelY = labelY
    destination.labelHAlign = labelHAlign
    destination.labelVAlign = labelVAlign
  }
}
