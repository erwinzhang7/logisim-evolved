// CircuitMutator.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.circuit.{CircuitMutator, CircuitMutatorImpl,
// CircuitTransactionResult}), https://github.com/logisim-evolution/logisim-evolution. Copyright by
// the Logisim-evolution developers. This translation is a derivative work and is therefore
// GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// Ported from the **4.1.0** tree (D16).
//
// ── The one door into the netlist ───────────────────────────────────────────────────────────
//
// `CircuitMutatorImpl` is the only thing in the editing layer that calls `Circuit.mutatorAdd`,
// `mutatorRemove` or `mutatorClear`, and the only thing that writes a component's attributes as
// part of an edit. That is not stylistic. Three separate mechanisms are wired to it and all
// three break silently if an edit goes round the side:
//
//   1. **Undo.** Every call appends to `log`, and `reverseTransaction()` replays that log
//      backwards. A direct `circuit.mutatorAdd(c)` produces a component on screen that Ctrl-Z
//      cannot remove, and, worse, that the *next* undo will try to reverse against a model
//      that no longer matches its recorded state.
//   2. **Simulation.** `replacements` accumulates a per-circuit `ReplacementMap`, delivered at
//      `TRANSACTION_DONE`; that is how `CircuitState` carries a component's simulation data onto
//      its replacement when a wire is split or a gate's width changes. Bypass it and the
//      component silently resets.
//   3. **The dirty flag.** `Project.doAction` names the document state from the action log and
//      publishes that single answer to the file. An edit outside a transaction leaves the file
//      looking saved when it is not.
//
// So: a direct mutation of `Circuit` that bypasses a transaction is a defect even when the
// screen looks right. If you need a new kind of edit, add a `CircuitChange.Kind`, not a call.
//
// ── D13 ─────────────────────────────────────────────────────────────────────────────────────
//
// Every method here `throws`, because `Circuit.mutatorAdd` and `AttributeSet.setValue` do. The
// error propagates out through `CircuitTransaction.execute()` and `Action.doIt` to
// `Project.doAction`, which is where the editing layer can report it. Note the ordering
// consequence: a throw part-way through a transaction leaves the circuit half-mutated, exactly
// as an exception does in Java. That is deliberate; the alternative is a rollback path that has
// never been tested against the oracle and would itself have to mutate the circuit to unwind.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.circuit.CircuitMutator`.
public protocol CircuitMutator: AnyObject {
  func add(_ circuit: Circuit, _ component: any Component) throws
  func clear(_ circuit: Circuit) throws
  func remove(_ circuit: Circuit, _ component: any Component) throws
  func replace(
    _ circuit: Circuit, _ oldComponent: any Component, _ newComponent: any Component) throws
  func replace(_ circuit: Circuit, _ replacements: ReplacementMap) throws
  func set(
    _ circuit: Circuit, _ component: any Component, _ attribute: AnyAttribute,
    _ value: AttributeValue?) throws
  func setForCircuit(
    _ circuit: Circuit, _ attribute: AnyAttribute, _ value: AttributeValue?) throws
}

/// `com.cburch.logisim.circuit.CircuitMutatorImpl`.
public final class CircuitMutatorImpl: CircuitMutator {

  /// `log`; every change actually applied, in order. Reversing this list is undo.
  private var log: [CircuitChange] = []

  /// `replacements`: one accumulated map per circuit touched.
  ///
  /// D4: identity-keyed, with the circuit carried in the value. `Circuit` has no `Hashable`
  /// conformance and must not gain one.
  private var replacements: [ObjectIdentifier: (circuit: Circuit, map: ReplacementMap)] = [:]

  /// `modified`; the circuits this transaction changed, in first-touch order.
  ///
  /// Insertion-ordered rather than a `HashSet`, for the reason in `ReplacementMap`'s header:
  /// Java's iteration order here derives from identity hash codes and is not reproducible, and
  /// this set drives the order in which `TRANSACTION_DONE` is fired. Determinism is worth more
  /// than bug-compatibility with an order that is not stable in the original either.
  private var modifiedOrder: [ObjectIdentifier] = []
  private var modifiedCircuits: [ObjectIdentifier: Circuit] = [:]

  public init() {}

  // MARK: - CircuitMutator

  public func add(_ circuit: Circuit, _ component: any Component) throws {
    markModified(circuit)
    log.append(.add(circuit, component))

    let repl = ReplacementMap()
    try repl.add(component)
    map(for: circuit).append(repl)

    try circuit.mutatorAdd(component)
  }

  public func clear(_ circuit: Circuit) throws {
    // Upstream builds a `HashSet` of non-wires and wires; `Circuit.components` is already that
    // union in a defined order (components first, then wires).
    let components = circuit.components
    if !components.isEmpty { markModified(circuit) }
    // The populated form; the only one `reversed()` can undo. See `CircuitChange.reversed`.
    log.append(.clear(circuit, components))

    let repl = ReplacementMap()
    for component in components { try repl.remove(component) }
    map(for: circuit).append(repl)

    circuit.mutatorClear()
  }

  public func remove(_ circuit: Circuit, _ component: any Component) throws {
    // The `contains` guard is upstream's, and it is worth knowing that **`CircuitMutation` never
    // reaches it**. `CircuitChange.execute` batches a `.remove` into the pending
    // `ReplacementMap` and it lands in `replace(_:_:)` below, which has no such guard, so
    // `mutation.remove(componentNotInThisCircuit)` really does log a reversible change, and
    // undoing it adds a component the circuit never had.
    //
    // That is Java's behaviour, verified rather than assumed: `Circuit.mutatorRemove`
    // (`Circuit.java:834`) has no containment check either, and `CircuitMutatorImpl.replace`
    // calls it unconditionally. Ported as-is. This method's guard is only live for a direct
    // mutator call, which today means the wire-repair seam.
    guard circuit.contains(component) else { return }
    markModified(circuit)
    log.append(.remove(circuit, component))

    let repl = ReplacementMap()
    try repl.remove(component)
    map(for: circuit).append(repl)

    circuit.mutatorRemove(component)
  }

  public func replace(
    _ circuit: Circuit, _ oldComponent: any Component, _ newComponent: any Component
  ) throws {
    try replace(circuit, ReplacementMap(old: oldComponent, new: newComponent))
  }

  public func replace(_ circuit: Circuit, _ repl: ReplacementMap) throws {
    guard !repl.isEmpty else { return }
    markModified(circuit)
    log.append(.replace(circuit, repl))

    repl.freeze()
    map(for: circuit).append(repl)

    // Removals first, then additions: upstream's order, and it matters. A wire split removes
    // one wire and adds two that occupy the same locations; adding first would make
    // `CircuitWireStore` see a duplicate and drop the new wire on the floor.
    for component in repl.removals {
      circuit.mutatorRemove(component)
    }
    for component in repl.additions {
      try circuit.mutatorAdd(component)
    }
  }

  public func set(
    _ circuit: Circuit, _ component: any Component, _ attribute: AnyAttribute,
    _ value: AttributeValue?
  ) throws {
    guard circuit.contains(component) else { return }
    markModified(circuit)
    // D5: read and write through the erased pair, so this file never has to recover `V`.
    let attributes = component.attributeSet
    let oldValue = attributes.rawValue(attribute)
    // Logged *before* the write, so a throwing `setRawValue` leaves no log entry claiming a
    // change that did not happen.
    log.append(.set(circuit, component, attribute, oldValue, value))
    try attributes.setRawValue(attribute, value)
  }

  public func setForCircuit(
    _ circuit: Circuit, _ attribute: AnyAttribute, _ value: AttributeValue?
  ) throws {
    // Note upstream does *not* call `markModified` here, and neither does this. A change to a
    // circuit's own attributes does not dirty its wire topology, so it must not trigger the
    // wire-repair pass or a `TRANSACTION_DONE` that the simulator would act on.
    let attributes = circuit.staticAttributes
    let oldValue = attributes.rawValue(attribute)
    log.append(.setForCircuit(circuit, attribute, oldValue, value))
    try attributes.setRawValue(attribute, value)

    if attribute === CircuitAttributes.nameAttribute
      || attribute === CircuitAttributes.namedCircuitBoxFixedSize
    {
      // Upstream calls `circuit.getAppearance().recomputeDefaultAppearance()` right here,
      // inline. The port queues it and `CircuitTransaction.execute` drains it into
      // `CircuitTransaction.appearanceRecompute`: board #25. See that drain for the one
      // ordering deviation a queue introduces.
      //
      // **This comment has been wrong in BOTH directions, so here is what was measured.**
      //
      // It first predicted that "a renamed circuit will keep drawing its old default box".
      // False: `CircuitStaticAttributeListener` fires `.setName`,
      // `CircuitSubcircuitFactory.observeSource` handles it, and a rename through the real
      // action path moves the placement's ends to the right place. Measured, on a one-in/one-out
      // child renamed `aa` → `a_very_long_circuit_name`: ends `[(230,300),(300,300)]` →
      // `[(80,300),(300,300)]`, bounds `70x40` → `220x40`.
      //
      // It was then corrected to "the queue is therefore redundant rather than load-bearing",
      // which generalised from the `nameAttribute` half to both halves and is also false.
      // `namedCircuitBoxFixedSize`'s event, `.changeDefaultBoxAppearance`, is declared and
      // handled and **fired nowhere**, so before the drain existed, toggling it produced
      // bounds `220x40` with ends still `[(230,300),(300,300)]`: a west port 150px inside its
      // own box, against an oracle's `[(80,300),(300,300)]`.
      //
      // Both errors came from reasoning about the listener graph instead of running it. The
      // numbers above are `AppearanceRecomputeSeamTests`, which exists so the third version of
      // this comment does not have to be trusted either.
      appearanceRecomputeRequests.append(circuit)
    }
  }

  /// Circuits whose default appearance upstream recomputes inline in `setForCircuit`.
  ///
  /// **Drained by `CircuitTransaction.execute`, into the `appearanceRecompute` seam**: board
  /// #25. Not deduplicated: one mutation writing both `nameAttribute` and
  /// `namedCircuitBoxFixedSize` enqueues the circuit twice, exactly as upstream calls
  /// `recomputeDefaultAppearance()` twice, and the second pass is a no-op because `computePorts`
  /// returns early when the ends are unchanged.
  public private(set) var appearanceRecomputeRequests: [Circuit] = []

  // MARK: - Internals upstream keeps package-private

  private func map(for circuit: Circuit) -> ReplacementMap {
    let key = ObjectIdentifier(circuit)
    if let existing = replacements[key] { return existing.map }
    let created = ReplacementMap()
    replacements[key] = (circuit, created)
    return created
  }

  /// `markModified(Circuit)`.
  func markModified(_ circuit: Circuit) {
    let key = ObjectIdentifier(circuit)
    if modifiedCircuits.updateValue(circuit, forKey: key) == nil {
      modifiedOrder.append(key)
    }
  }

  /// `getModifiedCircuits()`.
  var modified: [Circuit] { modifiedOrder.compactMap { modifiedCircuits[$0] } }

  /// `getReplacementMap(Circuit)`.
  func replacementMap(for circuit: Circuit) -> ReplacementMap? {
    replacements[ObjectIdentifier(circuit)]?.map
  }

  /// `getReverseTransaction()`: the log, replayed backwards.
  ///
  /// Every entry is reversed individually and the *order* is reversed too. Both are needed: a
  /// transaction that removes A then adds B must undo by removing B and then adding A, or the
  /// intermediate state is one where neither exists and a location-keyed structure sees a gap.
  func reverseTransaction() throws -> CircuitMutation {
    let reverse = CircuitMutation()
    for change in log.reversed() {
      reverse.change(try change.reversed())
    }
    return reverse
  }
}

/// `com.cburch.logisim.circuit.CircuitTransactionResult`.
///
/// D3: holds its mutator strongly. The mutator is created inside `execute()` and has no other
/// owner, and its edges run only to circuits (which it does not own) and to components (which
/// the circuits own), no cycle.
public final class CircuitTransactionResult {
  private let mutator: CircuitMutatorImpl

  init(mutator: CircuitMutatorImpl) {
    self.mutator = mutator
  }

  /// `getModifiedCircuits()`.
  public var modifiedCircuits: [Circuit] { mutator.modified }

  /// `getReplacementMap(Circuit)`. Upstream substitutes an empty map for `null`, and callers
  /// rely on that: `CircuitState` walks the result unconditionally.
  public func replacementMap(for circuit: Circuit) -> ReplacementMap {
    mutator.replacementMap(for: circuit) ?? ReplacementMap()
  }

  /// `getReverseTransaction()`.
  public func reverseTransaction() throws -> CircuitTransaction {
    try mutator.reverseTransaction()
  }
}

extension CircuitTransactionResult: CustomStringConvertible {
  public var description: String {
    var text = "CircuitTransactionResult affecting..."
    for circuit in modifiedCircuits {
      text += "\n    - circuit \(circuit.name) with replacements..."
      text += "\n\(replacementMap(for: circuit))"
    }
    return text
  }
}
