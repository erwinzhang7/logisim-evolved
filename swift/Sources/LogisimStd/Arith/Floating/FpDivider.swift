// FpDivider.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.arith.floating.FpDivider),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── The remainder is `IEEEremainder`, NOT `%` ────────────────────────────────────────────────
//
// The second output is `Math.IEEEremainder(a, b)`, which is the IEEE-754 remainder: it computes
// `a - b * n` where `n` is `a / b` rounded to the *nearest even* integer. The obvious Swift
// spelling `a.truncatingRemainder(dividingBy: b)` (Java's `%`) rounds `n` toward zero instead
// and gives different answers with different signs for half the input space: `IEEEremainder(5,
// 3)` is `-1` while `5 % 3` is `2`. `Double.remainder(dividingBy:)` is the correct one.
//
// ── ERR ignores the remainder ────────────────────────────────────────────────────────────────
//
// Upstream's ERR is `Double.isNaN(out_val)`: the quotient only. `IEEEremainder(x, 0)` is NaN
// and `x / 0` is ±∞, so **dividing by zero drives the remainder pin to NaN while ERR stays
// low**, and `0 / 0` raises ERR because the *quotient* is NaN, not because the remainder is.
// That asymmetry is upstream's and is preserved deliberately.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.arith.floating.FpDivider`.
public final class FpDivider: InstanceFactoryBase {

  /// `FpDivider._ID`. Do not change, `.circ` files reference it.
  public static let id = "FPDivider"

  /// `PER_DELAY`.
  static let perDelay = 1

  public static let in0 = 0
  public static let in1 = 1
  public static let out1 = 2
  public static let out2 = 3
  public static let err = 4

  public init() {
    super.init(FpDivider.id, displayName: "Floating Point Divider")
    setAttributes([
      FpArithmeticAttributes.fpWidth.binding(FpArithmeticAttributes.defaultFpWidth)
    ])
    setOffsetBounds(Bounds.create(-40, -20, 40, 40))
    setPorts([
      Port(-40, -10, .input, FpArithmeticAttributes.fpWidth),  // IN0, the dividend
      Port(-40, 10, .input, FpArithmeticAttributes.fpWidth),  // IN1, the divisor
      Port(0, 0, .output, FpArithmeticAttributes.fpWidth),  // OUT1, the quotient
      Port(-10, 20, .output, FpArithmeticAttributes.fpWidth),  // OUT2, the remainder
      Port(-20, 20, .output, 1),  // ERR
    ])
  }

  public override func propagate(_ state: any InstanceState) throws {
    let dataWidth = state.attributeValue(
      FpArithmeticAttributes.fpWidth, default: FpArithmeticAttributes.defaultFpWidth)

    let aValue = state.portValue(FpDivider.in0).toDoubleValueFromAnyFloat()
    let bValue = state.portValue(FpDivider.in1).toDoubleValueFromAnyFloat()

    let outValue = aValue / bValue
    // Java: `Math.IEEEremainder(a_val, b_val)`, see the header.
    let remValue = aValue.remainder(dividingBy: bValue)

    let delay = (dataWidth.width + 2) * FpDivider.perDelay
    state.setPort(FpDivider.out1, Value.createKnownFloat(dataWidth, outValue), delay)
    state.setPort(FpDivider.out2, Value.createKnownFloat(dataWidth, remValue), delay)
    state.setPort(
      FpDivider.err, Value.createKnown(BitWidth.known(1), outValue.isNaN ? 1 : 0), delay)
  }

  // PAINT (M6): the bounds box, all five ports, a division sign (two filled 4×4 ovals either
  //             side of a stroke at x-15…x-5), and the family's "F" glyph at x-35.
  //             See FpDivider.java:67-92.
}
