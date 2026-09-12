// ExpressionDerivation.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.analyze.model.Expressions, as the concrete
// algebra `com.cburch.logisim.circuit.Analyze` builds its expressions with),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── The join, and why it is thirty lines ────────────────────────────────────────────────────
//
// `LogisimStd/Analyze/CircuitExpressions` is the port of `Analyze.computeExpression`. It walks
// the netlist and builds one boolean expression per output bit: but it never names an
// `Expression`, because `LogisimStd` does not depend on `LogisimAnalyze` and should not: that
// edge would put the analysis model underneath the component library. It works through
// `ExpressionAlgebra`, an eight-method protocol standing for `Expressions`' constructors.
//
// This file is the one place in the tree that sees both, so it is where the algebra is filled
// in with the real type. `LogisimUI` is the lowest module that depends on `LogisimStd` and
// `LogisimAnalyze` at once; the same argument `CircuitAnalysis`'s header makes for the table
// path, and D9 is satisfied the same way: there is no UI in this file, no SwiftUI, no AppKit,
// no `@MainActor`, and its test runs with nothing on screen.
//
// ── Nothing simplifies ──────────────────────────────────────────────────────────────────────
//
// `Expressions.and/or/xor/not` build a node and stop (`Expressions.java:288-343`); none of them
// applies De Morgan's law or any other identity. So a NAND gate derives `~(a⋅b)`, not `~a+~b`.
// That is easy to get wrong from the far end, because reading the result back out of a populated
// `AnalyzerModel` gives you the Quine–McCluskey minimisation instead: see
// `LogisimStdTests/AnalyzeExpressionTests`' header, where it cost a rewritten oracle.
//
// The one behaviour they do have is nil-propagation, and it is load-bearing: `Expressions.or(a,
// null)` returns `a` rather than a half-built node. The port's `Expressions` reproduces it with
// `Expression?`, which is why every method here has a fallback.

import Foundation
import LogisimAnalyze
import LogisimFile
import LogisimKernel
import LogisimStd

/// `com.cburch.logisim.analyze.model.Expressions`, as an `ExpressionAlgebra`.
public final class AnalyzeExpressionAlgebra: ExpressionAlgebra {

  public init() {}

  /// Boxes the `indirect enum` so it can travel as an `ExpressionRef`.
  private final class Box {
    let expression: LogisimAnalyze.Expression
    init(_ expression: LogisimAnalyze.Expression) { self.expression = expression }
  }

  private func wrap(_ expression: LogisimAnalyze.Expression) -> ExpressionRef {
    ExpressionRef(Box(expression))
  }

  /// Force-unwrapped deliberately: an `ExpressionRef` reaching this algebra can only have been
  /// produced by this algebra: `CircuitExpressions` never constructs one itself and never
  /// mixes two algebras in one walk. A wrong box here is a programmer error no `.circ` file can
  /// cause, which is D13's carve-out for keeping a trap.
  private func unwrap(_ ref: ExpressionRef) -> LogisimAnalyze.Expression {
    (ref.boxed as! Box).expression
  }

  /// The `Expression?` that upstream's constructors return, collapsed. Every call site here
  /// passes non-nil operands, so the fallback is unreachable in practice; it exists so the
  /// nil-propagating signature does not have to leak into `ExpressionAlgebra`, whose callers
  /// (the gates) have already done their own `if (e != null)` filtering.
  private func or(
    _ produced: LogisimAnalyze.Expression?, else fallback: LogisimAnalyze.Expression
  ) -> ExpressionRef {
    wrap(produced ?? fallback)
  }

  public func variable(_ name: String) -> ExpressionRef { wrap(Expressions.variable(name)) }

  public func constant(_ value: Int) -> ExpressionRef { wrap(Expressions.constant(value)) }

  public func not(_ operand: ExpressionRef) -> ExpressionRef {
    let inner = unwrap(operand)
    return or(Expressions.not(inner), else: inner)
  }

  public func and(_ lhs: ExpressionRef, _ rhs: ExpressionRef) -> ExpressionRef {
    let a = unwrap(lhs)
    return or(Expressions.and(a, unwrap(rhs)), else: a)
  }

  public func or(_ lhs: ExpressionRef, _ rhs: ExpressionRef) -> ExpressionRef {
    let a = unwrap(lhs)
    return or(Expressions.or(a, unwrap(rhs)), else: a)
  }

  public func xor(_ lhs: ExpressionRef, _ rhs: ExpressionRef) -> ExpressionRef {
    let a = unwrap(lhs)
    return or(Expressions.xor(a, unwrap(rhs)), else: a)
  }

  /// `Objects.equals`. `Expression` is `Hashable` with synthesised structural `==`, which is
  /// what Java's per-subclass `equals` amounts to. Identity would be wrong: the fixpoint loop
  /// re-derives the same expression for a point every round, and comparing boxes would leave it
  /// permanently dirty and report `Circular` on every circuit after 100 rounds.
  public func equals(_ lhs: ExpressionRef, _ rhs: ExpressionRef) -> Bool {
    unwrap(lhs) == unwrap(rhs)
  }

  /// `Expression.isCircular()`. Provably `false` for an `indirect enum`, which is a tree; the
  /// port documents that on `Expression` itself. `CircuitExpressions` keeps calling it anyway,
  /// as upstream does, and relies on the 100-iteration cap for actual termination.
  public func isCircular(_ expression: ExpressionRef) -> Bool { unwrap(expression).isCircular }

  /// Reads a finished handle back out. The only consumer is the derivation's own result.
  public func expression(_ ref: ExpressionRef) -> LogisimAnalyze.Expression { unwrap(ref) }
}

// MARK: - The derivation, in `Expression` terms

extension CircuitAnalysis {

  /// One output bit's derived expression. `nil` where nothing drives the pin: upstream stores a
  /// `null` there and `OutputExpressions` accepts it.
  public struct DerivedExpression: Sendable {
    /// The model's bit name: `y`, or `q[1]` for bit 1 of a 2-bit pin.
    public let name: String
    public let expression: LogisimAnalyze.Expression?
  }

  /// `Analyze.computeExpression`, with the real expression type filled in.
  ///
  /// Returns one entry per output bit in `VariableList.bits` order, so it lines up index for
  /// index with `model.outputs.bits`.
  ///
  /// - Throws: `AnalyzeError`. Upstream catches all three cases in `configureAnalyzer` and falls
  ///   back to the truth table, which is what makes this safe to try first:
  ///   `.cannotHandle` for any component without an `ExpressionComputer` (every subcircuit,
  ///   every TTL part, a multiplexer), `.circular` for a feedback loop, `.conflict` for two
  ///   drivers disagreeing on one wire.
  public static func deriveExpressions(circuit: Circuit) throws -> [DerivedExpression] {
    let algebra = AnalyzeExpressionAlgebra()
    let derived = try CircuitExpressions.compute(
      circuit: circuit,
      connectivity: SimulatedCircuit(circuit).wireStore,
      columns: TruthTableRun.pinColumns(of: circuit),
      algebra: algebra)
    return derived.map {
      DerivedExpression(name: $0.name, expression: $0.expression.map(algebra.expression))
    }
  }
}
