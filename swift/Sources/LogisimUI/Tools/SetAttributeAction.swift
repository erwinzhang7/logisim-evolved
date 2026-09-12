// SetAttributeAction.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.tools.SetAttributeAction),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.tools.SetAttributeAction`; an undoable batch of attribute writes.
///
/// The subtlety worth reading twice is the **split** in `doIt`: a component that is in the circuit
/// has its write routed through a `CircuitMutation`, so it participates in the circuit's
/// transaction and its reverse transaction becomes the undo; a component that is *not* in the
/// circuit (a floating pasted selection, or a tool's own prototype attributes) is written
/// directly, and its old value is recorded here for the undo. `oldValues` therefore holds a real
/// value only for the second kind, and `undo` skips the nil entries; the transaction already
/// covers those.
///
/// D13 shapes one thing here that upstream does not have to think about: `AttributeSet.setValue`
/// throws in this port, so `doIt`/`undo` throw. That is the correct end of the rule; a component
/// whose set rejects an attribute is a recoverable editing error, not a reason to kill the app.
///
/// D5 shapes another. Java erases every attribute to `Attribute<Object>` and stores `Object`
/// values. Swift cannot, so each recorded write carries its own type-erased closure that knows the
/// concrete `Attribute<V>` and `V`. The batch stays heterogeneous; only the erasure moves from a
/// cast to a closure.
@MainActor
public final class SetAttributeAction: Action {

  /// `Action.getName()`. The structured `ToolActionName` the tools build is kept alongside
  /// the rendered string: the string is what the Edit menu shows and what `Action` declares,
  /// the key is what a differential test asserts on without depending on a translation.
  public let actionName: ToolActionName
  public override var name: String { actionName.displayName }
  private let circuit: Circuit

  /// One recorded write, with its own type preserved inside the closures.
  private struct Entry {
    /// Nil for a write against a set that belongs to no component; a tool's prototype
    /// attributes. `doIt` then always takes the direct branch, which is what
    /// `ToolAttributeAction` does upstream.
    let component: (any Component)?
    /// Applies the new value to the mutation (in-circuit): `xn.set(comp, attr, value)`.
    let applyToMutation: (CircuitMutation) -> Void
    /// Applies the new value directly and returns a closure that puts the old one back.
    let applyDirectly: () throws -> (() throws -> Void)
  }

  private var entries: [Entry] = []
  /// Set only for entries written directly; `nil` for entries the transaction owns.
  private var undoDirectWrites: [(() throws -> Void)?] = []
  /// The reverse of the circuit transaction, once `doIt` has run.
  private var reverseTransaction: (() -> Void)?

  public init(circuit: Circuit, name: ToolActionName) {
    self.circuit = circuit
    self.actionName = name
    super.init()
  }

  /// `isEmpty()`.
  public var isEmpty: Bool { entries.isEmpty }

  /// `set(Component, Attribute<?>, Object)`.
  public func set<V>(_ component: any Component, _ attribute: Attribute<V>, _ value: V?) {
    entries.append(
      Entry(
        component: component,
        applyToMutation: { mutation in mutation.set(component, attribute, value) },
        applyDirectly: {
          let attributes = component.attributeSet
          let oldValue = attributes[attribute]
          try attributes.setValue(attribute, value)
          return { try attributes.setValue(attribute, oldValue) }
        }))
  }

  /// `com.cburch.logisim.gui.main.ToolAttributeAction`; a write against an attribute set that is
  /// not attached to any placed component, i.e. a tool's own prototype. Upstream has a separate
  /// `Action` class for this; here it is the same class with no component, because `doIt` already
  /// has to handle "component not in this circuit" and the two cases are identical from there on.
  public func setDirect<V>(
    _ attributes: any AttributeSet, _ attribute: Attribute<V>, _ value: V?
  ) {
    entries.append(
      Entry(
        component: nil,
        applyToMutation: { _ in },
        applyDirectly: {
          let oldValue = attributes[attribute]
          try attributes.setValue(attribute, value)
          return { try attributes.setValue(attribute, oldValue) }
        }))
  }

  public override func doIt(_ project: Project) throws {
    let mutation = project.beginMutation(on: circuit)
    undoDirectWrites.removeAll()
    for entry in entries {
      if let component = entry.component, circuit.contains(component) {
        undoDirectWrites.append(nil)
        entry.applyToMutation(mutation)
      } else {
        undoDirectWrites.append(try entry.applyDirectly())
      }
    }

    if !mutation.isEmpty {
      // Upstream calls `xn.execute()` and keeps the reverse transaction. Here the mutation is
      // handed to the project, which owns transaction execution and hands back the inverse.
      let action = mutation.toAction(name)
      try action.doIt(project)
      reverseTransaction = { [weak project] in
        guard let project else { return }
        try? action.undo(project)
      }
    }
  }

  public override func undo(_ project: Project) throws {
    reverseTransaction?()
    // Reverse order, as upstream does, so that two writes to the same attribute unwind correctly.
    for index in stride(from: undoDirectWrites.count - 1, through: 0, by: -1) {
      try undoDirectWrites[index]?()
    }
  }
}
