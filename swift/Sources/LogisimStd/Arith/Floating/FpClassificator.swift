// FpClassificator.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.arith.floating.FpClassificator),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// The family's odd one out: it never converts to `double` as a number, it takes the raw bits
// apart. Six one-bit outputs, no ERR pin, and twice the height of every sibling.
//
// ── `>>>` is a LOGICAL shift, and the operand is signed ──────────────────────────────────────
//
// Every exponent extraction is `a.toLongValue() >>> n`, Java's *unsigned* right shift, on a
// value that is a signed `long`. At FP_WIDTH 64 with the sign bit set, `>>` would smear ones
// down through the exponent field and report `0x7FF`, infinity or NaN, for every negative
// number. The Swift spelling is to reinterpret as `UInt64` and shift there; `>>` on an unsigned
// type *is* the logical shift. Doing the reinterpret once, at the top, is what keeps this
// readable, and every mask below is written on the unsigned form.
//
// ── The masks are per-format and the width-8 one is a MiniFloat ──────────────────────────────
//
// | FP_WIDTH | exponent bits | shift | mask  | fraction mask |
// |---------:|--------------:|------:|------:|--------------:|
// | 8        | 4             | 3     | 0xF   | 0x7           |
// | 16       | 5             | 10    | 0x1F  | 0x3FF         |
// | 32       | 8             | 23    | 0xFF  | 0x7FFFFF      |
// | 64       | 11            | 52    | 0x7FF | 0xFFFFFFFFFFFFF |
//
// Width 8 is the (1,4,3) MiniFloat this port already implements in `LogisimKernel/MiniFloat`;
// the classification here is done from the bits directly rather than through it, matching
// upstream, and the two agree on which exponents are normal.
//
// ── Two upstream quirks, both preserved ──────────────────────────────────────────────────────
//
//   * **`isNegative` reads bit `width − 1` of `toLongValue()`, with no defined-ness check.**
//     `toLongValue()` answers `-1` for an unknown or error value, so an unconnected input drives
//     NEGATIVE high while every other pin reads low. That is upstream's behaviour, and it is why
//     this component appears to think a floating wire is a negative number.
//   * **Any FP_WIDTH other than 8/16/32/64 falls to the `default -> false` arm** in all five
//     `switch`es, so only NEGATIVE can be high. The option attribute makes those the only
//     reachable widths, so the arm is defensive; it is transcribed anyway.
//
// ── NOT PORTED: signalling-NaN detection ─────────────────────────────────────────────────────
//
// Upstream carries a commented-out eighth port (`SIGNALING_NAN`, index 7, at y = +20) behind a
// `//FIXME: Consider implementing signaling NaN's detection.` The *indices* are contiguous, the
// array is `new Port[7]`, 0…6, all filled, but the **geometry** has a hole: outputs sit at
// y = −30, −20, −10, 0, +10 and then jump to +30, with +20 held empty for the pin that was never
// built. Reproduced exactly, since moving `QUIET_NAN` up to +20 would move a connection point
// and silently disconnect the pin in every saved circuit that uses it.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.arith.floating.FpClassificator`.
public final class FpClassificator: InstanceFactoryBase {

  /// `FpClassificator._ID`. Do not change, `.circ` files reference it.
  public static let id = "FPClassificator"

  /// `PER_DELAY`.
  static let perDelay = 1

  public static let inPort = 0
  public static let negative = 1
  public static let zero = 2
  public static let subnormal = 3
  public static let normal = 4
  public static let infinite = 5
  /// `QUIET_NAN`. Upstream's commented-out `SIGNALING_NAN` would be index 7; this stays 6.
  public static let quietNaN = 6

  public init() {
    super.init(FpClassificator.id, displayName: "Floating Point Classificator")
    setAttributes([
      FpArithmeticAttributes.fpWidth.binding(FpArithmeticAttributes.defaultFpWidth)
    ])
    // Twice the height of the rest of the family: six outputs need the room.
    setOffsetBounds(Bounds.create(-40, -40, 40, 80))
    setPorts([
      Port(-40, 0, .input, FpArithmeticAttributes.fpWidth),  // IN
      Port(0, -30, .output, 1),  // NEGATIVE
      Port(0, -20, .output, 1),  // ZERO
      Port(0, -10, .output, 1),  // SUBNORMAL
      Port(0, 0, .output, 1),  // NORMAL
      Port(0, 10, .output, 1),  // INFINITE
      Port(0, 30, .output, 1), // QUIET_NAN: note the y = +20 gap, held for the unbuilt sNaN pin
    ])
  }

  public override func propagate(_ state: any InstanceState) throws {
    let dataWidth = state.attributeValue(
      FpArithmeticAttributes.fpWidth, default: FpArithmeticAttributes.defaultFpWidth)
    let width = dataWidth.width

    let a = state.portValue(FpClassificator.inPort)
    // `>>>` on a signed `long`: reinterpret once and shift on the unsigned form. See the header.
    let bits = UInt64(bitPattern: a.toLongValue())

    // Java: `(a.toLongValue() & (1L << (dataWidth.getWidth() - 1))) != 0`. The shift distance is
    // 7/15/31/63 for the four legal widths, so it never reaches Java's 63-mask; `javaLongBit`
    // is used anyway so a width of 0, unreachable through the attribute, but not through a
    // direct call, cannot trap on a negative shift.
    let isNegative = (a.toLongValue() & javaLongBit(width - 1)) != 0

    let isInfinite: Bool
    let isNaN: Bool
    let isZero: Bool
    switch width {
    case 8:
      let f = a.toFloatValueFromFP8()
      isInfinite = f.isInfinite
      isNaN = f.isNaN
      isZero = f == 0
    case 16:
      let f = a.toFloatValueFromFP16()
      isInfinite = f.isInfinite
      isNaN = f.isNaN
      isZero = f == 0
    case 32:
      let f = a.toFloatValue()
      isInfinite = f.isInfinite
      isNaN = f.isNaN
      isZero = f == 0
    case 64:
      let d = a.toDoubleValue()
      isInfinite = d.isInfinite
      isNaN = d.isNaN
      isZero = d == 0
    default:
      isInfinite = false
      isNaN = false
      isZero = false
    }

    // Exponent and fraction fields, per format. `isNormal` is "exponent neither all-zero nor
    // all-ones"; `isSubnormal` is "exponent zero and fraction non-zero", so a true zero is
    // neither normal nor subnormal, which is the intent.
    let isNormal: Bool
    let isSubnormal: Bool
    switch width {
    case 8:
      let exponent = (bits >> 3) & 0xF
      isNormal = exponent > 0 && exponent < 0xF
      isSubnormal = exponent == 0 && (bits & 0x7) != 0
    case 16:
      let exponent = (bits >> 10) & 0x1F
      isNormal = exponent > 0 && exponent < 0x1F
      isSubnormal = exponent == 0 && (bits & 0x3FF) != 0
    case 32:
      let exponent = (bits >> 23) & 0xFF
      isNormal = exponent > 0 && exponent < 0xFF
      isSubnormal = exponent == 0 && (bits & 0x7F_FFFF) != 0
    case 64:
      let exponent = (bits >> 52) & 0x7FF
      isNormal = exponent > 0 && exponent < 0x7FF
      isSubnormal = exponent == 0 && (bits & 0xF_FFFF_FFFF_FFFF) != 0
    default:
      isNormal = false
      isSubnormal = false
    }

    let delay = (width + 2) * FpClassificator.perDelay
    state.setPort(FpClassificator.negative, isNegative ? .trueValue : .falseValue, delay)
    state.setPort(FpClassificator.zero, isZero ? .trueValue : .falseValue, delay)
    state.setPort(FpClassificator.subnormal, isSubnormal ? .trueValue : .falseValue, delay)
    state.setPort(FpClassificator.normal, isNormal ? .trueValue : .falseValue, delay)
    state.setPort(FpClassificator.infinite, isInfinite ? .trueValue : .falseValue, delay)
    state.setPort(FpClassificator.quietNaN, isNaN ? .trueValue : .falseValue, delay)
  }

  // PAINT (M6): the tall bounds box, IN, and the six outputs labelled "-", "0", "sn", "n", "∞"
  //             and "NaN" to the west, plus an "F" glyph at (x-35, y-35).
  //             See FpClassificator.java:96-118.
}
