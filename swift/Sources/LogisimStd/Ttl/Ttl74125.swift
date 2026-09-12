// Ttl74125.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl74125),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// TTL 74x125: quad bus buffer with three-state outputs (active-low enable).
public final class Ttl74125: AbstractTtlGate {

  /// `Ttl74125._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public static let id = "74125"

  public init() {
    super.init(Ttl74125.id, pins: 14, outputPorts: [3, 6, 8, 11], drawGates: true)
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    for i in stride(from: 2, to: 6, by: 3) {
      if state.portValue(i - 2) == .trueValue {
        state.setPort(i, .unknownValue, 1)
      } else {
        state.setPort(i, state.portValue(i - 1), 1)
      }
    }
    for i in stride(from: 6, to: 11, by: 3) {
      if state.portValue(i + 2) == .trueValue {
        state.setPort(i, .unknownValue, 1)
      } else {
        state.setPort(i, state.portValue(i + 1), 1)
      }
    }
  }

  public override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    let portwidth = 15
    let portheight = 8
    let youtput = y + (up ? 20 : 40)
    Drawgates.paintBuffer(painter, x + 50, youtput, portwidth, portheight)
    Drawgates.paintOutputgate(
      painter, xpin: x + 50, y: y, xoutput: x + 45, youtput: youtput, up: up, height: height)
    Drawgates.paintSingleInputgate(
      painter, xpin: x + 30, y: y, xinput: x + 35, youtput: youtput, up: up, height: height)
    if !up {
      Drawgates.paintSingleInputgate(
        painter, xpin: x + 10, y: y, xinput: x + 41, youtput: youtput - 7, up: up, height: height)
      painter.drawLine(x + 41, youtput - 5, x + 41, youtput - 7)
      painter.drawOval(x + 40, youtput - 5, 3, 3)
    } else {
      Drawgates.paintSingleInputgate(
        painter, xpin: x + 10, y: y, xinput: x + 41, youtput: youtput + 7, up: up, height: height)
      painter.drawLine(x + 41, youtput + 5, x + 41, youtput + 7)
      painter.drawOval(x + 40, youtput + 2, 3, 3)
    }
  }
}
