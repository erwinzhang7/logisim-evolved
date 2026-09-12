// LineBuffer: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/util/LineBuffer.java`. Copyright by the Logisim-evolution developers.
// This translation is a derivative work and is therefore licensed GPL-3.0-only. See LICENSE.md.
//
// This class builds HDL source text: a buffer of lines plus a `{{key}}` → text substitution
// map, so a generator writes `contents.add("{{assign}} {{1}} {{=}} {{2}};", lhs, rhs)` instead
// of hand-splicing `Hdl.isVhdl()` branches at every call site. It is pure string manipulation,
// no Foundation, no AppKit, using the Swift standard library's native `Regex` for placeholder
// scanning.

/// `com.cburch.logisim.util.LineBuffer`.
public final class LineBuffer {
  public static let maxLineLength = 80
  public static let defaultIndentString = "   "  // three spaces
  public static let defaultIndent = 1
  public static let maxAllowedIndent = maxLineLength - (2 * Hdl.remarkMarkerLength)

  private var contents: [String] = []
  private var pairs = Pairs()
  private let space = " "

  // MARK: - Construction

  public init() {
    addDefaultPairs()
  }

  /// `new LineBuffer(String)`.
  public convenience init(line: String) {
    self.init()
    add(line)
  }

  /// `new LineBuffer(String, Pairs)`.
  public convenience init(line: String, pairsToAdd: Pairs) {
    self.init()
    pairs.addPairs(pairsToAdd)
    add(line)
  }

  /// `new LineBuffer(Pairs)`.
  public convenience init(pairsToAdd: Pairs) {
    self.init()
    pairs.addPairs(pairsToAdd)
  }

  /// `LineBuffer.getBuffer()`.
  public static func getBuffer() -> LineBuffer { LineBuffer() }

  /// `LineBuffer.getHdlBuffer()`.
  public static func getHdlBuffer() -> LineBuffer { getBuffer().addHdlPairs() }

  // MARK: - Basic queries

  public var size: Int { contents.count }
  public var isEmpty: Bool { contents.isEmpty }

  public func contains(_ line: String) -> Bool { contents.contains(line) }

  // MARK: - Pairs

  @discardableResult
  public func addPairs(_ pairsToAdd: Pairs) -> LineBuffer {
    pairs.addPairs(pairsToAdd)
    return self
  }

  /// `LineBuffer.addDefaultPairs()`.
  @discardableResult
  private func addDefaultPairs() -> LineBuffer {
    pair("1u", Self.getDefaultIndent())
    pair("2u", Self.getIndent(2))
    pair("3u", Self.getIndent(3))
    return self
  }

  /// `LineBuffer.addHdlPairs()`.
  @discardableResult
  public func addHdlPairs() -> LineBuffer {
    pair("assign", Hdl.assignPreamble())
    pair("=", Hdl.assignOperator())
    pair("==", Hdl.equalOperator())
    pair("!=", Hdl.notEqualOperator())
    pair("or", Hdl.orOperator())
    pair("and", Hdl.andOperator())
    pair("xor", Hdl.xorOperator())
    pair("not", Hdl.notOperator())
    pair("<", Hdl.bracketOpen())
    pair(">", Hdl.bracketClose())
    pair("else", Hdl.elseStatement())
    pair("endif", Hdl.endIf())
    pair("0b", Hdl.zeroBit())
    pair("1b", Hdl.oneBit())
    return self
  }

  /// `LineBuffer.addVhdlKeywords()`.
  @discardableResult
  public func addVhdlKeywords() -> LineBuffer {
    for keyword in Vhdl.vhdlKeywordSet() {
      pair(keyword.lowercased(), keyword)
    }
    return self
  }

  @discardableResult
  public func clear() -> LineBuffer {
    clearBuffer()
    clearPairs()
    return self
  }

  @discardableResult
  public func clearPairs() -> LineBuffer {
    pairs.clear()
    return self
  }

  @discardableResult
  public func clearBuffer() -> LineBuffer {
    contents.removeAll()
    return self
  }

  // MARK: - Adding lines

  /// `LineBuffer.addUnique(String, Object...)`.
  @discardableResult
  public func addUnique(_ fmt: String, _ args: CustomStringConvertible...) -> LineBuffer {
    let line = applyPairs(Self.format(fmt, args))
    if !contents.contains(line) { add(line, applyMap: false) }
    return self
  }

  /// `LineBuffer.addUnique(String)`.
  @discardableResult
  public func addUnique(line rawLine: String) -> LineBuffer {
    let line = applyPairs(rawLine)
    if !contents.contains(line) { add(line, applyMap: false) }
    return self
  }

  /// `LineBuffer.add(String)`.
  @discardableResult
  public func add(_ line: String) -> LineBuffer {
    add(line, applyMap: true)
  }

  /// `LineBuffer.add(String, boolean)`.
  @discardableResult
  public func add(_ rawLine: String, applyMap: Bool) -> LineBuffer {
    let line = applyMap ? Self.applyPairs(rawLine, pairs) : rawLine
    validateLineNoPositionals(line)
    contents.append(line)
    return self
  }

  /// `LineBuffer.add(String, Object...)`.
  @discardableResult
  public func add(_ fmt: String, _ args: CustomStringConvertible...) -> LineBuffer {
    add(fmt, Pairs.fromArgs(args))
  }

  /// `LineBuffer.add(String, Pairs)`.
  @discardableResult
  public func add(_ fmt: String, _ argPairs: Pairs) -> LineBuffer {
    let resolved = Self.applyPairs(fmt, argPairs)
    validateLineNoPositionals(resolved)
    return add(resolved)
  }

  /// `LineBuffer.add(Collection<String>)`.
  @discardableResult
  public func add<S: Sequence>(_ lines: S) -> LineBuffer where S.Element == String {
    for line in lines { add(line) }
    return self
  }

  /// `LineBuffer.addLines(String...)`.
  @discardableResult
  public func addLines(_ lines: String...) -> LineBuffer {
    add(lines)
  }

  /// `LineBuffer.add(LineBuffer)`.
  @discardableResult
  public func add(_ otherBuffer: LineBuffer) -> LineBuffer {
    add(otherBuffer.get())
  }

  // MARK: - Pair application

  public func applyPairs(_ fmt: String) -> String {
    Self.applyPairs(fmt, pairs)
  }

  /// `LineBuffer.applyPairs(String, Pairs)`.
  public static func applyPairs(_ format: String, _ pairs: Pairs?) -> String {
    guard let pairs else { return format }
    var result = format
    for (key, value) in pairs.container {
      result = replacingPlaceholder(in: result, key: key, with: value)
    }
    return result
  }

  /// Replaces every `{{ key }}` occurrence (arbitrary interior whitespace, matched exactly as
  /// Java's `\{\{\s*key\s*\}\}` does) with `value`, without touching anything else.
  private static func replacingPlaceholder(in text: String, key: String, with value: String)
    -> String
  {
    guard let regex = try? Regex("\\{\\{\\s*\(NSRegexEscape.escape(key))\\s*\\}\\}") else {
      return text
    }
    return text.replacing(regex, with: value)
  }

  /// `LineBuffer.repeat(int, String)`.
  @discardableResult
  public func repeatLine(_ count: Int, _ line: String) -> LineBuffer {
    for _ in 0..<count { add(line) }
    return self
  }

  /// `LineBuffer.empty()`.
  @discardableResult
  public func empty() -> LineBuffer { repeatLine(1, "") }

  /// `LineBuffer.empty(int)`.
  @discardableResult
  public func empty(_ count: Int) -> LineBuffer { repeatLine(count, "") }

  // MARK: - Retrieval

  /// `LineBuffer.get(int)`.
  public func get(_ index: Int) -> String { contents[index] }

  /// `LineBuffer.get()`.
  public func get() -> [String] { contents }

  /// `LineBuffer.getWithIndent()`.
  public func getWithIndent() -> [String] { getWithIndent(Self.getDefaultIndent()) }

  /// `LineBuffer.getWithIndent(int)`.
  public func getWithIndent(_ howMany: Int) -> [String] { getWithIndent(Self.getIndent(howMany)) }

  /// `LineBuffer.getWithIndent(int, String)`.
  public func getWithIndent(_ howMany: Int, _ indent: String) -> [String] {
    getWithIndent(String(repeating: indent, count: howMany))
  }

  /// `LineBuffer.getWithIndent(String)`.
  ///
  /// ── Java's `String.split` DISCARDS TRAILING EMPTY FIELDS ────────────────────────────────
  ///
  /// Upstream is `content.split("\n")`, and the one-argument `split` uses limit 0, which strips
  /// every trailing empty string from the result. Swift's
  /// `split(separator:omittingEmptySubsequences: false)` keeps them, so every multi-line `add(…)`
  /// whose text ends in a newline gained a blank line in the emitted architecture.
  ///
  /// All four component families found this independently while diffing against the jar; it is
  /// the single highest-count framework divergence in HDL output, and it is the same semantic as
  /// `javaSplitOnLiteral` in the codec (task #37): one Java behaviour, several call sites.
  ///
  /// The exact rule is `javaSplit(_:on:)` below, which is NOT the same as "keep one empty
  /// field", the shape this was first fixed with and which was wrong.
  public func getWithIndent(_ indent: String) -> [String] {
    var result: [String] = []
    for content in contents {
      for line in javaSplit(content, on: "\n") {
        result.append(line.isEmpty ? line : indent + line)
      }
    }
    return result
  }

  public func getPairCopy() -> Pairs { pairs.clone() }

  // MARK: - Indentation helpers

  public static func getDefaultIndent() -> String {
    getIndent(defaultIndent, defaultIndentString)
  }

  public static func getIndent(_ indentUnits: Int) -> String {
    getIndent(indentUnits, defaultIndentString)
  }

  public static func getIndent(_ indentUnits: Int, _ indentString: String) -> String {
    String(repeating: indentString, count: max(0, indentUnits))
  }

  // MARK: - Remark blocks

  /// `LineBuffer.addRemarkBlock(String)`.
  @discardableResult
  public func addRemarkBlock(_ remarkText: String) -> LineBuffer {
    addRemarkBlock(remarkText, 0)
  }

  /// `LineBuffer.addRemarkBlock(String, int)`.
  @discardableResult
  public func addRemarkBlock(_ remarkText: String, _ nrOfIndentSpaces: Int) -> LineBuffer {
    add(buildRemarkBlock(remarkText, nrOfIndentSpaces))
    return self
  }

  /// `LineBuffer.buildRemarkBlock(String, int)`.
  ///
  /// Generator-authoring misuse (negative or over-long indentation) traps rather than throws:
  /// it is a call-site bug in a generator, never something a `.circ` file can trigger (D13).
  private func buildRemarkBlock(_ remarkText: String, _ indentSpaces: Int) -> [String] {
    precondition(indentSpaces >= 0, "Negative indentation is not allowed.")
    precondition(
      indentSpaces <= Self.maxAllowedIndent,
      "Max allowed indentation is \(Self.maxAllowedIndent), \(indentSpaces) given.")

    let maxRemarkLineLength =
      Self.maxLineLength - indentSpaces - (2 * Hdl.remarkMarkerLength)
    let indent = String(repeating: space, count: indentSpaces)
    var contentLines: [String] = []

    // Java is `WordUtils.wrap(...).split("\n")`, so a newline already present INSIDE the remark
    // text becomes its own separately-framed comment line. The port left such newlines embedded,
    // so a multi-line remark rendered with a single `--` frame around the whole block and its
    // padding computed from the wrong length.
    //
    // `Shifter`'s "ShifterMode represents when:" block is the only case in the corpus today,
    // because `AbstractHdlGeneratorFactory` otherwise passes single-line remarks.
    var remarkLines: [String] = []
    for wrapped in Self.wordWrap(remarkText, width: maxRemarkLineLength) {
      remarkLines.append(contentsOf: javaSplit(wrapped, on: "\n"))
    }

    var line = indent + Hdl.getRemarkBlockStart()
    line += String(repeating: Hdl.getRemarkChar(), count: max(0, Self.maxLineLength - line.count))
    contentLines.append(line)

    for remarkLine in remarkLines {
      line = indent + Hdl.getRemarkBlockLineStart() + remarkLine
      if remarkLine.count < maxRemarkLineLength {
        line += String(repeating: space, count: maxRemarkLineLength - remarkLine.count)
      }
      line += Hdl.getRemarkBlockLineEnd()
      contentLines.append(line)
    }

    line = indent
    line += String(
      repeating: Hdl.getRemarkChar(),
      count: max(0, Self.maxLineLength - line.count - Hdl.remarkMarkerLength))
    line += Hdl.getRemarkBlockEnd()
    contentLines.append(line)

    return contentLines
  }

  /// The behaviour of Apache Commons `WordUtils.wrap(text, width, "\n", true)`: greedy word
  /// wrap at `width` columns, splitting a single word longer than `width` mid-word (the
  /// `wrapLongWords = true` argument) rather than overflowing the line.
  private static func wordWrap(_ text: String, width: Int) -> [String] {
    guard width > 0 else { return [text] }
    var lines: [String] = []
    var current = ""
    for rawWord in text.split(separator: " ", omittingEmptySubsequences: false) {
      var word = String(rawWord)
      while word.count > width {
        let head = String(word.prefix(width))
        if current.isEmpty {
          lines.append(head)
        } else {
          lines.append(current)
          lines.append(head)
          current = ""
        }
        word.removeFirst(width)
      }
      let candidate = current.isEmpty ? word : current + " " + word
      if candidate.count > width && !current.isEmpty {
        lines.append(current)
        current = word
      } else {
        current = candidate
      }
    }
    if !current.isEmpty || lines.isEmpty { lines.append(current) }
    return lines
  }

  /// `LineBuffer.addRemarkLine(String)`.
  @discardableResult
  public func addRemarkLine(_ remarkText: String) -> LineBuffer {
    add("{{1}}{{2}}", Hdl.getLineCommentStart(), remarkText)
    return self
  }

  // MARK: - Static formatting entry points

  /// `LineBuffer.format(String, Object...)`.
  public static func format(_ fmt: String, _ args: [CustomStringConvertible]) -> String {
    applyPairs(fmt, Pairs.fromArgs(args))
  }

  public static func format(_ fmt: String, _ args: CustomStringConvertible...) -> String {
    format(fmt, args)
  }

  /// `LineBuffer.formatHdl(String, Object...)`.
  public static func formatHdl(_ fmt: String, _ args: CustomStringConvertible...) -> String {
    getHdlBuffer().add(fmt, args).get(0)
  }

  /// `LineBuffer.formatVhdl(String, Object...)`.
  public static func formatVhdl(_ fmt: String, _ args: CustomStringConvertible...) -> String {
    getHdlBuffer().addVhdlKeywords().add(fmt, args).get(0)
  }

  // MARK: - Diagnostics

  /// `LineBuffer.warn(String, Object...)`.
  @discardableResult
  private func warn(_ fmt: String, _ args: CustomStringConvertible...) -> LineBuffer {
    print("WARNING: " + Self.format(fmt, args))
    return self
  }

  /// `LineBuffer.abort(String)` / `abort(String, Object...)`; `throw new RuntimeException(msg)`
  /// upstream (`LineBuffer.java:684`).
  ///
  /// This used to `preconditionFailure`, on the reasoning that every call site is malformed
  /// template usage inside a generator's own source and so unreachable from a `.circ` file.
  /// **That is not true.** `add(_:applyMap:)` substitutes the pair map and *then* validates the
  /// RESULT, so a substituted **value** containing `{{…}}` is indistinguishable from an unmapped
  /// placeholder. Values include component labels, and `CorrectLabel.correctLabel` only maps
  /// spaces and hyphens to underscores; it does not strip braces. A component labelled
  /// `a{{x}}b` therefore reaches `#E006`. See `LineBufferAbortTests`.
  ///
  /// D13 says a catchable Java exception becomes a Swift `throw`. It is recorded rather than
  /// thrown here for one reason, stated plainly so it is not mistaken for a judgement that
  /// trapping was fine: `abort` is reached from `add`, which has **641 call sites across 47
  /// generator files**, all in fluent chains. Making `add` throwing is a mechanical but very
  /// large change to files whose byte-exactness was just established, and it does not belong in
  /// the same commit as the registration join. See the report.
  ///
  /// What this does instead is faithful in effect and safe in the interim: validation is a pure
  /// check, so recording instead of dying changes **no emitted byte**, and `Reporter` is already
  /// this module's channel for a fatal generation error (`CorrectLabel.isCorrectLabel` uses it
  /// the same way). The process survives, the user sees the error, and `hasAbortedValidation`
  /// lets a caller refuse to write the file.
  private func abort(_ fmt: String, _ args: CustomStringConvertible...) {
    let message = Self.format(fmt, args)
    abortedValidationMessages.append(message)
    Reporter.shared.addFatalError(message)
  }

  /// Every `abort` message this buffer recorded, in order. Empty on a well-formed buffer.
  public private(set) var abortedValidationMessages: [String] = []

  /// Whether any template in this buffer failed validation. A caller assembling a file should
  /// consult this before writing it; the text is emitted regardless, exactly as it was before
  /// the placeholder went unresolved, so writing it would produce invalid HDL silently.
  public var hasAbortedValidation: Bool { !abortedValidationMessages.isEmpty }

  // MARK: - Placeholder validation

  /// `LineBuffer.extractPlaceholders(String)`: every `{{...}}` key, trimmed, first occurrence
  /// order, deduplicated.
  public func extractPlaceholders(_ fmt: String) -> [String] {
    var keys: [String] = []
    guard let regex = try? Regex("\\{\\{.+?\\}\\}") else { return keys }
    for match in fmt.matches(of: regex) {
      var keyStr = String(fmt[match.range])
      keyStr = String(keyStr.dropFirst(2).dropLast(2))
      keyStr = keyStr.trimmingCharacters()
      if !keys.contains(keyStr) { keys.append(keyStr) }
    }
    return keys
  }

  public func validateLineNoPositionals(_ fmt: String) {
    validateLine(fmt, nil)
  }

  /// `LineBuffer.validateLineWithPositionalArgs(String, Object...)`.
  private func validateLineWithPositionalArgs(_ fmt: String, _ args: [CustomStringConvertible]) {
    let (positionalPlaceholders, _) = classifyPlaceholders(extractPlaceholders(fmt))
    let posArgsCnt = positionalPlaceholders.count

    if positionalPlaceholders.isEmpty {
      if !args.isEmpty {
        warn(
          "#E004: Useless positional arguments. Expected nothing, but received {{2}} for '{{1}}'.",
          fmt, posArgsCnt)
      }
    } else {
      if posArgsCnt < args.count {
        abort(
          "#E001: Too many positional arguments, Expected {{2}}, but received {{3}} for '{{1}}'.",
          fmt, posArgsCnt, args.count)
      }
      if posArgsCnt > args.count {
        abort(
          "#E002: Insufficient positional arguments. Expected {{2}}, but received {{3}} for '{{1}}'.",
          fmt, posArgsCnt, args.count)
      }
      for posKey in positionalPlaceholders {
        if let value = Int(posKey), value > posArgsCnt {
          warn(
            "#E003: Invalid positional argument. '{{1}}' used, but max value is {{2}} for '{{3}}'.",
            posKey, posArgsCnt, fmt)
        }
      }
    }
  }

  /// `LineBuffer.validateLine(String, Pairs)`.
  private func validateLine(_ fmt: String, _ argPairs: Pairs?) {
    let (positionalPlaceholders, pairedPlaceholders) = classifyPlaceholders(
      extractPlaceholders(fmt))

    if let argPairs {
      validateLineWithPositionalArgs(fmt, argPairs.container.values.map { $0 })
    } else if !positionalPlaceholders.isEmpty {
      abort(
        "#E004: No positional arguments, but expected {{2}} for '{{1}}'.",
        fmt, positionalPlaceholders.count)
    }

    for key in pairedPlaceholders {
      let known = pairs.container[key] != nil || (argPairs?.container[key] != nil)
      if !known {
        abort("#E006: No mapping for '{{1}}' placeholder in '{{2}}'.", key, fmt)
      }
    }
  }

  /// Splits placeholder keys into positional (`{{1}}`, `{{2}}`, …) and paired (everything
  /// else), mirroring `LineBuffer.initValidator`.
  private func classifyPlaceholders(_ placeholders: [String]) -> (
    positional: [String], paired: [String]
  ) {
    var positional: [String] = []
    var paired: [String] = []
    for key in placeholders {
      if key.allSatisfy(\.isWholeNumber) && !key.isEmpty {
        positional.append(key)
      } else {
        paired.append(key)
      }
    }
    return (positional, paired)
  }

  // MARK: - Equatable / description

  /// `LineBuffer.equals(Object)`: content and order must match exactly.
  public static func == (lhs: LineBuffer, rhs: LineBuffer) -> Bool {
    lhs.contents == rhs.contents
  }

  public var description: String { String(describing: contents) }

  // MARK: - Pair convenience

  /// `LineBuffer.pair(String, Object)`.
  @discardableResult
  public func pair(_ key: String, _ value: CustomStringConvertible) -> LineBuffer {
    pairs.pair(key, value)
    return self
  }

  // MARK: - Pairs container

  /// `LineBuffer.Pairs`: the key→value substitution map, plus the positional-argument
  /// convenience constructor.
  public final class Pairs {
    fileprivate var container: [String: String] = [:]

    public init() {}

    public init(key: String, value: CustomStringConvertible) {
      pair(key, value)
    }

    /// `Pairs.fromArgs(Object...)`: `{{1}}`, `{{2}}`, … in argument order.
    public static func fromArgs(_ args: [CustomStringConvertible]) -> Pairs {
      let map = Pairs()
      var index = 1
      for arg in args {
        map.addPositionalPair(String(index), arg.description)
        index += 1
      }
      return map
    }

    @discardableResult
    public func pair(_ key: String, _ value: CustomStringConvertible) -> Pairs {
      addNonPositionalPair(key, value)
    }

    /// `Pairs.addNonPositionalPair(String, Object)`.
    ///
    /// A numeric-only key collides with the positional-placeholder namespace: a bug in the
    /// calling generator, not something a `.circ` file can produce, so this traps (D13).
    @discardableResult
    public func addNonPositionalPair(_ key: String, _ value: CustomStringConvertible) -> Pairs {
      precondition(
        !(key.allSatisfy(\.isWholeNumber) && !key.isEmpty),
        "Invalid pair key '\(key)'. You cannot add positional arguments as pairs.")
      container[key] = value.description
      return self
    }

    @discardableResult
    public func addPairs(_ other: Pairs) -> Pairs {
      for (key, value) in other.container { addNonPositionalPair(key, value) }
      return self
    }

    @discardableResult
    public func addPositionalPair(_ key: String, _ value: CustomStringConvertible) -> Pairs {
      precondition(
        key.allSatisfy(\.isWholeNumber) && !key.isEmpty,
        "Invalid pair key '\(key)'. Positional arguments' keys must be numeric.")
      container[key] = value.description
      return self
    }

    @discardableResult
    public func clear() -> Pairs {
      container.removeAll()
      return self
    }

    public func entries() -> [(key: String, value: String)] {
      container.map { (key: $0.key, value: $0.value) }
    }

    public func clone() -> Pairs {
      let copy = Pairs()
      for (key, value) in container { copy.pair(key, value) }
      return copy
    }
  }
}

extension LineBuffer: Equatable {}

extension LineBuffer.Pairs {
  fileprivate var _debugContainer: [String: String] { container }
}

/// Regex metacharacters need escaping when a caller-supplied key (an attribute or wire name) is
/// spliced into a pattern string, exactly as `Matcher.quoteReplacement`/`Pattern.quote` would.
/// Placeholder keys in practice are identifiers, so this only ever matters defensively.
private enum NSRegexEscape {
  private static let special = Set(".^$*+?()[]{}|\\")

  static func escape(_ text: String) -> String {
    var result = ""
    for character in text {
      if special.contains(character) { result.append("\\") }
      result.append(character)
    }
    return result
  }
}

extension String {
  /// Java's `String.strip()` (Unicode whitespace trim), used when parsing placeholder keys.
  fileprivate func trimmingCharacters() -> String {
    var slice = self[...]
    while let first = slice.first, first.isWhitespace { slice = slice.dropFirst() }
    while let last = slice.last, last.isWhitespace { slice = slice.dropLast() }
    return String(slice)
  }
}

// ── Java's `String.split(String)`, which is not what Swift's `split` does ────────────────────
//
// Every one of the four component families found this independently while diffing generated HDL
// against the 4.1.0 jar, which is why it lives in one place now rather than being re-derived at
// each call site.
//
// The rule, PROBED ON openjdk@21 rather than reasoned about; the first fix here was reasoned
// about and was wrong:
//
//     "".split("\n")       len=1   [""]
//     "\n".split("\n")     len=0   []
//     "\n\n".split("\n")   len=0   []
//     "a\nb".split("\n")   len=2   ["a", "b"]
//     "a\nb\n".split("\n") len=2   ["a", "b"]
//     "a\n\n".split("\n")  len=1   ["a"]
//     ",".split(",")       len=0   []
//     ",,".split(",")      len=0   []
//
// So: split, then discard **all** trailing empty fields. The empty input is the only special
// case, and it yields `[""]` not because one empty field is preserved but because no match
// occurred at all; Java returns the whole input when the pattern never matches.
//
// **The first version of this fix guarded with `count > 1` instead**, on the theory that "one
// empty field survives". That gives the right answer for `""` and the WRONG answer for any input
// that is entirely separators: `"\n"` became `[""]` where Java gives `[]`. It was caught by
// cross-checking against the codec's `javaSplitOnLiteral`, which was being fixed for the same
// Java behaviour at the same time and had arrived at a different shape. Two implementations of
// one semantic disagreeing is the same defect pattern as every other seam in this project, each
// half plausible, nothing owning the join, and here the join was a fact about Java.
//
// `LogisimFile.javaSplitOnLiteral` is the codec's copy of this. They should become one function;
// that is deliberately not done here because `LogisimFile` is being edited concurrently.
func javaSplit(_ text: String, on separator: Character) -> [String] {
  if text.isEmpty { return [""] }
  var parts = text.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
  while let last = parts.last, last.isEmpty { parts.removeLast() }
  return parts
}
