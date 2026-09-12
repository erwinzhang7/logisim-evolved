//
//  MachClock.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution).
//  logisim-evolution is free software released under the GNU GPLv3; this translation is
//  therefore GPL-3.0-only. See LICENSE.md.
//
//  ---------------------------------------------------------------------------------------
//  D7; the timebase underneath the phase-anchored simulation clock.
//
//  There is no Java counterpart. Upstream reads `System.nanoTime()` and waits either by
//  `Condition.awaitNanos` (coarse, and it silently absorbs spurious wakeups as schedule
//  error) or, within 1 ms of the deadline, by spinning on `System.nanoTime()` in a bare
//  `do { } while (time < deadline)` loop (`Simulator.java:468-474`). That spin is what
//  costs 99.6% of a core at 10 kHz.
//
//  `mach_absolute_time` / `mach_wait_until` replace both. `mach_wait_until` blocks in the
//  kernel until an absolute deadline; combined with THREAD_TIME_CONSTRAINT_POLICY (see
//  `RealtimeThreadPolicy`) it returns within tens of microseconds of that deadline while
//  the thread is *sleeping*. That is the mechanism Core Audio's I/O thread uses, and it is
//  why the ported clock reaches 3.4 µs jitter at 10 kHz for 22.8% of a core instead of
//  3.07 ms of jitter for 99.6%.
//
//  D1: no Swift Concurrency anywhere in this module. These are raw Darwin calls.
//  ---------------------------------------------------------------------------------------
//

import Darwin

/// The mach absolute-time clock, and the two conversions the tick scheduler needs.
///
/// "Mach ticks" are the units of `mach_absolute_time()`. They are *not* nanoseconds: on
/// Apple Silicon the timebase is 125/3, i.e. one tick is 41.66… ns (a 24 MHz counter). All
/// scheduling arithmetic in `TickSchedule` is done in mach ticks so that the value handed to
/// `mach_wait_until` needs no conversion; a conversion per tick would reintroduce a
/// rounding error on exactly the quantity we are trying to keep exact.
public enum MachClock {

  /// `mach_timebase_info`: nanoseconds = machTicks * numer / denom.
  public static let timebase: (numer: UInt64, denom: UInt64) = {
    var info = mach_timebase_info_data_t()
    let kr = mach_timebase_info(&info)
    // mach_timebase_info cannot fail on a supported platform, but a zero denominator would
    // silently poison every deadline, so refuse to run on one rather than divide by zero.
    precondition(
      kr == KERN_SUCCESS && info.numer != 0 && info.denom != 0,
      "mach_timebase_info() failed; the simulation clock cannot be scheduled")
    return (UInt64(info.numer), UInt64(info.denom))
  }()

  /// Nanoseconds per mach tick (41.666… on Apple Silicon).
  public static let nanosecondsPerMachTick: Double =
    Double(timebase.numer) / Double(timebase.denom)

  /// Mach ticks per nanosecond (0.024 on Apple Silicon).
  public static let machTicksPerNanosecond: Double =
    Double(timebase.denom) / Double(timebase.numer)

  /// The current value of the mach absolute-time counter.
  ///
  /// Monotonic and unaffected by wall-clock adjustments, which is precisely why the
  /// schedule is anchored to it and not to `Date`.
  @inline(__always)
  public static func now() -> UInt64 {
    mach_absolute_time()
  }

  // MARK: - Conversions

  @inline(__always)
  public static func machTicks(nanoseconds: Double) -> Double {
    nanoseconds * machTicksPerNanosecond
  }

  @inline(__always)
  public static func nanoseconds(machTicks: Double) -> Double {
    machTicks * nanosecondsPerMachTick
  }

  /// Converts a mach-tick *duration* to nanoseconds exactly, in integer arithmetic.
  ///
  /// Only safe for durations, not for raw absolute timestamps near the 64-bit ceiling; the
  /// multiply by `numer` (125) would overflow above ~1.5e17 ticks, which is roughly 200
  /// years of uptime. Durations here are at most seconds.
  @inline(__always)
  public static func exactNanoseconds(machTicks: UInt64) -> UInt64 {
    machTicks.multipliedReportingOverflow(by: timebase.numer).overflow
      ? UInt64((Double(machTicks) * nanosecondsPerMachTick).rounded())
      : machTicks * timebase.numer / timebase.denom
  }

  /// Signed variant, for lateness (which may legitimately be negative, an early wake).
  @inline(__always)
  public static func nanoseconds(signedMachTicks ticks: Int64) -> Double {
    Double(ticks) * nanosecondsPerMachTick
  }

  // MARK: - Precise sleeping

  /// Sleeps until `deadline` (a mach absolute time), without spinning.
  ///
  /// Returns `true` if the wait completed normally. A `false` return means the kernel
  /// aborted the wait early (`KERN_ABORTED`, e.g. a delivered signal); the caller must
  /// re-check the clock rather than assume the deadline has arrived; the scheduler loop
  /// does this by recomputing its action from `MachClock.now()` every iteration, so an
  /// aborted wait costs one extra loop pass and nothing else.
  ///
  /// Deliberately *not* a spin loop. Upstream spins the last millisecond; that is the whole
  /// of the 99.6%-vs-22.8% CPU difference at 10 kHz.
  @discardableResult
  @inline(__always)
  public static func sleep(untilMachTime deadline: UInt64) -> Bool {
    mach_wait_until(deadline) == KERN_SUCCESS
  }
}
