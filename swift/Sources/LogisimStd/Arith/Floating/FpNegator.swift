// FpNegator.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.arith.floating.FpNegator),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── `a * -1`, not `-a`, and the difference is one bit ────────────────────────────────────────
//
// Upstream writes `out_val = a_val * -1`. That is transcribed literally rather than turned into
// a negation, because for IEEE-754 the two are not the same operation:
//
//   * on a NaN, `-x` flips the sign bit of the *same* NaN, while `x * -1` yields the platform's
//     canonical NaN, and this port's `Value.createKnownFloat` then runs the result through
//     `Double.doubleToLongBits`, which collapses every NaN to `0x7FF8000000000000` anyway. So
//     the visible answer agrees, but only by accident, at the very last step.
//   * on a signalling NaN the multiply raises the invalid-operation flag where the negation
//     would not. Nothing in Logisim reads the FP flags, so this too is invisible; today.
//
// Both escapes are downstream of this file, so keeping the multiply costs nothing and removes
// the need to have been right about them. Zeros and infinities are identical under either.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.arith.floating.FpNegator`.
public final class FpNegator: InstanceFactoryBase {

  /// `FpNegator._ID`. Do not change, `.circ` files reference it.
  public static let id = "FPNegator"

  /// `PER_DELAY`.
  static let perDelay = 1

  public static let inPort = 0
  public static let out = 1
  public static let err = 2

  public init() {
    super.init(FpNegator.id, displayName: "Floating Point Negator")
    setAttributes([
      FpArithmeticAttributes.fpWidth.binding(FpArithmeticAttributes.defaultFpWidth)
    ])
    setOffsetBounds(Bounds.create(-40, -20, 40, 40))
    setPorts([
      Port(-40, 0, .input, FpArithmeticAttributes.fpWidth),  // IN
      Port(0, 0, .output, FpArithmeticAttributes.fpWidth),  // OUT
      Port(-20, 20, .output, 1),  // ERR
    ])
  }

  public override func propagate(_ state: any InstanceState) throws {
    let dataWidth = state.attributeValue(
      FpArithmeticAttributes.fpWidth, default: FpArithmeticAttributes.defaultFpWidth)

    let aValue = state.portValue(FpNegator.inPort).toDoubleValueFromAnyFloat()

    // Java: `a_val * -1`. See the header, not rewritten as `-aValue`.
    let outValue = aValue * -1

    let delay = (dataWidth.width + 2) * FpNegator.perDelay
    state.setPort(FpNegator.out, Value.createKnownFloat(dataWidth, outValue), delay)
    state.setPort(
      FpNegator.err, Value.createKnown(BitWidth.known(1), outValue.isNaN ? 1 : 0), delay)
  }

  // PAINT (M6): the bounds box, IN and ERR, OUT labelled "-x" to the west, and the family's
  //             three-stroke "F" glyph at x-35. See FpNegator.java:63-80.
}
