// LogSignalProbe.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.gui.log.{LoggableContract, SignalInfo}:
// the value-fetching half), https://github.com/logisim-evolution/logisim-evolution. Copyright by
// the Logisim-evolution developers. This translation is a derivative work and is therefore
// GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── The seam, and why it is filled in twice ─────────────────────────────────────────────────
//
// Upstream asks a component for `LoggableContract` through `Component.getFeature(Loggable.class)`
// and then calls `getLogValue(CircuitState, option)`. In this port:
//
//   * `ComponentFeatureKey.loggable` exists (LogisimFile/Component.swift:59), but
//     `InstanceComponent.feature(_:)` returns `nil` unconditionally and **no component in
//     LogisimStd supplies any feature yet**. So routing through the feature key would produce a
//     Log window that is wired, compiles, and logs nothing; precisely the defect class the
//     seam check exists to catch.
//   * `LoggableContract` cannot usefully be declared here anyway: LogisimStd does not depend on
//     LogisimUI, so a protocol declared in this module has no reachable conformer. It belongs in
//     LogisimFile alongside the feature key it is looked up by. That move is reported to the
//     integrator rather than made here; LogisimFile is another agent's file set.
//
// So the value seam is `LogSignalProbe`, and it is filled in by TWO concrete conformers in this
// same file, neither of them a stub:
//
//   * `CircuitPointProbe` reads the live simulation through `CircuitState.getValue(Location)` at
//     a component's own connection point. That is what upstream's `Pin`, `Led`, `Button`,
//     `Clock` and `Tty` loggers ultimately return, and it needs nothing from the component
//     beyond its end locations, so it works for every single-ended component today.
//   * `ManualProbe` holds a value that is written from outside. It backs the tests, the SwiftUI
//     previews, and any host that already has values in hand.
//
// When `LoggableContract` lands in LogisimFile, a third conformer forwards to it and
// `CircuitPointProbe` becomes the fallback for components that do not implement it; the same
// two-tier arrangement `SignalInfo.logName` already uses for names.

import Foundation
import LogisimFile
import LogisimKernel

/// The source of one logged signal's value, name and width.
///
/// Reference type: a probe is shared by the model, the table and the chronogram, and it tracks a
/// live component.
public protocol LogSignalProbe: AnyObject {
  /// `SignalInfo.getShortName()`'s input: the component's own log name, without any path
  /// prefix or width suffix.
  var probeName: String { get }

  /// `SignalInfo.getWidth()`; bits. `0` means the probe cannot currently determine a width,
  /// which renders as `NIL`.
  var probeWidth: Int { get }

  /// `LoggableContract.isInput(option)`. `Model`'s constructor sorts inputs before outputs.
  var probeIsInput: Bool { get }

  /// `SignalInfo.fetchValue(CircuitState)`. `nil` when the probe has gone stale; the component
  /// was deleted, or the simulation state it referred to is gone. The model turns that into
  /// `Value.NIL` rather than dropping the row, so a deleted pin leaves a visible gap instead of
  /// silently renumbering every row below it.
  func readValue() -> Value?
}

// MARK: - The live conformer

/// Reads a component's value out of a running simulation.
///
/// `CircuitState.getValue(Location)` is the port's equivalent of upstream's per-component
/// `getLogValue`: for a `Pin`, `Led`, `Button` or `Clock` the logged value *is* the value on the
/// wire at its connection point, and reading it there means the probe works without every
/// component having to implement a logging protocol first.
///
/// D3: the state is held **weakly**. A `CircuitState` owns its substates and its component data;
/// a Log window that outlived a closed document would otherwise pin the entire simulation tree
/// and every component in it, which is exactly the leak D3's corollary tells us tests cannot see.
public final class CircuitPointProbe: LogSignalProbe {

  /// The point on the netlist this probe samples.
  public let location: Location

  /// The component the point belongs to, for naming. Weak for the same reason as the state:
  /// `Circuit` owns its components (D3), and a log row must not resurrect a deleted one.
  ///
  /// Readable so that `LogSignalDiscovery` can ask a probe for its clock attributes without a
  /// linear scan of the circuit keyed on the sampled location; two components can legitimately
  /// share a point, and matching on it would pick an arbitrary one of them.
  public private(set) weak var component: (any Component)?

  private weak var state: CircuitState?

  /// Cached so the row keeps its name and its place in the table after the component is deleted,
  /// rather than collapsing to "?" and reordering everything.
  private let cachedName: String
  private var cachedWidth: Int
  private let input: Bool

  /// - Parameters:
  ///   - component: the component being logged. Its first end (or, for a component with no ends,
  ///     its own location) is the point sampled.
  ///   - state: the simulation state to read from.
  ///   - name: the display name, normally from `LogComponentNaming.logName(of:)`.
  ///   - isInput: whether the component drives the circuit rather than observing it.
  public init(
    component: any Component,
    state: CircuitState?,
    name: String,
    isInput: Bool
  ) {
    self.component = component
    self.state = state
    self.location = component.ends.first?.location ?? component.location
    self.cachedName = name
    self.cachedWidth = component.ends.first?.width.width ?? 0
    self.input = isInput
  }

  public var probeName: String { cachedName }

  public var probeWidth: Int {
    // Re-read from the component while it is alive: a Pin's width attribute can change under a
    // running log, and upstream's `computeName` re-reads it on every attribute event.
    if let width = component?.ends.first?.width.width {
      cachedWidth = width
    }
    return cachedWidth
  }

  public var probeIsInput: Bool { input }

  public func readValue() -> Value? {
    guard let state else { return nil }
    return state.getValue(location)
  }
}

// MARK: - The externally-driven conformer

/// A probe whose value is pushed in from outside.
///
/// Not a test double: this is the conformer a host uses when it already has the value; a replay
/// of a recorded run, a test vector being stepped, or a SwiftUI preview. Tests use it too, which
/// is what makes the whole log model runnable with no simulation attached at all.
public final class ManualProbe: LogSignalProbe {
  public let probeName: String
  public var probeWidth: Int
  public let probeIsInput: Bool

  /// The value `readValue()` returns. Setting it does **not** notify the model; the host calls
  /// `LogModel.propagationCompleted` when it has finished writing all of them, so one update
  /// produces one sample row rather than one per signal.
  public var currentValue: Value?

  public init(name: String, width: Int, isInput: Bool = false, value: Value? = nil) {
    self.probeName = name
    self.probeWidth = width
    self.probeIsInput = isInput
    self.currentValue = value
  }

  public func readValue() -> Value? { currentValue }
}
