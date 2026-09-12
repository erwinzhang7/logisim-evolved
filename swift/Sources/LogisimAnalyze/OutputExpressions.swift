//
//  OutputExpressions.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution, specifically
//  `src/main/java/com/cburch/logisim/analyze/model/OutputExpressions.java`,
//  `.../OutputExpressionsEvent.java` and `.../OutputExpressionsListener.java`.
//  GPL-3.0-only. See LICENSE.md.
//

/// Java: `com.cburch.logisim.analyze.model.OutputExpressionsEvent`.
public struct OutputExpressionsEvent {
  /// Java: the four int constants.
  public enum Kind: Int, Sendable {
    case allVariablesReplaced = 0
    case outputExpression = 1
    case outputMinimal = 2
    case outputVariableReplaced = 3
  }

  public unowned let model: AnalyzerModel
  public let type: Kind
  public let variable: String?
  public let data: Expression?
}

/// Java: `com.cburch.logisim.analyze.model.OutputExpressionsListener`.
public protocol OutputExpressionsListener: AnyObject {
  func expressionChanged(_ event: OutputExpressionsEvent)
}

/// Java: `com.cburch.logisim.analyze.model.OutputExpressions`; the per-output cache of "the
/// expression the user is editing" and "the minimal expression for the current truth table",
/// kept consistent with the table in both directions.
///
/// Java nests a `MyListener` implementing both listener protocols; here `OutputExpressions`
/// conforms to them directly, which removes an object and, with the weak listener lists,
/// removes the retain cycle that inner class would otherwise create under ARC (D3).
///
/// **Structural vs reference equality.** Java compares expressions with `==` in four places
/// (`expr == minimalExpr`, `expr != oldMinExpr`, `oldExpr == oldMinExpr`), which is *reference*
/// identity; its own comment says it is "for efficiency to avoid recomputation". Swift
/// `Expression` is a value type, so those become structural comparisons. The only difference
/// is that two structurally identical expressions now compare equal where Java saw two
/// objects: the port skips a redundant recomputation and a no-op change event that upstream
/// performs. `isExpressionMinimal()` also becomes correct in the case where Java reports a
/// false negative for an expression that *is* the minimal one, just freshly rebuilt.
public final class OutputExpressions {
  /// D3: the model owns this.
  private unowned let model: AnalyzerModel
  private var outputData: [String: OutputData] = [:]
  private var listeners: [WeakListenerBox<AnyObject>] = []
  private var updatingTable = false
  private var allowUpdates = false

  public init(model: AnalyzerModel) {
    self.model = model
    model.inputs.addVariableListListener(self)
    model.outputs.addVariableListListener(self)
    model.truthTable.addTruthTableListener(self)
  }

  /// Java: `OutputExpressions.OutputData`.
  private final class OutputData {
    unowned let owner: OutputExpressions
    var output: String
    var format = AnalyzerModel.formatSumOfProducts
    var expr: Expression?
    var exprString: String?
    var minimalImplicants: [Implicant]?
    var minimalExpr: Expression?
    private var invalidating = false

    init(owner: OutputExpressions, output: String) {
      self.owner = owner
      self.output = output
      invalidate(initializing: true, formatChanged: false, report: nil)
    }

    var expression: Expression? { expr }

    var expressionString: String {
      if exprString == nil {
        if expr == nil { invalidate(initializing: false, formatChanged: false, report: nil) }
        exprString = expr?.description ?? ""
      }
      return exprString!
    }

    var minimalExpression: Expression? {
      if minimalExpr == nil { invalidate(initializing: false, formatChanged: false, report: nil) }
      return minimalExpr
    }

    /// Java: `OutputData.invalidate(boolean, boolean, JTextArea)`.
    func invalidate(initializing: Bool, formatChanged: Bool, report: MinimizationReport?) {
      if invalidating { return }
      invalidating = true
      defer { invalidating = false }

      let model = owner.model
      let oldImplicants = minimalImplicants
      let oldMinExpr = minimalExpr
      minimalImplicants = Implicant.computeMinimal(
        format: format, model: model, variable: output, report: report)
      minimalExpr = Implicant.toExpression(
        format: format, model: model, implicants: minimalImplicants)
      let minChanged = !OutputExpressions.implicantsSame(oldImplicants, minimalImplicants)

      if !owner.updatingTable {
        // see whether the expression is still consistent with the truth table
        let table = model.truthTable
        let outputColumn = OutputExpressions.computeColumn(table, expr)
        let outputIndex = model.outputs.bits.firstIndex(of: output) ?? -1
        let currentColumn = (try? table.outputColumn(outputIndex)) ?? []
        if !OutputExpressions.columnsMatch(currentColumn, outputColumn)
          || OutputExpressions.isAllUndefined(outputColumn)
          || formatChanged
        {
          // if not, then we need to change the expression to maintain consistency
          let exprChanged = expr != oldMinExpr || minChanged
          expr = minimalExpr
          if exprChanged {
            exprString = nil
            if !initializing {
              owner.fireModelChanged(.outputExpression, output)
            }
          }
        }
      }

      if !initializing && minChanged {
        owner.fireModelChanged(.outputMinimal, output)
      }
    }

    var isExpressionMinimal: Bool { expr == minimalExpr }

    /// Java: `OutputData.removeInput(String)`.
    func removeInput(_ input: String) {
      let oldMinExpr = minimalExpr
      minimalImplicants = nil
      minimalExpr = nil
      if exprString != nil { exprString = nil }  // invalidate it so it recomputes
      if let oldExpr = expr {
        let newExpr: Expression?
        if oldExpr == oldMinExpr {
          newExpr = minimalExpression
          expr = newExpr
        } else {
          newExpr = oldExpr.removeVariable(input)
        }
        if newExpr == nil || newExpr != oldExpr {
          expr = newExpr
          owner.fireModelChanged(.outputExpression, output, expr)
        }
      }
      owner.fireModelChanged(.outputMinimal, output, minimalExpr)
    }

    /// Java: `OutputData.replaceInput(String, String)`.
    func replaceInput(_ input: String, _ newName: String) {
      minimalExpr = nil
      if let s = exprString {
        exprString = Parser.replaceVariable(s, input, newName)
      }
      if let current = expr {
        let newExpr = current.replaceVariable(input, newName)
        if newExpr != current {
          expr = newExpr
          owner.fireModelChanged(.outputExpression, output)
        }
      } else {
        owner.fireModelChanged(.outputExpression, output)
      }
      owner.fireModelChanged(.outputMinimal, output)
    }

    /// Java: `OutputData.setExpression(Expression, String)`.
    func setExpression(_ newExpr: Expression?, _ newExprString: String?) throws {
      expr = newExpr
      exprString = newExprString

      if expr != minimalExpr {  // for efficiency, to avoid recomputation
        let values = OutputExpressions.computeColumn(owner.model.truthTable, expr)
        let outputColumn = owner.model.outputs.bits.firstIndex(of: output) ?? -1
        owner.updatingTable = true
        defer { owner.updatingTable = false }
        try owner.model.truthTable.setOutputColumn(outputColumn, values)
      }

      owner.fireModelChanged(.outputExpression, output, expression)
    }

    /// Java: `OutputData.setMinimizedFormat(int)`.
    func setMinimizedFormat(_ value: Int) {
      if format != value {
        format = value
        invalidate(initializing: false, formatChanged: true, report: nil)
      }
    }
  }

  // MARK: - Static helpers (Java: private statics on OutputExpressions)

  /// Java: `columnsMatch(Entry[], Entry[])`; differences involving a don't-care do not
  /// count as a mismatch.
  static func columnsMatch(_ a: [Entry], _ b: [Entry]) -> Bool {
    if a.count != b.count { return false }
    for i in a.indices where a[i] != b[i] {
      let bothDefined =
        (a[i] == .zero || a[i] == .one) && (b[i] == .zero || b[i] == .one)
      if bothDefined { return false }
    }
    return true
  }

  /// Java: `computeColumn(TruthTable, Expression)`: evaluate the expression over every row.
  static func computeColumn(_ table: TruthTable, _ expr: Expression?) -> [Entry] {
    let rows = table.rowCount
    let cols = table.inputColumnCount
    guard let expr else { return [Entry](repeating: .dontCare, count: rows) }
    var values = [Entry](repeating: .dontCare, count: rows)
    var assn = Assignments()
    for i in 0..<rows {
      for j in 0..<cols {
        assn.put(table.inputHeader(j), TruthTable.isInputSet(row: i, column: j, inputs: cols))
      }
      values[i] = expr.evaluate(assn) ? .one : .zero
    }
    return values
  }

  /// Java: `implicantsSame(List<Implicant>, List<Implicant>)`.
  static func implicantsSame(_ a: [Implicant]?, _ b: [Implicant]?) -> Bool {
    guard let a else { return b?.isEmpty ?? true }
    guard let b else { return a.isEmpty }
    if a.count != b.count { return false }
    for (x, y) in zip(a, b) where x != y { return false }
    return true
  }

  /// Java: `isAllUndefined(Entry[])`.
  static func isAllUndefined(_ a: [Entry]) -> Bool {
    for entry in a where entry == .zero || entry == .one { return false }
    return true
  }

  // MARK: - Access

  /// Java: `getExpression(String)`.
  public func expression(for output: String?) -> Expression? {
    guard let output else { return nil }
    return data(for: output, create: true)?.expression
  }

  /// Java: `getExpressionString(String)`.
  public func expressionString(for output: String?) -> String {
    guard let output else { return "" }
    return data(for: output, create: true)?.expressionString ?? ""
  }

  /// Java: `getMinimalExpression(String)`.
  public func minimalExpression(for output: String?) -> Expression? {
    guard let output else { return Expressions.constant(0) }
    guard let d = data(for: output, create: true) else { return Expressions.constant(0) }
    return d.minimalExpression
  }

  /// Java: `getMinimalImplicants(String)`.
  public func minimalImplicants(for output: String?) -> [Implicant] {
    guard let output else { return Implicant.minimalList }
    guard let data = data(for: output, create: true) else { return Implicant.minimalList }
    return data.minimalImplicants ?? Implicant.minimalList
  }

  /// Java: `getMinimizedFormat(String)`.
  public func minimizedFormat(for output: String?) -> Int {
    guard let output, let data = data(for: output, create: true) else {
      return AnalyzerModel.formatSumOfProducts
    }
    return data.format
  }

  /// Java: `isExpressionMinimal(String)`.
  public func isExpressionMinimal(_ output: String) -> Bool {
    guard let data = data(for: output, create: false) else { return true }
    return data.isExpressionMinimal
  }

  /// Java: `hasExpressions()`.
  public func hasExpressions() -> Bool {
    for (_, data) in outputData where !(data.minimalImplicants ?? []).isEmpty { return true }
    return false
  }

  /// Java: `setExpression(String, Expression)` / `(String, Expression, String)`.
  public func setExpression(_ output: String?, _ expr: Expression?, _ exprString: String? = nil)
    throws
  {
    guard let output else { return }
    try data(for: output, create: true)?.setExpression(expr, exprString)
  }

  /// Java: `setMinimizedFormat(String, int)`.
  public func setMinimizedFormat(_ output: String, _ format: Int) {
    let oldFormat = minimizedFormat(for: output)
    if format != oldFormat {
      data(for: output, create: true)?.setMinimizedFormat(format)
      invalidate(output)
    }
  }

  /// Java: `forcedOptimize(JTextArea, int)`: the user-requested minimisation, which is also
  /// what lifts `computeMinimal`'s 6-input guard.
  public func forcedOptimize(report: MinimizationReport?, format: Int) {
    for output in outputData.keys.sorted() {
      guard let data = outputData[output] else { continue }
      data.setMinimizedFormat(format)
      data.invalidate(initializing: false, formatChanged: false, report: report)
    }
  }

  /// Java: `getOutputData(String, boolean)`. Upstream throws `IllegalArgumentException` for
  /// an unknown output and every caller swallows it with `catch (Exception e)`; returning
  /// `nil` says the same thing without the round trip.
  private func data(for output: String, create: Bool) -> OutputData? {
    if let ret = outputData[output] { return ret }
    guard create, model.outputs.bits.contains(output) else { return nil }
    let ret = OutputData(owner: self, output: output)
    outputData[output] = ret
    return ret
  }

  private func invalidate(_ output: String) {
    guard let data = data(for: output, create: false) else { return }
    if !allowUpdates {
      outputData[output] = nil
    } else {
      data.invalidate(initializing: false, formatChanged: false, report: nil)
    }
  }

  /// Java: `enableUpdates()` / `disableUpdates()` / `updatesEnabled()`.
  public func enableUpdates() { allowUpdates = true }
  public func disableUpdates() { allowUpdates = false }
  public var updatesEnabled: Bool { allowUpdates }

  // MARK: - Listeners

  public func addOutputExpressionsListener(_ l: OutputExpressionsListener) {
    listeners.append(WeakListenerBox(l))
  }

  public func removeOutputExpressionsListener(_ l: OutputExpressionsListener) {
    listeners.removeAll { $0.value === l || $0.value == nil }
  }

  fileprivate func fireModelChanged(
    _ type: OutputExpressionsEvent.Kind, _ variable: String? = nil, _ data: Expression? = nil
  ) {
    listeners.removeAll { $0.value == nil }
    if listeners.isEmpty { return }
    let event = OutputExpressionsEvent(
      model: model, type: type, variable: variable, data: data)
    for box in listeners {
      (box.value as? OutputExpressionsListener)?.expressionChanged(event)
    }
  }
}

// MARK: - Listening to the model

extension OutputExpressions: TruthTableListener {
  public func rowsChanged(_ event: TruthTableEvent) {
    // Do nothing.
  }

  public func cellsChanged(_ event: TruthTableEvent) {
    guard event.column < model.outputs.bits.count else { return }
    invalidate(model.outputs.bits[event.column])
  }

  public func structureChanged(_ event: TruthTableEvent) {
    // Do nothing.
  }
}

extension OutputExpressions: VariableListListener {
  public func listChanged(_ event: VariableListEvent) {
    if event.source === model.inputs {
      inputsChanged(event)
    } else {
      outputsChanged(event)
    }
  }

  /// Java: `MyListener.inputsChanged(VariableListEvent)`.
  private func inputsChanged(_ event: VariableListEvent) {
    let type = event.type
    if type == .allReplaced && !outputData.isEmpty {
      outputData.removeAll()
      fireModelChanged(.allVariablesReplaced)
      return
    }
    guard let v = event.variable else { return }
    switch type {
    case .remove:
      for input in v {
        // sorted: the callbacks these fire are observable, so their order must not depend
        // on Dictionary's per-process hash seed.
        for output in outputData.keys.sorted() {
          data(for: output, create: false)?.removeInput(input)
        }
      }
    case .replace:
      guard let index = event.index else { return }
      let newVar = model.inputs.vars[index]
      for output in outputData.keys.sorted() {
        for b in 0..<Swift.min(v.width, newVar.width) {
          data(for: output, create: false)?.replaceInput(v.bitName(b), newVar.bitName(b))
        }
        for b in newVar.width..<Swift.max(newVar.width, v.width) {
          data(for: output, create: false)?.removeInput(v.bitName(b))
        }
        if v.width < newVar.width {
          data(for: output, create: false)?
            .invalidate(initializing: false, formatChanged: false, report: nil)
        }
      }
    case .move, .add:
      for output in outputData.keys.sorted() {
        data(for: output, create: false)?
          .invalidate(initializing: false, formatChanged: false, report: nil)
      }
    case .allReplaced:
      break
    }
  }

  /// Java: `MyListener.outputsChanged(VariableListEvent)`.
  private func outputsChanged(_ event: VariableListEvent) {
    let type = event.type
    if type == .allReplaced && !outputData.isEmpty {
      outputData.removeAll()
      fireModelChanged(.allVariablesReplaced)
      return
    }
    guard let oldVar = event.variable else { return }
    switch type {
    case .remove:
      for bit in oldVar { outputData[bit] = nil }
    case .replace:
      guard let index = event.index else { return }
      let newVar = model.outputs.vars[index]
      for b in 0..<Swift.min(oldVar.width, newVar.width) {
        let oldName = oldVar.bitName(b)
        let newName = newVar.bitName(b)
        if let toMove = outputData[oldName] {
          outputData[oldName] = nil
          toMove.output = newName
          outputData[newName] = toMove
        }
      }
      for b in newVar.width..<Swift.max(newVar.width, oldVar.width) {
        outputData[oldVar.bitName(b)] = nil
      }
    case .add, .move, .allReplaced:
      break
    }
  }
}
