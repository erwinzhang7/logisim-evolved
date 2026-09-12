// FpLogarithm.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.arith.floating.FpLogarithm),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// `FpExponentiator`'s mirror: four modes, one of which (`logxy`) takes a second input. The
// transcendental accuracy caveat in JavaMath.swift applies to all four.
//
// ── The option ORDER is not the mode order ───────────────────────────────────────────────────
//
// The attribute declares its choices as `{LOGXY, LOG, LOG10, LOG1P}` while the constants are
// declared `LOGXY, LOG1P, LOG, LOG10`. The choice array is what the UI's dropdown shows and the
// order is kept from the array, not the declarations. Transcribed from the array.
//
// ── `logxy` is two logarithms and a divide, not a base-changing primitive ────────────────────
//
// `Math.log(a) / Math.log(b)`, so it inherits both calls' rounding and the divide's. Notably
// `log_b(b)` is not exactly 1 for most bases, and base 1 gives `x / 0`; ±∞ or NaN. Upstream
// makes no special case and neither does this.
//
// ── ARB's second port is BASE at index 3, and ALOG moves ─────────────────────────────────────
//
// Same shape as `FpExponentiator`, with the y offsets the other way round: in two-input mode
// ALOG sits at y = −10 and BASE at y = +10, where the exponentiator puts its exponent at +10 and
// its base at −10.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.arith.floating.FpLogarithm`.
public final class FpLogarithm: InstanceFactoryBase {

  /// `FpLogarithm._ID`. Do not change, `.circ` files reference it.
  public static let id = "FPLogarithm"

  /// `PER_DELAY`.
  static let perDelay = 1

  /// `ALOG`: the antilogarithm, i.e. the value being taken the log of.
  public static let alog = 0
  public static let out = 1
  public static let err = 2
  /// `BASE`: present only in `logxy` mode.
  public static let base = 3

  /// `FpLogarithm.LOGXY`, arbitrary base.
  public static let logxyOption = AttributeOption(value: "logxy")
  /// `FpLogarithm.LOG1P`: `log(1 + x)`, accurate for small `x`.
  public static let log1pOption = AttributeOption(value: "log1p")
  /// `FpLogarithm.LOG`, natural log.
  public static let logOption = AttributeOption(value: "log")
  /// `FpLogarithm.LOG10`.
  public static let log10Option = AttributeOption(value: "log10")

  /// `FpLogarithm.LOG_MODE`. The `.circ` token is `mode`; the choices are in upstream's array
  /// order, which is not its declaration order, see the header.
  public static let logMode: Attribute<AttributeOption> = Attributes.forOption(
    "mode", choices: [logxyOption, logOption, log10Option, log1pOption])

  public init() {
    super.init(FpLogarithm.id, displayName: "Floating Point Logarithm")
    setAttributes([
      FpArithmeticAttributes.fpWidth.binding(FpArithmeticAttributes.defaultFpWidth),
      FpLogarithm.logMode.binding(FpLogarithm.logxyOption),
    ])
    setOffsetBounds(Bounds.create(-40, -20, 40, 40))
  }

  /// `configurePorts(Instance)`.
  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    let mode = attributes[FpLogarithm.logMode, default: FpLogarithm.logxyOption]
    let isSingleInput = mode != FpLogarithm.logxyOption
    if isSingleInput {
      return [
        Port(-40, 0, .input, FpArithmeticAttributes.fpWidth),  // ALOG
        Port(0, 0, .output, FpArithmeticAttributes.fpWidth),  // OUT
        Port(-20, 20, .output, 1),  // ERR
      ]
    }
    return [
      Port(-40, -10, .input, FpArithmeticAttributes.fpWidth), // ALOG: y moves to -10
      Port(0, 0, .output, FpArithmeticAttributes.fpWidth),  // OUT
      Port(-20, 20, .output, 1),  // ERR
      Port(-40, 10, .input, FpArithmeticAttributes.fpWidth),  // BASE
    ]
  }

  public override func propagate(_ state: any InstanceState) throws {
    let dataWidth = state.attributeValue(
      FpArithmeticAttributes.fpWidth, default: FpArithmeticAttributes.defaultFpWidth)
    let mode = state.attributeValue(FpLogarithm.logMode, default: FpLogarithm.logxyOption)

    let aValue = state.portValue(FpLogarithm.alog).toDoubleValueFromAnyFloat()

    let outValue: Double
    if mode == FpLogarithm.logxyOption {
      let bValue = state.portValue(FpLogarithm.base).toDoubleValueFromAnyFloat()
      outValue = log(aValue) / log(bValue)
    } else if mode == FpLogarithm.logOption {
      outValue = log(aValue)
    } else if mode == FpLogarithm.log10Option {
      outValue = log10(aValue)
    } else {
      outValue = log1p(aValue)
    }

    let delay = (dataWidth.width + 2) * FpLogarithm.perDelay
    state.setPort(FpLogarithm.out, Value.createKnownFloat(dataWidth, outValue), delay)
    state.setPort(
      FpLogarithm.err, Value.createKnown(BitWidth.known(1), outValue.isNaN ? 1 : 0), delay)
  }

  // PAINT (M6): the bounds box, ERR, ALOG (and BASE in logxy mode), and OUT labelled "logᵧx",
  //             "log", "log₁₀" or "log+1" to the west, plus the family's "F" glyph at x-35.
  //             See FpLogarithm.java:112-148.
}
