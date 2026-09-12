// CanvasSimulation.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (the parts of com.cburch.logisim.gui.main.Canvas and
// com.cburch.logisim.circuit.Propagator that join the editing thread to the simulation),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE EDITING LAYER'S WINDOW ONTO THE LIVE SIMULATION.
//
// ── The gap this closes ─────────────────────────────────────────────────────────────────────
//
// Reported from real use: "poke tool seems to not do jack actually." It did not, and neither did
// anything else that needs a running circuit. Two facts, one cause:
//
//   * `CircuitEditorCanvas.circuitState` was assigned in exactly two places in the repository and
//     both were test files, so in the shipping app it was permanently `nil`. `PokeTool` built
//     every `ComponentUserEvent` with `state: nil`, and handed each component's poker nothing.
//   * `CircuitSceneSource.paintContext` hard-coded `showState: false`, so the schematic always
//     rendered in its unpowered form no matter what the simulator was doing.
//
// The simulator itself was never the problem. `SimulationEngine` owns a real propagation thread
// that ticks, propagates and resets, and the propagation kernel passes the jar-oracle `-tty table`
// gates. It was running the whole time with no window into it.
//
// ── Why it had not been done, and why that reason turned out to be smaller than it looked ───
//
// `Project.swift` and `SimulationEngine.swift` both record the blocker: `Propagator` asserts
// thread identity, mirroring Java's `Thread.currentThread() != propagatorThread` checks, so a
// `CircuitState` may only be *driven* from the propagation thread, and the canvas is
// `@MainActor`. Both headers concluded that closing this needs a decision about how the editing
// layer observes simulation state across that boundary.
//
// **It needs much less than that, because upstream already answered it.** Reading the assertions
// rather than counting them: they are on `propagate`, `reset` and `step`, the three *driving*
// entry points, and nowhere else. `Propagator.setValue` explicitly branches on the calling
// thread and, when it is not the propagation thread, parks the event in `nonPropThreadEvents` for
// the propagation thread to collect (`Propagator.swift:548-565`). That list exists for exactly
// one caller in upstream: **the EDT, poking.** `CircuitState.markComponentAsDirty` likewise takes
// its own `dirtyLock`. So a poke from the editing thread is not a violation of the design, it is
// the case the design was built for.
//
// What genuinely does race is unsynchronised *reading* of `CircuitState`'s tables while the
// propagation thread mutates them. That already has an answer too, and it is also not new:
// `SimulationEngine.modelLock`, which the propagation thread holds for the whole of one request
// and which `LogisimFileProjectHost` already takes around every `CircuitMutation`. So this file
// is a lock discipline, not an architecture:
//
//     the editing thread may touch the live state, but only inside `withModelLock`.
//
// Every entry point below holds it. Nothing here hops threads, nothing blocks on a semaphore, and
// no state is cloned or snapshotted.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimStd

// MARK: - The seam

/// What the editing layer is allowed to do with a running simulation.
///
/// A protocol rather than a direct reference to `SimulationEngine` for two reasons. Tests build a
/// `CircuitEditorCanvas` with no engine at all and must keep being able to; and the contract the
/// canvas actually needs is three members wide, where the engine's is thirty. `D9`: the narrow
/// thing is the one that crosses.
@MainActor
protocol CanvasSimulationAccess: AnyObject {

  /// Run `body` with the simulation's model lock held.
  ///
  /// **Every read or write of `liveState` must be inside one of these.** The propagation thread
  /// holds the same lock for the duration of one request, so this is what makes an editing-thread
  /// touch serialise against a propagation rather than tear one.
  func withModelLock<T>(_ body: () -> T) -> T

  /// The live root state. **Only valid inside `withModelLock`**, and nil when nothing is being
  /// simulated (no circuit, or the propagation thread has not built its session yet).
  var liveState: CircuitState? { get }

  /// Ask the propagation thread to settle the circuit again, after an edit or a poke.
  ///
  /// Asynchronous by construction: it queues and returns. A poke's effect therefore appears on
  /// the *next* frame, which is upstream's behaviour too; `PinPoker` calls `fireInvalidated`
  /// and lets the simulator get to it.
  func requestPropagate()
}

// MARK: - The engine's conformance

/// `CanvasSimulationAccess` over the real `SimulationEngine`.
///
/// A separate object rather than a conformance on the engine, because the engine is
/// `@unchecked Sendable` and lives partly on the propagation thread, while this protocol is
/// `@MainActor`. Conforming the engine directly would put a main-actor-isolated view on an object
/// whose whole point is that it is not one.
@MainActor
final class EngineSimulationAccess: CanvasSimulationAccess {

  /// **Weak (D3).** `LogisimFileProjectHost` owns the engine and owns the canvas; this sits
  /// between them and must not keep the engine alive past the host.
  ///
  /// It was `unowned` for exactly one build, on the reasoning that "the host constructs both
  /// together and drops both together". That reasoning is false and the cost of it was not a
  /// wrong answer but a dead process: a `CircuitCanvasSurface` outlives its host routinely, a
  /// test rig drops the host and keeps the surface, and every closed document does the same,
  /// and the first paint after that read a destroyed reference and took the whole test binary
  /// down with `Attempted to read an unowned reference but object … was already destroyed`.
  /// Weak makes that case what it actually is: a canvas with no simulation behind it any more,
  /// which is a state the rest of this file already handles.
  private weak var engine: SimulationEngine?

  init(engine: SimulationEngine) {
    self.engine = engine
  }

  /// With no engine there is no propagation thread to be excluded from, so the body runs inline.
  /// Same answer `ToolCanvas.withSimulation`'s default gives, for the same reason.
  func withModelLock<T>(_ body: () -> T) -> T {
    guard let engine else { return body() }
    engine.modelLock.lock()
    defer { engine.modelLock.unlock() }
    return body()
  }

  var liveState: CircuitState? { engine?.currentState }

  func requestPropagate() {
    engine?.post(.propagate)
  }
}

// MARK: - What the poke tool sees

/// `ToolCircuitState` over the live simulation; the object that was permanently `nil`.
///
/// Both methods take the model lock. `instanceState(for:)` hands the caller an
/// `InstanceStateImpl` that belongs to the propagation thread's object graph, and that is
/// deliberate rather than an oversight: a poker does not merely read through the `InstanceState`,
/// it reaches `InstanceData` out of it and mutates that object directly; `PinPoker.handleBitPress`
/// sets `PinState.intendedValue` on the very object the propagation thread will read. A proxy
/// cannot intercept that, so there is nothing to be gained by pretending the reference is
/// isolated. What keeps it correct is the caller: `PokeTool` runs every caret interaction inside
/// `ToolCanvas.withSimulation`, which takes the same lock.
@MainActor
final class EngineToolCircuitState: ToolCircuitState {

  private let access: any CanvasSimulationAccess

  init(access: any CanvasSimulationAccess) {
    self.access = access
  }

  /// `CircuitState.getValue(Location)`, what a `WireCaret` displays.
  func value(at location: Location) -> Value? {
    access.withModelLock { access.liveState?.getValue(location) }
  }

  /// `CircuitState.getInstanceState(Component)`.
  ///
  /// `try?` rather than a rethrow: upstream throws `RuntimeException("getInstanceState requires
  /// instance component")` for a component whose factory is not an `InstanceFactory`, and the
  /// poke tool's answer to that is the same as its answer to "this component has no poker";
  /// nothing happens. D13 keeps it catchable; there is simply nothing useful to report.
  func instanceState(for component: any Component) -> (any InstanceState)? {
    access.withModelLock { () -> (any InstanceState)? in
      guard let state = access.liveState,
        let simComponent = component as? any SimComponent
      else { return nil }
      return try? state.getInstanceState(simComponent) as? any InstanceState
    }
  }
}

// MARK: - What the canvas paints

/// `PaintContext` backed by a live `CircuitState`; the other half of the gap.
///
/// `StaticPaintContext` answers `value(at:)` with `.nilValue` and `data(for:)` with `nil`, which
/// is why the schematic rendered unpowered. This answers both out of the running simulation, so
/// wires take their logic colours, a Pin shows the value it is driving, and anything drawing from
/// `InstanceData`, an LED, a seven-segment digit, a register's contents, shows what it actually
/// holds.
///
/// **Only construct and use this inside `withModelLock`.** It holds the state directly and takes
/// no lock of its own: a paint makes hundreds of calls and locking per call would be both slower
/// and *less* correct, since the frame could then straddle a propagation and paint half of one
/// circuit state and half of the next.
final class LiveCircuitPaintContext: PaintContext {

  private let state: CircuitState

  let showState: Bool
  let showColor: Bool
  let isPrintView: Bool
  let gateShape: GateShape
  let pinAppearance: PinAppearance
  let componentColor: SceneColor
  let projectOptions: any AttributeSet

  /// The canvas ground, so the port-marker ring's hole reads as a hole on a dark canvas as well
  /// as a light one. Same override `StaticPaintContext` takes, for the same reason.
  var markerHoleColorOverride: SceneColor?

  init(
    state: CircuitState,
    showColor: Bool,
    gateShape: GateShape,
    pinAppearance: PinAppearance,
    componentColor: SceneColor,
    projectOptions: (any AttributeSet)? = nil
  ) {
    self.state = state
    self.showState = true
    self.showColor = showColor
    self.isPrintView = false
    self.gateShape = gateShape
    self.pinAppearance = pinAppearance
    self.componentColor = componentColor
    self.projectOptions = projectOptions ?? StaticPaintContext().projectOptions
  }

  var shouldDrawColor: Bool { !isPrintView && showColor }

  var markerHoleColor: SceneColor {
    markerHoleColorOverride ?? PortMarkerRing.holeColor(ink: componentColor)
  }

  func value(at location: Location) -> Value { state.getValue(location) }

  /// `Circuit.isConnected(Location, Component)`: asked of the *simulated* circuit, which is
  /// where the point index that answers it lives (`SimulatedCircuit.isConnected`). Note the
  /// argument flips from "excluding" to upstream's "ignoring": same predicate, two names, and
  /// this is the one place they meet.
  func isConnected(_ location: Location, excluding component: (any Component)?) -> Bool {
    guard let ignored = component as? any SimComponent else { return false }
    return state.circuit.isConnected(location, ignoring: ignored)
  }

  func data(for component: any Component) -> (any InstanceData)? {
    guard let simComponent = component as? any SimComponent else { return nil }
    return state.getData(simComponent) as? any InstanceData
  }

  func setData(_ data: (any InstanceData)?, for component: any Component) {
    guard let simComponent = component as? any SimComponent else { return }
    state.setData(simComponent, data)
  }

  var tickCount: Int { state.propagator.tickCount }

  var isCircuitRoot: Bool { !state.isSubstate }
}
