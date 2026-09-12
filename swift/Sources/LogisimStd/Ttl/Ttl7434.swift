// Ttl7434.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl7434),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Original Java code by Marcin Orlowski (http://MarcinOrlowski.com), 2021.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// TTL 74x34: hex buffer gate.
public final class Ttl7434: AbstractTtlGate {

  /// `Ttl7434._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public static let id = "7434"

  private static let pinCount = 14
  private static let outPins = [2, 4, 6, 8, 10, 12]

  public convenience init() {
    self.init(Ttl7434.id)
  }

  /// `Ttl7434(String name)`; unused within this file set, ported for parity with upstream's
  /// public constructor.
  public init(_ name: String) {
    super.init(
      name,
      pins: Ttl7434.pinCount,
      outputPorts: Ttl7434.outPins,
      drawGates: true)
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    for i in stride(from: 1, to: 6, by: 2) {
      state.setPort(i, state.portValue(i - 1), 1)
    }
    for i in stride(from: 6, to: 12, by: 2) {
      state.setPort(i, state.portValue(i + 1), 1)
    }
  }

  public override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    let portWidth = 16
    let portHeight = 6
    let yOutput = y + (up ? 20 : 40)
    Drawgates.paintBuffer(painter, x + 30, yOutput, portWidth, portHeight)
    Drawgates.paintOutputgate(
      painter, xpin: x + 30, y: y, xoutput: x + 26, youtput: yOutput, up: up, height: height)
    Drawgates.paintSingleInputgate(
      painter, xpin: x + 10, y: y, xinput: x + 30 - portWidth, youtput: yOutput, up: up,
      height: height)
  }
}
