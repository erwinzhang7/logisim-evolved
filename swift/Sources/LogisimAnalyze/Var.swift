//
//  Var.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution, specifically
//  `src/main/java/com/cburch/logisim/analyze/model/Var.java`. GPL-3.0-only. See LICENSE.md.
//

/// Java: `com.cburch.logisim.analyze.model.Var`: a named input or output of the analyzed
/// circuit, one bit wide unless it is a bus.
///
/// Java's `equals`/`hashCode` are over `(name, width)`; the synthesised Swift conformances
/// agree. `Var` is a value type here because nothing in the analyze package relies on its
/// identity; `VariableList` looks variables up with `indexOf`, which is `equals`-based.
public struct Var: Hashable, CustomStringConvertible, Sequence, Sendable {
  /// Java: `public final String name`.
  public let name: String
  /// Java: `public final int width`.
  public let width: Int

  public init(_ name: String, _ width: Int) {
    self.name = name
    self.width = width
  }

  /// Java: `toString()`: `"a[3..0]"` for a bus, plain `"a"` for a single bit.
  public var description: String {
    width > 1 ? "\(name)[\(width - 1)..0]" : name
  }

  /// Java: `bitName(int)`.
  ///
  /// Java throws `IllegalArgumentException` here, but unlike the D13 sites this one is not
  /// reachable from user input: every caller derives `b` from `width` itself (`VariableList`
  /// uses `bitName(0)`, the iterator counts down from `width - 1`). It stays a trap, which
  /// is the D13 rule for an invariant a caller cannot violate.
  public func bitName(_ b: Int) -> String {
    precondition(b >= 0 && b < width, "Can't access bit \(b) of \(width)")
    return width > 1 ? "\(name)[\(b)]" : name
  }

  /// Java: `iterator()`; yields bit names from the **most** significant down to bit 0.
  /// `VariableList` depends on that direction: it is the order the truth-table columns are
  /// laid out in.
  public func makeIterator() -> AnyIterator<String> {
    var bitIndex = width - 1
    return AnyIterator {
      guard bitIndex >= 0 else { return nil }
      defer { bitIndex -= 1 }
      return bitName(bitIndex)
    }
  }

  /// Java: `Var.parse(String)`.
  ///
  /// Offsets in the thrown `ParserError` are indices into the **trimmed** string, matching
  /// Java. The bit-count arithmetic is deliberately done in `Int32` so that an absurd width
  /// such as `x[2147483647..0]` overflows exactly the way Java's `1 + Integer.parseInt` does
  /// and lands on `variableFormat` rather than `variableTooMuchBits`.
  public static func parse(_ input: String) throws -> Var {
    var s = Array(input.trimmedForAnalyze())
    let i = s.firstIndex(of: "[") ?? -1
    let j = s.lastIndex(of: "]") ?? -1
    var w: Int32 = 1
    if 0 < i && i < j && j == s.count - 1 {
      let braces = String(s[(i + 1)..<j])
      guard braces.hasSuffix("..0") else {
        throw ParserError("variableFormat", offset: i)
      }
      let digits = String(braces.dropLast(3))
      guard let parsed = Int32(digits) else {
        // Java: NumberFormatException -> variableFormat.
        throw ParserError("variableFormat", offset: i)
      }
      w = parsed &+ 1
      if w < 1 {
        throw ParserError("variableFormat", offset: i)
      } else if w > 32 {
        throw ParserError("variableTooMuchBits", offset: i)
      }
      s = Array(String(s[0..<i]).trimmedForAnalyze())
    } else if i >= 0 || j >= 0 {
      throw ParserError("variableFormat", offset: i >= 0 ? i : j)
    }
    return Var(String(s), Int(w))
  }

  /// Java: `Var.Bit`: a single bit of a (possibly wide) variable, as it appears inside an
  /// `Expression`: `"a[3]"`, or `"a"` with `bitIndex == -1` for a one-bit variable.
  public struct Bit: Hashable, CustomStringConvertible, Sendable {
    public let name: String
    /// Java: `-1 means no index`.
    public let bitIndex: Int

    public init(_ name: String, _ bitIndex: Int) {
      self.name = name
      self.bitIndex = bitIndex
    }

    public var description: String {
      bitIndex == -1 ? name : "\(name)[\(bitIndex)]"
    }

    /// Java: `Var.Bit.parse(String)`. Accepts both `name:3` and `name[3]`.
    public static func parse(_ input: String) throws -> Bit {
      let s = Array(input.trimmedForAnalyze())
      if let colon = s.firstIndex(of: ":"), colon > 0 {
        // Int32, not Int: Java parses with Integer.parseInt, so an out-of-int-range
        // subscript is a NumberFormatException there and must be an error here too.
        guard let sub = Int32(String(s[(colon + 1)...])) else {
          throw ParserError("badVariableIndexError", offset: colon)
        }
        return Bit(String(s[0..<colon]), Int(sub))
      } else if s.first == ":" {
        throw ParserError("badVariableColonError", offset: 0)
      }
      let i = s.firstIndex(of: "[") ?? -1
      let j = s.lastIndex(of: "]") ?? -1
      if 0 < i && i < j && j == s.count - 1 {
        guard let sub = Int32(String(s[(i + 1)..<j])) else {
          throw ParserError("badVariableIndexError", offset: i)
        }
        return Bit(String(s[0..<i]).trimmedForAnalyze(), Int(sub))
      } else if i >= 0 || j >= 0 {
        throw ParserError("badVariableBitFormError", offset: i >= 0 ? i : j)
      }
      return Bit(String(s), -1)
    }
  }
}

extension String {
  /// Java's `String.trim()`, which strips every code point <= U+0020; *not* Unicode
  /// whitespace. Keeping the exact rule matters because `Var.parse` reports offsets into
  /// the trimmed string.
  func trimmedForAnalyze() -> String {
    var scalars = Array(unicodeScalars)
    while let first = scalars.first, first.value <= 0x20 { scalars.removeFirst() }
    while let last = scalars.last, last.value <= 0x20 { scalars.removeLast() }
    var view = String.UnicodeScalarView()
    view.append(contentsOf: scalars)
    return String(view)
  }
}
