// Ttl74164.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl74164),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// TTL 74x164: 8-bit serial-in/parallel-out shift register with asynchronous clear.
//
// ── Not ported ──────────────────────────────────────────────────────────────────────────────
//
//   * `Poker` (mouse-driven bit toggling): depends on `getTranslatedTtlXY`, itself not ported.
//   * `checkForGatedClocks`/`clockPinIndex`, HDL/FPGA backlog (D11).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

public final class Ttl74164: AbstractTtlGate {

  /// `Ttl74164._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public static let id = "74164"

  public static let portIndexA = 0
  public static let portIndexB = 1
  public static let portIndexQA = 2
  public static let portIndexQB = 3
  public static let portIndexQC = 4
  public static let portIndexQD = 5
  public static let portIndexClk = 6
  public static let portIndexClr = 7
  public static let portIndexQE = 8
  public static let portIndexQF = 9
  public static let portIndexQG = 10
  public static let portIndexQH = 11

  public init() {
    super.init(
      Ttl74164.id,
      pins: 14,
      outputPorts: [3, 4, 5, 6, 10, 11, 12, 13],
      portNames: ["A", "B", "QA", "QB", "QC", "QD", "Clock", "Clear", "QE", "QF", "QG", "QH"])
  }

  private func getData(_ state: any InstanceState) -> TtlShiftRegisterData {
    if let existing = state.data as? TtlShiftRegisterData {
      return existing
    }
    let data = TtlShiftRegisterData(width: .one, length: 8)
    state.setData(data)
    return data
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    let data = getData(state)
    let triggered = try data.clock.updateClock(
      state.portValue(Ttl74164.portIndexClk), trigger: StdAttr.triggerRising)
    if state.portValue(Ttl74164.portIndexClr) == .falseValue {  // Clear
      data.clear()
    } else if triggered {
      data.clear()

      data.pushDown(
        state.portValue(Ttl74164.portIndexA) == .trueValue
          && state.portValue(Ttl74164.portIndexB) == .trueValue
          ? .trueValue : .falseValue)

      data.pushDown(state.portValue(Ttl74164.portIndexQA))
      data.pushDown(state.portValue(Ttl74164.portIndexQB))
      data.pushDown(state.portValue(Ttl74164.portIndexQC))
      data.pushDown(state.portValue(Ttl74164.portIndexQD))
      data.pushDown(state.portValue(Ttl74164.portIndexQE))
      data.pushDown(state.portValue(Ttl74164.portIndexQF))
      data.pushDown(state.portValue(Ttl74164.portIndexQG))
    }
    state.setPort(Ttl74164.portIndexQA, data.get(0), 4)
    state.setPort(Ttl74164.portIndexQB, data.get(1), 4)
    state.setPort(Ttl74164.portIndexQC, data.get(2), 4)
    state.setPort(Ttl74164.portIndexQD, data.get(3), 4)
    state.setPort(Ttl74164.portIndexQE, data.get(4), 4)
    state.setPort(Ttl74164.portIndexQF, data.get(5), 4)
    state.setPort(Ttl74164.portIndexQG, data.get(6), 4)
    state.setPort(Ttl74164.portIndexQH, data.get(7), 4)
  }

  public override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    paintBase(painter, state, drawName: false, ghost: false)
    Drawgates.paintPortNames(
      painter, x: x, y: y, height: height,
      portNames: ["A", "B", "QA", "QB", "QC", "QD", "CLK", "CLR", "QE", "QF", "QG", "QH"])
    drawState(painter, x: x, y: y, height: height, data: state.data as? TtlShiftRegisterData)
  }

  private func drawState(
    _ painter: SceneBuilder, x: Int, y: Int, height: Int, data: TtlShiftRegisterData?
  ) {
    guard let data else { return }
    for i in 0..<8 {
      let bit = data.get(7 - i)
      painter.withColor(.palette(bit.paletteIndex)) {
        painter.fillOval(x + 36 + i * 10, y + height / 2 - 4, 8, 8)
      }
      painter.withColor(.white) {
        painter.drawCenteredText(bit.toDisplayString(), x: x + 40 + i * 10, y: y + height / 2)
      }
    }
  }
}
