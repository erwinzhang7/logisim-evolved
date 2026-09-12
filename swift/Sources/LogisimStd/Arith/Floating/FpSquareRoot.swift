// FpSquareRoot.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.arith.floating.FpSquareRoot),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// The one transcendental-looking member of the family that IS bit-exact: IEEE-754 requires
// square root to be correctly rounded, so `Math.sqrt` and `Double.squareRoot()` agree in every
// bit on every input: unlike `pow`/`log`/`sin`, which JavaMath.swift records as a permanent
// last-ulp divergence.
//
// `sqrt(-1)` is NaN, so a negative input raises ERR through the ordinary output-NaN test rather
// than through any check of its own.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.arith.floating.FpSquareRoot`.
public final class FpSquareRoot: InstanceFactoryBase {

  /// `FpSquareRoot._ID`. Do not change, `.circ` files reference it.
  public static let id = "FPSquareRoot"

  /// `PER_DELAY`.
  static let perDelay = 1

  public static let in0 = 0
  public static let out = 1
  public static let err = 2

  public init() {
    super.init(FpSquareRoot.id, displayName: "Floating Point Square Root")
    setAttributes([
      FpArithmeticAttributes.fpWidth.binding(FpArithmeticAttributes.defaultFpWidth)
    ])
    setOffsetBounds(Bounds.create(-40, -20, 40, 40))
    setPorts([
      Port(-40, 0, .input, FpArithmeticAttributes.fpWidth),  // IN0
      Port(0, 0, .output, FpArithmeticAttributes.fpWidth),  // OUT
      Port(-20, 20, .output, 1),  // ERR
    ])
  }

  public override func propagate(_ state: any InstanceState) throws {
    let dataWidth = state.attributeValue(
      FpArithmeticAttributes.fpWidth, default: FpArithmeticAttributes.defaultFpWidth)

    let aValue = state.portValue(FpSquareRoot.in0).toDoubleValueFromAnyFloat()

    let outValue = aValue.squareRoot()

    let delay = (dataWidth.width + 2) * FpSquareRoot.perDelay
    state.setPort(FpSquareRoot.out, Value.createKnownFloat(dataWidth, outValue), delay)
    state.setPort(
      FpSquareRoot.err, Value.createKnown(BitWidth.known(1), outValue.isNaN ? 1 : 0), delay)
  }

  // PAINT (M6): the bounds box, all three ports, a three-stroke radical glyph around x-15…x-5,
  //             and the family's "F" glyph at x-35. See FpSquareRoot.java:61-84.
}
