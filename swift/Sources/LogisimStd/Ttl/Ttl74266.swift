// Ttl74266.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl74266),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// TTL 74x266: quad 2-input XNOR gate, open-collector. Model based on
// https://www.ti.com/product/SN74LS266 datasheet.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

public final class Ttl74266: AbstractTtlGate {

  /// `Ttl74266._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public static let id = "74266"

  public init() {
    super.init(Ttl74266.id, pins: 14, outputPorts: [3, 6, 8, 11], drawGates: true)
  }

  /// Open-collector: the gate can only pull low or float, never drive high, so a `TRUE` XNOR
  /// result (both inputs agree) becomes `UNKNOWN` (floating) rather than `TRUE`, while a
  /// `FALSE` result still pulls the line low. Transcribed from upstream's
  /// `... .not() == Value.TRUE ? Value.UNKNOWN : Value.FALSE` exactly.
  public override func propagateTtl(_ state: any InstanceState) throws {
    for i in stride(from: 2, to: 6, by: 3) {
      let result = state.portValue(i - 1).xor(state.portValue(i - 2)).not()
      state.setPort(i, result == .trueValue ? .unknownValue : .falseValue, 1)
    }
    for i in stride(from: 6, to: 12, by: 3) {
      let result = state.portValue(i + 1).xor(state.portValue(i + 2)).not()
      state.setPort(i, result == .trueValue ? .unknownValue : .falseValue, 1)
    }
  }

  public override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    let portwidth = 18
    let portheight = 15
    let youtput = y + (up ? 20 : 40)
    Drawgates.paintXor(painter, x + 44, youtput, portwidth - 4, portheight, true)
    Drawgates.paintOutputgate(
      painter, xpin: x + 50, y: y, xoutput: x + 48, youtput: youtput, up: up, height: height)
    Drawgates.paintOpenCollector(painter, x + 52, youtput)
    Drawgates.paintDoubleInputgate(
      painter, rightPinX: x + 30, y: y, inputX: x + 44 - portwidth, outputY: youtput,
      portHeight: portheight, up: up, rightToLeft: false, height: height)
  }
}
