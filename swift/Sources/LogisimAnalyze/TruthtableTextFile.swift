//
//  TruthtableTextFile.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution, specifically
//  `src/main/java/com/cburch/logisim/analyze/file/TruthtableTextFile.java`. GPL-3.0-only.
//  See LICENSE.md.
//

import Foundation

/// Java: the `IOException`s `TruthtableTextFile` raises while parsing.
///
/// Every one is `String.format("Line %d: …", lineno, …)`, so the line number is pulled out of
/// the text and carried structurally; a UI wanting to put the caret on the offending line
/// should not have to scrape it back out of a sentence.
public struct TruthtableTextError: Error, Equatable, CustomStringConvertible {
  /// 1-based, as upstream counts. `nil` for the end-of-file case, which upstream reports
  /// without one.
  public let line: Int?
  /// The `en` text, verbatim from upstream's `String.format` templates. These are literals in
  /// the Java, not resource keys, so there is nothing to localise and nothing to key on.
  public let detail: String

  public init(line: Int?, _ detail: String) {
    self.line = line
    self.detail = detail
  }

  public var description: String {
    guard let line else { return detail }
    return "Line \(line): \(detail)"
  }
}

/// Java: `com.cburch.logisim.analyze.file.TruthtableTextFile`: the human-editable `.txt`
/// truth-table format, the one whose own header comment says "You can edit this file then
/// import it back into Logisim!".
///
/// ```text
/// A B[3..0] | D[3..0]
/// ~~~~~~~~~~~~~~~~~~~
/// 0  0000   |  1010
/// 1  ----   |  0000
/// ```
public enum TruthtableTextFile {
  /// Java: the extension on `FILE_FILTER`. The `FileFilter` itself is Swing and NOT-PORTED;
  /// the extension is what a save panel actually needs.
  public static let fileExtension = "txt"

  // MARK: - Writing

  /// Java: `center(PrintStream, String, int)`: pads `text` to `width`, extra space going to
  /// the right when the padding is odd.
  static func center(_ text: String, width: Int) -> String {
    let pad = width - text.count
    guard pad > 0 else { return text }
    let left = pad / 2
    return String(repeating: " ", count: left) + text + String(repeating: " ", count: pad - left)
  }

  /// Java: `doSave(File, AnalyzerModel)`, as a string.
  ///
  /// - Parameter circuitName: Java reads `model.getCurrentCircuit().getName()` and omits the
  ///   line when there is no circuit. `AnalyzerModel` here does not carry the circuit, see
  ///   its own note about the `proj.Project` seam, so the caller supplies the name.
  /// - Parameter exportDate: injected so the output is testable. Upstream writes
  ///   `new Date()`, rendered by `Date.toString()` in the default locale.
  public static func text(
    for model: AnalyzerModel,
    circuitName: String? = nil,
    exportDate: String = TruthtableTextFile.javaDateString(Date())
  ) -> String {
    var out = ""
    out += AnalyzeStrings.message("tableRemark1") + "\n"
    if let circuitName {
      out += AnalyzeStrings.message("tableRemark2", [circuitName]) + "\n"
    }
    out += AnalyzeStrings.message("tableRemark3", [exportDate]) + "\n"
    out += "\n"
    out += AnalyzeStrings.message("tableRemark4") + "\n"
    out += "\n"

    let inputs = model.inputs
    let outputs = model.outputs
    // Java: `Math.max(variable.toString().length(), variable.width)`: wide enough for the
    // header text and for the bit string underneath it.
    var colWidth: [Int] = []
    for variable in inputs.vars + outputs.vars {
      colWidth.append(max(variable.description.count, variable.width))
    }

    var i = 0
    for variable in inputs.vars {
      out += center(variable.description, width: colWidth[i])
      out += " "
      i += 1
    }
    out += "|"
    for variable in outputs.vars {
      out += " "
      out += center(variable.description, width: colWidth[i])
      i += 1
    }
    out += "\n"
    // The `~~~~` rule: one extra `~` per column, plus one to close.
    for width in colWidth {
      out += String(repeating: "~", count: width + 1)
    }
    out += "~\n"

    let table = model.truthTable
    for row in 0..<table.visibleRowCount {
      i = 0
      var col = 0
      for variable in inputs.vars {
        var bits = ""
        for _ in 0..<variable.width {
          bits += table.visibleInputEntry(row: row, column: col).toBitString()
          col += 1
        }
        out += center(bits, width: colWidth[i])
        out += " "
        i += 1
      }
      out += "|"
      col = 0
      for variable in outputs.vars {
        var bits = ""
        for _ in 0..<variable.width {
          bits += table.visibleOutputEntry(row: row, column: col).toBitString()
          col += 1
        }
        out += " "
        out += center(bits, width: colWidth[i])
        i += 1
      }
      out += "\n"
    }
    return out
  }

  /// Java: `doSave(File, AnalyzerModel)`.
  public static func save(
    _ model: AnalyzerModel,
    to url: URL,
    circuitName: String? = nil,
    exportDate: String = TruthtableTextFile.javaDateString(Date())
  ) throws {
    let contents = text(for: model, circuitName: circuitName, exportDate: exportDate)
    try contents.write(to: url, atomically: true, encoding: .utf8)
  }

  // MARK: - Reading

  /// Java: `validateHeader(String, VariableList, VariableList, int)`.
  static func validateHeader(
    _ line: String, inputs: VariableList, outputs: VariableList, lineNumber: Int
  ) throws {
    var current = inputs
    var currentIsInputs = true
    for value in splitOnWhitespace(line) {
      if value == "|" {
        guard currentIsInputs else {
          throw TruthtableTextError(line: lineNumber, "Separator '|' must appear only once.")
        }
        current = outputs
        currentIsInputs = false
      } else if isBareName(value) {
        try current.add(Var(value, 1))
      } else {
        // Java: `NAME_FORMAT = "([a-zA-Z]\w*)\[(-?\d+)\.\.(-?\d+)]"`, matched whole.
        guard let parsed = parseNameFormat(value) else {
          throw TruthtableTextError(line: lineNumber, "Invalid variable name '\(value)'.")
        }
        // Java parses both groups with Integer.parseInt inside a try/catch that turns
        // NumberFormatException into an IOException. The regex has already restricted them to
        // an optional minus and digits, so only overflow can fail, which is exactly why the
        // parse is Int32 here.
        guard let msb = Int32(parsed.msb), let lsb = Int32(parsed.lsb) else {
          throw TruthtableTextError(line: lineNumber, "Invalid bit range in '\(value)'.")
        }
        guard msb >= 1 && lsb == 0 else {
          throw TruthtableTextError(line: lineNumber, "Invalid bit range in '\(value)'.")
        }
        do {
          try current.add(Var(parsed.name, Int(msb &- lsb &+ 1)))
        } catch {
          let what = currentIsInputs ? "input" : "output"
          let maximum = currentIsInputs ? AnalyzerModel.maxInputs : AnalyzerModel.maxOutputs
          throw TruthtableTextError(
            line: lineNumber,
            "Too many bits in \(what) for truth table (max = \(maximum) bits).")
        }
      }
    }
    if inputs.vars.isEmpty {
      throw TruthtableTextError(line: lineNumber, "Truth table has no inputs.")
    }
    if outputs.vars.isEmpty {
      throw TruthtableTextError(line: lineNumber, "Truth table has no outputs.")
    }
  }

  /// Java: `parseBit(char, String, int)`.
  static func parseBit(_ c: Character, in value: String, lineNumber: Int) throws -> Entry {
    switch c {
    case "x", "X", "-": return .dontCare
    case "0": return .zero
    case "1": return .one
    default:
      throw TruthtableTextError(
        line: lineNumber,
        "Bit value '\(c)' in \"\(value)\" must be one of '0', '1', 'x', or '-'.")
    }
  }

  /// Java: `parseHex(char, int bit, int nbits, String, Var, int)`.
  static func parseHex(
    _ c: Character, bit: Int, bitCount: Int, in value: String, variable: Var, lineNumber: Int
  ) throws -> Entry {
    if c == "x" || c == "X" || c == "-" { return .dontCare }
    let digit: Int
    switch c {
    case "0"..."9": digit = Int(c.asciiValue! - UInt8(ascii: "0"))
    case "a"..."f": digit = 0xA + Int(c.asciiValue! - UInt8(ascii: "a"))
    case "A"..."F": digit = 0xA + Int(c.asciiValue! - UInt8(ascii: "A"))
    default:
      throw TruthtableTextError(
        line: lineNumber,
        "Hex digit '\(c)' in \"\(value)\" must be one of '0'-'9', 'a'-'f' or 'x'.")
    }
    // The partial-nibble check: a 5-bit variable's top hex digit only has one bit in it.
    if bitCount < 4 && digit >= (1 << bitCount) {
      throw TruthtableTextError(
        line: lineNumber,
        "Hex value \"\(value)\" contains too many bits for \(variable.name).")
    }
    return (digit & (1 << bit)) == 0 ? .zero : .one
  }

  /// Java: `parseVal(Entry[], int col, String, Var, int)`.
  ///
  /// Upstream decides binary vs hex purely by *length*: exactly `width` characters is binary,
  /// exactly `ceil(width/4)` is hex, anything else is an error. A 4-bit variable therefore
  /// reads `1010` as binary and `A` as hex, and there is no way to write a 4-bit hex `1010`.
  static func parseValue(
    into row: inout [Entry], at col: Int, text value: String, variable: Var, lineNumber: Int
  ) throws -> Int {
    var col = col
    let chars = Array(value)
    let hexDigits = (variable.width + 3) / 4
    if chars.count == variable.width {
      for i in 0..<variable.width {
        row[col] = try parseBit(chars[i], in: value, lineNumber: lineNumber)
        col += 1
      }
    } else if chars.count == hexDigits {
      for i in 0..<variable.width {
        // Upstream's index arithmetic, unchanged: the leading nibble may be partial, so the
        // character index is offset by however many bits the top digit is short of four.
        let charIndex = (i + ((4 - (variable.width % 4)) % 4)) / 4
        let bit = (variable.width - i - 1) % 4
        let bitCount = variable.width - ((variable.width - i - 1) / 4) * 4
        row[col] = try parseHex(
          chars[charIndex], bit: bit, bitCount: bitCount, in: value, variable: variable,
          lineNumber: lineNumber)
        col += 1
      }
    } else {
      throw TruthtableTextError(
        line: lineNumber,
        "Expected \(variable.width) bits (or \(hexDigits) hex digits) in column "
          + "\(variable.name), but found \"\(value)\".")
    }
    return col
  }

  /// Java: `validateRow(String, VariableList, VariableList, ArrayList<Entry[]>, int)`.
  static func validateRow(
    _ line: String, inputs: VariableList, outputs: VariableList, into rows: inout [[Entry]],
    lineNumber: Int
  ) throws {
    var row = [Entry](repeating: .dontCare, count: inputs.bits.count + outputs.bits.count)
    var col = 0
    let fields = splitOnWhitespace(line)
    var ix = 0
    for variable in inputs.vars {
      guard ix < fields.count, fields[ix] != "|" else {
        throw TruthtableTextError(line: lineNumber, "Not enough input columns.")
      }
      col = try parseValue(
        into: &row, at: col, text: fields[ix], variable: variable, lineNumber: lineNumber)
      ix += 1
    }
    guard ix < fields.count else {
      throw TruthtableTextError(line: lineNumber, "Missing '|' column separator.")
    }
    guard fields[ix] == "|" else {
      throw TruthtableTextError(line: lineNumber, "Too many input columns.")
    }
    ix += 1
    for variable in outputs.vars {
      guard ix < fields.count else {
        throw TruthtableTextError(line: lineNumber, "Not enough output columns.")
      }
      guard fields[ix] != "|" else {
        throw TruthtableTextError(
          line: lineNumber, "Column separator '|' must appear only once.")
      }
      col = try parseValue(
        into: &row, at: col, text: fields[ix], variable: variable, lineNumber: lineNumber)
      ix += 1
    }
    guard ix == fields.count else {
      throw TruthtableTextError(line: lineNumber, "Too many output columns.")
    }
    rows.append(row)
  }

  /// Java: `doLoad(File, AnalyzerModel, JFrame)`, taking the file as text.
  ///
  /// - Parameter resolveInconsistentRows: Java's "Ignore errors and try again?" dialog. See
  ///   the identical seam on ``CsvInterpretor/applyTruthTable(to:resolveInconsistentRows:)``:
  ///   declining leaves the model with the new variables and a default table, which is
  ///   upstream's behaviour and not an oversight here.
  public static func load(
    _ contents: String,
    into model: AnalyzerModel,
    resolveInconsistentRows: (AnalyzeError) -> Bool = { _ in false }
  ) throws {
    let inputs = VariableList(maxSize: AnalyzerModel.maxInputs)
    let outputs = VariableList(maxSize: AnalyzerModel.maxOutputs)
    var rows: [[Entry]] = []
    var lineNumber = 0

    // Java uses `Scanner.hasNextLine()/nextLine()` here: genuine lines, unlike
    // `CsvInterpretor`, which tokenises. `\n`, `\r\n` and a bare `\r` all end a line for
    // `Scanner`, and a trailing terminator does not produce an extra empty line.
    for rawLine in javaLines(contents) {
      lineNumber += 1
      var line = rawLine
      if let hash = line.firstIndex(of: "#") { line = String(line[line.startIndex..<hash]) }
      line = line.trimmedForAnalyze()
      // Java: `line.matches("\\s*[-~_=][- ~_=|]*")`: a rule such as `~~~~~~~` or `---|---`.
      if line.isEmpty || isSeparatorRule(line) {
        continue
      } else if inputs.vars.isEmpty {
        try validateHeader(line, inputs: inputs, outputs: outputs, lineNumber: lineNumber)
      } else {
        try validateRow(
          line, inputs: inputs, outputs: outputs, into: &rows, lineNumber: lineNumber)
      }
    }
    guard !rows.isEmpty else {
      throw TruthtableTextError(line: nil, "End of file: Truth table has no rows.")
    }

    try model.setVariables(inputs: inputs.vars, outputs: outputs.vars)
    let table = model.truthTable
    do {
      try table.setVisibleRows(rows, force: false)
    } catch let error as AnalyzeError {
      guard resolveInconsistentRows(error) else { return }
      try table.setVisibleRows(rows, force: true)
    }
  }

  /// Java: `doLoad(File, AnalyzerModel, JFrame)`.
  public static func load(
    contentsOf url: URL,
    into model: AnalyzerModel,
    resolveInconsistentRows: (AnalyzeError) -> Bool = { _ in false }
  ) throws {
    let text = try String(contentsOf: url, encoding: .utf8)
    try load(text, into: model, resolveInconsistentRows: resolveInconsistentRows)
  }

  // MARK: - Java text primitives

  /// Java's `String.split("\\s+")`, faithfully: including the three edge cases in
  /// `Pattern.split` that a naive `components(separatedBy:)` gets wrong:
  ///
  /// - a *leading* separator yields a leading empty field (`" a b"` -> `["", "a", "b"]`);
  /// - trailing empty fields are all dropped (`"   "` -> `[]`);
  /// - a string with no separator at all is returned whole, and `""` yields `[""]`.
  ///
  /// The callers trim first so only the last case can arise in practice, but a splitter that
  /// is right only for its current callers is the kind of thing that breaks the next one.
  static func splitOnWhitespace(_ text: String) -> [String] {
    if text.isEmpty { return [""] }
    var parts: [String] = []
    var current = ""
    var index = text.startIndex
    var matched = false
    while index < text.endIndex {
      if text[index].isJavaRegexSpace {
        matched = true
        parts.append(current)
        current = ""
        while index < text.endIndex && text[index].isJavaRegexSpace {
          index = text.index(after: index)
        }
      } else {
        current.append(text[index])
        index = text.index(after: index)
      }
    }
    // Java: `if (index == 0) return new String[] { input }`; no separator was ever matched.
    if !matched { return [text] }
    parts.append(current)
    while let last = parts.last, last.isEmpty { parts.removeLast() }
    return parts
  }

  /// Java: `value.matches("[a-zA-Z]\\w*")`.
  static func isBareName(_ value: String) -> Bool {
    let chars = Array(value)
    guard let first = chars.first, first.isAsciiLetter else { return false }
    return chars.dropFirst().allSatisfy { $0.isJavaWord }
  }

  /// Java: `NAME_FORMAT.matcher(value).matches()` with
  /// `([a-zA-Z]\w*)\[(-?\d+)\.\.(-?\d+)]`.
  static func parseNameFormat(_ value: String) -> (name: String, msb: String, lsb: String)? {
    let chars = Array(value)
    var i = 0
    guard i < chars.count, chars[i].isAsciiLetter else { return nil }
    i += 1
    while i < chars.count && chars[i].isJavaWord { i += 1 }
    let name = String(chars[0..<i])
    guard i < chars.count, chars[i] == "[" else { return nil }
    i += 1
    guard let msb = scanSignedDigits(chars, &i), !msb.isEmpty else { return nil }
    guard i + 1 < chars.count, chars[i] == ".", chars[i + 1] == "." else { return nil }
    i += 2
    guard let lsb = scanSignedDigits(chars, &i), !lsb.isEmpty else { return nil }
    guard i < chars.count, chars[i] == "]", i == chars.count - 1 else { return nil }
    return (name, msb, lsb)
  }

  /// `-?\d+`, greedy; `\d` here is ASCII, matching Java's default flags.
  private static func scanSignedDigits(_ chars: [Character], _ i: inout Int) -> String? {
    let start = i
    if i < chars.count && chars[i] == "-" { i += 1 }
    let digitStart = i
    while i < chars.count && chars[i].isAsciiDigit { i += 1 }
    guard i > digitStart else {
      i = start
      return nil
    }
    return String(chars[start..<i])
  }

  /// Java: `line.matches("\\s*[-~_=][- ~_=|]*")`.
  static func isSeparatorRule(_ line: String) -> Bool {
    var chars = Array(line)[...]
    while let first = chars.first, first.isJavaRegexSpace { chars = chars.dropFirst() }
    guard let first = chars.first, "-~_=".contains(first) else { return false }
    return chars.dropFirst().allSatisfy { "- ~_=|".contains($0) }
  }

  /// `java.util.Scanner`'s line splitting: `\r\n`, `\n` or `\r` ends a line, and a file that
  /// ends with a terminator does **not** yield a trailing empty line.
  static func javaLines(_ contents: String) -> [String] {
    var lines: [String] = []
    var current = ""
    var iterator = contents.makeIterator()
    var pending: Character?
    while true {
      let character: Character
      if let held = pending {
        character = held
        pending = nil
      } else if let next = iterator.next() {
        character = next
      } else {
        break
      }
      if character == "\r" {
        if let next = iterator.next() {
          if next != "\n" { pending = next }
        }
        lines.append(current)
        current = ""
      } else if character == "\n" {
        lines.append(current)
        current = ""
      } else {
        current.append(character)
      }
    }
    if !current.isEmpty { lines.append(current) }
    return lines
  }

  /// `java.util.Date.toString()` in the `en` locale: `"EEE MMM dd HH:mm:ss zzz yyyy"`.
  /// Upstream interpolates a bare `Date` into `tableRemark3`, so this is what the file says.
  public static func javaDateString(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE MMM dd HH:mm:ss zzz yyyy"
    return formatter.string(from: date)
  }
}
