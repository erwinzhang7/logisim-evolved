// SimulationSeamJoin.swift: part of logisim-evolved.
//
// Derived from logisim-evolution, https://github.com/logisim-evolution/logisim-evolution.
// Copyright by the Logisim-evolution developers. This translation is a derivative work and is
// therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// ── What this file is ───────────────────────────────────────────────────────────────────────
//
// The M3 kernel was built as three slices that never met. Java has one class per concept; the
// port has, for `CircuitState` alone, three *independent* seam protocols describing it:
// `PropagatorCircuitState` (PropagationEvent.swift), `WireCircuitState` (CircuitWires.swift) and
// the concrete `CircuitState` itself. Each slice compiled. Nothing joined them, so the engine
// could not run: `Propagator` had no state to drive and `CircuitWires` had no state to write
// into. "Each half built correctly and nothing owned the join" is, in this project's own words,
// the single largest defect class it has hit; six times.
//
// This file is that join, and it is deliberately one file so the join has an owner. It contains
// only conformances and forwarding; every behavioural decision stays in the slice that made it.
//
// ── The one ownership question the slices disagreed on, now settled ─────────────────────────
//
// `CircuitState.swift`'s header carried a ⚠ note: `CircuitState` holds its propagator strongly
// and requires `Propagator.root` to be the weak side, while `Propagator.swift`'s doc comment
// claimed the opposite. The code was already right, `Propagator.root` is declared
// `public private(set) weak var`, and only the prose disagreed. It is settled in that
// direction, for the reason `CircuitState` gives: `createRootState` and `cloneAsNewRootState`
// each construct a propagator inside an initializer and return *only the state*, so under the
// other rule the returned state's engine would have a zero strong count the instant the
// initializer returned.
//
//     CircuitState --(strong)--> Propagator --(weak)--> root CircuitState

import Foundation

// MARK: - CircuitState as the propagator's state tree

/// `Propagator`'s view of `CircuitState`. Every requirement is a rename or a direct forward; see
/// `PropagatorCircuitState`'s table for the Java correspondence.
extension CircuitState: PropagatorCircuitState {

  /// `CircuitState.getPropagator()`, under the name the propagator slice chose so that its
  /// requirement and this class's own `propagator` property can coexist.
  public var owningPropagator: Propagator? { propagator }

  /// `root.getProject().getOptions().getAttributeSet()`.
  ///
  /// `nil` in a headless run with no project, which is the case the propagator's own fallback
  /// (`simlimit = 1000`, `simrand = 0`) exists for; those are exactly the values a freshly
  /// constructed Java `Options` carries, so the fallback cannot diverge from upstream for a
  /// default project. A host that *has* a project must return its options through
  /// `SimProject.simulationOptions`, or a file setting `simrand`/`simlimit` is silently ignored.
  public var simulationOptions: (any PropagatorOptionsSource)? {
    projectSimulationOptions
  }

  /// `CircuitState.reset()`, under the propagator slice's defensive name.
  ///
  /// Non-throwing here where the requirement is `throws`: Swift lets a non-throwing function
  /// witness a throwing requirement, and `reset()` genuinely cannot fail; it only clears maps
  /// and calls the RAM/buzzer/GUI teardown hooks, none of which write values.
  public func resetStateTree() { reset() }
}

// MARK: - CircuitState as the wiring layer's state

/// `CircuitWires`' view of `CircuitState`.
///
/// Three of the four requirements are satisfied by members `CircuitState` already declares:
/// `wireData` (now a real `CircuitWires.State?`), `clearValuesByWire()` and one of the
/// `markComponentsDirty` overloads. Only `setValueByWire` needs a shim, because the two slices
/// spelled the same call with different argument labels.
extension CircuitState: WireCircuitState {

  /// `CircuitState.markComponentsDirty(Collection<Component>)`.
  ///
  /// `CircuitWires` stores its components as `WireComponent`, and this class's dirty list holds
  /// `SimComponent`. Since `SimComponent` now *refines* `WireComponent` (see the note on
  /// `SimComponent`), every component the wiring layer can hand back is already one; the
  /// `compactMap` cannot drop anything a real circuit produces. It is a `compactMap` rather than
  /// a force-cast because dropping a component from a dirty list degrades to a stale value,
  /// whereas trapping during propagation is what D13 forbids.
  public func markComponentsDirty(_ components: [any WireComponent]) {
    markComponentsDirty(components.compactMap { $0 as? any SimComponent })
  }

  /// `CircuitState.setValueByWire(Value, Location[], BusConnection[])`.
  public func setValueByWire(
    _ value: Value,
    locations: [Location],
    connections: [CircuitWires.BusConnection]
  ) {
    setValueByWire(value, locations, connections)
  }
}

// MARK: - PropagationEvent as a queued dirty point

/// `Propagator.SimulatorEvent` is what `CircuitState.dirtyPoints` holds, so `markPointAsDirty`
/// takes one directly and no `SimSimulatorEvent` box is needed. (`PropagationEvent`'s
/// `WireDirtyPoint` conformance, the other half of this join, is declared in
/// `CircuitWires.swift`, by the slice that consumes it.)

// MARK: - The project/options bridge

extension CircuitState {
  /// `root.getProject().getOptions()` in one hop, so the `PropagatorCircuitState` conformance
  /// above reads as a single forward.
  ///
  /// Upstream reads the options off the *root* project; every state in a tree shares one
  /// `Project`, and a substate's `proj` is the same object, so asking this state is equivalent.
  fileprivate var projectSimulationOptions: (any PropagatorOptionsSource)? {
    project?.simulationOptions
  }
}
