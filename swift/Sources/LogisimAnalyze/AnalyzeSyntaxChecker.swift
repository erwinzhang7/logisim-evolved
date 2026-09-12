//
//  AnalyzeSyntaxChecker.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution, specifically
//  `src/main/java/com/cburch/logisim/util/SyntaxChecker.java` and `checkindex` from
//  `src/main/java/com/cburch/logisim/analyze/gui/VariableTab.java`. GPL-3.0-only.
//  See LICENSE.md.
//

/// Java: `com.cburch.logisim.util.SyntaxChecker`, restricted to what the analyze package
/// actually calls: `isVariableNameAcceptable(val, false)`, from `data/CsvInterpretor`.
///
/// Upstream's `isVariableNameAcceptable(String, Boolean)` is `getErrorMessage(val) == null`
/// plus an `OptionPane` when the second argument is true. The dialog is UI; the rule is not.
///
/// ## The one deliberate gap, and why it is a seam rather than a copy
///
/// `getErrorMessage` also rejects a name that is a reserved VHDL or Verilog keyword, via
/// `fpga.designrulecheck.CorrectLabel.hdlCorrectLabel`. That class **is** already ported, it
/// is `LogisimHdl/CorrectLabel.swift`, but `LogisimAnalyze` depends on `LogisimKernel` and
/// `LogisimFile` only, and widening that edge means editing `Package.swift`, which this
/// module does not own. Copying the two keyword lists in here instead would leave two
/// divergeable copies of a 200-entry table, which is worse.
///
/// So the keyword check is an injection point. Left unset, `AnalyzeSyntaxChecker` enforces
/// every *other* rule upstream enforces and **accepts a name that upstream would reject for
/// being a keyword**. A host that links `LogisimHdl` should close the gap at startup:
///
/// ```swift
/// AnalyzeSyntaxChecker.hdlKeywordCheck = { CorrectLabel.hdlCorrectLabel($0) }
/// ```
///
/// The gap is narrow, it can only ever make CSV import *more* permissive, never reject a
/// name Java accepts, but it is a real divergence and is recorded as one.
public enum AnalyzeSyntaxChecker {
  /// Returns the HDL flavour whose keyword list contains `name`, or `nil`. See the type's
  /// note: unset by default, so the keyword rule does not fire.
  ///
  /// Java: `CorrectLabel.hdlCorrectLabel(String)`, which answers `"VHDL"`, `"Verilog"` or
  /// `null`. Only the nil-ness is used here, but the flavour picks the message key.
  nonisolated(unsafe) public static var hdlKeywordCheck: ((String) -> String?)?

  /// Java: `getErrorMessage(String)`, as the list of message keys it would have concatenated.
  ///
  /// Java builds one `String` by appending localised fragments; carrying keys instead is the
  /// same rule this module already follows for `ParserError` (see `AnalyzeStrings.swift`).
  /// Order matches upstream's append order, so joining the rendered fragments reproduces the
  /// Java message verbatim.
  public static func errorMessageKeys(_ value: String) -> [(key: String, args: [String])] {
    // Java: `StringUtil.isNullOrEmpty(val)` -> no message at all. This guard is what keeps
    // `charAt(0)` below in range.
    guard !value.isEmpty else { return [] }

    var out: [(key: String, args: [String])] = []
    let chars = Array(value)

    // Java: `variablePattern.matcher(val).matches()` with `^([a-zA-Z]+\w*)`. `matches()`
    // anchors both ends, so this is "one or more ASCII letters, then word characters".
    if !matchesVariablePattern(chars) {
      out.append(("variableInvalidCharacters", []))
    }

    if chars[0].isJavaDigit {
      out.append(("variableStartsWithDigit", []))
    } else {
      // Java resets the matcher and uses `find()`, the *prefix* match, to locate the first
      // character that is not part of a legal name, then reports it. When the whole string is
      // legal, `end()` == length and nothing is reported. When `find()` fails outright the
      // index is 0, so the offending character reported is the first one.
      let firstIllegal = variablePrefixEnd(chars) ?? 0
      if firstIllegal != chars.count {
        out.append(("variableIllegalCharacter", [String(chars[firstIllegal])]))
      }
    }

    // Java: `forbiddenPattern.matcher(val).find()` with `__`.
    if value.contains("__") {
      out.append(("variableDoubleUnderscore", []))
    }

    // Java appends the keyword message *before* the trailing-underscore one; order preserved.
    if let flavour = hdlKeywordCheck?(value) {
      out.append((flavour == "VHDL" ? "variableVHDLKeyword" : "variableVerilogKeyword", []))
    }

    if value.hasSuffix("_") {
      out.append(("variableEndsWithUndescore", []))
    }

    return out
  }

  /// Java: `isVariableNameAcceptable(String, false)`.
  public static func isVariableNameAcceptable(_ value: String) -> Bool {
    errorMessageKeys(value).isEmpty
  }

  /// `^([a-zA-Z]+\w*)$`; Java's `\w` is `[a-zA-Z_0-9]` with the default (non-UNICODE) flags,
  /// which is why this is spelled out in ASCII rather than using `isLetter`/`isNumber`.
  private static func matchesVariablePattern(_ chars: [Character]) -> Bool {
    guard let first = chars.first, first.isAsciiLetter else { return false }
    var index = 1
    while index < chars.count && chars[index].isAsciiLetter { index += 1 }
    while index < chars.count && chars[index].isJavaWord { index += 1 }
    return index == chars.count
  }

  /// Java: `variableMatcher.find() ? variableMatcher.end() : 0`: the end of the longest
  /// prefix matching `[a-zA-Z]+\w*`, or `nil` when there is no match at all.
  ///
  /// **`find()` here can only ever match at offset 0**, because the pattern is
  /// `^([a-zA-Z]+\w*)` and `^` without `MULTILINE` matches the start of input and nothing
  /// else. `find()` still walks positions 1, 2, … looking for a match, but `^` fails at every
  /// one of them, so the whole search fails and upstream falls back to index `0`. A scan that
  /// looked for "the first letter anywhere" would report a different character than Java for
  /// a name such as `$abc`: Java names `$`, a forward scan names nothing at all because the
  /// letters run to the end of the string.
  ///
  /// (Acceptability is unaffected either way, a string that reaches here and is not wholly
  /// `[a-zA-Z]+\w*` has already produced `variableInvalidCharacters`, but `errorMessageKeys`
  /// is public and its contents are the thing a UI shows the user.)
  private static func variablePrefixEnd(_ chars: [Character]) -> Int? {
    guard let first = chars.first, first.isAsciiLetter else { return nil }
    var index = 0
    while index < chars.count && chars[index].isAsciiLetter { index += 1 }
    while index < chars.count && chars[index].isJavaWord { index += 1 }
    return index
  }
}

/// Java: `VariableTab.checkindex(String)`; parses the `[msb]` or `[msb..lsb]` suffix of a
/// CSV column label and answers the bit count, or a negative code saying what was wrong.
///
/// The rest of `VariableTab` is Swing and NOT-PORTED; this one static method is called from
/// `data/CsvInterpretor`, so it comes down here. See `AnalyzeNotPorted.swift`.
public enum BitRangeParse {
  /// Java: `VariableTab.NO_START_PAR` … `INVALID_CHARS`, the negative return codes.
  ///
  /// Kept as an `Int` result rather than a `throws`, because the one caller in this module
  /// (`CsvInterpretor`) branches on `<= 0` and reports a single generic message; upstream's
  /// per-code messages are a `VariableTab` concern.
  public enum Failure: Int {
    case noStartParenthesis = -1
    case noValidMsbIndex = -2
    case noValidIndexSeparator = -3
    case noValidLsbIndex = -4
    case lsbBiggerThanMsb = -5
    case noFinalParenthesis = -6
    case invalidCharacters = -7
  }

  /// Java: `checkindex(String)`. Positive is the bit count; `0` and the negative `Failure`
  /// codes are errors.
  ///
  /// The index arithmetic is `Int32` where Java uses `Integer.parseInt`: `[99999999999..0]`
  /// throws `NumberFormatException` upstream and must not silently succeed here. Java lets
  /// that exception escape `checkindex` uncaught; D13 says a malformed string must not trap,
  /// so this returns `.noValidMsbIndex` / `.noValidLsbIndex` instead of crashing. That is a
  /// deliberate, narrow divergence in favour of not killing the process.
  public static func checkIndex(_ index: String) -> Int {
    let chars = Array(index)
    let length = chars.count
    var pos = 0
    if length < 2 { return 0 }
    guard chars[pos] == "[" else { return Failure.noStartParenthesis.rawValue }
    pos += 1
    while pos < length && chars[pos].isAsciiDigit { pos += 1 }
    if pos == 1 { return Failure.noValidMsbIndex.rawValue }
    guard let msb = Int32(String(chars[1..<pos])) else {
      return Failure.noValidMsbIndex.rawValue
    }
    if pos >= length { return Failure.noFinalParenthesis.rawValue }
    if chars[pos] == "]" {
      pos += 1
      return pos != length ? Failure.invalidCharacters.rawValue : Int(msb)
    }
    if pos >= length - 2 { return Failure.noValidIndexSeparator.rawValue }
    guard chars[pos] == "." && chars[pos + 1] == "." else {
      return Failure.noValidIndexSeparator.rawValue
    }
    pos += 2
    let lsbStart = pos
    while pos < length && chars[pos].isAsciiDigit { pos += 1 }
    if pos == lsbStart { return Failure.noValidLsbIndex.rawValue }
    guard let lsb = Int32(String(chars[lsbStart..<pos])) else {
      return Failure.noValidLsbIndex.rawValue
    }
    if lsb > msb { return Failure.lsbBiggerThanMsb.rawValue }
    if pos >= length { return Failure.noFinalParenthesis.rawValue }
    guard chars[pos] == "]" else { return Failure.noFinalParenthesis.rawValue }
    pos += 1
    if pos != length { return Failure.invalidCharacters.rawValue }
    // Java: `msbIndex - lsbIndex + 1`, in int. Both are non-negative and lsb <= msb, so the
    // subtraction cannot wrap; the +1 can only overflow at Integer.MAX_VALUE, which the
    // Int32 parse above has already let through, so it is done in Int32 to wrap as Java does.
    return Int(msb &- lsb &+ 1)
  }
}

extension Character {
  /// Java's `[a-zA-Z]`, ASCII only.
  var isAsciiLetter: Bool {
    ("a"..."z").contains(self) || ("A"..."Z").contains(self)
  }

  /// Java's `[0-9]`, ASCII only: `"0123456789".indexOf(kar) >= 0` in upstream's loops.
  var isAsciiDigit: Bool {
    ("0"..."9").contains(self)
  }

  /// Java's `\w` without `UNICODE_CHARACTER_CLASS`: `[a-zA-Z_0-9]`.
  var isJavaWord: Bool {
    isAsciiLetter || isAsciiDigit || self == "_"
  }

  /// Java's regex `\s` without `UNICODE_CHARACTER_CLASS`: `[ \t\n\x0B\f\r]` and nothing else.
  ///
  /// Deliberately *not* `Character.isWhitespace`, which is what `Scanner` uses and which is
  /// Unicode-aware. `TruthtableTextFile` splits with `\\s+`, so a U+00A0 in a truth-table
  /// line has to stay part of the field exactly as it does in Java.
  var isJavaRegexSpace: Bool {
    self == " " || self == "\t" || self == "\n" || self == "\u{0B}" || self == "\u{0C}"
      || self == "\r"
  }

  /// Java's `Character.isDigit(char)`, which, unlike `\d`, *is* Unicode-aware and accepts
  /// e.g. Arabic-Indic digits. `SyntaxChecker` uses it for the starts-with-a-digit test, so
  /// the Unicode-aware version is the faithful one there.
  var isJavaDigit: Bool {
    guard let scalar = unicodeScalars.first, unicodeScalars.count == 1 else { return false }
    return scalar.properties.numericType == .decimal
  }
}
