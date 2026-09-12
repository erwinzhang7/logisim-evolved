// PlaTable.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.gates.PlaTable),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. That file is in turn adopted from the MIPS.jar library by Martin Dybdal
// <dybber@dybber.dk> and Anders Boesen Lindbo Larsen <abll@diku.dk>, developed for the computer
// architecture class at the Department of Computer Science, University of Copenhagen.
// This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── What this is ────────────────────────────────────────────────────────────────────────────
//
// The programmable-logic-array truth table: a list of rows, each an input pattern over
// {'0', '1', 'x'} and an output pattern over {'0', '1'}. `valueFor` returns the output of the
// **first** matching row and 0 when none matches: first-match-wins, not a priority encoder and
// not an error.
//
// It is also an attribute *value*: `Pla.ATTR_TABLE` serialises it with `toStandardString` and
// reads it back with `parse`, so this file is on the `.circ` round-trip path and its text format
// is byte-visible.
//
// ── Not ported ──────────────────────────────────────────────────────────────────────────────
//
//   * `EditorDialog`, `HeaderPanel`, `TablePanel`: ~460 lines of Swing (D9/M6).
//   * `parse(File)` / `save(File)`: reachable only from that dialog's import/export buttons.
//
// ── Bit order, which is the easiest thing here to get backwards ─────────────────────────────
//
// `inBits[0]` is the **least** significant bit, but the text form prints most-significant
// first. That is why `toStandardString` builds its string by inserting at the front and why the
// parser reverses the token before storing it. `matches` walks `inBits` in index order while
// shifting the input right, which is consistent with index 0 being the LSB.

import Foundation
import LogisimKernel

/// The parse failures `PlaTable`'s line parser raises; Java's `IOException` with a localised
/// message. D5's precedent drops the localisation; the structure is kept so a caller can report
/// something useful.
///
/// Note these are **not** propagated to the `.circ` loader: `parse(_ str:)` catches every one of
/// them per line and carries on, exactly as upstream does (upstream pops an `OptionPane` and
/// continues). See `parse(_:)`.
public enum PlaTableParseError: Error, Equatable, CustomStringConvertible, Sendable {
  /// `plaRowExactInBitError`; the row's input field is not `inSize` characters wide.
  case wrongInputWidth(line: String, expected: Int)
  /// `plaRowExactOutBitError`.
  case wrongOutputWidth(line: String, expected: Int)
  /// `plaInvalidInputBitError`; a character that is not `0`, `1` or `x`.
  case invalidInputBit(line: String, character: Character)
  /// `plaInvalidOutputBitError`.
  case invalidOutputBit(line: String, character: Character)

  public var description: String {
    switch self {
    case .wrongInputWidth(let line, let expected):
      return "PLA row '\(line)' must have exactly \(expected) input bits"
    case .wrongOutputWidth(let line, let expected):
      return "PLA row '\(line)' must have exactly \(expected) output bits"
    case .invalidInputBit(let line, let character):
      return "PLA row '\(line)' has an invalid input bit '\(character)'"
    case .invalidOutputBit(let line, let character):
      return "PLA row '\(line)' has an invalid output bit '\(character)'"
    }
  }
}

/// `com.cburch.logisim.std.gates.PlaTable`.
///
/// A reference type, as upstream: `Pla`'s attribute set hands out the live table and the editor
/// mutates it in place.
public final class PlaTable {

  /// `PlaTable.ONE` / `ZERO` / `DONTCARE`.
  static let one: Character = "1"
  static let zero: Character = "0"
  static let dontCare: Character = "x"

  private var storage: [Row] = []
  private var inputSize: Int
  private var outputSize: Int
  private var label: String = ""

  /// `PlaTable(int inSz, int outSz, String l)`.
  public init(_ inSz: Int, _ outSz: Int, _ l: String) {
    self.inputSize = inSz
    self.outputSize = outSz
    self.label = l
  }

  /// `PlaTable(PlaTable other)`: a deep copy, including the rows.
  public convenience init(_ other: PlaTable) {
    self.init(other.inputSize, other.outputSize, other.label)
    copyFrom(other)
  }

  /// `setLabel(String)`.
  public func setLabel(_ l: String) {
    label = l
  }

  /// `rows()`.
  public var rows: [Row] { storage }

  /// `copyFrom(PlaTable)`.
  ///
  /// Note this copies the sizes *and* the rows but deliberately not the label; upstream's
  /// callers set the label separately, from the component's `StdAttr.LABEL`.
  public func copyFrom(_ other: PlaTable) {
    storage.removeAll()
    inputSize = other.inputSize
    outputSize = other.outputSize
    for otherRow in other.storage {
      let r = addTableRow()
      r.copyFrom(otherRow)
    }
  }

  /// `resize(int, int)`.
  public func resize(_ newInSize: Int, _ newOutSize: Int) {
    inputSize = newInSize
    outputSize = newOutSize
    for r in storage { r.truncate(inputSize, outputSize) }
  }

  /// `inSize()`.
  public var inSize: Int { inputSize }

  /// `outSize()`.
  public var outSize: Int { outputSize }

  /// `setInSize(int)`.
  public func setInSize(_ sz: Int) {
    resize(sz, outputSize)
  }

  /// `setOutSize(int)`.
  public func setOutSize(_ sz: Int) {
    resize(inputSize, sz)
  }

  /// `addTableRow()`.
  @discardableResult
  public func addTableRow() -> Row {
    let r = Row(inputSize, outputSize)
    storage.append(r)
    return r
  }

  /// `deleteTableRow(Row)`: identity removal, matching `ArrayList.remove(Object)` on a class
  /// with no `equals` (D4).
  public func deleteTableRow(_ row: Row) {
    if let index = storage.firstIndex(where: { $0 === row }) {
      storage.remove(at: index)
    }
  }

  /// `toStandardString()`, which is also `toString()`. Every row followed by a newline,
  /// including the last, so an empty table serialises to the empty string.
  public var standardString: String {
    var ret = ""
    for r in storage {
      ret += r.standardString
      ret += "\n"
    }
    return ret
  }

  /// `valueFor(long)`; first match wins; no match is 0, not an error.
  public func valueFor(_ input: Int64) -> Int64 {
    for row in storage where row.matches(input) { return row.output }
    return 0
  }

  /// `commentFor(long)`.
  public func commentFor(_ input: Int64) -> String {
    for row in storage where row.matches(input) { return row.comment }
    return "n/a"
  }

  // MARK: - Row

  /// `PlaTable.Row`.
  public final class Row {
    /// Index 0 is the least significant bit. See the file header.
    public internal(set) var inBits: [Character]
    public internal(set) var outBits: [Character]
    /// The text after `#` on the row's line.
    public internal(set) var comment: String = ""

    /// `Row(int inSize, int outSize)`.
    public init(_ inSize: Int, _ outSize: Int) {
      inBits = [Character](repeating: PlaTable.zero, count: max(inSize, 0))
      outBits = [Character](repeating: PlaTable.zero, count: max(outSize, 0))
    }

    /// `copyFrom(Row)`.
    ///
    /// Bug-for-bug: Java uses `System.arraycopy(other.inBits, 0, inBits, 0, inBits.length)`,
    /// which copies `this.inBits.length` characters and therefore throws
    /// `IndexOutOfBoundsException` if the source row is *narrower* than this one. Every upstream
    /// caller creates the destination at the source's size first (`PlaTable.copyFrom` calls
    /// `addTableRow()` after assigning the sizes), so it cannot happen; the Swift form clamps
    /// instead of trapping, which is the same answer on every reachable input and D13-safe on the
    /// unreachable one.
    public func copyFrom(_ other: Row) {
      for i in 0..<min(inBits.count, other.inBits.count) { inBits[i] = other.inBits[i] }
      for i in 0..<min(outBits.count, other.outBits.count) { outBits[i] = other.outBits[i] }
      comment = other.comment
    }

    /// `changeInBit(int)`: the editor's click cycle `0 → 1 → x → 0`.
    @discardableResult
    public func changeInBit(_ i: Int) -> Character {
      if inBits[i] == PlaTable.zero {
        inBits[i] = PlaTable.one
      } else if inBits[i] == PlaTable.one {
        inBits[i] = PlaTable.dontCare
      } else {
        inBits[i] = PlaTable.zero
      }
      return inBits[i]
    }

    /// `changeOutBit(int)`; outputs have no don't-care, so this toggles.
    ///
    /// Note the missing `else`: a value that is neither `0` nor `1` (which the parser cannot
    /// produce, but `truncate` fills with `0`) is left alone and returned unchanged. Transcribed
    /// as written.
    @discardableResult
    public func changeOutBit(_ i: Int) -> Character {
      if outBits[i] == PlaTable.zero {
        outBits[i] = PlaTable.one
      } else if outBits[i] == PlaTable.one {
        outBits[i] = PlaTable.zero
      }
      return outBits[i]
    }

    /// `truncate(int, int)`.
    func truncate(_ newInSize: Int, _ newOutSize: Int) {
      inBits = Row.truncate(inBits, newInSize)
      outBits = Row.truncate(outBits, newOutSize)
    }

    /// `static char[] truncate(char[] b, int n)`; keeps the low `n` bits, zero-filling if the
    /// array grew.
    static func truncate(_ b: [Character], _ n: Int) -> [Character] {
      if b.count == n { return b }
      var a = [Character](repeating: PlaTable.zero, count: max(n, 0))
      for i in 0..<min(max(n, 0), b.count) { a[i] = b[i] }
      // Java's second loop (`for i = b.length; i < n; i++ a[i] = ZERO`) is redundant here
      // because the array is created zero-filled; it is redundant in Java too, since `new
      // char[n]` is `\0`-filled and the loop overwrites those with '0'. Ours starts at '0'.
      return a
    }

    /// `toStandardString()`, which is also `toString()`: inputs, a space, outputs, and, only
    /// when it is non-blank, ` # ` and the trimmed comment. Both fields print
    /// most-significant-bit first, which is the reverse of the array order.
    public var standardString: String {
      var i = ""
      for inBit in inBits { i = String(inBit) + i }
      var o = ""
      for outBit in outBits { o = String(outBit) + o }
      var ret = i + " " + o
      let trimmed = javaTrim(comment)
      if trimmed != "" { ret += " # " + trimmed }
      return ret
    }

    /// `matches(long input)`.
    ///
    /// `x` matches either way because it is neither `ONE` nor `ZERO`, so neither test fires.
    /// Java's `>>` is arithmetic and so is Swift's on `Int64`; the two agree, including for the
    /// negative input a 64-bit-wide PLA can produce.
    func matches(_ input: Int64) -> Bool {
      var input = input
      for bit in inBits {
        let b = input & 1
        if (bit == PlaTable.one && b != 1) || (bit == PlaTable.zero && b != 0) { return false }
        input = input >> 1
      }
      return true
    }

    /// `getOutput()`.
    var output: Int64 {
      var out: Int64 = 0
      var bit: Int64 = 1
      for c in outBits {
        if c == PlaTable.one { out |= bit }
        // Java's `<<` masks the distance by 63 and wraps; Swift's `<<` on a fixed-width integer
        // is likewise a pure bit shift and does not trap. At index 63 `bit` becomes `Int64.min`
        // and the next shift is 0 in both languages.
        bit = bit << 1
      }
      return out
    }
  }

  // MARK: - Parsing

  /// `PlaTable.Parser`; the abstract base of the two line grammars. Kept as a class hierarchy
  /// rather than flattened, because `parse` is shared and only the three hooks differ.
  class Parser {

    /// `comment(String)`: everything after the first `#`, trimmed; `""` when there is none.
    fileprivate func comment(_ line: String) -> String {
      guard let hash = line.firstIndex(of: "#") else { return "" }
      return javaTrim(line[line.index(after: hash)...])
    }

    /// `inputsOutputs(String)`: everything before the first `#`, trimmed. Note the *no-hash*
    /// branch returns the line **untrimmed**, which is upstream's asymmetry and is why every
    /// caller trims again.
    func inputsOutputs(_ line: String) -> String {
      guard let hash = line.firstIndex(of: "#") else { return line }
      return javaTrim(line[line.startIndex..<hash])
    }

    /// `toLogicArray(String, String errorKey)`, reverse, then validate.
    fileprivate static func toLogicArray(
      _ line: String, _ fullLine: String, isInput: Bool
    ) throws -> [Character] {
      // "java char indices and IO indices are in opposite order i.e. str[0] is IO[n] etc"
      let arr = Array(line).reversed().map { $0 }
      for ch in arr where ch != one && ch != zero && ch != dontCare {
        throw isInput
          ? PlaTableParseError.invalidInputBit(line: fullLine, character: ch)
          : PlaTableParseError.invalidOutputBit(line: fullLine, character: ch)
      }
      return arr
    }

    /// `parse(PlaTable tt, String line)`.
    ///
    /// **Upstream behaviour worth knowing:** the row is appended *before* the bit fields are
    /// validated, so a line with a bad character leaves a half-populated all-zero row behind;
    /// `PlaTable.parse(String)` swallows the error and moves on. Preserved.
    /// Returns an optional because Java's does: the comment-line branch returns `tt` unchanged,
    /// which is still `null` on the first line of a file whose first line is a comment.
    func parse(_ tt: PlaTable?, _ line: String) throws -> PlaTable? {
      let andBits = inputs(line)
      let orBits = outputs(line)
      let isCommentLine = andBits.isEmpty && orBits.isEmpty

      var tt = tt
      if isCommentLine {
        return tt
      }

      if tt == nil {
        tt = PlaTable(andBits.count, orBits.count, "PLA")
      } else if andBits.count != tt!.inputSize {
        throw PlaTableParseError.wrongInputWidth(line: line, expected: tt!.inputSize)
      } else if orBits.count != tt!.outputSize {
        throw PlaTableParseError.wrongOutputWidth(line: line, expected: tt!.outputSize)
      }

      let r = tt!.addTableRow()
      r.inBits = try Parser.toLogicArray(andBits, line, isInput: true)
      r.outBits = try Parser.toLogicArray(orBits, line, isInput: false)
      r.comment = comment(line)
      return tt!
    }

    /// Java declares these three `abstract`, so the compiler makes them uncallable. Swift has no
    /// equivalent and no `.circ` file can reach them; only the two subclasses below are ever
    /// instantiated. D13's "genuine programmer error" carve-out: trap.
    func inputs(_ line: String) -> String {
      fatalError("PlaTable.Parser subclasses must override `inputs`")
    }

    func outputs(_ line: String) -> String {
      fatalError("PlaTable.Parser subclasses must override `outputs`")
    }

    func canParse(_ line: String) -> Bool {
      fatalError("PlaTable.Parser subclasses must override `canParse`")
    }
  }

  /// `PlaTable.CompactParser`: `010x 11 # comment`, one space between the two fields.
  final class CompactParser: Parser {
    override func inputs(_ line: String) -> String {
      let io = inputsOutputs(line)
      guard let space = io.firstIndex(of: " ") else { return "" }
      return javaTrim(io[io.startIndex..<space])
    }

    override func outputs(_ line: String) -> String {
      let io = inputsOutputs(line)
      guard let space = io.firstIndex(of: " ") else { return "" }
      return javaTrim(io[io.index(after: space)...])
    }

    /// `io.matches("[01x]+\\s+[01]+")`.
    ///
    /// **Deviation (mechanism), unobservable.** Java's `\s` is exactly
    /// `[ \t\n\f\r]`; ICU's would additionally match Unicode separators, so the class is
    /// spelled out to keep the two grammars identical on every input.
    override func canParse(_ line: String) -> Bool {
      let io = inputsOutputs(line)
      return PlaTable.matchesWholly(io, pattern: "[01x]+[ \\t\\n\\x0B\\f\\r]+[01]+")
    }
  }

  /// `PlaTable.FlexibleParser`: `0 1 0 x || 1 1 # comment`, with `|` and whitespace ignored
  /// inside each field.
  final class FlexibleParser: Parser {
    /// `stripSeparators(String)`: `line.replaceAll("[|\\s]", "").trim()`. Same `\s` note as
    /// `CompactParser.canParse`.
    private static func stripSeparators(_ line: some StringProtocol) -> String {
      let dropped: Set<Character> = ["|", " ", "\t", "\n", "\u{0B}", "\u{0C}", "\r"]
      return javaTrim(String(line.filter { !dropped.contains($0) }))
    }

    override func inputs(_ line: String) -> String {
      let io = inputsOutputs(line)
      guard let bar = io.range(of: "||") else { return "" }
      return FlexibleParser.stripSeparators(io[io.startIndex..<bar.lowerBound])
    }

    /// Note Java takes `substring(separatorIndex + 1)`, i.e. it skips only **one** of the two
    /// bars; the leftover `|` is then removed by `stripSeparators`. Reproduced by slicing from
    /// one past the `||` match's start.
    override func outputs(_ line: String) -> String {
      let io = inputsOutputs(line)
      guard let bar = io.range(of: "||") else { return "" }
      return FlexibleParser.stripSeparators(io[io.index(after: bar.lowerBound)...])
    }

    override func canParse(_ line: String) -> Bool {
      inputsOutputs(line).contains("||")
    }
  }

  /// `PlaTable.parsers`: tried in order, first one that claims the line wins.
  private static let parsers: [Parser] = [CompactParser(), FlexibleParser()]

  /// `parseOneLine(PlaTable, String)`. A line no parser claims is returned unchanged, which is
  /// how comment-only and blank lines are skipped.
  private static func parseOneLine(_ tt: PlaTable?, _ line: String) throws -> PlaTable? {
    for parser in parsers where parser.canParse(line) {
      return try parser.parse(tt, line)
    }
    return tt
  }

  /// `parse(String)`; the `Attribute.parse` side of `Pla.ATTR_TABLE`.
  ///
  /// **This deliberately does not throw**, which is not a D13 exemption but a transcription:
  /// upstream catches every per-line `IOException` itself, reports it through `OptionPane` and
  /// keeps parsing the remaining lines. Making the Swift throw would *change* behaviour; a
  /// `.circ` with one malformed PLA row would stop loading instead of loading with that row
  /// dropped. D17's headless rule turns the dialog into a log line; there is no logger wired
  /// into `LogisimStd`, so the error is dropped on the floor exactly as a headless run drops it.
  public static func parse(_ str: String) -> PlaTable {
    var tt: PlaTable? = nil
    for line in str.components(separatedBy: "\n") {
      do {
        tt = try parseOneLine(tt, line)
      } catch {
        // OptionPane.showMessageDialog(null, e.getMessage(), S.get("plaTableError"), ERROR)
      }
    }
    return tt ?? PlaTable(2, 2, "PLA")
  }

  /// `String.matches(regex)`: a *whole-string* match, unlike `find`.
  private static func matchesWholly(_ text: String, pattern: String) -> Bool {
    guard let range = text.range(of: pattern, options: [.regularExpression]) else { return false }
    return range.lowerBound == text.startIndex && range.upperBound == text.endIndex
  }

  // NOT PORTED: parse(File) / save(File): reachable only from `EditorDialog`'s import/export
  //             buttons, and they carry `Loader`/`JFileChoosers` with them (D9/M6).
  // PAINT (M6): EditorDialog, HeaderPanel, TablePanel: the whole click-to-edit UI.
  //             See PlaTable.java:405-869.
}
