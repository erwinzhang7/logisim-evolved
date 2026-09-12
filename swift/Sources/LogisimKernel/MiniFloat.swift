//
//  MiniFloat.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
//  specifically `src/main/java/com/cburch/logisim/util/MiniFloat.java`.
//  logisim-evolution is free software released under the GNU GPLv3; this translation is
//  therefore GPL-3.0-only. See LICENSE.md.
//
//  ---------------------------------------------------------------------------------------
//  PROVISIONAL. This file exists because `Value` needs FP8 conversion (`Value.createKnown`
//  and `Value.toFloatValueFromFP8`). It is a faithful, complete port of MiniFloat.java, but
//  it was written as a dependency of the Value port rather than as its own reviewed unit.
//  If MiniFloat.java is ported again as a first-class task, that port supersedes this file.
//  ---------------------------------------------------------------------------------------
//
//  Java-semantics notes:
//    * `&<<` / `&>>` are used wherever the Java uses `<<` / `>>`, because Java masks the
//      shift distance (mod 32 for int, mod 64 for long) and Swift's plain `<<` / `>>` do
//      not: they saturate to 0 on over-shift and reverse direction on a negative distance.
//    * Java's `assert` statements are omitted: assertions are disabled by default in the
//      JVM (`-ea` is not set by the shipped launcher), so they are not part of the observed
//      behaviour. Trapping on them in Swift would be a behavioural change.
//

/// The "miniFloat143" 8-bit float format used by logisim-evolution: 1 sign bit,
/// 4 exponent bits, 3 significand bits, exponent bias 7.
public enum MiniFloat {

  /// Number of bits in a `Float` significand, including the implicit leading 1.
  /// (Java: `jdk.internal.math.FloatConsts.SIGNIFICAND_WIDTH`.)
  public static let significandWidth: Int32 = 24

  /// Exponent bias for single precision. (Java: `FloatConsts.EXP_BIAS`.)
  public static let expBias: Int32 = 127

  /// 0x1p-9f, i.e. 2^-9, written as a bit pattern so it is exact and matches the Java
  /// hexadecimal float literal.
  private static let twoToMinus9 = Float(bitPattern: 0x3B00_0000)

  /// Java: `MiniFloat.miniFloat143ToFloat(byte)`.
  public static func miniFloat143ToFloat(_ miniFloat: Int8) -> Float {
    // Java widens `byte` to `int` with sign extension here. The masks below make the
    // extension irrelevant, but the widening is reproduced exactly anyway.
    let bin8arg = Int32(miniFloat)
    let bin8SignBit = 0x80 & bin8arg
    let bin8ExpBits = 0x78 & bin8arg
    let bin8SignifBits = 0x07 & bin8arg

    // Shift left by the difference in significand widths between float and miniFloat143.
    let signifShift = significandWidth - 4  // 20

    let sign: Float = (bin8SignBit != 0) ? -1.0 : 1.0

    let bin8Exp = (bin8ExpBits &>> 3) - 7
    if bin8Exp == -7 {
      // Subnormal miniFloat143 values and zero: the numeric value is 2^-9 times the
      // significand taken as an integer (no implicit bit).
      return sign * (twoToMinus9 * Float(bin8SignifBits))
    } else if bin8Exp == 8 {
      if bin8SignifBits == 0 {
        return sign * Float.infinity
      }
      // Preserve NaN significand bits.
      let bits = (bin8SignBit &<< 24) | Int32(bitPattern: 0x7f80_0000) | (bin8SignifBits &<< signifShift)
      return Float(bitPattern: UInt32(bitPattern: bits))
    }

    // -7 < bin8Exp < 8 here.
    let floatExpBits = (bin8Exp + expBias) &<< (significandWidth - 1)
    let bits = (bin8SignBit &<< 24) | floatExpBits | (bin8SignifBits &<< signifShift)
    return Float(bitPattern: UInt32(bitPattern: bits))
  }

  /// Java: `MiniFloat.floatToMiniFloat143(float)`.
  public static func floatToMiniFloat143(_ f: Float) -> Int8 {
    // Java: Float.floatToRawIntBits: the *raw* form, so NaN payloads are NOT canonicalised.
    let doppel = Int32(bitPattern: f.bitPattern)
    let signMask = Int32(bitPattern: 0x8000_0000)
    let signBit = Int8(truncatingIfNeeded: (doppel & signMask) &>> 24)

    if f.isNaN {
      // Preserve the sign and attempt to preserve significand bits (float bits 22..20).
      return Int8(truncatingIfNeeded: Int32(signBit) | 0x78 | ((doppel & 0x0070_0000) &>> 20))
    }

    let absF = abs(f)

    // Overflow threshold is miniFloat143 MAX_VALUE + 1/2 ulp == 0x1.0p8f == 256.
    if absF >= 256.0 {
      return Int8(truncatingIfNeeded: Int32(signBit) | 0x78)  // +/- infinity
    }

    // Smallest nonzero representable magnitude is 0x1.0p-9; half-way and below rounds to
    // zero. 0x1.0p-9f * 0.5f == 2^-10 == 0.0009765625. Covers float zeros and subnormals.
    if absF <= 0.0009765625 {
      return signBit  // +/- zero
    }

    // Finite values inside the miniFloat143 exponent range. (-10 <= exp <= 7 here.)
    var exp = javaGetExponent(f)

    // For miniFloat143 subnormals, force exp to -7 and retain expdelta = E_min - exp as an
    // excess shift on top of the base shift of 20. The hidden msb of `f` must participate.
    var expdelta: Int32 = 0
    var msb: Int32 = 0
    if exp < -6 {
      expdelta = -6 - exp
      exp = -7
      msb = 0x0080_0000
    }
    let fSignifBits = (doppel & 0x007f_ffff) | msb

    // Significand bits as if rounding toward zero (truncation).
    var signifBits = Int8(truncatingIfNeeded: fSignifBits &>> (20 + expdelta))

    // Round to nearest even.
    let lsb = fSignifBits & (Int32(1) &<< (20 + expdelta))
    let round = fSignifBits & (Int32(1) &<< (19 + expdelta))
    let sticky = fSignifBits & ((Int32(1) &<< (19 + expdelta)) &- 1)

    if round != 0 && ((lsb | sticky) != 0) {
      signifBits = signifBits &+ 1
    }

    // The significand is added to (not or-ed into) the shifted exponent, which is what
    // implements the carry-out from rounding the significand.
    return Int8(truncatingIfNeeded: Int32(signBit) | (((exp + 7) &<< 3) &+ Int32(signifBits)))
  }

  /// Java: `Math.getExponent(float)`; the unbiased exponent field. Returns -127 for zero
  /// and subnormals and 128 for infinities and NaN, exactly as the JDK does. This is *not*
  /// the same as Swift's `Float.exponent`, which denormalises subnormal exponents.
  @inline(__always)
  static func javaGetExponent(_ f: Float) -> Int32 {
    ((Int32(bitPattern: f.bitPattern) & 0x7F80_0000) &>> (significandWidth - 1)) - expBias
  }
}
