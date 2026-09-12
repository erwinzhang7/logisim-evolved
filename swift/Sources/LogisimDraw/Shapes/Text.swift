// Text.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/draw/shapes/Text.java. Copyright by the Logisim-evolution developers. This
// translation is a derivative work and is therefore licensed GPL-3.0-only. See LICENSE.md.
//
// Named `DrawText`, not `Text`; this codebase's UI layer may eventually import SwiftUI, whose
// `Text` view would otherwise collide (the only two shape names with a plausible SwiftUI clash;
// `Rectangle` gets the same treatment).

import LogisimKernel

/// `com.cburch.draw.shapes.Text`.
public final class DrawText: AbstractCanvasObject {
  private var label: EditableLabel

  public init(x: Int, y: Int, text: String) {
    // `DrawAttr.DEFAULT_FONT = new Font("SansSerif", Font.PLAIN, 12)`; `EditableLabel`'s own
    // defaults already match Java's private constructor (`LEFT`/`BASELINE`, `Color.BLACK`).
    self.label = EditableLabel(x: x, y: y, text: text, font: FontSpec(family: "SansSerif", size: 12))
    super.init()
  }

  /// Renderer hook: `EditableLabel.paint(Graphics)` minus the drawing, since text metrics start
  /// at zero until measured, see `TextMetrics.swift`.
  public func measure(using provider: TextMetricsProviding) {
    label.measure(using: provider)
  }

  public override func contains(_ loc: Location, assumeFilled: Bool) -> Bool {
    label.contains(loc.x, loc.y)
  }

  public override var attributes: [AnyAttribute] { DrawAttr.attrsText }

  public override var bounds: Bounds { label.bounds }

  public override var displayName: String { "Text" }

  public override func handles(_ gesture: HandleGesture?) -> [Handle] {
    let bds = bounds
    let x = bds.x
    let y = bds.y
    let w = bds.width
    let h = bds.height
    return [
      Handle(self, x, y), Handle(self, x + w, y), Handle(self, x + w, y + h), Handle(self, x, y + h),
    ]
  }

  public var location: Location { Location.create(label.x, label.y, hasToSnap: false) }

  /// Direct model access: this shape's own text content, distinct from
  /// `CanvasModel.setText(_:_:)`'s undo-tracked mutation.
  public var text: String {
    get { label.text }
    set { label.text = newValue }
  }

  public override func rawValue(_ attribute: AnyAttribute) -> AttributeValue? {
    if attribute === DrawAttr.font { return .font(label.font) }
    if attribute === DrawAttr.fillColor { return .color(label.color) }
    if attribute === DrawAttr.halignment {
      let option: AttributeOption
      switch label.horizontalAlignment {
      case .left: option = DrawAttr.halignLeft
      case .right: option = DrawAttr.halignRight
      case .center: option = DrawAttr.halignCenter
      }
      return .option(option)
    }
    if attribute === DrawAttr.valignment {
      let option: AttributeOption
      switch label.verticalAlignment {
      case .top: option = DrawAttr.valignTop
      case .bottom: option = DrawAttr.valignBottom
      case .baseline: option = DrawAttr.valignBaseline
      case .middle: option = DrawAttr.valignMiddle
      }
      return .option(option)
    }
    return nil
  }

  public override func setRawValue(_ attribute: AnyAttribute, _ value: AttributeValue?) throws {
    if attribute === DrawAttr.font {
      guard case .font(let font)? = value else { return }
      label.font = font
    } else if attribute === DrawAttr.fillColor {
      guard case .color(let color)? = value else { return }
      label.color = color
    } else if attribute === DrawAttr.halignment {
      guard case .option(let option)? = value, case .integer(let raw) = option.payload,
        let align = HorizontalTextAlign(rawValue: raw)
      else { return }
      label.horizontalAlignment = align
    } else if attribute === DrawAttr.valignment {
      guard case .option(let option)? = value, case .integer(let raw) = option.payload,
        let align = VerticalTextAlign(rawValue: raw)
      else { return }
      label.verticalAlignment = align
    }
  }

  public override func matches(_ other: CanvasObject) -> Bool {
    guard let that = other as? DrawText else { return false }
    return self.label == that.label
  }

  public override func matchesHashCode() -> Int { label.hashValue }

  public override func toSvgElement() -> SvgElement { SvgCreator.createText(self) }

  public override func translate(_ dx: Int, _ dy: Int) {
    label.setLocation(x: label.x + dx, y: label.y + dy)
  }

  public override func cloned() -> CanvasObject {
    let copy = DrawText(x: label.x, y: label.y, text: label.text)
    copy.label = label
    return copy
  }
}
