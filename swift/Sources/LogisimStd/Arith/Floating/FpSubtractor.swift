// FpSubtractor.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.arith.floating.FpSubtractor),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// `FpAdder` with `-`. See that file for the family's four invariants; nothing here departs from
// them. Note there is no borrow-in/borrow-out pair: unlike the integer `Subtractor`, which
// carries both, this component is two ports lighter because IEEE subtraction has nowhere to put
// them.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.arith.floating.FpSubtractor`.
public final class FpSubtractor: InstanceFactoryBase {

  /// `FpSubtractor._ID`. Do not change, `.circ` files reference it.
  public static let id = "FPSubtractor"

  /// `PER_DELAY`.
  static let perDelay = 1

  public static let in0 = 0
  public static let in1 = 1
  public static let out = 2
  public static let err = 3

  public init() {
    super.init(FpSubtractor.id, displayName: "Floating Point Subtractor")
    setAttributes([
      FpArithmeticAttributes.fpWidth.binding(FpArithmeticAttributes.defaultFpWidth)
    ])
    setOffsetBounds(Bounds.create(-40, -20, 40, 40))
    setPorts([
      Port(-40, -10, .input, FpArithmeticAttributes.fpWidth),  // IN0, the minuend
      Port(-40, 10, .input, FpArithmeticAttributes.fpWidth),  // IN1, the subtrahend
      Port(0, 0, .output, FpArithmeticAttributes.fpWidth),  // OUT
      Port(-20, 20, .output, 1),  // ERR
    ])
  }

  public override func propagate(_ state: any InstanceState) throws {
    let dataWidth = state.attributeValue(
      FpArithmeticAttributes.fpWidth, default: FpArithmeticAttributes.defaultFpWidth)

    let aValue = state.portValue(FpSubtractor.in0).toDoubleValueFromAnyFloat()
    let bValue = state.portValue(FpSubtractor.in1).toDoubleValueFromAnyFloat()

    let outValue = aValue - bValue

    let delay = (dataWidth.width + 2) * FpSubtractor.perDelay
    state.setPort(FpSubtractor.out, Value.createKnownFloat(dataWidth, outValue), delay)
    state.setPort(
      FpSubtractor.err, Value.createKnown(BitWidth.known(1), outValue.isNaN ? 1 : 0), delay)
  }

  // PAINT (M6): the bounds box, all four ports, a "-" stroke at (x-15…x-5, y), and the family's
  //             three-stroke "F" glyph at x-35. See FpSubtractor.java:64-83.
}
