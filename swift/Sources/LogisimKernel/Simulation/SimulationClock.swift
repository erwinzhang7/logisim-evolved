//
//  SimulationClock.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution).
//  logisim-evolution is free software released under the GNU GPLv3; this translation is
//  therefore GPL-3.0-only. See LICENSE.md.
//
//  ---------------------------------------------------------------------------------------
//  D7; the phase-anchored simulation clock. This is the port's headline behavioural fix.
//
//  Replaces the auto-tick half of `Simulator.SimThread` (4.1.0,
//  `circuit/Simulator.java:129-600`). Three defects go away at once:
//
//  1. **The moving origin.** Upstream's deadline is `lastTick + autoTickNanos`
//     (`Simulator.java:445`) and `lastTick = now` is assigned at `:520`, *after* the previous
//     propagation returned. Every overshoot and every nanosecond of propagation is therefore
//     added to the period permanently. Here the deadline is `origin + n * period` from a
//     fixed origin (`TickSchedule`), so nothing that happens during a tick can move the
//     phase. Falling behind drops ticks, counted and reported, instead of stretching time.
//
//  2. **The busy-spin.** Within 1 ms of its deadline upstream spins on `System.nanoTime()`
//     in a bare `do { } while (time < deadline)` (`Simulator.java:468-474`), because a JVM
//     cannot ask the kernel for a precise wake. That is the whole of the 99.6%-of-a-core
//     figure at 10 kHz. Here `mach_wait_until` on a `THREAD_TIME_CONSTRAINT_POLICY` thread
//     (`MachClock`, `RealtimeThreadPolicy`) sleeps to within microseconds of the deadline.
//
//  3. **The flattering readout.** `TickCounter` reports the *requested* frequency from four
//     separate "cannot compute" branches. `TickRateReport.achievedTicksPerSecond` is an
//     Optional and there is no path in this module that fills it with the request.
//
//  Measured on this machine, same language, same workload, same seed: only the algorithm
//  differing (see docs/decisions.md, D7):
//
//      1 Hz / 2 ms prop   drift 80.3 ms -> 3.6 µs    jitter 24.1 ms -> 3.2 µs   CPU 0.2% -> 0.2%
//      100 Hz             drift 8.71 ms -> 1.2 µs    jitter 2.52 ms -> 2.6 µs   CPU 9.9% -> 9.9%
//      10 kHz             drift 7.22 ms -> 251 µs    jitter 3.07 ms -> 3.4 µs   CPU 99.6% -> 22.8%
//
//  D1: plain `Thread` + `NSCondition`, no Swift Concurrency, no actors, so `handleTick` stays
//  synchronous and the 108 `propagate(InstanceState)` implementations below it stay
//  synchronous too.
//  ---------------------------------------------------------------------------------------
//

import Foundation

/// What the clock drives on each tick.
///
/// In the finished port this is implemented by the simulator, and `handleTick` performs
/// upstream's `propagator.toggleClocks()` followed by `propagator.propagate()`. It is
/// declared here so the clock does not depend on anything above it in the module graph; the
/// kernel is UI-free by D9, and the clock is testable with a closure.
///
/// **Synchronous and throwing, deliberately.** Synchronous by D1/D2. Throwing by D13:
/// `Simulator.java:520/533/556` wrap propagation in `catch (Exception err)` and turn it into
/// a circuit error the user sees, so the Swift equivalent must be a `throw` that the clock
/// catches; a trap here would convert a recoverable circuit error into a crash with unsaved
/// work lost.
public protocol SimulationTickHandler: AnyObject {

  /// Runs one tick.
  ///
  /// - Parameters:
  ///   - index: the tick's index in the current schedule. Non-contiguous indices mean ticks
  ///     were dropped to stay in phase.
  ///   - scheduledMachTime: the tick's deadline (`origin + index * period`), **not** the
  ///     time the handler was entered. Handed over so a component that needs simulated time
  ///     uses the ideal lattice rather than the jittered observation of it.
  func handleTick(index: UInt64, scheduledMachTime: UInt64) throws
}

/// Closure-backed `SimulationTickHandler`, for the CLI, the differential harness, and tests.
public final class BlockTickHandler: SimulationTickHandler {
  private let body: (UInt64, UInt64) throws -> Void

  public init(_ body: @escaping (UInt64, UInt64) throws -> Void) {
    self.body = body
  }

  public func handleTick(index: UInt64, scheduledMachTime: UInt64) throws {
    try body(index, scheduledMachTime)
  }
}

/// The phase-anchored simulation clock.
///
/// Thread-safe: every method may be called from any thread, including the UI thread while
/// the clock is running. All state lives behind one `NSCondition` (control) and one `NSLock`
/// (statistics), which are never held at the same time.
///
/// Ownership follows D3. The clock holds its handler **weakly**: in the assembled app the
/// simulator owns the clock and is also its handler, so a strong edge here would be an
/// unconditional retain cycle on the single longest-lived object in the process. The clock
/// thread holds an internal core object, not this façade, so dropping the last reference to
/// a `SimulationClock` runs `deinit`, which stops the thread.
public final class SimulationClock: @unchecked Sendable {

  private let core: Core

  /// - Parameters:
  ///   - ticksPerSecond: requested rate. Clamped into `TickSchedule`'s supported range; a
  ///     nonsense value from a preferences file clamps rather than traps (D13).
  ///   - mode: `.realTimeLocked` for interactive simulation, `.freeRunning` for batch work.
  public init(ticksPerSecond: Double = 1.0, mode: TickClockMode = .realTimeLocked) {
    core = Core(ticksPerSecond: ticksPerSecond, mode: mode)
  }

  deinit {
    // The thread retains `core`, not `self`, so this is reachable even if the owner forgot
    // to stop the clock.
    core.stop(timeout: 2.0)
  }

  // MARK: - Wiring

  /// Attaches (or detaches) the object driven on each tick. Held weakly, see the type note.
  public func setHandler(_ handler: SimulationTickHandler?) {
    core.setHandler(handler)
  }

  // MARK: - Rate and mode

  /// The requested rate, in ticks per second (a tick is a clock half-cycle).
  public var ticksPerSecond: Double { core.currentTicksPerSecond }

  /// Sets the requested rate.
  ///
  /// This **re-anchors the phase** and resets the statistics, because a rate change is a new
  /// schedule rather than a perturbation of the old one, and an achieved rate averaged
  /// across a frequency change measures nothing. It is the only sanctioned way for the origin
  /// to move, and it happens at an explicit call site, which is exactly the property
  /// `Simulator.java` lacks.
  public func setTicksPerSecond(_ value: Double) {
    core.setTicksPerSecond(value)
  }

  /// The mode in force.
  public var mode: TickClockMode { core.currentMode }

  /// Switches between real-time-locked and free-running. Re-anchors and resets statistics.
  public func setMode(_ mode: TickClockMode) {
    core.setMode(mode)
  }

  // MARK: - Run control

  /// Starts the clock thread if needed and begins auto-ticking. Idempotent.
  public func start() {
    core.setAutoTicking(true)
  }

  /// Stops auto-ticking. The thread stays alive and idle, so `resume()` is cheap; the phase
  /// is re-anchored on resume, since a gap in ticking is not a schedule the user asked for.
  public func pause() {
    core.setAutoTicking(false)
  }

  /// Resumes auto-ticking after `pause()`.
  public func resume() {
    core.setAutoTicking(true)
  }

  /// `true` while the thread is alive and auto-ticking.
  public var isRunning: Bool { core.isRunning }

  /// Terminates the clock thread and waits for it to exit.
  ///
  /// Worst-case wait is one uninterruptible `mach_wait_until` leg (`Core.machWaitCeiling`,
  /// 20 ms) plus the cost of a tick in flight.
  public func stop(timeout: TimeInterval = 2.0) {
    core.stop(timeout: timeout)
  }

  /// Requests `count` out-of-band ticks, executed as soon as the thread can run them.
  ///
  /// Upstream's `manualTicksRequested`. These have no deadline, so they are counted
  /// separately and excluded from the achieved rate and the jitter distribution; folding
  /// them in would corrupt both. Works whether the clock is running or paused, and starts
  /// the thread if it is not yet running.
  public func requestManualTick(count: Int = 1) {
    core.requestManualTick(count: count)
  }

  // MARK: - Readout

  /// An immutable, honest snapshot of what the clock is actually doing.
  ///
  /// Safe to call at display refresh from the UI thread; it takes the statistics lock only
  /// briefly and does its sorting outside it.
  public func report() -> TickRateReport {
    core.report()
  }

  /// Clears all measurements without disturbing the phase.
  public func resetStatistics() {
    core.resetStatistics()
  }

  // MARK: - Introspection for tests and diagnostics

  /// The schedule currently in force, including its origin. `nil` before the first anchor.
  public var currentSchedule: TickSchedule? { core.currentSchedule }
}

// MARK: - Core

extension SimulationClock {

  /// The half of the clock the thread actually retains.
  ///
  /// Split from the façade so the retain graph is `SimulationClock -> Core <- Thread`
  /// rather than a cycle through `self`. That is what makes `SimulationClock.deinit`
  /// reachable, and therefore what makes "forgot to call stop()" a non-leak.
  final class Core: @unchecked Sendable {

    /// Longest single uninterruptible `mach_wait_until` leg.
    ///
    /// Waits longer than this are split: a coarse, *interruptible* `NSCondition.wait(until:)`
    /// down to this much remaining, then one precise mach wait. So control changes are
    /// honoured within 20 ms even at 1 Hz, while every rate above 50 Hz waits purely on
    /// `mach_wait_until`; the configuration the D7 numbers were measured in.
    ///
    /// Note the coarse leg cannot damage the schedule: a spurious or early return costs one
    /// loop pass, and the next deadline is recomputed from the fixed origin. Upstream's
    /// equivalent (`awaitNanos`) feeds its error straight into `lastTick`.
    static let machWaitCeilingNanoseconds: Double = 20_000_000  // 20 ms

    private let condition = NSCondition()
    private let statistics = TickStatistics()

    // Control state, condition-guarded.
    private var baseSchedule: TickSchedule
    private var mode: TickClockMode
    private var autoTicking = false
    private var manualTicksRequested = 0
    private var stopRequested = false
    private var generation: UInt64 = 0
    private weak var handler: SimulationTickHandler?
    private var thread: Thread?
    private var threadDidExit = true
    /// The live schedule, republished by the clock thread each time it re-anchors, so
    /// `currentSchedule` can expose the actual origin without racing the thread.
    private var anchoredSchedule: TickSchedule?

    init(ticksPerSecond: Double, mode: TickClockMode) {
      self.baseSchedule = TickSchedule(ticksPerSecond: ticksPerSecond, origin: MachClock.now())
      self.mode = mode
      statistics.reset(requestedTicksPerSecond: baseSchedule.ticksPerSecond)
    }

    // MARK: Control API

    func setHandler(_ newHandler: SimulationTickHandler?) {
      condition.lock()
      handler = newHandler
      condition.broadcast()
      condition.unlock()
    }

    var currentTicksPerSecond: Double {
      condition.lock()
      defer { condition.unlock() }
      return baseSchedule.ticksPerSecond
    }

    var currentMode: TickClockMode {
      condition.lock()
      defer { condition.unlock() }
      return mode
    }

    var currentSchedule: TickSchedule? {
      condition.lock()
      defer { condition.unlock() }
      return anchoredSchedule
    }

    var isRunning: Bool {
      condition.lock()
      defer { condition.unlock() }
      return thread != nil && !threadDidExit && autoTicking
    }

    func setTicksPerSecond(_ value: Double) {
      condition.lock()
      let updated = TickSchedule(ticksPerSecond: value, origin: MachClock.now())
      // Compare the clamped rate, not the argument: setting 1e12 twice must not re-anchor
      // the phase on the second call.
      let unchanged = updated.ticksPerSecond == baseSchedule.ticksPerSecond
      if !unchanged {
        baseSchedule = updated
        generation &+= 1
        condition.broadcast()
      }
      let rate = baseSchedule.ticksPerSecond
      condition.unlock()
      if !unchanged { statistics.reset(requestedTicksPerSecond: rate) }
    }

    func setMode(_ newMode: TickClockMode) {
      condition.lock()
      let changed = newMode != mode
      if changed {
        mode = newMode
        generation &+= 1
        condition.broadcast()
      }
      let rate = baseSchedule.ticksPerSecond
      condition.unlock()
      if changed { statistics.reset(requestedTicksPerSecond: rate) }
    }

    func setAutoTicking(_ on: Bool) {
      if on { ensureThread() }
      condition.lock()
      if autoTicking != on {
        autoTicking = on
        // Turning ticking off, then on, is a gap in the schedule; bump the generation so the
        // thread re-anchors rather than "catching up" thousands of ticks that never ran.
        generation &+= 1
        condition.broadcast()
      }
      condition.unlock()
    }

    func requestManualTick(count: Int) {
      guard count > 0 else { return }
      ensureThread()
      condition.lock()
      manualTicksRequested += count
      condition.broadcast()
      condition.unlock()
    }

    func resetStatistics() {
      condition.lock()
      let rate = baseSchedule.ticksPerSecond
      condition.unlock()
      statistics.reset(requestedTicksPerSecond: rate)
    }

    func report() -> TickRateReport {
      condition.lock()
      let currentMode = mode
      let running = thread != nil && !threadDidExit && autoTicking
      condition.unlock()
      // Statistics lock is taken only after the control lock is released: the two are never
      // nested, in either order, anywhere in this file.
      return statistics.snapshot(mode: currentMode, isRunning: running)
    }

    // MARK: Thread lifecycle

    private func ensureThread() {
      condition.lock()
      defer { condition.unlock() }
      guard thread == nil else { return }
      stopRequested = false
      threadDidExit = false
      let worker = Thread { [core = self] in core.runLoop() }
      worker.name = "logisim.simulation-clock"
      worker.qualityOfService = .userInteractive
      thread = worker
      worker.start()
    }

    func stop(timeout: TimeInterval) {
      condition.lock()
      guard let worker = thread else {
        condition.unlock()
        return
      }
      stopRequested = true
      autoTicking = false
      condition.broadcast()

      let limit = Date(timeIntervalSinceNow: max(timeout, 0))
      while !threadDidExit, Date() < limit {
        _ = condition.wait(until: limit)
      }
      thread = nil
      stopRequested = false
      condition.unlock()

      // Belt and braces if the wait timed out mid-tick: the loop still observes
      // `stopRequested`... which we just cleared, so cancel the thread as well. `Thread` has
      // no join, and leaving a second loop running would double-drive the handler.
      if !worker.isFinished { worker.cancel() }
    }

    // MARK: The loop

    private func runLoop() {
      var appliedGeneration: UInt64 = .max
      var schedule = TickSchedule(ticksPerSecond: 1, origin: MachClock.now())
      var nextIndex: UInt64 = 0
      var needsAnchor = true
      var appliedPolicyMode: TickClockMode?
      var appliedPolicyPeriod = Double.nan

      loop: while true {
        // ---- control section -------------------------------------------------------
        condition.lock()
        while !stopRequested && !autoTicking && manualTicksRequested == 0 {
          // Idle. Any gap in ticking invalidates the phase, so re-anchor on the way out.
          needsAnchor = true
          condition.wait()
        }
        if stopRequested || Thread.current.isCancelled {
          threadDidExit = true
          condition.broadcast()
          condition.unlock()
          break loop
        }

        if generation != appliedGeneration {
          appliedGeneration = generation
          needsAnchor = true
        }

        let activeMode = mode
        let base = baseSchedule
        let activeHandler = handler
        let ticking = autoTicking
        var doManualTick = false
        if manualTicksRequested > 0 {
          manualTicksRequested -= 1
          doManualTick = true
        }

        var anchoredThisPass = false
        if needsAnchor {
          // THE anchor. `origin` is captured exactly once, here, and is read-only for every
          // deadline computed until the next deliberate re-anchor. There is no other
          // assignment to an origin in this file, which is the single-line summary of the
          // difference from `Simulator.java:520`.
          schedule = base.rebased(to: MachClock.now())
          nextIndex = 0
          anchoredSchedule = schedule
          needsAnchor = false
          anchoredThisPass = true
          appliedPolicyMode = nil
        }
        condition.unlock()

        // Deliberately outside the control lock: the condition lock and the statistics lock
        // are never held at the same time, in either order, anywhere in this file.
        //
        // The reset matters for honesty, not tidiness. A pause, a rate change or a handler
        // swap leaves `firstFiredMachTime` on the far side of the gap, so the achieved rate
        // would be `executedTicks / (running time + idle time)`; a fabricated shortfall
        // that would make the clock report BEHIND for a gap the user asked for. Re-anchoring
        // the phase and re-anchoring the measurement are the same event.
        if anchoredThisPass {
          statistics.reset(requestedTicksPerSecond: schedule.ticksPerSecond)
        }

        if appliedPolicyMode != activeMode || appliedPolicyPeriod != schedule.periodNanoseconds {
          applyThreadPolicy(mode: activeMode, schedule: schedule)
          appliedPolicyMode = activeMode
          appliedPolicyPeriod = schedule.periodNanoseconds
        }

        // Nothing attached yet. Without this the free-running branch would saturate a core
        // driving nobody, and the statistics would count ticks that did no work.
        guard activeHandler != nil else {
          if doManualTick {
            // Hand the request back rather than consuming it; the user asked for a tick,
            // not for a tick to be discarded because the wiring was not finished yet.
            condition.lock()
            manualTicksRequested += 1
            condition.unlock()
          }
          waitForHandlerAttachment()
          needsAnchor = true
          continue loop
        }

        // ---- manual, out-of-band tick ----------------------------------------------
        if doManualTick {
          _ = executeTick(
            handler: activeHandler,
            index: nextIndex,
            scheduledMachTime: MachClock.now(),
            latenessMachTicks: nil,
            isScheduled: false)
          continue loop
        }

        guard ticking else { continue loop }

        // ---- scheduled ticks --------------------------------------------------------
        switch activeMode {
        case .freeRunning:
          // No wall-clock relationship at all: back-to-back propagation, and lateness is
          // recorded as "no sample" rather than as zero.
          let now = MachClock.now()
          _ = executeTick(
            handler: activeHandler,
            index: nextIndex,
            scheduledMachTime: now,
            latenessMachTicks: nil,
            isScheduled: true)
          nextIndex &+= 1

        case .realTimeLocked:
          switch TickLoopPolicy.nextAction(
            schedule: schedule, index: nextIndex, machTime: MachClock.now())
          {
          case .wait(let target):
            sleep(untilMachTime: target)

          case .fire(let index, let deadline, let lateness):
            let completedAt = executeTick(
              handler: activeHandler,
              index: index,
              scheduledMachTime: deadline,
              latenessMachTicks: lateness,
              isScheduled: true)
            let advance = TickLoopPolicy.advance(
              schedule: schedule, afterFiring: index, completedAtMachTime: completedAt)
            statistics.recordDroppedTicks(advance.droppedTicks)
            nextIndex = advance.nextIndex
          }
        }
      }
    }

    /// Blocks until a handler is attached, the clock is stopped, or ticking is switched off.
    private func waitForHandlerAttachment() {
      condition.lock()
      while handler == nil && !stopRequested && (autoTicking || manualTicksRequested > 0) {
        condition.wait()
      }
      condition.unlock()
    }

    /// Runs the handler and records what it cost. Never throws, never traps (D13).
    ///
    /// - Returns: the mach time at which the handler returned, which is what
    ///   `TickLoopPolicy.advance` needs to decide whether ticks have to be dropped.
    private func executeTick(
      handler: SimulationTickHandler?,
      index: UInt64,
      scheduledMachTime: UInt64,
      latenessMachTicks: Int64?,
      isScheduled: Bool
    ) -> UInt64 {
      let startedAt = MachClock.now()
      var failure: String?
      if let handler {
        do {
          try handler.handleTick(index: index, scheduledMachTime: scheduledMachTime)
        } catch {
          // D13: `Simulator.java:520/533/556` catch here and turn the failure into a circuit
          // error the user sees. Trapping would lose the user's unsaved work over a bad
          // component.
          failure = String(describing: error)
        }
      }
      let finishedAt = MachClock.now()
      statistics.recordTick(
        firedAtMachTime: startedAt,
        propagationMachTicks: finishedAt &- startedAt,
        latenessMachTicks: latenessMachTicks,
        isScheduled: isScheduled,
        failure: failure)
      return finishedAt
    }

    /// Waits until `target`, precisely and without spinning.
    ///
    /// Long waits get an interruptible coarse leg first so that `stop()`, a rate change or a
    /// mode change is not stuck behind a one-second sleep at 1 Hz. Short waits, every rate
    /// above 50 Hz, are a single `mach_wait_until`.
    private func sleep(untilMachTime target: UInt64) {
      let now = MachClock.now()
      guard target > now else { return }

      let remainingNanoseconds = Double(target &- now) * MachClock.nanosecondsPerMachTick
      if remainingNanoseconds > Self.machWaitCeilingNanoseconds {
        let coarseSeconds =
          (remainingNanoseconds - Self.machWaitCeilingNanoseconds) / 1_000_000_000
        condition.lock()
        if !stopRequested {
          _ = condition.wait(until: Date(timeIntervalSinceNow: coarseSeconds))
        }
        condition.unlock()
        // Deliberately return without finishing the wait: the loop re-reads control state
        // and recomputes the deadline from the fixed origin, so an early or spurious return
        // costs one pass and cannot perturb the schedule.
        return
      }

      MachClock.sleep(untilMachTime: target)
    }

    /// Issues (or withdraws) the `THREAD_TIME_CONSTRAINT_POLICY` declaration for this thread.
    private func applyThreadPolicy(mode: TickClockMode, schedule: TickSchedule) {
      switch mode {
      case .freeRunning:
        // Free-running has no deadline to meet, so holding a realtime declaration while
        // saturating a core is exactly the antisocial behaviour the policy rations.
        _ = RealtimeThreadPolicy.resignOnCurrentThread()
        statistics.setRealtimeScheduled(false)

      case .realTimeLocked:
        let expectedWork =
          statistics.meanPropagationNanoseconds ?? (schedule.periodNanoseconds * 0.1)
        let policy = RealtimeThreadPolicy.forTickPeriod(
          schedule.periodNanoseconds, expectedWorkNanoseconds: expectedWork)
        // A refusal is not fatal: we still sleep rather than spin, we just take the
        // timeshare queue's jitter tail. It is surfaced in the report rather than hidden.
        statistics.setRealtimeScheduled(policy.applyToCurrentThread())
      }
    }
  }
}
