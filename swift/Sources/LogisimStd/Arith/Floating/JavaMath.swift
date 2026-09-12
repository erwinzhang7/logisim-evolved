// JavaMath.swift: part of logisim-evolved.
//
// Transcribed from the JDK (`java.lang.Math`), not from logisim-evolution. The surrounding port
// is a derivative work of logisim-evolution and is GPL-3.0-only; see LICENSE.md. The three
// algorithms reproduced here are the documented, specified behaviour of `Math.round(double)`,
// `Math.min/max(double,double)` and the JLS §5.1.3 narrowing primitive conversion, written from
// their specifications.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// WHY THIS FILE EXISTS
//
// The seventeen floating-point components are thin: each reads one or two ports, calls one
// `Math` method, and writes the result back. So *the entire fidelity risk of the family is in
// what `Math` means*, and four of its methods do not mean in Swift what they mean in Java.
// Getting any of them wrong produces output that is right for ordinary inputs and wrong at
// exactly the values a floating-point component exists to handle.
//
//   1. `Math.min` / `Math.max` **propagate NaN**; Swift's `min`/`max` return whichever operand
//      the `<` happened to favour, and `Double.minimum`/`.maximum` return the *non*-NaN operand
//      (IEEE-754 `minNum`). Java also distinguishes `-0.0` from `0.0`; none of the Swift forms
//      do. `FpMinMax` is the only caller and both differences are directly observable at its
//      pins.
//   2. `Math.round(double)` is **not** `rounded(.toNearestOrAwayFromZero)`. Java rounds halves
//      toward *positive infinity*, so `round(-2.5)` is `-2` where Swift's would give `-3`.
//   3. A Java `(long)` cast of a `double` is a **saturating, NaN-tolerant** narrowing
//      conversion. Swift's `Int64(x)` traps on NaN and on anything out of range, which under D13
//      is the worst possible outcome: a `.circ` with an infinity on an `FpToInt` input would
//      kill the process instead of producing a value.
//   4. `Math.abs`, `Math.sqrt`, `Math.rint`, `Math.ceil`, `Math.floor` and `Math.IEEEremainder`
//      *do* have exact Swift equivalents and are therefore NOT wrapped here: see the table at
//      the bottom, which exists so nobody wraps them "for symmetry" later.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// KNOWN, UNFIXABLE DIVERGENCE: THE TRANSCENDENTAL FUNCTIONS
//
// `FpExponentiator`, `FpLogarithm` and `FpTrigonometry` call `Math.pow`, `exp`, `expm1`, `log`,
// `log10`, `log1p`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `sinh`, `cosh` and `tanh`.
// **These are not bit-exactly specified in Java.** `java.lang.Math` permits a 1-ulp error (2 ulp
// for the hyperbolics and `pow`) and HotSpot substitutes platform intrinsics; only `StrictMath`
// is pinned, to fdlibm. Swift's calls land in Darwin's libm, which is a different
// implementation with the same accuracy guarantee.
//
// So results agree to within an ulp and may differ in the last bit: and at FP_WIDTH 8 or 16 the
// rounding down to a mini-float usually erases even that. Making it exact would mean porting
// fdlibm, which is far more code than the entire component family and buys parity with an
// implementation Java itself does not promise to use. **Recorded, deliberately not fixed.** It
// is the one place where this family is not bit-exact against a Java run, and it is why the
// differential harness should compare these three components with an ulp tolerance rather than
// for equality.

import Foundation

/// The `java.lang.Math` methods whose Swift spelling is not their Java meaning.
enum JavaMath {

  /// `Math.min(double, double)`.
  ///
  /// Three behaviours Swift's `min` does not have: NaN propagates (either operand NaN gives
  /// NaN, and it gives back `a`'s NaN when `a` is the NaN one), `-0.0` is smaller than `0.0`,
  /// and the comparison is `a <= b` so a tie returns `a`.
  static func min(_ a: Double, _ b: Double) -> Double {
    if a != a { return a }  // Java: `if (a != a) return a;`, the NaN test, verbatim.
    // Java: `if ((a == 0.0d) && (b == 0.0d) && (Double.doubleToRawLongBits(b) == negativeZero))`
    if a == 0.0 && b == 0.0 && b.sign == .minus { return b }
    return (a <= b) ? a : b
  }

  /// `Math.max(double, double)`: the mirror of `min`, including the `-0.0` clause, which here
  /// checks `a` for the negative zero rather than `b`.
  static func max(_ a: Double, _ b: Double) -> Double {
    if a != a { return a }
    if a == 0.0 && b == 0.0 && a.sign == .minus { return b }
    return (a >= b) ? a : b
  }

  /// `Math.round(double)`: "the closest `long` to the argument, **with ties rounding to
  /// positive infinity**".
  ///
  /// This is deliberately the bit-manipulating JDK implementation rather than
  /// `floor(a + 0.5)`, because the two differ: `floor(0.49999999999999994 + 0.5)` is `1`, and
  /// Java (since 7) returns `0`. Adding `0.5` rounds up into the tie at that value, and the
  /// same defect recurs at every exponent, so the naive form is wrong for a whole family of
  /// inputs rather than one special case.
  ///
  /// Reading it: `shift` is how far the significand must move right to land the units bit at
  /// bit 0. When `shift` is outside `0..<64` the value is either huge (already integral, or
  /// out of `long` range) or tiny, and Java defers to the `(long)` cast. Otherwise it shifts
  /// one bit short, adds one, and shifts once more: round-half-up, in integer arithmetic, on
  /// the sign-applied significand.
  static func round(_ a: Double) -> Int64 {
    let significandWidth = 53  // DoubleConsts.SIGNIFICAND_WIDTH
    let expBias: Int64 = 1023  // DoubleConsts.EXP_BIAS
    let expBitMask: Int64 = 0x7FF0_0000_0000_0000
    let significandBitMask: Int64 = 0x000F_FFFF_FFFF_FFFF

    // `doubleToRawLongBits`: raw, so a signalling NaN keeps its payload. Swift's `bitPattern`
    // is likewise raw.
    let longBits = Int64(bitPattern: a.bitPattern)
    let biasedExp = (longBits & expBitMask) >> Int64(significandWidth - 1)
    let shift = (Int64(significandWidth) - 2 + expBias) - biasedExp

    // Java: `if ((shift & -64) == 0)`: one test for `shift >= 0 && shift < 64`.
    if (shift & -64) == 0 {
      var r = (longBits & significandBitMask) | (significandBitMask + 1)
      if longBits < 0 { r = -r }
      return ((r >> shift) + 1) >> 1
    }
    return narrowToInt64(a)
  }

  /// The JLS §5.1.3 narrowing primitive conversion `(long) someDouble`.
  ///
  /// Java's cast never fails: NaN becomes `0`, values past the `long` range saturate to
  /// `Long.MIN_VALUE`/`Long.MAX_VALUE`, and everything else truncates toward zero. Swift's
  /// `Int64(_:)` traps on all three of the first cases.
  ///
  /// D13 makes this mandatory rather than defensive. `FpToInt` and `FpRound` both apply this
  /// cast to a value that came off a wire, so `<comp name="FPToInt">` fed an infinity, which
  /// any FP divide by zero produces; would otherwise terminate the application.
  static func narrowToInt64(_ value: Double) -> Int64 {
    if value.isNaN { return 0 }
    // The comparisons are against the exact powers of two, not `Int64.max` as a `Double`:
    // `Double(Int64.max)` rounds *up* to 2^63, so `value < Double(Int64.max)` would let 2^63
    // itself through and trap. `>=` against 2^63 is the correct boundary.
    if value >= 9_223_372_036_854_775_808.0 { return Int64.max }  // 2^63
    if value <= -9_223_372_036_854_775_808.0 { return Int64.min }  // -2^63
    return Int64(value.rounded(.towardZero))
  }
}

// ── Deliberately NOT wrapped ─────────────────────────────────────────────────────────────────
//
// These have exact Swift equivalents and are called directly at the use site. Listed so the
// next reader does not have to re-derive that they are safe:
//
//   Math.abs(double)          → `abs(x)` / `x.magnitude`: both clear the sign bit, so NaN stays
//                               NaN and `-0.0` becomes `0.0`, matching Java's bitmask definition.
//   Math.sqrt(double)         → `x.squareRoot()`: IEEE-754 correctly rounded in both.
//   Math.ceil / Math.floor    → `.rounded(.up)` / `.rounded(.down)`, including `ceil(-0.3) == -0.0`.
//   Math.rint(double)         → `.rounded(.toNearestOrEven)`; both are round-half-to-even.
//   Math.IEEEremainder(a, b)  → `a.remainder(dividingBy: b)`; both are the IEEE-754 remainder
//                               (quotient rounded to nearest even), NOT `truncatingRemainder`.
//   Math.fma(a, b, c)         → `c.addingProduct(a, b)`: a single fused operation in both, so
//                               the intermediate product is not rounded. `a * b + c` is NOT the
//                               same and would be a real defect in `FpMultiplier`'s FMA mode.
