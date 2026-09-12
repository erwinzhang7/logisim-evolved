// FpMinMax.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.arith.floating.FpMinMax),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── This is the file `JavaMath.min`/`max` exist for ──────────────────────────────────────────
//
// `Math.min`/`Math.max` on `double` are not Swift's `min`/`max`, and the difference is visible at
// this component's own pins:
//
//   * **NaN propagates.** Java returns NaN if either argument is NaN. Swift's generic
//     `min(_:_:)` compares with `<`, which is false against a NaN, so it would return whichever
//     operand happened to be first, and `Double.minimum(_:_:)` is worse for fidelity, since
//     IEEE's `minNum` deliberately returns the *non*-NaN operand. So `min(NaN, 3)` is NaN in
//     Java, `3` under `Double.minimum`, and `NaN` or `3` under Swift's `min` depending on
//     argument order.
//   * **`-0.0 < 0.0`.** Java tests the raw sign bit so `min(0.0, -0.0)` is `-0.0` and
//     `max(-0.0, 0.0)` is `0.0`. Every Swift form treats them as equal and returns the first.
//     The distinction survives all the way to the pin, because `Value.createKnownFloat` keeps
//     the sign bit.
//
// Both go through `JavaMath`, which transcribes the JDK's implementations directly.
//
// ── ERR tests the inputs ─────────────────────────────────────────────────────────────────────
//
// As in `FpComparator`: `isNaN(a) || isNaN(b)`, not the outputs. Here it is nearly the same test
// , with NaN propagating, a NaN input is a NaN output, but not identical, since ERR is one pin
// covering two results.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.arith.floating.FpMinMax`.
public final class FpMinMax: InstanceFactoryBase {

  /// `FpMinMax._ID`. Do not change, `.circ` files reference it.
  public static let id = "FPMinMax"

  /// `PER_DELAY`.
  static let perDelay = 1

  public static let in0 = 0
  public static let in1 = 1
  public static let minPort = 2
  public static let maxPort = 3
  public static let err = 4

  public init() {
    super.init(FpMinMax.id, displayName: "Floating Point Minimum and Maximum")
    setAttributes([
      FpArithmeticAttributes.fpWidth.binding(FpArithmeticAttributes.defaultFpWidth)
    ])
    setOffsetBounds(Bounds.create(-40, -20, 40, 40))
    // Upstream fills `ps[MAX]` before `ps[MIN]`; the array order is by index, so MIN (2) is at
    // y = -10 and MAX (3) is at y = +10: the opposite of the assignment order in the Java.
    setPorts([
      Port(-40, -10, .input, FpArithmeticAttributes.fpWidth),  // IN0
      Port(-40, 10, .input, FpArithmeticAttributes.fpWidth),  // IN1
      Port(0, -10, .output, FpArithmeticAttributes.fpWidth),  // MIN
      Port(0, 10, .output, FpArithmeticAttributes.fpWidth),  // MAX
      Port(-20, 20, .output, 1),  // ERR
    ])
  }

  public override func propagate(_ state: any InstanceState) throws {
    let dataWidth = state.attributeValue(
      FpArithmeticAttributes.fpWidth, default: FpArithmeticAttributes.defaultFpWidth)

    let aValue = state.portValue(FpMinMax.in0).toDoubleValueFromAnyFloat()
    let bValue = state.portValue(FpMinMax.in1).toDoubleValueFromAnyFloat()

    let minValue = JavaMath.min(aValue, bValue)
    let maxValue = JavaMath.max(aValue, bValue)

    let delay = (dataWidth.width + 2) * FpMinMax.perDelay
    state.setPort(FpMinMax.minPort, Value.createKnownFloat(dataWidth, minValue), delay)
    state.setPort(FpMinMax.maxPort, Value.createKnownFloat(dataWidth, maxValue), delay)
    state.setPort(
      FpMinMax.err, Value.createKnown(1, (aValue.isNaN || bValue.isNaN) ? 1 : 0), delay)
  }

  // PAINT (M6): the bounds box, IN0/IN1/ERR, MIN and MAX labelled "Min"/"Max" to the west, and
  //             the family's "F" glyph at x-35. See FpMinMax.java:82-101.
}
