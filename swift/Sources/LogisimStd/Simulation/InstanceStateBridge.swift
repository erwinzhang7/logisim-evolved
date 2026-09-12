// InstanceStateBridge.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.instance.InstanceStateImpl),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// ── The split, and why it is where it is ────────────────────────────────────────────────────
//
// Java has one `InstanceStateImpl`. The port has to cut it in two, because the class touches
// both sides of D9's module boundary: it stores a `CircuitState` (kernel) and it exposes
// `Component`, `InstanceFactory`, `Port` and `InstanceData` (this module and `LogisimFile`).
//
// The cut is: **all storage and every ownership decision in the kernel**
// (`LogisimKernel/Propagation/InstanceStateImpl.swift`), and only the type-level view up here.
// That is deliberate and is the point of the whole exercise; the `unowned` back-edge to
// `CircuitState` is the one thing that must not be got wrong, an ARC cycle there produces zero
// test failures, and nothing in this module checks it. This file adds no stored property, so it
// cannot introduce a cycle even by accident.
//
// What that costs: `InstanceState.component` is non-optional here while the kernel's is not,
// because upstream's *reusable* scratch object genuinely begins life holding `null`
// (`new InstanceStateImpl(this, null)`) and every getter would NPE until the first `repurpose`.
// See `component` below for why trapping is the right D13 answer for that one case.

import Foundation
import LogisimFile
import LogisimKernel

/// `InstanceStateImpl implements InstanceState`; the half of upstream's class that needs types
/// above the kernel.
extension InstanceStateImpl: InstanceState {

  /// `getAttributeSet()`.
  ///
  /// Traps on a component-less scratch object for the same reason `component` does, below.
  public var attributeSet: any AttributeSet {
    guard let set = attributeSetOrNil else {
      preconditionFailure(
        "InstanceStateImpl.attributeSet read before repurpose(_:_:) supplied a component")
    }
    return set
  }

  /// `getComponent()`; D3's replacement for `getInstance()`.
  ///
  /// **Trapping is correct here (D13's carve-out), and it is not the easy answer.** D13 says a
  /// Java exception that can reach `Simulator.recordException` must become a Swift `throw`; but
  /// upstream does not throw here, it dereferences `null` and NPEs, and the only way to reach it
  /// is to read a reusable `InstanceStateImpl` that `CircuitState` has not yet repurposed. No
  /// `.circ` can produce that, `CircuitState` repurposes before every hand-out, so it is a
  /// programmer error in the port, which is precisely what D13 leaves trapping.
  ///
  /// The downcast is total in practice: every `SimComponent` in the tree is one of the five
  /// `Component` conformers (see `ComponentSimulationSeams.swift`), and the kernel has no other
  /// way to make one.
  public var component: any Component {
    guard let comp = simComponent as? any Component else {
      preconditionFailure(
        "InstanceStateImpl.component read before repurpose(_:_:) supplied a component")
    }
    return comp
  }

  /// `getFactory()`; `null` when the component is not instance-backed (a `Wire`, a D8
  /// placeholder).
  public var factory: (any InstanceFactory)? {
    (simComponent as? any Component)?.factory as? any InstanceFactory
  }

  /// `getData()`.
  ///
  /// The kernel stores component data as `Any?` because `CircuitState.componentData` also holds
  /// a subcircuit's `CircuitState`, which is not an `InstanceData`. `as?` therefore reports "no
  /// instance data", which is what upstream's `(InstanceData) circuitState.getData(component)`
  /// cast means for every caller that can actually reach it.
  public var data: (any InstanceData)? { componentData as? any InstanceData }

  /// `setData(InstanceData)`.
  public func setData(_ value: (any InstanceData)?) { setComponentData(value) }

  /// `getPortIndex(Port)` → `getInstance().getPorts().indexOf(port)`.
  ///
  /// `indexOf` is `equals`-based in Java and `Port` is a value type here, so this matches
  /// structurally; see `Port`'s own note on why that is the right identity for a port.
  /// Upstream returns `-1` for a port the component does not have; so does this.
  public func portIndex(of port: Port) -> Int {
    guard let comp = simComponent as? StdInstanceComponent else { return -1 }
    return comp.ports.firstIndex(of: port) ?? -1
  }

  /// `getProject().getOptions().getAttributeSet()`.
  ///
  /// `InstanceState`'s header explains why this is an attribute set and not a `Project`: handing
  /// a component the project would pull the UI object graph onto the propagation path (D9), and
  /// the single thing any `propagate` reads through it is `Options.ATTR_GATE_UNDEFINED`
  /// (`AbstractGate`).
  ///
  /// Upstream's `getProject()` can return `null`, in which case `AbstractGate.propagate` NPEs.
  /// The port makes it total by falling back to a **shared, immutable defaults set**, the same
  /// values `Options.createAttributeSet()` produces, so a headless run behaves as a project
  /// with untouched options, which is what `-tty table` is.
  public var projectOptions: any AttributeSet {
    (circuitState.project as? any SimulationOptionsProviding)?.optionsAttributeSet
      ?? HeadlessSimulationOptions.defaults
  }
}

/// How a host exposes its `<options>` attribute set to component `propagate` implementations.
///
/// A separate protocol from `SimProject`, which lives in the kernel and cannot name
/// `AttributeSet`'s consumers up here without dragging `Options` down with it. A host that has a
/// real project conforms; anything else gets `HeadlessSimulationOptions.defaults`.
public protocol SimulationOptionsProviding: AnyObject {
  /// `getOptions().getAttributeSet()`.
  var optionsAttributeSet: any AttributeSet { get }
}

/// The `<options>` defaults a `propagate` implementation falls back to when its state has no
/// project at all.
///
/// `Options()`'s own attribute set, built once and shared so the fallback costs nothing per
/// `propagate`.
///
/// **Read-only, and that is now a load-bearing rule rather than an observation.** This used to be
/// `SimulationHost.init`'s fallback too, and a host *subscribes* to its options set: so every
/// default-constructed host appended a listener to this one object's registry, and two of them on
/// different threads corrupted the heap. The comment here said "immutable in practice; nothing
/// on the headless path writes to it", which was true of the values and false of the listener
/// list. `SimulationHost` now builds its own set (see its initialiser).
///
/// So: **do not subscribe to this, and do not write to it.** The only supported use is reading a
/// default value from a state that has no project. A caller that needs a set it can mutate or
/// observe must construct `Options()` itself, which is what makes the sharing safe; concurrent
/// readers of an unmutated `AttributeSet` are fine, concurrent listeners are not.
public enum HeadlessSimulationOptions {
  /// `Options.createAttributeSet()`'s defaults: `gateUndefined = ignore`, `simlimit = 1000`,
  /// `simrand = 0`.
  public static let defaults: any AttributeSet = Options().attributeSet
}
