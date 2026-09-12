// Ttl7402.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl7402),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// TTL 74x02: quad 2-input NOR gate.
public final class Ttl7402: AbstractTtlGate {

  /// `Ttl7402._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public static let id = "7402"

  private static let pinCount = 14
  private static let outPins = [1, 4, 10, 13]

  public convenience init() {
    self.init(Ttl7402.id)
  }

  public init(_ name: String) {
    super.init(
      name,
      pins: Ttl7402.pinCount,
      outputPorts: Ttl7402.outPins,
      drawGates: true)
  }

  /// Four NOR gates, laid out exactly as `Ttl7400`'s four NANDs but with `.or` in place of
  /// `.and` and the input/output pin roles swapped within each row (see the Java loop bounds).
  public override func propagateTtl(_ state: any InstanceState) throws {
    for i in stride(from: 0, to: 6, by: 3) {
      state.setPort(i, state.portValue(i + 1).or(state.portValue(i + 2)).not(), 1)
    }
    for i in stride(from: 8, to: 12, by: 3) {
      state.setPort(i, state.portValue(i - 1).or(state.portValue(i - 2)).not(), 1)
    }
  }

  public override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    let portwidth = 18
    let portheight = 15
    let youtput = y + (up ? 20 : 40)
    Drawgates.paintOr(painter, x + 20, youtput, portwidth - 4, portheight, true, true)
    Drawgates.paintOutputgate(
      painter, xpin: x + 10, y: y, xoutput: x + 16, youtput: youtput, up: up, height: height)
    Drawgates.paintDoubleInputgate(
      painter, rightPinX: x + 50, y: y, inputX: x + 16 + portwidth, outputY: youtput,
      portHeight: portheight, up: up, rightToLeft: true, height: height)
  }
}
