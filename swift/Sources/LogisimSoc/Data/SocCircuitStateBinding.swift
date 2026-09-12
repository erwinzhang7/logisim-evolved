// SocCircuitStateBinding.swift: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE CONFORMANCE THAT WAS DESCRIBED IN PROSE AND NEVER WRITTEN
//
// `SocBusInterfaces.swift` documents `SocCircuitStateToken` as the seam for
// `com.cburch.logisim.circuit.CircuitState`, and says:
//
//     The simulation module's real `CircuitState` needs only to conform (trivially, since D4
//     already keys everything on reference identity): `extension CircuitState:
//     SocCircuitStateToken {}`.
//
// Nothing conformed. `grep -rn SocCircuitStateToken swift/Sources` found the declaration, seven
// uses inside this module, and **no conformer anywhere in the tree**, so every
// `SocSimulationManager.data(for:)` and `.instanceState(for:)` returned `nil` by construction,
// and `initializeTransaction` could not be called at all because no caller could produce the
// argument. That is seam-shaped exactly like the eleven before it: the protocol is right, the
// consumers are right, and nothing owns the join.
//
// ── Why it lives here and not in the simulation module ──────────────────────────────────────
//
// The prose assumed the arrow had to point down from the simulation module. It does not.
// `CircuitState` is `LogisimKernel`'s, `Component`/`InstanceState` are `LogisimFile`'s and
// `LogisimStd`'s, and `LogisimSoc` already depends on all three, so this module can name every
// type involved and declare the conformance itself. Writing it here also keeps it next to the
// protocol it satisfies, which is what makes the pair reviewable as one thing.
//
// Retroactive conformance on a type from another module is normally worth a second look; here
// it is the correct direction, because the protocol exists *only* to describe what this module
// needs and no other module should be made to know about it.
//
// ── The `SimComponent`/`Component` bridge ───────────────────────────────────────────────────
//
// `CircuitState`'s two accessors take `any SimComponent` (the kernel's view), while every SoC
// caller holds `any Component` (the file layer's view). `LogisimStd.SimulatableComponent`
// refines both and is what the five real component classes conform to, so the downcast below is
// the same join `ComponentSimulationSeams.swift` already establishes; not a new one. A
// component that is not simulatable answers `nil`, which is what Java's `getData` would return
// for a component the state has never seen anyway.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

extension CircuitState: SocCircuitStateToken {

  /// `CircuitState.getData(Component)`; used by every peripheral's `getRegPropagateState()`
  /// (Java: `SocSimulationManager.getdata`) to reach its own live register state.
  ///
  /// `getData` returns `Any?` because upstream's is `Object`; the SoC callers all store class
  /// instances (`SocMemoryInfo`, `PioRegState`, `SocBusTraceLog`), so `AnyObject?` is the
  /// narrower and more honest return. A value type stored in the slot answers `nil` rather than
  /// being boxed into something the caller would then fail to downcast; the boxed form would
  /// satisfy `as AnyObject` on Darwin and then miss every `as? PioRegState` test, which is a
  /// silent wrong answer rather than a loud one.
  public func socComponentData(for component: any Component) -> AnyObject? {
    guard let simComponent = component as? any SimulatableComponent else { return nil }
    guard let data = getData(simComponent) else { return nil }
    return data as? AnyObject
  }

  /// `CircuitState.getInstanceState(Component)`; used by `PioState.getPropagateState()` to
  /// re-invoke `handleOperations` on a register write (Java: `SocSimulationManager.getState`).
  ///
  /// Upstream's method throws on a non-instance component; D13 keeps that catchable, and this
  /// seam's signature is non-throwing, so the two failure modes both answer `nil` here. That is
  /// not a swallowed error: the only caller uses the result to *optionally* nudge a peripheral's
  /// propagation, and Java's own `SocSimulationManager.getState` is called on components it has
  /// already established are SoC instance components.
  public func socInstanceState(for component: any Component) -> (any InstanceState)? {
    guard let simComponent = component as? any SimulatableComponent else { return nil }
    return try? getInstanceState(simComponent) as? any InstanceState
  }
}
