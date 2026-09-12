// Ttl74541.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl74541),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// TTL 74x541: octal buffer with three-state outputs, dual active-low output enable. Model
// based on https://www.ti.com/lit/ds/symlink/sn74f541.pdf (74F541 datasheet).
//
// Unlike the `AbstractOctalBuffers` family, this chip has a *single* 8-bit data path gated by
// two ANDed enables rather than two independent 4-bit channels, so it extends `AbstractTtlGate`
// directly, matching upstream.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

public final class Ttl74541: AbstractTtlGate {

  /// `Ttl74541._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public static let id = "74541"

  private static let delay = 1

  // IC pin indices as specified in the datasheet.
  private static let oe1: Int = 1
  private static let oe2: Int = 19
  private static let inputs: [Int] = [2, 3, 4, 5, 6, 7, 8, 9]
  private static let outputs: [Int] = [18, 17, 16, 15, 14, 13, 12, 11]
  private static let gnd: Int = 10

  public init() {
    super.init(
      Ttl74541.id,
      pins: 20,
      outputPorts: Ttl74541.outputs,
      portNames: [
        "nOE1", "A1", "A2", "A3", "A4", "A5", "A6", "A7", "A8",
        "Y8", "Y7", "Y6", "Y5", "Y4", "Y3", "Y2", "Y1", "nOE2",
      ])
  }

  /// IC pin indices are datasheet based (1-indexed), but ports are 0-indexed with GND/VCC
  /// omitted: the port-index contract every chip in this family shares
  /// (`AbstractTtlGate.swift`'s header).
  private func pinNrToPortNr(_ dsPinNr: Int) -> Int {
    dsPinNr <= Ttl74541.gnd ? dsPinNr - 1 : dsPinNr - 2
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    let active =
      state.portValue(pinNrToPortNr(Ttl74541.oe1)) == .falseValue
      && state.portValue(pinNrToPortNr(Ttl74541.oe2)) == .falseValue
    for i in 0..<8 {
      let outPort = pinNrToPortNr(Ttl74541.outputs[i])
      let inPort = pinNrToPortNr(Ttl74541.inputs[i])
      state.setPort(outPort, active ? state.portValue(inPort) : .unknownValue, Ttl74541.delay)
    }
  }

  /// `drawBuffer(Graphics2D, int, int, int, int)`. `x`/`y` are the tip of the buffer triangle;
  /// `top`/`bottom` are the package's own top/bottom edges (not the buffer's), used only to
  /// anchor the input/output stub lines against the pin rows.
  private func drawBuffer(_ painter: SceneBuilder, x: Int, y: Int, top: Int, bottom: Int) {
    // Input.
    painter.drawPolyline(
      [x - 10, x - 10, x, x], [bottom - AbstractTtlGate.pinHeight, y + 20, y + 20, y + 10])
    // Buffer.
    painter.drawPolyline([x, x + 5, x - 5, x], [y, y + 10, y + 10, y])
    // Output.
    painter.drawPolyline(
      [x + 10, x + 10, x, x], [top + AbstractTtlGate.pinHeight, y - 5, y - 5, y])
    // Control.
    painter.drawPolyline([x - 10, x - 10, x - 3], [y + 15, y + 5, y + 5])
  }

  public override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    paintBase(painter, state, drawName: false, ghost: false)

    for i in 0..<8 {
      drawBuffer(painter, x: x + 40 + i * 20, y: y + 25, top: y, bottom: y + height)
    }

    // OE1.
    painter.drawPolyline(
      [x + 10, x + 10, x + 13], [y + height - AbstractTtlGate.pinHeight, y + 43, y + 43])
    painter.drawOval(x + 13, y + 42, 2, 2)

    // OE2.
    painter.drawPolyline(
      [x + 30, x + 30, x + 10, x + 10, x + 13],
      [y + AbstractTtlGate.pinHeight, y + 20, y + 20, y + 37, y + 37])
    painter.drawOval(x + 13, y + 36, 2, 2)

    // AND.
    painter.drawPolyline([x + 22, x + 15, x + 15, x + 22], [y + 35, y + 35, y + 45, y + 45])
    painter.drawArc(x + 17, y + 35, 10, 10, 270, 180)
    painter.drawLine(x + 27, y + 40, x + 170, y + 40)
  }
}
