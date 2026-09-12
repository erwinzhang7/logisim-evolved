// Ttl747266.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl747266),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// TTL 74x7266: quad 2-input XNOR gate (totem-pole output, unlike the open-collector
// `Ttl74266`). Model based on https://www.ti.com/product/CD74HC7266 datasheet.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

public final class Ttl747266: AbstractTtlGate {

  /// `Ttl747266._ID`. "Unique identifier of the tool, used as reference in project files. Do
  /// NOT change as it will prevent project files from loading.", upstream's own comment.
  public static let id = "747266"

  public init() {
    super.init(Ttl747266.id, pins: 14, outputPorts: [3, 6, 8, 11], drawGates: true)
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    for i in stride(from: 2, to: 6, by: 3) {
      state.setPort(i, state.portValue(i - 1).xor(state.portValue(i - 2)).not(), 1)
    }
    for i in stride(from: 6, to: 12, by: 3) {
      state.setPort(i, state.portValue(i + 1).xor(state.portValue(i + 2)).not(), 1)
    }
  }

  public override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    let portwidth = 18
    let portheight = 15
    let youtput = y + (up ? 20 : 40)
    Drawgates.paintXor(painter, x + 44, youtput, portwidth, portheight, true)
    Drawgates.paintOutputgate(
      painter, xpin: x + 50, y: y, xoutput: x + 48, youtput: youtput, up: up, height: height)
    Drawgates.paintDoubleInputgate(
      painter, rightPinX: x + 30, y: y, inputX: x + 44 - portwidth, outputY: youtput,
      portHeight: portheight, up: up, rightToLeft: false, height: height)
  }
}
