// Ttl7486.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl7486),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// TTL 74x86: quad 2-input XOR gate.
public final class Ttl7486: AbstractTtlGate {

  /// `Ttl7486._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public static let id = "7486"

  public init() {
    super.init(Ttl7486.id, pins: 14, outputPorts: [3, 6, 8, 11], drawGates: true)
  }

  /// Four XOR gates, same port-index shape as `Ttl7400`'s NAND loop.
  public override func propagateTtl(_ state: any InstanceState) throws {
    for i in stride(from: 2, to: 6, by: 3) {
      state.setPort(i, state.portValue(i - 1).xor(state.portValue(i - 2)), 1)
    }
    for i in stride(from: 6, to: 12, by: 3) {
      state.setPort(i, state.portValue(i + 1).xor(state.portValue(i + 2)), 1)
    }
  }

  public override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    let portwidth = 18
    let portheight = 15
    let youtput = y + (up ? 20 : 40)
    Drawgates.paintXor(painter, x + 44, youtput, portwidth, portheight, false)
    Drawgates.paintOutputgate(
      painter, xpin: x + 50, y: y, xoutput: x + 44, youtput: youtput, up: up, height: height)
    Drawgates.paintDoubleInputgate(
      painter, rightPinX: x + 30, y: y, inputX: x + 44 - portwidth, outputY: youtput,
      portHeight: portheight, up: up, rightToLeft: false, height: height)
  }
}
