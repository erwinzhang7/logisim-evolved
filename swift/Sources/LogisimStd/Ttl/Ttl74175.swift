// Ttl74175.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl74175),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// TTL 74x175: quad D flip-flop with complementary outputs and asynchronous clear.
//
// Not ported: `checkForGatedClocks`/`clockPinIndex`; HDL/FPGA backlog (D11).
// `Ttl74175HdlGenerator` is stripped per this port's binding rules.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

public final class Ttl74175: AbstractTtlGate {

  /// `Ttl74175._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public static let id = "74175"

  public init() {
    super.init(
      Ttl74175.id,
      pins: 16,
      outputPorts: [2, 3, 6, 7, 10, 11, 14, 15],
      portNames: [
        "nCLR", "Q1", "nQ1", "D1", "D2", "nQ2", "Q2", "CLK", "Q3", "nQ3", "D3", "D4", "nQ4", "Q4",
      ])
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    let data: TtlRegisterData
    if let existing = state.data as? TtlRegisterData {
      data = existing
    } else {
      data = TtlRegisterData(width: BitWidth.known(4))
      state.setData(data)
    }
    let triggered = try data.clock.updateClock(state.portValue(7))
    if state.portValue(0) == .falseValue {
      data.setValue(Value.createKnown(data.width, 0))
    } else if triggered {
      var vals = data.getValue().getAll()
      vals[0] = state.portValue(3)
      vals[1] = state.portValue(4)
      vals[2] = state.portValue(10)
      vals[3] = state.portValue(11)
      data.setValue(try Value.create(vals))
    }
    state.setPort(1, data.getValue().get(0), 8)
    state.setPort(2, data.getValue().get(0).not(), 8)
    state.setPort(6, data.getValue().get(1), 8)
    state.setPort(5, data.getValue().get(1).not(), 8)
    state.setPort(8, data.getValue().get(2), 8)
    state.setPort(9, data.getValue().get(2).not(), 8)
    state.setPort(13, data.getValue().get(3), 8)
    state.setPort(12, data.getValue().get(3).not(), 8)
  }

  public override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    paintBase(painter, state, drawName: false, ghost: false)
    drawFlops(painter, x: x, y: y, height: height)
  }

  private func drawFlops(_ painter: SceneBuilder, x: Int, y: Int, height: Int) {
    // Reset line.
    painter.drawLine(x + 10, y + height - 10, x + 10, y + height - AbstractTtlGate.pinHeight)
    painter.drawLine(x + 10, y + height - 10, x + 140, y + height - 10)
    painter.drawLine(x + 140, y + height - 10, x + 140, y + 10)
    painter.drawLine(x + 60, y + 10, x + 140, y + 10)

    // Clock line.
    painter.drawLine(x + 150, y + AbstractTtlGate.pinHeight, x + 150, y + 30)
    painter.drawLine(x + 80, y + 30, x + 150, y + 30)

    // dff1.
    painter.drawRect(x + 57, y + 33, 6, 12)
    painter.drawOval(x + 59, y + 45, 2, 2)
    painter.fillOval(x + 59, y + 49, 2, 2)
    painter.drawLine(x + 60, y + 47, x + 60, y + 50)
    painter.drawOval(x + 55, y + 40, 2, 2)
    painter.drawLine(x + 50, y + height - AbstractTtlGate.pinHeight, x + 50, y + 41)
    painter.drawLine(x + 50, y + 41, x + 55, y + 41)
    painter.drawLine(x + 30, y + height - AbstractTtlGate.pinHeight, x + 30, y + 37)
    painter.drawLine(x + 30, y + 37, x + 57, y + 37)
    painter.drawLine(x + 70, y + height - AbstractTtlGate.pinHeight, x + 70, y + 37)
    painter.drawLine(x + 63, y + 37, x + 70, y + 37)
    painter.drawLine(x + 61, y + 41, x + 63, y + 42)
    painter.drawLine(x + 61, y + 41, x + 63, y + 40)
    painter.drawString("D", x: x + 64, y: y + 36)
    painter.drawString("Q", x: x + 52, y: y + 36)
    painter.drawLine(x + 63, y + 41, x + 97, y + 41)
    painter.drawLine(x + 80, y + 30, x + 80, y + 41)
    painter.fillOval(x + 79, y + 29, 2, 2)
    painter.fillOval(x + 79, y + 40, 2, 2)

    // dff2.
    painter.drawRect(x + 97, y + 33, 6, 12)
    painter.drawOval(x + 99, y + 45, 2, 2)
    painter.fillOval(x + 99, y + 49, 2, 2)
    painter.drawLine(x + 100, y + 47, x + 100, y + 50)
    painter.drawOval(x + 103, y + 40, 2, 2)
    painter.drawLine(x + 110, y + height - AbstractTtlGate.pinHeight, x + 110, y + 41)
    painter.drawLine(x + 105, y + 41, x + 110, y + 41)
    painter.drawLine(x + 130, y + height - AbstractTtlGate.pinHeight, x + 130, y + 37)
    painter.drawLine(x + 130, y + 37, x + 103, y + 37)
    painter.drawLine(x + 90, y + height - AbstractTtlGate.pinHeight, x + 90, y + 37)
    painter.drawLine(x + 90, y + 37, x + 97, y + 37)
    painter.drawLine(x + 97, y + 42, x + 99, y + 41)
    painter.drawLine(x + 97, y + 40, x + 99, y + 41)
    painter.drawString("D", x: x + 92, y: y + 36)
    painter.drawString("Q", x: x + 104, y: y + 36)

    // dff3.
    painter.drawRect(x + 97, y + 15, 6, 12)
    painter.drawOval(x + 99, y + 13, 2, 2)
    painter.fillOval(x + 99, y + 9, 2, 2)
    painter.drawLine(x + 100, y + 13, x + 100, y + 10)
    painter.drawOval(x + 103, y + 18, 2, 2)
    painter.drawLine(x + 110, y + AbstractTtlGate.pinHeight, x + 110, y + 19)
    painter.drawLine(x + 105, y + 19, x + 110, y + 19)
    painter.drawLine(x + 130, y + AbstractTtlGate.pinHeight, x + 130, y + 23)
    painter.drawLine(x + 130, y + 23, x + 103, y + 23)
    painter.drawLine(x + 90, y + AbstractTtlGate.pinHeight, x + 90, y + 23)
    painter.drawLine(x + 90, y + 23, x + 97, y + 23)
    painter.drawLine(x + 97, y + 20, x + 99, y + 19)
    painter.drawLine(x + 97, y + 18, x + 99, y + 19)
    painter.drawString("D", x: x + 92, y: y + 29)
    painter.drawString("Q", x: x + 104, y: y + 29)

    // dff4.
    painter.drawRect(x + 57, y + 15, 6, 12)
    painter.drawOval(x + 59, y + 13, 2, 2)
    painter.drawLine(x + 60, y + 13, x + 60, y + 10)
    painter.drawOval(x + 55, y + 18, 2, 2)
    painter.drawLine(x + 50, y + AbstractTtlGate.pinHeight, x + 50, y + 19)
    painter.drawLine(x + 50, y + 19, x + 55, y + 19)
    painter.drawLine(x + 30, y + AbstractTtlGate.pinHeight, x + 30, y + 23)
    painter.drawLine(x + 30, y + 23, x + 57, y + 23)
    painter.drawLine(x + 70, y + AbstractTtlGate.pinHeight, x + 70, y + 23)
    painter.drawLine(x + 63, y + 23, x + 70, y + 23)
    painter.drawLine(x + 61, y + 19, x + 63, y + 20)
    painter.drawLine(x + 61, y + 19, x + 63, y + 18)
    painter.drawString("D", x: x + 64, y: y + 29)
    painter.drawString("Q", x: x + 52, y: y + 29)
    painter.drawLine(x + 63, y + 19, x + 97, y + 19)
    painter.drawLine(x + 80, y + 19, x + 80, y + 40)
    painter.fillOval(x + 79, y + 18, 2, 2)
  }
}
