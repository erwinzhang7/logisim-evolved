// JavaBits.swift: part of logisim-evolved.
//
// Part of the logisim-evolution port (GPL-3.0-only, see LICENSE.md).
//
// Java and Swift disagree about shifts, and the disagreement is silent. These helpers exist so
// that a component transcribing `1L << n` or `1 << index` gets Java's answer, including where
// Java's answer is a bug that upstream depends on.
//
//   * Java masks the shift distance: `x << n` uses `n & 31` for `int` and `n & 63` for `long`.
//     Swift's `<<` on a fixed-width integer is a *smart shift*: over-shifting yields 0.
//     `1L << 64` is 1 in Java and 0 in Swift.
//   * Java's integer arithmetic wraps. Swift's `+` traps. Use `&+` when transcribing.
//
// Both differences are live in the exemplars: `GateAttributes.setValue` shifts by a value that
// can be 64, and `Adder.computeSum` adds two `long`s that can overflow.

import Foundation

/// Java `1L << (n & 63)`: a single-bit `long` mask.
@inline(__always)
public func javaLongBit(_ n: Int) -> Int64 {
  (1 as Int64) << Int64(n & 63)
}

/// Java `1 << (n & 31)`, evaluated as an `int` and then widened to `long`.
///
/// The widening is the whole point: `1 << 31` is `Integer.MIN_VALUE`, so widening gives
/// `0xFFFF_FFFF_8000_0000`, not `0x0000_0000_8000_0000`. Upstream's `GateAttributes` sets and
/// clears bits of a `long` field with `int` shifts and hits exactly this.
@inline(__always)
public func javaIntBitWidened(_ n: Int) -> Int64 {
  Int64(Int32(1) << Int32(n & 31))
}

/// Java `1 << (n & 31)` kept as an `int`: the plain single-bit `int` mask, no widening.
///
/// This is the form to use when the Java expression's static type is `int` and the result is
/// consumed as a count or a size (`final var inputs = 1 << select.getWidth()`), rather than
/// OR-ed into a `long` field. `javaIntBitWidened` sign-extends, which is right for the `long`
/// case and wrong here.
///
/// The difference from Swift's own `<<` only appears at `n >= 32`, where Java wraps the
/// distance and Swift saturates to 0; `1 << 32` is `1` in Java and `0` in Swift. Measured
/// against the 4.1.0 jar by `OffsetBoundsOracleTests`: the four plexers' `getOffsetBounds` all
/// diverge at `select` width 32, and every one of them is this shift.
@inline(__always)
public func javaIntBit(_ n: Int) -> Int {
  Int(Int32(1) << Int32(n & 31))
}

/// Java `~(1 << (n & 31))` evaluated as an `int` and then widened to `long`.
///
/// For `n = 31` this is `0x0000_0000_7FFF_FFFF`, i.e. it clears every bit above 30 as well as
/// bit 31: an upstream bug that this port preserves rather than "fixes".
@inline(__always)
public func javaIntBitComplementWidened(_ n: Int) -> Int64 {
  Int64(~(Int32(1) << Int32(n & 31)))
}

/// Java `(int) (value >> (n & 63)) & 1`: arithmetic right shift of a `long`, low bit.
@inline(__always)
public func javaLongBitAt(_ value: Int64, _ n: Int) -> Int {
  Int((value >> Int64(n & 63)) & 1)
}
