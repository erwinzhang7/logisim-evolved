// Ttl7474.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl7474),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// TTL 74x74: dual D-type positive-edge-triggered flip-flop with preset and clear. The two
// flip-flops are independent (own clock, own preset/clear), so `TtlRegisterData` here tracks
// two clock indices via `TtlClockState`'s `which` parameter rather than one: see
// `TtlClockState.swift`'s header, this is the file that motivated it.
//
// ── Not ported ──────────────────────────────────────────────────────────────────────────────
//
//   * `Poker` (mouse-driven bit toggling): depends on `getTranslatedTtlXY`, itself not ported
//     (`AbstractTtlGate.swift`'s header). No `Ttl*.swift` file in this family ports a poker.
//   * `checkForGatedClocks`/`clockPinIndex`, HDL/FPGA backlog (D11).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

public final class Ttl7474: AbstractTtlGate {

  /// `Ttl7474._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public static let id = "7474"

  public init() {
    super.init(
      Ttl7474.id,
      pins: 14,
      outputPorts: [5, 6, 8, 9],
      portNames: [
        "nCLR1", "D1", "CLK1", "nPRE1", "Q1", "nQ1", "nQ2", "Q2", "nPRE2", "CLK2", "D2", "nCLR2",
      ])
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    let data: TtlRegisterData
    if let existing = state.data as? TtlRegisterData {
      data = existing
    } else {
      data = TtlRegisterData(width: BitWidth.known(2))
      state.setData(data)
    }
    let triggered1 = try data.clock.updateClock(state.portValue(2), which: 0)
    let triggered2 = try data.clock.updateClock(state.portValue(9), which: 1)
    var values = data.getValue().getAll()
    if state.portValue(0) == .falseValue && state.portValue(3) == .falseValue {
      values[0] = Value.createUnknown(BitWidth.known(1))
    } else if state.portValue(0) == .falseValue {
      values[0] = Value.createKnown(BitWidth.known(1), 0)
    } else if state.portValue(3) == .falseValue {
      values[0] = Value.createKnown(BitWidth.known(1), 1)
    } else if triggered1 {
      values[0] = state.portValue(1)
    }
    if state.portValue(11) == .falseValue && state.portValue(8) == .falseValue {
      values[1] = Value.createUnknown(BitWidth.known(1))
    } else if state.portValue(11) == .falseValue {
      values[1] = Value.createKnown(BitWidth.known(1), 0)
    } else if state.portValue(8) == .falseValue {
      values[1] = Value.createKnown(BitWidth.known(1), 1)
    } else if triggered2 {
      values[1] = state.portValue(10)
    }
    data.setValue(try Value.create(values))

    state.setPort(4, data.getValue().get(0), 8)
    state.setPort(5, data.getValue().get(0).not(), 8)
    state.setPort(6, data.getValue().get(1).not(), 8)
    state.setPort(7, data.getValue().get(1), 8)
  }

  public override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    let data = state.data as? TtlRegisterData
    paintBase(painter, state, drawName: false, ghost: false)
    drawFlop(painter, x: x, y: y + 1)
    drawFlop(painter, x: x + 70, y: y - 2)
    drawCon1(painter, x: x, y: y, height: height)
    drawCon2(painter, x: x, y: y)
    drawState(painter, x: x, y: y + 1, id: 0, data: data)
    drawState(painter, x: x + 70, y: y - 2, id: 1, data: data)
  }

  private func drawState(_ painter: SceneBuilder, x: Int, y: Int, id: Int, data: TtlRegisterData?) {
    guard let data else { return }
    let bit = data.getValue().get(id)
    painter.withColor(.palette(bit.paletteIndex)) {
      painter.fillOval(x + 33, y + 30, 8, 8)
    }
    painter.withColor(.white) {
      painter.drawCenteredText(bit.toDisplayString(), x: x + 36, y: y + 33)
    }
  }

  private func drawFlop(_ painter: SceneBuilder, x: Int, y: Int) {
    painter.drawRect(x + 27, y + 20, 16, 20)
    painter.drawOval(x + 33, y + 16, 4, 4)
    painter.drawOval(x + 33, y + 40, 4, 4)
    painter.drawOval(x + 43, y + 33, 4, 4)
    painter.drawLine(x + 27, y + 33, x + 30, y + 35)
    painter.drawLine(x + 27, y + 37, x + 30, y + 35)
    painter.drawString("D", x: x + 28, y: y + 28)
    painter.drawString("Q", x: x + 38, y: y + 28)
  }

  private func drawCon1(_ painter: SceneBuilder, x: Int, y: Int, height: Int) {
    painter.drawLine(x + 70, y + height - AbstractTtlGate.pinHeight, x + 70, y + 16)
    painter.drawLine(x + 35, y + 16, x + 70, y + 16)
    painter.drawLine(x + 35, y + 16, x + 35, y + 17)

    painter.drawLine(x + 10, y + height - AbstractTtlGate.pinHeight, x + 10, y + 46)
    painter.drawLine(x + 10, y + 46, x + 35, y + 46)
    painter.drawLine(x + 35, y + 45, x + 35, y + 46)

    painter.drawLine(x + 30, y + height - AbstractTtlGate.pinHeight, x + 30, y + 50)
    painter.drawLine(x + 20, y + 50, x + 30, y + 50)
    painter.drawLine(x + 20, y + 26, x + 20, y + 50)
    painter.drawLine(x + 20, y + 26, x + 27, y + 26)

    painter.drawLine(x + 50, y + height - AbstractTtlGate.pinHeight, x + 50, y + 48)
    painter.drawLine(x + 22, y + 48, x + 50, y + 48)
    painter.drawLine(x + 22, y + 36, x + 22, y + 48)
    painter.drawLine(x + 22, y + 36, x + 27, y + 36)

    painter.drawLine(x + 90, y + height - AbstractTtlGate.pinHeight, x + 90, y + 48)
    painter.drawLine(x + 68, y + 48, x + 90, y + 48)
    painter.drawLine(x + 68, y + 26, x + 68, y + 48)
    painter.drawLine(x + 43, y + 26, x + 68, y + 26)

    painter.drawLine(x + 110, y + height - AbstractTtlGate.pinHeight, x + 110, y + 50)
    painter.drawLine(x + 66, y + 50, x + 110, y + 50)
    painter.drawLine(x + 66, y + 36, x + 66, y + 50)
    painter.drawLine(x + 47, y + 36, x + 66, y + 36)
  }

  private func drawCon2(_ painter: SceneBuilder, x: Int, y: Int) {
    painter.drawLine(x + 130, y + AbstractTtlGate.pinHeight, x + 130, y + 33)
    painter.drawLine(x + 117, y + 33, x + 130, y + 33)

    painter.drawLine(x + 110, y + AbstractTtlGate.pinHeight, x + 110, y + 10)
    painter.drawLine(x + 110, y + 10, x + 120, y + 10)
    painter.drawLine(x + 120, y + 10, x + 120, y + 23)
    painter.drawLine(x + 113, y + 23, x + 120, y + 23)

    painter.drawLine(x + 90, y + AbstractTtlGate.pinHeight, x + 90, y + 10)
    painter.drawLine(x + 90, y + 10, x + 105, y + 10)
    painter.drawLine(x + 105, y + 10, x + 105, y + 14)

    painter.drawLine(x + 70, y + AbstractTtlGate.pinHeight, x + 70, y + 10)
    painter.drawLine(x + 70, y + 10, x + 88, y + 10)
    painter.drawLine(x + 88, y + 10, x + 88, y + 33)
    painter.drawLine(x + 88, y + 33, x + 97, y + 33)

    painter.drawLine(x + 50, y + AbstractTtlGate.pinHeight, x + 50, y + 12)
    painter.drawLine(x + 50, y + 12, x + 86, y + 12)
    painter.drawLine(x + 86, y + 12, x + 86, y + 23)
    painter.drawLine(x + 86, y + 23, x + 97, y + 23)

    painter.drawLine(x + 30, y + AbstractTtlGate.pinHeight, x + 30, y + 14)
    painter.drawLine(x + 30, y + 14, x + 84, y + 14)
    painter.drawLine(x + 84, y + 14, x + 84, y + 44)
    painter.drawLine(x + 84, y + 44, x + 105, y + 44)
    painter.drawLine(x + 105, y + 43, x + 105, y + 44)
  }
}
