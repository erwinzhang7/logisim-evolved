// TextAttributes.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.base.TextAttributes),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Every default here is gate-visible ───────────────────────────────────────────────────────
//
// `XmlWriter` emits an `<a>` element only for an attribute whose value differs from the factory
// default, so each of the five defaults below decides whether a byte appears in a saved file.
// They are transcribed literally from `TextAttributes()`'s constructor:
//
//   text   "text"    -> ""                                (empty string)
//   font   "font"    -> StdAttr.DEFAULT_LABEL_FONT        (SansSerif, bold, 16)
//   color  "color"   -> Color.BLACK                       (#000000, opaque)
//   halign "halign"  -> "center"  (TextField.H_CENTER  =  0)
//   valign "valign"  -> "base"    (TextField.V_BASELINE =  1)

import Foundation
import LogisimFile
import LogisimKernel

/// `Text.ATTR_HALIGN`'s choice list, as the native-enum shape D5 prefers for new component ports
/// (see `BitExtenderType`). Raw values are the exact `.circ` tokens; `alignmentValue` is the
/// `Integer` each `AttributeOption` carries as its Java `value`, i.e. the `TextField.H_*`
/// constant the text field and `GraphicsUtil.drawText` dispatch on.
///
/// Declaration order is upstream's (`left, right, center`), which is the order the attribute
/// editor would present.
public enum TextHorizontalAlign: String, AttributeOptionValue, CaseIterable, Sendable {
  case left
  case right
  case center

  /// `TextField.H_LEFT` / `H_RIGHT` / `H_CENTER`, themselves aliases of `GraphicsUtil`'s.
  public var alignmentValue: Int {
    switch self {
    case .left: return -1
    case .right: return 1
    case .center: return 0
    }
  }
}

/// `Text.ATTR_VALIGN`'s choice list. Declaration order is upstream's
/// (`top, base, bottom, center`).
public enum TextVerticalAlign: String, AttributeOptionValue, CaseIterable, Sendable {
  case top
  case base
  case bottom
  case center

  /// `TextField.V_TOP` / `V_BASELINE` / `V_BOTTOM`, and, for `center`, `TextField.H_CENTER`.
  ///
  /// ── UPSTREAM ODDITY, PRESERVED ──
  ///
  /// `Text.java:66` really does build the "center" *vertical* option out of `TextField.H_CENTER`
  /// rather than `V_CENTER`. Both constants are 0 (`GraphicsUtil.H_CENTER == V_CENTER == 0`), so
  /// the value is right by accident and nothing observable depends on the difference. Copied as
  /// the same number rather than "corrected" to `V_CENTER`, and noted so the next reader does not
  /// take the mismatch for a transcription slip.
  public var alignmentValue: Int {
    switch self {
    case .top: return -1
    case .base: return 1
    case .bottom: return 2
    case .center: return 0
    }
  }
}

/// `com.cburch.logisim.std.base.TextAttributes`.
public final class TextAttributes: AbstractAttributeSet {

  /// `TextAttributes.ATTRIBUTES`.
  private static let attributeList: [AnyAttribute] = [
    Text.attrText, Text.attrFont, Text.attrColor, Text.attrHAlign, Text.attrVAlign,
  ]

  // MARK: - Stored state

  /// `TextAttributes.text`.
  var text: String = ""

  /// `TextAttributes.font`.
  var font: FontSpec = StdAttr.defaultLabelFont

  /// `TextAttributes.color`: Java's `Color.BLACK`, i.e. opaque #000000.
  var color: ColorSpec = ColorSpec(red: 0, green: 0, blue: 0)

  /// `TextAttributes.halign`, initialised from `Text.ATTR_HALIGN.parse("center")`.
  var hAlign: TextHorizontalAlign = .center

  /// `TextAttributes.valign`, initialised from `Text.ATTR_VALIGN.parse("base")`.
  var vAlign: TextVerticalAlign = .base

  /// `TextAttributes.offsetBounds`; `nil` is Java's `null`-as-"not yet computed" cache state.
  var offsetBounds: Bounds?

  // MARK: - Derived accessors (Java's package-private getters)

  /// `getHorizontalAlign()`: the `Integer` payload, not the token.
  var horizontalAlign: Int { hAlign.alignmentValue }

  /// `getVerticalAlign()`.
  var verticalAlign: Int { vAlign.alignmentValue }

  /// `TextAttributes.setOffsetBounds(Bounds)`; returns whether the cache actually changed, as
  /// Java's does. Upstream's one caller that reads the return value is `Text.paintGhost`, which
  /// is M6; kept anyway so the shape matches `TunnelAttributes.setOffsetBoundsCache`.
  @discardableResult
  func setOffsetBoundsCache(_ value: Bounds?) -> Bool {
    let same = offsetBounds == value
    if !same { offsetBounds = value }
    return !same
  }

  // MARK: - AbstractAttributeSet

  public override var attributes: [AnyAttribute] { TextAttributes.attributeList }

  public override func rawValue(_ attribute: AnyAttribute) -> AttributeValue? {
    if attribute === Text.attrText { return Text.attrText.encode(text) }
    if attribute === Text.attrFont { return Text.attrFont.encode(font) }
    if attribute === Text.attrHAlign { return Text.attrHAlign.encode(hAlign) }
    if attribute === Text.attrVAlign { return Text.attrVAlign.encode(vAlign) }
    if attribute === Text.attrColor { return Text.attrColor.encode(color) }
    return nil
  }

  /// `TextAttributes.setValue(Attribute<V>, V)` (`TextAttributes.java:95-112`).
  public override func setRawValue(_ attribute: AnyAttribute, _ newValue: AttributeValue?) throws {
    if attribute === Text.attrText {
      guard let decoded = newValue.flatMap(Text.attrText.decode) else {
        throw ComponentError.unsupportedAttributeValue(factory: Text.id, attribute: attribute.name)
      }
      text = decoded
    } else if attribute === Text.attrFont {
      guard let decoded = newValue.flatMap(Text.attrFont.decode) else {
        throw ComponentError.unsupportedAttributeValue(factory: Text.id, attribute: attribute.name)
      }
      font = decoded
    } else if attribute === Text.attrHAlign {
      guard let decoded = newValue.flatMap(Text.attrHAlign.decode) else {
        throw ComponentError.unsupportedAttributeValue(factory: Text.id, attribute: attribute.name)
      }
      hAlign = decoded
    } else if attribute === Text.attrVAlign {
      guard let decoded = newValue.flatMap(Text.attrVAlign.decode) else {
        throw ComponentError.unsupportedAttributeValue(factory: Text.id, attribute: attribute.name)
      }
      vAlign = decoded
    } else if attribute === Text.attrColor {
      guard let decoded = newValue.flatMap(Text.attrColor.decode) else {
        throw ComponentError.unsupportedAttributeValue(factory: Text.id, attribute: attribute.name)
      }
      color = decoded
    } else {
      // Java throws `IllegalArgumentException("unknown attribute")` here, and it is reachable
      // from a malformed `.circ` (an `<a name="…">` this set does not carry), so D13 makes it a
      // throw rather than a trap.
      throw AttributeSetError.attributeAbsent(name: attribute.name)
    }
    // Java clears the bounds cache unconditionally after every successful write, including
    // COLOR changes that cannot move the text. Preserved.
    offsetBounds = nil
    // Unlike `TunnelAttributes`, upstream passes `null` for `oldValue` on *every* attribute here
    // : including TEXT, where `TunnelAttributes` passes the old LABEL. Preserved.
    fireAttributeValueChanged(attribute, value: newValue, oldValue: nil)
  }

  public override func makeCopyInstance() -> AbstractAttributeSet {
    TextAttributes()
  }

  /// `TextAttributes.copyInto` (`:45-48`) is empty in Java, but see PATTERNS.md §5: Java's
  /// `clone()` runs `Object.clone()` first, so the fields are already copied and the empty body
  /// means "nothing *left* to copy". `makeCopyInstance()` here starts from a blank
  /// `TextAttributes()`, so every field genuinely must be copied or a duplicated text annotation
  /// would come back empty, black and centre-aligned.
  public override func copyInto(_ destination: AbstractAttributeSet) {
    guard let destination = destination as? TextAttributes else { return }
    destination.text = text
    destination.font = font
    destination.color = color
    destination.hAlign = hAlign
    destination.vAlign = vAlign
    destination.offsetBounds = offsetBounds
  }
}
