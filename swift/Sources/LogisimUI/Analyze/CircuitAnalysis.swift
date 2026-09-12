// CircuitAnalysis.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.circuit.Analyze and
// com.cburch.logisim.gui.menu.ProjectCircuitActions.doAnalyze / configureAnalyzer),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── What this is ────────────────────────────────────────────────────────────────────────────
//
// The missing half of "Analyze Circuit". `LogisimAnalyze` ports the whole analyze *model*, 22
// files: truth tables, Quine-McCluskey/Petrick minimisation, K-map grouping, the expression
// parser and printer, the CSV/TeX writers, and every one of them is measured against the 4.1.0
// jar by `LogisimAnalyzeTests`. What it never had was a way in from a `Circuit`. Upstream's way
// in is `com.cburch.logisim.circuit.Analyze`, which lives in the *circuit* package, not the
// analyze one, and it had not been ported at all. Consequence: nothing in the app imported
// `LogisimAnalyze`, so the feature was 22 files of correct, unreachable code.
//
// ── Why this file is in LogisimUI and still contains no UI ──────────────────────────────────
//
// The derivation needs three things at once: `Circuit`/`Component` (LogisimFile), `Pin` and a
// live `SimulationSession` (LogisimStd), and `AnalyzerModel` (LogisimAnalyze). `LogisimAnalyze`
// deliberately depends on LogisimKernel and LogisimFile only: "it consumes circuits rather than
// defining components", so it cannot see `Pin`, and inverting that to let it would put the
// analysis model *under* the component library, which is the wrong direction. LogisimUI is the
// lowest module that already sees all three.
//
// So this type is in LogisimUI but is **not UI** (D9): no SwiftUI, no AppKit, no `@MainActor`,
// no colour, no geometry. It is callable from a test with nothing on screen, and
// `AnalyzeModelTests` calls it exactly that way. The window is a separate file.
//
// ── The gap, stated plainly ─────────────────────────────────────────────────────────────────
//
// Upstream's `configureAnalyzer` tries **two** derivations, in order:
//
//   1. `Analyze.computeExpression`; walks the netlist symbolically and produces a boolean
//      expression per output directly, with no simulation. It works by asking each component
//      for its `ExpressionComputer` feature.
//   2. `Analyze.computeTable`: the fallback: build a fresh root `CircuitState`, drive every
//      input combination through the real propagator, and record the outputs as a truth table.
//
// **Both are reachable as of 2026-09-06.** This paragraph used to read "Only (2) is reachable
// here. `ExpressionComputer` is not ported… Nothing vends the feature", and it went stale the
// day the feature landed: `AbstractGate:148`, `NotGate:127` and `Buffer:150` all vend
// `.expressionComputer` now, `LogisimStd/Analyze/CircuitExpressions` walks the netlist, and
// `ExpressionDerivation` fills in the algebra with the real `Expression` type.
//
// What was missing was only the last hop. `deriveExpressions` was defined once in Sources and
// called **zero** times there, four times from `AnalyzeDerivedExpressionTests` and nowhere
// else, so `Derivation.netlistExpressions` was never produced by any `return` in `analyze`.
// Three complete layers and no consumer: the same shape as seams #17, #22 and #25, and the
// reason `deadseam.py` exists.
//
// The measured cost below is unchanged and still worth reading: most circuits take the table
// path in upstream too, so wiring (1) changes what a minority of circuits show on the
// Expression tab, not what any of them compute.
//
// That costs less than it looks like, and the number is measured rather than guessed. Running
// the 4.1.0 jar's own `Analyze.computeExpression` over corpus circuits (the probe is in
// `docs/experiments/analyze-wiring.md`), it **throws `AnalyzeException.CannotHandle` the moment
// the circuit contains any component without the feature**, which includes every subcircuit and
// every TTL part. Measured over three corpus circuits: the one built only from primitive gates
// returned an expression, and the two that instantiate a subcircuit or a TTL chip both threw,
// reporting "Computing truth table instead of expression due to <the offending component>".
//
// Two of three take the table path in upstream too. And the expressions the analyzer *shows* on
// its Minimized tab are derived from the truth table by `OutputExpressions.getMinimalExpression`
// in both paths: on the circuit where the netlist path succeeded, its expression and the
// table-derived minimal expression came back as the same string. So the user-visible loss is
// confined to the Expression tab's *unminimised* form on circuits built purely from primitive
// gates.
//
// The circuits are named, and their derived expressions printed, in neither this comment nor the
// experiment note. They are coursework, and a minimised expression for a named lab exercise is
// its answer; this repository is public and its author teaches the course.
//
// ── What is faithfully reproduced ───────────────────────────────────────────────────────────
//
//   * `Analyze.getPinLabels`' canonical column order and default labelling, by calling
//     `TruthTableRun.pinColumns` rather than re-deriving it. That routine is already pinned
//     against the jar by the simulation gate (1,347 oracles). Two implementations of one
//     ordering is the seam pattern this port keeps finding; there is one here.
//   * `doAnalyze`'s `MAX_INPUTS` (20) and `MAX_OUTPUTS` (256) guards, which are checked on the
//     summed *bit* counts and before any simulation happens.
//   * `computeTable`'s fresh root `CircuitState` per row: upstream's design, and what makes the
//     table combinational.
//   * The oscillation branch: every output column gets `OSCILLATE_ERROR` for that row.
//   * `Entry` mapping: TRUE→ONE, FALSE→ZERO, ERROR→BUS_ERROR, anything else→DONT_CARE.

import Foundation
import LogisimAnalyze
import LogisimFile
import LogisimKernel
import LogisimStd

/// The port of `ProjectCircuitActions.doAnalyze` + `Analyze.computeTable`.
///
/// Deliberately not `@MainActor`: it is model code and its test runs off the main actor.
public enum CircuitAnalysis {

  // MARK: - Errors

  /// D13: every one of these is a condition upstream reports to the user in a dialog and
  /// recovers from, so it is a `throw` rather than a trap.
  public enum Failure: Error, CustomStringConvertible {
    /// Java: `analyzeTooManyInputsError`. Checked on the summed bit count, not the pin count.
    case tooManyInputs(bits: Int, limit: Int)
    /// Java: `analyzeTooManyOutputsError`.
    case tooManyOutputs(bits: Int, limit: Int)

    public var description: String {
      switch self {
      case let .tooManyInputs(bits, limit):
        return
          "This circuit has \(bits) input bits; the analysis window supports at most \(limit)."
      case let .tooManyOutputs(bits, limit):
        return
          "This circuit has \(bits) output bits; the analysis window supports at most \(limit)."
      }
    }
  }

  // MARK: - Result

  /// Which of upstream's two derivations produced the model.
  public enum Derivation: Sendable, Equatable {
    /// `Analyze.computeTable`: simulate every input combination. The only one available here.
    case truthTable
    /// `Analyze.computeExpression`; symbolic walk of the netlist. Not reachable: see the file
    /// header. The case exists so a later port of `ExpressionComputer` has a name to fill in
    /// rather than a boolean to invert.
    case netlistExpressions
  }

  /// Everything the analyzer window needs, and nothing that needs a window to exist.
  public struct Analysis {
    public let circuitName: String
    public let model: AnalyzerModel
    /// The pins, in `Analyze.getPinLabels` order, with the label each was given.
    public let columns: [TruthTableRun.PinColumn]
    public let derivation: Derivation
    /// False exactly when upstream would have stopped on the Inputs/Outputs tab: a circuit with
    /// no input pins or no output pins has no table to compute.
    public let tableComputed: Bool

    public var inputVariables: [Var] { model.inputs.vars }
    public var outputVariables: [Var] { model.outputs.vars }

    /// **Hold the `Analysis` for as long as you hold this.** D3 puts `TruthTable.model` on an
    /// `unowned` edge, so `let t = analyze(…).truthTable` releases the model on the same line
    /// and every subsequent read traps. That is not hypothetical; it crashed the whole test
    /// bundle the first time this suite ran.
    public var truthTable: TruthTable { model.truthTable }

    /// The minimal expression for one output bit, as the Minimized tab shows it.
    /// Qualified: Foundation also declares an `Expression`, and an unqualified reference is
    /// ambiguous for type lookup here.
    public func minimalExpression(for outputBit: String) -> LogisimAnalyze.Expression? {
      model.outputExpressions.minimalExpression(for: outputBit)
    }
  }

  // MARK: - Entry point

  /// `ProjectCircuitActions.doAnalyze(Project, Circuit)`, minus the window.
  ///
  /// `file` supplies the `<options>` so `simrand`/`simlimit` match what the canvas simulates
  /// with; passing `nil` uses the defaults, as `SimulationSession(file:)` does.
  public static func analyze(circuit: Circuit, file: LogisimFile?) throws -> Analysis {
    let columns = TruthTableRun.pinColumns(of: circuit)
    let inputs = columns.filter(\.isInput)
    let outputs = columns.filter { !$0.isInput }

    // `new Var(label, width)` per pin, in the sorted-pin order. Note that upstream iterates the
    // single `pinNames` map once and appends to two lists, so within each list the vertical
    // order survives; filtering the same sorted array is the same thing.
    let inputVars = inputs.map { Var($0.label, $0.width.width) }
    let outputVars = outputs.map { Var($0.label, $0.width.width) }

    let inputBits = inputVars.reduce(0) { $0 + $1.width }
    let outputBits = outputVars.reduce(0) { $0 + $1.width }
    guard inputBits <= AnalyzerModel.maxInputs else {
      throw Failure.tooManyInputs(bits: inputBits, limit: AnalyzerModel.maxInputs)
    }
    guard outputBits <= AnalyzerModel.maxOutputs else {
      throw Failure.tooManyOutputs(bits: outputBits, limit: AnalyzerModel.maxOutputs)
    }

    let model = AnalyzerModel()
    try model.setVariables(inputs: inputVars, outputs: outputVars)

    // "If there are no inputs or outputs, we stop with that tab selected."
    guard !inputVars.isEmpty, !outputVars.isEmpty else {
      return Analysis(
        circuitName: circuit.name, model: model, columns: columns,
        derivation: .truthTable, tableComputed: false)
    }

    // ── (1) `Analyze.computeExpression`, tried first, exactly as `configureAnalyzer` does ────
    //
    // `deriveExpressions` was reachable only from tests: defined once in Sources, called zero
    // times there, four times from `AnalyzeDerivedExpressionTests`. Three layers were complete,
    // `AbstractGate`/`NotGate`/`Buffer` vend `.expressionComputer`, `CircuitExpressions` walks
    // the netlist, `ExpressionDerivation` fills in the algebra, and nothing consumed the top of
    // the stack, so `.netlistExpressions` was never produced by either `return` below it.
    //
    // Setting the expressions is what populates the table on this path: `OutputData.setExpression`
    // evaluates the expression over every row and calls `truthTable.setOutputColumn`
    // (`OutputExpressions.swift:184-188`), which is why `tableComputed` is true here and the
    // Table tab is not empty when the Expression tab is the one that succeeded.
    //
    // Only `AnalyzeError` falls through. Upstream catches `AnalyzeException` and nothing wider,
    // and its three cases are all ordinary: `.cannotHandle` for any component without the
    // feature (every subcircuit, every TTL part, a multiplexer), `.circular` for a feedback loop,
    // `.conflict` for two drivers disagreeing. A propagator failure is not one of them and must
    // not be silently downgraded into "take the table path".
    do {
      let derived = try deriveExpressions(circuit: circuit)
      for entry in derived {
        try model.outputExpressions.setExpression(entry.name, entry.expression)
      }
      return Analysis(
        circuitName: circuit.name, model: model, columns: columns,
        derivation: .netlistExpressions, tableComputed: true)
      // MODULE-QUALIFIED, and it has to be: `AnalyzeError` is declared in **both**
      // `LogisimStd/Analyze/ExpressionComputer.swift:151` and
      // `LogisimAnalyze/AnalyzeStrings.swift:230`, and this file imports both, so the bare name
      // is ambiguous for type lookup. `CircuitExpressions` throws the LogisimStd one. Fourth
      // same-name collision in this port: Java's packages keep these apart for free.
    } catch is LogisimStd.AnalyzeError {
      // Fall through to (2). Upstream logs "Computing truth table instead of expression due to
      // <component>." here; the reason travels in the error and no surface consumes it yet.
    }

    // ── (2) `Analyze.computeTable`: the fallback, and the common case ──────────────────────
    let session = SimulationSession(file: file)
    try computeTable(
      into: model, circuit: circuit, inputs: inputs, outputs: outputs,
      inputBits: inputBits, outputBits: outputBits, session: session)

    return Analysis(
      circuitName: circuit.name, model: model, columns: columns,
      derivation: .truthTable, tableComputed: true)
  }

  // MARK: - Analyze.computeTable

  /// `Analyze.computeTable(AnalyzerModel, Project, Circuit, Map<Instance,String>)`.
  ///
  /// The variable lists are assumed already installed on `model`; upstream sets them at the end
  /// instead, which is equivalent because `setOutputColumn` is what consumes them and it runs
  /// after. Setting them first lets `TruthTable.rowCount` be asked for here.
  ///
  /// This is deliberately a second loop rather than a call into `TruthTableRun.run`: upstream
  /// has the same two loops (`Analyze.computeTable` and `TtyInterface.doTableAnalysis`) because
  /// one produces `Entry[][]` and the other produces padded text. What is NOT duplicated is the
  /// part that actually diverges, the pin ordering and labelling, which comes from
  /// `TruthTableRun.pinColumns` in both. `AnalyzeTableTests.tableAgreesWithTheTtyTablePath`
  /// pins the two against each other so they cannot drift.
  static func computeTable(
    into model: AnalyzerModel,
    circuit: Circuit,
    inputs: [TruthTableRun.PinColumn],
    outputs: [TruthTableRun.PinColumn],
    inputBits: Int,
    outputBits: Int,
    session: SimulationSession
  ) throws {
    // `1 << inputCount`. No Java `int` masking dance here, unlike `TruthTableRun`: `doAnalyze`
    // has already refused anything past MAX_INPUTS = 20, so the shift distance is in range by
    // construction and the row count is at most 1,048,576.
    let rowCount = 1 << inputBits
    var columnData = [[Entry]](
      repeating: [Entry](repeating: .dontCare, count: rowCount), count: outputBits)

    for row in 0..<rowCount {
      // Fresh root state per row: upstream, inside the loop. This is what makes the table
      // combinational: nothing survives from one input combination to the next.
      let circuitState = session.createRootState(for: circuit)
      let propagator = circuitState.propagator

      var incol = 0
      for pin in inputs {
        let width = pin.width.width
        var bits = [Value](repeating: .falseValue, count: width)
        for b in stride(from: width - 1, through: 0, by: -1) {
          let set = TruthTable.isInputSet(row: row, column: incol, inputs: inputBits)
          incol += 1
          bits[b] = set ? .trueValue : .falseValue
        }
        if let state = instanceState(of: pin, in: circuitState) {
          Pin.driveInputPin(state, try Value.create(bits))
        }
      }

      _ = try propagator.propagate()

      if propagator.isOscillating {
        for j in 0..<outputBits { columnData[j][row] = .oscillateError }
        continue
      }

      var outcol = 0
      for pin in outputs {
        let width = pin.width.width
        let value =
          instanceState(of: pin, in: circuitState).map { Pin.getValue($0) } ?? .nilValue
        for b in stride(from: width - 1, through: 0, by: -1) {
          columnData[outcol][row] = entry(for: value.get(b))
          outcol += 1
        }
      }
    }

    for (index, column) in columnData.enumerated() {
      try model.truthTable.setOutputColumn(index, column)
    }
  }

  /// The unvalidated reusable instance state, exactly as `circuitState.getInstanceState(pin)`
  /// hands back in Java. Same call `TruthTableRun` makes.
  private static func instanceState(
    of pin: TruthTableRun.PinColumn, in circuitState: CircuitState
  ) -> InstanceStateImpl? {
    guard let simComponent = pin.component as? any SimComponent else { return nil }
    return circuitState.unvalidatedReusableInstanceState(for: simComponent) as? InstanceStateImpl
  }

  /// Java's `if (outValue == Value.TRUE) ONE else if (== FALSE) ZERO else if (== ERROR)
  /// BUS_ERROR else DONT_CARE`. Note UNKNOWN lands on DONT_CARE, which is upstream's choice and
  /// is why an unconnected output pin reads as `-` rather than `U` in the analyzer.
  private static func entry(for bit: Value) -> Entry {
    if bit == .trueValue { return .one }
    if bit == .falseValue { return .zero }
    if bit == .errorValue { return .busError }
    return .dontCare
  }
}
