// InstanceStateImpl.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.instance.InstanceStateImpl),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16): `instance/InstanceStateImpl.java`, 124 lines.
//
// ── Why the concrete class is HERE and not in LogisimStd ────────────────────────────────────
//
// `SimInstanceStateImpl` (ComponentState.swift) documented two hard ARC requirements in prose:
// "hold the CircuitState unowned", "keep the component strong", and left the conforming class
// for somebody above the kernel to write. No such class existed anywhere in the tree, so the
// contract was unenforced *and* the seam was unreachable: `CircuitState.instanceStateFactory`
// was `nil` and every path through it hit a `fatalError`.
//
// Writing the conformer above the kernel would have kept the ownership rule as prose forever:
// nothing in `LogisimStd` checks it, an ARC cycle produces zero test failures (D3's corollary),
// and there would be one cycle per subcircuit instance *at every nesting level*; the highest
// multiplicity leak in the propagation path. It is written here, in the module that owns
// `CircuitState`, so the `unowned` is right next to the strong edge it balances and the CI leak
// detector covers it.
//
// The split that makes this work: this class holds only what the *kernel* can name (a
// `CircuitState`, a `SimComponent`) and exposes every accessor upstream's class has.
// `LogisimStd` adds a small extension conforming it to that module's richer `InstanceState`
// protocol, the one the 108 `propagate` implementations are written against, which needs
// `Component`, `InstanceFactory` and `Port`. No stored state lives up there, so no ownership
// decision does either.
//
// ── D1/D2, standing rule 4: the reuse fast path ─────────────────────────────────────────────
//
// `repurpose` mutates `state` and `component` in place. `CircuitState` keeps exactly one of
// these per state and hands the same object back from `getReusableInstanceState`, which is only
// safe because propagation is synchronous, single-threaded and non-reentrant. Upstream measures
// per-call allocation as roughly a 90% slowdown on this path. Do not "fix" the aliasing.

import Foundation

/// `com.cburch.logisim.instance.InstanceStateImpl`.
///
/// The whole of what a component sees during `propagate`, as a kernel-level object.
public final class InstanceStateImpl: SimInstanceStateImpl {

  /// `private CircuitState circuitState`.
  ///
  /// **`unowned`, and this is load-bearing.** `CircuitState` holds `reusableInstanceState`
  /// strongly and hands this object back on every propagate; a strong edge here is an
  /// unconditional two-cycle on *every* circuit state in the tree, i.e. one per subcircuit
  /// instance at every nesting level.
  ///
  /// `unowned` rather than `weak` because the lifetime is genuinely nested: the only strong
  /// owner of the reusable instance is the very `CircuitState` this points at, and a
  /// non-reusable one is created, used and dropped inside a single call on a state the caller
  /// already holds. `unowned(unsafe)` is *not* used; a real `unowned` traps loudly if that
  /// invariant is ever broken, which is what you want for a scratch object that would otherwise
  /// read freed memory during propagation.
  private unowned var stateRef: CircuitState

  /// `private Component component`.
  ///
  /// **Strong, deliberately, and the asymmetry with `stateRef` is upstream behaviour.** Java's
  /// reference keeps a just-removed component alive for as long as this scratch object still
  /// points at it; `CircuitState`'s `ACTION_REMOVE` handler drops the component from the
  /// circuit while a propagation may still be reading through here. Making it `unowned` would
  /// convert that into a crash on the next read. It closes no cycle: a component never holds a
  /// strong reference to an `InstanceStateImpl` (see `component` in the initializer note below).
  ///
  /// Optional because `CircuitState` constructs its reusable instance with `null` for the
  /// component, `new InstanceStateImpl(this, null)`, and only fills it in on `repurpose`.
  private var componentRef: (any SimComponent)?

  /// `InstanceStateImpl(CircuitState, Component)`.
  ///
  /// **Upstream's constructor additionally calls `instComp.setInstanceStateImpl(this)`;
  /// `repurpose` does not.** That asymmetry is preserved by simply not having the call at all:
  /// D3 deletes the `Instance` facade and with it the component→instance-state edge, which was
  /// there so `Instance.fireInvalidated()` could find its state. `fireInvalidated()` below goes
  /// straight to the component instead, so nothing is lost and the strong edge that would have
  /// closed the cycle never exists.
  public init(_ state: CircuitState, _ component: (any SimComponent)?) {
    self.stateRef = state
    self.componentRef = component
  }

  // MARK: - SimInstanceStateImpl

  /// `repurpose(CircuitState, Component)`.
  public func repurpose(_ state: CircuitState, _ component: (any SimComponent)?) {
    self.stateRef = state
    self.componentRef = component
  }

  // MARK: - Accessors

  /// `getCircuitState()`.
  public var circuitState: CircuitState { stateRef }

  /// `getComponent()`; D3's replacement for `getInstance()`.
  ///
  /// Optional here where upstream's is not, because upstream's *reusable* instance genuinely
  /// starts life with a `null` component and every getter would NPE until the first `repurpose`.
  /// The upper layer's `InstanceState.component` is non-optional and traps on `nil`, which is
  /// correct there: reaching a component's `propagate` with no component is a programmer error
  /// no `.circ` can produce (D13's carve-out).
  public var simComponent: (any SimComponent)? { componentRef }

  /// `getAttributeSet()`.
  public var attributeSetOrNil: (any AttributeSet)? { componentRef?.componentAttributeSet }

  /// `getData()`.
  public var componentData: Any? {
    guard let componentRef else { return nil }
    return stateRef.getData(componentRef)
  }

  /// `setData(InstanceData)`.
  public func setComponentData(_ value: Any?) {
    guard let componentRef else { return }
    stateRef.setData(componentRef, value)
  }

  /// `getTickCount()`.
  public var tickCount: Int { stateRef.propagator.tickCount }

  /// `isCircuitRoot()`.
  public var isCircuitRoot: Bool { !stateRef.isSubstate }

  /// `fireInvalidated()`.
  ///
  /// Upstream reaches the component through `getInstance()`; with the facade gone (D3) this is
  /// the same call one hop shorter.
  ///
  /// ── AND IT MARKS THE COMPONENT DIRTY, WHICH IS THE HALF THAT WAS MISSING ────────────────
  ///
  /// `fireComponentInvalidated()` only notifies the component's own `ComponentListener`s, and
  /// **nothing in this port listens on behalf of the simulation**: upstream's
  /// `CircuitState.MyComponentListener.componentInvalidated` → `markComponentAsDirty` has no
  /// counterpart here, and `grep -rn markComponentAsDirty Sources/` finds only `CircuitState`'s
  /// own internal calls plus one in `TestVectorRun`, which marks components by hand. That
  /// hand-marking is why the headless `-tty` gates pass against the jar while the same code is
  /// inert behind the GUI.
  ///
  /// The consequence was the whole of "poking does nothing", and it survives every layer above
  /// being correct. Measured on a real host with a live simulation: `handleBitPress` returned
  /// `true` and moved a Pin's `intendedValue` from 0 to 1, and the value on its own port stayed
  /// `-` through a propagate *and* a tick, because the component was never dirty and
  /// `processDirtyComponents` therefore never called `Pin.propagate`.
  ///
  /// Marked here rather than by adding a listener registry because this is the one place that
  /// already holds **both** halves, the component and the state it belongs to, so there is no
  /// registration to keep in step with component add and remove, and no second source of truth
  /// about which state a component is being poked in.
  public func fireInvalidated() {
    guard let componentRef else { return }
    componentRef.fireComponentInvalidated()
    stateRef.markComponentAsDirty(componentRef)
  }

  /// `createCircuitSubstateFor(Circuit)`.
  ///
  /// Declared here rather than on `LogisimStd`'s `InstanceState` protocol for the reason that
  /// protocol's header gives: only `SubcircuitFactory` and `VhdlEntity` call it, and both hold a
  /// concrete `InstanceStateImpl`.
  public func createCircuitSubstate(for circuit: any SimCircuit) -> CircuitState? {
    guard let componentRef else { return nil }
    return stateRef.createCircuitSubstateFor(componentRef, circuit)
  }

  // MARK: - Ports

  /// The end at `portIndex`, or `nil` when there is no component or the index is out of range.
  ///
  /// Upstream indexes `component.getEnd(portIndex)` directly and lets an out-of-range index
  /// throw `ArrayIndexOutOfBoundsException`. That is not reachable from a `.circ`, the index
  /// always comes from a port number the factory itself defined, but it *is* reachable from a
  /// mis-ported component, and a trap during propagation is exactly what D13 forbids. The
  /// callers below degrade to `Value.NIL` / no-op instead, which is what a disconnected port
  /// already looks like.
  private func end(at portIndex: Int) -> WireEndInfo? {
    guard let componentRef else { return nil }
    let ends = componentRef.wireEnds
    guard ends.indices.contains(portIndex) else { return nil }
    return ends[portIndex]
  }

  /// `getPortValue(int)`.
  public func portValue(_ portIndex: Int) -> Value {
    guard let end = end(at: portIndex) else { return .nilValue }
    return stateRef.getValue(end.location)
  }

  /// `setPort(int, Value, int)`.
  public func setPort(_ portIndex: Int, _ value: Value, _ delay: Int) {
    guard let componentRef, let end = end(at: portIndex) else { return }
    stateRef.setValue(end.location, value, componentRef, delay)
  }

  /// `isPortConnected(int)`.
  public func isPortConnected(_ portIndex: Int) -> Bool {
    guard let componentRef, let end = end(at: portIndex) else { return false }
    return stateRef.circuit.isConnected(end.location, ignoring: componentRef)
  }
}

extension InstanceStateImpl: CustomStringConvertible {
  public var description: String {
    "InstanceStateImpl[\(componentRef.map { "\($0)" } ?? "nil") in \(stateRef)]"
  }
}
