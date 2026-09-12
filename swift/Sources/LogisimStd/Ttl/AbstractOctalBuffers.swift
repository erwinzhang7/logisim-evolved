// AbstractOctalBuffers.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.AbstractOctalBuffers),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// TTL 74x24x octal buffers/line drivers with three-state outputs. Backs `Ttl74240`, `Ttl74241`
// and `Ttl74244`; each just supplies the pin table and calls `setOutputInverted`/
// `setEnableInverted` from its own `init`, exactly as the Java constructors call
// `super.setOutputInverted(...)`/`super.setEnableInverted(...)` after `super(...)`.
//
// `propagateTtl` addresses fixed port indices (0-17) rather than recomputing them: every chip
// in this family shares the same 20-pin layout with no unused pins and `VCC_GND` off by
// default, so the port-index contract (`AbstractTtlGate.swift`'s header) always squeezes to
// exactly this numbering. Transcribed as literal indices, matching upstream.
//

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.ttl.AbstractOctalBuffers`.
open class AbstractOctalBuffers: AbstractTtlGate {

  private var ch1OutputInverted = false
  private var ch1EnableInverted = false
  private var ch2OutputInverted = false
  private var ch2EnableInverted = false

  public init(_ name: String, pins: Int, outputPorts: [Int], portNames: [String]) {
    super.init(name, pins: pins, outputPorts: outputPorts, portNames: portNames)
  }

  /// `setOutputInverted(boolean, boolean)`.
  public func setOutputInverted(_ ch1Invert: Bool, _ ch2Invert: Bool) {
    ch1OutputInverted = ch1Invert
    ch2OutputInverted = ch2Invert
  }

  /// `setEnableInverted(boolean, boolean)`.
  public func setEnableInverted(_ ch1Invert: Bool, _ ch2Invert: Bool) {
    ch1EnableInverted = ch1Invert
    ch2EnableInverted = ch2Invert
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    if state.portValue(0) == (ch1EnableInverted ? .trueValue : .falseValue) {
      // Channel 1 disabled
      state.setPort(16, .unknownValue, 1)
      state.setPort(14, .unknownValue, 1)
      state.setPort(12, .unknownValue, 1)
      state.setPort(10, .unknownValue, 1)
    } else if ch1OutputInverted {
      // Channel 1 enabled, inverted
      state.setPort(16, state.portValue(1).not(), 1)
      state.setPort(14, state.portValue(3).not(), 1)
      state.setPort(12, state.portValue(5).not(), 1)
      state.setPort(10, state.portValue(7).not(), 1)
    } else {
      // Channel 1 enabled, non-inverted
      state.setPort(16, state.portValue(1), 1)
      state.setPort(14, state.portValue(3), 1)
      state.setPort(12, state.portValue(5), 1)
      state.setPort(10, state.portValue(7), 1)
    }
    if state.portValue(17) == (ch2EnableInverted ? .trueValue : .falseValue) {
      // Channel 2 disabled
      state.setPort(8, .unknownValue, 1)
      state.setPort(6, .unknownValue, 1)
      state.setPort(4, .unknownValue, 1)
      state.setPort(2, .unknownValue, 1)
    } else if ch2OutputInverted {
      // Channel 2 enabled, inverted
      state.setPort(8, state.portValue(9).not(), 1)
      state.setPort(6, state.portValue(11).not(), 1)
      state.setPort(4, state.portValue(13).not(), 1)
      state.setPort(2, state.portValue(15).not(), 1)
    } else {
      // Channel 2 enabled, non-inverted
      state.setPort(8, state.portValue(9), 1)
      state.setPort(6, state.portValue(11), 1)
      state.setPort(4, state.portValue(13), 1)
      state.setPort(2, state.portValue(15), 1)
    }
  }

  public override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    paintBase(painter, state, drawName: false, ghost: false)
    drawBuffers(painter, x: x, y: y, height: height)
  }

  private func drawBuffers(_ painter: SceneBuilder, x: Int, y: Int, height: Int) {
    // Channel 1 enable.
    if ch1EnableInverted {
      painter.drawPolyline(
        [x + 10, x + 10, x + 20, x + 20],
        [
          y + height - AbstractTtlGate.pinHeight, y + height - 10, y + height - 10,
          y + height - 13,
        ])
      painter.drawOval(x + 18, y + height - 17, 4, 4)
    } else {
      painter.drawPolyline(
        [x + 10, x + 10, x + 20, x + 20],
        [
          y + height - AbstractTtlGate.pinHeight, y + height - 10, y + height - 10,
          y + height - 17,
        ])
    }

    painter.drawPolyline(
      [x + 15, x + 20, x + 25, x + 15], [y + height - 17, y + height - 25, y + height - 17, y + height - 17])

    painter.drawPolyline(
      [x + 20, x + 20, x + 155], [y + height - 25, y + height - 28, y + height - 28])

    // Channel 1 buffers.
    var i = x + 30
    while i < x + 190 {
      // Input.
      painter.drawPolyline(
        [i, i, i + 10, i + 10],
        [y + height - AbstractTtlGate.pinHeight, y + height - 10, y + height - 10, y + height - 16])

      // Buffer.
      painter.drawPolyline(
        [i + 6, i + 10, i + 14, i + 6], [y + height - 16, y + height - 22, y + height - 16, y + height - 16])

      // Enable.
      if i < x + 150 {
        painter.fillOval(i + 4, y + height - 29, 2, 2)
      }
      painter.drawPolyline([i + 5, i + 5, i + 8], [y + height - 28, y + height - 20, y + height - 20])

      // Output.
      if ch1OutputInverted {
        painter.drawOval(i + 9, y + height - 25, 2, 2)
        painter.drawPolyline(
          [i + 10, i + 10, i + 20, i + 20],
          [y + height - 25, y + 10, y + 10, y + AbstractTtlGate.pinHeight])
      } else {
        painter.drawPolyline(
          [i + 10, i + 10, i + 20, i + 20],
          [y + height - 22, y + 10, y + 10, y + AbstractTtlGate.pinHeight])
      }
      i += 40
    }

    // Channel 2 enable.
    if ch2EnableInverted {
      painter.drawLine(x + 30, y + AbstractTtlGate.pinHeight, x + 30, y + 12)
      painter.drawOval(x + 28, y + 13, 4, 4)
    } else {
      painter.drawLine(x + 30, y + AbstractTtlGate.pinHeight, x + 30, y + 17)
    }

    painter.drawPolyline([x + 25, x + 30, x + 35, x + 25], [y + 17, y + 25, y + 17, y + 17])

    painter.drawPolyline([x + 30, x + 30, x + 175], [y + 25, y + 28, y + 28])

    // Channel 2 buffers.
    i = x + 70
    while i < x + 230 {
      // Input.
      painter.drawPolyline([i, i, i - 10, i - 10], [y + AbstractTtlGate.pinHeight, y + 10, y + 10, y + 16])

      // Buffer.
      painter.drawPolyline([i - 6, i - 10, i - 14, i - 6], [y + 16, y + 22, y + 16, y + 16])

      // Enable.
      if i < x + 190 {
        painter.fillOval(i - 16, y + 27, 2, 2)
      }
      painter.drawPolyline([i - 15, i - 15, i - 12], [y + 28, y + 20, y + 20])

      // Output.
      if ch2OutputInverted {
        painter.drawOval(i - 11, y + 23, 2, 2)
        painter.drawPolyline(
          [i - 10, i - 10, i - 20, i - 20],
          [y + 25, y + height - 10, y + height - 10, y + height - AbstractTtlGate.pinHeight])
      } else {
        painter.drawPolyline(
          [i - 10, i - 10, i - 20, i - 20],
          [y + 22, y + height - 10, y + height - 10, y + height - AbstractTtlGate.pinHeight])
      }
      i += 40
    }
  }
}
