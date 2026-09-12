// Ttl74165.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl74165),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// TTL 74x165: 8-bit parallel-to-serial shift register with asynchronous load. Model based on
// https://www.ti.com/product/SN74LS165A datasheet.
//
// ── Not ported ──────────────────────────────────────────────────────────────────────────────
//
//   * `Poker` (mouse-driven bit toggling): depends on `getTranslatedTtlXY`, itself not ported.
//   * `checkForGatedClocks`/`clockPinIndex`: HDL/FPGA backlog (D11).
//   * `Ttl74165HdlGenerator`: HDL generation (strip per this port's binding rules).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

public final class Ttl74165: AbstractTtlGate {

  /// `Ttl74165._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public static let id = "74165"

  public init() {
    super.init(
      Ttl74165.id,
      pins: 16,
      outputPorts: [7, 9],
      portNames: [
        "Shift/Load", "Clock", "P4", "P5", "P6", "P7", "Q7n", "Q7", "Serial Input",
        "P0", "P1", "P2", "P3", "Clock Inhibit",
      ])
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
    let triggered = try data.clock.updateClock(state.portValue(1), trigger: StdAttr.triggerRising)
    if state.portValue(0) == .falseValue {  // load
      data.clear()
      data.pushDown(state.portValue(5))
      data.pushDown(state.portValue(4))
      data.pushDown(state.portValue(3))
      data.pushDown(state.portValue(2))
      data.pushDown(state.portValue(12))
      data.pushDown(state.portValue(11))
      data.pushDown(state.portValue(10))
      data.pushDown(state.portValue(9))
    } else if triggered && state.portValue(13) == .falseValue {  // shift
      data.pushDown(state.portValue(8))
    }
    state.setPort(6, data.get(0).not(), 4)
    state.setPort(7, data.get(0), 4)
  }

  public override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    paintBase(painter, state, drawName: false, ghost: false)
    Drawgates.paintPortNames(
      painter, x: x, y: y, height: height,
      portNames: [
        "ShLd", "CK", "P4", "P5", "P6", "P7", "Q7n", "Q7", "SER", "P0", "P1", "P2", "P3", "CkIh",
      ])
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
