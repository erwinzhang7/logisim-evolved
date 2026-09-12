// ParserTests: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// 93 differential cases measured against the shipped 4.1.0 jar (ParserGoldenData.swift), plus
// the cases where upstream does not have an answer to agree with because it crashes.

import Foundation
import Testing

@testable import LogisimAnalyze

/// The model the Java probe used: inputs `a`, `b`, `c` and the 4-bit bus `x`; outputs `q`, `r`.
func parserModel() throws -> AnalyzerModel {
  let model = AnalyzerModel()
  try model.setVariables(
    inputs: [Var("a", 1), Var("b", 1), Var("c", 1), Var("x", 4)],
    outputs: [Var("q", 1), Var("r", 1)])
  return model
}

private func describe(_ e: LogisimAnalyze.Expression) -> String {
  var parts: [String] = []
  for n in [
    LogisimAnalyze.Expression.Notation.mathematical, .logic, .altLogic, .progBools, .progBits, .latex,
  ] {
    parts.append(e.toString(n))
  }
  parts.append("cnf=\(e.isCnf)")
  parts.append("circ=\(e.isCircular)")
  parts.append(
    "xor=\(e.contains(.xor)) and=\(e.contains(.and)) not=\(e.contains(.not))")
  return parts.joined(separator: " ¦ ")
}

@Test func parserMatchesTheJavaOracle() throws {
  var checked = 0
  var skipped = 0
  for rawLine in ParserGolden.cases.split(separator: "\n", omittingEmptySubsequences: false) {
    let line = String(rawLine)
    guard let sep = line.range(of: " || ") else { continue }
    let input = String(line[line.startIndex..<sep.lowerBound])
    let expected = String(line[sep.upperBound...])
    if expected.hasPrefix("EXC ") {
      // Upstream throws StringIndexOutOfBoundsException here; covered by
      // `parserSurvivesTheBracketCasesUpstreamCrashesOn` instead.
      skipped += 1
      continue
    }
    let assignment = input.hasPrefix("A:")
    let text = assignment ? String(input.dropFirst(2)) : input
    let model = try parserModel()
    do {
      let expr =
        assignment
        ? try Parser.parseMaybeAssignment(text, model) : try Parser.parse(text, model)
      guard let expr else {
        #expect(expected == "null", "for [\(input)]")
        checked += 1
        continue
      }
      #expect(describe(expr) == expected, "for [\(input)]")
    } catch let error as ParserError {
      #expect(
        "ERR off=\(error.offset) len=\(error.length) \(error.message)" == expected,
        "for [\(input)]")
    }
    checked += 1
  }
  #expect(checked == 91)
  #expect(skipped == 2)
}

/// The measured upstream defect (see the long comment in `Parser.Tokenizer.tokenize`): 4.1.0
/// consumes one character too many after a bracketed bit subscript. These are the four
/// observations that motivated fixing it rather than porting it.
@Test func parserSurvivesTheBracketCasesUpstreamCrashesOn() throws {
  let model = try parserModel()

  // 4.1.0: StringIndexOutOfBoundsException: Index 5 out of bounds for length 5.
  #expect(try Parser.parse("x[0]", model) == .variable("x[0]"))
  // 4.1.0: StringIndexOutOfBoundsException: Index 12 out of bounds for length 12.
  #expect(
    try Parser.parse("x[1] + x[0]", model) == .or(.variable("x[1]"), .variable("x[0]")))
  // 4.1.0: swallows the '+' and returns `x[0]⋅b`: an OR silently turned into an AND.
  #expect(try Parser.parse("x[0]+b", model) == .or(.variable("x[0]"), .variable("b")))
  // 4.1.0: swallows the apostrophe and returns `x[0]`; the NOT is silently lost.
  #expect(try Parser.parse("x[0]'", model) == .not(.variable("x[0]")))

  // 4.1.0: StringIndexOutOfBoundsException: Index 4 out of bounds for length 4.
  // Here the fixed tokenizer reaches the error upstream meant to report.
  #expect(throws: ParserError.self) { try Parser.parse("a[]", model) }
  do {
    _ = try Parser.parse("a[]", model)
  } catch let e as ParserError {
    #expect(e.messageKey == "missingSubscriptError")
  }
}

// MARK: - Behaviour worth pinning independently of the oracle

@Test func plusAndTimesShareOnePrecedenceLevel() throws {
  // Not a typo in the golden file: the tokenizer gives both `+` and `*` LOGIC_PRECEDENCE, so
  // they associate left to right and `a+b*c` parses as `(a+b)*c`. The ASCII operators do not
  // follow the usual algebraic precedence; `&`/`|` and `&&`/`||` do.
  let model = try parserModel()
  #expect(try Parser.parse("a+b*c", model) == .and(.or(.variable("a"), .variable("b")), .variable("c")))
  #expect(try Parser.parse("a|b&c", model) == .or(.variable("a"), .and(.variable("b"), .variable("c"))))
}

@Test func adjacencyIsAnImplicitAnd() throws {
  let model = try parserModel()
  #expect(try Parser.parse("a b", model) == .and(.variable("a"), .variable("b")))
  #expect(try Parser.parse("a(b+c)", model) == .and(.variable("a"), .or(.variable("b"), .variable("c"))))
  #expect(try Parser.parse("~a~b", model) == .and(.not(.variable("a")), .not(.variable("b"))))
}

@Test func assignmentIsOnlyAcceptedInTheAssignmentEntryPoint() throws {
  let model = try parserModel()
  let assigned = try Parser.parseMaybeAssignment("q = a+b", model)
  #expect(assigned?.assignmentVariable == "q")
  #expect(assigned?.assignmentExpression == .or(.variable("a"), .variable("b")))
  #expect(assigned?.isAssignment == true)
  // Through the plain entry point, `q` is simply not an input variable.
  #expect(throws: ParserError.self) { try Parser.parse("q = a+b", model) }
}

@Test func replaceVariablePreservesSpacing() {
  #expect(Parser.replaceVariable("a  +  b", "a", "z") == "z  +  b")
  #expect(Parser.replaceVariable("a+ab", "a", "z") == "z+ab")
  #expect(Parser.replaceVariable("x[0] + x[1] ", "x[0]", "y[0]") == "y[0] + x[1] ")
}

@Test func variableParsing() throws {
  #expect(try Var.parse("a") == Var("a", 1))
  #expect(try Var.parse("  a  ") == Var("a", 1))
  #expect(try Var.parse("a[3..0]") == Var("a", 4))
  #expect(try Var.parse("a[31..0]") == Var("a", 32))
  #expect(throws: ParserError.self) { try Var.parse("a[32..0]") }
  #expect(throws: ParserError.self) { try Var.parse("a[3..1]") }
  #expect(throws: ParserError.self) { try Var.parse("a[x..0]") }
  #expect(throws: ParserError.self) { try Var.parse("a[") }
  #expect(Var("a", 4).description == "a[3..0]")
  #expect(Var("a", 1).description == "a")
  // The iterator runs from the most significant bit down; VariableList depends on it.
  #expect(Array(Var("a", 3)) == ["a[2]", "a[1]", "a[0]"])
  #expect(Array(Var("a", 1)) == ["a"])
  #expect(try Var.Bit.parse("a[3]") == Var.Bit("a", 3))
  #expect(try Var.Bit.parse("a:3") == Var.Bit("a", 3))
  #expect(try Var.Bit.parse("a") == Var.Bit("a", -1))
  #expect(throws: ParserError.self) { try Var.Bit.parse(":3") }
}
