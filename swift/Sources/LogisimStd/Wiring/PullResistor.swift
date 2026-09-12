// PullResistor.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.wiring.PullResistor),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── This is one of the four builtin tools the M2 migration gate is blocked on ───────────────
//
// `Pull Resistor`'s attribute defaults (`FACING = SOUTH`, `ATTR_PULL_TYPE = "0"`) are
// byte-visible `.circ` output: `XmlWriter` omits an attribute's `<a>` element exactly when the
// stored value equals the factory default it gets from this file. Get either default wrong and
// every file naming a Pull Resistor mismatches the oracle. See `decisions.md` D-block above
// `WHY THIS FAMILY MATTERS`.
//
// ── SEAM (do not implement here) ─────────────────────────────────────────────────────────────
//
// `propagate` is correctly a no-op; Java's comment says "handled by CircuitWires" and that is
// true here too: a pull resistor does not drive its own port through the normal propagation
// path. What CircuitWires needs from this file is `PullResistor.pullValue(for:)`, the Swift
// shape of `PullResistor.getPullValue(Instance)` (`CircuitWires.java:752`,
// `b.addPullValue(PullResistor.getPullValue(instance))`). That call site lives in
// `CircuitWires`, owned by the M3 Simulation workflow (`LogisimKernel/Simulation/`), which this
// task must not touch. When it lands, the equivalent Swift call is:
//
//     bundle.addPullValue(PullResistor.pullValue(for: component))
//
// for every placed component whose `factory === PullResistor.factory`, exactly where Java folds
// each pull resistor's value into the bus's combined value. **Do not "fix" `Value.combine`'s
// `combine(TRUE, UNKNOWN) == ERROR`** while wiring this; that is deliberate upstream semantics
// (D1 in the task brief / M1 log), not a bug a pull resistor's presence should paper over.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `PullResistor.ATTR_PULL_TYPE`'s choice list, expressed as the native-enum shape D5 prefers
/// for new component ports (`AttributeOptionValue`) rather than the raw `AttributeOption` Java
/// shape `Attributes.forOption(name, choices:)` also supports.
///
/// Java's `AttributeOption` carries the pull `Value` itself as its `Object value` payload
/// (`new AttributeOption(Value.FALSE, "0", …)`), read back via `PullResistor.getPullValue`'s
/// `(Value) opt.getValue()`. `pullValue` below is that payload.
public enum PullType: String, AttributeOptionValue, CaseIterable, Sendable {
  /// `PullResistor.ATTR_PULL_TYPE`'s `"0"` choice: pull to `Value.FALSE`. **The factory default**
  /// (`ATTR_PULL_TYPE.parse("0")` in the Java constructor).
  case zero = "0"
  /// The `"1"` choice, pull to `Value.TRUE`.
  case one = "1"
  /// The `"X"` choice: pull to `Value.ERROR`. Yes, a pull resistor can be configured to pull a
  /// floating bus to a conflict; preserved as Java declares it.
  case error = "X"

  /// `AttributeOption.getValue()` narrowed to the `Value` it always is for this attribute.
  public var pullValue: Value {
    switch self {
    case .zero: return .falseValue
    case .one: return .trueValue
    case .error: return .errorValue
    }
  }
}

/// `com.cburch.logisim.std.wiring.PullResistor`.
public final class PullResistor: InstanceFactoryBase {

  /// `PullResistor._ID`. Do not change, `.circ` files reference it.
  public static let id = "Pull Resistor"

  /// `PullResistor.ATTR_PULL_TYPE`. Java's `.circ` token is `"pull"`.
  public static let attrPullType: Attribute<PullType> = Attributes.forOption("pull")

  /// Java's `public static final PullResistor FACTORY = new PullResistor()`.
  public static let factory = PullResistor()

  public init() {
    super.init(PullResistor.id)
    setAttributes([
      StdAttr.facing.binding(.south),
      PullResistor.attrPullType.binding(.zero),
    ])
    setFacingAttribute(StdAttr.facing)
    setPorts([Port(0, 0, .inout_, BitWidth.unknown)])
  }

  /// `PullResistor.getPullValue(AttributeSet)` / `getPullValue(Instance)`, collapsed per D3:
  /// `Instance` is gone, so callers reach this from either an attribute set directly or a
  /// component. See the file-header SEAM note for the one real caller (`CircuitWires`).
  public static func pullValue(for attributes: any AttributeSet) -> Value {
    attributes[PullResistor.attrPullType, default: .zero].pullValue
  }

  /// `getPullValue(Instance)` over a placed component.
  public static func pullValue(for component: any Component) -> Value {
    pullValue(for: component.attributeSet)
  }

  /// `getOffsetBounds(AttributeSet)`. Java's trailing `else` covers SOUTH (also the default
  /// facing); the Swift `switch` is exhaustive over the four `Direction` cases, so nothing is
  /// lost by not writing an explicit `default`.
  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let facing = attributes[StdAttr.facing, default: .south]
    switch facing {
    case .east: return Bounds.create(-42, -6, 42, 12)
    case .west: return Bounds.create(0, -6, 42, 12)
    case .north: return Bounds.create(-6, 0, 12, 42)
    case .south: return Bounds.create(-6, -42, 12, 42)
    }
  }

  // NOT PORTED: `instanceAttributeChanged`: both Java branches (`FACING` -> `recomputeBounds()`,
  // `ATTR_PULL_TYPE` -> `fireInvalidated()`) are automatic/paint concerns the chassis already
  // covers; see `InstanceFactory.swift`'s file header and `PATTERNS.md` section 0. Bounds are
  // derived on demand from `offsetBounds`, and a repaint request belongs to M6.

  public override func propagate(_ state: any InstanceState) throws {
    // `PullResistor.propagate`: "nothing to do - handled by CircuitWires". See the SEAM note
    // above the imports for exactly what CircuitWires must call instead.
  }

  // NOT PORTED: paintIcon: the toolbar icon (see `Gates/AbstractGate.swift`'s header).

  // MARK: Painting (PullResistor.java:108-178)

  /// `paintBase(InstancePainter, Value pullValue, Color inColor, Color outColor)`.
  ///
  /// The value label is drawn **before** the rotation, in the unrotated frame, which is why it
  /// stays upright whichever way the resistor faces, and why each facing needs its own
  /// hand-placed anchor and alignment rather than one rotated position.
  ///
  /// The rotation is `SOUTH.toRadians() - facing.toRadians()`, not the `EAST`-relative form the
  /// rest of this family uses: the body below is drawn pointing *up* from the origin, so south
  /// is its natural orientation.
  ///
  /// `inColor`/`outColor` are `nil` for a ghost, and the `color &&` guard means a print view
  /// also ignores them.
  private func paintBase(
    _ painter: InstancePainter, _ pullValue: Value, _ inColor: SceneColor?,
    _ outColor: SceneColor?
  ) {
    let color = painter.shouldDrawColor
    let facing = painter.attributeValue(StdAttr.facing, default: .north)
    let g = painter.g
    let baseColor = painter.componentColor
    g.strokeWidth = 3
    if color, let inColor { g.color = inColor }
    switch facing {
    case .east:
      g.drawText(pullValue.toDisplayString(), x: -32, y: 0, halign: .right, valign: .center)
    case .west:
      g.drawText(pullValue.toDisplayString(), x: 32, y: 0, halign: .left, valign: .center)
    case .north:
      g.drawText(pullValue.toDisplayString(), x: 0, y: 32, halign: .center, valign: .top)
    case .south:
      g.drawText(pullValue.toDisplayString(), x: 0, y: -32, halign: .center, valign: .baseline)
    }

    let rotate = Direction.south.toRadians() - facing.toRadians()
    let rotated = rotate != 0.0
    if rotated { g.pushRotate(rotate) }
    g.drawLine(0, -30, 0, -26)
    g.drawLine(-6, -30, 6, -30)
    if color, let outColor { g.color = outColor }
    g.drawLine(0, -4, 0, 0)
    g.color = baseColor
    g.strokeWidth = 2
    if painter.gateShape == .shaped {
      g.drawPolyline([0, -5, 5, -5, 5, -5, 0], [-25, -23, -19, -15, -11, -7, -5])
    } else {
      g.drawRect(-5, -25, 10, 20)
    }
    if rotated { g.popTransform() }
  }

  public func paintGhost(_ painter: InstancePainter) {
    let pull = PullResistor.pullValue(for: painter.attributeSet)
    paintBase(painter, pull, nil, nil)
  }

  public func paintInstance(_ painter: InstancePainter) {
    let loc = painter.location
    let g = painter.g
    g.pushTranslate(loc.x, loc.y)
    let pull = PullResistor.pullValue(for: painter.attributeSet)
    let actual = painter.portValue(0)
    paintBase(painter, pull, painter.color(of: pull), painter.color(of: actual))
    g.popTransform()
    painter.drawPorts()
  }
}

extension PullResistor: InstancePaintable {}
