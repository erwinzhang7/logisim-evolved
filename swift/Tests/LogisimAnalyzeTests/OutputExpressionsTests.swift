// OutputExpressionsTests: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// OutputExpressions is the two-way binding between the truth table and the expression the
// user edits: changing the table invalidates the expression, and setting an expression
// rewrites the table's column. The sequence below is replayed verbatim from
// tools/analyze/OutProbe.java against the shipped 4.1.0 jar.

import Testing

@testable import LogisimAnalyze

private func snapshot(_ m: AnalyzerModel) -> String {
  let oe = m.outputExpressions
  let column = (0..<m.truthTable.rowCount)
    .map { m.truthTable.outputEntry(row: $0, column: 0).description() }.joined()
  return "expr=\(oe.expression(for: "q")?.description ?? "null")"
    + " | str=\(oe.expressionString(for: "q"))"
    + " | min=\(oe.minimalExpression(for: "q")?.description ?? "null")"
    + " | fmt=\(oe.minimizedFormat(for: "q"))"
    + " | col=\(column)"
    + " | inputs=\(m.inputs.bits)"
}

@Test func outputExpressionsTrackTheTableLikeTheJavaOracle() throws {
  let m = AnalyzerModel()
  try m.setVariables(
    inputs: [Var("a", 1), Var("b", 1), Var("c", 1)], outputs: [Var("q", 1)])
  try m.truthTable.setOutputColumn(0, Array("00010111").map { $0 == "1" ? .one : Entry.zero })

  // The majority function, minimised on first access.
  #expect(
    snapshot(m)
      == #"expr=b⋅c+a⋅c+a⋅b | str=b⋅c+a⋅c+a⋅b | min=b⋅c+a⋅c+a⋅b | fmt=0 | col=00010111 | inputs=["a", "b", "c"]"#)

  m.outputExpressions.enableUpdates()
  #expect(
    snapshot(m)
      == #"expr=b⋅c+a⋅c+a⋅b | str=b⋅c+a⋅c+a⋅b | min=b⋅c+a⋅c+a⋅b | fmt=0 | col=00010111 | inputs=["a", "b", "c"]"#)

  // Setting an expression rewrites the truth table column under it.
  try m.outputExpressions.setExpression("q", Parser.parse("a*b", m))
  #expect(
    snapshot(m)
      == #"expr=a⋅b | str=a⋅b | min=a⋅b | fmt=0 | col=00000011 | inputs=["a", "b", "c"]"#)

  m.outputExpressions.setMinimizedFormat("q", AnalyzerModel.formatProductOfSums)
  #expect(
    snapshot(m)
      == #"expr=a⋅b | str=a⋅b | min=a⋅b | fmt=1 | col=00000011 | inputs=["a", "b", "c"]"#)

  try m.outputExpressions.setExpression("q", Parser.parse("a+b+c", m))
  #expect(
    snapshot(m)
      == #"expr=a+b+c | str=a+b+c | min=a+b+c | fmt=1 | col=01111111 | inputs=["a", "b", "c"]"#)

  // Renaming an input rewrites the expression in place.
  try m.inputs.replace(Var("b", 1), Var("z", 1))
  #expect(
    snapshot(m)
      == #"expr=a+z+c | str=a+z+c | min=a+z+c | fmt=1 | col=01111111 | inputs=["a", "z", "c"]"#)

  // Removing an input drops it from the expression and halves the column.
  try m.inputs.remove(Var("c", 1))
  #expect(
    snapshot(m) == #"expr=a+z | str=a+z | min=a+z | fmt=1 | col=0111 | inputs=["a", "z"]"#)
}

/// The one measured divergence in this file, and it is the D3/value-type consequence spelled
/// out in `OutputExpressions`: Java compares `expr == minimalExpr` **by reference**.
@Test func isExpressionMinimalIsStructuralHereAndReferenceBasedUpstream() throws {
  let m = AnalyzerModel()
  try m.setVariables(
    inputs: [Var("a", 1), Var("b", 1), Var("c", 1)], outputs: [Var("q", 1)])
  try m.truthTable.setOutputColumn(0, Array("00010111").map { $0 == "1" ? .one : Entry.zero })
  m.outputExpressions.enableUpdates()

  // Freshly minimised: both implementations agree.
  #expect(m.outputExpressions.isExpressionMinimal("q") == true)

  // After setting `a*b`, the table becomes 00000011 and the minimal expression is `a⋅b`
  // again: structurally identical to what the user typed, but a different object.
  //
  //   4.1.0: expr=a⋅b  min=a⋅b  isExpressionMinimal=false
  //   here: expr=a⋅b  min=a⋅b  isExpressionMinimal=true
  //
  // The Java answer is a false negative: it would tell the user their expression is not
  // minimal while displaying the minimal expression next to it. Value semantics remove the
  // question rather than the behaviour.
  try m.outputExpressions.setExpression("q", Parser.parse("a*b", m))
  #expect(m.outputExpressions.expression(for: "q")?.description == "a⋅b")
  #expect(m.outputExpressions.minimalExpression(for: "q")?.description == "a⋅b")
  #expect(m.outputExpressions.isExpressionMinimal("q") == true)

  // A genuinely non-minimal expression is still reported as such.
  try m.outputExpressions.setExpression("q", Parser.parse("a*b*c+a*b*~c", m))
  #expect(m.outputExpressions.isExpressionMinimal("q") == false)
}

@Test func unknownOutputsAreInertRatherThanThrowing() throws {
  // Java throws IllegalArgumentException("unrecognized output …") and every caller swallows
  // it with `catch (Exception e)` and returns the same defaults produced here.
  let m = AnalyzerModel()
  try m.setVariables(inputs: [Var("a", 1)], outputs: [Var("q", 1)])
  #expect(m.outputExpressions.expression(for: "nope") == nil)
  #expect(m.outputExpressions.expressionString(for: "nope") == "")
  #expect(m.outputExpressions.minimalExpression(for: "nope") == .constant(0))
  #expect(m.outputExpressions.minimalImplicants(for: "nope") == Implicant.minimalList)
  #expect(m.outputExpressions.minimizedFormat(for: nil) == AnalyzerModel.formatSumOfProducts)
  #expect(m.outputExpressions.minimalExpression(for: nil) == .constant(0))
  #expect(m.outputExpressions.isExpressionMinimal("nope") == true)
}

@Test func theModelGraphDeallocatesCleanly() throws {
  // D3: the listener lists hold weak references, so AnalyzerModel -> TruthTable -> listener ->
  // OutputExpressions -> model is not a retain cycle. Java's ArrayList of listeners would be
  // one under ARC, and it would leak the entire analyzer for every circuit ever analysed.
  weak var weakTable: TruthTable?
  weak var weakExpressions: OutputExpressions?
  do {
    let m = AnalyzerModel()
    try m.setVariables(inputs: [Var("a", 1), Var("b", 1)], outputs: [Var("q", 1)])
    try m.truthTable.setOutputColumn(0, [.zero, .one, .one, .one])
    _ = m.outputExpressions.minimalExpression(for: "q")
    weakTable = m.truthTable
    weakExpressions = m.outputExpressions
    #expect(weakTable != nil)
    #expect(weakExpressions != nil)
  }
  #expect(weakTable == nil)
  #expect(weakExpressions == nil)
}
