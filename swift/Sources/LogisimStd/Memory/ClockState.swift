// ClockState.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.memory.ClockState),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Deviations, all mechanical ──────────────────────────────────────────────────────────────
//
//   * `Cloneable`/`clone()` is gone. `ClockState` is a `struct`; every `InstanceData` that wraps
//     one gets value-semantics copying for free instead of overriding `cloneData()` by hand.
//   * `Object trigger` becomes `AttributeOption?`. Upstream compares by reference identity
//     against the four `StdAttr.TRIG_*` singletons and treats `null` as "rising" (the default
//     trigger a component gets before its attribute set answers `StdAttr.TRIGGER`); the port
//     compares by value (D5's precedent: `AttributeOption` is a value type, and two components'
//     trigger attributes can never cross-contaminate, so structural equality reproduces every
//     upstream comparison exactly).

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.memory.ClockState`; the one bit of history a component needs to
/// turn a continuous `Value` into an edge: "what was the clock input last propagation?"
///
/// Shared by every `std/memory` component with a `StdAttr.trigger` attribute (`Register`,
/// `Counter`, `ShiftRegister`, `Ram`'s synchronous mode, the flip-flops via `AbstractFlipFlop`).
public struct ClockState {

  private var lastClock: Value = .falseValue

  public init() {}

  /// `updateClock(Value, Object)`.
  ///
  /// Records `newClock` as the new "last" value unconditionally; exactly as upstream does
  /// before it even looks at `trigger`; then reports whether *this* transition is the edge
  /// (or level) the given trigger mode fires on.
  ///
  /// `trigger == nil` takes the same branch as `StdAttr.triggerRising`, matching upstream's
  /// `trigger == null` check. The `default` arm is dead in upstream (every `StdAttr.trigger`
  /// value is one of the four `TRIG_*` options) and is preserved only because the Java method
  /// has one; reaching it here would mean a caller passed an `AttributeOption` that is not a
  /// trigger option at all, which no `.circ` file can produce.
  public mutating func updateClock(_ newClock: Value, trigger: AttributeOption?) -> Bool {
    let oldClock = lastClock
    lastClock = newClock

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
