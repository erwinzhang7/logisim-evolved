// FpToInt.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.arith.floating.FpToInt),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── This component owns the family's rounding-mode attribute ─────────────────────────────────
//
// `MODE_ATTRIBUTE` and its five options are declared here and `FpRound` reads them from here, as
// `FpToInt.MODE_ATTRIBUTE`; exactly the cross-file reference upstream makes. So the two
// components share one attribute *identity*, and a `<a name="mode" val="ceil"/>` means the same
// thing on either. Duplicating the declaration into `FpRound` would create a second attribute
// with the same name, which the port compares by reference: every lookup would miss and both
// components would silently fall back to their defaults. Keep the reference.
//
// ── D13: the `(long)` casts must not trap ────────────────────────────────────────────────────
//
// Every branch here narrows a `double` to a `long`, and the input is whatever is on the wire.
// `∞` is one FP division by zero away, and NaN is what an unconnected input decodes to. Java's
// cast saturates and maps NaN to 0; Swift's `Int64(_:)` traps on both, which would turn an
// ordinary mis-wired circuit into a process death. `JavaMath.narrowToInt64` is the required
// spelling: see its own comment.
//
// ── The delay tracks the OUTPUT width ────────────────────────────────────────────────────────
//
// `(dataWidthOut.getWidth() + 2) * PER_DELAY` reads `StdAttr.WIDTH`, the integer width, not
// FP_WIDTH. The rest of the family uses FP_WIDTH. Transcribed as-is.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.arith.floating.FpToInt`.
public final class FpToInt: InstanceFactoryBase {

  /// `FpToInt._ID`. Do not change, `.circ` files reference it.
  public static let id = "FPToInt"

  /// `PER_DELAY`.
  static let perDelay = 1

  public static let inPort = 0
  public static let out = 1
  public static let err = 2

  // The five rounding modes. Java builds each with the 3-arg
  // `AttributeOption(value, name, StringGetter)` passing the same string twice, so `getValue()`
  // and `toString()` agree; upstream's `propagate` switches on `getValue()`, this port compares
  // the whole option, and the two are the same test. Only `name` is serialised.
  /// `FpToInt.CEILING_OPTION`.
  public static let ceilingOption = AttributeOption(value: "ceil")
  /// `FpToInt.FLOOR_OPTION`.
  public static let floorOption = AttributeOption(value: "floor")
  /// `FpToInt.ROUND_OPTION`.
  public static let roundOption = AttributeOption(value: "round")
  /// `FpToInt.RINT_OPTION`.
  public static let rintOption = AttributeOption(value: "rint")
  /// `FpToInt.TRUNCATE_OPTION`.
  public static let truncateOption = AttributeOption(value: "truncate")

  /// `FpToInt.MODE_ATTRIBUTE`. The `.circ` token is `mode`. Shared with `FpRound`.
  public static let modeAttribute: Attribute<AttributeOption> = Attributes.forOption(
    "mode",
    choices: [ceilingOption, floorOption, roundOption, rintOption, truncateOption])

  public init() {
    super.init(FpToInt.id, displayName: "Floating Point to Integer")
    setAttributes([
      StdAttr.width.binding(BitWidth.known(8)),
      FpArithmeticAttributes.fpWidth.binding(FpArithmeticAttributes.defaultFpWidth),
      FpToInt.modeAttribute.binding(FpToInt.roundOption),
    ])
    setOffsetBounds(Bounds.create(-40, -20, 40, 40))
    setPorts([
      Port(-40, 0, .input, FpArithmeticAttributes.fpWidth),  // IN
      Port(0, 0, .output, StdAttr.width),  // OUT
      Port(-20, 20, .output, 1),  // ERR
    ])
  }

  public override func propagate(_ state: any InstanceState) throws {
    let dataWidthOut = state.attributeValue(StdAttr.width, default: BitWidth.known(8))
    let roundMode = state.attributeValue(FpToInt.modeAttribute, default: FpToInt.roundOption)

    let aValue = state.portValue(FpToInt.inPort).toDoubleValueFromAnyFloat()

    // Upstream's if/else chain, in order. The final `else` is the truncate case and, as written,
    // catches any option that is not one of the first four, with a five-option attribute that
    // is `truncate` alone.
    let outValue: Int64
    if roundMode == FpToInt.ceilingOption {
      outValue = JavaMath.narrowToInt64(aValue.rounded(.up))
    } else if roundMode == FpToInt.floorOption {
      outValue = JavaMath.narrowToInt64(aValue.rounded(.down))
    } else if roundMode == FpToInt.roundOption {
      // `Math.round(double)` returns a `long` directly: no cast, and ties go to +∞.
      outValue = JavaMath.round(aValue)
    } else if roundMode == FpToInt.rintOption {
      outValue = JavaMath.narrowToInt64(aValue.rounded(.toNearestOrEven))
    } else {
      outValue = JavaMath.narrowToInt64(aValue)
    }

    let delay = (dataWidthOut.width + 2) * FpToInt.perDelay
    state.setPort(FpToInt.out, Value.createKnown(dataWidthOut, outValue), delay)
    state.setPort(FpToInt.err, Value.createKnown(BitWidth.known(1), aValue.isNaN ? 1 : 0), delay)
  }

  // PAINT (M6): the bounds box, IN and ERR, and OUT labelled "F→I" to the west.
  //             See FpToInt.java:81-89.
}
