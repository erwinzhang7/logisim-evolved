//
//  CsvParameter.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution, specifically
//  `src/main/java/com/cburch/logisim/analyze/data/CsvParameter.java`. GPL-3.0-only.
//  See LICENSE.md.
//

/// Java: `com.cburch.logisim.analyze.data.CsvParameter`; the separator and quote characters
/// to read a CSV truth table with.
///
/// Upstream fills this in from `gui/CsvReadParameterDialog`, which previews the file and lets
/// the user pick; that dialog is NOT-PORTED. `isValid` is the dialog's "the user pressed OK"
/// flag, `TruthtableCsvFile.doLoad` bails when it is false, and it is kept because that
/// cancel path is model-visible: a cancelled import must leave the model untouched.
public struct CsvParameter: Hashable, Sendable {
  /// Java: `quote`, defaulting to `TruthtableCsvFile.DEFAULT_QUOTE`.
  public var quote: Character
  /// Java: `seperator`; upstream's spelling. Corrected here; it is a private field there and
  /// nothing outside the analyze package reads it by name.
  public var separator: Character
  /// Java: `isValid()` / `setValid()`.
  public var isValid: Bool

  public init(
    quote: Character = TruthtableCsvFile.defaultQuote,
    separator: Character = TruthtableCsvFile.defaultSeparator,
    isValid: Bool = false
  ) {
    self.quote = quote
    self.separator = separator
    self.isValid = isValid
  }

  /// The parameters a headless caller wants: RFC 4180 defaults, already accepted.
  public static let standard = CsvParameter(isValid: true)
}
