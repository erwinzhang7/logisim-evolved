// FpArithmeticAttributes.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (`com.cburch.logisim.instance.StdAttr.FP_WIDTH` and the
// `Attributes.forOption(String, StringGetter, BitWidth[])` shape it is built from),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// SEAM; `fpWidth` BELONGS IN `LogisimFile/StdAttr.swift`, NOT HERE
//
// Upstream declares this attribute as `StdAttr.FP_WIDTH`, and every one of the seventeen
// floating-point components names it. The Swift `StdAttr` deliberately left it out, and says so:
//
//     * `FP_WIDTH`: `Attributes.forOption` over a `BitWidth[]`, i.e. an option attribute whose
//       choices are widths rather than named options. Only floating-point components (M4) read
//       it.
//
// This slice is that tranche, but `LogisimFile/StdAttr.swift` is not a file it owns, so the
// declaration lands here instead. **The integrator should move `fpWidth` into `StdAttr` as
// `StdAttr.fpWidth` and delete this type**, updating the seventeen references. Nothing else
// needs to change: the attribute's identity is what matters (attributes compare by reference,
// D5/`AnyAttribute.==`), and moving one `let` between files preserves it as long as it stays a
// single stored global.
//
// Until that move, treat `FpArithmeticAttributes.fpWidth` as the one and only FP_WIDTH in the
// program. A second, independently-constructed `Attributes.forOption("fpwidth", …)` would be a
// *different* attribute despite the identical name, and every `attributeValue(…)` lookup keyed
// on it would silently return `nil` and fall through to the default, which is a component that
// ignores its own width attribute. That failure is invisible in a diff and is the reason this is
// spelled out at length.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// WHY `forBitWidthOption` IS NOT `Attributes.forBitWidth`
//
// The two are not interchangeable and the difference is observable in a `.circ`:
//
//   * `Attributes.forBitWidth("fpwidth")` accepts every width 1…64. It would load
//     `<a name="fpwidth" val="17"/>` happily, and the component would then hand 17 to
//     `Value.createKnownFloat(_:_:)`, whose default arm returns the *one-bit* `ERROR`
//     singleton: a silently mis-widthed output.
//   * Upstream's `Attributes.forOption(…, BitWidth[]{8,16,32,64})` rejects 17 outright with
//     `NumberFormatException("value not among choices")`, which the file reader surfaces as a
//     load error.
//
// So the option form is the fidelity-correct one, and it is not expressible with the kernel's
// existing `Attributes.forOption` (which is typed to `AttributeOption`, not `BitWidth`). Hence
// the local factory. Its codec matches Java's `OptionAttribute` exactly: `parse` compares the
// text against each choice's `toString()`, `BitWidth.toString()` is `String.valueOf(width)`,
// and `toStandardString` is the inherited `Attribute.toStandardString`, i.e. the same string.
//
// Storage is `.bitWidth`, the same case `Attributes.forBitWidth` uses, so a value written by
// either round-trips through the other. That matters because a `.circ` does not record which
// factory made an attribute.

import Foundation
import LogisimFile
import LogisimKernel

/// The attribute shared by the seventeen `std.arith.floating` components.
public enum FpArithmeticAttributes {

  /// `StdAttr.FP_WIDTH`: the IEEE-754 format, as a bit width restricted to the four the
  /// port can actually encode (`Value.createKnownFloat` handles 8, 16, 32 and 64 and returns
  /// `ERROR` for anything else).
  ///
  /// The `.circ` token is `fpwidth`.
  public static let fpWidth: Attribute<BitWidth> = forBitWidthOption(
    "fpwidth",
    choices: [BitWidth.known(8), BitWidth.known(16), BitWidth.known(32), BitWidth.known(64)])

  /// Java's `BitWidth.create(32)`, the default every FP component declares. A literal, so the
  /// non-throwing `known` (D13).
  public static let defaultFpWidth = BitWidth.known(32)

  /// `Attributes.forOption(String, StringGetter, BitWidth[])`; an `OptionAttribute` whose
  /// choices are `BitWidth`s.
  ///
  /// Kept `public` because `FpToFp` builds two more of these (`fpwidthin` / `fpwidthout`) with
  /// the same choice set.
  public static func forBitWidthOption(
    _ name: String, choices: [BitWidth]
  ) -> Attribute<BitWidth> {
    Attribute(
      name: name,
      codec: AttributeCodec(
        // `OptionAttribute.parse`: linear scan comparing `value.equals(val.toString())`, then
        // `throw new NumberFormatException("value not among choices")`. D13: reachable from
        // any `.circ`, so it throws rather than substituting a default.
        parse: { text in
          guard let match = choices.first(where: { String($0.width) == text }) else {
            throw AttributeParseError.numberFormat("value not among choices")
          }
          return match
        },
        toStandardString: { AttributeTextFormat.standardScrub(String($0.width)) },
        encode: { .bitWidth($0.attributeBitWidth) },
        // `decode` is restricted to the choice set, not to any `.bitWidth`. An `OptionAttribute`
        // in Java can only ever hold one of its own options, `parse` is the sole way a value
        // enters from a file, and it returns an element of `vals`, so a stored width outside
        // the set is a value this attribute could not have produced. Answering `nil` makes
        // `accepts` false, which is how the port spells "this value does not belong to this
        // attribute" (`AnyAttribute.accepts`).
        decode: {
          guard case .bitWidth(let width) = $0,
            let value = BitWidth(attributeBitWidth: width),
            choices.contains(where: { $0.width == value.width })
          else { return nil }
          return value
        }))
  }
}
