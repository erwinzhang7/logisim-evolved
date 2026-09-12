// UpDownCounterData.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.UpDownCounterData),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// The 4-bit up/down counter state shared by `Ttl74161`/`Ttl74163` (single-clock BCD/binary
// counters) and `Ttl74192`/`Ttl74193` (dual up/down-clock nibble counters). Every field is
// exactly upstream's: `value` is the current count, `carry`/`borrow` are the *registered*
// terminal-count outputs (they hold their previous value outside the edges that update them:
// see the `else` branch of every caller's `propagateTtl`), and `downPrev`/`upPrev` are last
// propagation's up/down inputs, used to detect edges without a `TtlClockState` (74192/193 need
// independent rising/falling detection on *two* clock-like inputs, which upstream hand-rolls
// here rather than reusing `ClockState.updateClock`).
//
// **Deviation (mechanism).** Java: `extends ClockState implements InstanceData`; composition
// (`clock: TtlClockState`) replaces inheritance; see `TtlClockState.swift`'s header. Note
// `clock` is unused by `Ttl74192`/`Ttl74193` (they track edges via `downPrev`/`upPrev` instead,
// exactly as upstream) but *is* used by `Ttl74161`/`Ttl74163`, which is why it is carried here
// rather than split out. `AppPreferences.Memory_Startup_Unknown` (default `false`) is hardcoded
// to its compiled default; see `TtlRegisterData.swift`'s header for the same call in this file
// set.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.ttl.UpDownCounterData`.
final class UpDownCounterData: InstanceData {
  static let width = BitWidth.known(4)

  var clock = TtlClockState()
  private(set) var value: Value
  private(set) var carry: Value
  private(set) var borrow: Value
  private(set) var downPrev: Value
  private(set) var upPrev: Value

  init() {
    value = Value.createKnown(UpDownCounterData.width, 0)
    downPrev = .falseValue
    upPrev = .falseValue
    carry = .trueValue
    borrow = .trueValue
  }

  /// `setAll(Value, Value, Value, Value, Value)`.
  func setAll(value: Value, carry: Value, borrow: Value, down: Value, up: Value) {
    self.value = value
    self.carry = carry
    self.borrow = borrow
    downPrev = down
    upPrev = up
  }

  func cloneData() -> any InstanceData {
    let copy = UpDownCounterData()
    copy.value = value
    copy.carry = carry
    copy.borrow = borrow
    copy.downPrev = downPrev
    copy.upPrev = upPrev
    copy.clock = clock
    return copy
  }
}
