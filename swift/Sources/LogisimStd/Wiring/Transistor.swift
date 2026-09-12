// Transistor.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.wiring.Transistor),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Getting UNKNOWN vs ERROR right here matters more than usual ─────────────────────────────
//
// A transistor's output is tri-state: fully floating (`UNKNOWN`) when the gate is a definite
// "off" level, `ERROR` when the gate is itself unresolved and the input is fully defined
// (contention has no defined answer), and a bit-by-bit mix of the two when the gate is
// unresolved and the input is *also* partially unknown. Every branch below is transcribed
// exactly from `computeOutput`; do not collapse `createError`/`createUnknown` into each other,
// and do not "simplify" the per-bit masking loops into a single `Value.combine`.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `Transistor.ATTR_TYPE`'s choice list, as a native enum (D5's preferred shape for new
/// component ports). Tokens are Java's exact `AttributeOption` names (`"p"`, `"n"`).
public enum TransistorType: String, AttributeOptionValue, CaseIterable, Sendable {
  case p, n
}

/// `com.cburch.logisim.std.wiring.Transistor`.
public final class Transistor: InstanceFactoryBase {

  /// `Transistor._ID`. Do not change, `.circ` files reference it.
  public static let id = "Transistor"

  /// `Transistor.ATTR_TYPE`. **Default: `.p`** (`TYPE_P` is first in Java's defaults array).
  public static let attrType: Attribute<TransistorType> = Attributes.forOption("type")

  /// `Transistor.OUTPUT` / `.INPUT` / `.GATE`: port indices, kept as named constants because
  /// `computeOutput` and `ports(_:)` both address them positionally and are unreadable with bare
  /// integers (`PATTERNS.md`, arith family note, applies equally here).
  public static let outputPort = 0
  public static let inputPort = 1
  public static let gatePort = 2

  /// Java's `public static final InstanceFactory FACTORY`-style singleton, matching this port's
  /// convention (Java itself has no `Transistor.FACTORY`; `WiringLibrary` builds `new
  /// AddTool(new Transistor())` inline).
  public static let factory = Transistor()

  public init() {
    super.init(Transistor.id)
    setAttributes([
      Transistor.attrType.binding(.p),
      StdAttr.facing.binding(.east),
      StdAttr.selectLocation.binding(StdAttr.selectTopRight),
      StdAttr.width.binding(.one),
    ])
    setFacingAttribute(StdAttr.facing)
  }

  /// `updatePorts(Instance)`, transcribed as a pure function of `attributes` per the chassis
  /// contract (`InstanceFactory.swift`'s file header): attribute-dependent, so this overrides
  /// `ports(_:)` rather than calling `setPorts` once in `init`.
  ///
  /// Tool tips (`setToolTip` on each port, type-dependent wording) are dropped: `Port` carries
  /// none, by design (`Port.swift`'s file header).
  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    let facing = attributes[StdAttr.facing, default: .east]
    var dx = 0
    var dy = 0
    switch facing {
    case .north: dy = 1
    case .east: dx = -1
    case .south: dy = -1
    case .west: dx = 1
    }

    let selectLoc = attributes[StdAttr.selectLocation, default: StdAttr.selectTopRight]
    let flip = (facing == .north || facing == .west) == (selectLoc == StdAttr.selectTopRight)

    var ports = [Port](repeating: Port(0, 0, .output, StdAttr.width), count: 3)
    ports[Transistor.outputPort] = Port(0, 0, .output, StdAttr.width)
    ports[Transistor.inputPort] = Port(40 * dx, 40 * dy, .input, StdAttr.width)
    if flip {
      ports[Transistor.gatePort] = Port(20 * (dx + dy), 20 * (-dx + dy), .input, 1)
    } else {
      ports[Transistor.gatePort] = Port(20 * (dx - dy), 20 * (dx + dy), .input, 1)
    }
    return ports
  }

  /// `contains(Location, AttributeSet)`; a transistor's hit-test region is not its full
  /// rectangular `offsetBounds`; it is a 24-pixel manhattan-distance disc around a point 20
  /// pixels behind the component's own location (opposite its facing direction), intersected
  /// with the bounds. Preserved exactly, including testing the *bounds* first as Java's
  /// `super.contains` does.
  public override func contains(_ point: Location, _ attributes: any AttributeSet) -> Bool {
    guard offsetBounds(attributes).contains(point, 1) else { return false }
    let facing = attributes[StdAttr.facing, default: .east]
    let center = Location.create(0, 0, hasToSnap: true).translate(facing, -20)
    return center.manhattanDistance(to: point) < 24
  }

  /// `getOffsetBounds(AttributeSet)`.
  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let facing = attributes[StdAttr.facing, default: .east]
    let selectLoc = attributes[StdAttr.selectLocation, default: StdAttr.selectTopRight]
    let delta = selectLoc == StdAttr.selectTopRight ? 20 : 0
    switch facing {
    case .north: return Bounds.create(-20 + delta, 0, 20, 40)
    case .south: return Bounds.create(-20 + delta, -40, 20, 40)
    case .west: return Bounds.create(0, delta * -1, 40, 20)
    case .east: return Bounds.create(-40, delta * -1, 40, 20)
    }
  }

  // NOT PORTED: `instanceAttributeChanged`; every branch only calls `recomputeBounds()`
  // (automatic) and/or re-derives ports from `attributes` (automatic via `ports(_:)`'s diff) or
  // `fireInvalidated()` (paint, M6). See `InstanceFactory.swift`'s file header.

  public override func instanceFeature(
    _ key: ComponentFeatureKey, _ component: StdInstanceComponent
  ) -> Any? {
    guard key == .wireRepair else {
      return super.instanceFeature(key, component)
    }
    return ClosureWireRepair { _ in true }
  }

  /// `computeOutput(InstanceState)`.
  ///
  /// `desired` and `masked` are the *same* expression in Java (`type == TYPE_P ? FALSE : TRUE`
  /// computed twice); not a copy-paste bug. `desired` is the gate level that turns this
  /// transistor on; `masked` is the input level a *conducting* transistor of this type fails to
  /// pass cleanly (a rough model of a real pass-transistor: a PMOS pass gate conducts a strong 1
  /// but floats on a 0 fed through it; an NMOS the mirror image), so the two roles legitimately
  /// share one value per type. Both are computed once here rather than twice.
  /// The arithmetic itself, lifted out of `computeOutput(InstanceState)` so that `paintInstance`
  /// can reach it too. Java does not need this: `InstancePainter implements InstanceState`, so
  /// `computeOutput(painter)` just works there.
  static func computeOutput(
    width: BitWidth, gate: Value, input: Value, type: TransistorType
  ) throws -> Value {
    let desired: Value = type == .p ? .falseValue : .trueValue
    let masked = desired

    // `Value` equality below is a width-1 (`gate`, and each element of `getAll()`) compare.
    // Java compares these by reference against interned singletons; the port compares
    // structurally, which agrees at width <= 1 (`PATTERNS.md`, "Equality"). Noted once for this
    // file.
    if !gate.isFullyDefined() {
      if input.isFullyDefined() {
        return Value.createError(width)
      } else {
        var bits = input.getAll()
        for i in bits.indices where bits[i] != .unknownValue {
          bits[i] = .errorValue
        }
        return try Value.create(bits)
      }
    } else if gate != desired {
      return Value.createUnknown(width)
    } else {
      // masked inputs become Z outputs; all other inputs pass through to output.
      var bits = input.getAll()
      for i in bits.indices where bits[i] == masked {
        bits[i] = .unknownValue
      }
      return try Value.create(bits)
    }
  }

  /// `computeOutput(InstanceState)`, the port-reading wrapper.
  private func computeOutput(_ state: any InstanceState) throws -> Value {
    try Transistor.computeOutput(
      width: state.attributeValue(StdAttr.width, default: .one),
      gate: state.portValue(Transistor.gatePort),
      input: state.portValue(Transistor.inputPort),
      type: state.attributeValue(Transistor.attrType, default: .p))
  }

  /// `Transistor.propagate(InstanceState)`. `Value.create([Value])` throws (D13), so this does.
  public override func propagate(_ state: any InstanceState) throws {
    state.setPort(Transistor.outputPort, try computeOutput(state), 1)
  }

  // NOT PORTED: paintIcon: the toolbar icon (see `Gates/AbstractGate.swift`'s header).

  // MARK: Painting (Transistor.java:117-240)

  /// `drawInstance(InstancePainter, boolean isGhost)`.
  ///
  /// `m` is the mirror factor: `+1` when the gate lead comes in from the side `SELECT_LOC`
  /// puts it on, `-1` otherwise, and it multiplies every y in the body. That single sign is the
  /// whole of the flip, which is why nothing below is duplicated per orientation.
  ///
  /// The "platform" colour is deliberately not the output port's: it is `computeOutput`'s
  /// result, with UNKNOWN forced to UNKNOWN's own colour, so a transistor that is off shows
  /// its channel floating even when the wire it drives is being held by something else.
  private func drawInstance(_ painter: InstancePainter, isGhost: Bool) {
    let type = painter.attributeValue(Transistor.attrType, default: .p)
    let powerLoc = painter.attributeValue(StdAttr.selectLocation)
    let from = painter.attributeValue(StdAttr.facing, default: .east)
    let facing = from
    let flip =
      (facing == .north || facing == .west) == (powerLoc == StdAttr.selectTopRight)

    let radians = WiringPaint.rotationRadians(from: from)
    let m = flip ? 1 : -1

    let g = painter.g
    let loc = painter.location
    g.pushTranslate(loc.x, loc.y)
    g.pushRotate(radians)

    let gate: SceneColor
    let input: SceneColor
    let output: SceneColor
    let platform: SceneColor
    if !isGhost && painter.showState {
      gate = painter.color(of: painter.portValue(Transistor.gatePort))
      input = painter.color(of: painter.portValue(Transistor.inputPort))
      output = painter.color(of: painter.portValue(Transistor.outputPort))
      let out = paintOutput(painter)
      platform = out.isUnknown() ? painter.color(of: .unknownValue) : painter.color(of: out)
    } else {
      let base = g.color
      gate = base
      input = base
      output = base
      platform = base
    }

    // input and output lines
    g.strokeWidth = WiringPaint.wireWidth
    g.color = output
    g.drawLine(0, 0, -13, 0)
    g.drawLine(-13, m * 6, -13, 0)

    g.color = input
    g.drawLine(-40, 0, -27, 0)
    g.drawLine(-27, m * 6, -27, 0)

    // gate line
    g.color = gate
    if type == .p {
      g.drawLine(-20, m * 20, -20, m * 18)
      g.strokeWidth = 2
      g.drawOval(-20 - 3, m * 15 - 3, 6, 6)
    } else {
      g.drawLine(-20, m * 20, -20, m * 13)
      g.strokeWidth = 2
    }

    // draw platforms
    g.drawLine(-12, m * 12, -28, m * 12)  // gate platform
    g.color = platform
    g.drawLine(-9, m * 7, -31, m * 7)  // input/output platform

    // arrow (same color as platform)
    g.strokeWidth = 1
    g.drawLine(-21, m * 4, -19, m * 2)
    g.drawLine(-21, 0, -19, m * 2)

    g.popTransform()
    g.popTransform()
  }

  /// `computeOutput(painter)`; Java gets this for free because `InstancePainter implements
  /// InstanceState`; here the shared arithmetic lives in `computeOutput(width:gate:input:type:)`
  /// and both callers feed it.
  ///
  /// D13: `Value.create([Value])` throws, and a paint cannot. A throw here would need a
  /// >64-bit input, which `StdAttr.WIDTH` cannot express, so the fallback is unreachable.
  private func paintOutput(_ painter: InstancePainter) -> Value {
    let width = painter.attributeValue(StdAttr.width, default: .one)
    let out = try? Transistor.computeOutput(
      width: width,
      gate: painter.portValue(Transistor.gatePort),
      input: painter.portValue(Transistor.inputPort),
      type: painter.attributeValue(Transistor.attrType, default: .p))
    return out ?? Value.createError(width)
  }

  public func paintGhost(_ painter: InstancePainter) {
    drawInstance(painter, isGhost: true)
  }

  public func paintInstance(_ painter: InstancePainter) {
    drawInstance(painter, isGhost: false)
  }
}

extension Transistor: InstancePaintable {}
