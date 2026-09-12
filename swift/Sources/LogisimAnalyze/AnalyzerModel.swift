//
//  AnalyzerModel.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution, specifically
//  `src/main/java/com/cburch/logisim/analyze/model/AnalyzerModel.java`. GPL-3.0-only.
//  See LICENSE.md.
//

/// Java: `com.cburch.logisim.analyze.model.AnalyzerModel`: the root of the analyzer's model
/// graph: the input and output variable lists, the truth table over them, and the cached
/// per-output expressions.
///
/// Java also carries `currentProject`/`currentCircuit` so the "build circuit" action knows
/// where to put its result. Those are `com.cburch.logisim.proj.Project` and
/// `.circuit.Circuit`, which live above this module; the seam is left to whoever ports
/// `analyze/gui/BuildCircuitButton`.
///
/// Ownership (D3): the model owns the two variable lists, the table and the expression cache.
/// Every edge back, `TruthTable.model`, `OutputExpressions.model`, is `unowned`, and both
/// listener registrations are weak, so the whole graph deallocates when the model does.
public final class AnalyzerModel {
  /// Java: `MAX_INPUTS`. The truth table is dense in the inputs, so this bounds a column at
  /// `2^20` cells; see `TruthTable`'s note on the cost.
  public static let maxInputs = 20
  /// Java: `MAX_OUTPUTS`.
  public static let maxOutputs = 256

  /// Java: `FORMAT_SUM_OF_PRODUCTS`.
  public static let formatSumOfProducts = 0
  /// Java: `FORMAT_PRODUCT_OF_SUMS`.
  public static let formatProductOfSums = 1

  /// Java: `getInputs()`.
  public let inputs = VariableList(maxSize: AnalyzerModel.maxInputs)
  /// Java: `getOutputs()`.
  public let outputs = VariableList(maxSize: AnalyzerModel.maxOutputs)

  private var storedTable: TruthTable!
  private var storedOutputExpressions: OutputExpressions!

  /// Java: `getTruthTable()`.
  public var truthTable: TruthTable { storedTable }
  /// Java: `getOutputExpressions()`.
  public var outputExpressions: OutputExpressions { storedOutputExpressions }

  public init() {
    // The order matters, exactly as upstream notes: the output expressions listen to the
    // truth table, so the table has to exist first.
    storedTable = TruthTable(model: self)
    storedOutputExpressions = OutputExpressions(model: self)
  }

  /// Java: `setVariables(List<Var>, List<Var>)`.
  public func setVariables(inputs newInputs: [Var], outputs newOutputs: [Var]) throws {
    try inputs.setAll(newInputs)
    try outputs.setAll(newOutputs)
  }
}
