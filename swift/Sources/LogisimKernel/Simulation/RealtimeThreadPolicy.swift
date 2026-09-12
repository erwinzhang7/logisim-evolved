//
//  RealtimeThreadPolicy.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution).
//  GPL-3.0-only. See LICENSE.md.
//
//  ---------------------------------------------------------------------------------------
//  D7; the scheduling half of "sub-100 µs jitter while sleeping".
//
//  `mach_wait_until` alone gets you a kernel-blocked wait, but a timeshare-scheduled thread
//  is not guaranteed to be *dispatched* promptly when that wait expires; under load it can
//  sit runnable for milliseconds. THREAD_TIME_CONSTRAINT_POLICY moves the thread onto the
//  realtime run queue, where the deadline is honoured. This is the documented mechanism
//  behind Core Audio's I/O thread and it is what makes a *sleeping* wait as accurate as
//  upstream's busy-spin, at 1/4 the CPU.
//
//  Upstream has no equivalent; the JVM cannot set it, which is why `Simulator` had to spin
//  to get anywhere near its deadline.
//  ---------------------------------------------------------------------------------------
//

import Darwin

/// A `THREAD_TIME_CONSTRAINT_POLICY` declaration, in nanoseconds.
///
/// The contract you make with the kernel is: "every `period`, I need `computation` ns of
/// CPU, and it must be finished within `constraint` ns of the period starting." Ask for
/// too much and the kernel refuses (or, worse, is granted and starves the UI); ask for a
/// period of several seconds and the declaration stops meaning anything useful. So
/// `forTickPeriod` clamps into a range that is grantable and still buys realtime dispatch.
public struct RealtimeThreadPolicy: Equatable, Sendable {

  /// Nominal wake interval declared to the kernel.
  public var periodNanoseconds: Double
  /// CPU time needed per period.
  public var computationNanoseconds: Double
  /// Deadline for that computation, measured from the start of the period.
  public var constraintNanoseconds: Double
  /// `true` lets the kernel preempt us. We are not hard-realtime, a late tick is a
  /// reported statistic, not a click in someone's headphones, so we stay preemptible and
  /// remain a good citizen on a machine that is also drawing a UI.
  public var isPreemptible: Bool

  /// The declared period is clamped into this range. Below ~0.5 ms the declaration starts
  /// to look like an audio thread and costs more in scheduling overhead than it returns;
  /// above ~50 ms it no longer describes a latency the kernel can act on.
  public static let minimumPeriodNanoseconds: Double = 500_000  // 0.5 ms
  public static let maximumPeriodNanoseconds: Double = 50_000_000  // 50 ms

  /// The fraction of a period we are willing to claim as computation. Claiming a large
  /// fraction of a short period is how you get a grant that starves everything else.
  public static let maximumDutyCycle: Double = 0.25

  public init(
    periodNanoseconds: Double,
    computationNanoseconds: Double,
    constraintNanoseconds: Double,
    isPreemptible: Bool = true
  ) {
    self.periodNanoseconds = periodNanoseconds
    self.computationNanoseconds = computationNanoseconds
    self.constraintNanoseconds = constraintNanoseconds
    self.isPreemptible = isPreemptible
  }

  /// Builds a grantable declaration for a tick period.
  ///
  /// - Parameters:
  ///   - tickPeriodNanoseconds: the simulation tick period. At 1 Hz this is 1 s, far past
  ///     anything worth declaring, so it clamps to `maximumPeriodNanoseconds`: we still
  ///     want realtime dispatch, we just describe it at a granularity the kernel can use.
  ///   - expectedWorkNanoseconds: measured (or estimated) propagation cost per tick.
  public static func forTickPeriod(
    _ tickPeriodNanoseconds: Double,
    expectedWorkNanoseconds: Double
  ) -> RealtimeThreadPolicy {
    let period = min(
      max(tickPeriodNanoseconds, minimumPeriodNanoseconds), maximumPeriodNanoseconds)
    // Claim what we actually expect to use, floored so the declaration is not degenerate
    // and capped so we never ask for a quarter of the machine at a short period.
    let work = max(expectedWorkNanoseconds, 50_000)  // 50 µs floor
    let computation = min(work, period * maximumDutyCycle)
    return RealtimeThreadPolicy(
      periodNanoseconds: period,
      computationNanoseconds: computation,
      // Allow the whole period to hit the deadline: we care that the *wake* is prompt, not
      // that the work finishes in a tight sub-window of it.
      constraintNanoseconds: period,
      isPreemptible: true)
  }

  // MARK: - Application

  /// Promotes the calling thread to the realtime band.
  ///
  /// Returns `false` if the kernel declined. That is not fatal and must not be treated as
  /// one: the clock still runs, `mach_wait_until` still sleeps rather than spins, and the
  /// only consequence is worse jitter under load. The failure is surfaced in
  /// `TickRateReport.isRealtimeScheduled` so the readout stays honest about it rather than
  /// quietly reporting numbers it is no longer entitled to.
  @discardableResult
  public func applyToCurrentThread() -> Bool {
    let toMach = MachClock.machTicksPerNanosecond
    var policy = thread_time_constraint_policy(
      period: UInt32(clamping: Int(periodNanoseconds * toMach)),
      computation: UInt32(clamping: Int(computationNanoseconds * toMach)),
      constraint: UInt32(clamping: Int(constraintNanoseconds * toMach)),
      preemptible: isPreemptible ? 1 : 0)

    let count = mach_msg_type_number_t(
      MemoryLayout<thread_time_constraint_policy>.size / MemoryLayout<integer_t>.size)

    let result = withUnsafeMutablePointer(to: &policy) { pointer -> kern_return_t in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
        thread_policy_set(
          pthread_mach_thread_np(pthread_self()),
          thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY),
          raw,
          count)
      }
    }
    return result == KERN_SUCCESS
  }

  /// Returns the calling thread to the default timeshare band.
  ///
  /// Used when the clock switches to free-running: free-running has no wall-clock deadline
  /// to meet, so holding a realtime declaration while burning 100% of a core is exactly the
  /// antisocial behaviour the policy exists to ration.
  @discardableResult
  public static func resignOnCurrentThread() -> Bool {
    // `timeshare: 1` is the documented way back to the ordinary timeshare band; setting
    // THREAD_EXTENDED_POLICY supersedes the time-constraint declaration.
    var policy = thread_extended_policy(timeshare: 1)
    let count = mach_msg_type_number_t(
      MemoryLayout<thread_extended_policy>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &policy) { pointer -> kern_return_t in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
        thread_policy_set(
          pthread_mach_thread_np(pthread_self()),
          thread_policy_flavor_t(THREAD_EXTENDED_POLICY),
          raw,
          count)
      }
    }
    return result == KERN_SUCCESS
  }
}
