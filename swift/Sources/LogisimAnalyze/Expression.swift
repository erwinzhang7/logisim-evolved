//
//  Expression.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution, specifically
//  `src/main/java/com/cburch/logisim/analyze/model/Expression.java` and
//  `.../Expressions.java`. GPL-3.0-only. See LICENSE.md.
//

/// Java: `com.cburch.logisim.analyze.model.Expression` plus the eight package-private
/// subclasses in `Expressions`.
///
/// **The visitor goes away.** Java double-dispatches through `Visitor<T>` and a second,
/// unrelated `IntVisitor`, because a Java `abstract class` has no other way to case-split on
/// its own subclasses. Swift has one, so this is an `indirect enum` and every former visitor
/// is an ordinary `switch`. Nothing is lost in the translation:
///
/// | Java | here |
/// |---|---|
/// | `Binary.equals` compares `getClass()` then both operands | distinct enum cases, synthesised `==` |
/// | `Variable.equals` compares the name | `case variable(String)` |
/// | `Constant.equals` compares the value | `case constant(Int)` |
/// | `hashCode` mixes the class in | synthesised `hash(into:)` discriminates on the case |
/// | `visit(Visitor)` / `visit(IntVisitor)` | `switch self` |
///
/// The one thing an enum cannot represent is a *cyclic* expression graph, which is why
/// `isCircular` is provably `false` here; see its documentation.
public indirect enum Expression: Hashable, CustomStringConvertible, Sendable {
  /// Java: `Expressions.Variable`.
  case variable(String)
  /// Java: `Expressions.Constant`.
  case constant(Int)
  /// Java: `Expressions.Not`.
  case not(Expression)
  /// Java: `Expressions.And`.
  case and(Expression, Expression)
  /// Java: `Expressions.Or`.
  case or(Expression, Expression)
  /// Java: `Expressions.Xor`.
  case xor(Expression, Expression)
  /// Java: `Expressions.Xnor`.
  case xnor(Expression, Expression)
  /// Java: `Expressions.Eq`.
  case eq(Expression, Expression)

  // MARK: - Op

  /// Java: `Expression.Op`. The `id` is a column index into `Notation.opLvl`/`opSym`, so the
  /// raw values are load-bearing.
  public enum Op: Int, CaseIterable, Sendable {
    case eq = 0
    case xnor = 1
    case or = 2
    case xor = 3
    case and = 4
    case not = 5

    /// Java: `Op.arity`.
    public var arity: Int { self == .not ? 1 : 2 }
    /// Java: `Op.id`.
    public var id: Int { rawValue }
  }

  /// Java: `getOp()`, `null` for a leaf.
  public var op: Op? {
    switch self {
    case .variable, .constant: return nil
    case .not: return .not
    case .and: return .and
    case .or: return .or
    case .xor: return .xor
    case .xnor: return .xnor
    case .eq: return .eq
    }
  }

  /// The operands of a binary node, or `nil` for `not`/leaves. Convenience for the ports of
  /// Java's `visitBinary`.
  public var binaryOperands: (Expression, Expression)? {
    switch self {
    case let .and(a, b), let .or(a, b), let .xor(a, b), let .xnor(a, b), let .eq(a, b):
      return (a, b)
    default:
      return nil
    }
  }

  // MARK: - Precedence

  /// Java: `getPrecedence(Notation)`. Leaves bind tightest (`Integer.MAX_VALUE`).
  public func precedence(in notation: Notation) -> Int {
    guard let op else { return Int(Int32.max) }
    return notation.opLevel[op.id]
  }

  // MARK: - Queries

  /// Java: `contains(Op)`.
  ///
  /// Faithful, including the quirk: Java's search visitor overrides `visitNot` to recurse
  /// **without testing `o == Op.NOT`**, so `contains(Op.NOT)` is always false no matter how
  /// many NOTs the tree holds. Upstream never notices: its only caller
  /// (`gui/BuildCircuitButton.java:79`) asks about `XOR` and `EQ`. Reproduced rather than
  /// "fixed" so a future caller sees the same answer the Java gives it.
  public func contains(_ o: Op) -> Bool {
    switch self {
    case .variable, .constant:
      return false
    case let .not(a):
      return a.contains(o)
    case let .and(a, b):
      return o == .and || a.contains(o) || b.contains(o)
    case let .or(a, b):
      return o == .or || a.contains(o) || b.contains(o)
    case let .xor(a, b):
      return o == .xor || a.contains(o) || b.contains(o)
    case let .xnor(a, b):
      return o == .xnor || a.contains(o) || b.contains(o)
    case let .eq(a, b):
      return o == .eq || a.contains(o) || b.contains(o)
    }
  }

  /// Java: `evaluate(Assignments)`.
  ///
  /// Java computes in `int` and only inspects bit 0 at the end, so `~` sets 31 irrelevant
  /// high bits along the way. `Int32` here keeps that arithmetic bit-identical.
  ///
  /// Note `visitEq`: Java writes `~(a ^ b & 1)`, which by Java's precedence is `~(a ^ (b & 1))`
  /// : the `& 1` binds to `b`, not to the whole XOR. It still yields the correct EQ in bit 0,
  /// which is the only bit read, so it is kept verbatim rather than tidied.
  public func evaluate(_ assignments: Assignments) -> Bool {
    (evaluateInt(assignments) & 1) != 0
  }

  private func evaluateInt(_ assignments: Assignments) -> Int32 {
    switch self {
    case let .variable(name):
      return assignments.get(name) ? 1 : 0
    case let .constant(value):
      return Int32(truncatingIfNeeded: value)
    case let .not(a):
      return ~a.evaluateInt(assignments)
    case let .and(a, b):
      return a.evaluateInt(assignments) & b.evaluateInt(assignments)
    case let .or(a, b):
      return a.evaluateInt(assignments) | b.evaluateInt(assignments)
    case let .xor(a, b):
      return a.evaluateInt(assignments) ^ b.evaluateInt(assignments)
    case let .xnor(a, b):
      return ~(a.evaluateInt(assignments) ^ b.evaluateInt(assignments))
    case let .eq(a, b):
      return ~(a.evaluateInt(assignments) ^ (b.evaluateInt(assignments) & 1))
    }
  }

  /// Java: `isCircular()`.
  ///
  /// Java walks the tree with a `HashSet<Expression>` of ancestors and reports a loop if it
  /// re-enters one. Because `Expression.equals` is structural and the tree is finite, a
  /// proper subexpression is strictly smaller than any ancestor and can never equal one, so
  /// upstream's answer is always `false` too, on any graph its own API can build. An
  /// `indirect enum` additionally makes a genuine cycle unrepresentable. The walk is kept
  /// rather than hard-coding `false` so the claim stays testable.
  public var isCircular: Bool {
    var visited: Set<Expression> = [self]
    return Expression.circularWalk(self, &visited)
  }

  private static func circularWalk(_ e: Expression, _ visited: inout Set<Expression>) -> Bool {
    switch e {
    case .variable, .constant:
      return false
    case let .not(a):
      if !visited.insert(a).inserted { return true }
      if circularWalk(a, &visited) { return true }
      visited.remove(a)
      return false
    default:
      guard let (a, b) = e.binaryOperands else { return false }
      if !visited.insert(a).inserted { return true }
      if circularWalk(a, &visited) { return true }
      visited.remove(a)
      if !visited.insert(b).inserted { return true }
      if circularWalk(b, &visited) { return true }
      visited.remove(b)
      return false
    }
  }

  /// Java: `isCnf()`: nominally conjunctive normal form. `level` mirrors the visitor's
  /// field: 0 = top, 1 = inside an AND, 2 = inside a NOT. Any XOR/XNOR/EQ disqualifies.
  ///
  /// Upstream's level test reads inverted: `visitOr` rejects anything at `level > 0`, and
  /// `visitAnd` sets `level = 1` before descending, so a textbook CNF such as
  /// `(a + b) * (c + d)` answers **false**. Ported verbatim, bug included: `isCnf` feeds the
  /// analyzer's "expression is already minimal" hint, and changing the answer here would
  /// silently change which expressions the UI offers to rewrite.
  public var isCnf: Bool {
    Expression.cnfWalk(self, level: 0)
  }

  private static func cnfWalk(_ e: Expression, level: Int) -> Bool {
    switch e {
    case .variable, .constant:
      return true
    case let .and(a, b):
      if level > 1 { return false }
      return cnfWalk(a, level: 1) && cnfWalk(b, level: 1)
    case let .or(a, b):
      if level > 0 { return false }
      // Java does NOT change `level` for OR, so a nested OR stays legal.
      return cnfWalk(a, level: level) && cnfWalk(b, level: level)
    case let .not(a):
      if level == 2 { return false }
      return cnfWalk(a, level: 2)
    case .xor, .xnor, .eq:
      return false
    }
  }

  // MARK: - Rewrites

  /// Java: `removeVariable(String)`; drops every occurrence of `input`, collapsing a binary
  /// node to whichever side survives. Returns `nil` when nothing is left (Java returns
  /// `null`).
  public func removeVariable(_ input: String) -> Expression? {
    switch self {
    case let .variable(name):
      return name == input ? nil : .variable(name)
    case let .constant(value):
      return .constant(value)
    case let .not(a):
      return Expressions.not(a.removeVariable(input))
    case let .and(a, b):
      return Expressions.and(a.removeVariable(input), b.removeVariable(input))
    case let .or(a, b):
      return Expressions.or(a.removeVariable(input), b.removeVariable(input))
    case let .xor(a, b):
      return Expressions.xor(a.removeVariable(input), b.removeVariable(input))
    case let .xnor(a, b):
      return Expressions.xnor(a.removeVariable(input), b.removeVariable(input))
    case let .eq(a, b):
      return Expressions.eq(a.removeVariable(input), b.removeVariable(input))
    }
  }

  /// Java: `replaceVariable(String, String)`. Total: never returns `null`.
  public func replaceVariable(_ oldName: String, _ newName: String) -> Expression {
    switch self {
    case let .variable(name):
      return .variable(name == oldName ? newName : name)
    case let .constant(value):
      return .constant(value)
    case let .not(a):
      return .not(a.replaceVariable(oldName, newName))
    case let .and(a, b):
      return .and(a.replaceVariable(oldName, newName), b.replaceVariable(oldName, newName))
    case let .or(a, b):
      return .or(a.replaceVariable(oldName, newName), b.replaceVariable(oldName, newName))
    case let .xor(a, b):
      return .xor(a.replaceVariable(oldName, newName), b.replaceVariable(oldName, newName))
    case let .xnor(a, b):
      return .xnor(a.replaceVariable(oldName, newName), b.replaceVariable(oldName, newName))
    case let .eq(a, b):
      return .eq(a.replaceVariable(oldName, newName), b.replaceVariable(oldName, newName))
    }
  }

  // MARK: - Assignments (`out = expr`)

  /// Java: `Expression.isAssignment(Expression)`.
  public var isAssignment: Bool {
    if case let .eq(a, _) = self, case .variable = a { return true }
    return false
  }

  /// Java: `Expression.getAssignmentVariable(Expression)`.
  public var assignmentVariable: String? {
    if case let .eq(a, _) = self, case let .variable(name) = a { return name }
    return nil
  }

  /// Java: `Expression.getAssignmentExpression(Expression)`.
  public var assignmentExpression: Expression? {
    if case let .eq(a, b) = self, case .variable = a { return b }
    return nil
  }

  // MARK: - Text

  /// Java: `toString()`, mathematical notation.
  public var description: String { toString(.mathematical) }

  /// Java: `toString(Notation)` / `toString(Notation, boolean)`.
  public func toString(_ notation: Notation = .mathematical, reduce: Bool = false) -> String {
    render(notation, reduce: reduce).text
  }
}

/// Java: `com.cburch.logisim.analyze.model.Expressions`: the static factory that treats
/// `null` as an identity element, so callers can fold over a list without a special first
/// case. Kept as free functions with the same names and the same `nil` handling.
public enum Expressions {
  /// Java: `Expressions.and(a, b)`; returns the other operand when one is `null`.
  public static func and(_ a: Expression?, _ b: Expression?) -> Expression? {
    guard let a else { return b }
    guard let b else { return a }
    return .and(a, b)
  }

  public static func or(_ a: Expression?, _ b: Expression?) -> Expression? {
    guard let a else { return b }
    guard let b else { return a }
    return .or(a, b)
  }

  public static func xor(_ a: Expression?, _ b: Expression?) -> Expression? {
    guard let a else { return b }
    guard let b else { return a }
    return .xor(a, b)
  }

  public static func xnor(_ a: Expression?, _ b: Expression?) -> Expression? {
    guard let a else { return b }
    guard let b else { return a }
    return .xnor(a, b)
  }

  public static func eq(_ a: Expression?, _ b: Expression?) -> Expression? {
    guard let a else { return b }
    guard let b else { return a }
    return .eq(a, b)
  }

  /// Java: `Expressions.not(a)`, `null` in, `null` out.
  public static func not(_ a: Expression?) -> Expression? {
    guard let a else { return nil }
    return .not(a)
  }

  public static func constant(_ value: Int) -> Expression { .constant(value) }

  public static func variable(_ name: String) -> Expression { .variable(name) }
}

/// Java: `com.cburch.logisim.analyze.model.Assignments`; the variable environment
/// `Expression.evaluate` reads. An unset variable is `false`, exactly as Java's
/// `map.get(name) != null && value`.
public struct Assignments: Hashable, Sendable {
  private var map: [String: Bool] = [:]

  public init() {}

  public func get(_ variable: String) -> Bool { map[variable] ?? false }

  public mutating func put(_ variable: String, _ value: Bool) { map[variable] = value }
}
