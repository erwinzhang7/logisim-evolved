// SubcircuitPropagation.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.circuit.SubcircuitFactory.propagate and its
// two getSubstate overloads), https://github.com/logisim-evolution/logisim-evolution. Copyright by
// the Logisim-evolution developers. This translation is a derivative work and is therefore
// GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16): `circuit/SubcircuitFactory.java:298-317, 387-406`.
//
// ── Why this is a free function and not a method on the factory ─────────────────────────────
//
// In Java `SubcircuitFactory extends InstanceFactory`, so `propagate(InstanceState)` is an
// override and `InstanceComponent.propagate` reaches it through the ordinary
// `((InstanceFactory) getFactory()).propagate(...)` cast. The port cannot do that: D9 puts
// `CircuitSubcircuitFactory` in `LogisimFile`, it has to be there, because a `Circuit` builds
// its own factory in its initialiser, while `InstanceFactory` is up here in `LogisimStd`, which
// depends on `LogisimFile` and not the other way round. Conforming the factory to
// `InstanceFactory` would need the arrow to point backwards.
//
// So a subcircuit placement is the one component in the tree that is NOT an `InstanceFactory`,
// and `SimulatableComponent.propagate(in:)`'s `as? any InstanceFactory` guard drops it on the
// floor. That guard is why correct ports (`computePorts` is implemented and corpus-validated at
// 786 placements) still produced all-`U` tables: the ends were right and nothing ever drove them.
// This file supplies the behaviour and `ComponentSimulationSeams.swift` routes to it *before* the
// guard.
//
// ── The route from a CircuitState back to the session that made it ──────────────────────────
//
// `getSubstate` needs `superState.createCircuitSubstateFor(comp, source)`, and the kernel's
// signature takes an `any SimCircuit`; not a `LogisimFile.Circuit`. Wrapping a circuit is
// `SimulationSession.simulated(_:)`, and it is a *cache*: `CircuitState` keys substates,
// `componentData` and dirty lists on the objects it is handed (D4), so two wrappers around one
// `Circuit` are two silently divergent circuits. A fresh `SimulatedCircuit(circuit)` per call
// would be wrong, not merely wasteful.
//
// A previous attempt at this reached for a process-global dictionary keyed by
// `ObjectIdentifier(circuit)`. That is exactly the pattern `SimulatedCircuit`'s own header
// rejects and D3's corollary names: nothing owns eviction, so every circuit ever simulated stays
// alive for the life of the process. It was thrown away rather than shipped.
//
// **The real route already existed and is already used.** `CircuitState.project` is the kernel's
// `any SimProject`, held weakly per D3, and `InstanceStateBridge.projectOptions` already asks it
// a question this module cannot express in the kernel:
//
//     (circuitState.project as? any SimulationOptionsProviding)?.optionsAttributeSet
//
// `SubcircuitCircuitProviding` below is the same seam for the same reason, and `SimulationHost`
// , the port's `Project` stand-in, is what answers it. That means **no new reference of any
// kind**, back-edge or otherwise: the only new arrow is host → cache → `SimulatedCircuit`, which
// points away from the kernel. `CircuitState`'s edge to the host was already there and was
// already weak. See `HeadlessSimulation.swift` for why the cache moved from the session onto the
// host it owns.

import Foundation
import LogisimFile
import LogisimKernel

/// How the simulation host answers "give me the one `SimulatedCircuit` for this `Circuit`".
///
/// Deliberately narrow: `SubcircuitFactory.getSubstate` is the only caller and the only thing it
/// needs is the identity-stable wrapper. Keeping it to one method means a future real `Project`
/// in `LogisimUI` can conform without inheriting the headless session's shape.
public protocol SubcircuitCircuitProviding: AnyObject {
  /// `SimulationSession.simulated(_:)`: the *cached* wrapper, never a fresh one.
  func simulatedCircuit(for circuit: Circuit) -> SimulatedCircuit
}

/// `SubcircuitFactory`'s simulation half.
public enum SubcircuitPropagation {

  // MARK: - Errors

  public enum Failure: Error, CustomStringConvertible {
    /// The state's project cannot hand back `SimulatedCircuit`s, so no substate can be built.
    ///
    /// **D13: a `throw`, not a trap, and not a silent return.** Upstream cannot reach this, its
    /// `getSubstate` takes the `Circuit` straight off the factory field, so there is no Java
    /// behaviour to match and the choice is the port's. A silent return is the *worst* of the
    /// three: it is precisely the failure mode this file exists to fix (a subcircuit that never
    /// propagates, whose neighbours then read `UNKNOWN`), and it would come back with no
    /// diagnostic attached. Throwing routes it to `Simulator.recordException`, i.e. a circuit
    /// error the user is shown, which is what D13 asks for on the propagation path.
    case noCircuitProvider(subcircuit: String)

    /// The component reached `propagate` without the kernel supplying one. See
    /// `InstanceStateImpl.simComponent` for why the kernel's is optional at all.
    case noComponent

    public var description: String {
      switch self {
      case let .noCircuitProvider(name):
        return """
          cannot simulate subcircuit '\(name)': this CircuitState's project does not conform to \
          SubcircuitCircuitProviding, so there is no cache to build its substate from. Create the \
          root state through SimulationSession.createRootState(for:).
          """
      case .noComponent:
        return "subcircuit propagate reached an InstanceStateImpl with no component"
      }
    }
  }

  // MARK: - getSubstate

  /// `getSubstate(CircuitState superState, Component comp)`:
  ///
  /// ```java
  /// public CircuitState getSubstate(CircuitState superState, Component comp) {
  ///   var subState = (CircuitState) superState.getData(comp);
  ///   if (subState == null) {
  ///     subState = superState.createCircuitSubstateFor(comp, source);
  ///     if (comp instanceof InstanceComponent) {
  ///       ((InstanceComponent) comp).fireInvalidated();
  ///     } else {
  ///       System.out.println("wrong kind... " + comp);
  ///     }
  ///   }
  ///   return subState;
  /// }
  /// ```
  ///
  /// Two transcription notes:
  ///
  ///   * the `instanceof InstanceComponent` test collapses. Every conformer of
  ///     `SimulatableComponent` answers `fireComponentInvalidated()`, and the four that are not
  ///     instance-backed inherit the kernel's no-op: so the `else` branch's only effect,
  ///     printing to stdout, is the one thing the port must not do. `logisim-cli --tty table`
  ///     writes the truth table to stdout and is compared byte-for-byte against the oracle, so a
  ///     stray `println` there is a corrupted gate rather than a diagnostic. (`CircuitState`
  ///     drops upstream's other propagation-path `println` for the same stated reason.)
  ///   * `superState.getData(comp)` is `Any?` in the port because `componentData` also holds
  ///     `InstanceData`; `as? CircuitState` is upstream's cast, and a `nil` from it means the
  ///     same thing as upstream's `null`.
  public static func substate(
    of superState: CircuitState,
    component: any SimComponent,
    factory: CircuitSubcircuitFactory,
    provider: (any SubcircuitCircuitProviding)?
  ) throws -> CircuitState {
    if let existing = superState.getData(component) as? CircuitState { return existing }
    guard let provider else {
      throw Failure.noCircuitProvider(subcircuit: factory.source.name)
    }
    let sub = superState.createCircuitSubstateFor(
      component, provider.simulatedCircuit(for: factory.source))
    component.fireComponentInvalidated()
    return sub
  }

  // MARK: - propagate

  /// `propagate(InstanceState stateInContext)`:
  ///
  /// ```java
  /// public void propagate(InstanceState stateInContext) {
  ///   final var subState = getSubstate(stateInContext);
  ///   final var attrs = (CircuitAttributes) stateInContext.getAttributeSet();
  ///   final var pins = attrs.getPinInstances();
  ///   for (var i = 0; i < pins.length; i++) {
  ///     final var pin = pins[i];
  ///     final var pinState = subState.getReusableInstanceState(pin);
  ///     if (Pin.FACTORY.isInputPin(pin)) {
  ///       final var newVal = stateInContext.getPortValue(i);
  ///       final var oldVal = Pin.FACTORY.getValue(pinState);
  ///       if (!newVal.equals(oldVal)) {
  ///         Pin.FACTORY.driveInputPin(pinState, newVal);
  ///         Pin.FACTORY.propagate(pinState);
  ///       }
  ///     } else { // it is output-only
  ///       final var val = pinState.getPortValue(0);
  ///       stateInContext.setPort(i, val, 1);
  ///     }
  ///   }
  /// }
  /// ```
  ///
  /// Every load-bearing detail is preserved, including the ones that look like they could be
  /// simplified:
  ///
  ///   * **the inequality guard on the input arm.** Driving unconditionally would re-drive the
  ///     child's net on every pass, which never settles: `Propagator` decides a circuit is
  ///     oscillating by counting passes that keep producing changes, so an unguarded drive turns
  ///     a correct combinational subcircuit into a false oscillation report.
  ///   * **the reused instance state**, with upstream's own comment: *"This reuse is OK since the
  ///     substate has its own reusable InstanceState, not equal to stateInContext. Accounts for
  ///     10% speedup."* The aliasing is safe here and only here because `subState` is a different
  ///     `CircuitState` from the one `stateInContext` belongs to, so the two scratch objects are
  ///     distinct. Note this is the reason `SimulatableComponent.propagate(in:)` must keep using
  ///     the *allocating* overload for `stateInContext` itself: see its header.
  ///   * **delay 1** on the output arm, not 0. It is what makes a subcircuit cost one propagation
  ///     step like any other component.
  ///
  /// `attrs.getPinInstances()` becomes `factory.pinComponents(for:)`, which `computePorts` fills
  /// in the same pass that builds the ends: so index `i` names the same port on both sides by
  /// construction. That property is what the whole loop rests on, and it is asserted directly in
  /// `SubcircuitPropagationTests`.
  public static func propagate(
    _ component: any SimComponent,
    factory: CircuitSubcircuitFactory,
    in state: CircuitState
  ) throws {
    // `state.getInstanceState(this)` upstream. The port must use the **unvalidated** overload:
    // `getInstanceState` guards on `factoryRoles.contains(.instanceFactory)`, and a subcircuit
    // factory is the one factory in the tree that does not carry that role (see the file header).
    // The checked overload would therefore throw `notAnInstanceComponent` on every subcircuit.
    guard let stateInContext = state.unvalidatedInstanceState(for: component) as? InstanceStateImpl
    else { return }

    // `instanceof InstanceComponent`; upstream's `getSubstate(InstanceState)` overload throws
    // `IllegalArgumentException("getSubstate on wrong type")` when the state is not the concrete
    // impl, which the guard above has already established.
    let subState = try substate(
      of: state,
      component: component,
      factory: factory,
      provider: state.project as? any SubcircuitCircuitProviding)

    // `attrs.getPinInstances()`. Upstream reads the pin list off `CircuitAttributes`, which any
    // placement carries; the port keeps it on the factory, keyed by placement, because
    // `CircuitAttributes.pinInstances` is typed `[InstanceComponent]` and a `Pin` loaded from a
    // `.circ` is a `StdInstanceComponent`: a sibling type, not a subclass (see
    // `CircuitSubcircuitFactory.pinComponents(for:)`). That key is an `InstanceComponent`, which
    // every subcircuit placement is: `CircuitSubcircuitFactory.createComponent` makes one, and it
    // is the only way a placement of a circuit comes into existence. A component that is not one
    // therefore also never had `computePorts` run on it, so it has no ends to drive and upstream's
    // "wrong kind..." branch is the matching no-op.
    guard let placement = component as? InstanceComponent else { return }
    let pins = factory.pinComponents(for: placement)
    for (index, pin) in pins.enumerated() {
      guard let pinComponent = pin as? any SimComponent,
        let pinState = subState.unvalidatedReusableInstanceState(for: pinComponent)
          as? InstanceStateImpl
      else { continue }

      if Pin.isInputPin(pin.attributeSet) {
        let newValue = stateInContext.portValue(index)
        let oldValue = Pin.getValue(pinState)
        if newValue != oldValue {
          Pin.driveInputPin(pinState, newValue)
          try Pin.factory.propagate(pinState)
        }
      } else {
        // Output-only. `getPortValue(0)` on the *child's* pin: a Pin has exactly one port.
        stateInContext.setPort(index, pinState.portValue(0), 1)
      }
    }
  }
}
