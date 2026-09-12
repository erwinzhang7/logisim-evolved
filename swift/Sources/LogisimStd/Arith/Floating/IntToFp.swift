// IntToFp.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.arith.floating.IntToFp),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── It borrows the signedness attribute from the integer `Comparator` ────────────────────────
//
// Upstream reads `Comparator.MODE_ATTR` / `Comparator.SIGNED_OPTION` / `UNSIGNED_OPTION`:
// literally the attribute object the integer comparator declares, from another package. This
// port already keeps those `public` on `Arith/Comparator.swift` for `Multiplier` and `Divider`,
// which do the same thing, so the reference carries across unchanged. As with
// `FpToInt.modeAttribute`, it must be *the same object*: re-declaring an `Attributes.forOption`
// named `"mode"` here would compare unequal by reference and every lookup would silently take
// the default.
//
// ── `Int128` is wide enough here, unlike D15's cases ─────────────────────────────────────────
//
// `Value.toBigInteger(unsigned:)` returns an `Int128`, and D15 records that this is too narrow
// for `Multiplier`, `Divider` and `Exponentiator` because those multiply or exponentiate the
// result. This component only *converts* it, and the source is at most 64 bits, so the value
// always fits and no wider type is needed. `Double(Int128)` rounds to nearest, ties to even:
// the same rule as `BigInteger.doubleValue()`.
//
// ── The unknown-input path ───────────────────────────────────────────────────────────────────
//
// Upstream computes `a.toBigInteger(unsigned)` unconditionally and *then* discards it when the
// input is not fully defined, substituting NaN. That matters because `Value.toLongValue()`
// returns `-1` for an unknown or error value, so without the `isFullyDefined()` guard an
// unconnected input would convert to `-1.0` (signed) or `2^width − 1` (unsigned) rather than
// raising ERR. The guard is the whole error path of this component.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.arith.floating.IntToFp`.
public final class IntToFp: InstanceFactoryBase {

  /// `IntToFp._ID`. Do not change; `.circ` files reference it. Note the capitalisation is
  /// `IntToFP`, not `IntToFp`; upstream's class name and its `_ID` disagree.
  public static let id = "IntToFP"

  /// `PER_DELAY`.
  static let perDelay = 1

  public static let inPort = 0
  public static let out = 1
  public static let err = 2

  public init() {
    super.init(IntToFp.id, displayName: "Integer to Floating Point")
    setAttributes([
      StdAttr.width.binding(BitWidth.known(8)),
      FpArithmeticAttributes.fpWidth.binding(FpArithmeticAttributes.defaultFpWidth),
      // Java: `Comparator.MODE_ATTR` / `Comparator.SIGNED_OPTION`, the integer comparator's.
      Comparator.modeAttr.binding(Comparator.signedOption),
    ])
    setOffsetBounds(Bounds.create(-40, -20, 40, 40))
    setPorts([
      Port(-40, 0, .input, StdAttr.width),  // IN
      Port(0, 0, .output, FpArithmeticAttributes.fpWidth),  // OUT
      Port(-20, 20, .output, 1),  // ERR
    ])
  }

  public override func propagate(_ state: any InstanceState) throws {
    let dataWidthIn = state.attributeValue(StdAttr.width, default: BitWidth.known(8))
    let dataWidthOut = state.attributeValue(
      FpArithmeticAttributes.fpWidth, default: FpArithmeticAttributes.defaultFpWidth)
    let unsigned =
      state.attributeValue(Comparator.modeAttr, default: Comparator.signedOption)
      == Comparator.unsignedOption

    let a = state.portValue(IntToFp.inPort)
    let aValue = a.toBigInteger(unsigned: unsigned)

    let outValue = a.isFullyDefined() ? Double(aValue) : Double.nan

    // Java: the delay reads the INPUT width, unlike `FpToInt`, which reads its output's.
    let delay = (dataWidthIn.width + 2) * IntToFp.perDelay
    state.setPort(IntToFp.out, Value.createKnownFloat(dataWidthOut, outValue), delay)
    state.setPort(IntToFp.err, Value.createKnown(BitWidth.known(1), outValue.isNaN ? 1 : 0), delay)
  }

  // PAINT (M6): the bounds box, IN and ERR, and OUT labelled "I→F" to the west.
  //             See IntToFp.java:64-72.
}
