//
//  TickLoopPolicy.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution).
//  logisim-evolution is free software released under the GNU GPLv3; this translation is
//  therefore GPL-3.0-only. See LICENSE.md.
//
//  ---------------------------------------------------------------------------------------
//  D7: the *decision* half of the phase-anchored clock, extracted from the thread.
//
//  The whole of upstream's scheduling bug lives in two statements that are 80 lines apart:
//  the deadline expression at `Simulator.java:445` and the assignment `lastTick = now` at
//  `Simulator.java:520`, which runs after the propagation. Because the deadline is relative
//  to `lastTick`, and `lastTick` is re-read after each propagation, the period silently
//  becomes `period + overshoot + propagationTime`, permanently, every tick.
//
//  Here the two decisions, "what do I do next?" and "where am I after a tick?", are pure
//  functions of (schedule, index, clock reading). They touch no state, so there is no
//  accumulator for an overshoot to leak into, and they can be exercised exhaustively against
//  synthetic clock readings without starting a thread. The thread in `SimulationClock` does
//  nothing but call these two functions and act on the answer.
//
//  D1: no Swift Concurrency. Pure value types.
//  ---------------------------------------------------------------------------------------
//

/// What the clock thread should do next.
public enum TickAction: Equatable, Sendable {

  /// Nothing is due yet; sleep until this mach absolute time and ask again.
  ///
  /// The caller is free to wake early (a spurious wakeup, a control change, an aborted
  /// `mach_wait_until`); it simply asks again. A premature wake costs one loop pass and
  /// **cannot** perturb the schedule, because the answer is recomputed from the fixed
  /// origin rather than from anything the previous pass stored. Upstream's
  /// `simStateUpdated.awaitNanos(delta)` has the opposite property: an early return there
  /// becomes schedule error.
  case wait(untilMachTime: UInt64)

  /// Tick `index` is due (its deadline is at or before the observed clock reading).
  ///
  /// `latenessMachTicks` is `observed - deadline` and is `>= 0` by construction here; it is
  /// the honest measurement of how late this tick actually is, and it is what feeds the
  /// jitter readout. Nothing in the scheduler *corrects* for it; correcting is precisely
  /// how upstream absorbs the error.
  case fire(index: UInt64, deadlineMachTime: UInt64, latenessMachTicks: Int64)
}

/// The outcome of finishing a tick: where the schedule resumes, and what it cost.
public struct TickAdvance: Equatable, Sendable {

  /// The index of the next tick to run.
  public let nextIndex: UInt64

  /// How many scheduled ticks were skipped because their deadlines had already passed by
  /// the time the previous propagation returned.
  ///
  /// This number is the honest cost of falling behind, and it is reported. Upstream has no
  /// equivalent because it never falls behind *by its own reckoning*: it stretches the
  /// period instead, so the ticks are not dropped, they are silently delivered late for the
  /// rest of the session while the UI keeps printing the requested frequency.
  public let droppedTicks: UInt64

  public init(nextIndex: UInt64, droppedTicks: UInt64) {
    self.nextIndex = nextIndex
    self.droppedTicks = droppedTicks
  }
}

/// The two scheduling decisions, as pure functions.
public enum TickLoopPolicy {

  /// Decides whether tick `index` is due at clock reading `machTime`.
  ///
  /// Note what is *absent*: there is no "close enough, fire early" window. Upstream fires
  /// whenever `deadline - now <= 1000` ns (`Simulator.java:446`), which biases every tick
  /// up to a microsecond early and, combined with the moving origin, is part of why the
  /// measured drift is one-directional. Here a tick fires when it is due and not before.
  @inline(__always)
  public static func nextAction(
    schedule: TickSchedule,
    index: UInt64,
    machTime: UInt64
  ) -> TickAction {
    let due = schedule.deadline(index)
    if machTime >= due {
      return .fire(
        index: index,
        deadlineMachTime: due,
        latenessMachTicks: Int64(bitPattern: machTime &- due))
    }
    return .wait(untilMachTime: due)
  }

  /// Decides where the schedule resumes after tick `firedIndex` completed at `machTime`.
  ///
  /// Real-time-locked semantics: the next tick is `firedIndex + 1` if its deadline is still
  /// in the future, and otherwise the first index whose deadline is still in the future;
  /// everything in between is *dropped* and counted.
  ///
  /// The property that matters, and that the tests assert: the returned index still indexes
  /// the same lattice `origin + n * period`. Dropping changes *which* ticks run. It cannot
  /// change *when* they run. That is the entire fix.
  @inline(__always)
  public static func advance(
    schedule: TickSchedule,
    afterFiring firedIndex: UInt64,
    completedAtMachTime machTime: UInt64
  ) -> TickAdvance {
    let immediateNext = firedIndex &+ 1
    if schedule.deadline(immediateNext) > machTime {
      return TickAdvance(nextIndex: immediateNext, droppedTicks: 0)
    }
    let resume = schedule.nextIndex(after: machTime)
    // `resume` is at least `immediateNext` here, but guard the subtraction anyway: a
    // schedule rebased underneath us must degrade to "drop nothing", never to a wrapped
    // count of 1.8e19 dropped ticks in the readout.
    let dropped = resume > immediateNext ? resume &- immediateNext : 0
    return TickAdvance(nextIndex: max(resume, immediateNext), droppedTicks: dropped)
  }
}
