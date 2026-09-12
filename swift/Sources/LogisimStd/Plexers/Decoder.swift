// Decoder.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.plexers.Decoder),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// HDL generation (`DecoderHdlGeneratorFactory`) is stripped, D11 backlog.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.plexers.Decoder`.
public final class Decoder: InstanceFactoryBase {

  /// `Decoder._ID`. Do not change, `.circ` files reference it.
  public static let id = "Decoder"

  public init() {
    super.init(Decoder.id)
    setAttributes([
      StdAttr.facing.binding(Direction.east),
      StdAttr.selectLocation.binding(StdAttr.selectBottomLeft),
      PlexersLibraryAttributes.select.binding(PlexersLibraryAttributes.defaultSelect),
      PlexersLibraryAttributes.tristate.binding(PlexersLibraryAttributes.defaultTristate),
      PlexersLibraryAttributes.disabled.binding(PlexersLibraryAttributes.disabledZero),
      // ── UPSTREAM QUIRK, PRESERVED ── the literal `true`, not `PlexersLibrary.DEFAULT_ENABLE`
      // (which is `false`). Every other plexer in this family defaults `enable` to `false`;
      // `Decoder` alone defaults it to `true`. Transcribed verbatim.
      PlexersLibraryAttributes.enable.binding(true),
    ])
    setFacingAttribute(StdAttr.facing)
    // `setKeyConfigurator` / `setIcon`, UI (D9) and M6.
  }

  /// `getDefaultAttributeValue(Attribute<?>, LogisimVersion)`.
  ///
  /// ── UPSTREAM QUIRK, PRESERVED ── this is a *different* version gate from every other plexer
  /// in the family: threshold `2.6.4` (not `3.6.1`) and the comparison is reversed (`>= 0`, i.e.
  /// "enabled by default from 2.6.4 onward", not "enabled by default up to and including" some
  /// version). A file older than 2.6.4 that omits `enable` gets `false` here; the same file would
  /// get `true` from `Multiplexer`/`Demultiplexer`. Both are upstream's stated intent, not a
  /// transcription slip: see the two files' comments side by side.
  public override func defaultAttributeValue(
    _ attribute: AnyAttribute, version: LogisimVersion
  ) -> AttributeValue? {
    if attribute === PlexersLibraryAttributes.enable {
      return .boolean(version.compare(to: LogisimVersion(2, 6, 4)) >= 0)
    }
    return super.defaultAttributeValue(attribute, version: version)
  }

  /// `contains(Location, AttributeSet)`: same reversed-facing hit test as `Demultiplexer`.
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
    let selectLoc = attributes[StdAttr.selectLocation]
    let select = attributes[
      PlexersLibraryAttributes.select, default: PlexersLibraryAttributes.defaultSelect]
    let outputs = javaIntBit(select.width)

    var reversed = facing == .west || facing == .north
    if selectLoc == StdAttr.selectTopRight { reversed.toggle() }

    let bds: Bounds
    if outputs == 2 {
      let y = reversed ? 0 : -40
      bds = Bounds.create(-20, y - 5, 30, 40 + 10)
    } else {
      let x = -20
      let y = reversed ? -10 : -(outputs * 10 + 10)
      bds = Bounds.create(x, y, 40, outputs * 10 + 20)
    }
    return bds.rotate(from: .east, to: facing, xc: 0, yc: 0)
  }

  /// `updatePorts(Instance)`.
  ///
  /// Port order: the `2^select` one-bit outputs, then select, then enable (only when
  /// `ATTR_ENABLE`). Unlike `Multiplexer`/`Demultiplexer` there is no trailing data port; a
  /// decoder has no data input at all. `propagate`'s indices mirror this exactly.
  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    let facing = attributes[StdAttr.facing, default: .east]
    let selectLoc = attributes[StdAttr.selectLocation]
    let select = attributes[
      PlexersLibraryAttributes.select, default: PlexersLibraryAttributes.defaultSelect]
    let enable = attributes[PlexersLibraryAttributes.enable, default: false]

    let outputs = javaIntBit(select.width)
    var ps = [Port?](repeating: nil, count: outputs + (enable ? 2 : 1))

    if outputs == 2 {
      let end0: Location
      let end1: Location
      if facing == .north || facing == .south {
        let y = facing == .north ? -10 : 10
        if selectLoc == StdAttr.selectTopRight {
          end0 = Location.create(-30, y, hasToSnap: true)
          end1 = Location.create(-10, y, hasToSnap: true)
        } else {
          end0 = Location.create(10, y, hasToSnap: true)
          end1 = Location.create(30, y, hasToSnap: true)
        }
      } else {
        let x = facing == .west ? -10 : 10
        if selectLoc == StdAttr.selectTopRight {
          end0 = Location.create(x, 10, hasToSnap: true)
          end1 = Location.create(x, 30, hasToSnap: true)
        } else {
          end0 = Location.create(x, -30, hasToSnap: true)
          end1 = Location.create(x, -10, hasToSnap: true)
        }
      }
      ps[0] = Port(end0.x, end0.y, .output, 1)
      ps[1] = Port(end1.x, end1.y, .output, 1)
    } else {
      var dx: Int
      var ddx: Int
      var dy: Int
      var ddy: Int
      if facing == .north || facing == .south {
        dy = facing == .north ? -20 : 20
        ddy = 0
        dx = selectLoc == StdAttr.selectTopRight ? -10 * outputs : 0
        ddx = 10
      } else {
        dx = facing == .west ? -20 : 20
        ddx = 0
        dy = selectLoc == StdAttr.selectTopRight ? 0 : -10 * outputs
        ddy = 10
      }
      for i in 0..<outputs {
        ps[i] = Port(dx, dy, .output, 1)
        dx += ddx
        dy += ddy
      }
    }

    let en = Location.create(0, 0, hasToSnap: true).translate(facing, -10)
    ps[outputs] = Port(0, 0, .input, select.width)
    if enable {
      ps[outputs + 1] = Port(en.x, en.y, .input, BitWidth.one)
    }

    // Every slot is written above for every reachable attribute combination; a nil is a
    // transcription defect (D13's programmer-error carve-out), same as Multiplexer.
    return ps.enumerated().map { index, port in
      guard let port else {
        preconditionFailure("Decoder: port \(index) of \(ps.count) was never assigned")
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
    let data = BitWidth.one
    let select = state.attributeValue(
      PlexersLibraryAttributes.select, default: PlexersLibraryAttributes.defaultSelect)
    let threeState = state.attributeValue(
      PlexersLibraryAttributes.tristate, default: PlexersLibraryAttributes.defaultTristate)
    let enable = state.attributeValue(PlexersLibraryAttributes.enable, default: false)
    let outputs = javaIntBit(select.width)

    var others: Value = threeState ? .unknownValue : .falseValue
    var outIndex = -1
    var out: Value?
    let en = enable ? state.portValue(outputs + 1) : .trueValue

    if en == .falseValue {
      let opt = state.attributeValue(PlexersLibraryAttributes.disabled)
      let base: Value = opt == PlexersLibraryAttributes.disabledZero ? .falseValue : .unknownValue
      // D13: `Value.repeat` throws. `data.width == 1` always here, so this is always a no-op
      // repeat, transcribed anyway to match Java exactly.
      others = try Value.repeat(base, data.width)
    } else if en == .errorValue && state.isPortConnected(outputs + 1) {
      others = Value.createError(data)
    } else {
      let sel = state.portValue(outputs)
      if sel.isFullyDefined() {
        outIndex = Int(sel.toLongValue())
        out = .trueValue
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

  // PAINT (M6): paintGhost / paintInstance: the reversed-facing trapezoid, "Decd" text, select
  // dot and "0" output marker. See Decoder.java:138-245.
}
