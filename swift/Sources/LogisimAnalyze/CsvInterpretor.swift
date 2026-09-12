//
//  CsvInterpretor.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution, specifically
//  `src/main/java/com/cburch/logisim/analyze/data/CsvInterpretor.java`. GPL-3.0-only.
//  See LICENSE.md.
//

import Foundation

/// Java: the `OptionPane.showMessageDialog(...); return false;` pairs inside
/// `CsvInterpretor`, as a value.
///
/// Upstream reports each failure by popping a modal dialog and then quietly discarding the
/// parsed content, so the caller's `getTruthTable` becomes a no-op and the model is left
/// alone. Two things are wrong with porting that shape directly: the dialog is UI (D9), and
/// "returned normally, changed nothing" is indistinguishable at the call site from "imported
/// an empty file". Throwing carries the same information to the same place; the message key
/// and its arguments are exactly what upstream would have rendered, and keeps the
/// leave-the-model-alone guarantee, because every one of these is raised before the model is
/// touched.
public struct CsvImportError: Error, Equatable, CustomStringConvertible {
  /// The `analyze.properties` key Java looks up.
  public let messageKey: String
  /// Positional arguments for the key's `%s` / `%d` placeholders.
  public let messageArgs: [String]

  public init(_ messageKey: String, _ messageArgs: [String] = []) {
    self.messageKey = messageKey
    self.messageArgs = messageArgs
  }

  /// The `en` rendering, for headless callers and tests.
  public var message: String { AnalyzeStrings.message(messageKey, messageArgs) }
  public var description: String { message }
}

/// Java: `com.cburch.logisim.analyze.data.CsvInterpretor`; reads an RFC 4180 CSV file into
/// input/output variable lists and truth-table rows.
///
/// Upstream's spelling of the class name is kept so the two trees stay greppable against each
/// other.
///
/// The accepted format, quoting upstream's own header comment:
///
/// - the first line names the inputs and outputs. A bare string is a one-bit signal; `D:3` is
///   bit 3 of a vector and the bits **must** appear MSB-first and contiguously; `B[3..0]` or
///   `D[4]` declares a vector whose remaining `n-1` header fields must be empty.
/// - one header field must contain `|`, separating inputs from outputs.
/// - every later line must have exactly as many fields as the header, each `0`, `1`, `x`, `X`
///   or `-`, except the separator field, which is ignored.
/// - empty lines and spaces are not allowed.
///
/// That last rule is not a style preference; see ``lines(inFileContents:)`` for why the file
/// is tokenised on whitespace rather than split on newlines.
public final class CsvInterpretor {
  private var content: [[String?]]
  private let inputs = VariableList(maxSize: AnalyzerModel.maxInputs)
  private let outputs = VariableList(maxSize: AnalyzerModel.maxOutputs)
  private let fileName: String

  /// Java: the `CsvInterpretor(File, CsvParameter, JFrame)` constructor, which parses and
  /// validates eagerly.
  ///
  /// - Parameter fileContents: the whole file as text. Upstream takes a `File` and opens a
  ///   `Scanner` on it; splitting that apart lets the validation be tested without a
  ///   filesystem, and ``init(contentsOf:parameter:)`` puts it back together.
  public init(fileContents: String, parameter: CsvParameter, fileName: String) throws {
    self.fileName = fileName
    self.content = CsvInterpretor.lines(inFileContents: fileContents).map {
      CsvInterpretor.parseCsvLine($0, separator: parameter.separator, quote: parameter.quote)
    }
    if content.isEmpty { return }
    try readInputsAndOutputs()
    try checkEntries()
  }

  /// Java: `new CsvInterpretor(file, param, parent)` with the `Scanner` reading the file.
  ///
  /// Java's `readFile` swallows `FileNotFoundException` into a dialog and continues with
  /// empty content; here the read error propagates, which is the same information reaching
  /// the same place.
  public convenience init(contentsOf url: URL, parameter: CsvParameter) throws {
    let text = try String(contentsOf: url, encoding: .utf8)
    try self.init(
      fileContents: text, parameter: parameter, fileName: url.lastPathComponent)
  }

  /// Java: `readFile`'s `while (scanner.hasNext()) content.add(parseCsvLine(scanner.next(), …))`.
  ///
  /// **`Scanner.next()`, not `nextLine()`.** It returns the next *token* under the default
  /// delimiter `\p{javaWhitespace}+`, so upstream is chopping the file on runs of any
  /// whitespace, not on line breaks. That is the real reason its format comment says "Spaces
  /// are not allowed": a space inside a line silently splits it into two rows, and the
  /// wrong-field-count check then rejects the file. Reproduced, because a file that Java
  /// rejects must not be accepted here.
  static func lines(inFileContents contents: String) -> [String] {
    contents.split(whereSeparator: { $0.isJavaWhitespace }).map(String.init)
  }

  /// Java: `getTruthTable(AnalyzerModel)`.
  ///
  /// - Parameter resolveInconsistentRows: Java shows "Ignore errors and try again?" when the
  ///   parsed rows do not partition the input space, and retries with `force` if the user
  ///   agrees. That dialog is UI, so the decision is a closure. The default declines, which
  ///   is upstream's behaviour when the user presses No: return, leaving the model with the
  ///   **new variables** but the default table. That half-applied state is upstream's and is
  ///   preserved deliberately; `setVariables` has already fired its listeners by then.
  public func applyTruthTable(
    to model: AnalyzerModel,
    resolveInconsistentRows: (AnalyzeError) -> Bool = { _ in false }
  ) throws {
    guard content.count > 1 else { return }
    let expectedEntries = inputs.bits.count + outputs.bits.count
    var rows: [[Entry]] = []
    for row in 1..<content.count {
      var entryRow: [Entry] = []
      let line = content[row]
      for col in 0..<line.count {
        // The separator field sits at exactly the input-bit count and carries no value.
        guard col != inputs.bits.count else { continue }
        guard let field = line[col], let first = field.first else {
          // Java indexes `entry.charAt(0)` on a possibly-null field here and would NPE or
          // throw StringIndexOutOfBounds. checkEntries() has already rejected every such
          // field, so this is unreachable; D13 says it throws rather than traps regardless.
          throw CsvImportError("Invalid entry value")
        }
        switch first {
        case "-", "x", "X": entryRow.append(.dontCare)
        case "0": entryRow.append(.zero)
        case "1": entryRow.append(.one)
        // Java: `throw new IOException("Invalid entry value")`: an un-keyed literal, unlike
        // every other message in this class. Kept verbatim; `AnalyzeStrings.message` renders
        // an unknown key as itself, which is exactly what is wanted here.
        default: throw CsvImportError("Invalid entry value")
        }
      }
      guard entryRow.count == expectedEntries else {
        // Java: `throw new IOException("Invalid nr of entries")`, likewise un-keyed.
        throw CsvImportError("Invalid nr of entries")
      }
      rows.append(entryRow)
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

  /// Java: `checkEntries()`.
  private func checkEntries() throws {
    if content.count == 1 {
      throw CsvImportError("CsvNoEntries", [fileName])
    }
    for row in 1..<content.count {
      let line = content[row]
      for col in 0..<line.count {
        guard col != inputs.bits.count else { continue }
        let entry = line[col]
        let isValid = entry.map { $0.count == 1 && "01-xX".contains($0) } ?? false
        if !isValid {
          throw CsvImportError(
            "CsvInvalidEntry", ["\(row + 1)", fileName, entry ?? "", "\(col + 1)"])
        }
      }
    }
  }

  /// Java: `isDuplicate(String)`, inverted; it reports and returns true, this throws.
  private func checkNotDuplicate(_ name: String) throws {
    // Java compares with `equalsIgnoreCase`, which is locale-independent ASCII-ish folding;
    // Swift's `lowercased()` is locale-independent too, and the two agree for every name
    // `isCorrectName` will have already accepted (ASCII letters, digits and underscore).
    let folded = name.lowercased()
    for variable in inputs.vars + outputs.vars where variable.name.lowercased() == folded {
      throw CsvImportError("CsvDuplicatedVar", ["1", fileName, name])
    }
  }

  /// Java: `isCorrectName(String)`.
  private func checkCorrectName(_ name: String) throws {
    guard AnalyzeSyntaxChecker.isVariableNameAcceptable(name) else {
      throw CsvImportError("CsvIncorrectVarName", ["1", fileName, name])
    }
  }

  /// Java: `getInputsOutputs()`.
  private func readInputsAndOutputs() throws {
    let header = content[0]
    let entryCount = header.count
    for line in 1..<content.count where content[line].count != entryCount {
      throw CsvImportError(
        "CsvIncorrectLine", ["\(line + 1)", fileName, "\(content[line].count)", "\(entryCount)"])
    }

    // Java uses a `HashMap<String, ArrayList<Boolean>>`. Insertion order is used here instead
    // ; see `checkAllBitsSpecified()` for the one place that choice is observable.
    var bitsPresentOrder: [String] = []
    var bitsPresent: [String: [Bool]] = [:]

    var processingInputs = true
    var separatorSeen = false

    var idx = 0
    while idx < entryCount {
      guard let field = header[idx] else {
        throw CsvImportError("CsvIncorrectEmpty", ["1", fileName, "\(idx)"])
      }
      if field.contains("|") {
        processingInputs = false
        separatorSeen = true
        idx += 1
        continue
      }
      if let colon = field.firstIndex(of: ":") {
        // `Name:<bit>`: one bit of a vector, MSB first.
        let name = String(field[field.startIndex..<colon])
        try checkCorrectName(name)
        let indexText = String(field[field.index(after: colon)...])
        guard !indexText.isEmpty, indexText.allSatisfy({ $0.isAsciiDigit }) else {
          throw CsvImportError("CsvIncorrectVarName", ["1", fileName, field])
        }
        // Java: `Integer.parseInt`, so an out-of-int-range subscript is a
        // NumberFormatException upstream. D13; it throws here rather than trapping.
        guard let parsed = Int32(indexText) else {
          throw CsvImportError("CsvIncorrectVarName", ["1", fileName, field])
        }
        let bitIndex = Int(parsed)
        let key = name.lowercased()

        if var selected = bitsPresent[key] {
          // Java: `if (bitIndex >= sels.size() || !sels.get(bitIndex + 1))`.
          //
          // `sels.get(bitIndex + 1)` is an out-of-bounds read whenever `bitIndex ==
          // sels.size() - 1`, which a header as ordinary as `D:3,D:3` or `D:0,D:0`
          // reaches; upstream throws IndexOutOfBoundsException out of a method whose whole
          // contract is "return false on bad input". D13 forbids reproducing that as a trap,
          // so the out-of-range case is folded into the bit-order error it was plainly
          // meant to be: the neighbouring, more-significant bit is not present.
          let previousBitPresent = bitIndex + 1 < selected.count && selected[bitIndex + 1]
          guard bitIndex < selected.count, previousBitPresent else {
            throw CsvImportError("CsvIncorrectBitOrder", ["1", fileName, name])
          }
          if selected[bitIndex] {
            throw CsvImportError("CsvDuplicatedBit", ["1", fileName, "\(bitIndex)", name])
          }
          selected[bitIndex] = true
          bitsPresent[key] = selected
        } else {
          try checkNotDuplicate(name)
          var selected = [Bool](repeating: false, count: bitIndex)
          selected.append(true)
          bitsPresent[key] = selected
          bitsPresentOrder.append(key)
          try add(Var(name, bitIndex + 1), toInputs: processingInputs)
        }
      } else if let bracket = field.firstIndex(of: "[") {
        // `Name[msb..lsb]` or `Name[n]`: a whole vector, followed by empty fields.
        let name = String(field[field.startIndex..<bracket])
        try checkCorrectName(name)
        try checkNotDuplicate(name)
        let bitCount = BitRangeParse.checkIndex(String(field[bracket...]))
        guard bitCount > 0 else {
          throw CsvImportError("CsvIncorrectVarName", ["1", fileName, field])
        }
        guard idx + bitCount <= entryCount else {
          throw CsvImportError("CsvNotEnoughEmpty", ["1", fileName, field])
        }
        for offset in 1..<bitCount where header[idx + offset] != nil {
          throw CsvImportError("CsvNotEnoughEmpty", ["1", fileName, field])
        }
        idx += bitCount - 1
        try add(Var(name, bitCount), toInputs: processingInputs)
      } else {
        try checkCorrectName(field)
        try checkNotDuplicate(field)
        try add(Var(field, 1), toInputs: processingInputs)
      }
      idx += 1
    }

    guard separatorSeen else {
      throw CsvImportError("CsvNoSepFound", ["1", fileName])
    }
    guard !inputs.bits.isEmpty else {
      throw CsvImportError("CsvNoInputsFound", ["1", fileName])
    }
    try checkAllBitsSpecified(order: bitsPresentOrder, bits: bitsPresent)
  }

  /// Java: the closing `for (String key : bitspresent.keySet())` loop.
  ///
  /// **This is the one place in the analyze port where Java's `HashMap` iteration order is
  /// observable, and it is worth being precise about what it does and does not decide.**
  /// Every branch inside the loop aborts the whole import, so which key is examined first
  /// cannot change *whether* a file is accepted; only *which* of several missing bits is
  /// named in the message. Insertion order is used here, which is both deterministic and the
  /// order a reader of the header would expect.
  ///
  /// This is emphatically **not** the cover-selection hazard `objectives.md` records against
  /// the minimiser. That one can change which minimal cover is returned, is checked against
  /// `MinimizationGoldenData`, and lives in `Implicant.swift`. This one is a message.
  private func checkAllBitsSpecified(order: [String], bits: [String: [Bool]]) throws {
    for key in order {
      guard let selected = bits[key] else { continue }
      for bit in 0..<selected.count where !selected[bit] {
        throw CsvImportError("CsvBitNotSpecified", ["1", fileName, "\(bit)", key])
      }
    }
  }

  /// Java: `inputs.add(variable)` / `outputs.add(variable)`, whose `IllegalArgumentException`
  /// on overflowing `MAX_INPUTS`/`MAX_OUTPUTS` escapes upstream's constructor uncaught. D13:
  /// it is reachable from a header naming 21 inputs, so it throws.
  private func add(_ variable: Var, toInputs: Bool) throws {
    try (toInputs ? inputs : outputs).add(variable)
  }

  /// Java: `parseCsvLine(String, char, char)`; a hand-rolled RFC 4180 field splitter.
  ///
  /// `nil` means an empty field, which the header parser treats as "continuation of the
  /// preceding vector" rather than as an error, so the distinction from `""` matters.
  ///
  /// The doubled-quote handling is upstream's: a run of `n` quote characters inside a quoted
  /// field emits `n / 2` literal quotes, and an odd one closes the field.
  public static func parseCsvLine(
    _ line: String, separator: Character, quote: Character
  ) -> [String?] {
    var inQuote = false
    var contiguousQuotes = 0
    var working = ""
    var result: [String?] = []

    func flush() {
      if working.isEmpty {
        result.append(nil)
      } else {
        result.append(working)
        working = ""
      }
    }

    for character in line {
      if inQuote {
        if character == quote {
          contiguousQuotes += 1
        } else {
          if contiguousQuotes > 1 {
            let toPrint = contiguousQuotes >> 1
            working += String(repeating: String(quote), count: toPrint)
            contiguousQuotes -= toPrint << 1
          }
          if contiguousQuotes == 1 {
            inQuote = false
            if character == separator {
              flush()
            } else {
              working.append(character)
            }
          } else {
            working.append(character)
          }
          contiguousQuotes = 0
        }
      } else {
        if character == separator {
          flush()
        } else if character == quote {
          inQuote = true
        } else if character == "\r" {
          continue
        } else if character == "\n" {
          break
        } else {
          working.append(character)
        }
      }
    }
    result.append(working.isEmpty ? nil : working)
    return result
  }
}

extension Character {
  /// Java's `Character.isWhitespace`, which is what `Scanner`'s default delimiter
  /// `\p{javaWhitespace}+` uses. Swift's `isWhitespace` is Unicode `White_Space`; the two
  /// differ only on NBSP-family code points (Java excludes them, Unicode includes them) and
  /// on the four Unicode-whitespace-but-not-Java control characters. Neither appears in a
  /// truth-table CSV, and the difference can only ever change how a file *fails*.
  var isJavaWhitespace: Bool {
    isWhitespace
  }
}
