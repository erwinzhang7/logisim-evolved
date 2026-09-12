// ShiftRegisterData.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.ShiftRegisterData),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Why `TtlShiftRegisterData`, not `ShiftRegisterData` ─────────────────────────────────────
//
// Upstream has *two* classes named `ShiftRegisterData`:
// `com.cburch.logisim.std.memory.ShiftRegisterData` (ported at `Memory/ShiftRegister.swift`)
// and this one: separate implementations backing separate component families, kept apart by
// Java's packages. Swift has one flat namespace per module, and the memory-module file already
// claims the bare name, so this one is prefixed, exactly as `TtlClockState.swift` documents for
// the same collision. This one backs `Ttl74164`, `Ttl74165`, `Ttl74166`, `Ttl74194` and
// `Ttl74299`. Kept `internal` (the Swift default) rather than `public`, matching the memory
// module's file; nothing outside this module needs it.
//
// ── `pushDown` vs `pushUp`: both directions, unlike the memory version ─────────────────────
//
// Upstream's memory-module `ShiftRegister` only ever shifts one way, so its port only needed
// `push`. This chip family includes `Ttl74194` (bidirectional), so both of upstream's
// `pushDown` (insert at the top index, drop toward zero) and `pushUp` (insert at zero, drop
// toward the top) are ported.
//
// **Deviation (mechanism).** Java: `extends ClockState implements InstanceData`; composition
// (`clock: TtlClockState`) replaces inheritance; see `TtlClockState.swift`'s header.
// `AppPreferences.Memory_Startup_Unknown` (default `false`) is hardcoded to its compiled
// default; see `TtlRegisterData.swift`'s header for the same call in this file set.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.ttl.ShiftRegisterData`.
final class TtlShiftRegisterData: InstanceData {
  var clock = TtlClockState()
  private var width: BitWidth
  private var values: [Value]
  /// `vsPos`: the circular buffer's write cursor.
  private var pos: Int = 0

  init(width: BitWidth, length: Int) {
    self.width = width
    values = [Value](repeating: Value.createKnown(width, 0), count: length)
  }

  /// `clear()`.
  func clear() {
    values = [Value](repeating: Value.createKnown(width, 0), count: values.count)
    pos = 0
  }

  /// `getLength()`.
  var length: Int { values.count }

  /// `toInternalIndex(int)`.
  private func toInternalIndex(_ index: Int) -> Int {
    (pos + index) % values.count
  }

  /// `get(int)`.
  func get(_ index: Int) -> Value {
    values[toInternalIndex(index)]
  }

  /// `pushDown(Value)`: push the contents of the register towards the zero index and insert
  /// the new value at the top index.
  func pushDown(_ v: Value) {
    values[pos] = v
    pos = toInternalIndex(1)
  }

  /// `pushUp(Value)`: push the contents of the register towards the top index and insert the
  /// new value at the zero index.
  func pushUp(_ v: Value) {
    pos = toInternalIndex(values.count - 1)
    values[pos] = v
  }

  /// `set(int, Value)`.
  func set(_ index: Int, _ val: Value) {
    values[toInternalIndex(index)] = val
  }

  /// `setDimensions(BitWidth, int)`.
  func setDimensions(width newWidth: BitWidth, length newLength: Int) {
    if values.count != newLength {
      var newValues = [Value](repeating: Value.createKnown(newWidth, 0), count: newLength)
      var j = pos
      let copyCount = min(newLength, values.count)
      for i in 0..<copyCount {
        newValues[i] = values[j]
        j += 1
        if j == values.count { j = 0 }
      }
      values = newValues
      pos = 0
    }
    if width.width != newWidth.width {
      for i in values.indices where values[i].width != newWidth.width {
        values[i] = values[i].extendWidth(newWidth.width, .falseValue)
      }
      width = newWidth
    }
  }

  func cloneData() -> any InstanceData {
    let copy = TtlShiftRegisterData(width: width, length: values.count)
    copy.values = values
    copy.pos = pos
    copy.clock = clock
    return copy
  }
}
