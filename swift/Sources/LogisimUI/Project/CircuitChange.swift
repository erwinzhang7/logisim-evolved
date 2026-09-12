// CircuitChange.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.circuit.CircuitChange),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// Ported from the **4.1.0** tree (D16).
//
// ── One change, and its reverse ─────────────────────────────────────────────────────────────
//
// `CircuitChange` is the atom of the edit system: a tagged record of one thing done to one
// circuit, able to produce the record that undoes it. It is deliberately *not* a closure; the
// change has to be inspectable after the fact, because `CircuitMutation.getAccessedCircuits`
// interrogates a whole list of them to work out which circuits a transaction will touch before
// any of them is applied.
//
// Java's eight `static final int` type tags become an enum with associated values, which removes
// the shape hazard the original carries: in Java `comp`, `comps`, `attr`, `oldValue` and
// `newValue` are all fields on every change, most of them null most of the time, and `REPLACE`
// smuggles its `ReplacementMap` through the `newValue` field with a cast. Here each case carries
// exactly what it has, so `getReverseChange` cannot read a field that a given kind never filled.
//
// ── D5: erased attribute writes ─────────────────────────────────────────────────────────────
//
// `set`/`setForCircuit` carry an `Attribute<?>` and an `Object` in Java. D5's answer is
// `AnyAttribute` plus `AttributeValue`, which is exactly what `AttributeSet.rawValue` and
// `setRawValue` speak; the storage-level pair that exists so the codec and this file never have
// to recover `V`. Nothing here needs the static type; it reads the old value out and writes the
// new one back, both opaque.
//
// ── D4 ──────────────────────────────────────────────────────────────────────────────────────
//
// Components are held and compared by reference. `concernsSupercircuit` asks about a component's
// *factory*, never about equality, and the attribute tests below are identity comparisons on
// `AnyAttribute` (which is `Hashable` by `ObjectIdentifier`); the port keeps them that way. Note
// `CircuitAttributes.appearance` and `StdAttr.appearance` share the `.circ` token "appearance"
// but are different objects, so name-based comparison here would silently widen the test.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.circuit.CircuitChange`.
public struct CircuitChange {

  /// Upstream's `CLEAR`/`ADD`/…/`SET_FOR_CIRCUIT` tags, with their payloads attached.
  ///
  /// The raw ordinals are preserved in `ordinal` so a log line or a differential trace can be
  /// compared against Java's `getType()` directly.
  public enum Kind {
    /// `CLEAR`. `oldComponents` is `nil` when the change is being *recorded* by
    /// `CircuitMutation.clear()` (nothing has been read yet) and populated when it is being
    /// *logged* by `CircuitMutatorImpl.clear`, which is the only version that can be reversed.
    case clear(oldComponents: [any Component]?)
    case add(any Component)
    case addAll([any Component])
    case remove(any Component)
    case removeAll([any Component])
    case replace(ReplacementMap)
    /// A component attribute write. `oldValue` is `nil` until the mutator fills it in.
    case set(
      component: any Component,
      attribute: AnyAttribute,
      oldValue: AttributeValue?,
      newValue: AttributeValue?)
    /// A write to the circuit's own static attribute set: the `<circuit>` element's `<a>`
    /// children.
    case setForCircuit(
      attribute: AnyAttribute,
      oldValue: AttributeValue?,
      newValue: AttributeValue?)

    /// Upstream's integer tag, for tracing only.
    public var ordinal: Int {
      switch self {
      case .clear: return 0
      case .add: return 1
      case .addAll: return 2
      case .remove: return 3
      case .removeAll: return 4
      case .replace: return 5
      case .set: return 6
      case .setForCircuit: return 7
      }
    }
  }

  /// The circuit being changed.
  ///
  /// D3: **unowned**. A change lives inside a `CircuitMutation`, which lives inside a
  /// `CircuitAction`, which lives in the undo log, which lives on the `Project`, and the
  /// project owns the `LogisimFile` that owns this circuit. A strong edge here would mean the
  /// undo log keeps every circuit a session ever edited alive for as long as the document is
  /// open, including circuits the user has since deleted. `unowned` rather than `weak` because
  /// a change is never applied to a circuit that has been freed: removing a circuit clears the
  /// undo log entries that name it (see `Project.setLogisimFile`).
  public unowned let circuit: Circuit

  public let kind: Kind

  private init(circuit: Circuit, kind: Kind) {
    self.circuit = circuit
    self.kind = kind
  }

  // MARK: - Factories (upstream's static constructors)

  public static func add(_ circuit: Circuit, _ component: any Component) -> CircuitChange {
    CircuitChange(circuit: circuit, kind: .add(component))
  }

  public static func addAll(_ circuit: Circuit, _ components: [any Component]) -> CircuitChange {
    CircuitChange(circuit: circuit, kind: .addAll(components))
  }

  public static func clear(
    _ circuit: Circuit, _ oldComponents: [any Component]?
  ) -> CircuitChange {
    CircuitChange(circuit: circuit, kind: .clear(oldComponents: oldComponents))
  }

  public static func remove(_ circuit: Circuit, _ component: any Component) -> CircuitChange {
    CircuitChange(circuit: circuit, kind: .remove(component))
  }

  public static func removeAll(
    _ circuit: Circuit, _ components: [any Component]
  ) -> CircuitChange {
    CircuitChange(circuit: circuit, kind: .removeAll(components))
  }

  public static func replace(
    _ circuit: Circuit, _ replacements: ReplacementMap
  ) -> CircuitChange {
    CircuitChange(circuit: circuit, kind: .replace(replacements))
  }

  public static func set(
    _ circuit: Circuit,
    _ component: any Component,
    _ attribute: AnyAttribute,
    _ value: AttributeValue?
  ) -> CircuitChange {
    CircuitChange(
      circuit: circuit,
      kind: .set(component: component, attribute: attribute, oldValue: nil, newValue: value))
  }

  public static func set(
    _ circuit: Circuit,
    _ component: any Component,
    _ attribute: AnyAttribute,
    _ oldValue: AttributeValue?,
    _ newValue: AttributeValue?
  ) -> CircuitChange {
    CircuitChange(
      circuit: circuit,
      kind: .set(
        component: component, attribute: attribute, oldValue: oldValue, newValue: newValue))
  }

  public static func setForCircuit(
    _ circuit: Circuit, _ attribute: AnyAttribute, _ value: AttributeValue?
  ) -> CircuitChange {
    CircuitChange(
      circuit: circuit,
      kind: .setForCircuit(attribute: attribute, oldValue: nil, newValue: value))
  }

  public static func setForCircuit(
    _ circuit: Circuit,
    _ attribute: AnyAttribute,
    _ oldValue: AttributeValue?,
    _ newValue: AttributeValue?
  ) -> CircuitChange {
    CircuitChange(
      circuit: circuit,
      kind: .setForCircuit(attribute: attribute, oldValue: oldValue, newValue: newValue))
  }

  // MARK: - Accessors upstream exposes

  public var component: (any Component)? {
    switch kind {
    case .add(let c), .remove(let c): return c
    case .set(let c, _, _, _): return c
    default: return nil
    }
  }

  public var attribute: AnyAttribute? {
    switch kind {
    case .set(_, let a, _, _), .setForCircuit(let a, _, _): return a
    default: return nil
    }
  }

  public var oldValue: AttributeValue? {
    switch kind {
    case .set(_, _, let v, _), .setForCircuit(_, let v, _): return v
    default: return nil
    }
  }

  public var newValue: AttributeValue? {
    switch kind {
    case .set(_, _, _, let v), .setForCircuit(_, _, let v): return v
    default: return nil
    }
  }

  // MARK: - Lock scoping

  /// `concernsSupercircuit()`; does this change alter how *containing* circuits see this one?
  ///
  /// It decides whether every circuit that instantiates `circuit` has to be write-locked for the
  /// transaction, so an over-broad answer costs concurrency and an under-broad one corrupts a
  /// supercircuit's port list. The four true cases are all things that change the subcircuit's
  /// **interface**: clearing it, adding or removing a `Pin`, or editing a pin's width, type or
  /// label.
  ///
  /// `SET_FOR_CIRCUIT` is true only for the three attributes a supercircuit renders from: the
  /// circuit's name, its fixed-size flag, and its appearance.
  public var concernsSupercircuit: Bool {
    switch kind {
    case .clear:
      return true
    case .add(let c), .remove(let c):
      return c.factory.isPin
    case .addAll(let cs), .removeAll(let cs):
      return cs.contains { $0.factory.isPin }
    case .replace(let repl):
      return repl.removals.contains { $0.factory.isPin }
        || repl.additions.contains { $0.factory.isPin }
    case .set(let c, let attr, _, _):
      // Identity comparisons, as upstream's `==` on `Attribute` objects is.
      return c.factory.isPin
        && (attr === StdAttr.width || attr === CircuitChange.pinTypeAttribute
          || attr === StdAttr.label)
    case .setForCircuit(let attr, _, _):
      return attr === CircuitAttributes.nameAttribute
        || attr === CircuitAttributes.namedCircuitBoxFixedSize
        || attr === CircuitAttributes.appearance
    }
  }

  /// `Pin.ATTR_TYPE`.
  ///
  /// SEAM: `std/wiring/Pin` is another slice's file and does not exist in `LogisimStd` at the
  /// time this was written, so the attribute is reached by name off the pin factory rather than
  /// by importing a symbol that is not there yet. `nil` degrades safely, the effect is a
  /// slightly narrower lock scope for pin-type edits, never a wrong mutation, and the lookup
  /// collapses to `Pin.attributeType` the moment that file lands.
  ///
  /// Computed rather than stored: a `static let` of a non-`Sendable` type is global mutable
  /// state as far as Swift 6 is concerned, and `AnyAttribute` is not `Sendable`.
  static var pinTypeAttribute: AnyAttribute? { nil }

  /// `concernsSiblingComponents()`; an appearance change on one subcircuit instance has to be
  /// mirrored onto every other instance of the same subcircuit, so all their containers are
  /// locked too.
  public var concernsSiblingComponents: Bool {
    guard case .set(let c, let attr, _, _) = kind else { return false }
    if c.factory is any SubcircuitFactory, attr === CircuitAttributes.appearance { return true }
    // The `VhdlEntity && attr == StdAttr.APPEARANCE` arm is unreachable until the VHDL entity
    // factory is ported (D11 keeps VHDL *co-simulation* out; the entity itself is a later
    // milestone). Recorded rather than dropped so the omission is visible.
    return false
  }

  // MARK: - Execution

  /// `execute(CircuitMutator, ReplacementMap)`.
  ///
  /// The batching here is the whole reason `CircuitMutation` is a list of changes rather than a
  /// sequence of direct calls. Adds and removes do **not** go to the mutator one at a time; they
  /// accumulate into `pending`, and the accumulated map is flushed as a single `replace` when
  /// something order-sensitive turns up: an attribute write, a clear, or the end of the run.
  ///
  /// That matters for correctness, not just speed: `Circuit.mutatorAdd` runs duplicate-label
  /// clearing against the components already present, and the simulator carries `componentData`
  /// across a replacement by looking the old component up in the map. Applying a five-component
  /// paste as five separate replacements would give five separate maps, and the simulator would
  /// see five unrelated single edits instead of one paste.
  func execute(_ mutator: any CircuitMutator, into pending: ReplacementMap) throws {
    switch kind {
    case .clear:
      try mutator.clear(circuit)
      pending.reset()
    case .add(let c):
      try pending.add(c)
    case .addAll(let cs):
      for c in cs { try pending.add(c) }
    case .remove(let c):
      try pending.remove(c)
    case .removeAll(let cs):
      for c in cs { try pending.remove(c) }
    case .replace(let repl):
      pending.append(repl)
    case .set(let c, let attr, _, let newValue):
      try mutator.replace(circuit, pending)
      pending.reset()
      try mutator.set(circuit, c, attr, newValue)
    case .setForCircuit(let attr, _, let newValue):
      try mutator.replace(circuit, pending)
      pending.reset()
      try mutator.setForCircuit(circuit, attr, newValue)
    }
  }

  /// `getReverseChange()`.
  ///
  /// D13: `throws` for the one shape that cannot be reversed; a `.clear` recorded without the
  /// component set it dropped. Java cannot hit that because `CircuitMutatorImpl.clear` always
  /// logs the populated form, and neither can this port, but the reversal is only *sound* for
  /// the populated form and saying so in the type is cheaper than a comment nobody reads. A
  /// silent `addAll([])` here would make undo of a Select-All-Delete a no-op: the whole circuit
  /// gone with Ctrl-Z unable to bring it back.
  func reversed() throws -> CircuitChange {
    switch kind {
    case .clear(let oldComponents):
      guard let oldComponents else {
        throw CircuitMutationError.unknownChangeKind("clear without recorded contents")
      }
      return .addAll(circuit, oldComponents)
    case .add(let c):
      return .remove(circuit, c)
    case .addAll(let cs):
      return .removeAll(circuit, cs)
    case .remove(let c):
      return .add(circuit, c)
    case .removeAll(let cs):
      return .addAll(circuit, cs)
    case .set(let c, let attr, let oldValue, let newValue):
      // Note the swap: the reverse change's "new" value is this one's old value, and it keeps
      // this one's new value as *its* old value, so reversing twice is the identity.
      return .set(circuit, c, attr, newValue, oldValue)
    case .setForCircuit(let attr, let oldValue, let newValue):
      return .setForCircuit(circuit, attr, newValue, oldValue)
    case .replace(let repl):
      return .replace(circuit, repl.inverseMap())
    }
  }
}
