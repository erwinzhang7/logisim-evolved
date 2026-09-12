// LogRadix.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.circuit.RadixOption),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Why this is here and not in LogisimKernel ───────────────────────────────────────────────
//
// Upstream's `RadixOption` is an `AttributeOption` and therefore drags `Attributes.forOption`,
// a `StringGetter` and the localisation machinery with it. D5 explicitly says display names for
// attributes *and* for values belong to the UI layer, so the display half lives here. The value
// half, `Value.toDisplayString(radix:)`, `toDecimalString(signed:)`, `toStringFromFloatValue()`
// , is already in the kernel and is what this enum calls.
//
// This is a `Sendable` value type rather than a class hierarchy of six singletons: the six
// subclasses differ only in three total functions, which is a switch.
//
// ── Deliberate divergence, stated ──────────────────────────────────────────────────────────
//
// Java's `getMaxLength(BitWidth)` for the two decimal radixes is a 65-arm `switch` that throws
// `AssertionError` on any width outside 0…64. `BitWidth` in this port cannot hold such a width
// (`BitWidth.create` throws first, D13), so the arm is unreachable; `maxLength` computes the
// same numbers arithmetically instead of transcribing 130 case labels. The two are checked
// against each other in `LogRadixTests.decimalMaxLengthsMatchUpstreamTable`, which transcribes
// upstream's table verbatim, so the arithmetic cannot drift from the source silently.

import Foundation
import LogisimKernel

/// `com.cburch.logisim.circuit.RadixOption`; how a logged value is rendered as text.
///
/// The case order is upstream's `RadixOption.OPTIONS` order, because that is the order the
/// radix menu is presented in and a reordering would silently change the UI.
public enum LogRadix: String, CaseIterable, Hashable, Sendable, Codable {
  /// `RADIX_2`.
  case binary = "2"
  /// `RADIX_8`.
  case octal = "8"
  /// `RADIX_10_SIGNED`.
  case decimalSigned = "10signed"
  /// `RADIX_10_UNSIGNED`.
  case decimalUnsigned = "10unsigned"
  /// `RADIX_16`.
  case hexadecimal = "16"
  /// `RADIX_FLOAT`.
  case float = "float"

  /// `RadixOption.RADIX_2`: upstream's default for a freshly created `SignalInfo`.
  public static let `default` = LogRadix.binary

  /// `getSaveString()` / `toString()`. Identical to `rawValue`; named so call sites read like
  /// the Java.
  public var saveString: String { rawValue }

  /// `decode(String)`: unknown strings fall back to `RADIX_2`, exactly as upstream does rather
  /// than throwing. A `.circ` carrying a radix this build does not know must still open (D13).
  public static func decode(_ value: String) -> LogRadix {
    LogRadix(rawValue: value) ?? .binary
  }

  /// `getIndexChar()`; the suffix the chronogram puts after a bus name.
  public var indexCharacter: String {
    switch self {
    case .binary: "b"
    case .octal: "o"
    case .decimalSigned: "s"
    case .decimalUnsigned: "u"
    case .hexadecimal: "h"
    case .float: "f"
    }
  }

  /// `toDisplayString()`. English only: the port has no localisation bundle yet, and inventing
  /// one here would be a second, competing string catalogue.
  public var displayName: String {
    switch self {
    case .binary: "Binary"
    case .octal: "Octal"
    case .decimalSigned: "Decimal (signed)"
    case .decimalUnsigned: "Decimal (unsigned)"
    case .hexadecimal: "Hexadecimal"
    case .float: "Float"
    }
  }

  /// `toString(Value)`: the one method the log and the chronogram actually depend on.
  public func format(_ value: Value) -> String {
    switch self {
    case .binary: value.toDisplayString(radix: 2)
    case .octal: value.toDisplayString(radix: 8)
    case .decimalSigned: value.toDecimalString(signed: true)
    case .decimalUnsigned: value.toDecimalString(signed: false)
    case .hexadecimal: value.toDisplayString(radix: 16)
    case .float: value.toStringFromFloatValue()
    }
  }

  /// `getMaxLength(BitWidth)`; how many characters a value of this width can occupy. The
  /// chronogram uses it to decide whether a bus label fits inside its segment.
  public func maxLength(_ width: BitWidth) -> Int {
    let bits = width.width
    switch self {
    case .binary:
      // Java: `(bits <= 1) ? 1 : bits + ((bits - 1) / 4)`: the separators every four bits.
      return bits <= 1 ? 1 : bits + ((bits - 1) / 4)
    case .octal:
      return max(1, (bits + 2) / 3)
    case .hexadecimal:
      return max(1, (bits + 3) / 4)
    case .float:
      return bits == 64 ? 24 : 12
    case .decimalUnsigned:
      // Digits in 2^bits - 1. Upstream tabulates this; see the file header.
      return LogRadix.decimalDigits(forMagnitudeBits: bits)
    case .decimalSigned:
      // Digits in the widest magnitude a signed value of this width reaches, 2^(bits-1), plus
      // one column for the sign. Width 0 is `1` in upstream's table, not `2`; a zero-width
      // value prints as a single character and has no sign to show.
      if bits <= 0 { return 1 }
      return LogRadix.decimalDigits(forMagnitudeBits: bits - 1) + 1
    }
  }

  /// `getMaxLength(Value)`: Radix2 and Radix8 override it to measure the actual value;
  /// everyone else falls back to the width.
  public func maxLength(of value: Value) -> Int {
    switch self {
    case .binary, .octal: format(value).count
    default: maxLength(BitWidth.known(min(max(value.width, 0), BitWidth.maxWidth)))
    }
  }

  /// Number of decimal digits in `2^bits - 1`, i.e. `ceil(bits * log10 2)` with the `bits == 0`
  /// case pinned to 1 because upstream prints "0" rather than "".
  private static func decimalDigits(forMagnitudeBits bits: Int) -> Int {
    if bits <= 0 { return 1 }
    if bits >= 64 { return 20 }
    // (1 << bits) - 1 fits in UInt64 for bits <= 63.
    return String((UInt64(1) << UInt64(bits)) - 1).count
  }
}
