//
//  TickSchedule.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution).
//  logisim-evolution is free software released under the GNU GPLv3; this translation is
//  therefore GPL-3.0-only. See LICENSE.md.
//
//  ---------------------------------------------------------------------------------------
//  D7; the phase anchor itself. This is the whole behavioural fix, in one value type.
//
//  Upstream (`Simulator.java:433-476`) computes
//
//      deadline = lastTick + autoTickNanos - (long)((smooth - 1) * (avgTickNanos - autoTickNanos))
//
//  and assigns `lastTick = now` at `:516`, where `now` was read at the top of the loop pass
//  that *noticed* the deadline had passed; i.e. after the previous propagation returned. So
//  the origin of the schedule moves forward by (overshoot + propagation time) on every single
//  tick, and the error is absorbed permanently rather than corrected. The weighted-moving
//  average term that looks like a correction is multiplied by `(smooth - 1)`, and
//  `smoothingFactor` is 1 (`Simulator.java:143`), so it is algebraically zero in the shipped
//  configuration.
//
//  Here the schedule is a pure function of a FIXED ORIGIN and the tick index:
//
//      deadline(n) = origin + n * period
//
//  Nothing that happens during a tick can move `origin`, so nothing that happens during a
//  tick can shift the phase. Falling behind costs *dropped* ticks (counted and reported),
//  never a silently stretched period.
//
//  Arithmetic note. The period is held in mach ticks as a 128-bit Q64 fixed-point number:
//  the high 64 bits are whole mach ticks, the low 64 bits are the fraction. `deadline(n)`
//  multiplies rather than accumulates, so there is no round-off to accumulate in the first
//  place; the only error is the one-time representation error of the period, bounded by
//  2^-64 mach ticks (~2.3e-12 ns) per tick index. Working in mach ticks, not nanoseconds,
//  means the value handed to `mach_wait_until` needs no conversion, so no rounding is
//  introduced on exactly the quantity we are trying to keep exact.
//
//  D1: no Swift Concurrency. This is a plain `struct` with no reference semantics at all,
//  which is what makes the drift property testable without starting a thread.
//  ---------------------------------------------------------------------------------------
//

/// A phase-anchored tick schedule: `deadline(n) = origin + n * period`, in mach absolute time.
///
/// Deliberately immutable and side-effect free. Changing the rate produces a *new* schedule
/// with a new origin (a frequency change is a new phase, not a perturbation of the old one);
/// it is never a mutation of an existing one, so there is no code path by which a running
/// simulation can nudge its own origin.
public struct TickSchedule: Equatable, Sendable {

  // MARK: - Rate limits

  /// Slowest schedulable rate. Below this the period exceeds a couple of hours and the
  /// fixed-point period would start to lose meaningful resolution against `UInt64` mach time.
  public static let minimumTicksPerSecond: Double = 0.000_1

  /// Fastest schedulable rate: **derived from the hardware timebase, not chosen.**
  ///
  /// A deadline is a `UInt64` of mach ticks, so the shortest schedule that is still strictly
  /// increasing has a period of one mach tick: 41.66… ns on Apple Silicon, i.e. 24 MHz. A
  /// flat constant above that (the obvious `100_000_000`) produces a period that floors to
  /// **zero** whole mach ticks, at which point `deadline(n)` stops increasing and the whole
  /// phase-anchoring argument silently evaporates; the lattice collapses to a point and the
  /// clock free-runs while still claiming to be real-time-locked. Found by
  /// `nonsenseRatesClamp`, which asserts strict monotonicity at the clamp boundary.
  ///
  /// So the cap is `min(100 MHz, one tick per mach tick)`: 24 MHz on Apple Silicon, 100 MHz
  /// on a 1 ns timebase. Above it, `.freeRunning` is the honest answer; there is no wall
  /// clock left to lock to.
  public static let maximumTicksPerSecond: Double = min(
    100_000_000, 1_000_000_000.0 / MachClock.nanosecondsPerMachTick)

  // MARK: - Stored form

  /// The requested rate, in ticks per second.
  ///
  /// Note the Logisim convention, inherited from the Java: a *tick* is a clock half-cycle,
  /// so a circuit's full clock frequency is `ticksPerSecond / 2` (`TickCounter.java` divides
  /// by 2.0 for exactly this reason).
  public let ticksPerSecond: Double

  /// Mach absolute time of tick 0. Fixed for the life of the schedule.
  public let origin: UInt64

  /// The period, in mach ticks, as Q64 fixed point (whole ticks in the high 64 bits).
  public let periodQ64: UInt128

  // MARK: - Construction

  /// Builds a schedule anchored at `origin` running at (a clamped) `ticksPerSecond`.
  ///
  /// - Parameters:
  ///   - ticksPerSecond: requested rate; clamped into
  ///     `minimumTicksPerSecond ... maximumTicksPerSecond`. A non-finite or non-positive
  ///     rate clamps to the minimum rather than trapping; a bad preference value must not
  ///     be able to kill the process (D13).
  ///   - origin: mach absolute time of tick 0. Defaults to now.
  public init(ticksPerSecond requested: Double, origin: UInt64 = MachClock.now()) {
    let clamped: Double
    if requested.isNaN || requested <= 0 {
      // NaN and non-positive rates have no defensible interpretation, so they take the
      // slowest schedule rather than trapping (D13; a bad preference value must not be
      // able to kill the process). `+infinity` is *not* in this branch: it has an obvious
      // interpretation, "as fast as possible", and clamps to the maximum below.
      clamped = Self.minimumTicksPerSecond
    } else {
      clamped = min(max(requested, Self.minimumTicksPerSecond), Self.maximumTicksPerSecond)
    }
    self.ticksPerSecond = clamped
    self.origin = origin
    self.periodQ64 = Self.periodQ64(ticksPerSecond: clamped)
  }

  /// Designated memberwise form, used by `rebased(to:)` and by tests that need an exact,
  /// synthetic period rather than one derived from a frequency.
  public init(ticksPerSecond: Double, origin: UInt64, periodQ64: UInt128) {
    self.ticksPerSecond = ticksPerSecond
    self.origin = origin
    self.periodQ64 = max(periodQ64, 1)
  }

  /// The same rate, re-anchored to a new origin. Tick indices restart at 0.
  ///
  /// The only sanctioned way to move the phase. It is a separate, named operation precisely
  /// so that "the origin moved" is always a deliberate act visible at a call site, never a
  /// side effect of a slow propagation, which is the upstream defect this file exists to
  /// remove.
  public func rebased(to newOrigin: UInt64) -> TickSchedule {
    TickSchedule(ticksPerSecond: ticksPerSecond, origin: newOrigin, periodQ64: periodQ64)
  }

  private static func periodQ64(ticksPerSecond: Double) -> UInt128 {
    let periodNanoseconds = 1_000_000_000.0 / ticksPerSecond
    let periodMachTicks = periodNanoseconds * MachClock.machTicksPerNanosecond

    let whole = periodMachTicks.rounded(.down)
    // `whole` is bounded by the minimum rate (about 4e11 mach ticks), so this conversion
    // cannot overflow; the clamp is belt and braces against a future rate-limit change.
    let wholePart = UInt64(min(max(whole, 0), Double(UInt64.max / 2)))

    // 2^64 is not representable as a rounded Double product without risking a value that
    // converts out of range, so scale by 2^63 twice and clamp below the ceiling.
    let fractionValue = (periodMachTicks - whole) * 9_223_372_036_854_775_808.0 * 2.0
    let fractionPart = UInt64(min(max(fractionValue, 0), 18_446_744_073_709_549_568.0))

    let combined = (UInt128(wholePart) << 64) | UInt128(fractionPart)
    // Floor at one *whole* mach tick, not at one Q64 unit.
    //
    // `deadline(n)` truncates `n * period` to whole mach ticks, so a period with a zero
    // whole part gives `deadline(0) == deadline(1)` and the lattice degenerates. The rate
    // cap above already prevents it, but the invariant that matters, deadlines strictly
    // increase, must not depend on a separate constant staying in sync with the hardware
    // timebase. Guaranteeing it here makes it structural.
    return max(combined, UInt128(1) << 64)
  }

  // MARK: - Derived quantities

  /// Nominal period in nanoseconds.
  public var periodNanoseconds: Double {
    1_000_000_000.0 / ticksPerSecond
  }

  /// Nominal period in mach ticks, as a Double (for policy sizing and diagnostics only:
  /// never for computing a deadline).
  public var periodMachTicks: Double {
    Double(periodQ64 >> 64) + Double(UInt64(truncatingIfNeeded: periodQ64)) / 18_446_744_073_709_551_616.0
  }

  // MARK: - The schedule

  /// The mach absolute time at which tick `index` is due: `origin + index * period`.
  ///
  /// Computed from the fixed origin every time. There is no accumulator, so there is nothing
  /// for an overshoot to accumulate *into*, which is the entire difference from
  /// `Simulator.java`.
  ///
  /// Uses wrapping arithmetic: mach absolute time is a 64-bit counter and the multiply is
  /// 128-bit. At the slowest supported rate the product overflows only past ~7.7e11 ticks,
  /// which is over twenty thousand years of uptime.
  @inline(__always)
  public func deadline(_ index: UInt64) -> UInt64 {
    origin &+ UInt64(truncatingIfNeeded: (UInt128(index) &* periodQ64) >> 64)
  }

  /// The index of the tick whose deadline most recently fell at or before `machTime`.
  ///
  /// Exact: both this and `deadline(_:)` are floors of the same rational function, computed
  /// in 128-bit integer arithmetic, so `deadline(index(containing: t)) <= t` always holds.
  /// The correction loop guards against a boundary disagreement of one and is bounded; it
  /// is not a search.
  public func index(containing machTime: UInt64) -> UInt64 {
    guard machTime > origin else { return 0 }
    let elapsed = UInt128(machTime &- origin) << 64
    var candidate = UInt64(truncatingIfNeeded: elapsed / periodQ64)

    var guardCount = 0
    while candidate > 0, deadline(candidate) > machTime, guardCount < 4 {
      candidate &-= 1
      guardCount += 1
    }
    guardCount = 0
    while deadline(candidate &+ 1) <= machTime, guardCount < 4 {
      candidate &+= 1
      guardCount += 1
    }
    return candidate
  }

  /// The smallest tick index whose deadline is strictly after `machTime`.
  ///
  /// This is the catch-up primitive: when a propagation overruns, the clock asks for the next
  /// index that is still in the future and *drops* everything between. The dropped ticks are
  /// counted and reported; the phase is untouched.
  public func nextIndex(after machTime: UInt64) -> UInt64 {
    guard machTime >= origin else { return 0 }
    return index(containing: machTime) &+ 1
  }

  /// How far `machTime` is from tick `index`'s deadline, in nanoseconds. Negative means early.
  @inline(__always)
  public func latenessNanoseconds(of machTime: UInt64, forTick index: UInt64) -> Double {
    let due = deadline(index)
    let delta =
      machTime >= due
      ? Int64(bitPattern: machTime &- due)
      : -Int64(bitPattern: due &- machTime)
    return MachClock.nanoseconds(signedMachTicks: delta)
  }
}
