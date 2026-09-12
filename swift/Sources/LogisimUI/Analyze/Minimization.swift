// Minimization.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.analyze.gui.MinimizeButton, and the two
// call sites in com.cburch.logisim.analyze.gui.Analyzer), GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ════════════════════════════════════════════════════════════════════════════════════════════
// THE CONTROL BEHIND `OutputExpressions.forcedOptimize`
// ════════════════════════════════════════════════════════════════════════════════════════════
//
// `forcedOptimize(report:format:)` existed in Sources with no caller in Sources. It is the only
// thing that lifts `Implicant.computeMinimal`'s guard:
//
//     if nrOfInputs > maximalNrOfInputsForAutoMinimalForm && report == nil { return [] }
//                     // Implicant.swift:337, and maximalNrOfInputsForAutoMinimalForm == 6
//
// so with no caller, every circuit with more than six input bits reported its minimal
// expression as the constant `0` and there was no way to ask for the real one.
//
// ── What upstream builds, verified rather than assumed ──────────────────────────────────────
//
// `Analyzer.java:170,172` constructs **two** buttons, and the format is baked into each one,
// it is not read from any current selection:
//
//     minimizeMinterms = new MinimizeButton(this, model, AnalyzerModel.FORMAT_SUM_OF_PRODUCTS);
//     minimizeMaxterms = new MinimizeButton(this, model, AnalyzerModel.FORMAT_PRODUCT_OF_SUMS);
//
// The port's constants are `AnalyzerModel.formatSumOfProducts` (0) and
// `AnalyzerModel.formatProductOfSums` (1), `AnalyzerModel.swift:29,31`.
//
// `Analyzer.java:116-119` enables them on exactly one condition, and it is the inverse of the
// Minimized tab's:
//
//     minimizeMinterms.setEnabled(hasInputsAndOutputs
//             && (nrOfInputs > Implicant.MAXIMAL_NR_OF_INPUTS_FOR_AUTO_MINIMAL_FORM));
//     ...
//     tabbedPane.setEnabledAt(MINIMIZED_TAB, hasInputsAndOutputs
//             && (nrOfInputs <= Implicant.MAXIMAL_NR_OF_INPUTS_FOR_AUTO_MINIMAL_FORM));
//
// i.e. at ≤6 inputs the tab computes it for you and the buttons are dead; past 6 the tab is
// dead and the buttons are the only route. `canMinimize` below is that predicate.
//
// `MinimizeButton.doOptimize` then: confirms with `OptimizeLongTimeWarning` ("can take a long
// time (hours)!"), opens a modal dialog holding a monospaced white-on-black `JTextArea`, starts
// a worker thread that runs `forcedOptimize(info, format)` and reveals a `Done` button when it
// returns.
//
// ════════════════════════════════════════════════════════════════════════════════════════════
// THE THREADING DECISION, AND WHY IT IS NOT "RUN forcedOptimize ON A BACKGROUND TASK"
// ════════════════════════════════════════════════════════════════════════════════════════════
//
// `forcedOptimize` is slow precisely in the case this control exists for: it lifts the guard,
// so it runs Quine-McCluskey plus Petrick over 2^n rows. Running it on the main actor freezes
// the window for as long as that takes, which upstream's own warning string measures in hours.
// So it has to leave the main actor. The problem is what it is allowed to take with it.
//
//   * `AnalyzerModel` is **not** `Sendable`, and cannot casually be made so: it is a class graph
//     (`AnalyzerModel` → `VariableList`/`TruthTable`/`OutputExpressions`) wired with `unowned`
//     back-edges and weak listener lists (D3), living in a `.v5` language-mode module.
//   * The live model is read from the main actor on every redraw; `ExpressionsPane` calls
//     `minimalExpression(for:)` inside a SwiftUI `body`, and the body *will* run during the
//     computation, because the progress sheet animates.
//   * `forcedOptimize` mutates that same graph: `setMinimizedFormat` then `invalidate`, which
//     rewrites `minimalImplicants`, `minimalExpr`, `expr`, `exprString` and fires listeners.
//
// A worker touching the live model is therefore an unsynchronised write against a live main-
// actor read. `@unchecked Sendable` or `nonisolated(unsafe)` on the model silences the compiler
// and ships exactly that race, which is the one thing this must not do.
//
// **What is done instead.** `forcedOptimize` is a pure function of four things: the input
// variables, the output variables, the output columns, and the format. All four are `Sendable`
// value types already (`Var`, `Entry`, `Int`). So:
//
//     main actor            worker (Task.detached)                 main actor
//     ──────────            ──────────────────────                 ──────────
//     snapshot the    ───►  build a PRIVATE AnalyzerModel     ───►  store [String: Expression]
//     live model's          from the snapshot, run                  + the report text
//     four values           forcedOptimize on THAT
//
// The private `AnalyzerModel`, its `OutputExpressions` and the `MinimizationReport` are all
// created inside the detached task and never escape it, so no non-`Sendable` value crosses an
// isolation boundary in either direction and nothing is `@unchecked`. The live model is never
// written at all; the answer is layered over it in the presentation (see
// `AnalyzerPresentation.minimalExpressionText`), which is also what makes re-analysing a
// circuit correctly discard a stale minimisation.
//
// This is sound only because the port's minimisation is deterministic. Upstream iterates
// `HashSet<Implicant>` and its answer follows that iteration; the port replaced every
// result-affecting traversal with `ImplicantSet`'s sorted one *specifically* so the same table
// gives the same expression on every run (see `Implicant.swift`'s note). Without that, "compute
// it again over there" would be a different answer, not the same one.
//
// Rejected alternatives, both viable, both larger than this fix:
//
//   1. **Make `AnalyzerModel` actor-isolated.** Correct, but then every read is `await`, and
//      three SwiftUI `body`s read it synchronously. That rewrites `CircuitAnalysis.swift` and
//      all three panes: outside this slice, and unnecessary for a pure computation.
//   2. **Stream progress out of the worker over an `AsyncStream`.** Genuinely safe (the
//      continuation is `Sendable`) and it is what would restore upstream's *live* text area.
//      It needs `MinimizationReport` to gain a callback: today `append(_:)` only accumulates
//      into a `String` (`Implicant.swift:180-186`), with no hook. That type is in
//      `LogisimAnalyze`, outside this slice. Recorded as the follow-up; the report text itself
//      is not lost, only its arrival time (all at the end, instead of line by line).
//
// Note for anyone tempted to "simplify" step one away: upstream streams by having the worker
// call `JTextArea.append` directly (`MinimizeButton.java:83`). `JTextArea` is a Swing component
// and that mutates its `Document` off the EDT. Upstream gets away with it; it is not a pattern
// to port.
//
// ════════════════════════════════════════════════════════════════════════════════════════════
// A DEFECT IN 4.1.0 THIS PORT DOES NOT REPRODUCE
// ════════════════════════════════════════════════════════════════════════════════════════════
//
// `forcedOptimize` iterates `outputData`, which `OutputExpressions` fills **lazily**; an entry
// appears only when something asks for that output. In upstream the thing that asks is
// `MinimizedTab.updateTab` (`getMinimalExpression(output)`, MinimizedTab.java:452), and
// `updateTab` is reached only through `MyChangeListener.stateChanged`, i.e. by selecting the
// Minimized tab, which `Analyzer.java:126` **disables** whenever `nrOfInputs > 6`. So on the
// truth-table path, in the only case where the buttons are enabled at all, `outputData` is
// empty and the button is a no-op. Measured against the 4.1.0 jar (probe reproduced verbatim in
// `AnalyzeMinimizeTests`):
//
//     n=7 SOP BEFORE=[0] AFTER=[c+a⋅b]                 <- getMinimalExpression called first
//     n=7 SOP UNTOUCHED-FIRST AFTER=[0] REPORTLEN=0    <- button pressed on a fresh model
//
// It only works when `Analyze.computeExpression` succeeded, because that path calls
// `setExpression` per output and populates the map as a side effect.
//
// `run` below therefore touches `minimalExpression(for:)` for every output bit before calling
// `forcedOptimize`. It is cheap in the exact case that matters, under the guard, with no
// report, `computeMinimal` returns `[]` immediately, and it makes the control do what its
// label says regardless of which derivation produced the table.

import LogisimAnalyze

// MARK: - What crosses the isolation boundary

/// Everything `forcedOptimize` is a function of, as `Sendable` values.
///
/// This exists so the worker never sees an `AnalyzerModel`. Every stored property is a value
/// type that already declares `Sendable` in `LogisimAnalyze`: `Var` (Var.swift:14),
/// `Entry` (Entry.swift:45), `Int`.
public struct MinimizationRequest: Sendable {
  public let inputs: [Var]
  public let outputs: [Var]
  /// One entry per output bit column, each `rowCount` long, in `outputs.bits` order.
  public let outputColumns: [[Entry]]
  /// `AnalyzerModel.formatSumOfProducts` or `.formatProductOfSums`.
  public let format: Int

  public init(inputs: [Var], outputs: [Var], outputColumns: [[Entry]], format: Int) {
    self.inputs = inputs
    self.outputs = outputs
    self.outputColumns = outputColumns
    self.format = format
  }
}

/// What comes back. `Expression` is a `Sendable` value type (Expression.swift:27).
public struct MinimizationOutcome: Sendable {
  /// The format that produced this, so the surface can say which button was pressed.
  public let format: Int
  /// Minimal expression per output bit. Missing keys mean the run produced nothing for that
  /// bit, which is what `Implicant.toExpression(implicants: nil)` returns.
  public let expressions: [String: Expression]
  /// Everything `MinimizationReport` accumulated, upstream's `JTextArea` contents.
  public let report: String
  /// Non-nil only if building the private model failed, which would mean the snapshot and the
  /// table disagreed about a column length. Surfaced rather than swallowed.
  public let failure: String?

  public init(format: Int, expressions: [String: Expression], report: String, failure: String?) {
    self.format = format
    self.expressions = expressions
    self.report = report
    self.failure = failure
  }
}

// MARK: - The two buttons

/// One of upstream's two `MinimizeButton`s. The format is a stored property, not a lookup,
/// because `Analyzer.java:170,172` bakes it into the button.
public struct MinimizeCommand: Identifiable, Sendable {
  public let id: String
  /// `minimizeMintermsButton` / `minimizeMaxtermsButton` from `analyze.properties`.
  public let title: String
  public let format: Int

  public init(id: String, title: String, format: Int) {
    self.id = id
    self.title = title
    self.format = format
  }

  /// `Analyzer.java:170`, `FORMAT_SUM_OF_PRODUCTS`.
  public static let minterms = MinimizeCommand(
    id: "minterms", title: "Optimize Minterms", format: AnalyzerModel.formatSumOfProducts)
  /// `Analyzer.java:172`, `FORMAT_PRODUCT_OF_SUMS`.
  public static let maxterms = MinimizeCommand(
    id: "maxterms", title: "Optimize Maxterms", format: AnalyzerModel.formatProductOfSums)

  /// In `buttonPanel.add` order (`Analyzer.java:192-193`).
  public static let all: [MinimizeCommand] = [.minterms, .maxterms]
}

// MARK: - The computation

/// `MinimizeButton.doOptimize`'s worker half, with no UI in it.
public enum Minimization {
  /// `OptimizeLongTimeWarning`; the confirm upstream shows before it starts, kept verbatim
  /// because "hours" is the whole point of asking.
  public static let longRunWarning =
    "Warning, optimizing logic functions with this number of inputs can take a long time "
    + "(hours)!\nDo you want to continue?"
  /// `minimizeFunctionTitle`.
  public static let title = "Optimizing logic function"
  /// `minimizeDone`.
  public static let doneLabel = "Finished optimizing logic function, click here to close window."

  /// Read the four values `forcedOptimize` depends on off a live model.
  ///
  /// Synchronous and `nonisolated`, so it runs wherever the model already is: for the window
  /// that is the main actor, and this is the last thing that touches the live model.
  public static func request(from model: AnalyzerModel, format: Int) throws -> MinimizationRequest
  {
    let table = model.truthTable
    var columns: [[Entry]] = []
    columns.reserveCapacity(table.outputColumnCount)
    for column in 0..<table.outputColumnCount {
      columns.append(try table.outputColumn(column))
    }
    return MinimizationRequest(
      inputs: model.inputs.vars, outputs: model.outputs.vars, outputColumns: columns,
      format: format)
  }

  /// Rebuild the model privately and run the minimisation on it.
  ///
  /// Everything reference-typed in here is born and dies inside this call. Callers on an actor
  /// must reach it through `perform`, not by calling it directly; a `nonisolated` synchronous
  /// function invoked from the main actor still runs *on* the main actor, which would freeze
  /// the window and defeat the entire point.
  public static func run(_ request: MinimizationRequest) -> MinimizationOutcome {
    let model = AnalyzerModel()
    let report = MinimizationReport()
    do {
      try model.setVariables(inputs: request.inputs, outputs: request.outputs)
      let table = model.truthTable
      for (column, values) in request.outputColumns.enumerated()
      where column < table.outputColumnCount {
        try table.setOutputColumn(column, values)
      }
    } catch {
      return MinimizationOutcome(
        format: request.format, expressions: [:], report: report.text,
        failure: String(describing: error))
    }

    let expressions = model.outputExpressions
    // Populate `outputData` first; see the 4.1.0 no-op note in this file's header. Under the
    // guard this costs one `computeMinimal` that returns `[]` on its first branch.
    // Red-probed: deleting this loop reproduces 4.1.0's own `UNTOUCHED-FIRST AFTER=[0]
    // REPORTLEN=0` exactly; `forcedOptimize` iterates an empty map and does nothing.
    for bit in model.outputs.bits {
      _ = expressions.minimalExpression(for: bit)
    }

    // ── THE WIRING. Everything else in this file exists to make this line reachable. ────────
    expressions.forcedOptimize(report: report, format: request.format)

    var results: [String: Expression] = [:]
    for bit in model.outputs.bits {
      if let expression = expressions.minimalExpression(for: bit) {
        results[bit] = expression
      }
    }
    return MinimizationOutcome(
      format: request.format, expressions: results, report: report.text, failure: nil)
  }

  /// `optimizeThread.start()`: get `run` off whatever actor asked for it.
  ///
  /// `Task.detached` and not `Task { }`: an unstructured child task inherits the caller's actor
  /// context, so `Task { run(request) }` from `@MainActor` would run the whole minimisation on
  /// the main actor. Detached inherits nothing. The closure captures only `request`, which is
  /// `Sendable`, and returns `MinimizationOutcome`, which is `Sendable`.
  public static func perform(_ request: MinimizationRequest) async -> MinimizationOutcome {
    await Task.detached(priority: .userInitiated) { run(request) }.value
  }
}
