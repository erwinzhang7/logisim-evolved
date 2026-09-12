//
//  BitWidth.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
//  specifically `src/main/java/com/cburch/logisim/data/BitWidth.java`.
//  logisim-evolution is free software released under the GNU GPLv3; this translation is
//  therefore GPL-3.0-only. See LICENSE.md.
//
//  ---------------------------------------------------------------------------------------
//  PROVISIONAL; MINIMAL. `Value` cannot be expressed without `BitWidth`, so this file was
//  written as a dependency of the Value port. It covers the non-UI surface of BitWidth.java
//  only. Deliberately NOT ported here:
//
//    * `BitWidth.Attribute` (the nested `Attribute<BitWidth>` subclass). It imports
//      `java.awt.Component` and `com.cburch.logisim.gui.generic.ComboBox` to build a cell
//      editor: UI, and therefore banned from LogisimKernel by D9. It also depends on the
//      `Attribute<V>` design, which is still OPEN (D5).
//
//  When BitWidth.java is ported as its own reviewed task, that port supersedes this file.
//  ---------------------------------------------------------------------------------------
//

/// A bit width in `0...64`. Width 0 is `BitWidth.unknown` (Java: `BitWidth.UNKNOWN`) and
/// denotes the "no width yet" placeholder, not a zero-bit bus.
///
/// Java models this as an interned final class with a `prefab[]` table so that `==`
/// reference comparison works. This port is a `struct`, so equality is structural; because
/// the Java only ever hands out interned instances, the two agree everywhere.
public struct BitWidth: Hashable, Comparable, CustomStringConvertible, Sendable {

  /// Java: `BitWidth.MAXWIDTH = Value.MAX_WIDTH`.
  public static let maxWidth: Int = Value.maxWidth

  /// Java: `BitWidth.MINWIDTH`.
  public static let minWidth: Int = 1

  /// Java: `BitWidth.UNKNOWN` (width 0).
  public static let unknown = BitWidth(unchecked: 0)

  /// Java: `BitWidth.ONE`.
  public static let one = BitWidth(unchecked: 1)

  /// Java: the package-private `final int width` field, exposed via `getWidth()`.
  public let width: Int

  private init(unchecked width: Int) {
    self.width = width
  }

  /// Java: `BitWidth.create(int)`; throws `IllegalArgumentException` for an out-of-range
  /// width (`BitWidth.java:72`, `:74`).
  ///
  /// Throws rather than traps (D13). The width reaching here comes from a `.circ` attribute,
  /// so a malformed file must produce a circuit error rather than terminating the app;
  /// the same reasoning that already made `parse` throwing.
  public static func create(_ width: Int) throws -> BitWidth {
    if width < 0 {
      throw BitWidthParseError.message("width \(width) must be positive")
    } else if width > maxWidth {
      throw BitWidthParseError.message("width \(width) must be at most \(maxWidth)")
    }
    return BitWidth(unchecked: width)
  }

  /// Non-throwing variant for widths already known to be in range; literals and values
  /// derived from an existing `BitWidth`. Traps only on a genuine programmer error, never
  /// on file input.
  public static func known(_ width: Int) -> BitWidth {
    precondition(width >= 0 && width <= maxWidth, "width \(width) out of range 0...\(maxWidth)")
    return BitWidth(unchecked: width)
  }

  /// Java: `BitWidth.parse(String)`.
  ///
  /// Deviation: the Java signals malformed input with `NumberFormatException` /
  /// `IllegalArgumentException`, both unchecked. Because `parse` consumes untrusted text
  /// from `.circ` files, this port makes the failure a thrown Swift error rather than a
  /// trap. Callers in the Java already wrap this in try/catch.
  public static func parse(_ str: String) throws -> BitWidth {
    if str.isEmpty {
      throw BitWidthParseError.message("Width string cannot be null")
    }
    var text = Substring(str)
    if text.first == "/" { text = text.dropFirst() }
    // Java uses Integer.parseInt: strictly 32-bit, and accepting any Unicode decimal digit
    // through Character.digit. Swift's Int(_:) is 64-bit and ASCII-only, so it rejected
    // widths Java accepts (e.g. an Arabic-Indic "٨") and accepted out-of-Int32 strings that
    // Java rejects with a different error.
    guard let v = javaParseInt32(text) else {
      throw BitWidthParseError.message("For input string: \"\(text)\"")
    }
    if v < 0 {
      throw BitWidthParseError.message("width \(v) must be positive")
    }
    if v > maxWidth {
      throw BitWidthParseError.message("width \(v) must be at most \(maxWidth)")
    }
    return BitWidth(unchecked: v)
  }

  /// Java: `getMask()`. Note that width 0 yields 0, not `-1`.
  /// Java: `BitWidth.getMask()`.
  ///
  /// The subtraction must WRAP. At width 63, `1 << 63` is `Int64.min`, and Java's `- 1`
  /// wraps to `Long.MAX_VALUE`; the correct 63-bit mask. Swift's checked `-` traps there
  /// instead, which killed the process for any Register, Counter or Shift Register with
  /// Data Bits = 63 (`getMask` has 12 Java call sites, including `RegisterPoker.java:45`
  /// and `CounterAttributes.java:102`). Widths 0 and 64 take the early returns; 1...62 do
  /// not overflow; 63 was the only affected width and the only one the tests skipped.
  public var mask: Int64 {
    if width == 0 { return 0 }
    if width == BitWidth.maxWidth { return -1 }
    return (Int64(1) &<< Int64(width)) &- 1
  }

  /// Java: `compareTo` returns `this.width - other.width`.
  public static func < (lhs: BitWidth, rhs: BitWidth) -> Bool {
    lhs.width < rhs.width
  }

  /// Java: `toString()` returns `"" + width`.
  public var description: String { String(width) }
}

/// Error thrown by `BitWidth.parse(_:)`. See the deviation note on that method.
public enum BitWidthParseError: Error, Equatable, CustomStringConvertible, Sendable {
  case message(String)

  public var description: String {
    switch self {
    case .message(let m): return m
    }
  }
}
