// Demultiplexer.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.plexers.Demultiplexer),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// HDL generation (`DemultiplexerHdlGeneratorFactory`, a private inner class in the same upstream
// file's package) is stripped; HDL is D11 backlog, not this workflow.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.plexers.Demultiplexer`.
public final class Demultiplexer: InstanceFactoryBase {

  /// `Demultiplexer._ID`. Do not change, `.circ` files reference it.
  public static let id = "Demultiplexer"

  public init() {
    super.init(Demultiplexer.id)
    setAttributes([
      StdAttr.facing.binding(Direction.east),
      StdAttr.selectLocation.binding(StdAttr.selectBottomLeft),
      PlexersLibraryAttributes.select.binding(PlexersLibraryAttributes.defaultSelect),
      StdAttr.width.binding(BitWidth.one),
      PlexersLibraryAttributes.tristate.binding(PlexersLibraryAttributes.defaultTristate),
      PlexersLibraryAttributes.disabled.binding(PlexersLibraryAttributes.disabledZero),
      PlexersLibraryAttributes.enable.binding(PlexersLibraryAttributes.defaultEnable),
    ])
    setFacingAttribute(StdAttr.facing)
    // `setKeyConfigurator` / `setIcon`, UI (D9) and M6.
  }

  /// `getDefaultAttributeValue(Attribute<?>, LogisimVersion)`. Same rule, and same comment, as
  /// `Multiplexer`.
  public override func defaultAttributeValue(
    _ attribute: AnyAttribute, version: LogisimVersion
  ) -> AttributeValue? {
    if attribute === PlexersLibraryAttributes.enable {
      return .boolean(version.compare(to: LogisimVersion(3, 6, 1)) <= 0)
    }
    return super.defaultAttributeValue(attribute, version: version)
  }

  /// `contains(Location, AttributeSet)`: the demultiplexer's trapezoid opens the opposite way
  /// from the multiplexer's, so the hit test is run against the *reversed* facing.
  public override func contains(_ point: Location, _ attributes: any AttributeSet) -> Bool {
    let facing = attributes[StdAttr.facing, default: .east].reverse()
    return PlexersLibraryAttributes.contains(point, offsetBounds(attributes), facing)
  }

  /// `hasThreeStateDrivers(AttributeSet)`.
  public override func hasThreeStateDrivers(_ attributes: any AttributeSet) -> Bool {
    attributes[PlexersLibraryAttributes.tristate, default: PlexersLibraryAttributes.defaultTristate]
      || attributes[PlexersLibraryAttributes.disabled] == PlexersLibraryAttributes.disabledFloating
  }

  // MARK: Geometry

  /// `getOffsetBounds(AttributeSet)`.
  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let facing = attributes[StdAttr.facing, default: .east]
    let select = attributes[
      PlexersLibraryAttributes.select, default: PlexersLibraryAttributes.defaultSelect]
    let outputs = javaIntBit(select.width)
    let bds =
      outputs == 2
      ? Bounds.create(0, -25, 30, 50)
      : Bounds.create(0, -(outputs / 2) * 10 - 10, 40, outputs * 10 + 20)
    return bds.rotate(from: .east, to: facing, xc: 0, yc: 0)
  }

  /// `updatePorts(Instance)`.
  ///
  /// Port order: the `2^select` data outputs, then select, then enable (only when
  /// `ATTR_ENABLE`), then the input last. `propagate` addresses all four groups arithmetically
  /// off `outputs`, so the order is a hard contract.
  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    let facing = attributes[StdAttr.facing, default: .east]
    let selectLoc = attributes[StdAttr.selectLocation]
    let data = attributes[StdAttr.width, default: .one]
    let select = attributes[
      PlexersLibraryAttributes.select, default: PlexersLibraryAttributes.defaultSelect]
    let enable = attributes[PlexersLibraryAttributes.enable, default: false]

    let outputs = javaIntBit(select.width)
    var ps = [Port?](repeating: nil, count: outputs + (enable ? 3 : 2))
    var sel: Location
    let selMult = selectLoc == StdAttr.selectBottomLeft ? 1 : -1

    if outputs == 2 {
      let end0: Location
      let end1: Location
      switch facing {
      case .west:
        end0 = Location.create(-30, -10, hasToSnap: true)
        end1 = Location.create(-30, 10, hasToSnap: true)
        sel = Location.create(-20, selMult * 20, hasToSnap: true)
      case .north:
        end0 = Location.create(-10, -30, hasToSnap: true)
        end1 = Location.create(10, -30, hasToSnap: true)
        sel = Location.create(selMult * -20, -20, hasToSnap: true)
      case .south:
        end0 = Location.create(-10, 30, hasToSnap: true)
        end1 = Location.create(10, 30, hasToSnap: true)
        sel = Location.create(selMult * -20, 20, hasToSnap: true)
      case .east:
        end0 = Location.create(30, -10, hasToSnap: true)
        end1 = Location.create(30, 10, hasToSnap: true)
        sel = Location.create(20, selMult * 20, hasToSnap: true)
      }
      ps[0] = Port(end0.x, end0.y, .output, data.width)
      ps[1] = Port(end1.x, end1.y, .output, data.width)
    } else {
      var dx = -(outputs / 2) * 10
      var ddx = 10
      var dy = dx
      var ddy = 10
      switch facing {
      case .west:
        dx = -40
        ddx = 0
        sel = Location.create(-20, selMult * (dy + 10 * outputs), hasToSnap: true)
      case .north:
        dy = -40
        ddy = 0
        sel = Location.create(selMult * dx, -20, hasToSnap: true)
      case .south:
        dy = 40
        ddy = 0
        sel = Location.create(selMult * dx, 20, hasToSnap: true)
      case .east:
        dx = 40
        ddx = 0
        sel = Location.create(20, selMult * (dy + 10 * outputs), hasToSnap: true)
      }
      // Same capture-before-advance note as Multiplexer: `sel` reads `dx`/`dy` before the loop
      // below mutates them.
      for i in 0..<outputs {
        ps[i] = Port(dx, dy, .output, data.width)
        dx += ddx
        dy += ddy
      }
    }

    let en = sel.translate(facing, -10)
    ps[outputs] = Port(sel.x, sel.y, .input, select.width)
    if enable {
      ps[outputs + 1] = Port(en.x, en.y, .input, BitWidth.one)
    }
    ps[ps.count - 1] = Port(0, 0, .input, data.width)

    // Every slot is written above for every reachable attribute combination; a nil is a
    // transcription defect (D13's programmer-error carve-out), same as Multiplexer.
    return ps.enumerated().map { index, port in
      guard let port else {
        preconditionFailure("Demultiplexer: port \(index) of \(ps.count) was never assigned")
      }
      return port
    }
  }

  // MARK: Propagation

  /// `propagate(InstanceState)`.
  ///
  /// **Deviation (mechanism), same as Multiplexer:** Java's `Value` reference comparisons
  /// against `Value.FALSE`/`Value.ERROR` are structural here, safe at one-bit width.
  public override func propagate(_ state: any InstanceState) throws {
    let data = state.attributeValue(StdAttr.width, default: .one)
    let select = state.attributeValue(
      PlexersLibraryAttributes.select, default: PlexersLibraryAttributes.defaultSelect)
    let threeState = state.attributeValue(
      PlexersLibraryAttributes.tristate, default: PlexersLibraryAttributes.defaultTristate)
    let enable = state.attributeValue(PlexersLibraryAttributes.enable, default: false)
    let outputs = javaIntBit(select.width)
    let en = enable ? state.portValue(outputs + 1) : .trueValue

    var others: Value = threeState ? Value.createUnknown(data) : Value.createKnown(data, 0)
    var outIndex = -1
    var out: Value?

    if en == .falseValue {
      let opt = state.attributeValue(PlexersLibraryAttributes.disabled)
      let base: Value = opt == PlexersLibraryAttributes.disabledZero ? .falseValue : .unknownValue
      // D13: `Value.repeat` throws (a multi-bit base, or a width over 64).
      others = try Value.repeat(base, data.width)
    } else if en == .errorValue && state.isPortConnected(outputs + 1) {
      others = Value.createError(data)
    } else {
      let sel = state.portValue(outputs)
      if sel.isFullyDefined() {
        outIndex = Int(sel.toLongValue())
        out = state.portValue(outputs + (enable ? 2 : 1))
      } else if sel.isErrorValue() {
        others = Value.createError(data)
      } else {
        others = Value.createUnknown(data)
      }
    }

    for i in 0..<outputs {
      // `out` is non-nil exactly when `outIndex` was set, i.e. whenever `i == outIndex` below.
      state.setPort(i, i == outIndex ? out! : others, PlexersLibraryAttributes.delay)
    }
  }

  // PAINT (M6): paintGhost / paintInstance: the reversed-facing trapezoid, "DMX" text, select
  // dot and "0" output marker. See Demultiplexer.java:139-246.
}
