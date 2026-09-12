// FpRound.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.arith.floating.FpRound),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// `FpToInt` with the result kept in floating point: same five modes, same attribute object
// (`FpToInt.modeAttribute`; see that file for why it must be the same one and not a copy), but
// the output port is FP_WIDTH rather than `StdAttr.WIDTH`.
//
// ── The `round` mode makes a round trip through `long`, and that is not a no-op ──────────────
//
// Upstream writes `roundedValue = Math.round(a_val)` into a `double` variable, so the value goes
// `double → long → double` via Java's implicit widening. Four consequences, all preserved by
// spelling the conversion out:
//
//   * NaN becomes `0.0`, not NaN, `Math.round` maps NaN to `0L`, so the OUT pin reads zero
//     while ERR reads 1. Every other mode leaves NaN as NaN.
//   * ±∞ saturates to ±(2^63−1)-ish rather than staying infinite.
//   * A magnitude past 2^53 cannot survive `long → double` exactly, so very large finite inputs
//     come back slightly altered even though rounding them is the identity.
//   * Ties go toward +∞ (`round(-2.5) == -2`), where `rint` gives half-to-even (`-2`) and
//     Swift's `.toNearestOrAwayFromZero` would give `-3`.
//
// The other four modes stay in `double` throughout: `ceil`, `floor` and `rint` are the IEEE
// operations, and the `else` branch is an explicit `(long)` cast: so *it* saturates and
// NaN-maps as well, while `ceil`/`floor`/`rint` do not.
//
// ── ERR tests the INPUT ──────────────────────────────────────────────────────────────────────
//
// `Double.isNaN(a_val)`, not the result: necessarily, since the `round` mode has already turned
// a NaN into `0.0` by the time the result exists.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.arith.floating.FpRound`.
public final class FpRound: InstanceFactoryBase {

  /// `FpRound._ID`. Do not change, `.circ` files reference it.
  public static let id = "FPRound"

  /// `PER_DELAY`.
  static let perDelay = 1

  public static let inPort = 0
  public static let out = 1
  public static let err = 2

  public init() {
    super.init(FpRound.id, displayName: "Floating Point Round")
    setAttributes([
      FpArithmeticAttributes.fpWidth.binding(FpArithmeticAttributes.defaultFpWidth),
      // Java: `FpToInt.MODE_ATTRIBUTE` / `FpToInt.ROUND_OPTION`: the same objects, not copies.
      FpToInt.modeAttribute.binding(FpToInt.roundOption),
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
    let roundMode = state.attributeValue(FpToInt.modeAttribute, default: FpToInt.roundOption)

    let aValue = state.portValue(FpRound.inPort).toDoubleValueFromAnyFloat()

    let roundedValue: Double
    if roundMode == FpToInt.ceilingOption {
      roundedValue = aValue.rounded(.up)
    } else if roundMode == FpToInt.floorOption {
      roundedValue = aValue.rounded(.down)
    } else if roundMode == FpToInt.roundOption {
      // Java: `roundedValue = Math.round(a_val)`; a `long` widened back to `double`. See the
      // header; the trip through `long` is observable and is not simplified away.
      roundedValue = Double(JavaMath.round(aValue))
    } else if roundMode == FpToInt.rintOption {
      roundedValue = aValue.rounded(.toNearestOrEven)
    } else {
      // Java: `roundedValue = (long) a_val`: likewise a cast, then a widening.
      roundedValue = Double(JavaMath.narrowToInt64(aValue))
    }

    let delay = (dataWidth.width + 2) * FpRound.perDelay
    state.setPort(FpRound.out, Value.createKnownFloat(dataWidth, roundedValue), delay)
    state.setPort(FpRound.err, Value.createKnown(BitWidth.known(1), aValue.isNaN ? 1 : 0), delay)
  }

  // PAINT (M6): the bounds box, IN and ERR, and OUT labelled per mode: "⌈x⌉", "⌊x⌋", "⟦x⟧",
  //             "⟦x⟧*" or "Trunc": plus the family's "F" glyph at x-35.
  //             See FpRound.java:64-93.
}
