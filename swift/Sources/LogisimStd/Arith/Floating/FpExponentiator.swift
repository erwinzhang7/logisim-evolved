// FpExponentiator.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.arith.floating.FpExponentiator),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THIS IS **NOT** THE `Exponentiator` D15 WAIVES, READ THIS BEFORE DELETING THE FILE
//
// There are two exponentiators upstream and they have nothing in common but a name:
//
//   * `com.cburch.logisim.std.arith.Exponentiator`, the INTEGER one. `Exponentiator.java:73`
//     computes `aa.pow(b)` on a `BigInteger`, which is unbounded (`3^100` is 5.15e47). D15
//     waives it as blocked on an arbitrary-precision integer dependency Swift's standard library
//     does not have, and `Arith/ArithmeticLibrary.swift` carries its NOT-PORTED note. **That note
//     stays as it is; nothing here changes it.**
//   * `com.cburch.logisim.std.arith.floating.FpExponentiator`: THIS one. It computes
//     `Math.pow(double, double)`, `Math.exp` or `Math.expm1`, all of which are ordinary
//     `Double` operations that Swift has natively. There is no big-integer dependency anywhere
//     in it, so D15's waiver does not reach it and the component is ported in full.
//
// Ported deliberately, and recorded here because "Exponentiator is waived" is exactly the
// half-remembered fact that would get this file deleted later. If it were skipped,
// `FPArithmeticLibrary` would publish sixteen tools where upstream publishes seventeen and every
// `<comp name="FPExponentiator">` in a saved circuit would fail to resolve; a real parity loss
// for no reason.
//
// ── The transcendentals are not bit-exact ────────────────────────────────────────────────────
//
// `pow`, `exp` and `expm1` land in Darwin's libm here and in a HotSpot intrinsic or fdlibm in
// Java. Both promise ≤ 1–2 ulp and neither promises the same bits. JavaMath.swift explains why
// this is not fixable short of porting fdlibm, and why the differential harness should compare
// this component with a tolerance.
//
// ── Ports depend on the mode, and the extra one is index 3 ───────────────────────────────────
//
// `ARB` (arbitrary base) takes two inputs, `EXP`/`EXPM1` take one. Upstream numbers `BASE = 3`,
// after ERR, and moves `EXPO` from y = 0 to y = +10 when the base pin appears. So the array is
// `[EXPO, OUT, ERR]` or `[EXPO, OUT, ERR, BASE]`; the shared prefix keeps OUT and ERR at the
// same indices in both shapes, which is what lets `propagate` write them without checking the
// mode.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.arith.floating.FpExponentiator`.
public final class FpExponentiator: InstanceFactoryBase {

  /// `FpExponentiator._ID`. Do not change, `.circ` files reference it.
  public static let id = "FPExponentiator"

  /// `PER_DELAY`.
  static let perDelay = 1

  public static let expo = 0
  public static let out = 1
  public static let err = 2
  /// `BASE`: present only in `arb` mode; numbered after ERR, as upstream does.
  public static let base = 3

  /// `FpExponentiator.ARB`, arbitrary base, `base ^ exponent`.
  public static let arbOption = AttributeOption(value: "arb")
  /// `FpExponentiator.EXP`, `e ^ x`.
  public static let expOption = AttributeOption(value: "exp")
  /// `FpExponentiator.EXPM1`: `e ^ x − 1`, computed as `expm1` so it stays accurate near zero.
  public static let expm1Option = AttributeOption(value: "expm1")

  /// `FpExponentiator.EXP_MODE`. The `.circ` token is `mode`.
  public static let expMode: Attribute<AttributeOption> = Attributes.forOption(
    "mode", choices: [arbOption, expOption, expm1Option])

  public init() {
    super.init(FpExponentiator.id, displayName: "Floating Point Exponentiator")
    setAttributes([
      FpArithmeticAttributes.fpWidth.binding(FpArithmeticAttributes.defaultFpWidth),
      FpExponentiator.expMode.binding(FpExponentiator.arbOption),
    ])
    setOffsetBounds(Bounds.create(-40, -20, 40, 40))
  }

  /// `configurePorts(Instance)`.
  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    let mode = attributes[FpExponentiator.expMode, default: FpExponentiator.arbOption]
    // Java: `isSingleInput = getAttributeValue(EXP_MODE) != ARB`; anything that is not ARB.
    let isSingleInput = mode != FpExponentiator.arbOption
    if isSingleInput {
      return [
        Port(-40, 0, .input, FpArithmeticAttributes.fpWidth),  // EXPO
        Port(0, 0, .output, FpArithmeticAttributes.fpWidth),  // OUT
        Port(-20, 20, .output, 1),  // ERR
      ]
    }
    return [
      Port(-40, 10, .input, FpArithmeticAttributes.fpWidth), // EXPO; note y moves to +10
      Port(0, 0, .output, FpArithmeticAttributes.fpWidth),  // OUT
      Port(-20, 20, .output, 1),  // ERR
      Port(-40, -10, .input, FpArithmeticAttributes.fpWidth),  // BASE
    ]
  }

  public override func propagate(_ state: any InstanceState) throws {
    let dataWidth = state.attributeValue(
      FpArithmeticAttributes.fpWidth, default: FpArithmeticAttributes.defaultFpWidth)
    let mode = state.attributeValue(FpExponentiator.expMode, default: FpExponentiator.arbOption)

    let expoValue = state.portValue(FpExponentiator.expo).toDoubleValueFromAnyFloat()

    let outValue: Double
    if mode == FpExponentiator.arbOption {
      let baseValue = state.portValue(FpExponentiator.base).toDoubleValueFromAnyFloat()
      outValue = pow(baseValue, expoValue)
    } else {
      outValue = mode == FpExponentiator.expOption ? exp(expoValue) : expm1(expoValue)
    }

    let delay = (dataWidth.width + 2) * FpExponentiator.perDelay
    state.setPort(FpExponentiator.out, Value.createKnownFloat(dataWidth, outValue), delay)
    state.setPort(
      FpExponentiator.err, Value.createKnown(BitWidth.known(1), outValue.isNaN ? 1 : 0), delay)
  }

  // PAINT (M6): the bounds box, ERR, EXPO (and BASE in arb mode), and OUT labelled "yˣ", "eˣ" or
  //             "eˣ-1" to the west, plus the family's "F" glyph at x-35.
  //             See FpExponentiator.java:109-142.
}
