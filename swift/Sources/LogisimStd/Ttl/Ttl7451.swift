// Ttl7451.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl7451),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// TTL 74x51: dual 2-wide 2-input AND-OR-INVERT gate.
public final class Ttl7451: AbstractTtlGate {

  /// `Ttl7451._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public static let id = "7451"

  public init() {
    super.init(
      Ttl7451.id,
      pins: 14,
      outputPorts: [6, 8],
      notUsedPins: [11, 12],
      portNames: ["A1", "A2", "B2", "C2", "D2", "Y2", "Y1", "C1", "D1", "B1"])
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    var val1 = state.portValue(1).and(state.portValue(2))
    var val2 = state.portValue(3).and(state.portValue(4))
    state.setPort(5, val1.or(val2).not(), 3)
    val1 = state.portValue(0).and(state.portValue(9))
    val2 = state.portValue(7).and(state.portValue(8))
    state.setPort(6, val1.or(val2).not(), 3)
  }

  /// **Deviation (mechanism):** `offset` is Java's `GATE_SHAPE == SHAPE_RECTANGULAR` check;
  /// `shaped` defaults to `true` (see `Drawgates.swift`'s header), so `offset == 0` here,
  /// matching the preference's own default.
  public override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    paintBase(painter, state, drawName: false, ghost: false)
    Drawgates.paintAnd(painter, x + 50, y + 24, 10, 10, false)
    Drawgates.paintAnd(painter, x + 50, y + 36, 10, 10, false)
    Drawgates.paintOr(painter, x + 70, y + 30, 10, 10, true, false)

    Drawgates.paintAnd(painter, x + 100, y + 24, 10, 10, false)
    Drawgates.paintAnd(painter, x + 100, y + 36, 10, 10, false)
    Drawgates.paintOr(painter, x + 120, y + 30, 10, 10, true, false)

    let shaped = true
    let offset = shaped ? 0 : 4

    var posX = [x + 50, x + 53 + offset / 2, x + 53 + offset / 2, x + 56 + offset]
    var posY = [y + 24, y + 24, y + 26 + offset / 2, y + 26 + offset / 2]
    painter.drawPolyline(posX, posY)
    for i in 0..<4 { posX[i] += 50 }
    painter.drawPolyline(posX, posY)
    posY[0] = y + 36
    posY[1] = y + 36
    posY[2] = y + 34 - offset / 2
    posY[3] = y + 34 - offset / 2
    painter.drawPolyline(posX, posY)
    for i in 0..<4 { posX[i] -= 50 }
    painter.drawPolyline(posX, posY)
    posX = [x + 10, x + 10, x + 40]
    posY = [y + height - AbstractTtlGate.pinHeight, y + 39, y + 39]
    painter.drawPolyline(posX, posY)
    posX = [x + 30, x + 30, x + 40]
    posY = [y + AbstractTtlGate.pinHeight, y + 33, y + 33]
    painter.drawPolyline(posX, posY)
    posX = [x + 90, x + 90, x + 33, x + 33, x + 40]
    posY = [y + AbstractTtlGate.pinHeight, y + 10, y + 10, y + 27, y + 27]
    painter.drawPolyline(posX, posY)
    posX = [x + 110, x + 110, x + 36, x + 36, x + 40]
    posY = [y + AbstractTtlGate.pinHeight, y + 13, y + 13, y + 21, y + 21]
    painter.drawPolyline(posX, posY)
    posX = [x + 130, x + 130, x + 75, x + 75, x + 74]
    posY = [y + AbstractTtlGate.pinHeight, y + 16, y + 16, y + 30, y + 30]
    painter.drawPolyline(posX, posY)
    posX = [x + 30, x + 30, x + 78, x + 78, x + 90]
    posY = [y + height - AbstractTtlGate.pinHeight, y + 44, y + 44, y + 21, y + 21]
    painter.drawPolyline(posX, posY)
    posX = [x + 50, x + 50, x + 81, x + 81, x + 90]
    posY = [y + height - AbstractTtlGate.pinHeight, y + 47, y + 47, y + 27, y + 27]
    painter.drawPolyline(posX, posY)
    posX = [x + 70, x + 70, x + 84, x + 84, x + 90]
    posY = [y + height - AbstractTtlGate.pinHeight, y + 50, y + 50, y + 33, y + 33]
    painter.drawPolyline(posX, posY)
    posX = [x + 90, x + 90, x + 87, x + 87, x + 90]
    posY = [y + height - AbstractTtlGate.pinHeight, y + 50, y + 50, y + 39, y + 39]
    painter.drawPolyline(posX, posY)
    posX = [x + 110, x + 110, x + 126, x + 126, x + 124]
    posY = [y + height - AbstractTtlGate.pinHeight, y + 40, y + 40, y + 30, y + 30]
    painter.drawPolyline(posX, posY)
  }
}
