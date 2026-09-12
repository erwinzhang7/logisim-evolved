//
//  SimulationClockTests.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
//  ---------------------------------------------------------------------------------------
//  D7, the wall-clock half. These start a real thread, sleep, and measure, so they are
//  serialized (two realtime-scheduled clock threads competing would measure the competition,
//  not the clock) and their bounds are deliberately generous. The *tight* assertions live in
//  `TickScheduleTests`, which proves the anchoring property on the arithmetic where no
//  machine load can perturb it.
//
//  What is asserted here is the part only a running clock can show:
//    - drift does not grow with tick index over thousands of ticks;
//    - a propagation that overruns its period does not move the phase of later ticks;
//    - the readout says so when the target cannot be met, and never reports the request as
//      if it were achieved.
//  ---------------------------------------------------------------------------------------
//

import Foundation
import Testing

@testable import LogisimKernel

/// Records what the clock actually did, from the clock thread.
private final class TickRecorder: SimulationTickHandler, @unchecked Sendable {
  struct Sample {
    let index: UInt64
    let scheduledMachTime: UInt64
    let observedMachTime: UInt64
  }

  private let lock = NSLock()
  private var storage: [Sample] = []
  private let work: ((UInt64) -> Void)?
  private let failure: (@Sendable (UInt64) -> Error?)?

  init(
    reserve: Int = 8192,
    work: ((UInt64) -> Void)? = nil,
    failure: (@Sendable (UInt64) -> Error?)? = nil
  ) {
    self.work = work
    self.failure = failure
    storage.reserveCapacity(reserve)
  }

  func handleTick(index: UInt64, scheduledMachTime: UInt64) throws {
    let observed = MachClock.now()
    lock.lock()
    storage.append(
      Sample(index: index, scheduledMachTime: scheduledMachTime, observedMachTime: observed))
    lock.unlock()
    work?(index)
    if let failure, let error = failure(index) { throw error }
  }

  var samples: [Sample] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

private struct TickTestError: Error, CustomStringConvertible {
  let description = "deliberate propagation failure"
}

/// Mean signed lateness, in nanoseconds, over a slice of samples.
private func meanLateness(_ samples: ArraySlice<TickRecorder.Sample>) -> Double {
  guard !samples.isEmpty else { return 0 }
  var total = 0.0
  for sample in samples {
    let delta =
      sample.observedMachTime >= sample.scheduledMachTime
      ? Int64(bitPattern: sample.observedMachTime &- sample.scheduledMachTime)
      : -Int64(bitPattern: sample.scheduledMachTime &- sample.observedMachTime)
    total += MachClock.nanoseconds(signedMachTicks: delta)
  }
  return total / Double(samples.count)
}

@Suite("SimulationClock — running behaviour (D7)", .serialized)
struct SimulationClockTests {

  // MARK: - Drift over thousands of ticks

  @Test("drift does not grow with tick index over thousands of ticks", .timeLimit(.minutes(1)))
  func driftStaysBoundedOverThousandsOfTicks() throws {
    let rate = 2000.0
    let recorder = TickRecorder(reserve: 8192)
    let clock = SimulationClock(ticksPerSecond: rate, mode: .realTimeLocked)
    defer { clock.stop() }

    clock.setHandler(recorder)
    clock.start()
    Thread.sleep(forTimeInterval: 2.0)
    let report = clock.report()
    clock.pause()

    let samples = recorder.samples
    #expect(samples.count > 3000, "expected thousands of ticks, got \(samples.count)")

    // The property. Under upstream's rule the mean lateness of the last window would exceed
    // the first by (tickCount x wake latency); hundreds of milliseconds over 4000 ticks.
    // Under the anchored rule the two windows are statistically the same number.
    let window = 400
    let early = meanLateness(samples[0..<window])
    let late = meanLateness(samples[(samples.count - window)...])
    #expect(
      abs(late - early) < 5_000_000,
      "drift grew from \(early) ns to \(late) ns across \(samples.count) ticks")

    // Indices must still be monotonically increasing, and the scheduled times must sit
    // exactly on the lattice implied by the very first sample.
    let schedule = try #require(clock.currentSchedule)
    let period = schedule.periodMachTicks
    let first = samples[0]
    for sample in samples {
      let expected =
        Double(first.scheduledMachTime) + Double(sample.index &- first.index) * period
      #expect(
        abs(Double(sample.scheduledMachTime) - expected) < 4.0,
        "tick \(sample.index) scheduled off-lattice")
    }

    // And the readout must be a measurement, not the request echoed back.
    let achieved = try #require(report.achievedTicksPerSecond)
    #expect(abs(achieved - rate) / rate < 0.05, "achieved \(achieved) vs requested \(rate)")
    #expect(report.lateness != nil)
  }

  // MARK: - Slow propagation must not shift the phase

  @Test("a slow propagation drops ticks but does not shift the phase", .timeLimit(.minutes(1)))
  func slowPropagationDoesNotShiftThePhase() throws {
    let rate = 200.0  // 5 ms period
    let recorder = TickRecorder(
      reserve: 1024,
      work: { index in
        // Every fortieth tick overruns its period by more than 2x.
        if index % 40 == 20 { Thread.sleep(forTimeInterval: 0.012) }
      })

    let clock = SimulationClock(ticksPerSecond: rate, mode: .realTimeLocked)
    defer { clock.stop() }
    clock.setHandler(recorder)
    clock.start()
    Thread.sleep(forTimeInterval: 1.5)
    let report = clock.report()
    clock.pause()

    let samples = recorder.samples
    #expect(samples.count > 100)

    let schedule = try #require(clock.currentSchedule)
    let period = schedule.periodMachTicks
    let first = try #require(samples.first)

    // THE assertion. Every scheduled time, including every tick after an overrun, is
    // still exactly `origin + n * period`. Upstream's rule would offset the lattice by the
    // 7 ms of overrun each time, permanently and cumulatively.
    for sample in samples {
      let expected =
        Double(first.scheduledMachTime) + Double(sample.index &- first.index) * period
      #expect(
        abs(Double(sample.scheduledMachTime) - expected) < 4.0,
        "tick \(sample.index): scheduled time drifted off the lattice")
    }

    // Indices must skip where ticks were dropped, and the drops must be reported.
    let skipped = samples.last!.index &- first.index &+ 1 &- UInt64(samples.count)
    #expect(skipped > 0, "the overruns should have cost scheduled ticks")
    #expect(report.droppedTicks > 0, "dropped ticks must be reported, not absorbed")
    if case .behindSchedule(let dropped) = report.status {
      #expect(dropped > 0)
    } else {
      Issue.record("expected .behindSchedule, got \(report.status)")
    }

    // The wall-clock span really is index-count periods: the schedule did not stretch.
    let last = samples.last!
    let spanNanoseconds = MachClock.nanoseconds(
      machTicks: Double(last.scheduledMachTime &- first.scheduledMachTime))
    let expectedSpan = Double(last.index &- first.index) * schedule.periodNanoseconds
    #expect(abs(spanNanoseconds - expectedSpan) < 1000)
  }

  // MARK: - Honest readout

  @Test("a clock that has not ticked reports nothing, not the requested rate")
  func idleClockReportsNothing() {
    let clock = SimulationClock(ticksPerSecond: 10_000, mode: .realTimeLocked)
    defer { clock.stop() }

    let report = clock.report()
    #expect(report.achievedTicksPerSecond == nil)
    #expect(report.achievedDescription == "—")
    #expect(report.status == .idle)
    #expect(!report.isMeetingTarget)
    #expect(report.requestedTicksPerSecond == 10_000)
    // The exact upstream behaviour that must not exist here.
    #expect(report.achievedTicksPerSecond != report.requestedTicksPerSecond)
  }

  @Test("a clock that cannot keep up says so", .timeLimit(.minutes(1)))
  func unmeetableRateIsReportedHonestly() throws {
    // 4 kHz requested, but each propagation costs 1 ms, a hard 4x overcommit.
    let recorder = TickRecorder(
      reserve: 2048, work: { _ in Thread.sleep(forTimeInterval: 0.001) })

    let clock = SimulationClock(ticksPerSecond: 4000, mode: .realTimeLocked)
    defer { clock.stop() }
    clock.setHandler(recorder)
    clock.start()
    Thread.sleep(forTimeInterval: 1.0)
    let report = clock.report()
    clock.pause()

    #expect(!report.isMeetingTarget)
    #expect(report.droppedTicks > 0)
    if case .behindSchedule = report.status {} else {
      Issue.record("expected .behindSchedule, got \(report.status)")
    }

    let achieved = try #require(report.achievedTicksPerSecond)
    #expect(achieved < 2000, "achieved \(achieved) should be far below the 4 kHz request")
    #expect(achieved != report.requestedTicksPerSecond)

    let shortfall = try #require(report.shortfallFraction)
    #expect(shortfall > 0.3)
    #expect(report.summary.hasPrefix("BEHIND"))

    // The measured propagation cost is what makes the shortfall explicable rather than
    // mysterious, so it must be present.
    let propagation = try #require(report.meanPropagationNanoseconds)
    #expect(propagation > 500_000)

    // And the phase is still intact despite the overcommit: every scheduled time on the
    // lattice, ticks dropped rather than delayed.
    let samples = recorder.samples
    let schedule = try #require(clock.currentSchedule)
    let first = try #require(samples.first)
    for sample in samples {
      let expected =
        Double(first.scheduledMachTime)
        + Double(sample.index &- first.index) * schedule.periodMachTicks
      #expect(abs(Double(sample.scheduledMachTime) - expected) < 4.0)
    }
  }

  // MARK: - Modes

  @Test("free-running ignores the wall clock entirely", .timeLimit(.minutes(1)))
  func freeRunningIgnoresTheWallClock() throws {
    // A 10 Hz request would allow ~2 ticks in 200 ms if it were honoured.
    let recorder = TickRecorder(reserve: 200_000)
    let clock = SimulationClock(ticksPerSecond: 10, mode: .freeRunning)
    defer { clock.stop() }
    clock.setHandler(recorder)
    clock.start()
    Thread.sleep(forTimeInterval: 0.2)
    let report = clock.report()
    clock.pause()

    #expect(report.status == .freeRunning)
    #expect(report.executedTicks > 1000, "free-running executed only \(report.executedTicks)")
    // Lateness is undefined without a deadline, and is reported as absent rather than as
    // a flattering zero.
    #expect(report.lateness == nil)
    #expect(report.peakAbsoluteLatenessNanoseconds == nil)
    #expect(!report.isMeetingTarget)
    #expect(report.summary.contains("free-running"))
  }

  @Test("switching mode re-anchors and resets the measurement", .timeLimit(.minutes(1)))
  func switchingModeResetsMeasurement() throws {
    let recorder = TickRecorder(reserve: 4096)
    let clock = SimulationClock(ticksPerSecond: 500, mode: .realTimeLocked)
    defer { clock.stop() }
    clock.setHandler(recorder)
    clock.start()
    Thread.sleep(forTimeInterval: 0.4)
    #expect(clock.report().executedTicks > 50)

    clock.setMode(.freeRunning)
    #expect(clock.mode == .freeRunning)
    Thread.sleep(forTimeInterval: 0.1)
    let report = clock.report()
    #expect(report.status == .freeRunning)
    #expect(report.lateness == nil)
  }

  @Test("changing the rate re-anchors the phase deliberately", .timeLimit(.minutes(1)))
  func changingTheRateReanchors() throws {
    let recorder = TickRecorder(reserve: 4096)
    let clock = SimulationClock(ticksPerSecond: 500, mode: .realTimeLocked)
    defer { clock.stop() }
    clock.setHandler(recorder)
    clock.start()
    Thread.sleep(forTimeInterval: 0.3)

    let before = try #require(clock.currentSchedule)
    clock.setTicksPerSecond(1000)
    Thread.sleep(forTimeInterval: 0.3)
    let after = try #require(clock.currentSchedule)

    #expect(after.ticksPerSecond == 1000)
    #expect(after.origin > before.origin, "a rate change must produce a new origin")

    let report = clock.report()
    #expect(report.requestedTicksPerSecond == 1000)
    let achieved = try #require(report.achievedTicksPerSecond)
    // Measured only since the re-anchor, so it reflects the new rate, not a blend.
    #expect(abs(achieved - 1000) / 1000 < 0.1, "achieved \(achieved)")
  }

  // MARK: - Manual ticks

  @Test("manual ticks run while paused and stay out of the rate", .timeLimit(.minutes(1)))
  func manualTicksAreOutOfBand() throws {
    let recorder = TickRecorder(reserve: 16)
    let clock = SimulationClock(ticksPerSecond: 1, mode: .realTimeLocked)
    defer { clock.stop() }
    clock.setHandler(recorder)

    clock.requestManualTick(count: 3)
    // Give the thread time to service them; 1 Hz means auto-ticking would produce at most
    // one tick in this window even if it were running, and it is not.
    Thread.sleep(forTimeInterval: 0.3)

    let report = clock.report()
    #expect(recorder.samples.count == 3)
    #expect(report.manualTicks == 3)
    #expect(report.executedTicks == 0)
    #expect(report.achievedTicksPerSecond == nil, "manual ticks must not fabricate a rate")
  }

  // MARK: - D13: a throwing propagation is recoverable

  @Test("a throwing handler is recorded and the clock keeps running", .timeLimit(.minutes(1)))
  func throwingHandlerDoesNotKillTheClock() throws {
    let recorder = TickRecorder(
      reserve: 1024,
      failure: { index in index % 5 == 0 ? TickTestError() : nil })

    let clock = SimulationClock(ticksPerSecond: 500, mode: .realTimeLocked)
    defer { clock.stop() }
    clock.setHandler(recorder)
    clock.start()
    Thread.sleep(forTimeInterval: 0.5)
    let report = clock.report()
    clock.pause()

    #expect(report.errorCount > 10, "expected the thrown errors to be counted")
    #expect(report.lastErrorDescription?.contains("deliberate") == true)
    // The clock did not stop: it kept ticking through the failures, exactly as
    // Simulator.java:520 does with `catch (Exception err) -> recordException(err)`.
    #expect(report.executedTicks > 100)
  }

  // MARK: - Lifecycle

  @Test("stop() terminates the thread promptly", .timeLimit(.minutes(1)))
  func stopIsPrompt() {
    let recorder = TickRecorder(reserve: 4096)
    let clock = SimulationClock(ticksPerSecond: 1, mode: .realTimeLocked)
    clock.setHandler(recorder)
    clock.start()
    Thread.sleep(forTimeInterval: 0.1)

    let started = MachClock.now()
    clock.stop(timeout: 2.0)
    let elapsed = MachClock.nanoseconds(machTicks: Double(MachClock.now() &- started))

    // Even at 1 Hz, where the coarse wait is nearly a full second, stop() must return
    // within one uninterruptible mach leg plus a tick, not within a period.
    #expect(elapsed < 200_000_000, "stop() took \(elapsed / 1_000_000) ms")
    #expect(!clock.isRunning)
  }

  @Test("pause and resume re-anchor rather than catching up", .timeLimit(.minutes(1)))
  func pauseDoesNotCauseACatchUpBurst() throws {
    let recorder = TickRecorder(reserve: 4096)
    let clock = SimulationClock(ticksPerSecond: 200, mode: .realTimeLocked)
    defer { clock.stop() }
    clock.setHandler(recorder)
    clock.start()
    Thread.sleep(forTimeInterval: 0.2)
    clock.pause()

    let afterPause = recorder.samples.count
    Thread.sleep(forTimeInterval: 0.5)
    #expect(recorder.samples.count == afterPause, "a paused clock must not tick")

    clock.resume()
    Thread.sleep(forTimeInterval: 0.2)

    // ~40 ticks in 200 ms at 200 Hz. If the pause were absorbed as lateness rather than
    // re-anchored, the resume would fire a ~100-tick burst instead.
    let afterResume = recorder.samples.count - afterPause
    #expect(afterResume > 10 && afterResume < 80, "resume produced \(afterResume) ticks")
    #expect(clock.report().droppedTicks == 0, "a pause is not a dropped tick")
  }

  /// A pause is a gap the user asked for, not a shortfall. Before the re-anchor was wired to
  /// reset the measurement, the achieved rate was `executedTicks / (running + idle)`, so a
  /// 0.6 s pause in a 1 s session reported a fabricated 60% shortfall: the mirror image of
  /// upstream's flattering fallback, and just as wrong.
  @Test("a pause does not fabricate a shortfall in the readout", .timeLimit(.minutes(1)))
  func pauseDoesNotFabricateAShortfall() throws {
    let recorder = TickRecorder(reserve: 4096)
    let clock = SimulationClock(ticksPerSecond: 500, mode: .realTimeLocked)
    defer { clock.stop() }
    clock.setHandler(recorder)

    clock.start()
    Thread.sleep(forTimeInterval: 0.3)
    clock.pause()
    Thread.sleep(forTimeInterval: 0.6)  // idle for twice as long as it ran
    clock.resume()
    Thread.sleep(forTimeInterval: 0.4)

    let report = clock.report()
    let achieved = try #require(report.achievedTicksPerSecond)
    #expect(
      abs(achieved - 500) / 500 < 0.05,
      "achieved \(achieved): the idle gap must not be counted against the rate")
    #expect(report.status == .onSchedule)
    #expect(report.droppedTicks == 0)
  }

  @Test("the handler is held weakly, so the clock cannot retain the simulator")
  func handlerIsHeldWeakly() {
    let clock = SimulationClock(ticksPerSecond: 100, mode: .realTimeLocked)
    defer { clock.stop() }

    weak var weakHandler: TickRecorder?
    do {
      let recorder = TickRecorder(reserve: 8)
      weakHandler = recorder
      clock.setHandler(recorder)
      #expect(weakHandler != nil)
    }
    // D3: the simulator owns the clock, so a strong edge back would be an unconditional
    // retain cycle on the longest-lived object in the process.
    #expect(weakHandler == nil)
  }
}
