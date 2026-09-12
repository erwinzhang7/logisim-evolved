// DiagramState.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.io.extra.DiagramState),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// The scrolling logic-analyzer buffer behind `DigitalOscilloscope`: one `Bool?` cell per
// (input, time-slot) pair, `nil` meaning "never sampled" (upstream's `Boolean` `null`), matching
// the two-input-vs-one-clock offset (`i + (showclock == 0 ? 1 : 0)`) `DigitalOscilloscope`
// applies when indexing this. `internal`, not `public`; this is `DigitalOscilloscope`'s private
// scratch state, exactly as upstream's package-private `class DiagramState`.

import Foundation
import LogisimKernel

/// `com.cburch.logisim.std.io.extra.DiagramState`.
final class DiagramState: InstanceData {
  /// `DiagramState.usedcell`; `-1` means "nothing sampled yet".
  private(set) var usedCell: Int = -1
  private var lastClock: Value = .unknownValue
  private(set) var moveBack = false
  /// `DiagramState.diagram`, `diagram[input][timeSlot]`.
  private var diagram: [[Bool?]]
  private(set) var inputs: Int
  private(set) var length: Int
  private(set) var clockNumber: Int

  init(inputs: Int, length: Int) {
    self.inputs = inputs
    self.length = length
    self.diagram = Array(repeating: Array(repeating: nil, count: length), count: inputs)
    self.clockNumber = length / 2
  }

  private init(
    usedCell: Int, lastClock: Value, moveBack: Bool, diagram: [[Bool?]], inputs: Int, length: Int,
    clockNumber: Int
  ) {
    self.usedCell = usedCell
    self.lastClock = lastClock
    self.moveBack = moveBack
    self.diagram = diagram
    self.inputs = inputs
    self.length = length
    self.clockNumber = clockNumber
  }

  /// `DiagramState.clear()`.
  func clear() {
    for i in 0..<inputs {
      for j in 0..<length { diagram[i][j] = nil }
    }
    moveBack = false
  }

  func cloneData() -> any InstanceData {
    DiagramState(
      usedCell: usedCell, lastClock: lastClock, moveBack: moveBack, diagram: diagram,
      inputs: inputs, length: length, clockNumber: clockNumber)
  }

  /// `DiagramState.getState(int, int)`.
  func state(_ i: Int, _ j: Int) -> Bool? { diagram[i][j] }

  /// `DiagramState.setState(byte, byte, Boolean)`.
  func setState(_ i: Int, _ j: Int, _ value: Bool?) { diagram[i][j] = value }

  /// `DiagramState.hastomoveback(boolean)`.
  func setMoveBack(_ value: Bool) { moveBack = value }

  /// `DiagramState.setusedcell(byte)`.
  func setUsedCell(_ value: Int) { usedCell = value }

  /// `DiagramState.setclocknumber(byte)`, `i < 100 ? i : 1`.
  func setClockNumber(_ value: Int) { clockNumber = value < 100 ? value : 1 }

  /// `DiagramState.setLastClock(Value)`.
  func setLastClock(_ newClock: Value) -> Value {
    let previous = lastClock
    lastClock = newClock
    return previous
  }

  /// `DiagramState.moveback()`; shift every input's row left by one slot.
  func moveBackAll() {
    guard length >= 1 else { return }
    for i in 0..<inputs {
      diagram[i].removeFirst()
      diagram[i].append(nil)
    }
  }

  /// `DiagramState.updateSize(byte, byte)`.
  func updateSize(inputs newInputs: Int, length newLength: Int) {
    guard newInputs != inputs || newLength != length else { return }
    let oldInputs = inputs
    let oldLength = length
    let oldDiagram = diagram
    let oldUsedCell = usedCell

    inputs = newInputs
    length = newLength
    clockNumber += (newLength - oldLength) / 2
    diagram = Array(repeating: Array(repeating: nil, count: newLength), count: newInputs)
    clear()

    if oldUsedCell < newLength - 1 {
      for i in 0..<min(newInputs, oldInputs) {
        for j in 0..<min(newLength, oldLength) {
          diagram[i][j] = oldDiagram[i][j]
        }
      }
      moveBack = false
    } else {
      // NOTE: upstream's index expression here (`h - (oldLength - usedCell - 1)`) can go
      // negative for some shrink sizes, which is a latent `ArrayIndexOutOfBoundsException` in
      // the Java too (reachable from `propagate`, so D13 would make it a circuit error rather
      // than a crash there). Not threaded through as `throws` in this port, `updateSize` is
      // called from a non-throwing context, so an out-of-range source index is skipped rather
      // than replicating the crash. Known, minor divergence; see the task's final report.
      for i in 0..<min(newInputs, oldInputs) {
        var h = oldLength - 1
        var j = newLength - 1
        while j >= 0 && h >= 0 {
          let sourceIndex = h - (oldLength - oldUsedCell - 1)
          if sourceIndex >= 0 && sourceIndex < oldDiagram[i].count {
            diagram[i][j] = oldDiagram[i][sourceIndex]
          }
          h -= 1
          j -= 1
        }
      }
      usedCell = newLength - 1
      moveBack = true
    }
  }
}
