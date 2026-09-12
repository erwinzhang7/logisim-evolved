// TruthTableTests: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// The reshaping code in TruthTable.MyListener is pure index arithmetic: adding an input
// duplicates every cell, removing one merges pairs and forces disagreements to don't-care,
// moving one permutes the row index bits. It is exactly the kind of code that compiles,
// looks right and is wrong, so every expectation below was captured from the shipped 4.1.0
// jar with tools/analyze/TableProbe.java rather than reasoned out.

import Testing

@testable import LogisimAnalyze

private func columnString(_ m: AnalyzerModel) -> String {
  (0..<m.truthTable.rowCount)
    .map { m.truthTable.outputEntry(row: $0, column: 0).description() }
    .joined()
}

private func rowsString(_ m: AnalyzerModel) -> String {
  let t = m.truthTable
  return (0..<t.visibleRowCount).map { r in
    let inputs = (0..<t.inputColumnCount)
      .map { t.visibleInputEntry(row: r, column: $0).description() }.joined()
    return inputs + "=" + t.visibleOutputEntry(row: r, column: 0).description()
  }.joined(separator: ",")
}

private func snapshot(_ m: AnalyzerModel) -> String {
  "bits=\(m.inputs.bits) | col=\(columnString(m)) | rows=\(rowsString(m))"
}

private func threeInputModel(_ spec: String) throws -> AnalyzerModel {
  let m = AnalyzerModel()
  try m.setVariables(
    inputs: [Var("a", 1), Var("b", 1), Var("c", 1)], outputs: [Var("q", 1)])
  let column = Array(spec).map { $0 == "1" ? Entry.one : Entry.zero }
  try m.truthTable.setOutputColumn(0, column)
  return m
}

@Test func reshapingMatchesTheJavaOracle() throws {
  let m = try threeInputModel("01101001")
  #expect(
    snapshot(m)
      == #"bits=["a", "b", "c"] | col=01101001 | rows=000=0,001=1,010=1,011=0,100=1,101=0,110=0,111=1"#)

  try m.inputs.add(Var("d", 1))
  #expect(
    snapshot(m)
      == #"bits=["a", "b", "c", "d"] | col=0011110011000011 | rows=0000=0,0001=0,0010=1,0011=1,0100=1,0101=1,0110=0,0111=0,1000=1,1001=1,1010=0,1011=0,1100=0,1101=0,1110=1,1111=1"#)

  try m.inputs.remove(Var("b", 1))
  #expect(
    snapshot(m)
      == #"bits=["a", "c", "d"] | col=00111100 | rows=000=0,001=0,010=1,011=1,100=1,101=1,110=0,111=0"#)

  try m.inputs.move(Var("a", 1), 1)
  #expect(
    snapshot(m)
      == #"bits=["c", "a", "d"] | col=00111100 | rows=000=0,001=0,010=1,011=1,100=1,101=1,110=0,111=0"#)

  try m.inputs.replace(Var("c", 1), Var("c", 2))
  #expect(
    snapshot(m)
      == #"bits=["c[1]", "c[0]", "a", "d"] | col=0011110000111100 | rows=0000=0,0001=0,0010=1,0011=1,0100=1,0101=1,0110=0,0111=0,1000=0,1001=0,1010=1,1011=1,1100=1,1101=1,1110=0,1111=0"#)

  try m.inputs.replace(Var("c", 2), Var("c", 1))
  #expect(
    snapshot(m)
      == #"bits=["c", "a", "d"] | col=00111100 | rows=000=0,001=0,010=1,011=1,100=1,101=1,110=0,111=0"#)

  m.truthTable.compactVisibleRows()
  #expect(snapshot(m) == #"bits=["c", "a", "d"] | col=00111100 | rows=00-=0,01-=1,10-=1,11-=0"#)

  m.truthTable.expandVisibleRows()
  #expect(
    snapshot(m)
      == #"bits=["c", "a", "d"] | col=00111100 | rows=000=0,001=0,010=1,011=1,100=1,101=1,110=0,111=0"#)

  #expect(m.truthTable.structuralFailure == nil)
}

@Test func compactingAndSplittingMatchTheJavaOracle() throws {
  let m = try threeInputModel("00110011")
  #expect(
    snapshot(m)
      == #"bits=["a", "b", "c"] | col=00110011 | rows=000=0,001=0,010=1,011=1,100=0,101=0,110=1,111=1"#)

  m.truthTable.compactVisibleRows()
  #expect(snapshot(m) == #"bits=["a", "b", "c"] | col=00110011 | rows=-0-=0,-1-=1"#)

  // Writing a visible row writes every concrete row it covers.
  m.truthTable.setVisibleOutputEntry(row: 0, column: 0, .one)
  #expect(snapshot(m) == #"bits=["a", "b", "c"] | col=11111111 | rows=-0-=1,-1-=1"#)

  // Writing a single concrete row splits the visible cube that contained it.
  try m.truthTable.setOutputEntry(row: 3, column: 0, .zero)
  #expect(snapshot(m) == #"bits=["a", "b", "c"] | col=11101111 | rows=-0-=1,-10=1,-11=0"#)

  #expect(m.truthTable.visibleRowDcMask(row: 0) == 5)
  #expect(m.truthTable.visibleRowIndex(row: 0) == 0)
  #expect(m.truthTable.visibleRowIndexes(row: 0) == [0, 1, 4, 5])
}

// MARK: - Shape and laziness

@Test func columnsAreLazyAndDefaultToDontCare() throws {
  let m = AnalyzerModel()
  try m.setVariables(inputs: [Var("a", 1), Var("b", 1)], outputs: [Var("q", 1), Var("r", 1)])
  #expect(m.truthTable.rowCount == 4)
  #expect(m.truthTable.outputColumnCount == 2)
  // Nothing is allocated until it is written or explicitly materialised.
  #expect(m.truthTable.isColumnAllocated(0) == false)
  #expect(m.truthTable.outputEntry(row: 3, column: 1) == .dontCare)
  #expect(m.truthTable.isColumnAllocated(1) == false)
  // Writing the default entry into an unallocated column stays lazy.
  m.truthTable.setVisibleOutputEntry(row: 0, column: 0, .dontCare)
  #expect(m.truthTable.isColumnAllocated(0) == false)
  m.truthTable.setVisibleOutputEntry(row: 0, column: 0, .one)
  #expect(m.truthTable.isColumnAllocated(0) == true)
  #expect(try m.truthTable.outputColumn(0) == [.one, .dontCare, .dontCare, .dontCare])
}

@Test func inputColumnZeroIsTheMostSignificantBit() {
  #expect(TruthTable.isInputSet(row: 0b100, column: 0, inputs: 3) == true)
  #expect(TruthTable.isInputSet(row: 0b100, column: 2, inputs: 3) == false)
  #expect(TruthTable.isInputSet(row: 0b001, column: 2, inputs: 3) == true)
}

@Test func badEditsThrowRatherThanTrap() throws {
  // D13: everything reachable from a user edit is a throw.
  let m = try threeInputModel("01101001")
  #expect(throws: AnalyzeError.self) {
    try m.truthTable.setOutputColumn(0, [.one, .zero])  // wrong length
  }
  #expect(throws: AnalyzeError.self) { _ = try m.truthTable.outputColumn(7) }
  #expect(throws: AnalyzeError.self) { _ = try m.truthTable.inputEntry(row: 99, column: 0) }
  #expect(throws: AnalyzeError.self) {
    _ = try m.truthTable.setVisibleInputEntry(row: 0, column: 0, .busError, force: false)
  }
  let big = AnalyzerModel()
  #expect(throws: AnalyzeError.self) {
    try big.inputs.setAll([Var("wide", 21)])  // MAX_INPUTS is 20
  }
  #expect(throws: AnalyzeError.self) { try m.inputs.remove(Var("zzz", 1)) }
}

@Test func setVisibleRowsRejectsGapsAndOverlaps() throws {
  let m = AnalyzerModel()
  try m.setVariables(inputs: [Var("a", 1), Var("b", 1)], outputs: [Var("q", 1)])
  // Missing rows.
  #expect(throws: AnalyzeError.self) {
    try m.truthTable.setVisibleRows([[.zero, .zero, .one]], force: false)
  }
  // Conflicting overlap: `-0` says 1, `00` says 0.
  #expect(throws: AnalyzeError.self) {
    try m.truthTable.setVisibleRows(
      [[.dontCare, .zero, .one], [.zero, .zero, .zero], [.dontCare, .one, .zero]], force: false)
  }
  // A complete, consistent set is accepted and expands into the dense column.
  try m.truthTable.setVisibleRows(
    [[.dontCare, .zero, .one], [.dontCare, .one, .zero]], force: false)
  #expect(columnString(m) == "1010")
  // force: true fills the gaps with don't-care rows instead of throwing.
  let m2 = AnalyzerModel()
  try m2.setVariables(inputs: [Var("a", 1), Var("b", 1)], outputs: [Var("q", 1)])
  try m2.truthTable.setVisibleRows([[.zero, .zero, .one]], force: true)
  #expect(columnString(m2) == "1---")
}

// MARK: - Entry

@Test func entryMatchesTheJavaSingletons() {
  #expect(Entry.zero.description() == "0")
  #expect(Entry.one.description() == "1")
  #expect(Entry.dontCare.description() == "-")
  #expect(Entry.busError.description() == "E")
  #expect(Entry.oscillateError.description() == "@")
  #expect(Entry.busError.isError)
  #expect(Entry.oscillateError.isError)
  #expect(!Entry.dontCare.isError)
  #expect(Entry.parse("0") == .zero)
  #expect(Entry.parse("-") == .dontCare)
  #expect(Entry.parse("E") == .busError)
  // Java's parse cannot read back '@' or the unknown character; the round trip is
  // deliberately incomplete upstream, which is why the model passes entries around rather
  // than description characters.
  #expect(Entry.parse("@") == nil)
  #expect(Entry.parse("U") == nil)
  // sortOrder, via Comparable.
  #expect(Entry.oscillateError < Entry.busError)
  #expect(Entry.busError < Entry.zero)
  #expect(Entry.zero < Entry.dontCare)
  #expect(Entry.dontCare < Entry.one)
  #expect(Entry.busError.toBitString() == "?")
  #expect(Entry.one.toBitString() == "1")
}
