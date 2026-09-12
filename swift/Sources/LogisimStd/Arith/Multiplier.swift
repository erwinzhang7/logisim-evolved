// Multiplier.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.arith.Multiplier),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Fixed bounds, fixed ports (C_IN/C_OUT are width-wide here, unlike Adder's 1-bit carry), one
// bespoke attribute pair shared with `Comparator` (`Comparator.modeAttr`).
//
// D15/wide-arithmetic note: `Value.toBigInteger` returns `Int128`, which is NOT wide enough for
// an unsigned 64x64 product; `(2^64-1)^2` ~= 3.4e38 overflows `Int128.max` ~= 1.7e38. The
// `w <= 32` branch never needs more than 64 bits (see the comment on `computeProduct`), so the
// only place this bites is the `w > 32` branch, below.
//
// Deviation (mechanism), argued once here: rather than the `magnitudeUInt64` +
// `multipliedFullWidth(by:)` construction suggested as the general recipe for this problem, the
// `w > 32` branch uses `UInt128` for the unsigned case and `Int128` for the signed case:
//   * `UInt128.max` (2^128-1) comfortably holds `(2^64-1)^2 + (2^64-1)`, so the unsigned multiply
//     and add cannot overflow. It is exactly the width the "128 unsigned bits" framing already
//     asks for, just typed as a single width instead of a `(high, low)` pair.
//   * `Int128` on its own is *insufficient for two full-magnitude 64-bit unsigned factors*, but
//     the largest a *signed* 64-bit product plus a 64-bit addend can reach is `2^126`-ish, which
//     is well inside `Int128.max` (~2^127), so no widening trick is needed there.
// `Divider.swift` makes the same choice for the same reason and explains the additional hazard
// (`dividingFullWidth` can trap when the true quotient does not fit back in 64 bits, which a
// `BigInteger`-based Java oracle never does) that rules out the literal recipe for division.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.arith.Multiplier`.
public final class Multiplier: InstanceFactoryBase {

  /// `Multiplier._ID`. Do not change, `.circ` files reference it.
  public static let id = "Multiplier"

  static let perDelay = 1
  public static let in0 = 0
  public static let in1 = 1
  public static let out = 2
  public static let cIn = 3
  public static let cOut = 4

  public init() {
    super.init(Multiplier.id)
    // Java: `BitWidth.create(8)`: a literal (D13's non-throwing carve-out).
    setAttributes([
      StdAttr.width.binding(BitWidth.known(8)),
      Comparator.modeAttr.binding(Comparator.unsignedOption),
    ])
    setOffsetBounds(Bounds.create(-40, -20, 40, 40))
    setPorts([
      Port(-40, -10, .input, StdAttr.width),  // IN0
      Port(-40, 10, .input, StdAttr.width),  // IN1
      Port(0, 0, .output, StdAttr.width),  // OUT
      Port(-20, -20, .input, StdAttr.width),  // C_IN
      Port(-20, 20, .output, StdAttr.width),  // C_OUT
    ])
  }

  /// `Multiplier.computeProduct(BitWidth, Value, Value, Value, boolean)` → `(product, carry)`.
  ///
  /// The `w <= 32` branch reproduces Java's plain-`long` arithmetic verbatim: two `w`-bit
  /// factors (`w <= 32`) plus a `w`-bit addend need at most `2*32 = 64` bits of product, and
  /// low-64-bit two's-complement multiplication is the same ring operation whether the operands
  /// are read as signed or unsigned: only *which* 64-bit pattern each factor contributes
  /// (zero- vs sign-extended, chosen by `unsigned`) differs. So `&*`/`&+` on `Int64` gives
  /// exactly Java's wrapped `long` result either way.
  static func computeProduct(
    _ width: BitWidth, _ a: Value, _ b: Value, _ cIn0: Value, unsigned: Bool
  ) throws -> (product: Value, carry: Value) {
    let w = width.width
    var cIn = cIn0
    if cIn == .nilValue || cIn.isUnknown() { cIn = Value.createKnown(width, 0) }

    if a.isFullyDefined() && b.isFullyDefined() && cIn.isFullyDefined() {
      if w <= 32 {
        let rr: Int64
        if unsigned {
          let aa = a.toLongValue()
          let bb = b.toLongValue()
          let cc = cIn.toLongValue()
          rr = aa &* bb &+ cc
        } else {
          let aa = a.toSignExtendedLongValue()
          let bb = b.toSignExtendedLongValue()
          let cc = cIn.toSignExtendedLongValue()
          rr = aa &* bb &+ cc
        }
        // `w <= 32`, so this shift never approaches the 64-bit boundary where Swift's native
        // `>>` would diverge from Java's masked shift; plain arithmetic shift is exact here.
        return (Value.createKnown(width, rr), Value.createKnown(width, rr >> w))
      }

      // w in 33...64: needs the true 128-bit product. See the file header.
      let lo: Int64
      let hi: Int64
      if unsigned {
        let aa = UInt128(a.magnitudeUInt64)
        let bb = UInt128(b.magnitudeUInt64)
        let cc = UInt128(cIn.magnitudeUInt64)
        let rr = aa &* bb &+ cc
        lo = Int64(truncatingIfNeeded: rr)
        hi = Int64(truncatingIfNeeded: rr >> UInt128(w))
      } else {
        let aa = a.toBigInteger(unsigned: false)
        let bb = b.toBigInteger(unsigned: false)
        let cc = cIn.toBigInteger(unsigned: false)
        let rr = aa &* bb &+ cc
        lo = Int64(truncatingIfNeeded: rr)
        hi = Int64(truncatingIfNeeded: rr >> w)
      }
      return (Value.createKnown(width, lo), Value.createKnown(width, hi))
    }

    // Not fully defined: Java still runs the raw (possibly garbage-in-undefined-bits) product
    // through `BigInteger`, then keeps only the bits below the first index at which *any* of
    // the three operands turns unknown, marks bits up to the first error index as unknown, and
    // errors the rest. `ret` only ever needs the low 64 bits (`i < w <= 64`), so, by the same
    // ring argument as above, plain `Int64` wraparound arithmetic on the truncated
    // `toBigInteger` values reproduces `BigInteger(...).longValue()` exactly, without needing
    // the 128-bit machinery the fully-defined branch requires.
    let avals = a.getAll()
    let aUnkIndex = findUnknown(avals)
    let aErrIndex = findError(avals)
    let bvals = b.getAll()
    let bUnkIndex = findUnknown(bvals)
    let bErrIndex = findError(bvals)
    let cvals = cIn.getAll()
    let cUnkIndex = findUnknown(cvals)
    let cErrIndex = findError(cvals)

    let known = min(min(aUnkIndex, bUnkIndex), cUnkIndex)
    let error = min(min(aErrIndex, bErrIndex), cErrIndex)

    let aa = Int64(truncatingIfNeeded: a.toBigInteger(unsigned: unsigned))
    let bb = Int64(truncatingIfNeeded: b.toBigInteger(unsigned: unsigned))
    let cc = Int64(truncatingIfNeeded: cIn.toBigInteger(unsigned: unsigned))
    let ret = aa &* bb &+ cc

    var bits = [Value](repeating: .falseValue, count: max(w, 0))
    for i in 0..<max(w, 0) {
      if i < known {
        // Java: `(ret & (1 << i)) != 0`; `1 << i` is an `int` shift (masked mod 32) widened to
        // `long` by sign extension before the `&`. Bug-for-bug via `javaIntBitWidened`.
        bits[i] = (ret & javaIntBitWidened(i)) != 0 ? .trueValue : .falseValue
      } else if i < error {
        bits[i] = .unknownValue
      } else {
        bits[i] = .errorValue
      }
    }
    let carry = error < w ? Value.createError(width) : Value.createUnknown(width)
    return (try Value.create(bits), carry)
  }

  private static func findError(_ vals: [Value]) -> Int {
    for i in 0..<vals.count where vals[i].isErrorValue() { return i }
    return vals.count
  }

  private static func findUnknown(_ vals: [Value]) -> Int {
    for i in 0..<vals.count where !vals[i].isFullyDefined() { return i }
    return vals.count
  }

  public override func propagate(_ state: any InstanceState) throws {
    let dataWidth = state.attributeValue(StdAttr.width, default: .one)
    let unsigned =
      state.attributeValue(Comparator.modeAttr, default: Comparator.unsignedOption)
      == Comparator.unsignedOption

    let a = state.portValue(Multiplier.in0)
    let b = state.portValue(Multiplier.in1)
    let cIn = state.portValue(Multiplier.cIn)
    let outs = try Multiplier.computeProduct(dataWidth, a, b, cIn, unsigned: unsigned)

    let delay = dataWidth.width * (dataWidth.width + 2) * Multiplier.perDelay
    state.setPort(Multiplier.out, outs.product, delay)
    state.setPort(Multiplier.cOut, outs.carry, delay)
  }

  // NOT PORTED: configureNewInstance/instanceAttributeChanged's `fireInvalidated()` on
  // MODE_ATTR: a repaint request, M6, and does not affect ports/bounds.
  public func paintInstance(_ painter: SceneBuilder, _ state: any InstanceState) {
    painter.color = ArithPaint.componentColor
    painter.drawBounds(state.component.bounds)
    painter.color = ArithPaint.secondaryColor
    ArithPaint.drawPort(painter, state, Multiplier.in0)
    ArithPaint.drawPort(painter, state, Multiplier.in1)
    ArithPaint.drawPort(painter, state, Multiplier.out)
    ArithPaint.drawPort(painter, state, Multiplier.cIn, label: "c in", direction: .north)
    ArithPaint.drawPort(painter, state, Multiplier.cOut, label: "c out", direction: .south)

    let loc = state.component.location
    painter.color = ArithPaint.componentColor
    painter.withStrokeWidth(2) {
      painter.drawLine(loc.x - 15, loc.y - 5, loc.x - 5, loc.y + 5)
      painter.drawLine(loc.x - 15, loc.y + 5, loc.x - 5, loc.y - 5)
    }
  }
}
