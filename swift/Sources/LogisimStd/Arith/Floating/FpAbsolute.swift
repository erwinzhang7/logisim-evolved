// FpAbsolute.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.arith.floating.FpAbsolute),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// `Math.abs(double)` is specified as a sign-bit mask, and Swift's `abs` on a `Double` is the
// same mask, so the two agree everywhere including `abs(-0.0) == 0.0` and `abs(NaN) == NaN`.
// See JavaMath.swift's closing table for why this one is not wrapped.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.arith.floating.FpAbsolute`.
public final class FpAbsolute: InstanceFactoryBase {

  /// `FpAbsolute._ID`. Do not change, `.circ` files reference it.
  public static let id = "FPAbsolute"

  /// `PER_DELAY`.
  static let perDelay = 1

  public static let in0 = 0
  public static let out = 1
  public static let err = 2

  public init() {
    super.init(FpAbsolute.id, displayName: "Floating Point Absolute")
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

    let aValue = state.portValue(FpAbsolute.in0).toDoubleValueFromAnyFloat()

    let outValue = abs(aValue)

    let delay = (dataWidth.width + 2) * FpAbsolute.perDelay
    state.setPort(FpAbsolute.out, Value.createKnownFloat(dataWidth, outValue), delay)
    state.setPort(
      FpAbsolute.err, Value.createKnown(BitWidth.known(1), outValue.isNaN ? 1 : 0), delay)
  }

  // PAINT (M6): the bounds box, IN0 and ERR, OUT labelled "Abs" to the west, and the family's
  //             three-stroke "F" glyph at x-35. See FpAbsolute.java:62-83.
}
