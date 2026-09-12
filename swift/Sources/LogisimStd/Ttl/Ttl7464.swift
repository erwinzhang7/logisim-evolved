// Ttl7464.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl7464),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// TTL 74x64: 4-2-3-2-input AND-OR-INVERT gate.
public final class Ttl7464: AbstractTtlGate {

  /// `Ttl7464._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public static let id = "7464"

  public init() {
    super.init(
      Ttl7464.id,
      pins: 14,
      outputPorts: [8],
      portNames: ["A", "E", "F", "G", "H", "I", "Y", "J", "K", "B", "C", "D"],
      height: 70)
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    let val1 = state.portValue(1).and(state.portValue(2))
    let val2 = state.portValue(3).and(state.portValue(4).and(state.portValue(5)))
    let val3 = state.portValue(7).and(state.portValue(8))
    let val4 =
      state.portValue(9)
      .and(state.portValue(10).and(state.portValue(11).and(state.portValue(0))))
    let val5 = val1.or(val2.or(val3.or(val4)))
    state.setPort(6, val5.not(), 7)
  }

  /// **Deviation (mechanism):** `isIEC` is Java's `GATE_SHAPE == SHAPE_RECTANGULAR` check;
  /// hardcoded `false` here, matching the preference's own default (`SHAPE_SHAPED`): see
  /// `Drawgates.swift`'s header.
  public override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    paintBase(painter, state, drawName: false, ghost: false)
    let isIEC = false
    let andOffset = isIEC ? 10 : 0
    Drawgates.paintOr(painter, x + 125, y + 35, 10, isIEC ? 40 : 10, true, false)
    Drawgates.paintAnd(painter, x + 105 + andOffset, y + 20, 10, 10, false)
    Drawgates.paintAnd(painter, x + 105 + andOffset, y + 30, 10, 10, false)
    Drawgates.paintAnd(painter, x + 105 + andOffset, y + 40, 10, 10, false)
    Drawgates.paintAnd(painter, x + 105 + andOffset, y + 50, 10, 10, false)
    painter.drawLine(x + 129, y + 35, x + 130, y + 35)
    painter.drawLine(x + 130, y + 35, x + 130, y + AbstractTtlGate.pinHeight)
    var posX: [Int]
    var posY: [Int]
    for i in 0..<4 {
      if !isIEC {
        let tmpOff = (i == 0 || i == 3) ? 2 : 0
        posX = [x + 105, x + 107 + tmpOff, x + 107 + tmpOff, x + 111]
        posY = [y + 20 + i * 10, y + 20 + i * 10, y + 32 + i * 2, y + 32 + i * 2]
        painter.drawPolyline(posX, posY)
      }
      posX = [x + 10 + i * 20, x + 10 + i * 20, x + 95 + andOffset]
      posY = [
        i == 0 ? y + height - AbstractTtlGate.pinHeight : y + AbstractTtlGate.pinHeight,
        y + 33 - i * 2, y + 33 - i * 2,
      ]
      painter.drawPolyline(posX, posY)
      if i < 2 {
        posX = [x + 30 + i * 20, x + 30 + i * 20, x + 95 + andOffset]
        posY = [y + height - AbstractTtlGate.pinHeight, y + 38 + i * 5, y + 38 + i * 5]
        painter.drawPolyline(posX, posY)
        posX = [x + 70 + i * 20, x + 70 + i * 20, x + 95 + andOffset]
        posY = [y + height - AbstractTtlGate.pinHeight, y + 47 + i * 3, y + 47 + i * 3]
        painter.drawPolyline(posX, posY)
      }
    }
    posX = [x + 90, x + 90, x + 95 + andOffset]
    posY = [y + AbstractTtlGate.pinHeight, y + 23, y + 23]
    painter.drawPolyline(posX, posY)
    posX = [x + 110, x + 110, x + 93 + andOffset, x + 93 + andOffset, x + 95 + andOffset]
    posY = [y + AbstractTtlGate.pinHeight, y + 12, y + 12, y + 18, y + 18]
    painter.drawPolyline(posX, posY)
    posY = [
      y + height - AbstractTtlGate.pinHeight, y + height - 12, y + height - 12, y + 53, y + 53,
    ]
    painter.drawPolyline(posX, posY)
  }
}
