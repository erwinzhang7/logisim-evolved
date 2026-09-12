// Ttl7430.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl7430),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// TTL 74x30: single 8-input NAND gate.
public final class Ttl7430: AbstractTtlGate {

  /// `Ttl7430._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public static let id = "7430"

  public init() {
    super.init(
      Ttl7430.id,
      pins: 14,
      outputPorts: [8],
      notUsedPins: [9, 10, 13],
      portNames: ["A", "B", "C", "D", "E", "F", "Y", "G", "H"])
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    let val1 =
      state.portValue(0)
      .and(state.portValue(1).and(state.portValue(2).and(state.portValue(3))))
    let val2 =
      val1.and(
        state.portValue(4)
          .and(state.portValue(5).and(state.portValue(7).and(state.portValue(8)))))
    state.setPort(6, val2.not(), 1)
  }

  public override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    paintBase(painter, state, drawName: false, ghost: false)
    Drawgates.paintAnd(painter, x + 123, y + 30, 10, 18, true)
    painter.drawLine(x + 70, y + AbstractTtlGate.pinHeight, x + 70, y + 23)
    painter.drawLine(x + 50, y + AbstractTtlGate.pinHeight, x + 50, y + 25)
    painter.drawLine(x + 10, y + height - AbstractTtlGate.pinHeight, x + 10, y + 27)
    painter.drawLine(x + 30, y + height - AbstractTtlGate.pinHeight, x + 30, y + 29)
    painter.drawLine(x + 50, y + height - AbstractTtlGate.pinHeight, x + 50, y + 31)
    painter.drawLine(x + 70, y + height - AbstractTtlGate.pinHeight, x + 70, y + 33)
    painter.drawLine(x + 90, y + height - AbstractTtlGate.pinHeight, x + 90, y + 35)
    painter.drawLine(x + 110, y + height - AbstractTtlGate.pinHeight, x + 110, y + 37)
    painter.drawLine(x + 70, y + 23, x + 113, y + 23)
    painter.drawLine(x + 50, y + 25, x + 113, y + 25)
    painter.drawLine(x + 10, y + 27, x + 113, y + 27)
    painter.drawLine(x + 30, y + 29, x + 113, y + 29)
    painter.drawLine(x + 50, y + 31, x + 113, y + 31)
    painter.drawLine(x + 70, y + 33, x + 113, y + 33)
    painter.drawLine(x + 90, y + 35, x + 113, y + 35)
    painter.drawLine(x + 110, y + 37, x + 113, y + 37)
    painter.drawLine(x + 128, y + 30, x + 130, y + 30)
    painter.drawLine(x + 130, y + AbstractTtlGate.pinHeight, x + 130, y + 30)
  }
}
