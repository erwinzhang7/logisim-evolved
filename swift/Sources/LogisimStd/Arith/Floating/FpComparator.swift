// FpComparator.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.arith.floating.FpComparator),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Unordered comparison: all three outputs go low ───────────────────────────────────────────
//
// This is the family's one component whose behaviour is *defined* by IEEE-754's unordered case,
// and it comes out right only because Java and Swift agree that every comparison with a NaN is
// false. With a NaN on either input, `>` `==` `<` are all false, so GT/EQ/LT all read 0 while
// ERR reads 1: the four pins together say "unordered", which is not a state the integer
// `Comparator` can produce.
//
// Two consequences worth stating, since both look like bugs from the outside:
//
//   * A floating (`NIL`) or partly-unknown input decodes to NaN through
//     `toDoubleValueFromAnyFloat()`, so an *unconnected* input reads as unordered, three zeros
//     and an error, rather than as X. The integer `Comparator` propagates X and E per bit;
//     this one has no such path.
//   * `-0.0 == 0.0` is true, so EQ is high for a pair that differs in every stored bit.
//
// ── ERR tests the INPUTS here ────────────────────────────────────────────────────────────────
//
// Unlike the arithmetic members of the family, this component has no floating-point output to
// test, so ERR is `isNaN(a) || isNaN(b)`. `FpMinMax` does the same. Noted because the rest of
// the family tests the *result*, and the two rules disagree: `∞ - ∞` raises ERR on `FpSubtractor`
// with two non-NaN inputs, and nothing here would.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.arith.floating.FpComparator`.
public final class FpComparator: InstanceFactoryBase {

  /// `FpComparator._ID`. Do not change, `.circ` files reference it.
  public static let id = "FPComparator"

  /// `PER_DELAY`.
  static let perDelay = 1

  public static let in0 = 0
  public static let in1 = 1
  public static let gt = 2
  public static let eq = 3
  public static let lt = 4
  public static let err = 5

  public init() {
    super.init(FpComparator.id, displayName: "Floating Point Comparator")
    setAttributes([
      FpArithmeticAttributes.fpWidth.binding(FpArithmeticAttributes.defaultFpWidth)
    ])
    setOffsetBounds(Bounds.create(-40, -20, 40, 40))
    setPorts([
      Port(-40, -10, .input, FpArithmeticAttributes.fpWidth),  // IN0
      Port(-40, 10, .input, FpArithmeticAttributes.fpWidth),  // IN1
      Port(0, -10, .output, 1),  // GT
      Port(0, 0, .output, 1),  // EQ
      Port(0, 10, .output, 1),  // LT
      Port(-20, 20, .output, 1),  // ERR
    ])
  }

  public override func propagate(_ state: any InstanceState) throws {
    let dataWidth = state.attributeValue(
      FpArithmeticAttributes.fpWidth, default: FpArithmeticAttributes.defaultFpWidth)

    let aValue = state.portValue(FpComparator.in0).toDoubleValueFromAnyFloat()
    let bValue = state.portValue(FpComparator.in1).toDoubleValueFromAnyFloat()

    let delay = (dataWidth.width + 2) * FpComparator.perDelay
    state.setPort(
      FpComparator.gt, Value.createKnown(1, aValue > bValue ? 1 : 0), delay)
    state.setPort(
      FpComparator.eq, Value.createKnown(1, aValue == bValue ? 1 : 0), delay)
    state.setPort(
      FpComparator.lt, Value.createKnown(1, aValue < bValue ? 1 : 0), delay)
    state.setPort(
      FpComparator.err,
      Value.createKnown(1, (aValue.isNaN || bValue.isNaN) ? 1 : 0), delay)
  }

  // PAINT (M6): the bounds box, IN0/IN1/ERR, and GT/EQ/LT labelled ">"/"="/"<" to the west, plus
  //             the family's "F" glyph at x-35. See FpComparator.java:85-105.
}
