// LogSignalDiscovery.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.gui.log.Model's constructor scan,
// com.cburch.logisim.gui.log.ComponentSelector.findClocks, and
// com.cburch.logisim.gui.log.ClockSource.getCycleInfo),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── This is the file that touches real circuits ─────────────────────────────────────────────
//
// Everything else under Log/ is either pure data or talks only to a `LogSignalProbe`. This one
// imports LogisimFile and LogisimStd, walks a `Circuit`, and produces the `LogSignalInfo` list
// the model starts with: i.e. it fills in the three seams `LogModel` declares
// (`clockCycleProvider`, `clockCandidateProvider`, and the probe behind every row). Keeping it
// in one file means the model's dependency on the component library is a single, greppable
// edge rather than a scattering of `import LogisimStd`.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

/// Builds the default log selection for a circuit, as `Model(CircuitState)` does inline.
public enum LogSignalDiscovery {

  /// `Model`'s constructor scan: every non-subcircuit component that can be logged, inputs
  /// before outputs, each group ordered left-to-right then top-to-bottom.
  ///
  /// Upstream's filter is `makeIfDefaultComponent`: skip subcircuits, skip anything with no
  /// `LoggableContract`, and skip anything whose logger offers *options* (a RAM, whose options
  /// are its addresses; those are added explicitly by the user, not by default). With no
  /// component supplying the `loggable` feature yet (see LogSignalProbe.swift), the equivalent
  /// filter is: skip subcircuits, skip wires, and keep components with at least one connection
  /// point, which admits exactly the pins, LEDs, buttons and clocks upstream admits, and
  /// excludes the multi-address memories for the same reason.
  public static func defaultSignals(
    for circuit: Circuit,
    state: CircuitState?
  ) -> [LogSignalInfo] {
    var infos: [LogSignalInfo] = []
    for component in circuit.nonWires {
      guard let info = makeIfDefaultComponent(component, state: state) else { continue }
      infos.append(info)
    }

    // `Location.sortHorizontal(info)`: left to right, ties top to bottom.
    infos.sort { lhs, rhs in
      let a = probeLocation(lhs)
      let b = probeLocation(rhs)
      if a.x != b.x { return a.x < b.x }
      return a.y < b.y
    }

    // "sort: inputs before outputs": a stable partition, matching upstream's in-place
    // move-to-back loop, which preserves the horizontal order inside each group.
    let inputs = infos.filter(\.isInput)
    let outputs = infos.filter { !$0.isInput }
    return inputs + outputs
  }

  /// `Model.makeIfDefaultComponent(Component)`.
  public static func makeIfDefaultComponent(
    _ component: any Component,
    state: CircuitState?
  ) -> LogSignalInfo? {
    if component.factory is any SubcircuitFactory { return nil }
    if component.ends.isEmpty { return nil }
    return makeSignal(for: component, state: state)
  }

  /// Wraps one component as a loggable signal.
  public static func makeSignal(
    for component: any Component,
    state: CircuitState?,
    pathPrefix: [String] = []
  ) -> LogSignalInfo {
    let probe = CircuitPointProbe(
      component: component,
      state: state,
      name: LogComponentNaming.logName(of: component),
      isInput: isInputComponent(component)
    )
    return LogSignalInfo(probe: probe, pathPrefix: pathPrefix)
  }

  /// `LoggableContract.isInput(option)`, as the components that implement it answer it.
  ///
  /// Upstream's `Model` comment enumerates the inputs: "things like Button, Clock, Pin(input),
  /// and Random". A `Pin` answers from its `attrType`; the other three answer `true`
  /// unconditionally because they drive the circuit with no input of their own.
  public static func isInputComponent(_ component: any Component) -> Bool {
    let factory = component.factory
    if factory is Pin { return Pin.isInputPin(component.attributeSet) }
    if factory is Clock { return true }
    // Anything with only output-typed ends drives the circuit and is therefore an input to the
    // log. This is the general form of upstream's per-component answers and needs no per-factory
    // table, so a component family ported later is classified correctly without an edit here.
    return component.ends.allSatisfy { $0.type == .outputOnly }
  }

  /// `ComponentSelector.findClocks(Circuit)`.
  ///
  /// Upstream returns three distinguishable things through one nullable list: a non-empty list
  /// of real `Clock` components; an *empty* list meaning "no clocks, but something 1-bit that
  /// could serve as one, so ask the user"; and `null` meaning "nothing usable at all". That
  /// tri-state through a nullable collection is exactly the kind of API a port should not carry
  /// over, so it becomes an enum.
  public static func findClocks(in circuit: Circuit, state: CircuitState?) -> LogClockSearch {
    var clocks: [LogSignalInfo] = []
    for component in circuit.nonWires where component.factory is Clock {
      clocks.append(makeSignal(for: component, state: state))
    }
    if !clocks.isEmpty { return .clocks(clocks) }

    // OBSERVEABLE_CLOCKS: any 1-bit signal, including inside subcircuits. Only its emptiness is
    // used, so the list itself is discarded, upstream clears it too.
    let hasObservable = circuit.nonWires.contains { component in
      !(component.factory is any SubcircuitFactory)
        && component.ends.contains { $0.width.width == 1 }
    }
    return hasObservable ? .candidatesOnly : .none
  }

  /// `ClockSource.getCycleInfo(SignalInfo)`.
  ///
  /// Reads `Clock.ATTR_HIGH` / `ATTR_LOW` / `ATTR_PHASE` off the component; anything that is not
  /// a `Clock` gets `DEFAULT_CYCLE_INFO`, as upstream does.
  ///
  /// This is the concrete implementation of `LogModel.clockCycleProvider`; the seam is filled
  /// in by `install(on:for:state:)` below, not merely declared.
  public static func cycleInfo(for component: any Component) -> LogClockCycle {
    guard component.factory is Clock else { return .default }
    let attributes = component.attributeSet
    let high = Int(attributes[Clock.attrHigh] ?? 1)
    let low = Int(attributes[Clock.attrLow] ?? 1)
    let phase = Int(attributes[Clock.attrPhase] ?? 0)
    return LogClockCycle(high: max(high, 1), low: max(low, 1), phase: max(phase, 0))
  }

  /// Installs the three circuit-dependent seams on a model.
  ///
  /// Call this for any model that is going to observe a live circuit. Without it the model still
  /// works, it falls back to a 1/1/0 clock cycle and an empty candidate list, but clocked
  /// capture will use the wrong period for any clock whose duty cycle is not 50%.
  public static func install(
    on model: LogModel,
    for circuit: Circuit,
    state: CircuitState?
  ) {
    model.clockCycleProvider = { info in
      guard let probe = info.probe as? CircuitPointProbe, let component = probe.component
      else { return .default }
      return cycleInfo(for: component)
    }
    model.clockCandidateProvider = {
      switch findClocks(in: circuit, state: state) {
      case .clocks(let list): list
      case .candidatesOnly, .none: []
      }
    }
  }

  // MARK: - Helpers

  private static func probeLocation(_ info: LogSignalInfo) -> Location {
    (info.probe as? CircuitPointProbe)?.location ?? Location.create(0, 0, hasToSnap: false)
  }
}

/// The result of `findClocks`; see the note on that method for why this is not a nullable list.
public enum LogClockSearch: Equatable {
  /// Real `Clock` components were found.
  case clocks([LogSignalInfo])
  /// No clocks, but 1-bit signals that could be observed as one. Upstream asks the user.
  case candidatesOnly
  /// Nothing usable.
  case none

  public static func == (lhs: LogClockSearch, rhs: LogClockSearch) -> Bool {
    switch (lhs, rhs) {
    case (.candidatesOnly, .candidatesOnly), (.none, .none): true
    case (.clocks(let a), .clocks(let b)): a.count == b.count && zip(a, b).allSatisfy { $0 === $1 }
    default: false
    }
  }
}
