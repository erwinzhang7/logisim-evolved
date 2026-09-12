//
//  TickRateReport.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution).
//  logisim-evolution is free software released under the GNU GPLv3; this translation is
//  therefore GPL-3.0-only. See LICENSE.md.
//
//  ---------------------------------------------------------------------------------------
//  D7: the honest readout.
//
//  Upstream's `TickCounter.HistoryData.getFullCyclesPerSecond()` (4.1.0,
//  `gui/main/TickCounter.java:103-116`) has **four** return paths that hand back
//  `requestedClockFrequency`, the number the user typed, whenever it cannot compute a real
//  one: not enough ticks, no elapsed time, a zero tick count, or auto-ticking off. The UI
//  label makes no distinction, so a simulation running at 300 Hz against a 10 kHz request
//  can read "10 kHz" indefinitely. Combined with the scheduler defect in `TickLoopPolicy`'s
//  header, that is why the drift was never visible from inside the application.
//
//  The rule here is absolute and is enforced by the type: **`achievedTicksPerSecond` is an
//  `Optional` and is `nil` when it cannot be measured.** There is no code path anywhere in
//  this module that assigns the requested rate to an "achieved" field. If we do not know, we
//  say we do not know, and `status` says why.
//  ---------------------------------------------------------------------------------------
//

import Foundation

/// How the clock relates simulated time to wall-clock time.
public enum TickClockMode: Equatable, Sendable {

  /// The schedule is bound to the wall clock: tick `n` runs at `origin + n * period`.
  ///
  /// If a propagation overruns, the ticks whose deadlines passed are **dropped and
  /// reported**; the phase is never stretched to accommodate them. This is the mode a
  /// user-facing clock frequency actually means.
  case realTimeLocked

  /// Ticks run back to back as fast as propagation allows; the wall clock is irrelevant.
  ///
  /// For batch/headless work (`-tty table`, test vectors, the differential harness) where
  /// pacing is pure waste. Lateness and jitter are undefined in this mode and are reported
  /// as `nil` rather than as zero; zero would be a claim of perfect timing.
  case freeRunning
}

/// What the clock is doing, and, when it is not keeping up, that it is not keeping up.
public enum TickRateStatus: Equatable, Sendable {

  /// Not ticking: stopped, paused, or no handler attached.
  case idle

  /// Ticking, but too few ticks have completed to compute a rate honestly.
  case measuring

  /// Real-time-locked, no ticks dropped, achieved rate matching the request.
  case onSchedule

  /// Real-time-locked and **failing to meet the requested rate**.
  ///
  /// The associated value is the number of scheduled ticks skipped since the last reset.
  /// It can be zero and the status still be `behindSchedule`: a propagation that overruns
  /// by less than one period drops nothing but still drags the achieved rate below the
  /// request.
  case behindSchedule(droppedTicks: UInt64)

  /// Free-running. There is no target to meet, so "on schedule" is not a meaningful claim.
  case freeRunning
}

/// Distribution of tick lateness: the measured jitter, and the drift.
///
/// "Lateness" is `actualFireTime - scheduledDeadline`, signed, in nanoseconds. Because the
/// deadline comes from the fixed origin (`TickSchedule`), lateness is an *absolute* error
/// against the ideal lattice, not an error against the previous tick. Upstream cannot report
/// this quantity at all: its deadline is defined relative to when the last tick happened, so
/// by construction it is never late with respect to its own reckoning.
public struct LatenessSummary: Equatable, Sendable {

  /// Number of samples in the window these statistics were computed over.
  public let sampleCount: Int

  /// Mean signed lateness. **This is the drift.** For a phase-anchored schedule it stays
  /// flat; for `lastTick + period` it grows without bound (measured: 80.3 ms at 1 Hz with a
  /// 2 ms propagation, versus 3.6 µs here).
  public let meanNanoseconds: Double

  /// Mean of `|lateness|`.
  public let meanAbsoluteNanoseconds: Double

  /// Standard deviation of lateness. **This is the jitter.**
  public let standardDeviationNanoseconds: Double

  /// Median signed lateness.
  public let medianNanoseconds: Double

  /// 99th percentile of `|lateness|`: the tail a user perceives, not the average.
  public let percentile99AbsoluteNanoseconds: Double

  /// Most negative (earliest) lateness observed in the window.
  public let minimumNanoseconds: Double

  /// Most positive (latest) lateness observed in the window.
  public let maximumNanoseconds: Double

  public init(
    sampleCount: Int,
    meanNanoseconds: Double,
    meanAbsoluteNanoseconds: Double,
    standardDeviationNanoseconds: Double,
    medianNanoseconds: Double,
    percentile99AbsoluteNanoseconds: Double,
    minimumNanoseconds: Double,
    maximumNanoseconds: Double
  ) {
    self.sampleCount = sampleCount
    self.meanNanoseconds = meanNanoseconds
    self.meanAbsoluteNanoseconds = meanAbsoluteNanoseconds
    self.standardDeviationNanoseconds = standardDeviationNanoseconds
    self.medianNanoseconds = medianNanoseconds
    self.percentile99AbsoluteNanoseconds = percentile99AbsoluteNanoseconds
    self.minimumNanoseconds = minimumNanoseconds
    self.maximumNanoseconds = maximumNanoseconds
  }

  /// Alias matching the vocabulary of the D7 measurement table.
  public var driftNanoseconds: Double { meanNanoseconds }

  /// Alias matching the vocabulary of the D7 measurement table.
  public var jitterNanoseconds: Double { standardDeviationNanoseconds }

  /// Full spread of the window.
  public var peakToPeakNanoseconds: Double { maximumNanoseconds - minimumNanoseconds }
}

/// An immutable snapshot of what the simulation clock is actually doing.
///
/// Safe to take from any thread (see `SimulationClock.report()`), and safe to hand to a
/// `@MainActor` UI: it is a plain value type with no reference to the clock.
public struct TickRateReport: Equatable, Sendable {

  // MARK: - Configuration

  /// The mode in force.
  public let mode: TickClockMode

  /// Whether the clock thread is alive and auto-ticking.
  public let isRunning: Bool

  /// Whether `THREAD_TIME_CONSTRAINT_POLICY` was actually granted.
  ///
  /// A `false` here with `mode == .realTimeLocked` means the numbers below are still real
  /// measurements, but the clock is competing on the timeshare run queue and the jitter tail
  /// will be worse under load. Reported rather than hidden, because "we asked for realtime"
  /// and "we got realtime" are different facts.
  public let isRealtimeScheduled: Bool

  /// The rate the user asked for, in ticks per second.
  ///
  /// Kept deliberately distinct from `achievedTicksPerSecond` and never substituted for it.
  public let requestedTicksPerSecond: Double

  // MARK: - Counts

  /// Scheduled ticks actually executed since the last reset (manual ticks excluded).
  public let executedTicks: UInt64

  /// Scheduled ticks skipped because propagation overran their deadlines.
  public let droppedTicks: UInt64

  /// Out-of-band single ticks requested by the user. Excluded from every rate calculation;
  /// a manual tick has no deadline, so folding it into the achieved rate would corrupt it.
  public let manualTicks: UInt64

  /// Wall-clock span the achieved rate was measured over, in seconds.
  public let measurementSeconds: Double

  // MARK: - Measurements

  /// Measured ticks per second, or `nil` when it cannot honestly be computed.
  ///
  /// `nil` means "not enough evidence": fewer than two executed ticks, or no elapsed time.
  /// It does **not** fall back to `requestedTicksPerSecond`. That fallback is the specific
  /// upstream behaviour (`TickCounter.java:104/111/115`) that hid the scheduling defect.
  public let achievedTicksPerSecond: Double?

  /// Lateness distribution over the recent window, or `nil` in free-running mode (where
  /// lateness is undefined) or before any sample exists.
  public let lateness: LatenessSummary?

  /// Largest `|lateness|` seen since the last reset, in nanoseconds: lifetime, not
  /// windowed, so a single bad tick an hour ago is still visible.
  public let peakAbsoluteLatenessNanoseconds: Double?

  /// Mean time spent inside the tick handler (toggle clocks + propagate), in nanoseconds.
  public let meanPropagationNanoseconds: Double?

  /// Worst time spent inside the tick handler since the last reset.
  public let maximumPropagationNanoseconds: Double?

  // MARK: - Errors

  /// Number of ticks whose handler threw. D13: a throwing propagation is a recoverable
  /// circuit error, so it is counted and surfaced, never a trap.
  public let errorCount: UInt64

  /// Description of the most recent handler error, if any.
  public let lastErrorDescription: String?

  // MARK: - Verdict

  /// The honest verdict.
  public let status: TickRateStatus

  public init(
    mode: TickClockMode,
    isRunning: Bool,
    isRealtimeScheduled: Bool,
    requestedTicksPerSecond: Double,
    executedTicks: UInt64,
    droppedTicks: UInt64,
    manualTicks: UInt64,
    measurementSeconds: Double,
    achievedTicksPerSecond: Double?,
    lateness: LatenessSummary?,
    peakAbsoluteLatenessNanoseconds: Double?,
    meanPropagationNanoseconds: Double?,
    maximumPropagationNanoseconds: Double?,
    errorCount: UInt64,
    lastErrorDescription: String?,
    status: TickRateStatus
  ) {
    self.mode = mode
    self.isRunning = isRunning
    self.isRealtimeScheduled = isRealtimeScheduled
    self.requestedTicksPerSecond = requestedTicksPerSecond
    self.executedTicks = executedTicks
    self.droppedTicks = droppedTicks
    self.manualTicks = manualTicks
    self.measurementSeconds = measurementSeconds
    self.achievedTicksPerSecond = achievedTicksPerSecond
    self.lateness = lateness
    self.peakAbsoluteLatenessNanoseconds = peakAbsoluteLatenessNanoseconds
    self.meanPropagationNanoseconds = meanPropagationNanoseconds
    self.maximumPropagationNanoseconds = maximumPropagationNanoseconds
    self.errorCount = errorCount
    self.lastErrorDescription = lastErrorDescription
    self.status = status
  }

  // MARK: - Derived

  /// Relative shortfall in `0...1`, or `nil` if the rate is not measurable.
  ///
  /// `0` means the target is met; `0.7` means the clock is running at 30% of the request.
  public var shortfallFraction: Double? {
    guard let achieved = achievedTicksPerSecond, requestedTicksPerSecond > 0 else { return nil }
    return max(0, 1 - achieved / requestedTicksPerSecond)
  }

  /// `true` only when we have measured the rate and it meets the request.
  ///
  /// Note it is `false` while `status == .measuring`. "We do not know yet" is not "yes".
  ///
  /// It can be `true` with `droppedTicks > 0`: an isolated OS hiccup that costs one tick in
  /// fifty thousand has not stopped the clock meeting its target. The drop is still reported
  /// in `droppedTicks` and printed by `summary`; see `TickStatistics.status` for why the
  /// verdict and the disclosure are separated.
  public var isMeetingTarget: Bool { status == .onSchedule }

  /// The Logisim convention: a *tick* is a clock half-cycle, so a circuit's clock frequency
  /// is half the tick rate (`TickCounter.java:120` divides by 2.0 for the same reason).
  public var achievedClockCyclesPerSecond: Double? {
    achievedTicksPerSecond.map { $0 / 2.0 }
  }

  /// The requested clock frequency in full cycles per second.
  public var requestedClockCyclesPerSecond: Double { requestedTicksPerSecond / 2.0 }

  // MARK: - Presentation

  /// Formats a frequency with three significant digits and a unit, mirroring the units
  /// upstream's label uses so the two are directly comparable.
  public static func formatFrequency(_ hertz: Double) -> String {
    guard hertz.isFinite, hertz > 0 else { return "0 Hz" }
    let (scaled, unit): (Double, String) =
      hertz >= 999_500 ? (hertz / 1_000_000, "MHz")
      : hertz >= 999.5 ? (hertz / 1000, "kHz")
      : (hertz, "Hz")
    let digits = scaled < 0.9995 ? 3 : scaled < 9.995 ? 2 : scaled < 99.95 ? 1 : 0
    return String(format: "%.\(digits)f %@", scaled, unit)
  }

  private static func formatDuration(_ nanoseconds: Double) -> String {
    let magnitude = abs(nanoseconds)
    if magnitude >= 1_000_000 { return String(format: "%.2f ms", nanoseconds / 1_000_000) }
    if magnitude >= 1000 { return String(format: "%.1f µs", nanoseconds / 1000) }
    return String(format: "%.0f ns", nanoseconds)
  }

  /// The achieved rate as a display string.
  ///
  /// Returns `"—"` when unmeasured. This getter is the one the UI binds to, and it is the
  /// single place where the "never print the request as if achieved" rule has to hold; it
  /// holds because there is no `requestedTicksPerSecond` anywhere in its body.
  public var achievedDescription: String {
    guard let achieved = achievedTicksPerSecond else { return "—" }
    return Self.formatFrequency(achieved)
  }

  /// A one-line, self-incriminating summary suitable for a status bar or a CLI footer.
  public var summary: String {
    switch status {
    case .idle:
      return "idle (requested \(Self.formatFrequency(requestedTicksPerSecond)))"

    case .measuring:
      return "measuring… (requested \(Self.formatFrequency(requestedTicksPerSecond)))"

    case .freeRunning:
      let rate = achievedTicksPerSecond.map(Self.formatFrequency) ?? "—"
      return "free-running at \(rate) (wall clock not tracked)"

    case .onSchedule:
      var text = "\(achievedDescription) (target \(Self.formatFrequency(requestedTicksPerSecond)))"
      if let lateness {
        text += ", jitter \(Self.formatDuration(lateness.jitterNanoseconds))"
        text += ", drift \(Self.formatDuration(lateness.driftNanoseconds))"
      }
      // Printed even while on schedule. A drop is a clock edge that never happened, so it is
      // reported whether or not it was material enough to move the verdict.
      if droppedTicks > 0 { text += ", \(Self.pluralTicks(droppedTicks)) dropped" }
      if !isRealtimeScheduled { text += " [timeshare]" }
      return text

    case .behindSchedule(let dropped):
      // Lead with the reason, not with a rate comparison that can read as "X of a requested
      // X (0% short)" when the shortfall is entirely in dropped ticks.
      var reasons: [String] = []
      if let shortfall = shortfallFraction, shortfall >= 0.005 {
        reasons.append(
          String(
            format: "%@ of a requested %@ (%.0f%% short)", achievedDescription,
            Self.formatFrequency(requestedTicksPerSecond), shortfall * 100))
      } else {
        reasons.append("target \(Self.formatFrequency(requestedTicksPerSecond))")
      }
      if dropped > 0 { reasons.append("\(Self.pluralTicks(dropped)) dropped") }
      if let propagation = meanPropagationNanoseconds {
        reasons.append("propagation \(Self.formatDuration(propagation))/tick")
      }
      var text = "BEHIND: " + reasons.joined(separator: ", ")
      if !isRealtimeScheduled { text += " [timeshare]" }
      return text
    }
  }

  private static func pluralTicks(_ count: UInt64) -> String {
    "\(count) tick\(count == 1 ? "" : "s")"
  }
}
