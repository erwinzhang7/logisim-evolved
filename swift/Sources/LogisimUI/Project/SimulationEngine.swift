// SimulationEngine.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.circuit.Simulator and its SimThread),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── What this is ────────────────────────────────────────────────────────────────────────────
//
// The join between the D7 phase-anchored clock (`LogisimKernel/Simulation`), the propagation
// core (`LogisimKernel/Propagation` through `LogisimStd`'s `SimulationSession`), and the shell's
// `SimulationStatus` snapshot. It replaces `DemoProjectHost.perform(_ command:)`, which toggled
// booleans and assigned `achievedTickHz = requestedTickHz`; the exact `TickCounter` behaviour
// D7 exists to eliminate.
//
// **There is no `Timer` in this file, and there must never be one.** The rate control drives
// `SimulationClock.setTicksPerSecond`, which re-anchors a `TickSchedule` whose deadlines are
// `origin + n * period`. That is the headline fix.
//
// ── D1: which thread everything runs on ─────────────────────────────────────────────────────
//
// `SimulationClock` owns a `Thread` (`logisim.simulation-clock`, `.userInteractive`) and calls
// `handleTick` on it. **That thread is the propagation thread.** `Propagator` asserts thread
// identity at 62 sites, mirroring Java's `Thread.currentThread() != propagatorThread` checks, so
// every `propagate`, `step`, `reset` and `toggleClocks` in the process has to happen there:
// including the ones the user triggers from a menu on the main thread.
//
// Two consequences shape the whole design:
//
//   1. The `SimulationSession` (and therefore `SimulationHost.simulationThread`) can only be
//      built *on* that thread, because it captures `Thread.current`. So it is created lazily
//      inside the first `handleTick`, never in `init`.
//
//   2. A UI request is not executed inline. It is queued, the clock thread is woken with
//      `requestManualTick`, and the thread drains the queue. `wakeDebt` below is what keeps
//      that wake accounting exact: see `handleTick`.
//
// Results come back the other way through `publish`, which hops to the main actor the way
// `LogController.onMain` does and for the same stated reason: `MainActor.assumeIsolated` would
// **trap** here, because these callbacks genuinely originate off the main thread. That hop is
// copied deliberately rather than reinvented.
//
// ── The model lock ──────────────────────────────────────────────────────────────────────────
//
// The propagation thread reads `Circuit` while the editing thread mutates it. Upstream has the
// same situation and answers it with `CircuitLocker`, taken by `CircuitTransaction` precisely so
// a transaction can run off the EDT. `modelLock` is the small version of that: the propagation
// thread holds it for the duration of one request, and `LogisimFileProjectHost` holds it around
// every `CircuitMutation`. Uncontended it is two atomics; contended it serialises an edit
// against one propagation, which is the correct answer.
//
// ── What is deliberately NOT here ───────────────────────────────────────────────────────────
//
// Reading simulated values back onto the canvas. `CircuitSceneSource.paintContext` builds a
// `StaticPaintContext(showState: false)`, so the schematic renders in its unpowered form and
// nothing on the main thread reads a `CircuitState`. Wiring live values into the canvas means
// solving "the renderer samples committed state at display refresh" (D7's last sentence), which
// is a renderer-side change in a file this slice does not own. Stated here so the absence is a
// documented gap and not a seam: `currentState` below is the handle that work will need.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

// MARK: - Requests

/// What the propagation thread can be asked to do. One case per thing upstream's `SimThread`
/// loop handles.
enum SimulationRequest {
  /// `Simulator.tick(int)`: `toggleClocks()` then `propagate()`, `count` half-cycles.
  case tick(count: Int)
  /// `Simulator.step()`: one propagation step, for single-stepping a circuit.
  case step
  /// `Simulator.reset()`: a fresh root state, which is what upstream's reset actually does.
  case reset
  /// Point the engine at a different circuit (the explorer changed the current circuit).
  case setCircuit(UncheckedSendableBox<Circuit?>)
  /// Re-propagate after an edit, when auto-propagation is on.
  case propagate
}

// MARK: - Snapshot

/// Everything the shell needs to know about the simulation, as one value.
///
/// Every field is measured. `achievedTickHz` is an `Optional` all the way from
/// `TickRateReport.achievedTicksPerSecond` and there is no path in this file that fills it with
/// the request; that substitution is the specific upstream behaviour D7 names.
struct SimulationSnapshot: Sendable, Equatable {
  var isAutoPropagating = true
  var isTicking = false
  var requestedTickHz: Double = 1
  var achievedTickHz: Double?
  var tickJitterSeconds: Double?
  var isFallingBehind = false
  var canStep = false
  var errorMessage: String?
  var oscillationDetected = false
  var currentStateName: String?
  var canAscendState = false
  /// `Propagator.tickCount`; half clock cycles since the state was created.
  var halfCycleCount: Int = 0
  /// How many requests the propagation thread has completed.
  ///
  /// Deliberately **not** part of `SimulationStatus`: the status is what the shell's toolbar
  /// shows and it must not churn sixty times a second. This is the canvas's staleness signal:
  /// monotonic, bumped once per `publish`, and the only thing that tells the renderer a value
  /// somewhere changed without the circuit's shape changing. See
  /// `CircuitSceneGeometryKey.simulationRevision`.
  var propagationCount: UInt64 = 0

  /// `THREAD_TIME_CONSTRAINT_POLICY` was requested and granted. Reported because "we asked for
  /// realtime" and "we got it" are different facts (`TickRateReport.isRealtimeScheduled`).
  var isRealtimeScheduled = false

  var status: SimulationStatus {
    SimulationStatus(
      isAutoPropagating: isAutoPropagating,
      isTicking: isTicking,
      requestedTickHz: requestedTickHz,
      achievedTickHz: achievedTickHz,
      tickJitterSeconds: tickJitterSeconds,
      isFallingBehind: isFallingBehind,
      canStep: canStep,
      errorMessage: errorMessage,
      oscillationDetected: oscillationDetected,
      currentStateName: currentStateName,
      canAscendState: canAscendState)
  }
}

// MARK: - Engine

/// Owns the clock, the propagation thread's state, and the request queue between them.
///
/// D3: the engine holds the clock strongly and the clock holds its handler (this object)
/// **weakly**, `SimulationClock.setHandler`'s own contract, so there is no cycle. The host
/// holds the engine; the engine's callback out is a closure the host installs and the host owns
/// nothing on the far side of it (see `onChange`).
final class SimulationEngine: SimulationTickHandler, @unchecked Sendable {

  // MARK: Cross-thread state

  private let lock = NSLock()
  private var queue: [SimulationRequest] = []
  /// Wakes posted with `requestManualTick` that have not yet been consumed.
  ///
  /// Without it there is a real race: an auto-tick invocation can drain a queued request, and
  /// the pump wake that was meant to service that request then arrives to find an empty queue
  /// and would perform a *second* tick. Counting the debt makes the pairing exact: the extra
  /// wake sees `wakeDebt > 0`, consumes one, and does nothing. The scheduled tick that gave up
  /// its slot is skipped rather than doubled, which is both the safer direction and what
  /// upstream's loop does (one request per pass).
  private var wakeDebt = 0
  private var snapshotStorage = SimulationSnapshot()

  /// Held by the propagation thread for one request, and by the editing thread around a
  /// `CircuitMutation`. See the file header.
  let modelLock = NSRecursiveLock()

  // MARK: Propagation-thread-only state
  //
  // Everything in this section is touched exclusively from inside `handleTick`, i.e. on the
  // clock thread. No lock guards it because no other thread may look at it.

  private var session: SimulationSession?
  private var currentStateStorage: CircuitState?
  private var simulatedCircuit: Circuit?
  private var lastError: String?

  // MARK: Immutable wiring

  /// The document. **Strong**, and it closes no cycle: `LogisimFile` has no reference to the
  /// engine, and the engine has to keep the file's `<options>` alive because `simrand`/
  /// `simlimit` are read through it on every propagation.
  private let fileBox: UncheckedSendableBox<LogisimFile>

  /// The D7 clock. Free of any `Timer`, by construction.
  let clock: SimulationClock

  /// Called on the **main actor** whenever the snapshot changes.
  private var onChange: (@MainActor (SimulationSnapshot) -> Void)?

  init(file: LogisimFile) {
    self.fileBox = UncheckedSendableBox(file)
    let initial = file.mainCircuit?.tickFrequency ?? -1
    self.clock = SimulationClock(
      ticksPerSecond: initial > 0 ? initial : 1, mode: .realTimeLocked)
    snapshotStorage.requestedTickHz = clock.ticksPerSecond
    clock.setHandler(self)
  }

  deinit {
    // The clock's own `deinit` stops its thread, but the engine may outlive nothing and the
    // thread must not outlive the circuits it propagates. Stopping explicitly makes the
    // ordering deterministic instead of dependent on release order.
    clock.stop(timeout: 2.0)
  }

  // MARK: - Main-thread API

  @MainActor
  func setObserver(_ observer: @escaping @MainActor (SimulationSnapshot) -> Void) {
    lock.lock()
    onChange = observer
    lock.unlock()
  }

  var snapshot: SimulationSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return snapshotStorage
  }

  /// Queue a request and wake the propagation thread.
  func post(_ request: SimulationRequest) {
    lock.lock()
    queue.append(request)
    wakeDebt += 1
    lock.unlock()
    clock.requestManualTick(count: 1)
  }

  /// `Simulator.setIsTicking(boolean)`.
  func setTicking(_ on: Bool) {
    if on { clock.start() } else { clock.pause() }
    refreshClockFields()
  }

  /// `Simulator.setTickFrequency(double)`; **the D7 control.**
  ///
  /// This goes straight to `SimulationClock.setTicksPerSecond`, which re-anchors the schedule
  /// origin and resets the statistics, because a rate change is a new schedule and an achieved
  /// rate averaged across a frequency change measures nothing.
  func setTickFrequency(_ hz: Double) {
    clock.setTicksPerSecond(hz)
    refreshClockFields()
  }

  var tickFrequency: Double { clock.ticksPerSecond }

  /// `Simulator.setAutoPropagation(boolean)`.
  func setAutoPropagating(_ on: Bool) {
    mutateSnapshot { $0.isAutoPropagating = on }
    if on { post(.propagate) }
  }

  /// Re-read everything the clock knows and publish. Cheap: `report()` takes the statistics
  /// lock briefly and sorts outside it.
  func refreshClockFields() {
    let report = clock.report()
    mutateSnapshot { snapshot in
      snapshot.isTicking = report.isRunning
      snapshot.requestedTickHz = report.requestedTicksPerSecond
      snapshot.achievedTickHz = report.achievedTicksPerSecond
      snapshot.tickJitterSeconds = report.lateness.map { $0.jitterNanoseconds / 1e9 }
      snapshot.isRealtimeScheduled = report.isRealtimeScheduled
      switch report.status {
      case .behindSchedule: snapshot.isFallingBehind = true
      case .idle, .measuring, .onSchedule, .freeRunning: snapshot.isFallingBehind = false
      }
      // D7's "report honestly" clause: a handler that threw is a circuit error the user sees.
      if let handlerError = report.lastErrorDescription, report.errorCount > 0 {
        snapshot.errorMessage = handlerError
      }
    }
  }

  // MARK: - SimulationTickHandler  (runs on the clock/propagation thread)

  func handleTick(index: UInt64, scheduledMachTime: UInt64) throws {
    // Claim the whole queue, or establish that this is a genuine scheduled tick. See the
    // `wakeDebt` note for why the two cannot be told apart by the arguments.
    lock.lock()
    let requests = queue
    queue.removeAll()
    if !requests.isEmpty {
      // **One wake, one debt**; not `requests.count`. Decrementing by the number drained was
      // the first version and it was wrong: draining N requests in one wake left the other N-1
      // wakes with zero debt and an empty queue, which reads as "a genuine scheduled tick" and
      // fired N-1 spurious ticks. Caught by the reset test, which ends at a non-zero
      // `Propagator.tickCount` when that happens.
      wakeDebt = max(0, wakeDebt - 1)
      lock.unlock()
    } else if wakeDebt > 0 {
      wakeDebt -= 1
      lock.unlock()
      return
    } else {
      lock.unlock()
    }

    modelLock.lock()
    defer {
      modelLock.unlock()
      publish()
    }

    guard !requests.isEmpty else {
      // A scheduled auto-tick.
      try run(.tick(count: 1))
      return
    }
    for request in requests {
      try run(request)
    }
  }

  /// One request, on the propagation thread, with the model lock held.
  ///
  /// D13: `Propagator` throws where Java's `Simulator` catches `Exception` and calls
  /// `recordException`, so the throw is caught here and turned into `errorMessage`; never
  /// allowed to escape into a trap, and never swallowed silently.
  private func run(_ request: SimulationRequest) throws {
    switch request {
    case .setCircuit(let box):
      simulatedCircuit = box.value
      rebuildRootState()

    case .reset:
      // `Simulator.reset()` upstream calls `propagator.reset()`, but the observable behaviour
      // users expect from the Reset item, and what `Project.setCircuitState` produces, is a
      // fresh root state. Both are done: the state is rebuilt, which resets the propagator with
      // it, and any recorded error is cleared.
      lastError = nil
      rebuildRootState()

    case .tick(let count):
      guard let state = currentStateStorage else { return }
      do {
        for _ in 0..<max(1, count) {
          _ = try state.propagator.toggleClocks()
          _ = try state.propagator.propagate()
        }
        lastError = nil
      } catch {
        lastError = String(describing: error)
      }

    case .step:
      guard let state = currentStateStorage else { return }
      do {
        _ = try state.propagator.step(nil)
        lastError = nil
      } catch {
        lastError = String(describing: error)
      }

    case .propagate:
      guard let state = currentStateStorage, snapshot.isAutoPropagating else { return }
      do {
        _ = try state.propagator.propagate()
        lastError = nil
      } catch {
        lastError = String(describing: error)
      }
    }
  }

  /// Builds (or rebuilds) the root `CircuitState` for the circuit being simulated.
  ///
  /// **This is the only place a `SimulationSession` is created, and it is on the propagation
  /// thread deliberately**; `SimulationHost` captures `Thread.current` as the thread
  /// `Propagator` will assert against, so constructing it anywhere else installs an assertion
  /// that every subsequent propagation fails.
  private func rebuildRootState() {
    guard let circuit = simulatedCircuit else {
      currentStateStorage = nil
      return
    }
    if session == nil {
      session = SimulationSession(file: fileBox.value, thread: Thread.current)
    }
    guard let session else { return }
    let state = session.createRootState(for: circuit)
    currentStateStorage = state
    // Upstream propagates once on entering a state so the schematic is not showing `U`
    // everywhere before the first tick.
    do {
      _ = try state.propagator.propagate()
    } catch {
      lastError = String(describing: error)
    }
  }

  /// The live root state. Propagation-thread-only; exposed for the canvas/log wiring that will
  /// need it (see the file header's "what is deliberately NOT here").
  var currentState: CircuitState? { currentStateStorage }

  // MARK: - Publishing

  private func publish() {
    let report = clock.report()
    let oscillating = currentStateStorage?.propagator.isOscillating ?? false
    let ticks = currentStateStorage?.propagator.tickCount ?? 0
    let name = simulatedCircuit?.name
    let error = lastError
    let hasState = currentStateStorage != nil

    mutateSnapshot { snapshot in
      // **Once per completed request, and this must be inside `publish` and not
      // `refreshClockFields`.** The two methods have identical opening blocks, and putting it in
      // the wrong one is not a compile error and not a test failure; it is a counter that only
      // moves when the tick *rate* changes, so the canvas repaints on a rate change and never on
      // a propagation. Measured that way first: `canStep` went true while the count stayed at 0.
      snapshot.propagationCount &+= 1
      snapshot.isTicking = report.isRunning
      snapshot.requestedTickHz = report.requestedTicksPerSecond
      snapshot.achievedTickHz = report.achievedTicksPerSecond
      snapshot.tickJitterSeconds = report.lateness.map { $0.jitterNanoseconds / 1e9 }
      snapshot.isRealtimeScheduled = report.isRealtimeScheduled
      switch report.status {
      case .behindSchedule: snapshot.isFallingBehind = true
      case .idle, .measuring, .onSchedule, .freeRunning: snapshot.isFallingBehind = false
      }
      snapshot.oscillationDetected = oscillating
      snapshot.halfCycleCount = ticks
      snapshot.currentStateName = name
      snapshot.canStep = hasState
      snapshot.errorMessage = error ?? (report.errorCount > 0 ? report.lastErrorDescription : nil)
    }
  }

  /// Mutate the shared snapshot and notify, hopping to the main actor when we are not on it.
  ///
  /// **Not `MainActor.assumeIsolated`.** This is called from the propagation thread on every
  /// tick; assuming isolation there would trap on every tick of a running simulation. That is
  /// the same reasoning `LogController.onMain` records, and it is copied rather than
  /// re-derived, see that function's comment.
  private func mutateSnapshot(_ body: (inout SimulationSnapshot) -> Void) {
    lock.lock()
    let before = snapshotStorage
    body(&snapshotStorage)
    let after = snapshotStorage
    let observer = onChange
    lock.unlock()
    guard before != after, let observer else { return }
    if Thread.isMainThread {
      MainActor.assumeIsolated { observer(after) }
    } else {
      Task { @MainActor in observer(after) }
    }
  }
}

// MARK: - Sendable box
//
// `UncheckedSendableBox` is `Tools/ToolSeams.swift`'s, reused rather than redeclared; two types
// with one name in one module is a link-time collision and this project has hit that twice
// already (objectives.md, "basename collisions").
//
// Its justification there is the `assumeIsolated` case, where nothing actually crosses a thread.
// Here it genuinely does, and the claim that makes it safe is different and is stated in this
// file's header: the propagation thread touches a boxed object only while holding `modelLock`,
// and the editing thread mutates one only while holding the same lock.
