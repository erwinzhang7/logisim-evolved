// Ttl7485.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl7485),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// TTL 74x85: 4-bit magnitude comparator.
public final class Ttl7485: AbstractTtlGate {

  /// `Ttl7485._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public static let id = "7485"

  public init() {
    super.init(
      Ttl7485.id,
      pins: 16,
      outputPorts: [5, 6, 7],
      portNames: [
        "B3", "A<B", "A=B", "A>B", "A>B", "A=B", "A<B", "B0", "A0", "B1", "A1", "A2", "B2", "A3",
      ])
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    let a0: Int = state.portValue(8) == .trueValue ? 1 : 0
    let a1: Int = state.portValue(10) == .trueValue ? 2 : 0
    let a2: Int = state.portValue(11) == .trueValue ? 4 : 0
    let a3: Int = state.portValue(13) == .trueValue ? 8 : 0
    let b0: Int = state.portValue(7) == .trueValue ? 1 : 0
    let b1: Int = state.portValue(9) == .trueValue ? 2 : 0
    let b2: Int = state.portValue(12) == .trueValue ? 4 : 0
    let b3: Int = state.portValue(0) == .trueValue ? 8 : 0
    let a = a3 + a2 + a1 + a0
    let b = b3 + b2 + b1 + b0
    if a > b {
      state.setPort(4, .trueValue, 1)
      state.setPort(5, .falseValue, 1)
      state.setPort(6, .falseValue, 1)
    } else if a < b {
      state.setPort(4, .falseValue, 1)
      state.setPort(5, .falseValue, 1)
      state.setPort(6, .trueValue, 1)
    } else if state.portValue(2) == .trueValue {
      state.setPort(4, .falseValue, 1)
      state.setPort(5, .trueValue, 1)
      state.setPort(6, .falseValue, 1)
    } else if state.portValue(1) == .trueValue && state.portValue(3) == .trueValue {
      state.setPort(4, .falseValue, 1)
      state.setPort(5, .falseValue, 1)
      state.setPort(6, .falseValue, 1)
    } else if state.portValue(1) == .trueValue {
      state.setPort(4, .falseValue, 1)
      state.setPort(5, .falseValue, 1)
      state.setPort(6, .trueValue, 1)
    } else if state.portValue(3) == .trueValue {
      state.setPort(4, .trueValue, 1)
      state.setPort(5, .falseValue, 1)
      state.setPort(6, .falseValue, 1)
    } else {
      state.setPort(4, .trueValue, 1)
      state.setPort(5, .falseValue, 1)
      state.setPort(6, .trueValue, 1)
    }
  }

  public override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    paintBase(painter, state, drawName: true, ghost: false)
    Drawgates.paintPortNames(painter, x: x, y: y, height: height, portNames: portNames ?? [])
  }
}
