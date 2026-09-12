// CircuitExpressions.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.circuit.Analyze: `computeExpression`,
// `ExpressionMap`, `propagateComponents`, `propagateWires`, `checkForCircularExpressions`,
// `getDirtyComponents`, `LocationBit`),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── What this is ────────────────────────────────────────────────────────────────────────────
//
// The **symbolic** half of Analyze Circuit: it derives a boolean expression per output pin by
// walking the netlist, with no simulation and therefore no 2^n row cost at all. Upstream's
// `ProjectCircuitActions.configureAnalyzer` tries it first and falls back to `computeTable`
// only when it throws:
//
//     try   Analyze.computeExpression(...)  -> lands the window on the Expression tab
//     catch Analyze.computeTable(...)       -> lands the window on the Table tab
//
// Before this file the port had only the second branch (`LogisimUI/Analyze/CircuitAnalysis`),
// so the window could show a truth table but never an expression, a K-map cover or a minimised
// form derived from the netlist.
//
// ── The three things the brief asked to settle from the Java ────────────────────────────────
//
// **1. Where does the feature protocol live?**  `LogisimStd/Analyze/ExpressionComputer.swift`,
// beside its implementors, for the reason set out in that file's header. This driver lives
// beside it rather than in `LogisimUI` because everything it touches is in or below
// `LogisimStd`: `Circuit`/`Component` (LogisimFile), `CircuitWires` (LogisimKernel), `Pin`,
// `SplitterFactory`, `Text` and the gates (LogisimStd). The concrete expression type is the one
// thing it does *not* touch; that arrives as an `ExpressionAlgebra`.
//
// **2. What happens when the circuit is not combinational?**  Upstream does **not** hang, and
// neither does this. Two independent guards, both reproduced:
//
//   * a hard cap of `maxIterations = 100` fixpoint rounds (`Analyze.java:132-136`), which is
//     what actually stops a feedback loop; a latch never reaches a fixpoint because each round
//     wraps the output in another operator, so `dirtyPoints` never empties;
//   * `checkForCircularExpressions`, run every round, which catches an expression that has
//     become self-referential before the cap does.
//
//   Both raise `AnalyzeException.Circular` → `AnalyzeError.circular`, a D13 `throw`. There is no
//   trap and no unbounded walk anywhere in this file: every loop is bounded either by the
//   circuit's component count or by that cap.
//
//   Note what this means in practice, and it is the honest answer rather than the flattering
//   one: a sequential circuit does not produce a diagnosis of "sequential", it produces
//   `Circular`, and the caller falls back to the truth table, which is exactly what upstream
//   does, and exactly what the jar was observed doing.
//
// **3. The row cap.**  There isn't one on this path, and inventing one would be wrong. The
// 2^n cost that `TruthTableRun` and `AnalyzerModel.maxInputs` (20) exist to bound belongs to
// `computeTable`, which simulates every row. `computeExpression` is symbolic: its cost is
// linear in components × bit-width × iterations. Upstream applies `MAX_INPUTS`/`MAX_OUTPUTS`
// **once, in `doAnalyze`, before either derivation** (`ProjectCircuitActions.java:196-203`),
// and `LogisimUI/Analyze/CircuitAnalysis` already reproduces that check on the summed *bit*
// counts. The only bound inside `computeExpression` is `maxIterations = 100`. Matching upstream
// here means adding nothing.
//
// ── Ordering ────────────────────────────────────────────────────────────────────────────────
//
// Java's `dirtyPoints` is a `HashSet<LocationBit>` and `getDirtyComponents` returns a
// `HashSet<Component>`; both are iterated. Iteration order is JVM hash order and is not
// reproducible (the standing decision on `WireBundle.tempPoints`), so both are insertion-ordered
// here. Order is observable in exactly one place, which of two conflicting drivers is reported
// first by `AnalyzeException.Conflict`, and a deterministic order is strictly better there than
// an unreproducible one.
//
// ── Not ported ──────────────────────────────────────────────────────────────────────────────
//
//   * `Analyze.getPinLabels`: already ported, as `TruthTableRun.pinColumns`, and pinned against
//     1,347 jar oracles by the simulation gate. A second copy is the duplication this port keeps
//     finding; this file consumes the existing one.
//   * `Analyze.computeTable`: already ported, in `LogisimUI/Analyze/CircuitAnalysis`.

import Foundation
import LogisimFile
import LogisimKernel

// MARK: - LocationBit

/// `Analyze.LocationBit`: one bit of one connection point, the key the whole walk is indexed
/// by. Java hand-writes `equals`/`hashCode`; Swift synthesises both.
public struct LocationBit: Hashable, CustomStringConvertible {
  public let location: Location
  public let bit: Int

  public init(_ location: Location, _ bit: Int) {
    self.location = location
    self.bit = bit
  }

  public var description: String { "\(location)#\(bit)" }
}

// MARK: - The map

/// `Analyze.ExpressionMap`: a `HashMap<LocationBit, Expression>` that also records which
/// component wrote each entry (`causes`) and which entries changed (`dirtyPoints`).
///
/// The `causes` map is not bookkeeping: `propagateWires` uses it to tell "two components drive
/// this point with different expressions" (a `Conflict`) from "one component drove it twice"
/// (fine). Dropping it would make every re-derivation look like a conflict.
final class ExpressionMapStore: ExpressionComputerMap {
  let algebra: any ExpressionAlgebra

  private var storage: [LocationBit: ExpressionRef] = [:]
  private var causeOf: [LocationBit: ObjectIdentifier] = [:]

  /// `ExpressionMap.dirtyPoints`, insertion-ordered, see the file header.
  private(set) var dirtyPoints: [LocationBit] = []
  private var dirtySet: Set<LocationBit> = []

  /// `ExpressionMap.currentCause`. D4: components are compared by reference identity, so only
  /// the identity is stored; holding the component itself would be a strong edge from the walk
  /// into the netlist for no reason.
  var currentCause: ObjectIdentifier?

  init(algebra: any ExpressionAlgebra) {
    self.algebra = algebra
  }

  // MARK: ExpressionComputerMap

  func expression(at point: Location, bit: Int) -> ExpressionRef? {
    storage[LocationBit(point, bit)]
  }

  func put(_ point: Location, bit: Int, _ expression: ExpressionRef) {
    put(LocationBit(point, bit), expression)
  }

  /// `Expression put(LocationBit point, Expression expression)` (`Analyze.java:71-78`).
  ///
  /// The dirty test is `!Objects.equals(ret, expression)`: **structural**, on the previous
  /// value. Writing the same expression twice must not re-dirty the point, or the fixpoint loop
  /// never terminates and every circuit reports `Circular` after 100 rounds.
  func put(_ point: LocationBit, _ expression: ExpressionRef) {
    let previous = storage[point]
    storage[point] = expression
    if let cause = currentCause { causeOf[point] = cause }
    let unchanged = previous.map { algebra.equals($0, expression) } ?? false
    if !unchanged, dirtySet.insert(point).inserted {
      dirtyPoints.append(point)
    }
  }

  // MARK: Driver-side access

  func expression(at point: LocationBit) -> ExpressionRef? { storage[point] }

  func cause(of point: LocationBit) -> ObjectIdentifier? { causeOf[point] }

  func clearDirtyPoints() {
    dirtyPoints.removeAll(keepingCapacity: true)
    dirtySet.removeAll(keepingCapacity: true)
  }
}

// MARK: - The walk

/// The port of `com.cburch.logisim.circuit.Analyze.computeExpression`.
public enum CircuitExpressions {

  /// `Analyze.computeExpression`'s fixpoint cap (`Analyze.java:132`). This is the bound that
  /// makes a sequential circuit terminate.
  public static let maxIterations = 100

  /// One derived output column: the bit name the analyzer model keys expressions by, and the
  /// expression itself.
  public struct OutputExpression {
    /// `label` for a 1-bit pin, `label[b]` for bit *b* of a wider one: the same naming
    /// `Var`/`VariableList` use, so the result can be handed straight to
    /// `OutputExpressions.setExpression(name:)`.
    public let name: String
    /// `nil` where upstream stores a `null` expression: an output pin nothing drives.
    /// `model.getOutputExpressions().setExpression(name, null)` is legal and shows an empty row.
    public let expression: ExpressionRef?
  }

  /// The whole derivation. Ordered exactly as `Analyze.computeExpression` is.
  ///
  /// - Parameters:
  ///   - circuit: the circuit to walk.
  ///   - connectivity: the wire-connectivity engine for `circuit`, i.e.
  ///     `SimulatedCircuit(circuit).wireStore`. Passed in rather than built here so a caller
  ///     that already has one (every caller does; the table path builds one too) does not pay
  ///     for a second connectivity computation.
  ///   - columns: the pins in `Analyze.getPinLabels` order, from `TruthTableRun.pinColumns`.
  ///   - algebra: the expression constructors, supplied by whoever owns the expression type.
  /// - Returns: one entry per **output bit**, in pin order and MSB-first within a pin; the
  ///   order `VariableList.bits` produces, so index *i* of this array is bit *i* of the model's
  ///   output list. See the harvest loop for why this differs from the Java's loop direction.
  /// - Throws: `AnalyzeError`. Every case is one upstream reports and recovers from (D13).
  public static func compute(
    circuit: Circuit,
    connectivity: CircuitWires,
    columns: [TruthTableRun.PinColumn],
    algebra: any ExpressionAlgebra
  ) throws -> [OutputExpression] {
    let expressionMap = ExpressionMapStore(algebra: algebra)

    // "for (final var entry : pinNames.entrySet())": seed every *input* pin's location with a
    // fresh variable per bit, and remember the output pins for the harvest at the end.
    var outputPins: [TruthTableRun.PinColumn] = []
    for column in columns {
      let width = column.width.width
      if column.isInput {
        expressionMap.currentCause = ObjectIdentifier(column.component)
        for bit in 0..<width {
          let name = width > 1 ? "\(column.label)[\(bit)]" : column.label
          expressionMap.put(
            LocationBit(column.component.location, bit), algebra.variable(name))
        }
      } else {
        outputPins.append(column)
      }
    }

    // "propagateComponents(expressionMap, circuit.getNonWires());"
    let nonWires = circuit.nonWires
    try propagateComponents(expressionMap, nonWires)

    // The fixpoint loop, `Analyze.java:131-145`, move for move.
    let componentsByPoint = index(nonWires)
    var iterations = 0
    while !expressionMap.dirtyPoints.isEmpty {
      if iterations > CircuitExpressions.maxIterations { throw AnalyzeError.circular }
      iterations += 1

      // Java copies the dirty set before walking it, because `propagateWires` writes back into
      // `dirtyPoints` through `put`. Dropping the copy would mutate the collection being
      // iterated; a Swift array would not trap on that, it would silently walk the additions
      // too and change the result.
      let toProcess = expressionMap.dirtyPoints
      try propagateWires(expressionMap, toProcess, connectivity)

      let dirtyComponents = dirtyComponents(componentsByPoint, expressionMap.dirtyPoints)
      expressionMap.clearDirtyPoints()
      try propagateComponents(expressionMap, dirtyComponents)

      if checkForCircularExpressions(expressionMap) { throw AnalyzeError.circular }
    }

    // "for (final var pin : outputPins)"; harvest.
    //
    // **Bit order is MSB-first here and LSB-first in the Java.** Upstream's harvest loop runs
    // `for (var b = 0; b < width; b++)` and calls `setExpression(name, …)`, which is keyed by
    // *name*, so the loop's direction is unobservable there. It is observable here, because this
    // returns a list. The list is therefore ordered to match `VariableList.bits`, `q[1]`,
    // `q[0]`, which is the order the analyzer model, `Var`'s iterator and `TruthTableRun`'s
    // headers all use, so index *i* of this array is output bit *i* of the model.
    //
    // The jar confirms it: `ExprProbe` walks `model.getOutputs().bits` and prints `q[1]` before
    // `q[0]`. A first cut of this loop emitted `0..<width` and the gate caught it; a defect
    // that would have been invisible to any single-bit fixture.
    var result: [OutputExpression] = []
    for pin in outputPins {
      let width = pin.width.width
      for bit in stride(from: width - 1, through: 0, by: -1) {
        let name = width > 1 ? "\(pin.label)[\(bit)]" : pin.label
        let point = LocationBit(pin.component.location, bit)
        result.append(
          OutputExpression(name: name, expression: expressionMap.expression(at: point)))
      }
    }
    return result
  }

  // MARK: - propagateComponents

  /// `Analyze.propagateComponents` (`Analyze.java:322-338`).
  ///
  /// The `else if` ladder is the whole reason `computeExpression` fails on real circuits: a
  /// component that vends no `ExpressionComputer` and is not a pin, a splitter or a text label
  /// aborts the derivation with `CannotHandle(displayName)`. That includes every subcircuit and
  /// every TTL part, which is why the jar takes the table path on two of three corpus circuits.
  static func propagateComponents(
    _ expressionMap: ExpressionMapStore, _ components: [any Component]
  ) throws {
    for component in components {
      if let computer = component.feature(.expressionComputer) as? any ExpressionComputer {
        expressionMap.currentCause = ObjectIdentifier(component)
        do {
          try computer.computeExpression(expressionMap)
        } catch AnalyzeError.unsupported {
          // Java: `catch (UnsupportedOperationException e)` → `CannotHandle(displayName)`.
          // `XorGate` with three or more inputs is the one component in 4.1.0 that takes this
          // branch (`XorGate.xorExpression` throws for `numInputs > 2`).
          throw AnalyzeError.cannotHandle(component.factory.displayName)
        }
      } else if component.factory is Pin {
        // "pins are handled elsewhere": seeded above, harvested at the end.
      } else if component.factory is SplitterFactory {
        // "splitters are handled elsewhere": by `propagateWires`, which walks `WireThread`s,
        // and a thread passes *through* a splitter by construction.
      } else if component.factory is Text {
        // "can safely ignore"
      } else {
        throw AnalyzeError.cannotHandle(component.factory.displayName)
      }
    }
  }

  // MARK: - propagateWires

  /// `Analyze.propagateWires` (`Analyze.java:341-370`).
  ///
  /// Spreads each dirty point's expression to every other `(point, bit)` on the same
  /// `WireThread`. The thread walk itself is `CircuitWires.threadPoints(at:bit:)`; see there
  /// for why it is on that side of the module boundary.
  static func propagateWires(
    _ expressionMap: ExpressionMapStore,
    _ pointsToProcess: [LocationBit],
    _ connectivity: CircuitWires
  ) throws {
    expressionMap.currentCause = nil
    for locationBit in pointsToProcess {
      guard let expression = expressionMap.expression(at: locationBit) else { continue }
      expressionMap.currentCause = expressionMap.cause(of: locationBit)

      switch connectivity.threadPoints(at: locationBit.location, bit: locationBit.bit) {
      case .notWired:
        // Java's guard `bundle != null && bundle.isValid() && bundle.threads != null`: a point
        // with no wire attached simply propagates nowhere.
        continue
      case .incompatibleWidths:
        throw AnalyzeError.cannotHandle("incompatible widths")
      case let .points(points):
        for (point, bit) in points {
          // "if (p2.equals(locationBit.loc)) continue;"; do not write back onto the source
          // point. Java compares only the *location*, not the bit, and that asymmetry is
          // load-bearing: a splitter maps one location's bit *b* onto the same location's bit
          // *c*, and skipping the whole location is what stops a splitter feeding itself.
          if point == locationBit.location { continue }
          let target = LocationBit(point, bit)
          if let old = expressionMap.expression(at: target) {
            let oldCause = expressionMap.cause(of: target)
            if oldCause != expressionMap.currentCause, !expressionMap.algebra.equals(old, expression)
            {
              throw AnalyzeError.conflict
            }
          }
          expressionMap.put(target, expression)
        }
      }
    }
  }

  // MARK: - Dirty components

  /// A location → components-with-an-end-there index, i.e. what
  /// `circuit.getNonWires(Location)` reads out of `CircuitWires.points`.
  ///
  /// Built once per derivation rather than queried per point: `getDirtyComponents` runs every
  /// iteration, and the alternative is a linear scan of the netlist per dirty point.
  static func index(_ components: [any Component]) -> [Location: [any Component]] {
    var result: [Location: [any Component]] = [:]
    for component in components {
      var seen: Set<Location> = []
      for end in component.ends where seen.insert(end.location).inserted {
        result[end.location, default: []].append(component)
      }
    }
    return result
  }

  /// `Analyze.getDirtyComponents` (`Analyze.java:246-253`). Deduplicated by reference identity
  /// (D4), which is what Java's `HashSet<Component>` does; `Component` does not override
  /// `equals`.
  static func dirtyComponents(
    _ index: [Location: [any Component]], _ pointsToProcess: [LocationBit]
  ) -> [any Component] {
    var result: [any Component] = []
    var seen: Set<ObjectIdentifier> = []
    for point in pointsToProcess {
      for component in index[point.location] ?? [] where seen.insert(ObjectIdentifier(component)).inserted {
        result.append(component)
      }
    }
    return result
  }

  // MARK: - Circularity

  /// `Analyze.checkForCircularExpressions` (`Analyze.java:94-100`).
  ///
  /// Java returns the offending expression; the caller only tests it against `null`, so this
  /// returns the boolean directly.
  ///
  /// **This is the weaker of the two loop guards in the port, and deliberately so.** Java's
  /// `Expression.isCircular` walks the expression graph looking for a node that reaches itself,
  /// which is possible because Java's `Expression` is a mutable object graph. The port's
  /// `Expression` is an `indirect enum`, a tree, structurally incapable of a cycle, so its
  /// `isCircular` is provably `false` and this check can never fire. The `maxIterations` cap is
  /// what actually terminates a feedback loop, in both languages: a latch's expression grows by
  /// one operator per round and never converges, so `dirtyPoints` never empties. The check is
  /// kept because the algebra is a protocol and a future concrete expression type could be a
  /// graph.
  static func checkForCircularExpressions(_ expressionMap: ExpressionMapStore) -> Bool {
    for point in expressionMap.dirtyPoints {
      guard let expression = expressionMap.expression(at: point) else { continue }
      if expressionMap.algebra.isCircular(expression) { return true }
    }
    return false
  }
}
