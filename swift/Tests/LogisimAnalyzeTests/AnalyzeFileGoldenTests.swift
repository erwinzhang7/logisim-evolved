// AnalyzeFileGoldenTests: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// Differential tests for the analyze *file and data* layer: the `.txt`, `.csv` and `.tex`
// codecs, the CSV header grammar, the K-map placement and cover geometry, and the two
// borrowed helpers (`VariableTab.checkindex`, `util.SyntaxChecker`).
//
// Every expectation lives in `AnalyzeFileGoldenData.swift` and was captured from the SHIPPED
// 4.1.0 jar (D16), not reasoned out here: see that file's header for the probe and how to
// re-run it. The four places where this port deliberately differs from upstream are each
// tested *as divergences*, with the Java behaviour named, rather than quietly omitted.

import Foundation
import Testing

@testable import LogisimAnalyze

// MARK: - Shared helpers

/// Builds a model from the probe's spec strings: comma-separated `name` or `name/width`.
private func model(inputs: String, outputs: String, bits: String) throws -> AnalyzerModel {
  func vars(_ spec: String) -> [Var] {
    spec.split(separator: ",").map { field in
      let parts = field.split(separator: "/")
      return parts.count == 1
        ? Var(String(parts[0]), 1)
        : Var(String(parts[0]), Int(parts[1])!)
    }
  }
  let m = AnalyzerModel()
  try m.setVariables(inputs: vars(inputs), outputs: vars(outputs))
  let table = m.truthTable
  let characters = Array(bits)
  var k = 0
  for column in 0..<table.outputColumnCount {
    var values: [Entry] = []
    for _ in 0..<table.rowCount {
      let c = characters[k % characters.count]
      k += 1
      values.append(c == "1" ? .one : c == "0" ? .zero : .dontCare)
    }
    try table.setOutputColumn(column, values)
  }
  return m
}

/// The probe's `dump(AnalyzerModel)`, reproduced exactly so the two strings are comparable.
private func dump(_ m: AnalyzerModel) -> String {
  var out = "in="
  for v in m.inputs.vars { out += "\(v.name)/\(v.width)," }
  out += " out="
  for v in m.outputs.vars { out += "\(v.name)/\(v.width)," }
  let t = m.truthTable
  out += " rows=\(t.visibleRowCount) "
  for row in 0..<t.visibleRowCount {
    for col in 0..<t.inputColumnCount {
      out += t.visibleInputEntry(row: row, column: col).description()
    }
    out += ":"
    for col in 0..<t.outputColumnCount {
      out += t.visibleOutputEntry(row: row, column: col).description()
    }
    out += " "
  }
  while out.hasSuffix(" ") { out.removeLast() }
  return out
}

// MARK: - VariableTab.checkindex

@Test func bitRangeParseMatchesTheJavaOracle() {
  for c in AnalyzeFileGolden.checkIndex {
    #expect(
      BitRangeParse.checkIndex(c.input) == c.result,
      "checkindex(\(c.input)) — expected \(c.result), got \(BitRangeParse.checkIndex(c.input))")
  }
}

/// DIVERGENCE (D13). `checkindex` parses its indices with `Integer.parseInt` and does not
/// catch `NumberFormatException`, so a header field such as `B[99999999999..0]`, ordinary
/// user input, straight out of a CSV, throws out of a method whose entire contract is to
/// return a negative code. A Swift trap there would kill the process, so the port returns the
/// failure code the method was plainly reaching for instead.
@Test func bitRangeParseReturnsWhereUpstreamThrows() {
  for c in AnalyzeFileGolden.checkIndexThrowsUpstream {
    #expect(BitRangeParse.checkIndex(c.input) == c.portResult)
  }
}

// MARK: - util.SyntaxChecker

/// The keyword rows in the golden data need `hdlKeywordCheck`, which is a seam in this module
/// (`LogisimAnalyze` does not depend on `LogisimHdl`: see `AnalyzeSyntaxChecker`'s note). The
/// stub covers exactly the keywords the golden cases use, so the rest of the rules are
/// measured against the jar with the seam closed.
private let hdlKeywordStub: (String) -> String? = { name in
  let vhdl: Set<String> = ["in", "out", "entity", "signal", "begin"]
  let verilog: Set<String> = ["module", "wire", "reg", "always"]
  if vhdl.contains(name.lowercased()) { return "VHDL" }
  if verilog.contains(name.lowercased()) { return "Verilog" }
  return nil
}

/// Both halves of this, with the seam installed and without, are one test on purpose.
/// `hdlKeywordCheck` is process-global mutable state, and swift-testing runs `@Test`s in
/// parallel, so two tests that each set it would race each other rather than measure the port.
@Test func syntaxCheckerMatchesTheJavaOracle() {
  func rendered(_ name: String) -> String {
    AnalyzeSyntaxChecker.errorMessageKeys(name)
      .map { AnalyzeStrings.message($0.key, $0.args) }.joined()
  }

  AnalyzeSyntaxChecker.hdlKeywordCheck = hdlKeywordStub
  for c in AnalyzeFileGolden.syntaxErrors {
    let text = rendered(c.name)
    let actual: String? = text.isEmpty ? nil : text
    #expect(actual == c.message, "getErrorMessage(\(c.name))")
    #expect(AnalyzeSyntaxChecker.isVariableNameAcceptable(c.name) == (c.message == nil))
  }

  // With the seam left unset the port is strictly more permissive than upstream, and only
  // there: a VHDL/Verilog keyword is accepted, every other rule still matches. That is stated
  // in `AnalyzeSyntaxChecker`'s documentation as a known divergence, so it is pinned rather
  // than left to be discovered.
  AnalyzeSyntaxChecker.hdlKeywordCheck = nil
  for c in AnalyzeFileGolden.syntaxErrors {
    let expectedWithoutKeyword =
      (c.message ?? "")
      .replacingOccurrences(of: AnalyzeStrings.message("variableVHDLKeyword"), with: "")
      .replacingOccurrences(of: AnalyzeStrings.message("variableVerilogKeyword"), with: "")
    #expect(rendered(c.name) == expectedWithoutKeyword, "\(c.name) without the seam")
  }
}

// MARK: - CsvInterpretor.parseCsvLine

@Test func csvLineSplittingMatchesTheJavaOracle() {
  for c in AnalyzeFileGolden.csvLines {
    let fields = CsvInterpretor.parseCsvLine(c.line, separator: ",", quote: "\"")
    #expect(fields.count == c.fields.count, "field count for \(c.line)")
    if fields.count == c.fields.count {
      for (i, expected) in c.fields.enumerated() {
        #expect(fields[i] == expected, "field \(i) of \(c.line)")
      }
    }
  }
}

// MARK: - KarnaughMapPanel geometry

@Test func karnaughPlacementMatchesTheJavaOracle() {
  for c in AnalyzeFileGolden.kmapPlacement {
    #expect(1 << KarnaughMapGeometry.rowVars[c.inputs] == c.rows)
    #expect(1 << KarnaughMapGeometry.colVars[c.inputs] == c.cols)
    for (tableRow, cell) in c.cells.enumerated() {
      #expect(
        KarnaughMapGeometry.row(tableRow: tableRow, rows: c.rows, cols: c.cols) == cell.row,
        "row of \(tableRow) with \(c.inputs) inputs")
      #expect(
        KarnaughMapGeometry.col(tableRow: tableRow, rows: c.rows, cols: c.cols) == cell.col,
        "col of \(tableRow) with \(c.inputs) inputs")
    }
  }
}

/// Every K-map cell is used exactly once; the property the Gray-code permutation exists to
/// guarantee, and the one a transcription slip in `bigColPlace` would break while still
/// matching most individual rows.
@Test func karnaughPlacementIsABijection() {
  for c in AnalyzeFileGolden.kmapPlacement {
    var seen = Set<Int>()
    for tableRow in 0..<(c.rows * c.cols) {
      let r = KarnaughMapGeometry.row(tableRow: tableRow, rows: c.rows, cols: c.cols)
      let k = KarnaughMapGeometry.col(tableRow: tableRow, rows: c.rows, cols: c.cols)
      #expect(seen.insert(r * c.cols + k).inserted, "cell (\(r),\(k)) used twice")
    }
    #expect(seen.count == c.rows * c.cols)
  }
}

// MARK: - CoverColor

@Test func coverPaletteMatchesTheJavaOracle() {
  #expect(CoverColor.defaultRGB.count == AnalyzeFileGolden.coverPalette.count)
  for (index, expected) in AnalyzeFileGolden.coverPalette.enumerated() {
    #expect(CoverColor.colorName(index: index) == expected.name)
    let rgb = CoverColor.rgb(index: index)
    #expect(rgb?.red == expected.red)
    #expect(rgb?.green == expected.green)
    #expect(rgb?.blue == expected.blue)
  }
  // Out of range is `null` upstream, which the .tex writer prints as the literal text.
  #expect(CoverColor.colorName(index: -1) == nil)
  #expect(CoverColor.colorName(index: 16) == nil)
  #expect(CoverColor.rgb(index: 16) == nil)
}

@Test func coverColorRotationWrapsAtSixteen() {
  let rotation = CoverColor()
  var seen: [String] = []
  for _ in 0..<AnalyzeFileGolden.coverRotation.count {
    seen.append(CoverColor.colorName(index: rotation.next()) ?? "null")
  }
  #expect(seen == AnalyzeFileGolden.coverRotation)
  rotation.reset()
  #expect(CoverColor.colorName(index: rotation.next()) == AnalyzeFileGolden.coverRotation[0])
}

// MARK: - TruthtableTextFile

@Test func textFileExportMatchesTheJavaOracle() throws {
  for c in AnalyzeFileGolden.textSave {
    let m = try model(inputs: c.inputs, outputs: c.outputs, bits: c.bits)
    let text = TruthtableTextFile.text(for: m, exportDate: "IGNORED")
    // Strip the one non-reproducible line, exactly as the probe does.
    let body = text.split(separator: "\n", omittingEmptySubsequences: false)
      .filter { !$0.hasPrefix("# Exported on ") }
      .joined(separator: "\n")
    #expect(
      body == AnalyzeFileGolden.textFilePreamble + c.body,
      "txt export of \(c.inputs) / \(c.outputs)")
  }
}

/// The stripped line, checked on its own so the preamble is still covered end to end.
@Test func textFileExportDatesTheDocument() throws {
  let m = try model(inputs: "a", outputs: "q", bits: "01")
  let text = TruthtableTextFile.text(for: m, exportDate: "Fri Jan 02 03:04:05 UTC 2026")
  #expect(text.contains("\n# Exported on Fri Jan 02 03:04:05 UTC 2026\n"))
  // Java omits `tableRemark2` entirely when there is no circuit, rather than printing an
  // empty name.
  #expect(!text.contains("# Generated from circuit"))
  let named = TruthtableTextFile.text(for: m, circuitName: "main", exportDate: "D")
  #expect(named.contains("# Truth table\n# Generated from circuit main\n# Exported on D\n"))
}

@Test func textFileImportMatchesTheJavaOracle() throws {
  for c in AnalyzeFileGolden.textLoad {
    let m = AnalyzerModel()
    do {
      try TruthtableTextFile.load(c.source, into: m)
      #expect(c.error == nil, "expected \(c.error ?? "") for \(c.source)")
      if let expected = c.dump { #expect(dump(m) == expected, "load of \(c.source)") }
    } catch let error as TruthtableTextError {
      #expect(c.dump == nil, "unexpected \(error) for \(c.source)")
      #expect(error.description == c.error, "message for \(c.source)")
    }
  }
}

/// The rows-do-not-partition path. Upstream asks "Ignore errors and try again?" and retries
/// with `force` on Yes; headless it answers CANCEL and returns with the variables installed
/// but a default table. Both answers are reachable here, and the golden data above pins the
/// declining one.
@Test func textFileImportRetriesWhenTheCallerAgrees() throws {
  // Missing rows: `10` and `11` are never mentioned. Declining leaves the default table.
  let incomplete = "a b | q\n0 0 | 0\n0 1 | 1\n"
  let declined = AnalyzerModel()
  try TruthtableTextFile.load(incomplete, into: declined)
  #expect(dump(declined) == "in=a/1,b/1, out=q/1, rows=4 00:- 01:- 10:- 11:-")

  var asked: AnalyzeError?
  let forced = AnalyzerModel()
  try TruthtableTextFile.load(incomplete, into: forced) { error in
    asked = error
    return true
  }
  #expect(asked != nil, "the caller should have been consulted")
  // `TruthTable.java:466` fills each uncovered row with a fresh default row rather than
  // rejecting, so the two stated rows land and the rest stay don't-care.
  #expect(dump(forced) == "in=a/1,b/1, out=q/1, rows=4 00:0 01:1 10:- 11:-")
}

/// Agreeing does *not* rescue every failure: `TruthTable.java:452` still refuses genuinely
/// duplicated rows even under `force`, with a message that says so ("Sorry, this error can't
/// yet be fixed"). The retry therefore has to be able to throw, which is why `load` is
/// `throws` on both paths rather than swallowing the second attempt.
@Test func textFileImportStillFailsOnDuplicateRowsEvenWhenForced() {
  let duplicated = "a b | q\n0 0 | 0\n0 1 | 1\n1 0 | 1\n1 1 | 0\n1 1 | 1\n"
  #expect(throws: AnalyzeError.self) {
    try TruthtableTextFile.load(duplicated, into: AnalyzerModel()) { _ in true }
  }
}

/// Round trip: everything `doSave` writes, `doLoad` reads back to the same visible rows.
@Test func textFileRoundTripsItsOwnOutput() throws {
  for c in AnalyzeFileGolden.textSave {
    let source = try model(inputs: c.inputs, outputs: c.outputs, bits: c.bits)
    // A model with no outputs has nothing to round-trip through a format that requires them.
    guard !source.outputs.vars.isEmpty else { continue }
    let text = TruthtableTextFile.text(for: source, exportDate: "D")
    let reloaded = AnalyzerModel()
    try TruthtableTextFile.load(text, into: reloaded)
    #expect(dump(reloaded) == dump(source), "round trip of \(c.inputs) / \(c.outputs)")
  }
}

// MARK: - TruthtableCsvFile

@Test func csvExportMatchesTheJavaOracle() throws {
  for c in AnalyzeFileGolden.csvSave {
    let m = try model(inputs: c.inputs, outputs: c.outputs, bits: c.bits)
    #expect(
      TruthtableCsvFile.text(for: m) == c.csv, "csv export of \(c.inputs) / \(c.outputs)")
  }
}

/// Java returns without creating the file when either list is empty. `nil` says that; an
/// empty `String` would have said "wrote an empty file", which is a different thing.
@Test func csvExportRefusesAnEmptyVariableList() throws {
  let m = AnalyzerModel()
  try m.setVariables(inputs: [Var("a", 1)], outputs: [])
  #expect(TruthtableCsvFile.text(for: m) == nil)
  let n = AnalyzerModel()
  try n.setVariables(inputs: [], outputs: [Var("q", 1)])
  #expect(TruthtableCsvFile.text(for: n) == nil)
}

// MARK: - CsvInterpretor

@Test func csvImportMatchesTheJavaOracle() throws {
  var rejectMessages: [String] = []
  for c in AnalyzeFileGolden.csvLoad {
    let m = AnalyzerModel()
    do {
      let interpretor = try CsvInterpretor(
        fileContents: c.source, parameter: .standard, fileName: "FILE")
      try interpretor.applyTruthTable(to: m)
      #expect(c.dump != nil, "expected a rejection for \(c.source)")
      if let expected = c.dump { #expect(dump(m) == expected, "csv load of \(c.source)") }
    } catch let error as CsvImportError {
      #expect(c.dump == nil, "unexpected \(error) for \(c.source)")
      // The rows where upstream threw instead of reporting have no logged message to line up
      // against; they are covered by their own divergence test below.
      if c.javaException == nil { rejectMessages.append(error.message) }
      // Rejecting must leave the model exactly as it was; upstream's guarantee is that a
      // bad CSV never half-applies.
      #expect(dump(m) == "in= out= rows=1 :")
    }
  }
  #expect(rejectMessages == AnalyzeFileGolden.csvLoadRejectMessages)
}

/// DIVERGENCE (D13). `getInputsOutputs` reads `sels.get(bitIndex + 1)` to check that the
/// next-most-significant bit is already present, which is out of bounds whenever `bitIndex`
/// is the highest index seen so far: a header as ordinary as `"D:3","D:3"` reaches it, and
/// upstream throws `IndexOutOfBoundsException` out of a method whose contract is to return
/// false. The port folds it into the bit-order error it was reaching for.
@Test func csvImportReportsWhereUpstreamThrowsOutOfBounds() {
  let source = "\"D:3\",\"D:3\",\"|\",\"q\"\n0,0,\"|\",0\n"
  #expect(AnalyzeFileGolden.csvLoad.contains { $0.source == source && $0.javaException != nil })
  #expect(throws: CsvImportError.self) {
    _ = try CsvInterpretor(fileContents: source, parameter: .standard, fileName: "FILE")
  }
  do {
    _ = try CsvInterpretor(fileContents: source, parameter: .standard, fileName: "FILE")
  } catch let error as CsvImportError {
    #expect(error.messageKey == "CsvIncorrectBitOrder")
  } catch {
    Issue.record("wrong error type")
  }
}

/// Upstream's `CsvReadParameterDialog` sets `valid` only when the user confirms; cancelling
/// leaves it false and `doLoad` returns without touching the model.
@Test func csvImportHonoursAnInvalidParameter() throws {
  var parameter = CsvParameter.standard
  parameter.isValid = false
  let m = AnalyzerModel()
  let url = URL(fileURLWithPath: "/nonexistent/never-opened.csv")
  try TruthtableCsvFile.load(contentsOf: url, into: m, parameter: parameter)
  #expect(dump(m) == "in= out= rows=1 :")
}

/// Round trip: `TruthtableCsvFile.doSave` writes the wide-variable header form, which
/// `CsvInterpretor` must accept. Note the export compacts rows first, so the comparison is
/// against the *compacted* source.
@Test func csvRoundTripsItsOwnOutput() throws {
  for c in AnalyzeFileGolden.csvSave {
    let source = try model(inputs: c.inputs, outputs: c.outputs, bits: c.bits)
    let text = TruthtableCsvFile.text(for: source)
    let expected = dump(source)  // text(for:) has already compacted it
    let reloaded = AnalyzerModel()
    let interpretor = try CsvInterpretor(
      fileContents: text!, parameter: .standard, fileName: "FILE")
    try interpretor.applyTruthTable(to: reloaded)
    #expect(dump(reloaded) == expected, "round trip of \(c.inputs) / \(c.outputs)")
  }
}

// MARK: - KarnaughMapGroups

@Test func karnaughCoversMatchTheJavaOracle() throws {
  for c in AnalyzeFileGolden.covers {
    let m = try model(inputs: c.inputs, outputs: c.outputs, bits: c.bits)
    let groups = KarnaughMapGroups(model: m)
    groups.setOutput(c.output)
    #expect(groups.covers.count == c.count, "cover count for \(c.bits)")
    var rendered = ""
    for group in groups.covers {
      rendered += "[" + (CoverColor.colorName(index: group.colorIndex) ?? "null") + ":"
      for area in group.areas {
        rendered += "(\(area.col),\(area.row),\(area.width),\(area.height))"
      }
      rendered += "]"
    }
    #expect(rendered == c.groups, "covers for \(c.inputs) \(c.bits)")
  }
}

/// Hit-testing: exactly one group claims each cell that is covered at all, because
/// `addSingleCover` steals a shared minterm from whichever earlier group already had it.
@Test func karnaughHighlightPicksExactlyOneGroup() throws {
  for c in AnalyzeFileGolden.covers where c.count > 0 {
    let m = try model(inputs: c.inputs, outputs: c.outputs, bits: c.bits)
    let inputCount = m.truthTable.inputColumnCount
    guard inputCount <= KarnaughMapGeometry.maxVars else { continue }
    let groups = KarnaughMapGroups(model: m)
    groups.setOutput(c.output)
    let rows = 1 << KarnaughMapGeometry.rowVars[inputCount]
    let cols = 1 << KarnaughMapGeometry.colVars[inputCount]
    var claimed = 0
    for row in 0..<rows {
      for col in 0..<cols where groups.highlight(col: col, row: row) || groups.highlighted >= 0 {
        if groups.highlighted >= 0 {
          claimed += 1
          #expect(groups.highlightedExpression != nil)
          #expect(groups.highlightedColorIndex == groups.covers[groups.highlighted].colorIndex)
        }
      }
    }
    // Every minterm covered by the solution is claimed by exactly one group, so the count of
    // claimed cells is the count of solely-covered implicants.
    let solelyCovered = groups.covers.reduce(0) { $0 + $1.singleCoveredImplicants.count }
    #expect(claimed == solelyCovered, "hit-test coverage for \(c.bits)")
    #expect(groups.clearHighlight() == (groups.highlighted >= 0) || groups.highlighted == -1)
    #expect(groups.highlighted == -1)
  }
}

/// Java leaves `covers` null until the first `setOutput`/`setformat`, and would NPE if
/// anything iterated it. An empty array reaches the same output without the crash.
@Test func karnaughGroupsStartEmptyRatherThanNull() throws {
  let m = try model(inputs: "a,b", outputs: "q", bits: "0110")
  let groups = KarnaughMapGroups(model: m)
  #expect(groups.covers.isEmpty)
  #expect(groups.highlighted == -1)
  #expect(groups.highlightedExpression == nil)
  #expect(groups.highlightedColorIndex == nil)
  #expect(groups.highlight(col: 0, row: 0) == false)
}

// MARK: - AnalyzerTexWriter

@Test func texExportMatchesTheJavaOracle() throws {
  for c in AnalyzeFileGolden.tex {
    let m = try model(inputs: c.inputs, outputs: c.outputs, bits: c.bits)
    let text = AnalyzerTexWriter.text(for: m, exportDate: "IGNORED")
    let stripped = text.split(separator: "\n", omittingEmptySubsequences: false)
      .filter { !$0.hasPrefix("\\fancyhead[C] {") }
      .joined(separator: "\n")
    #expect(stripped == c.document, "tex export of \(c.inputs) / \(c.outputs)")
  }
}

@Test func texExportDatesTheDocument() throws {
  let m = try model(inputs: "a,b", outputs: "q", bits: "0110")
  let text = AnalyzerTexWriter.text(for: m, exportDate: "Fri Jan 02 03:04:05 UTC 2026")
  #expect(
    text.contains(
      "\\fancyhead[C] {Logisim-evolution generated this document on "
        + "Fri Jan 02 03:04:05 UTC 2026}"))
}

/// `AppPreferences.KMAP_LINED_STYLE` is a preference, so D9 makes it an argument. The golden
/// documents are the default (`false`, numbered); `true` drops `disable bars,` and the whole
/// hand-drawn axis header with it.
@Test func texExportHonoursTheLinedStyle() throws {
  let m = try model(inputs: "a,b", outputs: "q", bits: "0110")
  let numbered = AnalyzerTexWriter.text(for: m, lined: false, exportDate: "D")
  let lined = AnalyzerTexWriter.text(for: m, lined: true, exportDate: "D")
  #expect(numbered.contains("[karnaugh,disable bars,x=1\\kmunitlength"))
  #expect(lined.contains("[karnaugh,x=1\\kmunitlength"))
  #expect(numbered.contains("\\draw[kmbox]"))
  #expect(!lined.contains("\\draw[kmbox]"))
  // The covers are still emitted in lined style; only the axis header goes away.
  #expect(lined.contains("\\node[grp={LogisimKMapColor0}"))
}

/// The palette is an argument too, and it is the only thing that decides the `\definecolor`
/// preamble; a host with live preferences passes its own.
@Test func texExportUsesTheSuppliedPalette() throws {
  let m = try model(inputs: "a,b", outputs: "q", bits: "0110")
  let text = AnalyzerTexWriter.text(
    for: m, palette: [0x01_02_03, 0xFF_00_80], exportDate: "D")
  #expect(text.contains("\\definecolor{LogisimKMapColor0}{RGB}{1,2,3}\n"))
  #expect(text.contains("\\definecolor{LogisimKMapColor1}{RGB}{255,0,128}\n"))
  #expect(!text.contains("LogisimKMapColor2"))
}

/// `DecimalFormat` in `Locale.ENGLISH`: three fraction digits, no trailing zeros, `.` for the
/// point. What matters for the `.tex` bytes is that a whole number loses its `.0`.
@Test func texDecimalFormatMatchesJava() {
  #expect(AnalyzerTexWriter.decimalFormat(4.0) == "4")
  #expect(AnalyzerTexWriter.decimalFormat(-0.5) == "-0.5")
  #expect(AnalyzerTexWriter.decimalFormat(2.7) == "2.7")
  #expect(AnalyzerTexWriter.decimalFormat(0.8) == "0.8")
  #expect(AnalyzerTexWriter.decimalFormat(1.5) == "1.5")
  #expect(AnalyzerTexWriter.decimalFormat(0.0) == "0")
  #expect(AnalyzerTexWriter.decimalFormat(8.2) == "8.2")
}

/// The `karnaugh` tikz package orders the axis variables differently from Logisim, and
/// `reorderedIndex` is the permutation that reconciles them. It must be a bijection on
/// `0..<2^n` or the K-map values come out scrambled.
@Test func texReorderingIsAPermutation() {
  for inputCount in 1...6 {
    var seen = Set<Int>()
    for row in 0..<(1 << inputCount) {
      let mapped = AnalyzerTexWriter.reorderedIndex(inputCount: inputCount, row: row)
      #expect(mapped >= 0 && mapped < (1 << inputCount))
      #expect(seen.insert(mapped).inserted, "row \(row) collides at \(inputCount) inputs")
    }
  }
  // Upstream returns an empty permutation past six, and `reorderedIndex` then indexes it.
  // The port returns 0 rather than trapping; nothing reaches it, because every caller is
  // already behind the 64-row gate.
  #expect(AnalyzerTexWriter.reordered(7).isEmpty)
  #expect(AnalyzerTexWriter.reorderedIndex(inputCount: 7, row: 3) == 0)
}

// MARK: - AnalyzeStrings

/// The `.txt` preamble is `tableRemark1` + `tableRemark4` verbatim, so byte-matching it
/// against the jar is also the check that this module's copy of the `en` bundle, including
/// every curly quote, did not drift.
@Test func englishBundleMatchesTheJarForTheExportedStrings() {
  #expect(
    AnalyzeFileGolden.textFilePreamble
      == AnalyzeStrings.message("tableRemark1") + "\n\n"
        + AnalyzeStrings.message("tableRemark4") + "\n\n")
}

/// `LocaleManager` renders an unknown key as the key; several messages in `CsvInterpretor`
/// are un-keyed literals upstream and rely on exactly that.
@Test func unknownMessageKeysRenderAsThemselves() {
  #expect(AnalyzeStrings.message("Invalid entry value") == "Invalid entry value")
  #expect(AnalyzeStrings.message("Invalid nr of entries") == "Invalid nr of entries")
  #expect(AnalyzeStrings.message("tableRemark2", ["x"]) == "# Generated from circuit x")
  // A `%` that is not a placeholder is passed through, as `String.format` would reject but
  // `LocaleManager`'s simple substitution does not reach.
  #expect(AnalyzeStrings.message("nosuchkey", ["a"]) == "nosuchkey")
}
