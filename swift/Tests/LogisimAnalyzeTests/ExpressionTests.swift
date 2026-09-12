// ExpressionTests: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// The Java `Expression` is an abstract class with a Visitor<T>/IntVisitor double dispatch; the
// port is an indirect enum with ordinary switches. These tests exist to show that nothing was
// lost in that translation, so every expectation is a measurement from the shipped 4.1.0 jar
// (tools/analyze/EvalProbe.java and RenderProbe.java) rather than a restatement of the Swift.

import Testing

@testable import LogisimAnalyze

private func expr(_ s: String) throws -> Expression {
  let model = AnalyzerModel()
  try model.setVariables(
    inputs: [Var("a", 1), Var("b", 1), Var("c", 1), Var("x", 4)], outputs: [Var("q", 1)])
  return try #require(try Parser.parse(s, model))
}

/// The truth table of `e` over a, b, c with `a` as the most significant bit.
private func table(_ e: Expression) -> String {
  (0..<8).map { i -> String in
    var assn = Assignments()
    assn.put("a", i & 4 != 0)
    assn.put("b", i & 2 != 0)
    assn.put("c", i & 1 != 0)
    return e.evaluate(assn) ? "1" : "0"
  }.joined()
}

// MARK: - evaluate / removeVariable / replaceVariable

@Test func evaluationAndRewritesMatchTheJavaOracle() throws {
  // input, truth table, removeVariable("b"), replaceVariable("b", "z")
  let golden: [(String, String, String, String)] = [
    ("a", "00001111", "a", "a"),
    ("~a", "11110000", "~a", "~a"),
    ("a*b", "00000011", "a", "a⋅z"),
    ("a+b", "00111111", "a", "a+z"),
    ("a^b", "00111100", "a", "a⊕z"),
    ("a=b", "11000011", "a", "a⊙z"),
    ("a*b+c", "01010111", "a+c", "a⋅z+c"),
    ("(a+b)*c", "00010101", "a⋅c", "(a+z)⋅c"),
    ("~(a*b)", "11111100", "~a", "~(a⋅z)"),
    ("a^b^c", "01101001", "a⊕c", "a⊕z⊕c"),
    ("a=b=c", "01101001", "a⊙c", "a⊙z⊙c"),
    ("a^(b=c)", "10010110", "a⊕c", "a⊕(z⊙c)"),
    ("(a=b)^c", "10010110", "a⊕c", "(a⊙z)⊕c"),
    ("~a*~b*~c", "10000000", "~a⋅~c", "~a⋅~z⋅~c"),
    ("a+~b+c", "11011111", "a+c", "a+~z+c"),
    ("a*b*c", "00000001", "a⋅c", "a⋅z⋅c"),
    ("a b c", "00000001", "a⋅c", "a⋅z⋅c"),
    ("~~a", "00001111", "~~a", "~~a"),
    ("a*~a", "00000000", "a⋅~a", "a⋅~a"),
    ("a+~a", "11111111", "a+~a", "a+~a"),
    ("a=a", "11111111", "a⊙a", "a⊙a"),
    ("a^a", "00000000", "a⊕a", "a⊕a"),
    ("b", "00110011", "null", "z"),
    ("~b", "11001100", "null", "~z"),
    ("a*b*~c+~a*c", "01010000", "(a⋅~c+~a)⋅c", "(a⋅z⋅~c+~a)⋅c"),
  ]
  for (source, expectedTable, expectedRemoved, expectedReplaced) in golden {
    let e = try expr(source)
    #expect(table(e) == expectedTable, "evaluate [\(source)]")
    #expect((e.removeVariable("b")?.description ?? "null") == expectedRemoved, "remove [\(source)]")
    #expect(e.replaceVariable("b", "z").description == expectedReplaced, "replace [\(source)]")
  }
}

@Test func equalityIsStructuralAndDiscriminatesTheOperator() {
  // Java: Binary.equals compares getClass() first, so an AND never equals an OR even with the
  // same operands; Variable and Constant compare their payload. The enum gives all of that.
  #expect(Expression.and(.variable("a"), .variable("b")) == .and(.variable("a"), .variable("b")))
  #expect(Expression.and(.variable("a"), .variable("b")) != .or(.variable("a"), .variable("b")))
  #expect(Expression.and(.variable("a"), .variable("b")) != .and(.variable("b"), .variable("a")))
  #expect(Expression.variable("a") != .variable("b"))
  #expect(Expression.constant(1) != .constant(0))
  #expect(Expression.constant(1) != .variable("1"))
  var seen = Set<Expression>()
  seen.insert(.and(.variable("a"), .variable("b")))
  #expect(seen.contains(.and(.variable("a"), .variable("b"))))
  #expect(!seen.contains(.xor(.variable("a"), .variable("b"))))
}

@Test func nilPropagationInTheFactoriesMatchesJava() {
  // Java's Expressions.and/or/... return the other operand when one side is null, so callers
  // can fold a list without a special first iteration; not(null) is null.
  #expect(Expressions.and(nil, .variable("a")) == .variable("a"))
  #expect(Expressions.and(.variable("a"), nil) == .variable("a"))
  #expect(Expressions.and(nil, nil) == nil)
  #expect(Expressions.not(nil) == nil)
  #expect(Expressions.xnor(nil, .variable("a")) == .variable("a"))
}

// MARK: - Queries

@Test func containsNeverReportsNotEvenWhenNotIsPresent() throws {
  // Faithful to upstream: the search visitor's visitNot recurses without testing the operator,
  // so contains(Op.NOT) is unconditionally false. Measured on 4.1.0 for `~a`, `a NOT b`, and
  // every other case in the parser golden file: all report not=false.
  #expect(try expr("~a").contains(.not) == false)
  #expect(try expr("~(a*b)").contains(.not) == false)
  #expect(try expr("a^b").contains(.xor) == true)
  #expect(try expr("a*b").contains(.and) == true)
  #expect(try expr("a*(b^c)").contains(.xor) == true)
  #expect(try expr("~(a^b)").contains(.xor) == true)
  #expect(try expr("a*b").contains(.or) == false)
  #expect(try expr("a=b").contains(.xnor) == true)
}

@Test func isCnfReproducesTheUpstreamLevelInversion() throws {
  // Measured: 4.1.0 answers false for a textbook CNF and true for a DNF, because visitOr
  // rejects anything below the top level while visitAnd descends with level = 1.
  #expect(try expr("(a+b)*c").isCnf == false)
  #expect(try expr("a*b+c").isCnf == true)
  #expect(try expr("(a+b)(b+c)").isCnf == false)
  #expect(try expr("a").isCnf == true)
  #expect(try expr("~a").isCnf == true)
  #expect(try expr("~~a").isCnf == false)  // NOT inside NOT
  #expect(try expr("a^b").isCnf == false)  // any XOR disqualifies
}

@Test func isCircularIsUnreachableForAnIndirectEnum() throws {
  // Upstream's walk can only fire on a cyclic object graph, which its own API cannot build
  // either; an indirect enum makes it unrepresentable. Every case in the parser golden file
  // reports circ=false on 4.1.0, including the self-referential-looking ones.
  #expect(try expr("a*a").isCircular == false)
  #expect(try expr("(a+b)*(a+b)").isCircular == false)
  #expect(try expr("~~a").isCircular == false)
}

@Test func assignmentAccessors() {
  let assignment = Expression.eq(.variable("q"), .or(.variable("a"), .variable("b")))
  #expect(assignment.isAssignment)
  #expect(assignment.assignmentVariable == "q")
  #expect(assignment.assignmentExpression == .or(.variable("a"), .variable("b")))
  // Java requires the left side to be a bare Variable.
  let notAssignment = Expression.eq(.not(.variable("q")), .variable("a"))
  #expect(!notAssignment.isAssignment)
  #expect(notAssignment.assignmentVariable == nil)
  #expect(notAssignment.assignmentExpression == nil)
  #expect(!Expression.and(.variable("q"), .variable("a")).isAssignment)
}

// MARK: - Rendering

@Test func reducedRenderingMatchesTheJavaOracle() throws {
  // From RenderProbe against 4.1.0: with `reduce` on and mathematical notation, NOTs are not
  // printed at all, the UI draws an overbar over the recorded range instead, and bus
  // subscripts become subscript ranges.
  struct Expected {
    let text: String
    let nots: [(Int, Int)]
    let subs: [(Int, Int)]
    let badness: [Int]
  }
  let golden: [(String, Expected)] = [
    ("a", Expected(text: "a", nots: [], subs: [], badness: [200])),
    ("~a", Expected(text: "a", nots: [(0, 1)], subs: [], badness: [215])),
    ("~(a+b)", Expected(text: "a+b", nots: [(0, 3)], subs: [], badness: [215, 15, 215])),
    ("a*~b", Expected(text: "a⋅b", nots: [(2, 3)], subs: [], badness: [205, 5, 220])),
    ("x[3] ", Expected(text: "x3", nots: [], subs: [(1, 2)], badness: [200, 200])),
    ("~~a", Expected(text: "a", nots: [(0, 1), (0, 1)], subs: [], badness: [230])),
    (
      "a*b+~a",
      Expected(text: "a⋅b+a", nots: [(4, 5)], subs: [], badness: [205, 5, 205, 0, 215])
    ),
    (
      "(a+b)*(a+~b)",
      Expected(
        text: "(a+b)⋅(a+b)", nots: [(9, 10)], subs: [],
        badness: [15, 215, 15, 215, 15, 5, 15, 215, 15, 230, 15])
    ),
  ]
  for (source, expected) in golden {
    let rendering = try expr(source).render(.mathematical, reduce: true)
    #expect(rendering.text == expected.text, "text [\(source)]")
    #expect(
      rendering.nots.map { ($0.startIndex, $0.stopIndex) }.map { "\($0)-\($1)" }
        == expected.nots.map { "\($0)-\($1)" }, "nots [\(source)]")
    #expect(
      rendering.subscripts.map { ($0.startIndex, $0.stopIndex) }.map { "\($0)-\($1)" }
        == expected.subs.map { "\($0)-\($1)" }, "subscripts [\(source)]")
    #expect(rendering.badness == expected.badness, "badness [\(source)]")
  }
}

@Test func highlightingProducesMarkRanges() throws {
  // Java's `other` parameter: every structurally equal subexpression is marked, not just one.
  // Parenthesised: `a*b+a*b` would parse as `((a*b)+a)*b`, since + and * share a precedence
  // level (see ParserTests.plusAndTimesShareOnePrecedenceLevel).
  let e = try expr("(a*b)+(a*b)")
  let rendering = e.render(.mathematical, highlighting: .and(.variable("a"), .variable("b")))
  #expect(rendering.text == "a⋅b+a⋅b")
  #expect(rendering.marks.map { [$0.startIndex, $0.stopIndex] } == [[0, 3], [4, 7]])
}

@Test func renderingIsPurelyFunctional() throws {
  // Upstream accumulates `marks` on the expression object across calls because it only clears
  // them when `reduce` is set; repeated highlighting grows the list forever. A value returned
  // per call cannot do that.
  let e = try expr("a*b")
  let mark = Expression.variable("a")
  let first = e.render(.mathematical, highlighting: mark)
  let second = e.render(.mathematical, highlighting: mark)
  #expect(first.marks.count == 1)
  #expect(second.marks.count == 1)
  // Measured on 4.1.0 with `(a*b)+(a*b)` highlighting `a*b`: `e.marks.size()` is 2 after the
  // first toString and 4 after the second.
}

@Test func notationSymbolsAndPrecedenceLevels() {
  // The opLvl/opSym tables are indexed by Op.id, { EQ, XNOR, OR, XOR, AND, NOT }, and a
  // transposition there is invisible until an expression renders wrongly.
  #expect(Expression.Notation.mathematical.opSym == [" = ", "⊙", "+", "⊕", "⋅", "~"])
  #expect(Expression.Notation.mathematical.opLevel == [0, 10, 11, 12, 13, 14])
  #expect(Expression.Notation.progBools.opSym == [" = ", "==", "||", "!=", "&&", "!"])
  #expect(Expression.Notation.progBools.opLevel == [0, 9, 4, 9, 5, 14])
  #expect(Expression.Notation.progBits.opSym == [" = ", "^~", "|", "^", "&", "~"])
  #expect(Expression.Notation.latex.opLevel == [0, 10, 11, 12, 13, 14])
  // Leaves bind tightest, matching Integer.MAX_VALUE upstream.
  #expect(Expression.variable("a").precedence(in: .mathematical) == Int(Int32.max))
  #expect(Expression.constant(1).precedence(in: .mathematical) == Int(Int32.max))
  #expect(Expression.and(.variable("a"), .variable("b")).precedence(in: .mathematical) == 13)
  #expect(Expression.Op.not.arity == 1)
  #expect(Expression.Op.and.arity == 2)
}
