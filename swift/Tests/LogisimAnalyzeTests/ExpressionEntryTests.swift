// ExpressionEntryTests: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Why this file exists ────────────────────────────────────────────────────────────────────
//
// `analyze/gui/ExpressionTab` is excluded by D9 (it is a `JTable` with a cell editor and a
// `TransferHandler`), and `AnalyzeNotPorted.swift` records that. But it is the *only* caller in
// all of 4.1.0 of five model entry points that are otherwise fully ported and pinned:
//
//   Parser.parse                      ExpressionTab.java:279
//   Parser.parseMaybeAssignment       ExpressionTab.java:496
//   Expression.isAssignment           ExpressionTab.java:520, 529
//   Expression.getAssignmentVariable  ExpressionTab.java:521
//   Expression.getAssignmentExpression ExpressionTab.java:529
//
// Each of those five is individually tested (`ParserTests`, `ExpressionTests`). What is *not*
// tested anywhere is the sequence they are used in: `importData`, ExpressionTab.java:485-539:
// parse a pasted string that may be an assignment, route it to the output row its left-hand
// side names, strip the assignment, and commit it through `OutputExpressions.setExpression`,
// which rewrites that output's truth-table column underneath it.
//
// That composition is the whole model-side contract of the missing tab. Pinning it here means
// whoever adds the UI is wiring up a path that is already known to agree with 4.1.0, rather
// than discovering the routing and rejection rules by experiment. In particular it fixes the
// three ways upstream *rejects* an import, which are easy to get wrong and are not obvious from
// the individual units: a parser error, a non-assignment with no row selected, and an
// assignment whose target is not an output.
//
// ── Regenerating the oracle ─────────────────────────────────────────────────────────────────
//
// The probe is reproduced in full below rather than committed, because it exercises no
// production seam of its own; it is a transcription of `importData` with the Swing removed.
// Save it as `ExprTabProbe.java` and run:
//
//     JAR=/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar
//     JAVA=/opt/homebrew/opt/openjdk@21/bin/java
//     ${JAVA%java}javac -cp "$JAR" -d /tmp/anaprobe ExprTabProbe.java
//     "$JAVA" -Djava.awt.headless=true -cp "$JAR:/tmp/anaprobe" \
//         com.cburch.logisim.analyze.model.ExprTabProbe
//
//     package com.cburch.logisim.analyze.model;
//     import java.util.ArrayList; import java.util.List;
//     public class ExprTabProbe {
//       static AnalyzerModel m;
//       static final String[] NAMES = {"q", "r", "s"};
//       static String col(int c) {
//         TruthTable t = m.getTruthTable(); StringBuilder s = new StringBuilder();
//         for (int i = 0; i < t.getRowCount(); i++)
//           s.append(t.getOutputEntry(i, c).getDescription());
//         return s.toString();
//       }
//       static void show(String label) {
//         OutputExpressions oe = m.getOutputExpressions();
//         StringBuilder sb = new StringBuilder(label);
//         for (int i = 0; i < NAMES.length; i++)
//           sb.append(" | ").append(NAMES[i]).append("=").append(oe.getExpression(NAMES[i]))
//             .append("/").append(col(i));
//         System.out.println(sb);
//       }
//       static void importData(String s) {          // ExpressionTab.java:485-539
//         Expression expr;
//         try { expr = Parser.parseMaybeAssignment(s, m); }
//         catch (ParserException ex) {
//           System.out.println("import " + q(s) + " -> REJECT parser:" + ex.getMessage()); return; }
//         if (expr == null) { System.out.println("import " + q(s) + " -> REJECT null"); return; }
//         int idx = -1; // getSelectedRow() < 0
//         if (Expression.isAssignment(expr)) {
//           String v = Expression.getAssignmentVariable(expr);
//           for (idx = NAMES.length - 1; idx >= 0; idx--) if (v.equals(NAMES[idx])) break;
//         }
//         if (idx < 0 || idx >= NAMES.length) {
//           System.out.println("import " + q(s) + " -> REJECT norow"); return; }
//         if (Expression.isAssignment(expr)) expr = Expression.getAssignmentExpression(expr);
//         m.getOutputExpressions().setExpression(NAMES[idx], expr, s);
//         show("import " + q(s) + " -> row " + idx);
//       }
//       static String q(String s) { return "\"" + s + "\""; }
//       public static void main(String[] a) throws Exception {
//         m = new AnalyzerModel();
//         m.setVariables(
//           new ArrayList<>(List.of(new Var("a",1), new Var("b",1), new Var("c",1))),
//           new ArrayList<>(List.of(new Var("q",1), new Var("r",1), new Var("s",1))));
//         m.getOutputExpressions().enableUpdates();
//         show("initial");
//         importData("q = a+b"); importData("r = a*b"); importData("s = ~c");
//         importData("a+b"); importData("z = a"); importData("q = a ^ b");
//         importData("r = 1"); importData("s = a b c"); importData("q = ");
//         importData("r = a &&& b"); importData("q = (a+b)'");
//         System.exit(0);
//       }
//     }

// NB: deliberately no `import Foundation`. On macOS it exports its own `Expression` type, which
// makes every unqualified `Expression` here ambiguous. Nothing in this file needs it.
import Testing

@testable import LogisimAnalyze

/// The transcript the 4.1.0 jar prints, verbatim. Measured 2026-09-06.
private let javaTranscript = """
  initial | q=0/-------- | r=0/-------- | s=0/--------
  import "q = a+b" -> row 0 | q=a+b/00111111 | r=0/-------- | s=0/--------
  import "r = a*b" -> row 1 | q=a+b/00111111 | r=a⋅b/00000011 | s=0/--------
  import "s = ~c" -> row 2 | q=a+b/00111111 | r=a⋅b/00000011 | s=~c/10101010
  import "a+b" -> REJECT norow
  import "z = a" -> REJECT parser:“z” is not an input variable.
  import "q = a ^ b" -> row 0 | q=a⊕b/00111100 | r=a⋅b/00000011 | s=~c/10101010
  import "r = 1" -> row 1 | q=a⊕b/00111100 | r=1/11111111 | s=~c/10101010
  import "s = a b c" -> row 2 | q=a⊕b/00111100 | r=1/11111111 | s=a⋅b⋅c/00000001
  import "q = " -> REJECT parser:Operator “=” missing right operand.
  import "r = a &&& b" -> REJECT parser:Operator “&” missing left operand.
  import "q = (a+b)'" -> row 0 | q=~(a+b)/11000000 | r=1/11111111 | s=a⋅b⋅c/00000001
  """

private let outputNames = ["q", "r", "s"]

private struct ImportHarness {
  let model = AnalyzerModel()
  var lines: [String] = []

  init() throws {
    try model.setVariables(
      inputs: [Var("a", 1), Var("b", 1), Var("c", 1)],
      outputs: [Var("q", 1), Var("r", 1), Var("s", 1)])
    model.outputExpressions.enableUpdates()
  }

  func column(_ index: Int) -> String {
    (0..<model.truthTable.rowCount)
      .map { model.truthTable.outputEntry(row: $0, column: index).description() }
      .joined()
  }

  func show(_ label: String) -> String {
    var out = label
    for (i, name) in outputNames.enumerated() {
      let expr = model.outputExpressions.expression(for: name)?.description ?? "null"
      out += " | \(name)=\(expr)/\(column(i))"
    }
    return out
  }

  /// `ExpressionTab.importData`, ExpressionTab.java:485-539, with no row selected and no drop
  /// location: the paste case. The Swing half (the transferable, the error label, the caret
  /// move) is D9-excluded; this is everything below it.
  mutating func importData(_ s: String) throws {
    var expr: Expression?
    do {
      expr = try Parser.parseMaybeAssignment(s, model)
    } catch let error as ParserError {
      lines.append("import \"\(s)\" -> REJECT parser:\(error.message)")
      return
    }
    guard var expression = expr else {
      lines.append("import \"\(s)\" -> REJECT null")
      return
    }
    // `getSelectedRow()` is < 0, so the assignment's left-hand side names the row. Java scans
    // downward from the last row and leaves `idx` at -1 when nothing matches.
    var idx = -1
    if expression.isAssignment, let target = expression.assignmentVariable {
      idx = outputNames.count - 1
      while idx >= 0 && outputNames[idx] != target { idx -= 1 }
    }
    guard idx >= 0 && idx < outputNames.count else {
      lines.append("import \"\(s)\" -> REJECT norow")
      return
    }
    if expression.isAssignment, let stripped = expression.assignmentExpression {
      expression = stripped
    }
    try model.outputExpressions.setExpression(outputNames[idx], expression, s)
    lines.append(show("import \"\(s)\" -> row \(idx)"))
  }
}

/// The model-side contract of the not-ported `ExpressionTab`, replayed against the 4.1.0 jar.
///
/// This is the composition that the five otherwise-unreachable entry points exist for. Each
/// line is compared separately so a divergence names the import that caused it rather than
/// dumping the whole transcript.
@Test func expressionImportMatchesTheJavaOracle() throws {
  var h = try ImportHarness()
  h.lines.append(h.show("initial"))

  for input in [
    "q = a+b", "r = a*b", "s = ~c", "a+b", "z = a", "q = a ^ b",
    "r = 1", "s = a b c", "q = ", "r = a &&& b", "q = (a+b)'",
  ] {
    try h.importData(input)
  }

  let expected = javaTranscript.split(separator: "\n").map(String.init)
  #expect(h.lines.count == expected.count)
  #expect(h.lines.count == 12)
  for (actual, want) in zip(h.lines, expected) {
    #expect(actual == want)
  }
}

/// The three ways upstream refuses an import, stated as behaviour rather than as a transcript
/// line, because a UI has to distinguish them: two are user errors worth reporting at a caret
/// position, and the third is silent.
@Test func expressionImportRejectionsAreDistinguishable() throws {
  let model = AnalyzerModel()
  try model.setVariables(
    inputs: [Var("a", 1), Var("b", 1), Var("c", 1)],
    outputs: [Var("q", 1), Var("r", 1), Var("s", 1)])

  // 1. A parser error carries an offset and length, which upstream uses to select the offending
  //    text in the field (`ExpressionTab.java:285-286`).
  #expect(throws: ParserError.self) {
    _ = try Parser.parseMaybeAssignment("q = ", model)
  }
  do {
    _ = try Parser.parseMaybeAssignment("z = a", model)
    Issue.record("an assignment to a non-variable should not parse")
  } catch let error as ParserError {
    #expect(error.message == "“z” is not an input variable.")
  }

  // 2. A well-formed expression that is not an assignment has no row to go to when nothing is
  //    selected, and is dropped with no message at all.
  let plain = try Parser.parseMaybeAssignment("a+b", model)
  #expect(plain != nil)
  #expect(plain?.isAssignment == false)
  #expect(plain?.assignmentVariable == nil)

  // 3. An assignment *is* routable, and the variable it names is the row key.
  let assigned = try Parser.parseMaybeAssignment("s = ~c", model)
  #expect(assigned?.isAssignment == true)
  #expect(assigned?.assignmentVariable == "s")
  #expect(assigned?.assignmentExpression == .not(.variable("c")))
}
