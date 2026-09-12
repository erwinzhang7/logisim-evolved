// NotGate.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.gates.NotGate),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Like `Buffer`, this is a plain `InstanceFactory` and not an `AbstractGate`: see
// `Buffer.swift`'s header for why. It additionally publishes its own two-valued size attribute,
// which `ControlledBuffer` borrows for its inverter form.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.gates.NotGate`.
public final class NotGate: InstanceFactoryBase {

  /// `NotGate._ID`. Do NOT change: `.circ` files reference it by name.
  public static let id = "NOT Gate"

  // MARK: Attribute identities

  /// `NotGate.SIZE_NARROW` / `SIZE_WIDE`: `new AttributeOption(Integer, …)`, so the `.circ`
  /// token is the number itself ("20" / "30").
  public static let sizeNarrow = AttributeOption(value: Int32(20))
  public static let sizeWide = AttributeOption(value: Int32(30))

  /// `NotGate.ATTR_SIZE`.
  ///
  /// A **different attribute object** from `GateAttributes.size` that happens to share the
  /// `.circ` token `"size"` and to have different choices (20/30 rather than 30/50/70). Two
  /// distinct identities under one serialized name, exactly like `StdAttr.trigger` /
  /// `StdAttr.edgeTrigger`. Preserved; nothing can confuse them because a component's attribute
  /// list only ever contains one of the two.
  public static let size: Attribute<AttributeOption> = Attributes.forOption(
    "size", choices: [sizeNarrow, sizeWide])

  /// Java's `private static final String RECT_LABEL = "1"`: paint only, kept for M6.
  static let rectLabel = "1"

  /// Java's `public static final InstanceFactory FACTORY = new NotGate()`.
  public static let factory = NotGate()

  public init() {
    super.init(NotGate.id)
    setAttributes([
      StdAttr.facing.binding(Direction.east),
      StdAttr.width.binding(BitWidth.one),
      NotGate.size.binding(NotGate.sizeWide),
      GateAttributes.output.binding(GateAttributes.output01),
      StdAttr.label.binding(""),
      StdAttr.labelFont.binding(StdAttr.defaultLabelFont),
    ])
    setFacingAttribute(StdAttr.facing)
    // `setKeyConfigurator(new BitWidthConfigurator(StdAttr.WIDTH))`, UI (D9). Not ported.
  }

  // MARK: Geometry

  /// `getOffsetBounds(AttributeSet)`.
  ///
  /// Note the narrow/wide split is on `ATTR_SIZE`, and that Java compares it against the
  /// `SIZE_NARROW` singleton by reference; `AttributeOption` is a struct here with distinct
  /// names, so the structural comparison agrees (PATTERNS.md §0).
  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let facing = attributes.getValue(StdAttr.facing) ?? .east
    if attributes[NotGate.size] == NotGate.sizeNarrow {
      switch facing {
      case .south: return Bounds.create(-9, -20, 18, 20)
      case .north: return Bounds.create(-9, 0, 18, 20)
      case .west: return Bounds.create(0, -9, 20, 18)
      case .east: return Bounds.create(-20, -9, 20, 18)
      }
    } else {
      switch facing {
      case .south: return Bounds.create(-9, -30, 18, 30)
      case .north: return Bounds.create(-9, 0, 18, 30)
      case .west: return Bounds.create(0, -9, 30, 18)
      case .east: return Bounds.create(-30, -9, 30, 18)
      }
    }
  }

  /// `configurePorts(Instance)` as a pure function (PATTERNS.md §0).
  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    let facing = attributes.getValue(StdAttr.facing) ?? .east
    let dx = attributes[NotGate.size] == NotGate.sizeNarrow ? -20 : -30
    let out = Location.create(0, 0, hasToSnap: true).translate(facing, dx)
    return [
      Port(0, 0, .output, StdAttr.width),
      Port(out.x, out.y, .input, StdAttr.width),
    ]
  }

  /// `hasThreeStateDrivers(AttributeSet)`.
  public override func hasThreeStateDrivers(_ attributes: any AttributeSet) -> Bool {
    guard attributes.containsAttribute(GateAttributes.output) else { return false }
    return attributes[GateAttributes.output] != GateAttributes.output01
  }

  // MARK: Propagation

  /// `propagate(InstanceState)`. Note the NOT happens *before* `Buffer.repair`, so a partly
  /// undefined input is inverted and only then collapsed to ERROR.
  public override func propagate(_ state: any InstanceState) throws {
    let input = state.portValue(1)
    var out = input.not()
    out = try Buffer.repair(state, out)
    state.setPort(0, out, GateAttributes.delay)
  }

  // MARK: The ExpressionComputer feature

  /// `getInstanceFeature(Instance, ExpressionComputer.class)` (`NotGate.java:141-157`).
  ///
  /// Bit *b* of the output is `not` of bit *b* of the input. Note this is the *symbolic* path
  /// and it does **not** mirror `propagate`'s ordering subtlety: propagation inverts first and
  /// then runs `Buffer.repair`, which can collapse a partly-undefined input to `ERROR`; an
  /// expression has no undefined value to collapse, so there is nothing for the repair step to
  /// do here. Upstream's computer is likewise a bare `Expressions.not`.
  public override func instanceFeature(
    _ key: ComponentFeatureKey, _ component: StdInstanceComponent
  ) -> Any? {
    guard key == .expressionComputer else {
      return super.instanceFeature(key, component)
    }
    let width = (component.attributeSet.getValue(StdAttr.width) ?? .one).width
    let ends = component.ends
    return ClosureExpressionComputer { map in
      guard ends.indices.contains(0), ends.indices.contains(1) else { return }
      for bit in 0..<width {
        guard let expression = map.expression(at: ends[1].location, bit: bit) else { continue }
        map.put(ends[0].location, bit: bit, map.algebra.not(expression))
      }
    }
  }

  // NOT PORTED: getHDLName: D11.
  // NOT PORTED: paintIcon: the toolbar icon (see AbstractGate's header).

  // MARK: Painting (NotGate.java:47-69, :186-269)

  /// `configureLabel(Instance, boolean isRectangular, Location control)`, as the on-demand
  /// placement `InstancePainter` asks for.
  ///
  /// Shared with `Buffer` and `ControlledBuffer`, which is why it is `static` here exactly as
  /// upstream has it. The `control` argument is what makes it shared: a controlled buffer's
  /// enable line comes in at the top edge, and when it lands on the same `y` as the bounds top
  /// the label has to shift right past it instead of centring, or the two overlap.
  public static func labelPlacement(
    _ painter: InstancePainter, isRectangular: Bool, control: Location?
  ) -> LabelPlacement {
    let facing = painter.attributeValue(StdAttr.facing, default: .east)
    let bds = painter.bounds
    let x: Int
    let y: Int
    let halign: HAlign
    if facing == .north || facing == .south {
      x = bds.x + bds.width / 2 + 2
      y = bds.y - 2
      halign = .left
    } else {  // west or east
      y = isRectangular ? bds.y - 2 : bds.y
      if let control, control.y == bds.y {
        // the control line will get in the way
        x = control.x + 2
        halign = .left
      } else {
        x = bds.x + bds.width / 2
        halign = .center
      }
    }
    return LabelPlacement(x: x, y: y, halign: halign, valign: .baseline)
  }

  public func labelPlacement(_ painter: InstancePainter) -> LabelPlacement? {
    NotGate.labelPlacement(
      painter, isRectangular: painter.gateShape == .rectangular, control: nil)
  }

  /// `paintRectangularBase(Graphics, InstancePainter)`: the IEC box, its `1`, and the output
  /// bubble. Two hard-coded geometries, one per `ATTR_SIZE` option.
  private func paintRectangularBase(_ painter: InstancePainter) {
    let g = painter.g
    g.strokeWidth = 2
    if painter.attributeValue(NotGate.size) == NotGate.sizeNarrow {
      g.drawRect(-20, -9, 14, 18)
      g.drawCenteredText(NotGate.rectLabel, x: -13, y: 0)
      g.drawOval(-6, -3, 6, 6)
    } else {
      g.drawRect(-30, -9, 20, 18)
      g.drawCenteredText(NotGate.rectLabel, x: -20, y: 0)
      g.drawOval(-10, -5, 9, 9)
    }
    g.strokeWidth = 1
  }

  /// `paintBase(InstancePainter)`.
  private func paintBase(_ painter: InstancePainter) {
    let g = painter.g
    let facing = painter.attributeValue(StdAttr.facing)
    let loc = painter.location
    g.pushTranslate(loc.x, loc.y)
    // Upstream's guard is `facing != null && facing != EAST`; a missing FACING attribute
    // leaves the body unrotated rather than throwing.
    let rotate = facing != nil && facing != .east
    if rotate { g.pushRotate(-facing!.toRadians()) }

    if painter.gateShape == .rectangular {
      paintRectangularBase(painter)
      // } else if shape == .din40700 {
      //   let width = painter.attributeValue(NotGate.size) == NotGate.sizeNarrow ? 20 : 30
      //   PainterDin.paintAnd(painter, width, 18, true)
      //
      // Commented out upstream at NotGate.java:210-212, and left commented here.
    } else {
      PainterShaped.paintNot(painter)
    }

    if rotate { g.popTransform() }
    g.popTransform()
  }

  /// `paintGhost(InstancePainter)`.
  public func paintGhost(_ painter: InstancePainter) {
    paintBase(painter)
  }

  /// `paintInstance(InstancePainter)`.
  public func paintInstance(_ painter: InstancePainter) {
    painter.g.color = painter.componentColor
    paintBase(painter)
    painter.drawPorts()
    painter.drawLabel()
  }
}

extension NotGate: InstancePaintable {}
extension NotGate: InstanceLabelProvider {}
