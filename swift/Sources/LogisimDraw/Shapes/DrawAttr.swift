// DrawAttr.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/draw/shapes/DrawAttr.java. Copyright by the Logisim-evolution developers. This
// translation is a derivative work and is therefore licensed GPL-3.0-only. See LICENSE.md.
//
// Every attribute here is an ordinary `LogisimKernel.Attribute<V>` (D5) built through the same
// `Attributes` factory component attributes use; shapes are not a parallel attribute system.
// Localisation (`S.getter(...)` display names) does not come across, matching D9/D5: the UI
// layer owns display strings.
//
// `HALIGN_LEFT`/`VALIGN_TOP`/etc. carry the exact numeric payload Java's `AttributeOption`
// constructor derives from `EditableLabel.LEFT`/`.../TOP`/etc. via `Object.toString()`:
// `JTextField.LEFT/CENTER/RIGHT` are `2/0/4` (verified against the JDK), and
// `EditableLabel.TOP/MIDDLE/BASELINE/BOTTOM` are `8/9/10/11` (declared directly in
// `EditableLabel.java`). Nothing here actually depends on the exact numbers, shapes compare
// options with `==`, never parse the payload back out of `.circ` text (the SVG codec spells
// alignment out as `text-anchor`/`dominant-baseline` strings, not this attribute's stored
// name), but they are reproduced for fidelity for the class-hierarchy `Attribute<AttributeOption>`
// they would produce.

import LogisimKernel

/// `com.cburch.draw.shapes.DrawAttr`.
public enum DrawAttr {
  // MARK: - Fonts

  public static let font = Attributes.forFont("font")

  // MARK: - Alignment options

  public static let halignLeft = AttributeOption(value: Int32(2))
  public static let halignCenter = AttributeOption(value: Int32(0))
  public static let halignRight = AttributeOption(value: Int32(4))

  public static let valignTop = AttributeOption(value: Int32(8))
  public static let valignMiddle = AttributeOption(value: Int32(9))
  public static let valignBaseline = AttributeOption(value: Int32(10))
  public static let valignBottom = AttributeOption(value: Int32(11))

  public static let halignment = Attributes.forOption(
    "halign", choices: [halignLeft, halignCenter, halignRight])
  public static let valignment = Attributes.forOption(
    "valign", choices: [valignTop, valignMiddle, valignBaseline, valignBottom])

  // MARK: - Paint type

  public static let paintStroke = AttributeOption(value: "stroke")
  public static let paintFill = AttributeOption(value: "fill")
  public static let paintStrokeFill = AttributeOption(value: "both")

  public static let paintType = Attributes.forOption(
    "paintType", choices: [paintStroke, paintFill, paintStrokeFill])

  // MARK: - Stroke / fill

  public static let strokeWidth = Attributes.forIntegerRange("stroke-width", start: 1, end: 8)
  public static let strokeColor = Attributes.forColor("stroke")
  public static let fillColor = Attributes.forColor("fill")
  /// `DrawAttr.TEXT_DEFAULT_FILL`: a second `Attribute<ColorSpec>` sharing the `"fill"` name,
  /// used only as the text tool's default-attributes key (distinct `Attribute` identity from
  /// `fillColor`, exactly as upstream keeps two distinct `Attribute` objects that happen to
  /// share a `.circ` name).
  public static let textDefaultFill = Attributes.forColor("fill")

  public static let cornerRadius = Attributes.forIntegerRange("rx", start: 1, end: 1000)

  // MARK: - Attribute lists

  /// `DrawAttr.ATTRS_TEXT`.
  public static let attrsText: [AnyAttribute] = [font, halignment, valignment, fillColor]
  /// `DrawAttr.ATTRS_TEXT_TOOL`.
  public static let attrsTextTool: [AnyAttribute] = [font, halignment, valignment, textDefaultFill]
  /// `DrawAttr.ATTRS_STROKE` (line, polyline).
  public static let attrsStroke: [AnyAttribute] = [strokeWidth, strokeColor]

  private static let attrsFillStroke: [AnyAttribute] = [paintType, strokeWidth, strokeColor]
  private static let attrsFillFill: [AnyAttribute] = [paintType, fillColor]
  private static let attrsFillBoth: [AnyAttribute] = [paintType, strokeWidth, strokeColor, fillColor]

  private static let attrsRRectStroke: [AnyAttribute] = [
    paintType, strokeWidth, strokeColor, cornerRadius,
  ]
  private static let attrsRRectFill: [AnyAttribute] = [paintType, fillColor, cornerRadius]
  private static let attrsRRectBoth: [AnyAttribute] = [
    paintType, strokeWidth, strokeColor, fillColor, cornerRadius,
  ]

  /// `DrawAttr.getFillAttributes(AttributeOption)`, rectangle, oval, polygon.
  public static func fillAttributes(for paint: AttributeOption) -> [AnyAttribute] {
    if paint == paintStroke { return attrsFillStroke }
    if paint == paintFill { return attrsFillFill }
    return attrsFillBoth
  }

  /// `DrawAttr.getRoundRectAttributes(AttributeOption)`.
  public static func roundRectAttributes(for paint: AttributeOption) -> [AnyAttribute] {
    if paint == paintStroke { return attrsRRectStroke }
    if paint == paintFill { return attrsRRectFill }
    return attrsRRectBoth
  }
}
