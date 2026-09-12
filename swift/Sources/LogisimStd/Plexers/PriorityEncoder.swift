// PriorityEncoder.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.plexers.PriorityEncoder),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// HDL generation (`PriorityEncoderHdlGeneratorFactory`) is stripped, D11 backlog.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.plexers.PriorityEncoder`.
public final class PriorityEncoder: InstanceFactoryBase {

  /// `PriorityEncoder._ID`. Do not change; `.circ` files reference it. Note the space: the
  /// `.circ` token is literally `"Priority Encoder"`.
  public static let id = "Priority Encoder"

  // Port-index constants, added to `n` (the input count). Java's names, verbatim.
  static let out = 0
  static let enIn = 1
  static let enOut = 2
  static let gs = 3

  public init() {
    super.init(PriorityEncoder.id)
    setAttributes([
      StdAttr.facing.binding(Direction.east),
      PlexersLibraryAttributes.select.binding(BitWidth.known(3)),
      PlexersLibraryAttributes.disabled.binding(PlexersLibraryAttributes.disabledZero),
    ])
    setFacingAttribute(StdAttr.facing)
    // `setKeyConfigurator` / `setIcon`, UI (D9) and M6.
  }

  /// `hasThreeStateDrivers(AttributeSet)`.
  public override func hasThreeStateDrivers(_ attributes: any AttributeSet) -> Bool {
    attributes[PlexersLibraryAttributes.disabled] == PlexersLibraryAttributes.disabledFloating
  }

  // MARK: Geometry

  /// `getOffsetBounds(AttributeSet)`.
  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let dir = attributes[StdAttr.facing, default: .east]
    let select = attributes[
      PlexersLibraryAttributes.select, default: PlexersLibraryAttributes.defaultSelect]
    let inputs = javaIntBit(select.width)
    let offs = -5 * inputs
    let len = 10 * inputs + 10
    switch dir {
    case .north:
      return Bounds.create(offs, 0, len, 40)
    case .south:
      return Bounds.create(offs, -40, len, 40)
    case .west:
      return Bounds.create(0, offs, 40, len)
    case .east:
      return Bounds.create(-40, offs, 40, len)
    }
  }

  /// `updatePorts(Instance)`.
  ///
  /// Port order: the `n` one-bit inputs, then `OUT` (select-width output), `EN_IN` (one-bit
  /// input), `EN_OUT` (one-bit output), `GS` (one-bit output): the constants above, offset by
  /// `n`. `propagate` addresses all four by the same constants.
  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    let dir = attributes[StdAttr.facing, default: .east]
    let select = attributes[
      PlexersLibraryAttributes.select, default: PlexersLibraryAttributes.defaultSelect]
    let n = javaIntBit(select.width)
    var ps = [Port?](repeating: nil, count: n + 4)

    if dir == .north || dir == .south {
      let x = -5 * n + 10
      let y = dir == .north ? 40 : -40
      for i in 0..<n {
        ps[i] = Port(x + 10 * i, y, .input, 1)
      }
      ps[n + PriorityEncoder.out] = Port(0, 0, .output, select.width)
      ps[n + PriorityEncoder.enIn] = Port(x + 10 * n, y / 2, .input, 1)
      ps[n + PriorityEncoder.enOut] = Port(x - 10, y / 2, .output, 1)
      ps[n + PriorityEncoder.gs] = Port(10, 0, .output, 1)
    } else {
      let x = dir == .east ? -40 : 40
      let y = -5 * n + 10
      for i in 0..<n {
        ps[i] = Port(x, y + 10 * i, .input, 1)
      }
      ps[n + PriorityEncoder.out] = Port(0, 0, .output, select.width)
      ps[n + PriorityEncoder.enIn] = Port(x / 2, y + 10 * n, .input, 1)
      ps[n + PriorityEncoder.enOut] = Port(x / 2, y - 10, .output, 1)
      ps[n + PriorityEncoder.gs] = Port(0, 10, .output, 1)
    }

    // Every slot is written above for every reachable attribute combination; a nil is a
    // transcription defect (D13's programmer-error carve-out), same as Multiplexer.
    return ps.enumerated().map { index, port in
      guard let port else {
        preconditionFailure("PriorityEncoder: port \(index) of \(ps.count) was never assigned")
      }
      return port
    }
  }

  // MARK: Propagation

  /// `propagate(InstanceState)`.
  ///
  /// **Deviation (mechanism):** Java's `Value` reference comparisons against `Value.TRUE`/
  /// `Value.FALSE` are structural here, safe at one-bit width.
  public override func propagate(_ state: any InstanceState) throws {
    let select = state.attributeValue(
      PlexersLibraryAttributes.select, default: PlexersLibraryAttributes.defaultSelect)
    let n = javaIntBit(select.width)
    // Note the asymmetry, upstream's: "enabled" is anything that is NOT exactly FALSE; an
    // ERROR or UNKNOWN enable input still counts as enabled.
    let enabled = state.portValue(n + PriorityEncoder.enIn) != .falseValue

    var out = -1
    var outDefault: Value
    if enabled {
      outDefault = Value.createUnknown(select)
      for i in stride(from: n - 1, through: 0, by: -1) {
        if state.portValue(i) == .trueValue {
          out = i
          break
        }
      }
    } else {
      let opt = state.attributeValue(PlexersLibraryAttributes.disabled)
      let base: Value = opt == PlexersLibraryAttributes.disabledZero ? .falseValue : .unknownValue
      // D13: `Value.repeat` throws (a multi-bit base, or a width over 64).
      outDefault = try Value.repeat(base, select.width)
    }

    if out < 0 {
      state.setPort(n + PriorityEncoder.out, outDefault, PlexersLibraryAttributes.delay)
      state.setPort(
        n + PriorityEncoder.enOut, enabled ? .trueValue : .falseValue,
        PlexersLibraryAttributes.delay)
      state.setPort(n + PriorityEncoder.gs, .falseValue, PlexersLibraryAttributes.delay)
    } else {
      state.setPort(
        n + PriorityEncoder.out, Value.createKnown(select, Int64(out)),
        PlexersLibraryAttributes.delay)
      state.setPort(n + PriorityEncoder.enOut, .falseValue, PlexersLibraryAttributes.delay)
      state.setPort(n + PriorityEncoder.gs, .trueValue, PlexersLibraryAttributes.delay)
    }
  }

  // PAINT (M6): paintInstance: the bounding box, "Pri" text, and the "0" input marker. See
  // PriorityEncoder.java:96-129.
}
