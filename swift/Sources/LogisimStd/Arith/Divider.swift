// Divider.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.arith.Divider),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Fixed bounds, fixed ports (UPPER/REM are width-wide), the same bespoke attribute pair as
// `Multiplier` (`Comparator.modeAttr`).
//
// D15/wide-arithmetic note, and why this file does NOT use `dividingFullWidth(_:)`:
//
// The `w > 32` branch forms a `2w`-bit dividend `(upper << w) | a` and divides it by `b`. The
// literal recipe for this class of problem is `Value.magnitudeUInt64` with
// `UInt64.dividingFullWidth(_:)`. That is unsafe here: `dividingFullWidth`'s precondition is
// that the *quotient* fit back in 64 bits, and Java's oracle is `BigInteger.divideAndRemainder`,
// which has no such limit: it happily computes an arbitrarily wide quotient and then
// `longValue()` truncates it to the low 64 bits. A small `b` (e.g. 1) with a large `upper` can
// easily produce a mathematical quotient far wider than 64 bits, which would hit
// `dividingFullWidth`'s trap instead of Java's silent truncation; an actual crash bug the
// original does not have.
//
// `UInt128`/`Int128` sidestep this entirely: both dividend and divisor fit in 128 bits (dividend
// `< 2^(2w) <= 2^128`; divisor `< 2^64`), so native `/`/`%` never traps, and the low-64-bit
// truncation of the (potentially huge) true quotient is done explicitly afterwards via
// `truncatingIfNeeded`, matching `BigInteger.longValue()`.
//
// The signed path additionally has to reproduce a real upstream quirk: Java builds `num` from
// `uu.shiftLeft(w).or(aa)` where, in signed mode, `aa` (`a.toBigInteger(false)`) can itself be
// *negative*: and `BigInteger.or` on a negative operand ORs in its conceptually-infinite
// leading 1s, which can swamp bits contributed by `uu` entirely (e.g. `aa == -1` forces
// `num == -1`, discarding `uu` completely). `Int128`'s native `<<`/`|` reproduce this exactly:
// as long as every intermediate value's true magnitude fits within `Int128` (it does: see
// `Multiplier.swift`'s header for the bound), a fixed-width two's-complement type's bit pattern
// *is* the same "infinite" two's-complement representation `BigInteger` uses, just viewed
// through a 128-bit window. Preserved rather than "fixed": see the top-level porting brief.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.arith.Divider`.
public final class Divider: InstanceFactoryBase {

  /// `Divider._ID`. Do not change, `.circ` files reference it.
  public static let id = "Divider"

  static let perDelay = 1
  public static let in0 = 0
  public static let in1 = 1
  public static let out = 2
  public static let upper = 3
  public static let rem = 4

  public init() {
    super.init(Divider.id)
    // Java: `BitWidth.create(8)`: a literal (D13's non-throwing carve-out).
    setAttributes([
      StdAttr.width.binding(BitWidth.known(8)),
      Comparator.modeAttr.binding(Comparator.unsignedOption),
    ])
    setOffsetBounds(Bounds.create(-40, -20, 40, 40))
    setPorts([
      Port(-40, -10, .input, StdAttr.width),  // IN0 (dividend, lower word)
      Port(-40, 10, .input, StdAttr.width),  // IN1 (divisor)
      Port(0, 0, .output, StdAttr.width),  // OUT (quotient)
      Port(-20, -20, .input, StdAttr.width),  // UPPER (dividend, upper word)
      Port(-20, 20, .output, StdAttr.width),  // REM (remainder)
    ])
  }

  /// `Divider.computeResult(BitWidth, Value, Value, Value, boolean)` → `(quotient, remainder)`.
  static func computeResult(
    _ width: BitWidth, _ a: Value, _ b: Value, _ upper0: Value, unsigned: Bool
  ) throws -> (quotient: Value, remainder: Value) {
    let w = width.width
    let hasUpper = !(upper0 == .nilValue || upper0.isUnknown())
    let upper = hasUpper ? upper0 : Value.createKnown(width, 0)

    if a.isFullyDefined() && b.isFullyDefined() && upper.isFullyDefined() {
      if w <= 32 {
        let bb = b.toSignExtendedLongValue()
        let num: Int64
        if hasUpper {
          let low = a.toLongValue()
          // `w <= 32`, so this shift is nowhere near the 64-bit boundary where Swift's native
          // `<<` would diverge from Java's masked shift.
          let upp = upper.toSignExtendedLongValue() << w
          num = upp | low
        } else {
          num = a.toSignExtendedLongValue()
        }
        let den: Int64 = bb == 0 ? 1 : bb

        let res: Int64
        let remV: Int64
        if unsigned {
          res = Int64(bitPattern: UInt64(bitPattern: num) / UInt64(bitPattern: den))
          remV = Int64(bitPattern: UInt64(bitPattern: num) % UInt64(bitPattern: den))
        } else {
          // `dividedReportingOverflow`, NOT `/`. Java's `ldiv` is TOTAL; JLS 15.17.2 says that
          // when the dividend is the negative integer of largest magnitude and the divisor is -1,
          // "integer overflow occurs and the result is equal to the dividend", with no exception.
          // So `Long.MIN_VALUE / -1L == Long.MIN_VALUE` and `Long.MIN_VALUE % -1L == 0`. Swift's
          // `/` and `%` are PARTIAL at exactly that point and end the process.
          //
          // It is reachable from three ordinary constants: the dividend is not typed, it is
          // ASSEMBLED as `(upper << w) | a`, so a 32-bit signed Divider with UPPER = 0x8000_0000
          // sign-extends to -2^31, shifts to exactly -2^63, and IN1 = 0xFFFF_FFFF sign-extends to
          // -1. The existing `bb == 0 ? 1 : bb` above guards the OTHER total-vs-partial difference
          // in integer division; this is its twin, and it was missed.
          //
          // The overflowing result is the one Java produces, so taking `partialValue` is the
          // faithful answer rather than a fallback.
          let (quotient, quotientOverflowed) = num.dividedReportingOverflow(by: den)
          let (remainder, remainderOverflowed) = num.remainderReportingOverflow(dividingBy: den)
          res = quotientOverflowed ? num : quotient
          remV = remainderOverflowed ? 0 : remainder
        }
        return (Value.createKnown(width, res), Value.createKnown(width, remV))
      }

      // w in 33...64: needs the true 2w-bit dividend. See the file header.
      let result: Int64
      let remainderValue: Int64
      if unsigned {
        let uu = UInt128(upper.magnitudeUInt64)
        let aa = UInt128(a.magnitudeUInt64)
        let bb = UInt128(b.magnitudeUInt64)
        let num = (uu << UInt128(w)) | aa
        let den: UInt128 = bb == 0 ? 1 : bb
        result = Int64(truncatingIfNeeded: num / den)
        remainderValue = Int64(truncatingIfNeeded: num % den)
      } else {
        let uu = upper.toBigInteger(unsigned: false)
        let aa = a.toBigInteger(unsigned: false)
        let bb = b.toBigInteger(unsigned: false)
        let num = (uu << Int128(w)) | aa
        let den: Int128 = bb == 0 ? 1 : bb
        // The 33...64 branch has the SAME total-vs-partial hazard as the narrow one above, one
        // width up: `Int128.min / -1` overflows and Swift's `/` traps. It is reachable for the
        // same reason, the dividend is assembled from UPPER and IN0 rather than typed, and Java
        // computes in `BigInteger` here, which has no overflow at all, so the faithful answer is
        // the wrapped one rather than an error.
        let (quotient, quotientOverflowed) = num.dividedReportingOverflow(by: den)
        let (remainder, remainderOverflowed) = num.remainderReportingOverflow(dividingBy: den)
        result = Int64(truncatingIfNeeded: quotientOverflowed ? num : quotient)
        remainderValue = Int64(truncatingIfNeeded: remainderOverflowed ? 0 : remainder)
      }
      return (Value.createKnown(width, result), Value.createKnown(width, remainderValue))
    } else if a.isErrorValue() || b.isErrorValue() || upper.isErrorValue() {
      return (Value.createError(width), Value.createError(width))
    } else {
      return (Value.createUnknown(width), Value.createUnknown(width))
    }
  }

  public override func propagate(_ state: any InstanceState) throws {
    let dataWidth = state.attributeValue(StdAttr.width, default: .one)
    let unsigned =
      state.attributeValue(Comparator.modeAttr, default: Comparator.unsignedOption)
      == Comparator.unsignedOption

    let a = state.portValue(Divider.in0)
    let b = state.portValue(Divider.in1)
    let upperValue = state.portValue(Divider.upper)
    let outs = try Divider.computeResult(dataWidth, a, b, upperValue, unsigned: unsigned)

    let delay = dataWidth.width * (dataWidth.width + 2) * Divider.perDelay
    state.setPort(Divider.out, outs.quotient, delay)
    state.setPort(Divider.rem, outs.remainder, delay)
  }

  // NOT PORTED: configureNewInstance/instanceAttributeChanged's `fireInvalidated()` on
  // MODE_ATTR: a repaint request, M6, and does not affect ports/bounds.
  /// `S.get("dividerUpperInput")`/`S.get("dividerRemainderOutput")`; localisation (D5's
  /// precedent); the English resource strings ("upper"/"rem") are used directly.
  public func paintInstance(_ painter: SceneBuilder, _ state: any InstanceState) {
    painter.color = ArithPaint.componentColor
    painter.drawBounds(state.component.bounds)
    painter.color = ArithPaint.secondaryColor
    ArithPaint.drawPort(painter, state, Divider.in0)
    ArithPaint.drawPort(painter, state, Divider.in1)
    ArithPaint.drawPort(painter, state, Divider.out)
    ArithPaint.drawPort(painter, state, Divider.upper, label: "upper", direction: .north)
    ArithPaint.drawPort(painter, state, Divider.rem, label: "rem", direction: .south)

    let loc = state.component.location
    painter.color = ArithPaint.componentColor
    painter.withStrokeWidth(2) {
      painter.fillOval(loc.x - 12, loc.y - 7, 4, 4)
      painter.drawLine(loc.x - 15, loc.y, loc.x - 5, loc.y)
      painter.fillOval(loc.x - 12, loc.y + 3, 4, 4)
    }
  }
}
