// ExpressionComputer.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.circuit.ExpressionComputer and
// com.cburch.logisim.circuit.AnalyzeException),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Where this lives, and why it cannot live anywhere else ──────────────────────────────────
//
// `ExpressionComputer` is the feature that makes the Analyze window's **Expression** tab work:
// upstream derives a boolean expression per output by walking the netlist and asking each
// component what it contributes, with no simulation at all. Its four implementors are
// `AbstractGate` (all eight symmetric gates), `NotGate`, `Buffer` and `Constant`; every one of
// them a `LogisimStd` component. A protocol whose entire implementor set is in `LogisimStd`
// belongs in `LogisimStd`; declaring it above (in `LogisimUI`, beside `CircuitAnalysis`) is the
// exact mistake board #23 records for `TextEditable`, `WireRepair` and `CustomHandles`, where
// the protocol ended up somewhere no implementor could see and therefore had no conformers at
// all. `InstancePoker`, in `LogisimStd/Instance/`, is the shape that works, and this file
// follows it.
//
// ── Why the expression type is abstracted, rather than imported ─────────────────────────────
//
// The one thing upstream's interface names that this module genuinely cannot see is
// `com.cburch.logisim.analyze.model.Expression`. Its port is `LogisimAnalyze.Expression`, and
// `LogisimStd` does not depend on `LogisimAnalyze`, nor should it acquire the dependency
// casually: that edge puts the analysis model *underneath* the component library, and
// `Package.swift` is owner-held (the edge is reported as a diff in this task's summary rather
// than taken unilaterally).
//
// So the expression is abstracted behind two small types:
//
//   * `ExpressionRef`: an opaque handle. A component never inspects one; it only receives
//     handles for its input ports and hands a handle back for its output port. That is exactly
//     the contract upstream's components honour anyway; none of the four implementors calls
//     anything on an `Expression` except to pass it to `Expressions.and/or/xor/not`.
//   * `ExpressionAlgebra`: the six constructors (`variable`, `constant`, `not`, `and`, `or`,
//     `xor`) plus the two predicates the driver needs (`equals`, `isCircular`), supplied by
//     whoever owns the concrete expression type.
//
// The cost is one indirection; the benefit is that the module graph is unchanged and the
// component library stays ignorant of the analyzer, which is what D9 is for. `Constant`'s
// conformance is **not** here; `LogisimStd/Wiring/Constant.swift` is outside this task's
// ownership; see the summary for its exact diff.
//
// ── Not ported ──────────────────────────────────────────────────────────────────────────────
//
//   * Nothing. `ExpressionComputer.java` is 30 lines and all of it is here, with the nested
//     `ExpressionComputer.Map` becoming `ExpressionComputerMap` (Swift has no nested protocols).

import Foundation
import LogisimFile
import LogisimKernel

// MARK: - The opaque expression handle

/// A `com.cburch.logisim.analyze.model.Expression`, seen from a module that cannot name one.
///
/// Reference-wrapped so that identity is cheap and so the concrete type can be a Swift `enum`
/// (`LogisimAnalyze.Expression` is an `indirect enum`, which is a value type and cannot be an
/// `AnyObject` on its own).
///
/// **Equality goes through the algebra, not through this type.** Upstream compares expressions
/// with `Expression.equals`, which is structural; two distinct boxes can hold equal expressions,
/// and `ExpressionMap`'s dirty tracking depends on getting that right. Hence no `Equatable`
/// conformance here; `ExpressionAlgebra.equals(_:_:)` is the only sanctioned comparison.
public struct ExpressionRef {
  public let boxed: AnyObject

  public init(_ boxed: AnyObject) { self.boxed = boxed }
}

/// The expression constructors and predicates the analyze walk needs, supplied by the module
/// that owns the concrete expression type.
///
/// Java calls these as statics on `Expressions`; the port routes them through an object so the
/// concrete type stays above this module. The three-argument shapes upstream never uses
/// (`Expressions.eq`, `Expressions.xnor`) are deliberately absent: no `ExpressionComputer` in
/// 4.1.0 builds one: `XnorGate` builds `not(xor(...))` and `NorGate` builds `not(or(...))`.
public protocol ExpressionAlgebra: AnyObject {
  /// `Expressions.variable(String)`.
  func variable(_ name: String) -> ExpressionRef
  /// `Expressions.constant(int)`.
  func constant(_ value: Int) -> ExpressionRef
  /// `Expressions.not(Expression)`.
  func not(_ operand: ExpressionRef) -> ExpressionRef
  /// `Expressions.and(Expression, Expression)`.
  func and(_ lhs: ExpressionRef, _ rhs: ExpressionRef) -> ExpressionRef
  /// `Expressions.or(Expression, Expression)`.
  func or(_ lhs: ExpressionRef, _ rhs: ExpressionRef) -> ExpressionRef
  /// `Expressions.xor(Expression, Expression)`.
  func xor(_ lhs: ExpressionRef, _ rhs: ExpressionRef) -> ExpressionRef

  /// `Objects.equals(a, b)` on two expressions, structural, not identity.
  func equals(_ lhs: ExpressionRef, _ rhs: ExpressionRef) -> Bool
  /// `Expression.isCircular()`.
  func isCircular(_ expression: ExpressionRef) -> Bool
}

// MARK: - The feature

/// `com.cburch.logisim.circuit.ExpressionComputer.Map`.
///
/// The map from `(Location, bit)` to expression that the walk threads through the circuit. A
/// component reads its input ports out of it and writes its output ports into it.
public protocol ExpressionComputerMap: AnyObject {
  /// `Expression get(Location point, int bit)`.
  func expression(at point: Location, bit: Int) -> ExpressionRef?
  /// `Expression put(Location point, int bit, Expression expression)`.
  func put(_ point: Location, bit: Int, _ expression: ExpressionRef)
  /// The constructors to build new expressions with. Java reaches the `Expressions` statics
  /// directly; here they arrive with the map, which is the only object a computer is handed.
  var algebra: any ExpressionAlgebra { get }
}

/// `com.cburch.logisim.circuit.ExpressionComputer`.
///
/// Vended through `Component.feature(.expressionComputer)`. Upstream's contract: "if, in fact,
/// no valid expression exists for the component, it throws `UnsupportedOperationException`";
/// becomes `throw AnalyzeError.unsupported`, which the driver converts into
/// `AnalyzeError.cannotHandle(displayName)` exactly as `Analyze.propagateComponents` does.
/// D13: this is a condition upstream reports in a dialog and recovers from, so it throws.
public protocol ExpressionComputer: AnyObject {
  /// `void computeExpression(Map expressionMap)`.
  func computeExpression(_ expressionMap: any ExpressionComputerMap) throws
}

/// A computer built from a closure, so a factory can vend one without a named class: the
/// Swift equivalent of upstream's `return (ExpressionComputer) expressionMap -> { … }` lambda.
public final class ClosureExpressionComputer: ExpressionComputer {
  private let body: (any ExpressionComputerMap) throws -> Void

  public init(_ body: @escaping (any ExpressionComputerMap) throws -> Void) {
    self.body = body
  }

  public func computeExpression(_ expressionMap: any ExpressionComputerMap) throws {
    try body(expressionMap)
  }
}

// MARK: - Errors

/// `com.cburch.logisim.circuit.AnalyzeException` and its three nested subclasses.
///
/// D13: every one of these is caught by `ProjectCircuitActions.configureAnalyzer`, which falls
/// back to the truth-table derivation and shows the window anyway. A trap here would turn
/// "this circuit needs the table path" into a crash.
public enum AnalyzeError: Error, Equatable, CustomStringConvertible {
  /// `AnalyzeException.CannotHandle(reason)`. The reason is the component's display name for
  /// the no-feature case, and the literal `"incompatible widths"` for the bus-width case,
  /// both verbatim from upstream.
  case cannotHandle(String)
  /// `AnalyzeException.Circular`: a self-referential expression, or the 100-iteration cap.
  case circular
  /// `AnalyzeException.Conflict`: two different components drive the same point with two
  /// different expressions.
  case conflict
  /// Java's `UnsupportedOperationException` thrown from inside a computer. Never escapes:
  /// `CircuitExpressions.propagateComponents` catches it and rethrows `.cannotHandle`.
  case unsupported(String)

  public var description: String {
    switch self {
    case let .cannotHandle(reason):
      // Java: `analyzeCannotHandleError` = "Computing truth table instead of expression due to
      // {0}.": the message the jar prints, reproduced so the two can be diffed.
      return "Computing truth table instead of expression due to \(reason)."
    case .circular:
      return "The circuit's expression is self-referential; it cannot be analyzed."
    case .conflict:
      return "The circuit contains conflicting values on the same wire."
    case let .unsupported(what):
      return "\(what) cannot be expressed as a boolean expression."
    }
  }
}
