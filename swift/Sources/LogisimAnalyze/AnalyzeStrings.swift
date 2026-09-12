//
//  AnalyzeStrings.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
//  specifically `src/main/resources/resources/logisim/strings/analyze/analyze.properties`.
//  logisim-evolution is free software released under the GNU GPLv3; this translation is
//  therefore GPL-3.0-only. See LICENSE.md.
//

/// The message keys the analyze model raises, with their English text.
///
/// Java routes these through `Strings.S.getter(key)` / `S.fmt(key, args)`, which returns a
/// lazily-localised `StringGetter`. Localisation is a UI concern and does not come across
/// (same rule as D5 applies to `Attribute` display names): the model carries the **key** and
/// the arguments, and the UI layer decides how to render them. `englishMessage` exists so
/// that headless callers and tests have something readable and stable to assert on, and it
/// is a verbatim copy of the `en` bundle.
public enum AnalyzeStrings {

  /// The `en` text for every key the ported model can raise. `%s`/`%d` placeholders are
  /// substituted positionally from `args`.
  private static let english: [String: String] = [
    // model/Entry.java
    "busError": "Conflicting output values in circuit.",
    "oscillateError": "Circuit oscillates.",
    // model/Parser.java
    "badVariableName": "\u{201C}%s\u{201D} is not an input variable.",
    "implicitAndOperator": "(Implicit AND)",
    "invalidCharacterError": "Unrecognized characters: \u{2018}%s\u{2019}",
    "lparenMissingError": "No matching opening parenthesis.",
    "missingBraceError": "No matching brace: \u{201C}%s\u{201D}",
    "missingIdentifierError": "Missing identifier before subscript: \u{201C}%s\u{201D}",
    "missingLeftOperandError": "Operator \u{201C}%s\u{201D} missing left operand.",
    "missingRightOperandError": "Operator \u{201C}%s\u{201D} missing right operand.",
    "missingSubscriptError": "Missing subscript: \u{201C}%s\u{201D}",
    "rparenMissingError": "No matching closing parenthesis.",
    "unexpectedApostrophe": "Unexpected apostrophe (\u{201C}'\u{201D})",
    "unexpectedAssignmentError": "Unexpected assignment operator: \u{201C}%s\u{201D}",
    // model/Var.java
    "badVariableBitFormError": "Variable name must be of the form \u{2018}name[i]\u{2019}",
    "badVariableColonError": "Variable name must appear before \u{2018}:\u{2019}",
    "badVariableIndexError": "Variable bit index must be an integer",
    "variableFormat": "Variables must be of the form \u{2018}name[N..0]\u{2019}",
    "variableTooMuchBits": "Variables can\u{2019}t be more than 32 bits wide",
    // model/Implicant.java (the optimisation report)
    "implicantOutputName": "Optimizing output: %s",
    "implicantGroupSize": "Finding primes of size: %d",
    "implicantNoneFound": "None",
    "implicantColumRowReduction": "Finding essential primes by column-row reduction:",
    "implicantGreedy": "Using greedy to pick last essential primes:",

    // file/TruthtableTextFile.java, the `.txt` export preamble.
    "tableRemark1": "# Truth table",
    "tableRemark2": "# Generated from circuit %s",
    "tableRemark3": "# Exported on %s",
    "tableRemark4": """
      # Hints and Notes on Formatting:
      # * You can edit this file then import it back into Logisim!
      # * Anything after a \u{2018}#\u{2019} is a comment and will be ignored.
      # * Blank lines and separator lines (e.g., ~~~~~~) are ignored.
      # * Keep column names simple (no spaces, punctuation, etc.)
      # * \u{2018}Name[N..0]\u{2019} indicates an N+1 bit variable, whereas
      #   \u{2018}Name\u{2019} by itself indicates a 1-bit variable.
      # * You can use \u{2018}x\u{2019} or \u{2018}-\u{2019} to indicate \u{201C}don\u{2019}t \
      care\u{201D} for both
      #   input and output bits.
      # * You can use binary (e.g., \u{2018}10100011xxxx\u{2019}) notation or
      #   or hex (e.g., \u{2018}C3x\u{2019}). Logisim will figure out which is which.
      """,
    "tableParseErrorMessage": "Ignore errors and try again?",
    "tableParseErrorTitle": "Error Parsing Truth Table",
    "tableTxtFileFilter": "Logisim-evolution Truth Table (*.txt)",
    "tableCsvFileFilter": "Logisim-evolution Truth Table (*.csv)",
    "tableLatexFilter": "Logisim-evolution TeX document (*.tex)",
    "openButton": "Import Truth Table",
    "cantReadMessage": "Can\u{2019}t read file: %s",

    // data/CsvInterpretor.java
    "CsvBitNotSpecified":
      "Line %d of the csv file \u{2018}%s\u{2019} does not contain bit %d of variable "
      + "\u{2018}%s\u{2019}, aborting.",
    "CsvDuplicatedBit":
      "Line %d of the csv file \u{2018}%s\u{2019} contains twice the bit %d of the variable "
      + "\u{2018}%s\u{2019}, aborting.",
    "CsvDuplicatedVar":
      "Line %d of the csv file \u{2018}%s\u{2019} contains multiple times the variable "
      + "\u{2018}%s\u{2019}, aborting.",
    "CsvIncorrectBitOrder":
      "Line %d of the csv file \u{2018}%s\u{2019} contains a incorrect bit-sequence for "
      + "variable \u{2018}%s\u{2019}, aborting.",
    "CsvIncorrectEmpty":
      "Line %d of the csv file \u{2018}%s\u{2019} contains an incorrect empty field at "
      + "position %d, aborting.",
    "CsvIncorrectLine":
      "Line %d of the csv file \u{2018}%s\u{2019} has %d entries instead of the %d required, "
      + "aborting.",
    "CsvIncorrectVarName":
      "Line %d of the csv file \u{2018}%s\u{2019} contains the incorrect formatted label "
      + "\u{2018}%s\u{2019}, aborting.",
    "CsvInvalidEntry":
      "Line %d of the csv file \u{2018}%s\u{2019} contains an invalid entry "
      + "\u{2018}%s\u{2019} at field %d, aborting.",
    "CsvNoEntries": "File \u{201C}%s\u{201D} does not contain any entries, aborting.",
    "CsvNoInputsFound":
      "Line %d of the csv file \u{2018}%s\u{2019} does not contain any inputs, aborting.",
    "CsvNoSepFound":
      "Line %d of the csv file \u{2018}%s\u{2019} contains no separator field, aborting.",
    "CsvNotEnoughEmpty":
      "Line %d of the csv file \u{2018}%s\u{2019} contains not enough empty fields after "
      + "variable \u{2018}%s\u{2019}, aborting.",

    // util/SyntaxChecker.java: these live in util.properties upstream, not analyze.properties,
    // but the only caller that survives into this module is data/CsvInterpretor's name check.
    // Each fragment ends in a newline in Java, because getErrorMessage concatenates them.
    "variableInvalidCharacters": "Error: Detected invalid characters!\n",
    "variableStartsWithDigit": "Error: The name must not start with a digit.\n",
    "variableIllegalCharacter": "Error: The character \u{201C}%s\u{201D} is not allowed.\n",
    "variableDoubleUnderscore": "Error: Detected concatenated \u{201C}_\u{201D}-symbols!\n",
    "variableVHDLKeyword": "Error: Detected VHDL keyword!\n",
    "variableVerilogKeyword": "Error: Detected Verilog keyword!\n",
    "variableEndsWithUndescore": "Error: Name ends with a \u{201C}_\u{201D}-symbol!\n",

    // gui/ExpressionTab.java and gui/MinimizedTab.java. These are `gui` strings, but they live
    // in the same `analyze.properties` bundle as everything above and are copied here for the
    // same reason `openButton`/`cantReadMessage` already are: the bundle is ported once, and
    // the UI layer asks for a key rather than carrying a second copy of the English text.
    "expressionTab": "Expression",
    "outputExpressionEdit": "Output Expressions (double-click to edit):",
    "cantImportFormatError": "Can\u{2019}t import this type of data",
    "ExpressionNotation": "Notation:",
    "expressionMathrepresentation": "Mathematical",
    "expressionLogicrepresentation": "Logical",
    "expressionAltLogicrepresentation": "Alternative Logical",
    "expressionProgboolsrepresentation": "Programming with booleans",
    "expressionProgbitsrepresentation": "Programming with bits",

    // file/AnalyzerTexWriter.java
    "latexBabelLanguage": "english",
    "latexHeader": "Logisim-evolution generated this document on %s",
    "latexIntroduction": "Introduction",
    "latexIntroductionText":
      "This document was generated by Logisim-evolution. Any part of the TeX sources can be "
      + "used in your own documents without any problems. In case you want to use all/parts "
      + "of this generated TeX-sources please (1) do not forget to include the required "
      + "packages, and (2) include a remark that this source was generated by "
      + "Logisim-evolution.",
    "latexEmpty": "Empty analyzer",
    "latexEmptyText":
      "As the analyzer did not have input variables and/or output variables at the moment "
      + "this document was generated there is nothing to show.",
    "latexTruthTable": "Truth table",
    "latexTruthTableText":
      "The table may be way to big to be displayed on the page. At generation time no "
      + "calculation was done on the size of the table with respect to the width/height of "
      + "the page.",
    // The `\\~\\` prefix is upstream's, and survives the .properties unescaping as two
    // literal backslashes either side of a tilde: a LaTeX line break, a hard space, another
    // break.
    "latexTruthTableToBig":
      "\\\\~\\\\The truth table has more than %d entries, it makes no sense to show it here.",
    "latexTruthTableCompact": "Compacted truth table",
    "latexTruthTableComplete": "Complete truth table",
    "latexKarnaugh": "Karnaugh diagrams",
    "latexKarnaughText":
      "This section shows various versions of the Karnaugh diagrams of the given functions.",
    "latexKarnaughToBig": "Cannot display Karnaugh diagrams with more than %d input vars.",
    "latexKarnaughEmpty": "Empty Karnaugh diagrams",
    "latexKarnaughFilledIn": "Filled in Karnaugh diagrams",
    "latexKarnaughFilledInGroups": "Filled in Karnaugh diagrams with covers",
    "latexMinimal": "Minimal expressions",
  ]

  /// Renders `key` with `args` substituted for its `%s`/`%d` placeholders, left to right.
  /// An unknown key renders as the key itself, which is also what a missing entry does in
  /// Java's `LocaleManager`.
  public static func message(_ key: String, _ args: [String] = []) -> String {
    guard let template = english[key] else { return key }
    var out = ""
    var remainingArgs = args[...]
    var iterator = template.makeIterator()
    var pending: Character?
    while let c = pending ?? iterator.next() {
      pending = nil
      if c == "%", let next = iterator.next() {
        if next == "s" || next == "d" {
          out += remainingArgs.popFirst() ?? ""
          continue
        }
        if next == "%" {
          out.append("%")
          continue
        }
        out.append(c)
        pending = next
        continue
      }
      out.append(c)
    }
    return out
  }
}

/// Java: `com.cburch.logisim.analyze.model.ParserException`.
///
/// D13: `Parser` failures are ordinary user input (someone typed a malformed expression), so
/// they throw rather than trap.
public struct ParserError: Error, Equatable, CustomStringConvertible {
  /// The `analyze.properties` key Java would have looked up.
  public let messageKey: String
  /// Positional arguments for the key's `%s` placeholders.
  public let messageArgs: [String]
  /// Java: `getOffset()`; index of the offending text.
  ///
  /// Java counts UTF-16 code units; this port counts `Character`s. The two agree for every
  /// input the tokenizer accepts (all recognised operator glyphs are BMP), and diverge only
  /// inside an unrecognised-character run that is being reported as an error anyway.
  public let offset: Int
  /// Java: `length`, defaulting to 1.
  public let length: Int

  public init(_ messageKey: String, args: [String] = [], offset: Int, length: Int = 1) {
    self.messageKey = messageKey
    self.messageArgs = args
    self.offset = offset
    self.length = length
  }

  /// Java: `getEndOffset()`.
  public var endOffset: Int { offset + length }

  /// Java: `getMessage()`, in the `en` locale.
  public var message: String { AnalyzeStrings.message(messageKey, messageArgs) }

  public var description: String { message }
}

/// Java: the `IllegalArgumentException` / `IllegalStateException` / `NoSuchElementException`
/// family that the analyze model throws on bad edits.
///
/// D13: every one of these is reachable from ordinary user interaction, renaming a variable
/// to a duplicate, pasting a truth table with missing rows, asking for a 33-bit bus, so they
/// throw instead of trapping. Trapping would turn a recoverable edit error into a lost-work
/// crash.
public enum AnalyzeError: Error, Equatable, CustomStringConvertible {
  /// Java: `VariableList.add` / `setAll`; "maximum size is N".
  case maximumSizeExceeded(maximum: Int)
  /// Java: `NoSuchElementException(variable.toString())`.
  case noSuchVariable(String)
  /// Java: `VariableList.move`. Upstream raises two *different* messages here; a bare
  /// "cannot move index i by d" when the target index is negative, and a capitalised
  /// "Cannot move index i by d: size n" when it runs off the end, so `size` is `nil` for the
  /// first. The asymmetry is almost certainly an accident upstream, but the message is what a
  /// user sees and this is the only place it is decided.
  case cannotMove(index: Int, delta: Int, size: Int?)
  /// Java: `TruthTable.setOutputColumn`, "bad column length".
  case badColumnLength(expected: Int, actual: Int)
  /// Java: `TruthTable` index checks.
  case indexOutOfBounds(String)
  /// Java: `TruthTable.splitRow` / `setDontCare` invariant failures.
  case rowStructure(String)
  /// Java: `setVisibleInputEntry`, "invalid input entry".
  case invalidInputEntry
  /// Java: `setVisibleRows`: overlapping or missing input rows.
  case inconsistentRows(String)
  /// Java: `OutputExpressions.getOutputData`, "unrecognized output X".
  case unrecognizedOutput(String)

  public var description: String {
    switch self {
    case .maximumSizeExceeded(let maximum):
      return "maximum size is \(maximum)"
    case .noSuchVariable(let name):
      return "no such variable: \(name)"
    case .cannotMove(let index, let delta, let size):
      guard let size else { return "cannot move index \(index) by \(delta)" }
      return "Cannot move index \(index) by \(delta): size \(size)"
    case .badColumnLength(let expected, let actual):
      return "bad column length: expected \(expected), got \(actual)"
    case .indexOutOfBounds(let what):
      return "bad \(what)"
    case .rowStructure(let what):
      return what
    case .invalidInputEntry:
      return "invalid input entry"
    case .inconsistentRows(let what):
      return what
    case .unrecognizedOutput(let name):
      return "unrecognized output \(name)"
    }
  }
}
