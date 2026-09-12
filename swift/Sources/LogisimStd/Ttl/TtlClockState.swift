// TtlClockState.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.ClockState),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Why `TtlClockState`, not `ClockState` ───────────────────────────────────────────────────
//
// Upstream has *two* classes named `ClockState`: `com.cburch.logisim.std.memory.ClockState`
// (ported at `Memory/ClockState.swift`, one clock bit) and this one,
// `com.cburch.logisim.std.ttl.ClockState`, which tracks up to 32 independent clock inputs
// addressed by an integer `which` (`Ttl7474`'s two flip-flops, `Ttl74670`'s per-write-address
// latch). Java's packages keep the two apart; Swift has one flat namespace per module, and
// `Memory/ClockState.swift` already claims the name. This is purely a naming necessity forced
// by the language, not a behavioural choice: see that file's own header for the identical
// composition-over-inheritance reasoning, which applies here unchanged.
//
// ── Deviations, all mechanical ──────────────────────────────────────────────────────────────
//
//   * `Cloneable`/`clone()` is gone. `TtlClockState` is a `struct`; every `InstanceData` that
//     wraps one gets value-semantics copying for free instead of overriding `cloneData()` by
//     hand.
//   * `Object trigger` becomes `AttributeOption?`, compared by value rather than upstream's
//     reference identity: see `Memory/ClockState.swift`'s header for why that reproduces every
//     upstream comparison exactly.
//   * Java's `newClock == null || newClock == Value.NIL` guard: the `null` half is unreachable
//     (`InstanceState.portValue` never returns a null `Value`), so only the `NIL` half is kept.
//   * `throws`: growing `lastClock` and writing bit `which` goes through `Value.set`, which
//     throws where Java's backing array cannot fail (D13). Every call site in this family passes
//     a small non-negative literal `which` and a width-1 `newClock`, so the throw is not expected
//     to fire in practice; it is propagated rather than force-unwrapped because D13 forbids
//     trapping on a hypothetical malformed input instead of surfacing it as a circuit error.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.ttl.ClockState`; one bit of "what was this clock input last
/// propagation?" per tracked index, for chips with more than one independent clock.
///
/// Shared by every `std/ttl` component whose `InstanceData` needs an edge: `TtlRegisterData`,
/// `ShiftRegisterData`, `UpDownCounterData`.
public struct TtlClockState {

  private var lastClock: Value = .falseValue

  public init() {}

  /// `updateClock(Value, int, Object)`. Records `newClock` as the new "last" value for index
  /// `which` unconditionally, then reports whether *this* transition is the edge (or level) the
  /// given trigger mode fires on. `trigger == nil` takes the same branch as
  /// `StdAttr.triggerRising`, matching upstream's `trigger == null` check.
  @discardableResult
  public mutating func updateClock(
    _ newClock: Value, which: Int = 0, trigger: AttributeOption? = nil
  ) throws -> Bool {
    if newClock == .nilValue { return false }
    if lastClock.width <= which {
      lastClock = lastClock.extendWidth(which + 1, .falseValue)
    }
    let oldClock = lastClock.get(which)
    lastClock = try lastClock.set(which, newClock)
    return Self.isTriggered(oldClock, newClock, trigger)
  }

  /// `isTriggered(Value, Value, Object)`. The `default` arm is dead in upstream (every
  /// `StdAttr.trigger` value is one of the four `TRIG_*` options); preserved only because the
  /// Java method has one.
  private static func isTriggered(
    _ oldClock: Value, _ newClock: Value, _ trigger: AttributeOption?
  ) -> Bool {
    switch trigger {
    case nil, StdAttr.triggerRising?:
      return oldClock == .falseValue && newClock == .trueValue
    case StdAttr.triggerFalling?:
      return oldClock == .trueValue && newClock == .falseValue
    case StdAttr.triggerHigh?:
      return newClock == .trueValue
    case StdAttr.triggerLow?:
      return newClock == .falseValue
    default:
      return oldClock == .falseValue && newClock == .trueValue
    }
  }
}
