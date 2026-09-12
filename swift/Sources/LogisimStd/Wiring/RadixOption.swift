// RadixOption.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.circuit.RadixOption),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Why a `circuit`-package type lives in `std/wiring` ───────────────────────────────────────
//
// Upstream puts `RadixOption` in `com.cburch.logisim.circuit` even though nothing in that
// package uses it: its readers are `std/wiring` (`Probe`, `Pin`, `PinAttributes`,
// `ProbeAttributes`), `std/io` (`Slider`, `ProgrammableGenerator`), the value-log window and the
// attribute-table renderer. `Probe`/`Pin` are the components that make it *observable in a saved
// file*, `radix.getMaxLength(width)` is what sizes their bounds, so it is ported here, with the
// components that pin its behaviour down. Move it to a `LogisimFile`-level home if a
// `circuit`-package slice ever wants it; nothing about the type is wiring-specific.
//
// **This supersedes `Io/Extra/RadixOptionShim.swift`.** That file is an explicitly temporary
// stand-in ("Replace every reference to `RadixOptionShim` with the real … port once one lands,
// and delete this file") carrying only the six `.circ` tokens. This type carries the same six
// tokens *plus* `getMaxLength`, `toString(Value)` and `getIndexChar()`. `RadixOptionShim.swift`
// is owned by the io/extra slice, so deleting it is reported rather than done: see the final
// report.
//
// ── Shape: abstract class + six singletons → one enum ───────────────────────────────────────
//
// Java models this as `abstract class RadixOption extends AttributeOption` with six private
// subclasses and six `public static final` instances, compared throughout with `==` (reference).
// The subclasses carry no state, they exist only to hold the three overridden methods, so a
// Swift `enum` with `switch`-based methods is exactly equivalent, and it makes the
// name↔case mapping total (D5's preference for native enums over transcribed `AttributeOption`
// arrays). Every upstream `radix == RadixOption.RADIX_16` becomes `radix == .radix16` and means
// the same thing, because the six singletons are the only instances that can ever exist.
//
// **Declaration order is `RadixOption.OPTIONS`**, not alphabetical and not the order the
// `static final`s appear: `OPTIONS = {RADIX_2, RADIX_8, RADIX_10_SIGNED, RADIX_10_UNSIGNED,
// RADIX_16, RADIX_FLOAT}`. `CaseIterable` derives `attributeOptions` from declaration order and
// that is the order the attribute-table combo box offers, so it must match.
//
// ── Not ported ──────────────────────────────────────────────────────────────────────────────
//
//   * `getDisplayGetter()` / `toDisplayString()`; localisation (D5: the kernel keeps raw names
//     only; display strings belong to `LogisimUI`).
//   * `getSaveString()` is kept, as `saveString`, because `Value.fromLogString` and the `.tv`
//     test-vector reader both parse against it rather than against `toString()`.

import Foundation
import LogisimKernel

/// `com.cburch.logisim.circuit.RadixOption`; how a component renders a `Value` for display.
///
/// The raw value is Java's `saveName`, which is simultaneously `toString()`, `getSaveString()`
/// and the `.circ` `<a name="radix" val="…"/>` token. All three are the same string upstream.
public enum RadixOption: String, AttributeOptionValue, CaseIterable, Sendable {
  /// `RadixOption.RADIX_2`.
  case radix2 = "2"
  /// `RadixOption.RADIX_8`.
  case radix8 = "8"
  /// `RadixOption.RADIX_10_SIGNED`.
  case radix10Signed = "10signed"
  /// `RadixOption.RADIX_10_UNSIGNED`.
  case radix10Unsigned = "10unsigned"
  /// `RadixOption.RADIX_16`.
  case radix16 = "16"
  /// `RadixOption.RADIX_FLOAT`.
  case radixFloat = "float"

  /// `RadixOption.OPTIONS`: the order the attribute editor offers, and the order `decode`
  /// scans.
  public static var attributeOptions: [RadixOption] { Array(allCases) }

  /// `RadixOption.ATTRIBUTE`: `Attributes.forOption("radix", …, OPTIONS)`.
  ///
  /// The `.circ` token is `"radix"`. Note `ProbeAttributes`, `PinAttributes`, `Slider` and
  /// `ProgrammableGenerator` all key off this one identity; there is no per-component radix
  /// attribute upstream.
  public static let attribute: Attribute<RadixOption> = Attributes.forOption("radix")

  /// `RadixOption.getSaveString()`.
  public var saveString: String { rawValue }

  /// `RadixOption.decode(String)`.
  ///
  /// Note the fallback: an unrecognised token silently becomes `RADIX_2` rather than throwing.
  /// That is *not* how `RadixOption.ATTRIBUTE` parses; `OptionAttribute.parse` throws
  /// `NumberFormatException("value not among choices")`: so the two entry points disagree, and
  /// deliberately so: `decode` is used by the value-log reader on user-supplied text.
  public static func decode(_ value: String) -> RadixOption {
    for option in attributeOptions where value == option.saveString {
      return option
    }
    return .radix2
  }

  /// `RadixOption.getIndexChar()`.
  ///
  /// Painted at 70% scale in blue next to the value on the "new pins" appearance
  /// (`Probe.paintValue`, `Pin.drawNewStyleValue`). The abstract base returns `""`; every
  /// concrete subclass overrides it, so the empty case is unreachable and is not represented.
  public var indexChar: String {
    switch self {
    case .radix2: return "b"
    case .radix8: return "o"
    case .radix10Signed: return "s"
    case .radix10Unsigned: return "u"
    case .radix16: return "h"
    case .radixFloat: return "f"
    }
  }

  /// `RadixOption.toString(Value)`; the character-for-character display form.
  ///
  /// This is observable in two gated places: `--tty` output and the value-log window. Do not
  /// substitute Swift's own formatting for any of the four routines it delegates to.
  public func toString(_ value: Value, chars: DisplayCharacters = .default) -> String {
    switch self {
    case .radix2: return value.toDisplayString(radix: 2, chars: chars)
    case .radix8: return value.toDisplayString(radix: 8, chars: chars)
    case .radix10Signed: return value.toDecimalString(signed: true, chars: chars)
    case .radix10Unsigned: return value.toDecimalString(signed: false, chars: chars)
    case .radix16: return value.toDisplayString(radix: 16, chars: chars)
    case .radixFloat: return value.toStringFromFloatValue()
    }
  }

  /// `RadixOption.getMaxLength(BitWidth)`; how many characters the widest value of this width
  /// can occupy, which is what sizes `Probe`/`Pin` bounds.
  ///
  /// The two decimal tables are transcribed verbatim rather than derived. They are *not* the
  /// same shape as each other (signed counts the sign column, unsigned does not) and the
  /// grouping runs are irregular, so a closed-form replacement would be a guess.
  ///
  /// Java's `default -> throw new AssertionError("unexpected bit width: " + width)` is an
  /// `Error`, not an `Exception`, so `Simulator`'s `catch (Exception)` would not catch it
  /// anyway. It is also unreachable: `BitWidth` is constructed only through `create`/`known`,
  /// both of which enforce `0…64`. D13's carve-out for invariants no `.circ` file can violate
  /// applies, so it traps.
  public func maxLength(_ width: BitWidth) -> Int {
    let bits = width.width
    switch self {
    case .radix10Signed:
      switch bits {
      case 0: return 1
      case 1, 2, 3, 4: return 2  // 1..8
      case 5, 6, 7: return 3  // 16..64
      case 8, 9, 10: return 4  // 128..512
      case 11, 12, 13, 14: return 5  // 1K..8K
      case 15, 16, 17: return 6  // 16K..64K
      case 18, 19, 20: return 7  // 128K..512K
      case 21, 22, 23, 24: return 8  // 1M..8M
      case 25, 26, 27: return 9  // 16M..64M
      case 28, 29, 30: return 10  // 128M..512M
      case 31, 32, 33, 34: return 11  // 1G..8G
      case 35, 36, 37: return 12  // 16G..64G
      case 38, 39, 40: return 13  // 128G..512G
      case 41, 42, 43, 44: return 14  // 1T..8T
      case 45, 46, 47: return 15  // 16T..64T
      case 48, 49, 50: return 16  // 128..512T
      case 51, 52, 53, 54: return 17  // 1P..8P
      case 55, 56, 57: return 18  // 16P..64P
      case 58, 59, 60: return 19  // 128P..512P
      case 61, 62, 63, 64: return 20  // 1E..4E
      default: preconditionFailure("unexpected bit width: \(width)")
      }
    case .radix10Unsigned:
      switch bits {
      case 0, 1, 2, 3: return 1  // 0..7
      case 4, 5, 6: return 2  // 8..63
      case 7, 8, 9: return 3  // 64..511
      case 10, 11, 12, 13: return 4  // 512..8K-1
      case 14, 15, 16: return 5  // 8K..64K-1
      case 17, 18, 19: return 6  // 64K..512K-1
      case 20, 21, 22, 23: return 7  // 512K..8M-1
      case 24, 25, 26: return 8  // 8M..64M-1
      case 27, 28, 29: return 9  // 64M..512M-1
      case 30, 31, 32, 33: return 10  // 512M..8G-1
      case 34, 35, 36: return 11  // 8G..64G-1
      case 37, 38, 39: return 12  // 64G..512G-1
      case 40, 41, 42, 43: return 13  // 512G..8T-1
      case 44, 45, 46: return 14  // 8T..64T-1
      case 47, 48, 49: return 15  // 64T..512T-1
      case 50, 51, 52, 53: return 16  // 512T..8P-1
      case 54, 55, 56: return 17  // 8P..64P-1
      case 57, 58, 59: return 18  // 64P..512P-1
      case 60, 61, 62, 63: return 19  // 512P..8E-1
      case 64: return 20  // 8E..16E-1
      default: preconditionFailure("unexpected bit width: \(width)")
      }
    case .radix16:
      return max(1, (bits + 3) / 4)
    case .radix8:
      return max(1, (bits + 2) / 3)
    case .radix2:
      // Bit characters plus one space per nibble boundary, matching `toDisplayString()`.
      return (bits <= 1) ? 1 : bits + ((bits - 1) / 4)
    case .radixFloat:
      return bits == 64 ? 24 : 12
    }
  }

  /// `RadixOption.getMaxLength(Value)`.
  ///
  /// The base implementation is `getMaxLength(value.getBitWidth())`; `Radix2` and `Radix8`
  /// override it to measure the rendered string instead, which for a partially-unknown value is
  /// *shorter* than the width-derived bound (an unknown nibble collapses to one `U`). Both
  /// behaviours are preserved.
  ///
  /// Throws because `Value.getBitWidth()` throws (D13: `BitWidth.create` on an out-of-range
  /// width is reachable from a malformed file).
  public func maxLength(_ value: Value, chars: DisplayCharacters = .default) throws -> Int {
    switch self {
    case .radix2:
      return value.toDisplayString(radix: 2, chars: chars).count
    case .radix8:
      return value.toDisplayString(radix: 8, chars: chars).count
    default:
      return maxLength(try value.getBitWidth())
    }
  }
}
