//
//  TickScheduleTests.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
//  ---------------------------------------------------------------------------------------
//  D7, the arithmetic half. Everything here is pure and deterministic: no thread, no clock
//  reading, no sleeping. The phase-anchoring property is a property of the *arithmetic*, so
//  it is provable over millions of ticks in milliseconds, which is not something a wall-clock
//  test could ever do.
//
//  The contrast test (`absorbingRuleAccumulatesDriftWhereAnchoredRuleDoesNot`) models the two
//  scheduling *rules* against an identical sequence of observation latencies. It does not
//  claim to reproduce a JVM; it isolates the one line that differs, whether the origin is
//  reassigned from the observation (`Simulator.java:520`) or held fixed, and shows that this
//  line alone is the difference between linear drift and no drift.
//  ---------------------------------------------------------------------------------------
//

import Testing

@testable import LogisimKernel

@Suite("TickSchedule — phase anchoring (D7)")
struct TickScheduleTests {

  // MARK: - The anchoring property

  @Test("deadline(n) stays on the ideal lattice over two million ticks")
  func deadlinesDoNotAccumulateError() {
    // 10 kHz is the case where upstream costs 99.6% of a core and still drifts 7.22 ms.
    let rate = 10_000.0
    let origin: UInt64 = 12_345_678_901
    let schedule = TickSchedule(ticksPerSecond: rate, origin: origin)

    let idealPeriodNanoseconds = 1_000_000_000.0 / rate
    // `deadline` truncates to whole mach ticks, so the error can never exceed one tick
    // (~41.7 ns on Apple Silicon) regardless of how far out we look. If it were an
    // accumulator instead of a multiply, this bound would be violated within a few hundred
    // ticks.
    let tolerance = MachClock.nanosecondsPerMachTick + 1.0

    // 2,000,000 ticks at 10 kHz is 200 seconds of scheduled simulation.
    for index in stride(from: 0, through: 2_000_000, by: 977) {
      let elapsedMachTicks = schedule.deadline(UInt64(index)) &- origin
      let elapsedNanoseconds = MachClock.nanoseconds(machTicks: Double(elapsedMachTicks))
      let ideal = Double(index) * idealPeriodNanoseconds
      #expect(
        abs(elapsedNanoseconds - ideal) < tolerance,
        "tick \(index): \(elapsedNanoseconds) ns vs ideal \(ideal) ns")
    }
  }

  @Test("the first thousand deadlines are individually exact", arguments: [1.0, 100.0, 10_000.0])
  func earlyDeadlinesAreExact(rate: Double) {
    let origin: UInt64 = 999_999
    let schedule = TickSchedule(ticksPerSecond: rate, origin: origin)
    let idealPeriodNanoseconds = 1_000_000_000.0 / rate
    let tolerance = MachClock.nanosecondsPerMachTick + 1.0

    for index in 0..<1000 {
      let elapsed = MachClock.nanoseconds(
        machTicks: Double(schedule.deadline(UInt64(index)) &- origin))
      #expect(abs(elapsed - Double(index) * idealPeriodNanoseconds) < tolerance)
    }
  }

  @Test("deadlines are strictly increasing at every supported rate")
  func deadlinesAreMonotonic() {
    for rate in [0.001, 0.5, 1.0, 60.0, 1000.0, 10_000.0, 1_000_000.0] {
      let schedule = TickSchedule(ticksPerSecond: rate, origin: 1_000)
      var previous = schedule.deadline(0)
      for index in 1...5000 {
        let next = schedule.deadline(UInt64(index))
        #expect(next > previous, "rate \(rate), tick \(index)")
        previous = next
      }
    }
  }

  // MARK: - The defect, isolated to one line

  /// Runs the two scheduling *rules* against an identical, deterministic sequence of
  /// observation latencies and reports the drift of each after `tickCount` ticks.
  ///
  /// - `absorbing` is upstream's rule: the next deadline is measured from *when the loop
  ///   noticed the last one*, so every observation latency is folded into the period and
  ///   never given back (`Simulator.java:445` + `:520`).
  /// - `anchored` is this port's rule: `origin + n * period`, so an observation latency is
  ///   a one-off measurement error that the next deadline knows nothing about.
  private func driftNanoseconds(
    tickCount: Int,
    periodNanoseconds: Double,
    latency: (Int) -> Double
  ) -> (absorbing: Double, anchored: Double) {
    // Upstream: deadline is relative to the previous observation.
    var lastTick = 0.0
    var absorbingFire = 0.0
    for n in 1...tickCount {
      let deadline = lastTick + periodNanoseconds
      absorbingFire = deadline + latency(n)
      lastTick = absorbingFire  // Simulator.java:520, the whole defect, in one assignment.
    }

    // Anchored: deadline is relative to a fixed origin.
    let anchoredDeadline = Double(tickCount) * periodNanoseconds
    let anchoredFire = anchoredDeadline + latency(tickCount)

    let idealFinalTime = Double(tickCount) * periodNanoseconds
    return (absorbingFire - idealFinalTime, anchoredFire - idealFinalTime)
  }

  @Test("the absorbing rule accumulates drift linearly; the anchored rule does not")
  func absorbingRuleAccumulatesDriftWhereAnchoredRuleDoesNot() {
    // A fixed 50 µs observation latency; the kind of number an ordinary timeshare wake
    // produces. Deterministic, so this test cannot flake.
    let latencyNanoseconds = 50_000.0
    let tickCount = 10_000
    let periodNanoseconds = 100_000.0  // 10 kHz

    let result = driftNanoseconds(
      tickCount: tickCount,
      periodNanoseconds: periodNanoseconds,
      latency: { _ in latencyNanoseconds })

    // Upstream's rule turns a 50 µs wake latency into 500 ms of accumulated drift.
    #expect(result.absorbing > 0.9 * Double(tickCount) * latencyNanoseconds)

    // The anchored rule's error is exactly one latency, forever; it does not depend on
    // tickCount at all.
    #expect(abs(result.anchored - latencyNanoseconds) < 1e-6)

    // And the ratio is the tick count. This is the property, stated plainly.
    #expect(result.absorbing / result.anchored > Double(tickCount) * 0.9)
  }

  @Test("drift stays bounded over ten thousand ticks with varying latency")
  func anchoredRuleIsBoundedUnderVaryingLatency() {
    // A deterministic pseudo-random latency in [0, 200 µs), so the two rules see identical
    // input and only the rule differs.
    var seed: UInt64 = 0x2545_F491_4F6C_DD1D
    func nextLatency(_ index: Int) -> Double {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Double(seed >> 40) / Double(1 << 24) * 200_000.0
    }

    var latencies = [Double](repeating: 0, count: 10_001)
    for index in 0...10_000 { latencies[index] = nextLatency(index) }

    let result = driftNanoseconds(
      tickCount: 10_000,
      periodNanoseconds: 1_000_000.0,  // 1 kHz
      latency: { latencies[$0] })

    // Anchored drift is one latency sample: strictly under the 200 µs ceiling, no matter
    // how many ticks have elapsed.
    #expect(result.anchored < 200_000.0)
    // Absorbing drift is the sum of ten thousand of them: hundreds of milliseconds.
    #expect(result.absorbing > 100_000_000.0)
  }

  // MARK: - Slow propagation must not shift the phase

  @Test("dropping ticks after an overrun leaves every later deadline on the lattice")
  func overrunDropsTicksWithoutMovingThePhase() {
    let origin: UInt64 = 5_000_000
    let schedule = TickSchedule(ticksPerSecond: 1000, origin: origin)  // 1 ms period
    let period = schedule.periodMachTicks

    // Tick 10 fires on time, then its propagation runs for 4.5 periods.
    let firedIndex: UInt64 = 10
    let overrun = UInt64(period * 4.5)
    let completedAt = schedule.deadline(firedIndex) &+ overrun

    let advance = TickLoopPolicy.advance(
      schedule: schedule, afterFiring: firedIndex, completedAtMachTime: completedAt)

    // Ticks 11..14 are gone, and the count is reported rather than absorbed.
    #expect(advance.nextIndex == 15)
    #expect(advance.droppedTicks == 4)

    // The whole point: the resumed deadline is still exactly origin + n * period. Under
    // upstream's rule the origin would now be `completedAt`, permanently offset by 4.5 ms.
    let resumed = schedule.deadline(advance.nextIndex)
    let ideal = Double(origin) + Double(advance.nextIndex) * period
    #expect(abs(Double(resumed) - ideal) < 2.0)

    // And a thousand ticks later it is *still* on the lattice.
    let later = schedule.deadline(advance.nextIndex &+ 1000)
    let laterIdeal = Double(origin) + Double(advance.nextIndex &+ 1000) * period
    #expect(abs(Double(later) - laterIdeal) < 2.0)
  }

  @Test("repeated overruns never move the phase, however many there are")
  func repeatedOverrunsNeverMoveThePhase() {
    let origin: UInt64 = 777_777
    let schedule = TickSchedule(ticksPerSecond: 500, origin: origin)  // 2 ms period
    let period = schedule.periodMachTicks

    var index: UInt64 = 0
    var totalDropped: UInt64 = 0
    for step in 0..<2000 {
      let deadline = schedule.deadline(index)
      // Every seventh tick overruns by three periods; the rest are instant.
      let cost = step % 7 == 3 ? UInt64(period * 3.2) : UInt64(period * 0.01)
      let advance = TickLoopPolicy.advance(
        schedule: schedule, afterFiring: index, completedAtMachTime: deadline &+ cost)
      totalDropped &+= advance.droppedTicks
      index = advance.nextIndex

      // Invariant checked on every single step, not just at the end.
      let ideal = Double(origin) + Double(index) * period
      #expect(abs(Double(schedule.deadline(index)) - ideal) < 2.0)
    }

    #expect(totalDropped > 0, "the overruns must actually have cost ticks")
    // Real-time-locked semantics: time advanced by exactly index periods, no more.
    let elapsedNanoseconds = MachClock.nanoseconds(
      machTicks: Double(schedule.deadline(index) &- origin))
    #expect(abs(elapsedNanoseconds - Double(index) * schedule.periodNanoseconds) < 100.0)
  }

  // MARK: - Index arithmetic

  @Test("index(containing:) and deadline(_:) are consistent inverses")
  func indexAndDeadlineAgree() {
    let origin: UInt64 = 1_000_000
    for rate in [1.0, 250.0, 10_000.0] {
      let schedule = TickSchedule(ticksPerSecond: rate, origin: origin)
      for index in stride(from: 0, through: 20_000, by: 37) {
        let due = schedule.deadline(UInt64(index))
        #expect(schedule.index(containing: due) == UInt64(index), "rate \(rate) index \(index)")
        #expect(schedule.deadline(schedule.index(containing: due)) <= due)
        #expect(schedule.nextIndex(after: due) == UInt64(index) + 1)
      }
    }
  }

  @Test("index(containing:) floors, for arbitrary times inside a period")
  func indexFloorsWithinAPeriod() {
    let origin: UInt64 = 4242
    let schedule = TickSchedule(ticksPerSecond: 128, origin: origin)
    let period = schedule.periodMachTicks

    for index in 0..<500 {
      let due = schedule.deadline(UInt64(index))
      for fraction in [0.0, 0.1, 0.5, 0.9, 0.999] {
        let probe = due &+ UInt64(period * fraction)
        #expect(schedule.index(containing: probe) == UInt64(index))
      }
    }
  }

  @Test("times before the origin resolve to tick 0")
  func timesBeforeOriginClampToZero() {
    let schedule = TickSchedule(ticksPerSecond: 10, origin: 1_000_000)
    #expect(schedule.index(containing: 0) == 0)
    #expect(schedule.index(containing: 999_999) == 0)
    #expect(schedule.nextIndex(after: 0) == 0)
  }

  // MARK: - Lateness

  @Test("latenessNanoseconds is signed and correctly oriented")
  func latenessIsSigned() {
    let schedule = TickSchedule(ticksPerSecond: 1000, origin: 100_000)
    let due = schedule.deadline(42)
    let oneMillisecondOfTicks = UInt64(MachClock.machTicks(nanoseconds: 1_000_000))

    #expect(schedule.latenessNanoseconds(of: due, forTick: 42) == 0)

    let late = schedule.latenessNanoseconds(of: due &+ oneMillisecondOfTicks, forTick: 42)
    #expect(late > 999_000 && late < 1_001_000)

    let early = schedule.latenessNanoseconds(of: due &- oneMillisecondOfTicks, forTick: 42)
    #expect(early < -999_000 && early > -1_001_000)
  }

  // MARK: - Robustness (D13: clamp, never trap)

  @Test(
    "nonsense rates clamp instead of trapping",
    arguments: [0.0, -1.0, -1e12, Double.nan, Double.infinity, -Double.infinity, 1e30])
  func nonsenseRatesClamp(rate: Double) {
    let schedule = TickSchedule(ticksPerSecond: rate)
    #expect(schedule.ticksPerSecond >= TickSchedule.minimumTicksPerSecond)
    #expect(schedule.ticksPerSecond <= TickSchedule.maximumTicksPerSecond)
    #expect(schedule.periodQ64 > 0)
    // Whatever the rate clamped to, the lattice still has to be strictly increasing.
    #expect(schedule.deadline(1) > schedule.deadline(0))
  }

  /// Regression. The first version of this file capped the rate at a flat 100 MHz, which is
  /// four times finer than the Apple Silicon mach timebase can express. The period floored to
  /// *zero* whole mach ticks, `deadline(n)` stopped increasing, and the clock would have
  /// free-run while still reporting itself real-time-locked: the phase-anchoring guarantee
  /// silently gone at exactly the rate where it matters most.
  @Test("the maximum rate is bounded by the hardware timebase")
  func maximumRateRespectsTheTimebase() {
    let oneTickPerMachTick = 1_000_000_000.0 / MachClock.nanosecondsPerMachTick
    #expect(TickSchedule.maximumTicksPerSecond <= oneTickPerMachTick)

    for absurdRate in [1e30, Double.infinity, 1e9] {
      let schedule = TickSchedule(ticksPerSecond: absurdRate, origin: 1_000)
      #expect(schedule.ticksPerSecond == TickSchedule.maximumTicksPerSecond)
      // One whole mach tick is the floor, structurally; not because the cap happens to
      // agree with it.
      #expect(schedule.periodMachTicks >= 1.0)
      for index in 1...2000 {
        #expect(schedule.deadline(UInt64(index)) > schedule.deadline(UInt64(index) - 1))
      }
    }
  }

  @Test("rebasing changes only the origin")
  func rebasingPreservesTheRate() {
    let original = TickSchedule(ticksPerSecond: 440, origin: 1000)
    let rebased = original.rebased(to: 9_999_999)
    #expect(rebased.ticksPerSecond == original.ticksPerSecond)
    #expect(rebased.periodQ64 == original.periodQ64)
    #expect(rebased.origin == 9_999_999)
    #expect(rebased.deadline(0) == 9_999_999)
    #expect(
      rebased.deadline(100) &- rebased.origin == original.deadline(100) &- original.origin)
  }

  // MARK: - TickLoopPolicy

  @Test("nextAction waits before the deadline and fires at or after it")
  func nextActionRespectsTheDeadline() {
    let schedule = TickSchedule(ticksPerSecond: 200, origin: 10_000)
    let due = schedule.deadline(7)

    #expect(
      TickLoopPolicy.nextAction(schedule: schedule, index: 7, machTime: due &- 1)
        == .wait(untilMachTime: due))

    #expect(
      TickLoopPolicy.nextAction(schedule: schedule, index: 7, machTime: due)
        == .fire(index: 7, deadlineMachTime: due, latenessMachTicks: 0))

    #expect(
      TickLoopPolicy.nextAction(schedule: schedule, index: 7, machTime: due &+ 250)
        == .fire(index: 7, deadlineMachTime: due, latenessMachTicks: 250))
  }

  @Test("a tick that finishes inside its period drops nothing")
  func timelyTickDropsNothing() {
    let schedule = TickSchedule(ticksPerSecond: 100, origin: 10_000)
    let finished = schedule.deadline(3) &+ UInt64(schedule.periodMachTicks * 0.5)
    let advance = TickLoopPolicy.advance(
      schedule: schedule, afterFiring: 3, completedAtMachTime: finished)
    #expect(advance == TickAdvance(nextIndex: 4, droppedTicks: 0))
  }
}

@Suite("Tick statistics — the honest readout (D7)")
struct TickStatisticsTests {

  @Test("an unmeasured rate is nil, never the requested figure")
  func unmeasuredRateIsNil() {
    let statistics = TickStatistics()
    statistics.reset(requestedTicksPerSecond: 10_000)

    var report = statistics.snapshot(mode: .realTimeLocked, isRunning: true)
    #expect(report.achievedTicksPerSecond == nil)
    #expect(report.achievedDescription == "—")
    #expect(report.status == .measuring)

    // One tick is still not enough: one fire time gives zero intervals.
    statistics.recordTick(
      firedAtMachTime: 1000, propagationMachTicks: 5, latenessMachTicks: 0,
      isScheduled: true, failure: nil)
    report = statistics.snapshot(mode: .realTimeLocked, isRunning: true)
    #expect(report.achievedTicksPerSecond == nil)
    #expect(report.status == .measuring)
    // The specific upstream behaviour that must never appear here.
    #expect(report.achievedTicksPerSecond != report.requestedTicksPerSecond)
  }

  @Test("the achieved rate is measured between fire times, not inflated by an off-by-one")
  func achievedRateUsesIntervalsNotSamples() {
    let statistics = TickStatistics()
    statistics.reset(requestedTicksPerSecond: 1000)

    // 11 fires, one millisecond apart => 10 intervals over 10 ms => exactly 1000 ticks/s.
    let millisecond = UInt64(MachClock.machTicks(nanoseconds: 1_000_000))
    for index in 0...10 {
      statistics.recordTick(
        firedAtMachTime: 1_000_000 &+ UInt64(index) &* millisecond,
        propagationMachTicks: 10,
        latenessMachTicks: 0,
        isScheduled: true,
        failure: nil)
    }

    let report = statistics.snapshot(mode: .realTimeLocked, isRunning: true)
    let achieved = try! #require(report.achievedTicksPerSecond)
    #expect(abs(achieved - 1000) < 1.0)
    #expect(report.status == .onSchedule)
    #expect(report.isMeetingTarget)
  }

  @Test("a shortfall is reported as a shortfall")
  func shortfallIsReported() {
    let statistics = TickStatistics()
    statistics.reset(requestedTicksPerSecond: 10_000)

    // Fires 1 ms apart against a 0.1 ms request: 1 kHz achieved, 10 kHz asked for.
    let millisecond = UInt64(MachClock.machTicks(nanoseconds: 1_000_000))
    for index in 0...20 {
      statistics.recordTick(
        firedAtMachTime: 1_000_000 &+ UInt64(index) &* millisecond,
        propagationMachTicks: millisecond,
        latenessMachTicks: 0,
        isScheduled: true,
        failure: nil)
    }

    let report = statistics.snapshot(mode: .realTimeLocked, isRunning: true)
    #expect(!report.isMeetingTarget)
    if case .behindSchedule = report.status {} else {
      Issue.record("expected .behindSchedule, got \(report.status)")
    }
    let achieved = try! #require(report.achievedTicksPerSecond)
    #expect(abs(achieved - 1000) < 10)
    let shortfall = try! #require(report.shortfallFraction)
    #expect(shortfall > 0.85)
    #expect(report.summary.hasPrefix("BEHIND"))
    #expect(!report.summary.contains("10.0 kHz of a requested 10.0 kHz"))
  }

  @Test("dropped ticks alone put the report behind schedule")
  func droppedTicksAreReported() {
    let statistics = TickStatistics()
    statistics.reset(requestedTicksPerSecond: 100)
    statistics.recordDroppedTicks(7)
    let report = statistics.snapshot(mode: .realTimeLocked, isRunning: true)
    #expect(report.droppedTicks == 7)
    #expect(report.status == .behindSchedule(droppedTicks: 7))
  }

  /// Regression from a real measurement: 10 kHz, 50,015 ticks executed, exactly one dropped
  /// to an OS hiccup, and the readout said
  /// `BEHIND: 10.0 kHz of a requested 10.0 kHz (0% short), 1 tick dropped`. Self-contradictory,
  /// and an indicator that cries wolf is ignored, which hides the real thing exactly as
  /// effectively as upstream's flattering fallback. The verdict is now tolerance-based; the
  /// disclosure is unconditional.
  @Test("an isolated drop does not cry wolf, but is still disclosed")
  func immaterialDropIsDisclosedWithoutFalseAlarm() {
    let statistics = TickStatistics()
    statistics.reset(requestedTicksPerSecond: 1000)
    let millisecond = UInt64(MachClock.machTicks(nanoseconds: 1_000_000))
    for index in 0...1000 {
      statistics.recordTick(
        firedAtMachTime: 1_000_000 &+ UInt64(index) &* millisecond,
        propagationMachTicks: 10, latenessMachTicks: 0, isScheduled: true, failure: nil)
    }
    statistics.recordDroppedTicks(1)

    let report = statistics.snapshot(mode: .realTimeLocked, isRunning: true)
    #expect(report.status == .onSchedule)
    #expect(report.isMeetingTarget)
    // Disclosed anyway: a dropped tick is a clock edge that never happened.
    #expect(report.droppedTicks == 1)
    #expect(report.summary.contains("1 tick dropped"))
    #expect(!report.summary.contains("BEHIND"))
    #expect(!report.summary.contains("0% short"))
  }

  @Test("a material drop rate is behind schedule even when the interval rate looks right")
  func materialDropRateIsBehindSchedule() {
    let statistics = TickStatistics()
    statistics.reset(requestedTicksPerSecond: 1000)
    let millisecond = UInt64(MachClock.machTicks(nanoseconds: 1_000_000))
    for index in 0...100 {
      statistics.recordTick(
        firedAtMachTime: 1_000_000 &+ UInt64(index) &* millisecond,
        propagationMachTicks: 10, latenessMachTicks: 0, isScheduled: true, failure: nil)
    }
    statistics.recordDroppedTicks(100)  // half the scheduled edges never happened

    let report = statistics.snapshot(mode: .realTimeLocked, isRunning: true)
    #expect(!report.isMeetingTarget)
    #expect(report.status == .behindSchedule(droppedTicks: 100))
    #expect(report.summary.hasPrefix("BEHIND"))
    #expect(report.summary.contains("100 ticks dropped"))
  }

  @Test("drops prove a shortfall before any rate is measurable")
  func dropsBeforeAnyRateAreStillBehind() {
    let statistics = TickStatistics()
    statistics.reset(requestedTicksPerSecond: 100)
    statistics.recordDroppedTicks(3)
    let report = statistics.snapshot(mode: .realTimeLocked, isRunning: true)
    #expect(report.achievedTicksPerSecond == nil)
    #expect(report.status == .behindSchedule(droppedTicks: 3))
  }

  @Test("manual ticks are excluded from the rate")
  func manualTicksAreExcludedFromTheRate() {
    let statistics = TickStatistics()
    statistics.reset(requestedTicksPerSecond: 1)
    for index in 0..<5 {
      statistics.recordTick(
        firedAtMachTime: 1000 &+ UInt64(index) &* 1000,
        propagationMachTicks: 10,
        latenessMachTicks: nil,
        isScheduled: false,
        failure: nil)
    }
    let report = statistics.snapshot(mode: .realTimeLocked, isRunning: true)
    #expect(report.manualTicks == 5)
    #expect(report.executedTicks == 0)
    #expect(report.achievedTicksPerSecond == nil)
  }

  @Test("free-running reports no lateness rather than zero lateness")
  func freeRunningHasNoLateness() {
    let statistics = TickStatistics()
    statistics.reset(requestedTicksPerSecond: 1)
    for index in 0..<10 {
      statistics.recordTick(
        firedAtMachTime: 1000 &+ UInt64(index) &* 100,
        propagationMachTicks: 10,
        latenessMachTicks: nil,
        isScheduled: true,
        failure: nil)
    }
    let report = statistics.snapshot(mode: .freeRunning, isRunning: true)
    #expect(report.lateness == nil)
    #expect(report.peakAbsoluteLatenessNanoseconds == nil)
    #expect(report.status == .freeRunning)
  }

  @Test("lateness summary computes drift, jitter and the tail")
  func latenessSummaryIsCorrect() {
    // Symmetric samples: mean 0, so drift 0, but a real spread.
    let samples: [Double] = [-100, -50, 0, 50, 100]
    let summary = try! #require(TickStatistics.summarize(samples))
    #expect(summary.sampleCount == 5)
    #expect(abs(summary.meanNanoseconds) < 1e-9)
    #expect(abs(summary.meanAbsoluteNanoseconds - 60) < 1e-9)
    #expect(abs(summary.medianNanoseconds) < 1e-9)
    #expect(summary.minimumNanoseconds == -100)
    #expect(summary.maximumNanoseconds == 100)
    #expect(summary.peakToPeakNanoseconds == 200)
    // Population standard deviation of {-100,-50,0,50,100} is sqrt(5000) ≈ 70.71.
    #expect(abs(summary.jitterNanoseconds - 70.710_678) < 0.001)
    #expect(summary.percentile99AbsoluteNanoseconds > 95)
  }

  @Test("the lateness window is bounded and keeps the most recent samples")
  func windowIsBounded() {
    let statistics = TickStatistics()
    statistics.reset(requestedTicksPerSecond: 1000)
    let capacity = TickStatistics.windowCapacity

    // Twice the capacity: the first half must have aged out of the distribution.
    for index in 0..<(capacity * 2) {
      let lateness: Int64 = index < capacity ? 1_000_000 : 1
      statistics.recordTick(
        firedAtMachTime: 1000 &+ UInt64(index),
        propagationMachTicks: 1,
        latenessMachTicks: lateness,
        isScheduled: true,
        failure: nil)
    }

    let report = statistics.snapshot(mode: .realTimeLocked, isRunning: true)
    let lateness = try! #require(report.lateness)
    #expect(lateness.sampleCount == capacity)
    // Windowed mean reflects only the recent, small samples...
    #expect(lateness.meanNanoseconds < 1000)
    // ...but the lifetime peak still remembers the bad ones. Nothing ages out silently.
    let peak = try! #require(report.peakAbsoluteLatenessNanoseconds)
    #expect(peak > 1_000_000)
  }

  @Test("handler errors are counted, not swallowed and not fatal")
  func handlerErrorsAreCounted() {
    let statistics = TickStatistics()
    statistics.reset(requestedTicksPerSecond: 10)
    statistics.recordTick(
      firedAtMachTime: 1, propagationMachTicks: 1, latenessMachTicks: 0,
      isScheduled: true, failure: "oscillation detected")
    let report = statistics.snapshot(mode: .realTimeLocked, isRunning: true)
    #expect(report.errorCount == 1)
    #expect(report.lastErrorDescription == "oscillation detected")
  }

  @Test("frequency formatting matches the units upstream's label uses")
  func frequencyFormatting() {
    #expect(TickRateReport.formatFrequency(1) == "1.00 Hz")
    #expect(TickRateReport.formatFrequency(0.5) == "0.500 Hz")
    #expect(TickRateReport.formatFrequency(100) == "100 Hz")
    #expect(TickRateReport.formatFrequency(1000) == "1.00 kHz")
    #expect(TickRateReport.formatFrequency(10_000) == "10.0 kHz")
    #expect(TickRateReport.formatFrequency(2_000_000) == "2.00 MHz")
  }
}
