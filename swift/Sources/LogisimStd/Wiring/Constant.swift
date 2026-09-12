// Constant.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.wiring.Constant),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// The wiring template, and the second of the two hand-written-attribute-set shapes (the other is
// `GateAttributes`). Constant is small but it exercises the awkward corners:
//
//   * an attribute whose stored form is NOT what it reads back as (`ATTR_VALUE` is an
//     `Attribute<Long>` over a `Value` field);
//   * a cross-attribute side effect (changing WIDTH rewrites VALUE);
//   * `attributesMayAlsoBeChanged`, which the attribute table and the undo stack both need.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `Constant.ConstantAttributes`.
///
/// Three fields, three attributes, and a deliberate asymmetry: `value` is stored as a `Value`
/// but read and written as a `Long`, so setting WIDTH silently re-derives it.
public final class ConstantAttributes: AbstractAttributeSet {

  public var facing: Direction = .east
  public var width: BitWidth = .one
  public var value: Value = .trueValue

  public override init() {
    super.init()
  }

  public override var attributes: [AnyAttribute] { Constant.attributeList }

  public override func rawValue(_ attribute: AnyAttribute) -> AttributeValue? {
    if attribute === StdAttr.facing { return StdAttr.facing.encode(facing) }
    if attribute === StdAttr.width { return StdAttr.width.encode(width) }
    // `Long.valueOf(value.toLongValue())`; the stored `Value` is never handed out directly.
    if attribute === Constant.attrValue { return .long(value.toLongValue()) }
    return nil
  }

  public override func setRawValue(
    _ attribute: AnyAttribute, _ newValue: AttributeValue?
  ) throws {
    if attribute === StdAttr.facing {
      guard let decoded = newValue.flatMap(StdAttr.facing.decode) else {
        throw ComponentError.unsupportedAttributeValue(
          factory: Constant.id, attribute: attribute.name)
      }
      facing = decoded
    } else if attribute === StdAttr.width {
      guard let decoded = newValue.flatMap(StdAttr.width.decode) else {
        throw ComponentError.unsupportedAttributeValue(
          factory: Constant.id, attribute: attribute.name)
      }
      width = decoded
      // Sign-extend (or truncate) the existing value into the new width, replicating the old
      // value's top bit. Note `value.get(value.getWidth() - 1)` is evaluated against the OLD
      // width, which is what makes this a sign extension rather than a zero fill.
      value = value.extendWidth(width.width, value.get(value.getWidth() - 1))
    } else if attribute === Constant.attrValue {
      guard case .long(let raw)? = newValue else {
        throw ComponentError.unsupportedAttributeValue(
          factory: Constant.id, attribute: attribute.name)
      }
      value = Value.createKnown(width, raw)
    } else {
      // `throw new IllegalArgumentException("unknown attribute " + attr)`
      throw AttributeSetError.attributeAbsent(name: attribute.name)
    }
    // Upstream passes `null` for the old value on every attribute, including LABEL; Constant
    // has no label. Preserved.
    fireAttributeValueChanged(attribute, value: newValue, oldValue: nil)
  }

  /// `attributesMayAlsoBeChanged(Attribute<V>, V)`.
  ///
  /// Declares that writing WIDTH will also move VALUE, so the attribute table refreshes the
  /// value row and the undo stack records both. The `Objects.equals` guard means a no-op write
  /// declares nothing.
  public override func attributesMayAlsoBeChanged<V>(
    _ attribute: Attribute<V>, _ newValue: V?
  ) -> [AnyAttribute]? {
    guard attribute === StdAttr.width else { return nil }
    if rawValue(attribute) == newValue.map(attribute.encode) { return nil }
    return [Constant.attrValue]
  }

  public override func makeCopyInstance() -> AbstractAttributeSet {
    ConstantAttributes()
  }

  /// Java's `clone()` copies the fields via `Object.clone()` and `copyInto` then does the rest;
  /// Swift has no `Object.clone`, so the copy is explicit. See `GateAttributes.copyInto` for
  /// why leaving this empty (as the Java text does for gates) would be a real bug here.
  public override func copyInto(_ destination: AbstractAttributeSet) {
    guard let destination = destination as? ConstantAttributes else { return }
    destination.facing = facing
    destination.width = width
    destination.value = value
  }
}

/// `com.cburch.logisim.std.wiring.Constant`.
public final class Constant: InstanceFactoryBase {

  /// `Constant._ID`. Do not change, `.circ` files reference it.
  public static let id = "Constant"

  /// `Constant.ATTR_VALUE`: written to `.circ` in hex, e.g. `val="0xff"`.
  public static let attrValue: Attribute<Int64> = Attributes.forHexLong("value")

  /// `Constant.ATTRIBUTES`.
  static let attributeList: [AnyAttribute] = [StdAttr.facing, StdAttr.width, Constant.attrValue]

  /// Java's `public static final InstanceFactory FACTORY = new Constant()`.
  public static let factory = Constant()

  public init() {
    super.init(Constant.id)
    setFacingAttribute(StdAttr.facing)
    // No `setAttributes`; `createAttributeSet()` builds a bespoke set, which is exactly what
    // upstream's `attrs == null` state means. Leaving `attributeTemplate` empty is required:
    // a non-empty template makes `defaultAttributeValue` answer only from the template.
  }

  public override func createAttributeSet() -> any AttributeSet {
    ConstantAttributes()
  }

  public override func validateAttributeSet(_ attributes: any AttributeSet) throws {
    guard attributes is ConstantAttributes else {
      throw ComponentError.wrongAttributeSet(factory: Constant.id)
    }
  }

  /// `getOffsetBounds(AttributeSet)`: one hex digit per four bits, 7 pixels each plus 7.
  ///
  /// Upstream ends with `else throw new IllegalArgumentException("unrecognized arguments")`,
  /// which is dead code: `Direction` has exactly four values and all four are handled. The
  /// Swift `switch` is exhaustive, so the throw disappears with nothing lost.
  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let facing = attributes[StdAttr.facing, default: .east]
    let width = attributes[StdAttr.width, default: .one]
    let chars = (width.width + 3) / 4
    let w = 7 + 7 * chars
    switch facing {
    case .east: return Bounds.create(-w, -8, w, 16)
    case .west: return Bounds.create(0, -8, w, 16)
    case .south: return Bounds.create(-w / 2, -16, w, 16)
    case .north: return Bounds.create(-w / 2, 0, w, 16)
    }
  }

  /// `updatePorts(Instance)`: one output at the component's own location.
  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    [Port(0, 0, .output, StdAttr.width)]
  }

  public override func propagate(_ state: any InstanceState) throws {
    let width = state.attributeValue(StdAttr.width, default: .one)
    let value = state.attributeValue(Constant.attrValue, default: 0)
    state.setPort(0, Value.createKnown(width, value), 1)
  }

  // NOT PORTED: the ExpressionComputer feature (`ConstantExpression`): analyze path.
  // NOT PORTED: paintIcon: the toolbar icon (see `Gates/AbstractGate.swift`'s header).

  // MARK: Painting (Constant.java:190-270)

  /// `Constant.BACKGROUND_COLOR`, `new Color(230, 230, 230)`.
  static let backgroundColor = SceneColor.rgba(RGBA(r: 230, g: 230, b: 230))

  /// `Constant.DEFAULT_FONT`: `new Font("monospaced", Font.PLAIN, 12)`. Monospaced on purpose:
  /// a constant's glyphs are hex digits and have to line up between neighbouring components.
  static let defaultFont = SceneFont(family: .monospaced, size: 12)

  /// `paintGhost(InstancePainter)`.
  ///
  /// The ghost shows the raw attribute as bare hex, `Long.toHexString(v)`, which is
  /// **unsigned** and has no width padding, whereas the placed component shows
  /// `Value.toHexString()`, which is width-aware. The two genuinely differ (a 4-bit constant of
  /// -1 ghosts as `ffffffffffffffff` and settles as `f`), and that is upstream's behaviour.
  public func paintGhost(_ painter: InstancePainter) {
    let v = painter.attributeValue(Constant.attrValue, default: 0)
    let vStr = String(UInt64(bitPattern: v), radix: 16)
    let bds = offsetBounds(painter.attributeSet)

    let g = painter.g
    g.strokeWidth = 2
    g.fillOval(-2, -2, 4, 4)
    let savedFont = g.font
    g.font = Constant.defaultFont
    g.drawCenteredText(vStr, x: bds.x + bds.width / 2, y: bds.y + bds.height / 2 - 2)
    g.font = savedFont
  }

  /// `paintInstance(InstancePainter)`.
  ///
  /// Note the `- 2` on the text's y: the glyph sits two above the box's centre, and dropping it
  /// puts every constant in a schematic a pixel and a half low.
  public func paintInstance(_ painter: InstancePainter) {
    let bds = painter.offsetBounds
    let width = painter.attributeValue(StdAttr.width, default: .one)
    let longValue = painter.attributeValue(Constant.attrValue, default: 0)
    let v = Value.createKnown(width, longValue)
    let loc = painter.location
    let x = loc.x
    let y = loc.y

    let g = painter.g
    if painter.shouldDrawColor {
      g.color = Constant.backgroundColor
      g.fillRect(x + bds.x, y + bds.y, bds.width, bds.height)
    }
    let savedFont = g.font
    if v.width == 1 {
      if painter.shouldDrawColor { g.color = painter.color(of: v) }
      g.font = Constant.defaultFont
      g.drawCenteredText(
        v.description, x: x + bds.x + bds.width / 2, y: y + bds.y + bds.height / 2 - 2)
    } else {
      g.color = .black
      g.font = Constant.defaultFont
      g.drawCenteredText(
        v.toHexString(), x: x + bds.x + bds.width / 2, y: y + bds.y + bds.height / 2 - 2)
    }
    g.font = savedFont
    painter.drawPorts()
  }
}

extension Constant: InstancePaintable {}
