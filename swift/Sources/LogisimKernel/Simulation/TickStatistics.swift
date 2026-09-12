//
//  TickStatistics.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution).
//  logisim-evolution is free software released under the GNU GPLv3; this translation is
//  therefore GPL-3.0-only. See LICENSE.md.
//
//  ---------------------------------------------------------------------------------------
//  D7; what the honest readout is computed from.
//
//  Two rules shape this file.
//
//  1. **Recording must be O(1) and allocation-free.** It runs on the realtime-scheduled
//     clock thread, at up to 10 kHz. Anything that allocates, grows, or sorts on the write
//     path would show up as jitter in the very number it is measuring. So: a fixed-size ring
//     of lateness samples plus a handful of running sums. Sorting happens only on `snapshot()`,
//     which is called by a UI poll or a test, never by the clock.
//
//  2. **A quantity that was not measured is `nil`, never a plausible substitute.** Upstream's
//     `TickCounter` returns the requested frequency from four separate "cannot compute"
//     branches; this type returns `nil` and lets `TickRateReport` say so.
//
//  D1: `NSLock`, not an actor. The clock thread and the UI thread contend for a few hundred
//  nanoseconds per tick, which is well inside the noise floor of the measurement.
//  ---------------------------------------------------------------------------------------
//

import Foundation

/// Thread-safe accumulator behind `SimulationClock.report()`.
///
/// Internal on purpose: the supported public surface is `TickRateReport`. Tests reach it
/// through `@testable import`.
final class TickStatistics {

  /// Number of recent lateness samples retained for the distribution.
  ///
  /// 4096 is ~0.4 s at 10 kHz and ~68 min at 1 Hz, so the window is meaningful at both ends
  /// of the supported range. Percentiles are windowed; counts, peaks and the achieved rate
  /// are lifetime (since the last reset), so a bad tick cannot age out of the report
  /// silently.
  static let windowCapacity = 4096

  private let lock = NSLock()

  // MARK: - Configuration mirror

  private var requestedTicksPerSecond: Double = 1
  private var isRealtimeScheduled = false

  // MARK: - Lifetime counters

  private var executedTicks: UInt64 = 0
  private var droppedTicks: UInt64 = 0
  private var manualTicks: UInt64 = 0
  private var errorCount: UInt64 = 0
  private var lastErrorDescription: String?

  private var firstFiredMachTime: UInt64 = 0
  private var lastFiredMachTime: UInt64 = 0

  private var peakAbsoluteLatenessNanoseconds: Double = 0
  private var hasLatenessSample = false

  private var propagationSumNanoseconds: Double = 0
  private var propagationMaximumNanoseconds: Double = 0
  private var propagationSampleCount: UInt64 = 0

  // MARK: - Windowed lateness ring

  private var window = [Double](repeating: 0, count: TickStatistics.windowCapacity)
  private var windowWriteIndex = 0
  private var windowCount = 0

  // MARK: - Lifecycle

  init() {}

  /// Clears every measurement and re-anchors the rate the report will compare against.
  ///
  /// Called whenever the frequency, the mode, or the phase origin changes: an achieved rate
  /// averaged across a frequency change is not a measurement of anything.
  func reset(requestedTicksPerSecond rate: Double) {
    lock.lock()
    defer { lock.unlock() }
    requestedTicksPerSecond = rate
    executedTicks = 0
    droppedTicks = 0
    manualTicks = 0
    errorCount = 0
    lastErrorDescription = nil
    firstFiredMachTime = 0
    lastFiredMachTime = 0
    peakAbsoluteLatenessNanoseconds = 0
    hasLatenessSample = false
    propagationSumNanoseconds = 0
    propagationMaximumNanoseconds = 0
    propagationSampleCount = 0
    windowWriteIndex = 0
    windowCount = 0
  }

  func setRealtimeScheduled(_ granted: Bool) {
    lock.lock()
    isRealtimeScheduled = granted
    lock.unlock()
  }

  // MARK: - Write path (clock thread only)

  /// Records one completed tick.
  ///
  /// - Parameters:
  ///   - firedAtMachTime: when the handler was entered. The achieved rate is measured
  ///     between *fire* times, not completion times, so a propagation whose duration varies
  ///     does not smear the rate measurement.
  ///   - propagationMachTicks: time spent inside the handler.
  ///   - latenessMachTicks: `fired - deadline`, or `nil` when the tick had no deadline
  ///     (free-running, or a manual out-of-band tick). `nil` is recorded as "no sample",
  ///     never as zero; zero would be a claim of perfect timing.
  ///   - isScheduled: `false` for manual ticks, which are counted separately and excluded
  ///     from every rate calculation.
  ///   - failure: description of a thrown handler error, if any (D13).
  func recordTick(
    firedAtMachTime: UInt64,
    propagationMachTicks: UInt64,
    latenessMachTicks: Int64?,
    isScheduled: Bool,
    failure: String?
  ) {
    let propagationNanoseconds = Double(propagationMachTicks) * MachClock.nanosecondsPerMachTick

    lock.lock()
    defer { lock.unlock() }

    if let failure {
      errorCount &+= 1
      lastErrorDescription = failure
    }

    propagationSumNanoseconds += propagationNanoseconds
    propagationMaximumNanoseconds = max(propagationMaximumNanoseconds, propagationNanoseconds)
    propagationSampleCount &+= 1

    guard isScheduled else {
      manualTicks &+= 1
      return
    }

    if executedTicks == 0 { firstFiredMachTime = firedAtMachTime }
    lastFiredMachTime = firedAtMachTime
    executedTicks &+= 1

    if let latenessMachTicks {
      let nanoseconds = MachClock.nanoseconds(signedMachTicks: latenessMachTicks)
      window[windowWriteIndex] = nanoseconds
      windowWriteIndex = (windowWriteIndex + 1) % Self.windowCapacity
      if windowCount < Self.windowCapacity { windowCount += 1 }
      peakAbsoluteLatenessNanoseconds = max(peakAbsoluteLatenessNanoseconds, abs(nanoseconds))
      hasLatenessSample = true
    }
  }

  /// Records ticks skipped because their deadlines passed during a propagation.
  func recordDroppedTicks(_ count: UInt64) {
    guard count > 0 else { return }
    lock.lock()
    droppedTicks &+= count
    lock.unlock()
  }

  // MARK: - Read path

  /// Mean handler cost so far, or `nil` if nothing has run yet.
  ///
  /// Used by the clock to size its `THREAD_TIME_CONSTRAINT_POLICY` declaration from measured
  /// reality rather than a guess.
  var meanPropagationNanoseconds: Double? {
    lock.lock()
    defer { lock.unlock() }
    guard propagationSampleCount > 0 else { return nil }
    return propagationSumNanoseconds / Double(propagationSampleCount)
  }

  /// Assembles the honest report.
  ///
  /// - Parameters:
  ///   - mode: the mode in force, supplied by the clock (this type does not own it).
  ///   - isRunning: whether the clock thread is alive and auto-ticking.
  func snapshot(mode: TickClockMode, isRunning: Bool) -> TickRateReport {
    lock.lock()

    let requested = requestedTicksPerSecond
    let executed = executedTicks
    let dropped = droppedTicks
    let manual = manualTicks
    let errors = errorCount
    let lastError = lastErrorDescription
    let realtime = isRealtimeScheduled
    let peakLateness = hasLatenessSample ? peakAbsoluteLatenessNanoseconds : nil

    let meanPropagation =
      propagationSampleCount > 0
      ? propagationSumNanoseconds / Double(propagationSampleCount) : nil
    let maximumPropagation = propagationSampleCount > 0 ? propagationMaximumNanoseconds : nil

    // Span between the first and last *fire* times. With N fires there are N-1 intervals;
    // dividing N by the span would inflate the rate by a factor of N/(N-1), which at small
    // N is exactly the kind of flattering error this readout exists to avoid.
    var measurementSeconds = 0.0
    var achieved: Double?
    if executed >= 2, lastFiredMachTime > firstFiredMachTime {
      let spanNanoseconds =
        Double(lastFiredMachTime &- firstFiredMachTime) * MachClock.nanosecondsPerMachTick
      measurementSeconds = spanNanoseconds / 1_000_000_000
      if measurementSeconds > 0 {
        achieved = Double(executed - 1) / measurementSeconds
      }
    }

    // Copy the ring while holding the lock; sort and reduce after releasing it.
    var samples = [Double]()
    if windowCount > 0 {
      samples.reserveCapacity(windowCount)
      let start = (windowWriteIndex - windowCount + Self.windowCapacity) % Self.windowCapacity
      for offset in 0..<windowCount {
        samples.append(window[(start + offset) % Self.windowCapacity])
      }
    }

    lock.unlock()

    let lateness = mode == .freeRunning ? nil : Self.summarize(samples)

    let status = Self.status(
      mode: mode,
      isRunning: isRunning,
      executed: executed,
      dropped: dropped,
      achieved: achieved,
      requested: requested)

    return TickRateReport(
      mode: mode,
      isRunning: isRunning,
      isRealtimeScheduled: realtime,
      requestedTicksPerSecond: requested,
      executedTicks: executed,
      droppedTicks: dropped,
      manualTicks: manual,
      measurementSeconds: measurementSeconds,
      achievedTicksPerSecond: achieved,
      lateness: lateness,
      peakAbsoluteLatenessNanoseconds: mode == .freeRunning ? nil : peakLateness,
      meanPropagationNanoseconds: meanPropagation,
      maximumPropagationNanoseconds: maximumPropagation,
      errorCount: errors,
      lastErrorDescription: lastError,
      status: status)
  }

  // MARK: - Pure helpers

  /// The tolerance within which a measured rate counts as meeting its target.
  ///
  /// 2% is comfortably wider than the measurement noise of a short window and far narrower
  /// than any real shortfall: the 10 kHz upstream case in D7's table misses by orders of
  /// magnitude, not by percent.
  static let rateTolerance = 0.02

  /// The verdict.
  ///
  /// Note the tolerance applies to the **drop fraction** as well as to the rate, and that is
  /// a deliberate correction to a first version of this file which made any drop at all
  /// `.behindSchedule`. A measured run at 10 kHz executed 50,015 ticks and dropped 1, a
  /// single OS scheduling hiccup, and the readout said
  /// `BEHIND: 10.0 kHz of a requested 10.0 kHz (0% short)`, which is self-contradictory and
  /// is its own kind of dishonesty: an indicator that cries wolf gets ignored, and then it
  /// hides the real thing just as effectively as upstream's flattering fallback does.
  ///
  /// So: the *status* is about whether the requested rate is being met, and one tick in
  /// fifty thousand does not stop it being met. The drop is not hidden; `droppedTicks` is
  /// always populated and `summary` always prints it, in either status.
  static func status(
    mode: TickClockMode,
    isRunning: Bool,
    executed: UInt64,
    dropped: UInt64,
    achieved: Double?,
    requested: Double
  ) -> TickRateStatus {
    guard isRunning else { return .idle }
    if mode == .freeRunning { return .freeRunning }

    guard let achieved, executed >= 2, requested > 0 else {
      // No measurable rate yet. Drops are still proof of a shortfall on their own; they
      // are counted against a deadline that has already passed, not against an estimate.
      return dropped > 0 ? .behindSchedule(droppedTicks: dropped) : .measuring
    }

    let scheduled = Double(dropped) + Double(executed)
    let dropFraction = scheduled > 0 ? Double(dropped) / scheduled : 0
    let meetsRate = achieved >= requested * (1 - rateTolerance)
    return meetsRate && dropFraction <= rateTolerance
      ? .onSchedule
      : .behindSchedule(droppedTicks: dropped)
  }

  static func summarize(_ samples: [Double]) -> LatenessSummary? {
    guard !samples.isEmpty else { return nil }
    let count = Double(samples.count)

    var sum = 0.0
    var absoluteSum = 0.0
    for value in samples {
      sum += value
      absoluteSum += abs(value)
    }
    let mean = sum / count

    var varianceSum = 0.0
    for value in samples {
      let delta = value - mean
      varianceSum += delta * delta
    }
    // Population standard deviation: this is the whole window, not a sample drawn from it.
    let standardDeviation = (varianceSum / count).squareRoot()

    let sortedSigned = samples.sorted()
    let sortedAbsolute = samples.map(abs).sorted()

    return LatenessSummary(
      sampleCount: samples.count,
      meanNanoseconds: mean,
      meanAbsoluteNanoseconds: absoluteSum / count,
      standardDeviationNanoseconds: standardDeviation,
      medianNanoseconds: percentile(sortedSigned, 0.5),
      percentile99AbsoluteNanoseconds: percentile(sortedAbsolute, 0.99),
      minimumNanoseconds: sortedSigned[0],
      maximumNanoseconds: sortedSigned[sortedSigned.count - 1])
  }

  /// Linear-interpolated percentile over an already sorted array.
  static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    guard sorted.count > 1 else { return sorted[0] }
    let rank = min(max(fraction, 0), 1) * Double(sorted.count - 1)
    let lower = Int(rank.rounded(.down))
    let upper = min(lower + 1, sorted.count - 1)
    let weight = rank - Double(lower)
    return sorted[lower] + (sorted[upper] - sorted[lower]) * weight
  }
}
