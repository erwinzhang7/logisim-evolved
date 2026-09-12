// Ttl74283.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl74283),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// TTL 74x283: 4-bit binary full adder with fast carry.
public final class Ttl74283: AbstractTtlGate {

  /// `Ttl74283._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public static let id = "74283"

  public init() {
    super.init(
      Ttl74283.id,
      pins: 16,
      outputPorts: [1, 4, 9, 10, 13],
      portNames: [
        "\u{2211}2", "B2", "A2", "\u{2211}1", "A1", "B1", "CIN", "C4", "\u{2211}4", "B4", "A4",
        "\u{2211}3", "A3", "B3",
      ])
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    let a1: Int64 = state.portValue(4) == .trueValue ? 1 : 0
    let a2: Int64 = state.portValue(2) == .trueValue ? 2 : 0
    let a3: Int64 = state.portValue(12) == .trueValue ? 4 : 0
    let a4: Int64 = state.portValue(10) == .trueValue ? 8 : 0
    let b1: Int64 = state.portValue(5) == .trueValue ? 1 : 0
    let b2: Int64 = state.portValue(1) == .trueValue ? 2 : 0
    let b3: Int64 = state.portValue(13) == .trueValue ? 4 : 0
    let b4: Int64 = state.portValue(9) == .trueValue ? 8 : 0
    let cin: Int64 = state.portValue(6) == .trueValue ? 1 : 0
    let sum = a1 + a2 + a3 + a4 + b1 + b2 + b3 + b4 + cin
    let output = Value.createKnown(5, sum)
    state.setPort(3, output.get(0), 1)
    state.setPort(0, output.get(1), 1)
    state.setPort(11, output.get(2), 1)
    state.setPort(8, output.get(3), 1)
    state.setPort(7, output.get(4), 1)
  }

  public override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    paintBase(painter, state, drawName: true, ghost: false)
    Drawgates.paintPortNames(painter, x: x, y: y, height: height, portNames: portNames ?? [])
  }
}
