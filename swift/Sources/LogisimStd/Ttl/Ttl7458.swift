// Ttl7458.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl7458),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// TTL 74x58: dual 2-wide 2-input AND-OR gate (not inverted, unlike `Ttl7451`).
public final class Ttl7458: AbstractTtlGate {

  /// `Ttl7458._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public static let id = "7458"

  public init() {
    super.init(
      Ttl7458.id,
      pins: 14,
      outputPorts: [6, 8],
      portNames: ["A0", "A1", "B1", "C1", "D1", "Y1", "Y0", "D0", "E0", "F0", "B0", "C0"])
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    var val1 = state.portValue(1).and(state.portValue(2))
    var val2 = state.portValue(3).and(state.portValue(4))
    state.setPort(5, val1.or(val2), 5)
    val1 = state.portValue(0).and(state.portValue(11).and(state.portValue(10)))
    val2 = state.portValue(9).and(state.portValue(8).and(state.portValue(7)))
    state.setPort(6, val1.or(val2), 5)
  }

  /// **Deviation (mechanism):** `orOffset` is Java's `GATE_SHAPE == SHAPE_RECTANGULAR` check;
  /// `shaped` defaults to `true`, so `orOffset == 0` here, matching the default gate shape.
  public override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    paintBase(painter, state, drawName: false, ghost: false)
    Drawgates.paintOr(painter, x + 107, y + 39, 10, 10, false, false)
    Drawgates.paintAnd(painter, x + 86, y + 34, 10, 10, false)
    Drawgates.paintAnd(painter, x + 86, y + 44, 10, 10, false)
    let shaped = true
    let orOffset = shaped ? 0 : 4
    var posX = [x + 86, x + 90, x + 90, x + 93 + orOffset]
    var posY = [y + 34, y + 34, y + 36, y + 36]
    painter.drawPolyline(posX, posY)
    posY = [y + 44, y + 44, y + 42, y + 42]
    painter.drawPolyline(posX, posY)
    posX = [x + 107, x + 110, x + 110]
    posY = [y + 39, y + 39, y + height - AbstractTtlGate.pinHeight]
    painter.drawPolyline(posX, posY)
    for i in 0..<3 {
      painter.drawLine(
        x + 30 + i * 20, y + 32 + i * 5, x + 30 + i * 20, y + height - AbstractTtlGate.pinHeight)
      painter.drawLine(x + 30 + i * 20, y + 32 + i * 5, x + 76, y + 32 + i * 5)
    }
    posX = [x + 76, x + 73, x + 73, x + 90, x + 90]
    posY = [y + 47, y + 47, y + 51, y + 51, y + height - AbstractTtlGate.pinHeight]
    painter.drawPolyline(posX, posY)

    Drawgates.paintOr(painter, x + 127, y + 21, 10, 10, false, false)
    Drawgates.paintAnd(painter, x + 106, y + 16, 10, 10, false)
    Drawgates.paintAnd(painter, x + 106, y + 26, 10, 10, false)
    posX = [x + 106, x + 110, x + 110, x + 113 + orOffset]
    posY = [y + 16, y + 16, y + 18, y + 18]
    painter.drawPolyline(posX, posY)
    posY = [y + 26, y + 26, y + 24, y + 24]
    painter.drawPolyline(posX, posY)
    posX = [x + 127, x + 130, x + 130]
    posY = [y + 21, y + 21, y + AbstractTtlGate.pinHeight]
    painter.drawPolyline(posX, posY)
    for i in 0..<5 {
      posX = [x + 10 + i * 20, x + 10 + i * 20, x + 95]
      posY = [
        i == 0 ? y + height - AbstractTtlGate.pinHeight : y + AbstractTtlGate.pinHeight,
        y + 28 - i * 3, y + 28 - i * 3,
      ]
      painter.drawPolyline(posX, posY)
    }
    posX = [x + 96, x + 93, x + 93, x + 110, x + 110]
    posY = [y + 13, y + 13, y + 9, y + 9, y + AbstractTtlGate.pinHeight]
    painter.drawPolyline(posX, posY)
  }
}
