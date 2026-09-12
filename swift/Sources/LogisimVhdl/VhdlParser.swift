// VhdlParser: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/logisim/vhdl/base/VhdlParser.java. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore licensed
// GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── What this parser is, and is not ─────────────────────────────────────────────────────
//
// This is *not* a VHDL grammar. It is a small hand-rolled scanner over a fixed sequence of
// regexes that recognises exactly one shape:
//
//     [library/use clauses] entity NAME is [port(...);] [generic(...);]... end [entity] NAME;
//     architecture ...                                    -- captured verbatim, unparsed
//
// Anything else, multiple entities per file, ports declared before generics, a `component`
// or `package` declaration, a port type other than `std_logic`/`std_logic_vector`, is
// rejected. Upstream additionally shells out to a real VHDL compiler (QuestaSim/ModelSim's
// `vcom`, via `com.cburch.logisim.util.Softwares.validateVhdl`) *before* running this parser;
// that is the co-simulation bridge D11 puts out of scope for macOS, so the port's validation
// ceiling is exactly this regex parser; stricter inputs that only a real compiler would
// reject are no longer caught, and the "architecture" body is never validated at all (see
// `getArchitecture`).
//
// Ported faithfully, including its bugs: most importantly:
//
//   * `getPortType` recognises the source tokens `"in"`, `"out"`, and, as a direction token,
//     literally `"input"`, which it maps to `Port.INOUT`. The actual VHDL keyword `inout` is
//     never recognised as a direction token and always throws. This looks like a
//     find-and-replace typo upstream (`"inout"` → `"input"`) that shipped anyway; see
//     `VhdlPortDirection.parse(token:)`.
//   * A port whose direction parsed as `.inout_` (via that `"input"` token, since real
//     `inout` can never reach this point) is filed into the *outputs* list, not a separate
//     inout list: `parsePort`'s `if (ptype.equals(Port.INPUT)) inputs.add(...) else
//     outputs.add(...)`.
//   * Generic parsing keeps re-scanning for a following time unit (`fs`/`ps`/`ns`/`us`)
//     whenever the generic's type is `time`, even when no default value was supplied at all;
//     `parseGeneric`'s `if (type.equalsIgnoreCase("time"))` block is not conditioned on the
//     preceding `if (input.next(DVALUE))` having matched.
//   * The "unrecognized time unit" message interpolates the *numeric* `dval`, not the
//     offending unit string: a copy/paste bug in the Java (`"Unrecognized time unit: " +
//     dval`).
//   * Integer overflow in the time-unit multiplication (`dval *= 1000000000`) wraps silently,
//     exactly as Java's 32-bit `int` does; see `&*` below.
//   * Only `integer`, `natural`, `positive` and `time` generics are accepted; anything else
//     (`boolean`, `real`, a user-defined type) is rejected.
//
// ── Regex engine notes ───────────────────────────────────────────────────────────────────
//
// Java builds each pattern from a terse template via `regex(String)`: a leading `^`, then
// every run of two spaces becomes `\s+` (required whitespace) and every remaining single
// space becomes `\s*` (optional whitespace): see `vhdlRegex(_:)` below, which reproduces
// that substitution algorithm exactly (not just its effect), because a template with three
// consecutive spaces depends on the two-pass, left-to-right, non-overlapping order.
//
// `Scanner.next(Pattern)` is Java's `Matcher.lookingAt()`: match anchored at the *start* of
// the remaining input, without requiring the match to reach the end. `VhdlScanner.next(_:)`
// reproduces this with `NSRegularExpression` by matching over the full remaining range and
// checking the match starts at offset 0 (guaranteed by the template's own leading `^` in
// practice, but checked explicitly rather than assumed).
//
// **`\w`, `\d` and `\s` mean different things to the two engines, and the difference decides
// what the parser accepts.** Java compiles these patterns without `UNICODE_CHARACTER_CLASS`,
// so the three classes are ASCII; ICU (behind `NSRegularExpression`) defines them over
// Unicode. Left alone, the port would accept sources upstream rejects: a non-breaking space
// between two tokens, an entity named `café`, a bus range written in Arabic-Indic digits.
// `javaCharacterClasses(_:)` rewrites all six escapes to Java's definitions; see its doc
// comment for the one residual divergence (ICU's case folding is full Unicode, Java's is
// ASCII) and why it is left as is.
//
// One further Java detail is deliberately *not* reproduced: `Scanner.next` advances with
// `input = match.hitEnd() ? "" : input.substring(m.end())`, and `hitEnd()` asks whether the
// engine ever looked past the end of input, not whether the match reached it. For a pattern
// that peeks past the end and then backtracks to a shorter match (`^(?:a{5}|a)` against
// `"aaa"`) Java therefore discards the unmatched tail. `NSRegularExpression` exposes no
// equivalent, and none of the fourteen patterns here has that shape; each ends in a greedy
// element or a required literal, so `hitEnd()` and `m.end() == length` coincide. Recorded
// because it is a real behavioural difference in the general case, not because it bites.

import Foundation
import LogisimKernel

// MARK: - Port and generic descriptions

/// `Port.INPUT` / `Port.OUTPUT` / `Port.INOUT`, as recognised by `VhdlParser.getPortType`.
///
/// See the file header: the real VHDL keyword `inout` can never produce `.inout_` here; only
/// the literal (mistaken) source token `"input"` does.
public enum VhdlPortDirection: Equatable, Sendable {
  case input
  case output
  case inout_

  /// `getPortType(String)`. Case-insensitive on the VHDL source token.
  static func parse(token: String) -> VhdlPortDirection? {
    if token.caseInsensitiveCompare("in") == .orderedSame { return .input }
    if token.caseInsensitiveCompare("out") == .orderedSame { return .output }
    if token.caseInsensitiveCompare("input") == .orderedSame { return .inout_ }
    return nil
  }

  /// `PortDescription.getVhdlType()`.
  public var vhdlKeyword: String {
    switch self {
    case .input: return "in"
    case .output: return "out"
    case .inout_: return "inout"
    }
  }
}

/// `VhdlParser.PortDescription`.
public struct VhdlPortDescription: Equatable, Sendable {
  public let name: String
  public let direction: VhdlPortDirection
  public let width: BitWidth

  public init(name: String, direction: VhdlPortDirection, width: BitWidth) {
    self.name = name
    self.direction = direction
    self.width = width
  }
}

/// `VhdlParser.GenericDescription`.
public struct VhdlGenericDescription: Equatable, Sendable {
  public let name: String
  /// Always one of `"integer"`, `"natural"`, `"positive"`, `"time"`, lowercased.
  public let type: String
  public let defaultValue: Int32

  public init(name: String, type: String, defaultValue: Int32) {
    self.name = name
    self.type = type
    self.defaultValue = defaultValue
  }
}

// MARK: - Errors

/// `VhdlParser.IllegalVhdlContentException`. Java carries only a message; so does this.
///
/// The message text mirrors the English strings in `resources/logisim/strings/{hdl,std}/
/// hdl.properties` / `std.properties` (`S.get(...)`), reproduced verbatim since the kernel
/// does not localise (D9): see `AttributeParseError`/`BitWidthParseError` for the same
/// precedent elsewhere in the port.
public struct VhdlParserError: Error, Equatable, CustomStringConvertible, Sendable {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var description: String { message }

  public static let cannotFindEntity =
    VhdlParserError("The entity declaration cannot be found")
  public static let emptySource = VhdlParserError("Cannot parse empty content")
  public static let illegalPortSyntax = VhdlParserError("Illegal port syntax")
  public static func illegalPortSyntax(before remaining: String) -> VhdlParserError {
    VhdlParserError("Illegal port syntax before \(remaining)")
  }
  public static func invalidPortType(_ type: String) -> VhdlParserError {
    VhdlParserError("Invalid port type: \(type)")
  }
  public static func unsupportedPortType(_ type: String) -> VhdlParserError {
    VhdlParserError(
      "Unsupported port type: \u{201C}\(type)\u{201D}. Please only use "
        + "\u{201C}std_logic\u{201D} and \u{201C}std_logic_vector\u{201D}.")
  }
  public static let illegalGenericSyntax = VhdlParserError("Illegal generics syntax")
  public static func unsupportedGenericType(_ type: String) -> VhdlParserError {
    VhdlParserError("Unsupported generics type: \(type)")
  }
  public static func unrecognizedGenericDefault(_ value: String) -> VhdlParserError {
    VhdlParserError("Unrecognized generics default value: \(value)")
  }
  public static func unrecognizedTimeUnit(_ dval: Int32) -> VhdlParserError {
    // Bug-for-bug (see file header): Java interpolates the numeric value, not the unit text.
    VhdlParserError("Unrecognized time unit: \(dval)")
  }

  /// `java.lang.NumberFormatException`'s message for a radix-10 `Integer.parseInt` failure.
  ///
  /// Not an `IllegalVhdlContentException` upstream; `parsePort` calls `Integer.parseInt`
  /// unguarded, so the `NumberFormatException` escapes `parse()`. It is nonetheless *caught*,
  /// by `VhdlContent.setContent`'s `catch (Exception ex)`, and its message is what the user is
  /// shown; the exception type is invisible from outside. So D13 says this must throw, and
  /// carrying the same message means the user-visible text matches too.
  public static func numberFormat(_ text: String) -> VhdlParserError {
    VhdlParserError("For input string: \"\(text)\"")
  }
}

// MARK: - Regex plumbing (Scanner + the `regex(String)` template expander)

/// `VhdlParser.regex(String)`: expands the terse two-space/one-space template convention into
/// a real, compiled, case-insensitive, dot-matches-all pattern anchored at the start.
///
/// The two `replacingOccurrences` calls must run in this order and must both be *literal*
/// substring replacements (not regex-driven), exactly mirroring Java's
/// `pattern.replaceAll(" {2}", "\\s+")` followed by `pattern.replaceAll(" ", "\\s*")`, which,
/// because `" {2}"` as a regex matches nothing but two literal spaces, behaves identically to
/// a literal, non-overlapping, left-to-right substring replacement.
///
/// **The third step is not in the Java, and exists to make this parser reject what Java
/// rejects.** `java.util.regex` compiled *without* `UNICODE_CHARACTER_CLASS`, as every pattern
/// here is, defines `\w`, `\d` and `\s` as pure ASCII. ICU, which backs `NSRegularExpression`,
/// defines them over Unicode: `\d` is `\p{Nd}` (so Arabic-Indic digits match), `\w` includes
/// every alphabetic scalar (so `entity café is` parses), and `\s` includes `\p{Z}` (so a
/// non-breaking space, very reachable, it is what a copy-paste out of a web page or a PDF
/// leaves behind, counts as the whitespace between two tokens). Each of those makes the port
/// **accept a source upstream rejects**, which is the direction that silently produces a
/// component Java could never have built. Expanding the three classes to their Java definitions
/// removes all three divergences.
///
/// Ordering matters: this expansion must come last. `\S`'s replacement contains a literal
/// space, and `\s`'s contains a space and a tab, so running it before the two-space/one-space
/// pass would have those re-expanded as if they were template whitespace.
private func vhdlRegex(_ raw: String) -> NSRegularExpression {
  var pattern = javaTrim(raw)
  pattern = "^ " + pattern
  pattern = pattern.replacingOccurrences(of: "  ", with: "\\s+")
  pattern = pattern.replacingOccurrences(of: " ", with: "\\s*")
  pattern = javaCharacterClasses(pattern)
  // swiftlint:disable:next force_try; every pattern below is a fixed literal, compiled once.
  return try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive])
}

/// `java.util.regex.Pattern`'s ASCII definitions of `\w`, `\W`, `\d`, `\D`, `\s` and `\S`,
/// substituted into an ICU pattern so the two engines agree. See `vhdlRegex`.
///
/// Java: `\s` is `[ \t\n\x0B\f\r]`, `\w` is `[a-zA-Z_0-9]`, `\d` is `[0-9]`, and the upper-case
/// forms are their complements. A single left-to-right pass, so a replacement's own contents
/// are never rescanned; `\\` is consumed as a unit so an escaped backslash cannot be mistaken
/// for the start of a class escape.
///
/// Known residual divergence, documented rather than fixed: ICU's case-insensitive matching
/// applies full Unicode case folding, while Java's `CASE_INSENSITIVE` without `UNICODE_CASE`
/// folds ASCII only. So `entity foo i\u{17F}` (LATIN SMALL LETTER LONG S) still matches here
/// and not upstream. There is no ICU flag for ASCII-only folding, the patterns' literal text is
/// entirely ASCII, and no real VHDL source reaches it.
private func javaCharacterClasses(_ pattern: String) -> String {
  // Spelled as `\x{..}` escapes rather than literal control characters so the compiled pattern
  // stays readable in a debugger and cannot be mangled by an editor that trims trailing space.
  let space = #"\x{20}\x{09}\x{0A}\x{0B}\x{0C}\x{0D}"#
  var out = String.UnicodeScalarView()
  let scalars = Array(pattern.unicodeScalars)
  var index = 0
  while index < scalars.count {
    guard scalars[index] == "\\", index + 1 < scalars.count else {
      out.append(scalars[index])
      index += 1
      continue
    }
    let replacement: String?
    switch scalars[index + 1] {
    case "s": replacement = "[\(space)]"
    case "S": replacement = "[^\(space)]"
    case "w": replacement = "[a-zA-Z_0-9]"
    case "W": replacement = "[^a-zA-Z_0-9]"
    case "d": replacement = "[0-9]"
    case "D": replacement = "[^0-9]"
    default: replacement = nil
    }
    if let replacement {
      out.append(contentsOf: replacement.unicodeScalars)
    } else {
      // Not a class escape: copy both scalars, so `\\` never leaves a dangling backslash that
      // the next iteration would read as an escape introducer.
      out.append(scalars[index])
      out.append(scalars[index + 1])
    }
    index += 2
  }
  return String(out)
}

/// `VhdlParser.Scanner`. Walks `input` forward, always matching (Java: `lookingAt()`) at the
/// current position and discarding everything the match consumed.
private final class VhdlScanner {
  private(set) var input: String
  private var lastMatch: NSTextCheckingResult?
  private var lastMatchSource: NSString?

  init(_ input: String) { self.input = input }

  /// `Scanner.next(Pattern)`.
  @discardableResult
  func next(_ pattern: NSRegularExpression) -> Bool {
    let source = input as NSString
    guard
      let match = pattern.firstMatch(
        in: input, options: [], range: NSRange(location: 0, length: source.length)),
      match.range.location == 0
    else {
      lastMatch = nil
      lastMatchSource = nil
      return false
    }
    lastMatch = match
    lastMatchSource = source
    let end = match.range.location + match.range.length
    input = end >= source.length ? "" : source.substring(from: end)
    return true
  }

  /// `Scanner.match().group(index)`. `nil` when the group did not participate.
  func group(_ index: Int) -> String? {
    guard let match = lastMatch, let source = lastMatchSource, index < match.numberOfRanges
    else { return nil }
    let range = match.range(at: index)
    guard range.location != NSNotFound else { return nil }
    return source.substring(with: range)
  }

  /// `Scanner.remaining()`.
  var remaining: String { input }
}

// MARK: - VhdlParser

public final class VhdlParser {
  // Every pattern is a direct transcription of the Java template strings, run through the
  // same `regex(String)` expansion (`vhdlRegex` above).
  private static let libraryPattern = vhdlRegex("library  \\w+ ;")
  private static let usingPattern = vhdlRegex("use  \\S+ ;")
  private static let entityPattern = vhdlRegex("entity  (\\w+)  is")
  private static let endKeywordPattern = vhdlRegex("end  (\\w+) ;")
  private static let endEntityPattern = vhdlRegex("end entity  (\\w+) ;")
  private static let endPattern = vhdlRegex("end;")
  private static let architecturePattern = vhdlRegex("architecture .*")

  private static let semicolonPattern = vhdlRegex(";")
  private static let openListPattern = vhdlRegex("[(]")
  private static let doneListPattern = vhdlRegex("[)] ;")

  private static let portsPattern = vhdlRegex("port")
  private static let portPattern = vhdlRegex("(\\w+(?: , \\w+)*) : (\\w+)  (\\w+)")
  private static let rangePattern = vhdlRegex("[(] (\\d+) downto (\\d+) [)]")

  private static let genericsPattern = vhdlRegex("generic")
  private static let genericPattern = vhdlRegex("(\\w+(?: , \\w+)*) : (\\w+)")
  private static let dvaluePattern = vhdlRegex(":= (\\w+)")
  private static let unitPattern = vhdlRegex("(\\w+)")

  private static let supportedGenericTypes: Set<String> = ["integer", "natural", "positive", "time"]

  /// Java's constructor takes a plain `String`; the port accepts `String?` solely so a `nil`
  /// source reproduces the one path that genuinely needs it: Java's `new
  /// StringBuilder(source)` throwing `NullPointerException` on a null source, caught and
  /// re-thrown as `emptySourceException`. A non-null, merely *empty* string does **not** take
  /// this path in Java (it falls through to `CannotFindEntityException` once the entity
  /// pattern fails to match): preserved here for the same reason.
  private let source: String?

  public private(set) var inputs: [VhdlPortDescription] = []
  public private(set) var outputs: [VhdlPortDescription] = []
  public private(set) var generics: [VhdlGenericDescription] = []
  public private(set) var name: String = ""
  public private(set) var libraries: String = ""
  /// The `architecture ...` clause, captured verbatim to the end of input and never itself
  /// parsed: matching Java, which only recognises where the clause *starts*.
  public private(set) var architecture: String = ""

  public init(source: String?) {
    self.source = source
  }

  /// `VhdlParser.parse()`.
  public func parse() throws {
    let scanner = VhdlScanner(try Self.removeComments(source))
    parseLibraries(scanner)

    guard scanner.next(Self.entityPattern) else { throw VhdlParserError.cannotFindEntity }
    name = scanner.group(1) ?? ""

    while try parsePorts(scanner) || parseGenerics(scanner) {}

    let justEndForEntity = scanner.next(Self.endPattern)
    if (!scanner.next(Self.endKeywordPattern) && !scanner.next(Self.endEntityPattern) && !justEndForEntity)
      || (!justEndForEntity && (scanner.group(1) ?? "") != name)
    {
      throw VhdlParserError.cannotFindEntity
    }

    parseArchitecture(scanner)
    guard scanner.remaining.isEmpty else { throw VhdlParserError.cannotFindEntity }
  }

  // MARK: Comment stripping

  /// `VhdlParser.removeComments()`. VHDL line comments start with `--` and run to end of line.
  private static func removeComments(_ source: String?) throws -> String {
    guard let source else { throw VhdlParserError.emptySource }
    var text = source
    while let dashes = text.range(of: "--") {
      let endOfLine = endOfLineIndex(in: text, from: dashes.lowerBound)
      text.removeSubrange(dashes.lowerBound..<endOfLine)
    }
    return javaTrim(text)
  }

  /// `VhdlParser.getEOLIndex`: `\n`, then `\r\n`, then `\r`, in that priority order (checking
  /// for `\n` first also catches CRLF, since the embedded `\n` is found either way).
  private static func endOfLineIndex(in text: String, from index: String.Index) -> String.Index {
    if let r = text.range(of: "\n", range: index..<text.endIndex) { return r.lowerBound }
    if let r = text.range(of: "\r\n", range: index..<text.endIndex) { return r.lowerBound }
    if let r = text.range(of: "\r", range: index..<text.endIndex) { return r.lowerBound }
    return text.endIndex
  }

  // MARK: Libraries

  /// `VhdlParser.parseLibraries`.
  private func parseLibraries(_ scanner: VhdlScanner) {
    var result = ""
    while scanner.next(Self.libraryPattern) || scanner.next(Self.usingPattern) {
      let clause = javaTrim(scanner.group(0) ?? "")
      result += collapseWhitespace(clause) + "\n"
    }
    libraries = result
  }

  /// Java: `.replaceAll("\\s+", " ")`.
  private func collapseWhitespace(_ text: String) -> String {
    text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
  }

  // MARK: Architecture (captured verbatim, never parsed further)

  /// `VhdlParser.parseArchitecture`.
  private func parseArchitecture(_ scanner: VhdlScanner) {
    architecture = scanner.next(Self.architecturePattern) ? (scanner.group(0) ?? "") : ""
  }

  // MARK: Ports

  /// `VhdlParser.parsePorts`. `port ( decl ; decl ; ... ) ;`
  private func parsePorts(_ scanner: VhdlScanner) throws -> Bool {
    guard scanner.next(Self.portsPattern) else { return false }
    guard scanner.next(Self.openListPattern) else { throw VhdlParserError.illegalPortSyntax }
    try parsePort(scanner)
    while scanner.next(Self.semicolonPattern) { try parsePort(scanner) }
    guard scanner.next(Self.doneListPattern) else {
      throw VhdlParserError.illegalPortSyntax(before: scanner.remaining)
    }
    return true
  }

  /// `VhdlParser.parsePort`. `name[, name...] : IN|OUT|input std_logic[_vector(u downto l)]`
  private func parsePort(_ scanner: VhdlScanner) throws {
    guard scanner.next(Self.portPattern) else { throw VhdlParserError.illegalPortSyntax }
    let names = javaTrim(scanner.group(1) ?? "")
    let directionToken = javaTrim(scanner.group(2) ?? "")
    guard let direction = VhdlPortDirection.parse(token: directionToken) else {
      throw VhdlParserError.invalidPortType(directionToken)
    }
    let typeToken = javaTrim(scanner.group(3) ?? "")
    let isOneBit = typeToken.caseInsensitiveCompare("std_logic") == .orderedSame
    let isBitVector = typeToken.caseInsensitiveCompare("std_logic_vector") == .orderedSame
    guard isOneBit || isBitVector else { throw VhdlParserError.unsupportedPortType(typeToken) }

    var widthValue: Int32 = 1
    if isBitVector {
      guard scanner.next(Self.rangePattern) else { throw VhdlParserError.illegalPortSyntax }
      // `Integer.parseInt`, not `Int(_:)`. Three things differ and all three are observable:
      // Java is 32-bit, so `std_logic_vector(3000000000 downto 0)` is a `NumberFormatException`
      // and not a very wide bus; Java *throws* on anything it cannot parse where `?? 0` would
      // silently substitute zero and yield a plausible width; and the subtraction below is
      // 32-bit and wraps. `javaParseInt32` is the kernel's exact-semantics parse (D13's rule
      // applies; the throw is what upstream surfaces, see below).
      let upperText = scanner.group(1) ?? ""
      let lowerText = scanner.group(2) ?? ""
      guard let upper = javaParseInt32(upperText).map(Int32.init) else {
        throw VhdlParserError.numberFormat(upperText)
      }
      guard let lower = javaParseInt32(lowerText).map(Int32.init) else {
        throw VhdlParserError.numberFormat(lowerText)
      }
      // Java: `width = upper - lower + 1` in 32-bit `int`. `(2147483647 downto 0)` therefore
      // wraps to `Integer.MIN_VALUE` and is rejected by `BitWidth.create`, rather than being a
      // 2-billion-bit bus. `&-`/`&+` reproduce the wrap instead of trapping (D13).
      widthValue = upper &- lower &+ 1
    }
    let width = try BitWidth.create(Int(widthValue))

    for name in splitNames(names) {
      let port = VhdlPortDescription(name: name, direction: direction, width: width)
      // Bug-for-bug (see file header): only a direction that parsed as exactly `.input`
      // goes into `inputs`; both `.output` *and* `.inout_` land in `outputs`, matching
      // Java's `if (ptype.equals(Port.INPUT)) inputs.add(...) else outputs.add(...)`.
      if direction == .input {
        inputs.append(port)
      } else {
        outputs.append(port)
      }
    }
  }

  // MARK: Generics

  /// `VhdlParser.parseGenerics`. `generic ( decl ; decl ; ... ) ;`
  private func parseGenerics(_ scanner: VhdlScanner) throws -> Bool {
    guard scanner.next(Self.genericsPattern) else { return false }
    guard scanner.next(Self.openListPattern) else { throw VhdlParserError.illegalGenericSyntax }
    try parseGeneric(scanner)
    while scanner.next(Self.semicolonPattern) { try parseGeneric(scanner) }
    // Unlike `parsePorts`, Java does not append " before <remaining>" to this failure.
    guard scanner.next(Self.doneListPattern) else { throw VhdlParserError.illegalGenericSyntax }
    return true
  }

  /// `VhdlParser.parseGeneric`. `name[, name...] : integer|natural|positive|time [:= value
  /// [unit]]`
  private func parseGeneric(_ scanner: VhdlScanner) throws {
    guard scanner.next(Self.genericPattern) else { throw VhdlParserError.illegalGenericSyntax }
    let names = javaTrim(scanner.group(1) ?? "")
    let rawType = javaTrim(scanner.group(2) ?? "")
    let type = rawType.lowercased()
    guard Self.supportedGenericTypes.contains(type) else {
      throw VhdlParserError.unsupportedGenericType(rawType)
    }

    var dval: Int32 = type == "positive" ? 1 : 0
    if scanner.next(Self.dvaluePattern) {
      let text = scanner.group(1) ?? ""
      guard let decoded = try? javaIntegerDecode(text) else {
        throw VhdlParserError.unrecognizedGenericDefault(text)
      }
      dval = decoded
      if (type == "natural" && dval < 0) || (type == "positive" && dval < 1) {
        throw VhdlParserError.unrecognizedGenericDefault(String(dval))
      }
    }

    // Bug-for-bug (see file header): this block runs whenever the generic's type is `time`,
    // regardless of whether a default value (and therefore a preceding `:=`) was present.
    if type == "time" {
      if scanner.next(Self.unitPattern) {
        let unit = scanner.group(1) ?? ""
        switch unit {
        case "fs":
          break  // femtoseconds is the base unit
        case "ps":
          dval = dval &* 1_000
        case "ns":
          dval = dval &* 1_000_000
        case "us":
          dval = dval &* 1_000_000_000
        default:
          throw VhdlParserError.unrecognizedTimeUnit(dval)
        }
      }
    }

    for name in splitNames(names) {
      generics.append(VhdlGenericDescription(name: name, type: type, defaultValue: dval))
    }
  }

  /// Java: `names.split("\\s*,\\s*")`.
  ///
  /// The capturing group this is applied to is already constrained by its own regex to
  /// `\w+(?:\s*,\s*\w+)*`, so no empty field is reachable and a plain comma split with
  /// per-token trimming would do. `String.split(String)`'s limit-0 rule, keep interior empty
  /// fields, drop trailing ones, is reproduced anyway, because "unreachable given the current
  /// regex" is exactly the kind of coupling that silently stops holding when a pattern is
  /// edited.
  private func splitNames(_ text: String) -> [String] {
    var fields = text.split(separator: ",", omittingEmptySubsequences: false).map { javaTrim($0) }
    while let last = fields.last, last.isEmpty { fields.removeLast() }
    return fields
  }
}

// MARK: - Integer.decode

/// `Integer.decode(String)`, as used by `VhdlParser.parseGeneric` to read a generic's default
/// value token. Not a mechanical port (there is no Swift/JDK source to transcribe) but a
/// reconstruction from `java.lang.Integer.decode`'s documented grammar: an optional sign,
/// then a radix prefix (`0x`/`0X`/`#` for hex, a leading extra `0` for octal, otherwise
/// decimal), then a `Long.parseLong`-equivalent parse of the remaining digits, narrowed to
/// `int` with the same out-of-range check `Integer.valueOf` performs.
///
/// In practice the only strings this ever sees are whatever `DVALUE`'s `(\w+)` capture group
/// can match, digits, letters and underscores, no leading `+`/`-`/`#`, so the sign and `#`
/// handling below is unreachable from this parser today but is kept for fidelity to what
/// `Integer.decode` actually does, and to be exercisable directly (bypassing the regex) by
/// callers of `javaIntegerDecode` in tests.
func javaIntegerDecode(_ raw: String) throws -> Int32 {
  var text = Substring(raw)
  guard !text.isEmpty else { throw VhdlParserError("For input string: \"\(raw)\"") }

  var negative = false
  if text.first == "-" {
    negative = true
    text = text.dropFirst()
  } else if text.first == "+" {
    text = text.dropFirst()
  }

  var radix = 10
  if text.hasPrefix("0x") || text.hasPrefix("0X") {
    radix = 16
    text = text.dropFirst(2)
  } else if text.hasPrefix("#") {
    radix = 16
    text = text.dropFirst(1)
  } else if text.hasPrefix("0") && text.count > 1 {
    radix = 8
    text = text.dropFirst(1)
  }

  guard !text.isEmpty, let magnitude = UInt64(text, radix: radix) else {
    throw VhdlParserError("For input string: \"\(raw)\"")
  }

  let limit = UInt64(Int32.max) + (negative ? 1 : 0)
  guard magnitude <= limit else { throw VhdlParserError("For input string: \"\(raw)\"") }

  let signedMagnitude = Int64(magnitude)
  let value = negative ? -signedMagnitude : signedMagnitude
  return Int32(value)
}
