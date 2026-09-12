//
//  Entry.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution, specifically
//  `src/main/java/com/cburch/logisim/analyze/model/Entry.java`. GPL-3.0-only. See LICENSE.md.
//

/// The characters a truth-table cell is displayed and parsed with.
///
/// Java reads these from `AppPreferences.{TRUE,FALSE,DONTCARE,ERROR,UNKNOWN}_CHAR` and each
/// `Entry` singleton registers itself as a `PreferenceChangeListener` so the table repaints
/// when a preference changes. D9 forbids the model reaching into `AppPreferences`, so the
/// characters are a plain value passed in by the caller; the defaults below are the Java
/// defaults (`"1 "`, `"0 "`, `"- "`, `"E "`, `"U "`, of which Java takes `charAt(0)`).
public struct EntryCharacters: Hashable, Sendable {
  public var trueChar: Character
  public var falseChar: Character
  public var dontCareChar: Character
  public var errorChar: Character
  public var unknownChar: Character

  public init(
    trueChar: Character = "1",
    falseChar: Character = "0",
    dontCareChar: Character = "-",
    errorChar: Character = "E",
    unknownChar: Character = "U"
  ) {
    self.trueChar = trueChar
    self.falseChar = falseChar
    self.dontCareChar = dontCareChar
    self.errorChar = errorChar
    self.unknownChar = unknownChar
  }

  /// The `AppPreferences` defaults.
  public static let standard = EntryCharacters()
}

/// Java: `com.cburch.logisim.analyze.model.Entry`.
///
/// Java models this as five interned singletons compared with `==`; every comparison in the
/// analyze package is by reference. A Swift enum gives the same semantics with structural
/// equality, and `rawValue` is Java's `sortOrder`, so `Comparable` matches `compareTo`.
public enum Entry: Int, Hashable, Comparable, CaseIterable, Sendable {
  /// Java: `Entry.OSCILLATE_ERROR` (`sortOrder == -2`).
  case oscillateError = -2
  /// Java: `Entry.BUS_ERROR` (`sortOrder == -1`).
  case busError = -1
  /// Java: `Entry.ZERO`.
  case zero = 0
  /// Java: `Entry.DONT_CARE`.
  case dontCare = 1
  /// Java: `Entry.ONE`.
  case one = 2

  public static func < (lhs: Entry, rhs: Entry) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  /// Java: `Entry.parse(String)`: tests only the **first** character, and returns `null`
  /// for anything unrecognised (including `"@"`, which `getDescription` emits for
  /// `OSCILLATE_ERROR`; the round trip is deliberately incomplete upstream).
  public static func parse(_ description: String, chars: EntryCharacters = .standard) -> Entry? {
    guard let c = description.first else { return nil }
    if c == chars.falseChar { return .zero }
    if c == chars.trueChar { return .one }
    if c == chars.dontCareChar { return .dontCare }
    if c == chars.errorChar { return .busError }
    return nil
  }

  /// Java: `getDescription()`.
  public func description(chars: EntryCharacters = .standard) -> String {
    switch self {
    case .oscillateError: return "@"
    case .busError: return String(chars.errorChar)
    case .zero: return String(chars.falseChar)
    case .dontCare: return String(chars.dontCareChar)
    case .one: return String(chars.trueChar)
    }
  }

  /// Java: `toBitString()`, `"?"` for anything that is not a bit or a don't-care.
  public func toBitString(chars: EntryCharacters = .standard) -> String {
    switch self {
    case .dontCare, .zero, .one: return description(chars: chars)
    default: return "?"
    }
  }

  /// Java: `isError()`: true exactly when `errorMessage != null`.
  public var isError: Bool {
    self == .oscillateError || self == .busError
  }

  /// Java: `getErrorMessage()`, as an `analyze.properties` key. `nil` for non-error entries.
  public var errorMessageKey: String? {
    switch self {
    case .oscillateError: return "oscillateError"
    case .busError: return "busError"
    default: return nil
    }
  }

  /// Java: `getErrorMessage()` in the `en` locale.
  public var errorMessage: String? {
    errorMessageKey.map { AnalyzeStrings.message($0) }
  }
}
