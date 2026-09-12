// Ttl7454.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl7454),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// TTL 74x54: 4-wide AND-OR-INVERT gate (two 2-input products, two 3-input products).
public final class Ttl7454: AbstractTtlGate {

  /// `Ttl7454._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public static let id = "7454"

  public init() {
    super.init(
      Ttl7454.id,
      pins: 14,
      outputPorts: [8],
      notUsedPins: [6, 11, 12],
      portNames: ["A", "C", "D", "E", "F", "Y", "G", "H", "B"])
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    let val1 = state.portValue(0).and(state.portValue(8))
    let val2 = state.portValue(1).and(state.portValue(2))
    let val3 = state.portValue(3).and(state.portValue(4))
    let val4 = state.portValue(6).and(state.portValue(7))
    state.setPort(5, val1.or(val2.or(val3.or(val4))).not(), 3)
  }

  /// **Deviation (mechanism):** `offset` is Java's `GATE_SHAPE == SHAPE_RECTANGULAR` check;
  /// `shaped` defaults to `true`, so `offset == 0` here, matching the default gate shape.
  public override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    paintBase(painter, state, drawName: false, ghost: false)
    Drawgates.paintOr(painter, x + 125, y + 30, 10, 10, true, false)
    Drawgates.paintAnd(painter, x + 105, y + 20, 10, 10, false)
    Drawgates.paintAnd(painter, x + 105, y + 40, 10, 10, false)
    Drawgates.paintAnd(painter, x + 65, y + 20, 10, 10, false)
    Drawgates.paintAnd(painter, x + 65, y + 40, 10, 10, false)
    let shaped = true
    let offset = shaped ? 0 : 4
    var xpos = [x + 105, x + 108, x + 108, x + 111 + offset]
    var ypos = [y + 20, y + 20, y + 27, y + 27]
    painter.drawPolyline(xpos, ypos)
    xpos = [x + 65, x + 68, x + 68, x + 111 + offset]
    ypos = [y + 20, y + 20, y + 29, y + 29]
    painter.drawPolyline(xpos, ypos)
    ypos = [y + 40, y + 40, y + 31, y + 31]
    painter.drawPolyline(xpos, ypos)
    xpos = [x + 105, x + 108, x + 108, x + 111 + offset]
    ypos = [y + 40, y + 40, y + 33, y + 33]
    painter.drawPolyline(xpos, ypos)
    xpos = [x + 129, x + 130, x + 130]
    ypos = [y + 30, y + 30, y + AbstractTtlGate.pinHeight]
    painter.drawPolyline(xpos, ypos)
    xpos = [x + 30, x + 30, x + 55]
    ypos = [y + AbstractTtlGate.pinHeight, y + 17, y + 17]
    painter.drawPolyline(xpos, ypos)
    xpos = [x + 10, x + 10, x + 55]
    ypos = [y + height - AbstractTtlGate.pinHeight, y + 23, y + 23]
    painter.drawPolyline(xpos, ypos)
    xpos = [x + 30, x + 30, x + 55]
    ypos = [y + height - AbstractTtlGate.pinHeight, y + 37, y + 37]
    painter.drawPolyline(xpos, ypos)
    xpos = [x + 50, x + 50, x + 55]
    ypos = [y + height - AbstractTtlGate.pinHeight, y + 43, y + 43]
    painter.drawPolyline(xpos, ypos)
    xpos = [x + 70, x + 70, x + 95]
    ypos = [y + height - AbstractTtlGate.pinHeight, y + 37, y + 37]
    painter.drawPolyline(xpos, ypos)
    xpos = [x + 90, x + 90, x + 95]
    ypos = [y + height - AbstractTtlGate.pinHeight, y + 43, y + 43]
    painter.drawPolyline(xpos, ypos)
    xpos = [x + 90, x + 90, x + 95]
    ypos = [y + AbstractTtlGate.pinHeight, y + 23, y + 23]
    painter.drawPolyline(xpos, ypos)
    xpos = [x + 110, x + 110, x + 93, x + 93, x + 95]
    ypos = [y + AbstractTtlGate.pinHeight, y + 10, y + 10, y + 17, y + 17]
    painter.drawPolyline(xpos, ypos)
  }
}
