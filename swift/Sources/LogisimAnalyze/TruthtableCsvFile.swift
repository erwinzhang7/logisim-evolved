//
//  TruthtableCsvFile.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution, specifically
//  `src/main/java/com/cburch/logisim/analyze/file/TruthtableCsvFile.java`. GPL-3.0-only.
//  See LICENSE.md.
//

import Foundation

/// Java: `com.cburch.logisim.analyze.file.TruthtableCsvFile`: the RFC 4180 `.csv`
/// truth-table format.
///
/// ```text
/// "A","B[3..0]",,,,"|","D:3","D:2","D:1","D:0"
/// 0,0,0,-,0,"|",1,0,1,0
/// ```
///
/// Note the asymmetry between the two directions, which is upstream's: the writer emits the
/// wide-variable form (`"B[3..0]"` followed by empty fields), while the reader
/// (``CsvInterpretor``) accepts that *and* the per-bit `D:3` form.
public enum TruthtableCsvFile {
  /// Java: `DEFAULT_SEPARATOR`.
  public static let defaultSeparator: Character = ","
  /// Java: `DEFAULT_QUOTE`.
  public static let defaultQuote: Character = "\""
  /// Java: the extension on `FILE_FILTER`; the Swing `FileFilter` is NOT-PORTED.
  public static let fileExtension = "csv"

  /// Java: `doSave(File, AnalyzerModel)`, as a string.
  ///
  /// **This mutates the model**: upstream calls `tt.compactVisibleRows()` before writing, so
  /// saving a CSV merges rows that agree. That is a visible edit to the open truth table, not
  /// just a file-format detail, and it is preserved.
  ///
  /// Returns `nil` when either variable list is empty; Java returns without creating the
  /// file at all, and an empty `String` would misrepresent that as "wrote an empty file".
  public static func text(for model: AnalyzerModel) -> String? {
    let inputs = model.inputs
    let outputs = model.outputs
    guard !inputs.vars.isEmpty && !outputs.vars.isEmpty else { return nil }

    let separator = String(defaultSeparator)
    let quote = String(defaultQuote)
    let table = model.truthTable
    table.compactVisibleRows()

    // Java writes `name[msb..0]` here directly rather than through `Var.toString()`, and the
    // two differ for a one-bit variable; `toString()` would give the bare name either way,
    // but upstream spells the conditional out. Same result; kept in the same shape.
    func header(_ variable: Var) -> String {
      variable.width == 1 ? variable.name : "\(variable.name)[\(variable.width - 1)..0]"
    }

    var out = ""
    for variable in inputs.vars {
      out += quote + header(variable) + quote + separator
      // One empty field per remaining bit, so the column count matches the data rows.
      out += String(repeating: separator, count: max(variable.width - 1, 0))
    }
    out += quote + "|" + quote
    for variable in outputs.vars {
      out += separator
      out += quote + header(variable) + quote
      out += String(repeating: separator, count: max(variable.width - 1, 0))
    }
    out += "\n"

    for row in 0..<table.visibleRowCount {
      for col in 0..<inputs.bits.count {
        out += table.visibleInputEntry(row: row, column: col).description() + separator
      }
      out += quote + "|" + quote
      for col in 0..<outputs.bits.count {
        out += separator
        out += table.visibleOutputEntry(row: row, column: col).description()
      }
      out += "\n"
    }
    return out
  }

  /// Java: `doSave(File, AnalyzerModel)`.
  public static func save(_ model: AnalyzerModel, to url: URL) throws {
    guard let contents = text(for: model) else { return }
    try contents.write(to: url, atomically: true, encoding: .utf8)
  }

  /// Java: `doLoad(File, AnalyzerModel, JFrame)`.
  ///
  /// Upstream opens `CsvReadParameterDialog` to ask for the separator and quote characters,
  /// and returns without touching the model if the user cancels. That dialog is NOT-PORTED,
  /// so the parameters arrive as an argument and `isValid` carries the cancel, see
  /// ``CsvParameter``.
  public static func load(
    contentsOf url: URL,
    into model: AnalyzerModel,
    parameter: CsvParameter = .standard,
    resolveInconsistentRows: (AnalyzeError) -> Bool = { _ in false }
  ) throws {
    guard parameter.isValid else { return }
    let interpretor = try CsvInterpretor(contentsOf: url, parameter: parameter)
    try interpretor.applyTruthTable(
      to: model, resolveInconsistentRows: resolveInconsistentRows)
  }
}
