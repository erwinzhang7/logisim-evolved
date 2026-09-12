// HexDigit.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.io.HexDigit),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Not ported ──────────────────────────────────────────────────────────────────────────────
//
//   (`paintInstance` IS ported, it delegates to `SevenSegment.drawBase`, as upstream does.)
//   * `DynamicElementProvider`/`createDynamicElement` (`HexDigitShape`), appearance editor, M7.
//   * `StdAttr.MAPINFO`; omitted; see `SevenSegment.swift`'s file header for why.
//
// Needs `StdAttr.labelLocation`: see `SevenSegment.swift`'s file header; same gap, same fix.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.io.HexDigit`.
public final class HexDigit: InstanceFactoryBase {

  /// `HexDigit._ID`.
  public static let id = "Hex Digit Display"

  public static let hexPortIndex = 0
  public static let decimalPointPortIndex = 1

  /// `HexDigit.NoDataDisplayMode` / `NO_DATA_DISPLAY`. Only `.blank` is reachable via the
  /// upstream constant, but the full enum is kept because `getSegs`'s `-1` branch switches on
  /// it, and a hand-edited build could pick a different one.
  public enum NoDataDisplayMode {
    case blank, u, uCapital, h
  }

  public static let noDataDisplay: NoDataDisplayMode = .blank

  //                                     FEAGDBC
  public static let segAMask: Int32 = 0x0010000
  public static let segBMask: Int32 = 0x0000010
  public static let segCMask: Int32 = 0x0000001
  public static let segDMask: Int32 = 0x0000100
  public static let segEMask: Int32 = 0x0100000
  public static let segFMask: Int32 = 0x1000000
  public static let segGMask: Int32 = 0x0001000

  /// `HexDigit()`.
  public init() {
    super.init(HexDigit.id, requiresLabel: true)
    setAttributes([
      IoLibrary.onColor.binding(ColorSpec(red: 240, green: 0, blue: 0)),
      IoLibrary.offColor.binding(SevenSegment.defaultOff),
      IoLibrary.background.binding(IoLibrary.defaultBackground),
      SevenSegment.attrDecimalPoint.binding(true),
      StdAttr.label.binding(""),
      StdAttr.labelLocation.binding(.east),
      StdAttr.labelFont.binding(StdAttr.defaultLabelFont),
      StdAttr.labelVisibility.binding(false),
    ])
    setOffsetBounds(Bounds.create(-15, -60, 40, 60))
  }

  // MARK: Ports — `updatePorts(Instance)`

  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    let hasDp = attributes[SevenSegment.attrDecimalPoint, default: true]
    var ports: [Port] = [Port(0, 0, .input, 4)]
    if hasDp {
      ports.append(Port(20, 0, .input, 1))
    }
    return ports
  }

  // MARK: `getSegs(int)`

  /// `HexDigit.getSegs(int)`. `value == -1` is `Value.toLongValue()`'s not-fully-defined
  /// sentinel (see `Value.toLongValue`); anything else out of `0...15` is upstream's "invalid"
  /// display (segments A, D, G: a flat dash-like glyph).
  public static func segs(for value: Int) -> Int32 {
    switch value {
    case 0: return 0x1110111
    case 1: return 0x0000011
    case 2: return 0x0111110
    case 3: return 0x0011111
    case 4: return 0x1001011
    case 5: return 0x1011101
    case 6: return 0x1111101
    case 7: return 0x0010011
    case 8: return 0x1111111
    case 9: return 0x1011011
    case 10: return 0x1111011
    case 11: return 0x1101101
    case 12: return 0x1110100
    case 13: return 0x0101111
    case 14: return 0x1111100
    case 15: return 0x1111000
    case -1:
      switch noDataDisplay {
      case .h: return segBMask | segCMask | segEMask | segFMask | segGMask  // "H"
      case .uCapital: return segBMask | segCMask | segEMask | segFMask | segDMask  // "U"
      case .u: return segCMask | segEMask | segDMask  // "u"
      case .blank: return 0
      }
    default:
      // Out-of-bounds value: A + D + G.
      return segAMask | segDMask | segGMask
    }
  }

  // MARK: InstanceFactory

  /// `propagate(InstanceState)`.
  public override func propagate(_ state: any InstanceState) throws {
    var summary: Int32 = 0
    let baseVal = state.portValue(HexDigit.hexPortIndex)
    let segs = HexDigit.segs(for: Int(baseVal.toLongValue()))
    if (segs & HexDigit.segCMask) != 0 { summary |= 4 }  // vertical seg, bottom right
    if (segs & HexDigit.segBMask) != 0 { summary |= 2 }  // vertical seg, top right
    if (segs & HexDigit.segDMask) != 0 { summary |= 8 }  // horizontal seg, bottom
    if (segs & HexDigit.segGMask) != 0 { summary |= 64 }  // horizontal seg, middle
    if (segs & HexDigit.segAMask) != 0 { summary |= 1 }  // horizontal seg, top
    if (segs & HexDigit.segEMask) != 0 { summary |= 16 }  // vertical seg, bottom left
    if (segs & HexDigit.segFMask) != 0 { summary |= 32 }  // vertical seg, top left

    if state.attributeValue(SevenSegment.attrDecimalPoint, default: true) {
      let dpVal = state.portValue(HexDigit.decimalPointPortIndex)
      // Java: `dpVal != null && (int) dpVal.toLongValue() == 1`; `getPortValue` never returns
      // null here (see `InstanceState.swift`), and an undefined `dpVal` yields `toLongValue()
      // == -1`, which already fails the `== 1` test, so the `null` check has no port-side effect.
      if dpVal.toLongValue() == 1 {
        summary |= 128  // decimal point
      }
    }

    if let data = state.data as? InstanceDataSingleton {
      data.value = summary
    } else {
      state.setData(InstanceDataSingleton(summary))
    }
  }
}

extension HexDigit: IoPaintable {
  /// `paintInstance(InstancePainter)`; `HexDigit.java:123-125`. The whole glyph is
  /// `SevenSegment.drawBase`; `propagate` above is what turns a 4-bit value into the segment
  /// bit set `drawBase` renders.
  public func paintInstance(_ painter: any IoInstancePainter) {
    SevenSegment.drawBase(
      painter, drawPoint: painter.attributeValue(SevenSegment.attrDecimalPoint, default: true))
  }
}

/// `HexDigit` installs a label field through a THIRD spelling: neither `Instance.setTextField`
/// nor `Instance.computeLabelTextField`, but `SevenSegment.computeTextField(instance)`, called at
/// `HexDigit.java:110` from `configureNewInstance` and again at `:116` when `LABEL_LOC` changes.
///
/// That third route is exactly why every grep-based survey of the label gap missed this factory:
/// board #78's spec doc scoped io as fourteen factories and this is the fifteenth. It was found
/// by the io agent while porting the other fourteen, and confirmed independently by the jar probe
/// (`docs/experiments/label-fields-measured.txt`: `Hex Digit Display  HAS label field`).
///
/// Delegating to the shared static rather than repeating the arithmetic is not tidiness: upstream
/// calls the same method, so the two placements are guaranteed identical and must stay so.
extension HexDigit: InstanceLabelProvider {
  public func labelPlacement(_ painter: InstancePainter) -> LabelPlacement? {
    SevenSegment.computeTextField(painter)
  }
}
