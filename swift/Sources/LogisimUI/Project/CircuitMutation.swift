// CircuitMutation.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.circuit.{CircuitMutation, CircuitAction}),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// Ported from the **4.1.0** tree (D16).
//
// ── The shape every tool uses ───────────────────────────────────────────────────────────────
//
// A tool builds a `CircuitMutation`, calls `add`/`remove`/`replace`/`set` on it as many times as
// it likes, and turns it into an `Action` at the end. Nothing is applied until `Project.doAction`
// runs the action, which means a gesture can be assembled and then abandoned; the Wiring tool
// builds one while the mouse is down and discards it on Escape.
//
// The buffering in `run` is the reason this is a list of changes rather than a sequence of
// direct calls; see `CircuitChange.execute`.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.circuit.CircuitMutation`.
public final class CircuitMutation: CircuitTransaction {

  /// `primary`: the circuit the convenience methods target.
  ///
  /// D3: **unowned**. Same reasoning as `CircuitChange.circuit`; a mutation ends up in the undo
  /// log, and a strong edge there would keep every circuit an editing session ever touched
  /// alive for the life of the document.
  ///
  /// Optional because `CircuitMutatorImpl.reverseTransaction()` builds one with no primary: a
  /// reverse transaction only ever receives whole `CircuitChange`s through `change(_:)`, each
  /// carrying its own circuit, so it never consults `primary`. Java expresses this with a
  /// package-private no-arg constructor that leaves the field `null`; making it optional here
  /// means a mistaken convenience call on a reverse transaction is a compile-time question
  /// rather than a null dereference.
  private unowned let primaryCircuit: Circuit?

  private var changes: [CircuitChange] = []

  /// The package-private `CircuitMutation()`, for reverse transactions only.
  override init() {
    self.primaryCircuit = nil
    super.init()
  }

  public init(_ circuit: Circuit) {
    self.primaryCircuit = circuit
    super.init()
  }

  /// The circuit the convenience methods target. Traps if consulted on a reverse transaction,
  /// which is a programmer error no user input can reach (D13's carve-out for internal
  /// invariants); `change(_:)` is the only method a reverse transaction is allowed to use.
  private var primary: Circuit {
    guard let primaryCircuit else {
      fatalError("CircuitMutation built without a primary circuit; use change(_:)")
    }
    return primaryCircuit
  }

  // MARK: - Building

  public func add(_ component: any Component) {
    changes.append(.add(primary, component))
  }

  public func addAll(_ components: [any Component]) {
    changes.append(.addAll(primary, components))
  }

  /// `change(CircuitChange)`: the general form, and the only one a reverse transaction uses.
  public func change(_ change: CircuitChange) {
    changes.append(change)
  }

  /// `clear()`. Records the *unpopulated* form: nothing has been read yet, so there is nothing
  /// to record. `CircuitMutatorImpl.clear` logs the populated form when it actually runs, and
  /// that is the one the reverse transaction is built from.
  public func clear() {
    changes.append(.clear(primary, nil))
  }

  public func remove(_ component: any Component) {
    changes.append(.remove(primary, component))
  }

  public func removeAll(_ components: [any Component]) {
    changes.append(.removeAll(primary, components))
  }

  public func replace(_ oldComponent: any Component, with newComponent: any Component) {
    changes.append(.replace(primary, ReplacementMap(old: oldComponent, new: newComponent)))
  }

  /// `replace(ReplacementMap)`. Freezes the map on the way in; it becomes part of the undo
  /// record from this point, and a tool that kept a reference and went on mutating it would be
  /// rewriting history.
  public func replace(_ replacements: ReplacementMap) {
    guard !replacements.isEmpty else { return }
    replacements.freeze()
    changes.append(.replace(primary, replacements))
  }

  /// `set(Component, Attribute<?>, Object)`, D5's erased pair.
  public func set(
    _ component: any Component, _ attribute: AnyAttribute, _ value: AttributeValue?
  ) {
    changes.append(.set(primary, component, attribute, value))
  }

  /// Typed convenience, for the common case where the caller does have the static type.
  /// Encodes through the attribute's own codec, so a value the attribute cannot represent is
  /// caught here rather than becoming an `.opaque` string in the saved file.
  public func set<V>(_ component: any Component, _ attribute: Attribute<V>, _ value: V?) {
    set(component, attribute as AnyAttribute, value.map { attribute.encode($0) })
  }

  public func setForCircuit(_ attribute: AnyAttribute, _ value: AttributeValue?) {
    changes.append(.setForCircuit(primary, attribute, value))
  }

  public func setForCircuit<V>(_ attribute: Attribute<V>, _ value: V?) {
    setForCircuit(attribute as AnyAttribute, value.map { attribute.encode($0) })
  }

  /// `isEmpty()`.
  public var isEmpty: Bool { changes.isEmpty }

  // MARK: - CircuitTransaction

  /// `getAccessedCircuits()`.
  ///
  /// Every circuit named by any change is write-locked. On top of that, a change that alters a
  /// circuit's *interface* (`concernsSupercircuit`) pulls in every circuit that instantiates it,
  /// and an appearance change on one subcircuit instance pulls in the containers of all its
  /// siblings (`concernsSiblingComponents`).
  ///
  /// The three `…Done` sets are upstream's memoisation, kept because they are not merely an
  /// optimisation: `getCircuitsUsingThis()` walks a weak collection and purges as it reads, so
  /// asking it once per change instead of once per circuit would be quadratic in a large paste.
  public override var accessedCircuits:
    [ObjectIdentifier: (circuit: Circuit, access: Access)]
  {
    var accessMap: [ObjectIdentifier: (circuit: Circuit, access: Access)] = [:]
    var supercircuitsDone: Set<ObjectIdentifier> = []
    var siblingsDone: Set<ObjectIdentifier> = []

    func requireWrite(_ circuit: Circuit) {
      accessMap[ObjectIdentifier(circuit)] = (circuit, .readWrite)
    }

    for change in changes {
      let circuit = change.circuit
      requireWrite(circuit)

      if change.concernsSupercircuit,
        supercircuitsDone.insert(ObjectIdentifier(circuit)).inserted
      {
        for supercircuit in circuit.circuitsUsingThisCircuit {
          requireWrite(supercircuit)
        }
      }

      if change.concernsSiblingComponents, let component = change.component {
        let factory = component.factory
        guard siblingsDone.insert(ObjectIdentifier(factory)).inserted else { continue }
        if let subcircuitFactory = factory as? any SubcircuitFactory,
          let sibling = subcircuitFactory.subcircuit as? Circuit,
          supercircuitsDone.insert(ObjectIdentifier(sibling)).inserted
        {
          for supercircuit in sibling.circuitsUsingThisCircuit {
            requireWrite(supercircuit)
          }
        }
        // The `VhdlEntity` arm is unreachable until that factory is ported; see
        // `CircuitChange.concernsSiblingComponents`.
      }
    }
    return accessMap
  }

  /// `run(CircuitMutator)`.
  ///
  /// The `curCircuit`/`curReplacements` pair is the batching buffer: consecutive changes to the
  /// same circuit accumulate into one `ReplacementMap`, which is flushed when the circuit
  /// changes or the list ends. Note it is flushed on a change of circuit *identity*, not on a
  /// change of kind; a mutation that alternates between two circuits therefore produces several
  /// flushes, which is upstream's behaviour and is why `SelectionActions` groups its changes by
  /// circuit before building the mutation.
  public override func run(_ mutator: any CircuitMutator) throws {
    var currentCircuit: Circuit?
    var currentReplacements = ReplacementMap()

    for change in changes {
      let circuit = change.circuit
      if currentCircuit !== circuit {
        if let currentCircuit {
          try mutator.replace(currentCircuit, currentReplacements)
        }
        currentCircuit = circuit
        currentReplacements = ReplacementMap()
      }
      try change.execute(mutator, into: currentReplacements)
    }

    if let currentCircuit {
      try mutator.replace(currentCircuit, currentReplacements)
    }
  }

  /// `toAction(StringGetter)`.
  ///
  /// D9/localisation: upstream passes a `StringGetter` so the menu label can be re-resolved
  /// when the locale changes. Attribute and menu localisation is a UI-layer concern here (D5's
  /// closing note), so this takes a plain `String` and the default is upstream's
  /// `unknownChangeAction` key rendered in English.
  /// `@MainActor` because `Action` is (see `Tool.swift`'s header) while the rest of this
  /// class deliberately is not: recording changes happens wherever the mutation is built,
  /// but turning one into an undo entry is an editing-layer act.
  @MainActor
  public func toAction(_ name: String? = nil) -> Action {
    CircuitAction(name: name ?? "Change Circuit", mutation: self)
  }

  /// `toAction(StringGetter)` as the tools spell it.
  ///
  /// The six tools name their edits with a `ToolActionName`, the resource key plus its
  /// arguments, rather than a rendered string, so that a differential test can assert *which*
  /// action a gesture produced without depending on a translation. This overload is where that
  /// structured name is rendered, and it is the only place it happens; see
  /// `ToolActionName.displayName` for what is lost by rendering here rather than at display time.
  @MainActor
  public func toAction(_ name: ToolActionName) -> Action {
    toAction(name.displayName)
  }
}

/// `com.cburch.logisim.circuit.CircuitAction`; a `CircuitMutation` wrapped as an undoable edit.
///
/// The reverse transaction is captured on `doIt`, not built up front, because it can only be
/// known once the mutation has actually run: a `set` change does not know the old value until
/// the mutator reads it, and a `clear` does not know what it dropped until it drops it.
///
/// That also means `undo` before `doIt` is a no-op rather than a corruption, which is what
/// `reverse == null` guards in Java. `Project` never does that, but `redoAction` re-runs `doIt`
/// and so re-captures the reverse each time: correct, and the reason `doIt` must not assume it
/// runs once.
@MainActor
public final class CircuitAction: Action {
  private let actionName: String
  private let forward: CircuitMutation
  private var reverse: CircuitTransaction?

  init(name: String, mutation: CircuitMutation) {
    self.actionName = name
    self.forward = mutation
    super.init()
  }

  public override var name: String { actionName }

  public override func doIt(_ project: Project) throws {
    let result = try forward.execute()
    reverse = try result.reverseTransaction()
  }

  public override func undo(_ project: Project) throws {
    try reverse?.execute()
  }
}
