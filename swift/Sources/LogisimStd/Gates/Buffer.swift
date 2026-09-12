// Buffer.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.gates.Buffer),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Not an `AbstractGate` ───────────────────────────────────────────────────────────────────
//
// Buffer and NOT extend `InstanceFactory` directly, not `AbstractGate`. That is not an
// oversight upstream: a one-input gate has no input count, no negation bubbles and no size
// table, so none of `GateAttributes` applies. They keep a plain fixed attribute template and
// override `getOffsetBounds`/`configurePorts` for the facing.
//
// `repair` lives here and is shared with `NotGate`; it is the whole of the "undefined inputs
// are an error" project option for these two components, standing in for the corresponding
// branch inside `AbstractGate.propagate`.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.gates.Buffer`.
public final class Buffer: InstanceFactoryBase {

  /// `Buffer._ID`. Do NOT change: `.circ` files reference it by name.
  public static let id = "Buffer"

  /// Java's `public static final InstanceFactory FACTORY = new Buffer()`.
  public static let factory = Buffer()

  public init() {
    super.init(Buffer.id)
    setAttributes([
      StdAttr.facing.binding(Direction.east),
      StdAttr.width.binding(BitWidth.one),
      GateAttributes.output.binding(GateAttributes.output01),
      StdAttr.label.binding(""),
      StdAttr.labelFont.binding(StdAttr.defaultLabelFont),
    ])
    setFacingAttribute(StdAttr.facing)
    // `setKeyConfigurator(new BitWidthConfigurator(StdAttr.WIDTH))` is the attribute-table key
    // handler; UI (D9). Not ported.
    //
    // Upstream also calls `setPorts([...])` in the constructor and then immediately replaces
    // the list from `configureNewInstance` → `configurePorts`. The chassis makes `ports(_:)` a
    // pure function of the attributes (PATTERNS.md §0), so only the computed form survives; the
    // constructor's east-facing list is exactly what `ports(_:)` returns for `facing == .east`.
  }

  // MARK: Static helpers

  /// `repair(InstanceState, Value)`; shared with `NotGate`.
  ///
  /// When the project option `ATTR_GATE_UNDEFINED` is `error`, every bit that is not fully
  /// defined becomes ERROR and the result is widened (with ERROR) to the component's own width.
  /// Otherwise the value passes through untouched. Either way the result goes through
  /// `AbstractGate.pullOutput`, which applies the 0/Z output behaviour.
  ///
  /// D13: `Value.create([Value])` and `pullOutput` both throw where Java throws catchably, so
  /// this throws.
  public static func repair(_ state: any InstanceState, _ v: Value) throws -> Value {
    let opts = state.projectOptions
    // Java: `opts.getValue(ATTR_GATE_UNDEFINED).equals(GATE_UNDEFINED_ERROR)`, which NPEs on a
    // project-less run. `InstanceState.projectOptions` is non-optional by construction (see its
    // header), and a missing attribute compares unequal rather than trapping.
    let errorIfUndefined = opts[Options.gateUndefined] == Options.gateUndefinedError

    let repaired: Value
    if errorIfUndefined {
      let vw = v.getWidth()
      let w = state.attributeValue(StdAttr.width, default: .one)
      let ww = w.width
      if vw == ww && v.isFullyDefined() { return v }
      var vs = [Value]()
      vs.reserveCapacity(max(ww, 0))
      for i in 0..<max(ww, 0) {
        let ini = i < vw ? v.get(i) : Value.errorValue
        vs.append(ini.isFullyDefined() ? ini : Value.errorValue)
      }
      repaired = try Value.create(vs)
    } else {
      repaired = v
    }

    // The attribute is always present, it is in the fixed template of both callers, so the
    // fallback is unreachable. Java would pass `null` through `pullOutput`, whose three
    // reference comparisons would all miss and which would then return `Value.create(getAll())`,
    // i.e. the value unchanged: the same answer `output01` gives.
    let outType = state.attributeValue(GateAttributes.output, default: GateAttributes.output01)
    return try AbstractGate.pullOutput(repaired, outType)
  }

  // MARK: Geometry

  /// `getOffsetBounds(AttributeSet)`.
  ///
  /// Java ends the chain with a bare `return` for EAST rather than testing it; the Swift
  /// `switch` is exhaustive over the four directions and says so explicitly.
  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let facing = attributes.getValue(StdAttr.facing) ?? .east
    switch facing {
    case .south: return Bounds.create(-9, -20, 18, 20)
    case .north: return Bounds.create(-9, 0, 18, 20)
    case .west: return Bounds.create(0, -9, 20, 18)
    case .east: return Bounds.create(-20, -9, 20, 18)
    }
  }

  /// `configurePorts(Instance)` as a pure function (PATTERNS.md §0).
  ///
  /// Port 0 is the output at the component's own location; port 1 is the input 20 units back
  /// along the facing.
  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    let facing = attributes.getValue(StdAttr.facing) ?? .east
    let out = Location.create(0, 0, hasToSnap: true).translate(facing, -20)
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

  public override func propagate(_ state: any InstanceState) throws {
    let input = try Buffer.repair(state, state.portValue(1))
    state.setPort(0, input, GateAttributes.delay)
  }

  // MARK: The ExpressionComputer feature

  /// `getInstanceFeature(Instance, ExpressionComputer.class)` (`Buffer.java:126-140`).
  ///
  /// A buffer is the identity on the expression path: bit *b* of the output carries exactly the
  /// expression on bit *b* of the input, with no wrapping node at all. The tri-state `ATTR_OUTPUT`
  /// behaviour that `propagate` honours through `Buffer.repair` has no expression form and
  /// upstream does not attempt one: a buffer configured for open-drain output still derives as
  /// the identity.
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
        // `if (e != null)`; an unconnected input leaves the output port untouched.
        guard let expression = map.expression(at: ends[1].location, bit: bit) else { continue }
        map.put(ends[0].location, bit: bit, expression)
      }
    }
  }

  // NOT PORTED: getHDLName: D11.
  // NOT PORTED: paintIcon: the toolbar icon (see AbstractGate's header).

  // MARK: Painting (Buffer.java:158-234)

  /// `paintBase(InstancePainter)`: an 18x18 IEC box carrying a `1`, or the ANSI triangle.
  ///
  /// The triangle's four points close back onto `(0, 0)`, so `drawPolyline` (not
  /// `drawPolygon`) with a repeated first point is what upstream draws and what is drawn here;
  /// the difference is visible at the tip, where a polygon would mitre and a polyline does not.
  private func paintBase(_ painter: InstancePainter) {
    let facing = painter.attributeValue(StdAttr.facing, default: .east)
    let loc = painter.location
    let g = painter.g
    g.pushTranslate(loc.x, loc.y)
    let rotate = facing != .east
    if rotate { g.pushRotate(-facing.toRadians()) }

    g.strokeWidth = 2
    if painter.gateShape == .rectangular {
      g.drawRect(-19, -9, 18, 18)
      g.drawCenteredText("1", x: -10, y: 0)
    } else {
      g.drawPolyline([0, -19, -19, 0], [0, -7, 7, 0])
    }

    if rotate { g.popTransform() }
    g.popTransform()
  }

  /// `configureLabel` is `NotGate.configureLabel(instance, false, null)` for a buffer:
  /// never the rectangular offset, never a control line. Buffer.java:102.
  public func labelPlacement(_ painter: InstancePainter) -> LabelPlacement? {
    NotGate.labelPlacement(painter, isRectangular: false, control: nil)
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

extension Buffer: InstancePaintable {}
extension Buffer: InstanceLabelProvider {}
