// SquareRoot.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.arith.SquareRoot),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── D15/wide arithmetic: `UInt128`, not `Int128`, and not `toBigInteger` ────────────────────
//
// Like `Divider`, this component forms a `2w`-bit radicand `(upper << w) | a`. Unlike `Divider`
// it does so **unsigned in both branches**, upstream calls `toBigInteger(true)` for `uu` and
// `aa` alike, so there is no signed path to reproduce and no `BigInteger.or`-on-a-negative
// quirk. What there *is* is a genuine 128-bit range: at `w == 64` with `upper`'s top bit set,
// `uu.shiftLeft(64)` occupies bits 64…127, which `Int128` (D15) cannot hold and `UInt128` can
// exactly. So the wide branch works entirely in `UInt128`, and the final narrowing to `Int64`
// is done with `truncatingIfNeeded`, matching `BigInteger.longValue()`'s low-64-bit truncation.
//
// `BigInteger.sqrtAndRemainder()` has no Swift equivalent, so `integerSquareRoot` below is a
// digit-by-digit exact integer square root over `UInt128`. It is exact, which is what
// `sqrtAndRemainder` promises; it is *not* an attempt to reproduce the narrow branch's
// floating-point behaviour, which is deliberately different (see `computeResult`).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.arith.SquareRoot`.
public final class SquareRoot: InstanceFactoryBase {

  /// `SquareRoot._ID`. Do not change, `.circ` files reference it.
  public static let id = "SquareRoot"

  /// `SquareRoot.PER_DELAY`.
  static let perDelay = 1

  // Port indices, kept named per the arith-family convention (PATTERNS.md §4).
  public static let inPort = 0
  public static let out = 1
  public static let upper = 2
  public static let rem = 3

  public init() {
    super.init(SquareRoot.id, displayName: "Square Root")
    // Java: `BitWidth.create(8)`: a literal (D13's non-throwing carve-out). Note this component
    // declares WIDTH and nothing else; see the `instanceAttributeChanged` note at the bottom.
    setAttributes([StdAttr.width.binding(BitWidth.known(8))])
    setOffsetBounds(Bounds.create(-40, -20, 40, 40))
    // Upstream fills `ps` by index, out of declaration order (`ps[UPPER]` before `ps[OUT]`).
    // Transcribed in index order, which is what `setPorts` and `propagate` address.
    setPorts([
      Port(-40, 0, .input, StdAttr.width),  // IN  (radicand, lower word)
      Port(0, 0, .output, StdAttr.width),  // OUT (root)
      Port(-20, -20, .input, StdAttr.width),  // UPPER (radicand, upper word)
      Port(-20, 20, .output, StdAttr.width),  // REM (remainder)
    ])
  }

  /// Exact `floor(sqrt(n))` over `UInt128`: the stand-in for `BigInteger.sqrtAndRemainder()`'s
  /// root half. Standard restoring digit-by-digit method: no floating point, so no precision
  /// ceiling, which is exactly why upstream falls back to `BigInteger` above width 26.
  ///
  /// No intermediate overflows: `result` stays below `2 * sqrt(n) <= 2^65` and `bit` below
  /// `2^126`, so `result + bit < 2^127`.
  static func integerSquareRoot(_ n: UInt128) -> UInt128 {
    if n == 0 { return 0 }
    var result: UInt128 = 0
    var remainder = n
    // The largest power of four not exceeding `n`.
    var bit: UInt128 = 1 << UInt128(((127 - n.leadingZeroBitCount) / 2) * 2)
    while bit != 0 {
      if remainder >= result + bit {
        remainder -= result + bit
        result = (result >> 1) + bit
      } else {
        result >>= 1
      }
      bit >>= 2
    }
    return result
  }

  /// `SquareRoot.computeResult(BitWidth, Value a, Value upper)` → `(root, remainder)`.
  ///
  /// Upstream returns a two-element array; a tuple is the same thing with the indices named.
  static func computeResult(
    _ width: BitWidth, _ a: Value, _ upper0: Value
  ) -> (root: Value, remainder: Value) {
    let w = width.width
    // Java reassigns the parameter before the definedness test, so a NIL or all-X upper word is
    // treated as a defined zero and does *not* fall through to the UNKNOWN branch below.
    let upper =
      (upper0 == .nilValue || upper0.isUnknown()) ? Value.createKnown(width, 0) : upper0

    if a.isFullyDefined() && upper.isFullyDefined() {
      if w <= 26 {
        // ── UPSTREAM QUIRK, PRESERVED: the narrow branch is floating-point ──────────────────
        //
        // Upstream's own comment: "Math.sqrt() uses double so we only have 53 bit
        // precision (26 + 26 = 52)". Every `num` here is below 2^52 and therefore exact as a
        // `Double`, but `sqrt` is only *correctly rounded*, not truncated: for a `num` just
        // below a perfect square the rounded root can come out one too large, making
        // `rem = num - root * root` **negative**. That negative remainder is then written to the
        // REM port through `createKnown`, which masks it to the width. Swift's
        // `Double.squareRoot()` is the same IEEE-754 correctly-rounded operation as
        // `Math.sqrt`, so this reproduces the quirk rather than papering over it; computing an
        // exact integer root here instead would silently change REM on those inputs.
        //
        // `w <= 26` bounds `num` below 2^52 and `root` below 2^26, so neither the `Double`
        // conversion nor the `Int64` truncation can trap.
        let num = (upper.toLongValue() << Int64(w)) | a.toLongValue()
        let root = Int64(Double(num).squareRoot())
        let remainder = num &- root &* root
        return (Value.createKnown(width, root), Value.createKnown(width, remainder))
      }

      // w in 27...64: needs the true 2w-bit radicand. See the file header.
      let uu = UInt128(upper.magnitudeUInt64)
      let aa = UInt128(a.magnitudeUInt64)
      let num = (uu << UInt128(w)) | aa
      let root = integerSquareRoot(num)
      let remainder = num - root * root
      return (
        Value.createKnown(width, Int64(truncatingIfNeeded: root)),
        Value.createKnown(width, Int64(truncatingIfNeeded: remainder))
      )
    } else if a.isErrorValue() || upper.isErrorValue() {
      return (Value.createError(width), Value.createError(width))
    } else {
      return (Value.createUnknown(width), Value.createUnknown(width))
    }
  }

  public override func propagate(_ state: any InstanceState) throws {
    let dataWidth = state.attributeValue(StdAttr.width, default: .one)

    let a = state.portValue(SquareRoot.inPort)
    let upperValue = state.portValue(SquareRoot.upper)
    let outs = SquareRoot.computeResult(dataWidth, a, upperValue)

    let delay = dataWidth.width * (dataWidth.width + 2) * SquareRoot.perDelay
    state.setPort(SquareRoot.out, outs.root, delay)
    state.setPort(SquareRoot.rem, outs.remainder, delay)
  }

  // NOT PORTED: `configureNewInstance`/`instanceAttributeChanged`. The latter is dead upstream
  // anyway; it fires only for `Comparator.MODE_ATTR`, which this factory never registers
  // (`setAttributes` declares WIDTH alone), so the condition is never true. Copy-paste from
  // `Divider`, which does carry that attribute. Recorded rather than "tidied".
  //
  /// The UPPER/REM labels reuse `Divider`'s resource strings verbatim (`"upper"`/`"rem"`):
  /// upstream's own copy-paste, not this port's.
  public func paintInstance(_ painter: SceneBuilder, _ state: any InstanceState) {
    painter.color = ArithPaint.componentColor
    painter.drawBounds(state.component.bounds)
    painter.color = ArithPaint.secondaryColor
    ArithPaint.drawPort(painter, state, SquareRoot.inPort)
    ArithPaint.drawPort(painter, state, SquareRoot.out)
    ArithPaint.drawPort(painter, state, SquareRoot.upper, label: "upper", direction: .north)
    ArithPaint.drawPort(painter, state, SquareRoot.rem, label: "rem", direction: .south)

    let loc = state.component.location
    let x = loc.x
    let y = loc.y
    painter.color = ArithPaint.componentColor
    painter.withStrokeWidth(2) {
      painter.drawLine(x - 15, y, x - 12, y + 5)
      painter.drawLine(x - 12, y + 5, x - 9, y - 5)
      painter.drawLine(x - 9, y - 5, x - 5, y - 5)
    }
  }
}
