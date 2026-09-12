// InstanceState.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.instance.{InstanceState, InstanceData,
// InstanceDataSingleton}), https://github.com/logisim-evolution/logisim-evolution. Copyright by
// the Logisim-evolution developers. This translation is a derivative work and is therefore
// GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Why this protocol lives here and not in the simulation kernel ────────────────────────────
//
// `InstanceState` is the *only* surface a component's `propagate` touches. Declaring it here
// means `LogisimStd` compiles, and every component can be written and reviewed, before
// `CircuitState`/`Propagator` exist, and it pins the contract those types must satisfy rather
// than letting it be discovered one component at a time. `InstanceStateImpl` (the reusable
// scratch object D1/D2 protect) is the simulation module's job: it conforms to this and nothing
// here needs to change.
//
// ── Deviations from `InstanceState.java` ────────────────────────────────────────────────────
//
//   * `getInstance()` is gone; D3 deletes the `Instance` facade. `component` replaces it.
//   * `getProject()` is replaced by `projectOptions`, the one thing any `propagate` reads
//     through it (`AbstractGate` → `Options.ATTR_GATE_UNDEFINED`). Handing components a whole
//     `Project` would pull the UI object graph into the propagation path, which D9 forbids.
//     Upstream's `getProject()` can return `null`, in which case `AbstractGate.propagate`
//     NPEs; the port makes the options set non-optional, so the implementer must supply
//     `Options.createAttributeSet()`'s defaults in a project-less (headless) run.
//   * `createCircuitSubstateFor(Circuit)` is **not** declared. It is used only by
//     `SubcircuitFactory` and `VhdlEntity`, both of which belong to the simulation module and
//     both of which will hold a concrete `InstanceStateImpl`, not this protocol.
//   * `setPort` does not throw, matching `CircuitState.setValue`.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.instance.InstanceData`; a component's per-`CircuitState` scratch state.
///
/// Java's `clone()` is inherited from `ComponentState`; Swift has no `Object.clone`, so the
/// requirement is explicit. Implementations that are logically value-like should return a fresh
/// object; `CircuitState` clones component data when a circuit state is forked.
public protocol InstanceData: AnyObject {
  func cloneData() -> any InstanceData
}

/// `com.cburch.logisim.instance.InstanceDataSingleton`: the one-field data holder that most
/// stateful components use.
public final class InstanceDataSingleton: InstanceData {
  public var value: Any?

  public init(_ value: Any?) {
    self.value = value
  }

  public func cloneData() -> any InstanceData {
    InstanceDataSingleton(value)
  }
}

/// `com.cburch.logisim.instance.InstanceState`.
///
/// The whole of what a component sees during propagation. Synchronous and non-reentrant by
/// D1/D2: nothing here is `async`, and the implementation is expected to be one reusable
/// object repurposed per component.
public protocol InstanceState: AnyObject {

  /// `getAttributeSet()`.
  var attributeSet: any AttributeSet { get }

  /// `getComponent()` / D3's replacement for `getInstance()`.
  var component: any Component { get }

  /// `getFactory()`. `nil` when the component is not instance-backed (a `Wire`, an
  /// unresolved-component placeholder).
  var factory: (any InstanceFactory)? { get }

  /// `getData()` / `setData(InstanceData)`.
  var data: (any InstanceData)? { get }
  func setData(_ value: (any InstanceData)?)

  /// `getPortIndex(Port)`. See `Port` for why this matches structurally rather than by
  /// identity.
  func portIndex(of port: Port) -> Int

  /// `getPortValue(int)`.
  func portValue(_ index: Int) -> Value

  /// `isPortConnected(int)`.
  func isPortConnected(_ index: Int) -> Bool

  /// `setPort(int, Value, int)`.
  func setPort(_ index: Int, _ value: Value, _ delay: Int)

  /// `getTickCount()`.
  var tickCount: Int { get }

  /// `isCircuitRoot()`.
  var isCircuitRoot: Bool { get }

  /// `fireInvalidated()`.
  func fireInvalidated()

  /// `getProject().getOptions().getAttributeSet()`, see the file header.
  var projectOptions: any AttributeSet { get }
}

extension InstanceState {
  /// `getAttributeValue(Attribute<E>)`.
  public func attributeValue<V>(_ attribute: Attribute<V>) -> V? {
    attributeSet.getValue(attribute)
  }

  /// `getAttributeValue` for attributes a factory guarantees are present. Java would NPE (or
  /// silently unbox `null`) here; the fallback makes the assumption explicit at the call site.
  public func attributeValue<V>(_ attribute: Attribute<V>, default fallback: @autoclosure () -> V)
    -> V
  {
    attributeSet.getValue(attribute) ?? fallback()
  }
}
