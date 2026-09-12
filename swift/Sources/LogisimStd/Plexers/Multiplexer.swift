// Multiplexer.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.plexers.Multiplexer),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// The plexer template: a fixed attribute template, attribute-dependent bounds AND ports, a
// version-dependent default, and a `propagate` that reads a computed port index.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.plexers.Multiplexer`.
public final class Multiplexer: InstanceFactoryBase {

  /// `Multiplexer._ID`. Do not change, `.circ` files reference it.
  public static let id = "Multiplexer"

  public init() {
    super.init(Multiplexer.id)
    setAttributes([
      StdAttr.facing.binding(Direction.east),
      PlexersLibraryAttributes.size.binding(PlexersLibraryAttributes.sizeWide),
      StdAttr.selectLocation.binding(StdAttr.selectBottomLeft),
      PlexersLibraryAttributes.select.binding(PlexersLibraryAttributes.defaultSelect),
      StdAttr.width.binding(BitWidth.one),
      PlexersLibraryAttributes.disabled.binding(PlexersLibraryAttributes.disabledZero),
      PlexersLibraryAttributes.enable.binding(PlexersLibraryAttributes.defaultEnable),
    ])
    setFacingAttribute(StdAttr.facing)
    // `setKeyConfigurator` / `setIcon`, UI (D9) and M6.
  }

  /// `getDefaultAttributeValue(Attribute<?>, LogisimVersion)`.
  ///
  /// The one place in this family where the version argument is actually used: "for backward
  /// compatibility, after 2.6.4 the enable pin was 'enabled' by default up to and until 3.6.1".
  /// A file written by 3.6.1 or earlier that omits `enable` therefore gets `true`, and the
  /// `.circ` writer omits `enable` for a *current* file only when it is `false`. Dropping this
  /// silently adds or removes an enable port on every old file.
  public override func defaultAttributeValue(
    _ attribute: AnyAttribute, version: LogisimVersion
  ) -> AttributeValue? {
    if attribute === PlexersLibraryAttributes.enable {
      return .boolean(version.compare(to: LogisimVersion(3, 6, 1)) <= 0)
    }
    return super.defaultAttributeValue(attribute, version: version)
  }

  /// `hasThreeStateDrivers(AttributeSet)`.
  public override func hasThreeStateDrivers(_ attributes: any AttributeSet) -> Bool {
    attributes[PlexersLibraryAttributes.disabled] == PlexersLibraryAttributes.disabledFloating
  }

  // MARK: Geometry

  /// `getOffsetBounds(AttributeSet)`.
  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let size = attributes[PlexersLibraryAttributes.size]
    let wide = size == PlexersLibraryAttributes.sizeWide
    let dir = attributes[StdAttr.facing, default: .east]
    let select = attributes[
      PlexersLibraryAttributes.select, default: PlexersLibraryAttributes.defaultSelect]
    let inputs = javaIntBit(select.width)

    if inputs == 2 {
      let w = wide ? 30 : 20
      return Bounds.create(-w, -20, w, 40).rotate(from: .east, to: dir, xc: 0, yc: 0)
    } else {
      let w = wide ? 40 : 20
      let lengthAdjust = wide ? 0 : -5
      var offs = -(inputs / 2) * 10 - 10
      let length = inputs * 10 + 20 + lengthAdjust
      // "narrow isn't symmetrical when switching selector sides, rotating"
      if !wide && (dir == .south || dir == .west) { offs += 5 }
      return Bounds.create(-w, offs, w, length).rotate(from: .east, to: dir, xc: 0, yc: 0)
    }
  }

  /// `updatePorts(Instance)`.
  ///
  /// Port order is: the `2^select` data inputs, then select, then enable (only when
  /// `ATTR_ENABLE`), then the output last. `propagate` addresses all four groups arithmetically
  /// off `inputs`, so the order is a hard contract.
  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    let size = attributes[PlexersLibraryAttributes.size]
    let wide = size == PlexersLibraryAttributes.sizeWide
    let dir = attributes[StdAttr.facing, default: .east]
    let vertical = dir != .north && dir != .south
    let selectLoc = attributes[StdAttr.selectLocation]
    let botLeft = selectLoc == StdAttr.selectBottomLeft
    let selMult = botLeft ? 1 : -1
    let data = attributes[StdAttr.width, default: .one]
    let select = attributes[
      PlexersLibraryAttributes.select, default: PlexersLibraryAttributes.defaultSelect]
    let enable = attributes[PlexersLibraryAttributes.enable, default: false]

    let inputs = javaIntBit(select.width)
    var ps = [Port?](repeating: nil, count: inputs + (enable ? 3 : 2))
    var sel: Location

    if inputs == 2 {
      let w = (size == PlexersLibraryAttributes.sizeNarrow) ? 20 : 30
      let s = (size == PlexersLibraryAttributes.sizeNarrow) ? 10 : 20
      let end0: Location
      let end1: Location
      switch dir {
      case .west:
        end0 = Location.create(w, -10, hasToSnap: true)
        end1 = Location.create(w, 10, hasToSnap: true)
        sel = Location.create(s, selMult * 20, hasToSnap: true)
      case .north:
        end0 = Location.create(-10, w, hasToSnap: true)
        end1 = Location.create(10, w, hasToSnap: true)
        sel = Location.create(selMult * -20, s, hasToSnap: true)
      case .south:
        end0 = Location.create(-10, -w, hasToSnap: true)
        end1 = Location.create(10, -w, hasToSnap: true)
        sel = Location.create(selMult * -20, -s, hasToSnap: true)
      case .east:
        end0 = Location.create(-w, -10, hasToSnap: true)
        end1 = Location.create(-w, 10, hasToSnap: true)
        sel = Location.create(-s, selMult * 20, hasToSnap: true)
      }
      ps[0] = Port(end0.x, end0.y, .input, data.width)
      ps[1] = Port(end1.x, end1.y, .input, data.width)
    } else {
      let w = (size == PlexersLibraryAttributes.sizeNarrow) ? 20 : 40
      let s = (size == PlexersLibraryAttributes.sizeNarrow) ? 10 : 20
      var dx = -(inputs / 2) * 10
      var ddx = 10
      var dy = -(inputs / 2) * 10
      var ddy = 10
      switch dir {
      case .west:
        dx = w
        ddx = 0
        sel = Location.create(s, selMult * (dy + 10 * inputs), hasToSnap: true)
      case .north:
        dy = w
        ddy = 0
        sel = Location.create(selMult * dx, s, hasToSnap: true)
      case .south:
        dy = -w
        ddy = 0
        sel = Location.create(selMult * dx, -s, hasToSnap: true)
      case .east:
        dx = -w
        ddx = 0
        sel = Location.create(-s, selMult * (dy + 10 * inputs), hasToSnap: true)
      }
      // Note the `sel` expressions above capture `dx`/`dy` BEFORE this loop advances them, which
      // is why `sel` is computed inside the switch and not after.
      for i in 0..<inputs {
        ps[i] = Port(dx, dy, .input, data.width)
        dx += ddx
        dy += ddy
      }
    }

    if !wide && !vertical && botLeft && inputs > 2 {
      sel = sel.translate(-10, 0)  // left side, adjust selector left
    } else if !wide && vertical && !botLeft && inputs > 2 {
      sel = sel.translate(0, -10)  // top side, adjust selector up
    }
    let en = sel.translate(dir, 10)
    ps[inputs] = Port(sel.x, sel.y, .input, select.width)
    if enable {
      ps[inputs + 1] = Port(en.x, en.y, .input, BitWidth.one)
    }
    ps[ps.count - 1] = Port(0, 0, .output, data.width)

    // Every slot is written above for every reachable attribute combination; a nil would be a
    // defect in this transcription, which is the same class of error as Java's NPE at
    // `instance.setPorts`. D13's programmer-error carve-out.
    return ps.enumerated().map { index, port in
      guard let port else {
        preconditionFailure("Multiplexer: port \(index) of \(ps.count) was never assigned")
      }
      return port
    }
  }

  // MARK: Propagation

  /// `propagate(InstanceState)`.
  ///
  /// **Deviation (mechanism), same as every plexer:** Java's `en == Value.FALSE` and
  /// `en == Value.ERROR` are reference comparisons that work because one-bit values are
  /// interned. `Value` is a struct here, so these are structural: identical answers, since
  /// the enable port is declared one bit wide.
  ///
  /// Note the asymmetry upstream deliberately has: a FALSE enable produces the *disabled* value
  /// (zero or floating), but an ERROR enable produces an error output only when the enable port
  /// is actually connected; an unconnected enable pin reads ERROR on a bus and would otherwise
  /// wedge the mux.
  public override func propagate(_ state: any InstanceState) throws {
    let data = state.attributeValue(StdAttr.width, default: .one)
    let select = state.attributeValue(
      PlexersLibraryAttributes.select, default: PlexersLibraryAttributes.defaultSelect)
    let enable = state.attributeValue(PlexersLibraryAttributes.enable, default: false)
    let inputs = javaIntBit(select.width)
    let en = enable ? state.portValue(inputs + 1) : .trueValue

    let out: Value
    if en == .falseValue {
      let opt = state.attributeValue(PlexersLibraryAttributes.disabled)
      let base: Value = (opt == PlexersLibraryAttributes.disabledZero) ? .falseValue : .unknownValue
      // D13: `Value.repeat` throws (a multi-bit base, or a width over 64).
      out = try Value.repeat(base, data.width)
    } else if en == .errorValue && state.isPortConnected(inputs + 1) {
      out = Value.createError(data)
    } else {
      let sel = state.portValue(inputs)
      if sel.isFullyDefined() {
        // `sel` is masked to `select.width` bits, so this is always in 0..<inputs.
        out = state.portValue(Int(sel.toLongValue()))
      } else if sel.isErrorValue() {
        out = Value.createError(data)
      } else {
        out = Value.createUnknown(data)
      }
    }
    state.setPort(inputs + (enable ? 2 : 1), out, PlexersLibraryAttributes.delay)
  }

  // PAINT (M6): paintGhost / paintInstance / drawSelectCircle: the trapezoid, the "MUX" text,
  // the select-side dot and the "0" input marker. See Multiplexer.java:46-69, 164-261.
}
