// AnalyzeMinimizeTests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// BOARD #68; DOES THE MINIMIZE CONTROL ACTUALLY LIFT THE 6-INPUT GUARD?
//
// `Implicant.computeMinimal` refuses to run unasked past six input bits:
//
//     if nrOfInputs > maximalNrOfInputsForAutoMinimalForm && report == nil { return [] }
//                                                            // Implicant.swift:337
//
// and the only thing that passes a report is `OutputExpressions.forcedOptimize`, whose only
// caller is the control this suite tests. So the discriminating case is a circuit with MORE
// THAN SIX input bits, where the minimal expression is the guard's answer (`0`) before and the
// real one after.
//
// A test that called `forcedOptimize` directly would be a test of `forcedOptimize`, which was
// already covered and already green while the feature was unreachable. Everything below goes
// through `AnalyzerPresentation.minimize(_:)`, literally the closure the button's `Continue`
// action runs, and through `MinimizeCommand.all`, the list the button bar is built from.
// Deleting either the wiring or a command turns these red.
//
// ── Where the expected values come from ─────────────────────────────────────────────────────
//
// The 4.1.0 jar (D16), driven by a probe that reproduces `MinimizeButton.doOptimize`'s effect
// on the model exactly; `getMinimalExpression` first (that is `MinimizedTab.updateTab`, and it
// is what creates the `OutputData` entry `forcedOptimize` iterates), then
// `forcedOptimize(new JTextArea(), format)`, then `getMinimalExpression` again:
//
//     JAR=/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar
//     javac -cp "$JAR" -d out ButtonProbe.java
//     java -Djava.awt.headless=true -cp "$JAR:out" \
//         com.cburch.logisim.analyze.model.ButtonProbe
//
//     n=3 SOP BEFORE=[c+a⋅b] AFTER=[c+a⋅b]
//     n=3 POS BEFORE=[c+a⋅b] AFTER=[(a+c)⋅(b+c)]
//     n=7 SOP BEFORE=[0] AFTER=[c+a⋅b]
//     n=7 POS BEFORE=[0] AFTER=[(b+c)⋅(a+c)]
//     n=7 SOP REPORTLEN=319 REPORTHEAD=[\nOptimizing output: y\n\nFinding primes of size: 2\n…]
//     n=7 SOP UNTOUCHED-FIRST AFTER=[0] REPORTLEN=0
//
// The probe built `y = (a AND b) OR c` over `n` inputs with `a` as the most significant column,
// which is the same function and the same column order the `sevenInputAndOrCirc` fixture below
// derives from a real circuit through the real propagator.
//
// A second probe prints the cover rather than the rendered expression, because one of the four
// answers above differs from the port's by factor ORDER and the difference had to be measured:
//
//     SOP order=[16/111, 96/31]    SOP sorted=[16/111, 96/31]    SOP expr=c+a⋅b
//     POS order=[0/79, 0/47]       POS sorted=[0/47, 0/79]       POS expr=(b+c)⋅(a+c)
//
// Identical implicant sets; upstream emits them in `HashSet` iteration order, the port in
// `Implicant.<` order. See `maxtermsUsesProductOfSums` for the full argument.
//
// ── The last line of that output is a 4.1.0 defect, and it is deliberate that this port fails
//    to reproduce it ──────────────────────────────────────────────────────────────────────────
//
// `n=7 SOP UNTOUCHED-FIRST AFTER=[0] REPORTLEN=0`: pressing upstream's button on a model whose
// `outputData` map is still empty does nothing at all; `forcedOptimize` iterates that map. The
// map is filled by `MinimizedTab.updateTab`, reached only by selecting the Minimized tab, which
// `Analyzer.java:126` disables at exactly `nrOfInputs > 6`; the only case where the button is
// enabled. So upstream's button is a no-op on every circuit that took the truth-table path.
// `Minimization.run` touches every output bit first, which is why `minimizeFillsInTheAnswer…`
// below expects `c+a⋅b` and not `0`. Reported to the board rather than replicated.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimAnalyze
import LogisimFile
import LogisimKernel
import LogisimStd
import Testing

@testable import LogisimUI

// MARK: - Fixture

/// `y = (a AND b) OR c`, with four more input pins that nothing reads: **seven input bits**,
/// one past `Implicant.maximalNrOfInputsForAutoMinimalForm`.
///
/// The unused pins are the cheapest honest way to get past the guard: they widen the table to
/// 128 rows without changing the function, so the expected minimal expression is the same one
/// `AnalyzeModelTests` already pins for the 3-input version, which makes "the guard is the
/// only difference" the only thing this fixture can be measuring.
///
/// Pin order matters and is by vertical position (`Analyze.getPinLabels` sorts every pin
/// top-to-bottom before splitting inputs from outputs), so the y coordinates below are chosen
/// to give `a b c d e f g` with `y` sorted in between `b` and `c`, exactly as in `andOrCirc`.
private let sevenInputAndOrCirc = """
  <?xml version="1.0" encoding="UTF-8" standalone="no"?>
  <project source="4.1.0" version="1.0">
    <lib desc="#Wiring" name="0"/>
    <lib desc="#Gates" name="1"/>
    <main name="andor7"/>
    <options>
      <a name="gateUndefined" val="ignore"/>
      <a name="simlimit" val="1000"/>
      <a name="simrand" val="0"/>
    </options>
    <circuit name="andor7">
      <a name="circuit" val="andor7"/>
      <comp lib="0" loc="(80,100)" name="Pin">
        <a name="label" val="a"/>
      </comp>
      <comp lib="0" loc="(80,140)" name="Pin">
        <a name="label" val="b"/>
      </comp>
      <comp lib="0" loc="(80,220)" name="Pin">
        <a name="label" val="c"/>
      </comp>
      <comp lib="0" loc="(80,260)" name="Pin">
        <a name="label" val="d"/>
      </comp>
      <comp lib="0" loc="(80,300)" name="Pin">
        <a name="label" val="e"/>
      </comp>
      <comp lib="0" loc="(80,340)" name="Pin">
        <a name="label" val="f"/>
      </comp>
      <comp lib="0" loc="(80,380)" name="Pin">
        <a name="label" val="g"/>
      </comp>
      <comp lib="0" loc="(390,170)" name="Pin">
        <a name="facing" val="west"/>
        <a name="label" val="y"/>
        <a name="output" val="true"/>
      </comp>
      <comp lib="1" loc="(220,120)" name="AND Gate"/>
      <comp lib="1" loc="(340,170)" name="OR Gate"/>
      <wire from="(80,100)" to="(180,100)"/>
      <wire from="(80,140)" to="(180,140)"/>
      <wire from="(220,120)" to="(290,120)"/>
      <wire from="(290,120)" to="(290,150)"/>
      <wire from="(80,220)" to="(290,220)"/>
      <wire from="(290,190)" to="(290,220)"/>
      <wire from="(340,170)" to="(390,170)"/>
    </circuit>
  </project>
  """

/// The same circuit with three inputs; the case upstream leaves the buttons disabled for,
/// because the Minimized tab already computes it. Same file as `AnalyzeModelTests.andOrCirc`,
/// duplicated rather than shared so neither suite can silently change the other's fixture.
private let threeInputAndOrCirc = """
  <?xml version="1.0" encoding="UTF-8" standalone="no"?>
  <project source="4.1.0" version="1.0">
    <lib desc="#Wiring" name="0"/>
    <lib desc="#Gates" name="1"/>
    <main name="andor"/>
    <options>
      <a name="gateUndefined" val="ignore"/>
      <a name="simlimit" val="1000"/>
      <a name="simrand" val="0"/>
    </options>
    <circuit name="andor">
      <a name="circuit" val="andor"/>
      <comp lib="0" loc="(80,100)" name="Pin">
        <a name="label" val="a"/>
      </comp>
      <comp lib="0" loc="(80,140)" name="Pin">
        <a name="label" val="b"/>
      </comp>
      <comp lib="0" loc="(80,220)" name="Pin">
        <a name="label" val="c"/>
      </comp>
      <comp lib="0" loc="(390,170)" name="Pin">
        <a name="facing" val="west"/>
        <a name="label" val="y"/>
        <a name="output" val="true"/>
      </comp>
      <comp lib="1" loc="(220,120)" name="AND Gate"/>
      <comp lib="1" loc="(340,170)" name="OR Gate"/>
      <wire from="(80,100)" to="(180,100)"/>
      <wire from="(80,140)" to="(180,140)"/>
      <wire from="(220,120)" to="(290,120)"/>
      <wire from="(290,120)" to="(290,150)"/>
      <wire from="(80,220)" to="(290,220)"/>
      <wire from="(290,190)" to="(290,220)"/>
      <wire from="(340,170)" to="(390,170)"/>
    </circuit>
  </project>
  """

/// Does `expression` evaluate to the derived table's column on every row? An oracle-free,
/// print-order-free check that the cover is the right one.
@MainActor
private func reproducesTable(
  _ expression: LogisimAnalyze.Expression?, _ analysis: CircuitAnalysis.Analysis,
  outputBit: String
) -> Bool {
  guard let expression else { return false }
  let table = analysis.truthTable
  let column = table.outputIndex(of: outputBit)
  guard column >= 0 else { return false }
  let inputs = table.inputColumnCount
  for row in 0..<table.rowCount {
    var assignments = Assignments()
    for bit in 0..<inputs {
      assignments.put(
        table.inputHeader(bit), TruthTable.isInputSet(row: row, column: bit, inputs: inputs))
    }
    let expected = table.outputEntry(row: row, column: column) == .one
    if expression.evaluate(assignments) != expected { return false }
  }
  return true
}

@MainActor
private func present(_ text: String, circuit name: String) throws -> AnalyzerPresentation {
  LogisimFileProjectHostFactory.registerBuiltinLibrariesIfNeeded()
  let file = try #require(try Loader().openLogisimFile(data: Data(text.utf8)))
  let circuit = try #require(file.circuit(named: name))
  // Not `.shared`: one per test, so the suite cannot depend on ordering.
  let presentation = AnalyzerPresentation()
  presentation.analyze(circuit: circuit, file: file)
  return presentation
}

// MARK: - Suite

@MainActor
@Suite("Analyze — the Minimize control (board #68)")
struct AnalyzeMinimizeTests {

  @Test("Seven input bits: the guard hides the minimal expression until the button asks")
  func minimizeFillsInTheAnswerTheGuardWithheld() async throws {
    let presentation = try present(sevenInputAndOrCirc, circuit: "andor7")
    let analysis = try #require(presentation.analysis)

    // The premise: past six inputs, and therefore under the guard.
    #expect(analysis.truthTable.inputColumnCount == 7)
    #expect(analysis.truthTable.inputColumnCount > Implicant.maximalNrOfInputsForAutoMinimalForm)
    #expect(analysis.truthTable.rowCount == 128)

    // BEFORE. jar: `n=7 SOP BEFORE=[0]`; `computeMinimal` returned `[]` on the guard, and
    // `toExpression(SOP, [])` is the constant 0.
    #expect(presentation.minimalExpression(for: "y")?.toString() == "0")

    // The button. This is the closure the Continue action of the confirm dialog runs.
    let outcome = try #require(await presentation.minimize(.minterms))

    // AFTER. jar: `n=7 SOP AFTER=[c+a⋅b]`.
    #expect(outcome.failure == nil)
    #expect(outcome.expressions["y"]?.toString() == "c+a⋅b")
    #expect(presentation.minimalExpression(for: "y")?.toString() == "c+a⋅b")
    #expect(presentation.isMinimizing == false)
    // Order-free corroboration: the cover reproduces all 128 rows of the derived column.
    #expect(reproducesTable(outcome.expressions["y"], analysis, outputBit: "y"))
  }

  @Test("The format is baked into the button, so Maxterms yields product-of-sums")
  func maxtermsUsesProductOfSums() async throws {
    // `Analyzer.java:170,172` constructs two buttons with the format fixed per button; it is
    // never read from current state. `MinimizeCommand.all` is that pair, in `buttonPanel.add`
    // order, and is what the button bar iterates.
    #expect(MinimizeCommand.all.count == 2)
    #expect(MinimizeCommand.all.map(\.format) == [0, 1])
    #expect(MinimizeCommand.minterms.format == AnalyzerModel.formatSumOfProducts)
    #expect(MinimizeCommand.maxterms.format == AnalyzerModel.formatProductOfSums)

    let presentation = try present(sevenInputAndOrCirc, circuit: "andor7")
    #expect(presentation.minimalExpression(for: "y")?.toString() == "0")

    // ── A DOCUMENTED DIVERGENCE, MEASURED, NOT ASSUMED ────────────────────────────────────
    //
    // jar: `n=7 POS BEFORE=[0] AFTER=[(b+c)⋅(a+c)]`. The port prints `(a+c)⋅(b+c)`.
    //
    // Same two factors, opposite order, and this is the `ImplicantSet` decision showing up in
    // an assertion for the first time (see `Implicant.swift`'s header). A second probe against
    // the same jar prints the cover itself:
    //
    //     POS order=[0/79, 0/47]      <- HashSet iteration order; the JLS does not fix it
    //     POS sorted=[0/47, 0/79]
    //     POS expr=(b+c)⋅(a+c)
    //
    // The SET is identical, `0/47` is `(a+c)`, `0/79` is `(b+c)`, so the two expressions are
    // the same cover, and the port emits it in `Implicant.<` order because Swift's `Set` is
    // seeded per process and a literal port would have given a *different answer on different
    // runs of the same binary*. Corroboration that the port's order is upstream's own and not
    // invented: at three inputs the jar itself prints `(a+c)⋅(b+c)`, the string expected here.
    //
    // At `n=3` the jar's iteration happened to agree with sorted order; at `n=7` it did not.
    // That is exactly the property `ImplicantSet` exists to remove.
    let outcome = try #require(await presentation.minimize(.maxterms))
    #expect(outcome.format == AnalyzerModel.formatProductOfSums)
    #expect(outcome.expressions["y"]?.toString() == "(a+c)⋅(b+c)")
    #expect(presentation.minimalExpression(for: "y")?.toString() == "(a+c)⋅(b+c)")

    // And the assertion that does not care about print order at all: the minimised expression
    // reproduces the derived truth-table column on all 128 rows. If the cover were wrong rather
    // than merely differently ordered, this is what would catch it.
    let analysis = try #require(presentation.analysis)
    #expect(reproducesTable(outcome.expressions["y"], analysis, outputBit: "y"))
  }

  @Test("The run narrates into the report, and the report is what reaches the sheet")
  func theReportIsPopulated() async throws {
    let presentation = try present(sevenInputAndOrCirc, circuit: "andor7")
    let outcome = try #require(await presentation.minimize(.minterms))

    // jar: `REPORTHEAD=[\nOptimizing output: y\n\nFinding primes of size: 2\nNone…]`.
    // `MinimizationReport` is the port of the `JTextArea` the run appends to, and before this
    // control existed it was constructed nowhere in Sources.
    #expect(outcome.report.hasPrefix("\nOptimizing output: y\n"))
    #expect(outcome.report.contains("Finding primes of size: 2"))
    #expect(presentation.reportPresented)
  }

  @Test("The worker never touches the live model — the answer is layered over it")
  func theLiveModelIsUntouched() async throws {
    let presentation = try present(sevenInputAndOrCirc, circuit: "andor7")
    let analysis = try #require(presentation.analysis)
    _ = try #require(await presentation.minimize(.minterms))

    // `Minimization.run` builds a private `AnalyzerModel` inside the detached task, so the
    // model the three SwiftUI panes read from the main actor is byte-for-byte what it was.
    // If this ever starts returning `c+a⋅b`, the worker is writing the live graph and the
    // whole threading argument in Minimization.swift has been undone.
    #expect(analysis.minimalExpression(for: "y")?.toString() == "0")
    // …while the presentation, which is what the pane actually asks, has the real answer.
    #expect(presentation.minimalExpression(for: "y")?.toString() == "c+a⋅b")
  }

  @Test("Enablement mirrors Analyzer.java:116-119 — dead at ≤6 inputs, live past it")
  func enablementMirrorsUpstream() throws {
    let seven = try present(sevenInputAndOrCirc, circuit: "andor7")
    #expect(seven.canMinimize)

    // Three inputs: upstream leaves both buttons disabled, because the Minimized tab is the
    // one that is enabled there and it minimises unasked.
    let three = try present(threeInputAndOrCirc, circuit: "andor")
    #expect(three.analysis?.truthTable.inputColumnCount == 3)
    #expect(three.canMinimize == false)
    // jar: `n=3 SOP BEFORE=[c+a⋅b]`: already minimal without asking, which is why the button
    // has nothing to add and upstream disables it.
    #expect(three.minimalExpression(for: "y")?.toString() == "c+a⋅b")

    // Nothing analysed at all: no model, no buttons.
    #expect(AnalyzerPresentation().canMinimize == false)
  }

  @Test("Re-analysing discards a stale minimisation")
  func reanalysingClearsTheOutcome() async throws {
    let presentation = try present(sevenInputAndOrCirc, circuit: "andor7")
    _ = try #require(await presentation.minimize(.minterms))
    #expect(presentation.minimization != nil)

    // The outcome is keyed by output-bit NAME. A different circuit with a `y` would otherwise
    // inherit this one's expression.
    LogisimFileProjectHostFactory.registerBuiltinLibrariesIfNeeded()
    let file = try #require(try Loader().openLogisimFile(data: Data(threeInputAndOrCirc.utf8)))
    let circuit = try #require(file.circuit(named: "andor"))
    presentation.analyze(circuit: circuit, file: file)

    #expect(presentation.minimization == nil)
    #expect(presentation.reportPresented == false)
    #expect(presentation.minimalExpression(for: "y")?.toString() == "c+a⋅b")
  }
}
