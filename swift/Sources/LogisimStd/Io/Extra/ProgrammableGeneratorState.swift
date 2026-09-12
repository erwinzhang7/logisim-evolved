// ProgrammableGeneratorState.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.io.extra.ProgrammableGeneratorState),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// A per-state (high-duration, low-duration) pair driving a square wave through `currentState`
// ticks of `ticks`. See `ProgrammableGenerator.swift`'s header for why nothing can currently
// place or edit one of these.
//
// ── What did not come across ─────────────────────────────────────────────────────────────────
//
//   * `editWindow()` / the `JTextField[]`/`GridBagLayout` editor and `saveValues(JTextField[])`,
//     which only `editWindow()` calls, Swing UI, M6+.

import Foundation
import LogisimKernel

/// D13, mirroring `PlaRomContentsError` for this component's own `Contents` attribute. Kept as a
/// separate type rather than shared, because the two are surfaced with different component names
/// and a caller catching one should not silently swallow the other.
public enum ProgrammableGeneratorContentsError: Error, CustomStringConvertible, Equatable, Sendable
{
  /// `Integer.parseInt` on a token that is not a 32-bit decimal integer.
  case notANumber(String)
  /// A token containing `*` whose `split("\\*")` has no element at index 1, `"1*"`, `"*"`.
  case missingRepeatCount(String)

  public var description: String {
    switch self {
    case .notANumber(let token):
      return "programmable generator contents: for input string: \"\(token)\""
    case .missingRepeatCount(let token):
      return "programmable generator contents: repeat token \"\(token)\" has no count after '*'"
    }
  }
}

/// `com.cburch.logisim.std.io.extra.ProgrammableGeneratorState`.
public final class ProgrammableGeneratorState: InstanceData {
  /// `ProgrammableGeneratorState.sending`; package-visible field upstream (`Poker`/`tick`
  /// read it directly); mirrored here without an accessor wrapper for the same reason.
  public var sending: Value = .falseValue

  private var durationHigh: [Int]
  private var durationLow: [Int]
  private(set) var savedData = ""
  private var ticks = 0
  private var currentState = 0

  public init(stateCount: Int) {
    durationHigh = Array(repeating: 1, count: stateCount)
    durationLow = Array(repeating: 1, count: stateCount)
  }

  private init(
    durationHigh: [Int], durationLow: [Int], savedData: String, ticks: Int, currentState: Int,
    sending: Value
  ) {
    self.durationHigh = durationHigh
    self.durationLow = durationLow
    self.savedData = savedData
    self.ticks = ticks
    self.currentState = currentState
    self.sending = sending
  }

  public func cloneData() -> any InstanceData {
    ProgrammableGeneratorState(
      durationHigh: durationHigh, durationLow: durationLow, savedData: savedData, ticks: ticks,
      currentState: currentState, sending: sending)
  }

  /// `ProgrammableGeneratorState.clearValues()`.
  public func clearValues() {
    ticks = 0
    currentState = 0
    for i in 0..<durationHigh.count {
      durationHigh[i] = 1
      durationLow[i] = 1
    }
    savedData = ""
  }

  /// `ProgrammableGeneratorState.getdurationHighValue()`.
  public func durationHighValue() -> Int { durationHigh[currentState] }
  /// `ProgrammableGeneratorState.getdurationLowValue()`.
  public func durationLowValue() -> Int { durationLow[currentState] }
  /// `ProgrammableGeneratorState.getStateTick()`.
  public func stateTick() -> Int { ticks }
  public func getSavedData() -> String { savedData }

  /// `ProgrammableGeneratorState.incrementCurrentState()`.
  public func incrementCurrentState() {
    ticks = 1
    currentState += 1
    if currentState >= durationHigh.count { currentState = 0 }
  }

  /// `ProgrammableGeneratorState.incrementTicks()`.
  public func incrementTicks() {
    ticks += 1
    if ticks > durationHighValue() + durationLowValue() { incrementCurrentState() }
  }

  /// `ProgrammableGeneratorState.setdurationHigh(int, int)`.
  public func setDurationHigh(_ i: Int, _ value: Int) {
    if value != durationHigh[i] { durationHigh[i] = value }
  }
  /// `ProgrammableGeneratorState.setdurationLow(int, int)`.
  public func setDurationLow(_ i: Int, _ value: Int) {
    if value != durationLow[i] { durationLow[i] = value }
  }

  /// `ProgrammableGeneratorState.updateSize(int)`.
  @discardableResult
  public func updateSize(_ newSize: Int) -> Bool {
    guard newSize != durationHigh.count else { return false }
    let oldHigh = durationHigh
    let oldLow = durationLow
    durationHigh = Array(repeating: 1, count: newSize)
    durationLow = Array(repeating: 1, count: newSize)
    clearValues()
    let lower = min(oldHigh.count, newSize)
    for i in 0..<lower {
      durationHigh[i] = oldHigh[i]
      durationLow[i] = oldLow[i]
    }
    saveData()
    return true
  }

  /// `ProgrammableGeneratorState.decodeSavedData(String)`.
  ///
  /// D13, and the same defect PlaRomData's twin had, from the same origin: see that file's
  /// commentary for the full accounting of `"1*-1"` (a trap on `0..<(-1)` where Java simply does
  /// not enter the loop), `"1*"` and non-numeric tokens. The one difference from `PlaRomData` is
  /// that upstream's local here is an `int`, not a `byte`: there is no narrowing cast, so `"256"`
  /// is a duration of 256 and stays one. Reproduced by keeping `writeData`'s parameter `Int`.
  public func decodeSavedData(_ text: String?) throws {
    guard let text, !text.isEmpty else { return }
    var index = 0
    for token in javaSplitOnLiteral(text, separator: " ") {
      if token.contains("*") {
        let parts = javaSplitOnLiteral(token, separator: "*")
        guard parts.count > 1 else {
          throw ProgrammableGeneratorContentsError.missingRepeatCount(token)
        }
        // `Integer.parseInt(tmp[1])` lives in the `for` condition upstream, so the count is
        // parsed before the value ever is; `"*0"` runs zero iterations and never throws on the
        // empty value, `"*5"` throws on it.
        guard let repeats = javaParseInt32(parts[1]) else {
          throw ProgrammableGeneratorContentsError.notANumber(parts[1])
        }
        var j = 0
        while j < repeats {
          guard let value = javaParseInt32(parts[0]) else {
            throw ProgrammableGeneratorContentsError.notANumber(parts[0])
          }
          writeData(value, at: index)
          index += 1
          j += 1
        }
      } else {
        guard let value = javaParseInt32(token) else {
          throw ProgrammableGeneratorContentsError.notANumber(token)
        }
        writeData(value, at: index)
        index += 1
      }
    }
  }

  /// `ProgrammableGeneratorState.writeData(int, int)`.
  private func writeData(_ value: Int, at cnt: Int) {
    if cnt < durationHigh.count {
      setDurationHigh(cnt, value)
    } else if cnt < durationHigh.count + durationLow.count {
      setDurationLow(cnt - durationHigh.count, value)
    }
  }

  /// `ProgrammableGeneratorState.saveData()`: same run-length-encoding shape as
  /// `PlaRomData.saveData()`, but the "is anything non-default" test is `val != "1"` here
  /// (durations default to `1`) instead of `val != "0"`.
  public func saveData() {
    let size = durationHigh.count * 2
    var data = ""
    var last = "x"
    var count = 0
    var dirty = false
    for i in 0..<size {
      let val = i < durationHigh.count ? String(durationHigh[i]) : String(durationLow[i - durationHigh.count])
      if !dirty && val != "1" { dirty = true }
      if val == last {
        count += 1
      } else if last == "x" {
        last = val
        count += 1
      }
      if val != last || i == size - 1 {
        if count >= 3 {
          data += "\(last)*\(count) "
        } else {
          for _ in 0..<count { data += "\(last) " }
        }
        if val != last && i == size - 1 {
          data += "\(val) "
        }
        count = 1
        last = val
      }
    }
    savedData = dirty ? data : ""
  }
}
