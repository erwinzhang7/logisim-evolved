// Ttl74245.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl74245),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// TTL 74x245: octal bus transceiver with three-state outputs. Model based on
// https://www.ti.com/product/SN74LS245 datasheet.
//
// Unlike the `AbstractOctalBuffers` family (74240/241/244), the A/B pins here are genuinely
// bidirectional, driven one way when `DIR` is high, the other when low, so this extends
// `AbstractTtlGate` directly and declares all 16 data pins `inoutPorts` rather than
// `outputPorts`, exactly as upstream's constructor does.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

public final class Ttl74245: AbstractTtlGate {

  /// `Ttl74245._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public static let id = "74245"

  public init() {
    super.init(
      Ttl74245.id,
      pins: 20,
      inoutPorts: [2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17, 18],
      portNames: [
        "DIR", "A1", "A2", "A3", "A4", "A5", "A6", "A7", "A8",
        "B8", "B7", "B6", "B5", "B4", "B3", "B2", "B1", "nOE",
      ])
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    if state.portValue(17) == .trueValue {
      // Output disabled
      for port in 1...16 { state.setPort(port, .unknownValue, 1) }
    } else if state.portValue(0) == .trueValue {
      // DIR HIGH = A->B
      for port in 1...8 { state.setPort(port, .unknownValue, 1) }
      state.setPort(9, state.portValue(8), 1)
      state.setPort(10, state.portValue(7), 1)
      state.setPort(11, state.portValue(6), 1)
      state.setPort(12, state.portValue(5), 1)
      state.setPort(13, state.portValue(4), 1)
      state.setPort(14, state.portValue(3), 1)
      state.setPort(15, state.portValue(2), 1)
      state.setPort(16, state.portValue(1), 1)
    } else {
      // DIR LOW = B->A
      state.setPort(1, state.portValue(16), 1)
      state.setPort(2, state.portValue(15), 1)
      state.setPort(3, state.portValue(14), 1)
      state.setPort(4, state.portValue(13), 1)
      state.setPort(5, state.portValue(12), 1)
      state.setPort(6, state.portValue(11), 1)
      state.setPort(7, state.portValue(10), 1)
      state.setPort(8, state.portValue(9), 1)
      for port in 9...16 { state.setPort(port, .unknownValue, 1) }
    }
  }

  public override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    paintBase(painter, state, drawName: false, ghost: false)
    drawBuffers(painter, x: x, y: y, height: height)
  }

  private func drawBuffers(_ painter: SceneBuilder, x: Int, y: Int, height: Int) {
    // DIR.
    painter.drawPolyline(
      [x + 10, x + 10, x + 17, x + 17],
      [y + height - AbstractTtlGate.pinHeight, y + 10, y + 10, y + 13])
    painter.drawOval(x + 16, y + 13, 2, 2)

    painter.fillOval(x + 9, y + height - 11, 2, 2)
    painter.drawPolyline(
      [x + 10, x + 17, x + 17], [y + height - 10, y + height - 10, y + height - 15])

    // nOE.
    painter.drawPolyline(
      [x + 30, x + 30, x + 27, x + 23, x + 23],
      [
        y + AbstractTtlGate.pinHeight, y + height - 13, y + height - 10, y + height - 10,
        y + height - 13,
      ])
    painter.drawOval(x + 22, y + height - 15, 2, 2)

    painter.fillOval(x + 29, y + 9, 2, 2)
    painter.drawPolyline([x + 30, x + 23, x + 23], [y + 10, y + 10, y + 13])
    painter.drawOval(x + 22, y + 13, 2, 2)

    // A enable.
    painter.drawPolyline(
      [x + 15, x + 15, x + 25, x + 25],
      [y + height - 20, y + height - 15, y + height - 15, y + height - 20])
    painter.drawCenteredArc(x + 20, y + height - 20, 5, 0, 180)
    painter.drawPolyline(
      [x + 20, x + 20, x + 175], [y + height - 25, y + height - 28, y + height - 28])

    // A buffers.
    var i = x + 30
    while i < x + 190 {
      // Input.
      painter.drawPolyline(
        [i, i + 3, i + 10, i + 10],
        [y + height - AbstractTtlGate.pinHeight, y + height - 10, y + height - 10, y + height - 17])

      // Buffer.
      painter.drawPolyline(
        [i + 6, i + 10, i + 14, i + 6], [y + height - 17, y + height - 23, y + height - 17, y + height - 17])

      // Enable.
      if i < x + 170 {
        painter.fillOval(i + 4, y + height - 29, 2, 2)
      }
      painter.drawPolyline([i + 5, i + 5, i + 8], [y + height - 28, y + height - 21, y + height - 21])

      // Output.
      painter.drawPolyline([i + 10, i + 10, i + 16, i + 20], [y + height - 23, y + 16, y + 10, y + 10])
      painter.fillOval(i + 19, y + 9, 2, 2)
      i += 20
    }

    // B enable.
    painter.drawPolyline([x + 15, x + 15, x + 25, x + 25], [y + 20, y + 15, y + 15, y + 20])
    painter.drawCenteredArc(x + 20, y + 20, 5, 180, 180)
    painter.drawPolyline([x + 20, x + 20, x + 185], [y + 25, y + 28, y + 28])

    // B buffers.
    i = x + 50
    while i < x + 210 {
      // Input.
      painter.drawLine(i, y + AbstractTtlGate.pinHeight, i, y + 17)

      // Buffer.
      painter.drawPolyline([i + 4, i, i - 4, i + 4], [y + 17, y + 23, y + 17, y + 17])

      // Enable.
      if i < x + 190 {
        painter.fillOval(i - 6, y + 27, 2, 2)
      }
      painter.drawPolyline([i - 5, i - 5, i - 2], [y + 28, y + 21, y + 21])

      // Output.
      painter.drawPolyline([i, i, i - 6, i - 10], [y + 23, y + height - 16, y + height - 10, y + height - 10])
      painter.fillOval(i - 11, y + height - 11, 2, 2)
      i += 20
    }
  }
}
