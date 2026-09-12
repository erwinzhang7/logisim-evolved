// TtlRegisterData.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.TtlRegisterData),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// A small fixed-size register bank: `depth` independent words, each `width` bits, plus the
// clock-edge tracking every one of its users (`AbstractOctalFlops`, `Ttl74161`/`Ttl74163`,
// `Ttl7474`, `Ttl74175`, `Ttl74670`) needs. `depth` defaults to 1: most chips hold a single
// word and use `getValue()`/`setValue(_:)`, matching upstream's `getValue()`/`setValue(Value)`
// overloads that forward to index 0.
//
// **Deviation (mechanism).** Java: `extends ClockState implements InstanceData`; composition
// (`clock: TtlClockState`) replaces inheritance, exactly as `Memory/ClockState.swift` and
// `TtlClockState.swift` document. `AppPreferences.Memory_Startup_Unknown` (default `false`) is
// hardcoded to its compiled default rather than read from a preferences store: see
// `Memory/AbstractFlipFlop.swift`'s header for the same call across the sibling module.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.ttl.TtlRegisterData`.
final class TtlRegisterData: InstanceData {
  var clock = TtlClockState()
  private var values: [Value]
  private let bits: BitWidth

  /// `TtlRegisterData(BitWidth, int)`.
  init(width: BitWidth, depth: Int = 1) {
    bits = width
    values = [Value](repeating: Value.createKnown(width, 0), count: depth)
  }

  /// `setValue(int, Value)`.
  func setValue(_ index: Int, _ value: Value) {
    values[index] = value
  }

  /// `setValue(Value)`.
  func setValue(_ value: Value) {
    setValue(0, value)
  }

  /// `getValue(int)`.
  func getValue(_ index: Int) -> Value {
    values[index]
  }

  /// `getValue()`.
  func getValue() -> Value {
    getValue(0)
  }

  /// `getWidth()`.
  var width: BitWidth { bits }

  func cloneData() -> any InstanceData {
    let copy = TtlRegisterData(width: bits, depth: values.count)
    copy.values = values
    copy.clock = clock
    return copy
  }
}
