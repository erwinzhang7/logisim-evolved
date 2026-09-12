// Ttl74151.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl74151),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// TTL 74x151: 8-line to 1-line data selector. Model based on
// https://www.ti.com/lit/ds/symlink/sn74ls151.pdf (74LS151 datasheet).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

public final class Ttl74151: AbstractTtlGate {

  /// `Ttl74151._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public static let id = "74151"

  private static let delay = 1

  // IC pin indices as specified in the datasheet.
  private static let a = 11
  private static let b = 10
  private static let c = 9
  private static let g = 7
  private static let inputs = [4, 3, 2, 1, 15, 14, 13, 12]  // D0..D7
  private static let y = 5
  private static let w = 6
  private static let gnd = 8

  public init() {
    super.init(
      Ttl74151.id,
      pins: 16,
      outputPorts: [Ttl74151.y, Ttl74151.w],
      portNames: [
        "D3", "D2", "D1", "D0", "Y", "W", "nG",
        "C", "B", "A", "D7", "D6", "D5", "D4",
      ])
  }

  /// IC pin indices are datasheet based (1-indexed), but ports are 0-indexed with GND/VCC
  /// omitted: the port-index contract every chip in this family shares
  /// (`AbstractTtlGate.swift`'s header).
  private func pinNrToPortNr(_ dsPinNr: Int) -> Int {
    dsPinNr <= Ttl74151.gnd ? dsPinNr - 1 : dsPinNr - 2
  }

  private func getPort(_ state: any InstanceState, _ dsPinNr: Int) -> Bool {
    state.portValue(pinNrToPortNr(dsPinNr)) == .trueValue
  }

  private func setPort(_ state: any InstanceState, _ dsPinNr: Int, _ b: Bool) {
    state.setPort(pinNrToPortNr(dsPinNr), b ? .trueValue : .falseValue, Ttl74151.delay)
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    let inputs = Ttl74151.inputs.map { getPort(state, $0) }
    let select = (getPort(state, Ttl74151.c) ? 4 : 0) + (getPort(state, Ttl74151.b) ? 2 : 0)
      + (getPort(state, Ttl74151.a) ? 1 : 0)

    setPort(state, Ttl74151.y, !getPort(state, Ttl74151.g) && inputs[select])
    setPort(state, Ttl74151.w, getPort(state, Ttl74151.g) || !inputs[select])
  }

  public override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    paintBase(painter, state, drawName: false, ghost: false)

    // D0..D1.
    for i in 0...1 {
      painter.drawPolyline(
        [x + 70 - i * 20, x + 70 - i * 20, x + 34 - i * 2, x + 34 - i * 2, x + 45 + i * 10, x + 45 + i * 10],
        [
          y + height - AbstractTtlGate.pinHeight, y + 47 + i * 3, y + 47 + i * 3, y + 27 - i * 2,
          y + 27 - i * 2, y + 29,
        ])
    }

    // D2..D3.
    for i in 2...3 {
      painter.drawPolyline(
        [x + 70 - i * 20, x + 70 - i * 20, x + 45 + i * 10, x + 45 + i * 10],
        [y + height - AbstractTtlGate.pinHeight, y + 27 - i * 2, y + 27 - i * 2, y + 29])
    }

    // D4..D7.
    for i in 4...7 {
      painter.drawPolyline(
        [x - 50 + i * 20, x - 50 + i * 20, x + 45 + i * 10, x + 45 + i * 10],
        [y + AbstractTtlGate.pinHeight, y + 27 - i * 2, y + 27 - i * 2, y + 29])
    }

    // Y.
    painter.drawPolyline(
      [x + 90, x + 90, x + 75, x + 75],
      [y + height - AbstractTtlGate.pinHeight, y + 50, y + 50, y + 44])

    // W.
    painter.drawPolyline(
      [x + 110, x + 110, x + 85, x + 85],
      [y + height - AbstractTtlGate.pinHeight, y + 47, y + 47, y + 46])
    painter.drawOval(x + 84, y + 44, 2, 2)

    // Mux.
    painter.drawPolygon([x + 35, x + 125, x + 120, x + 40], [y + 29, y + 29, y + 44, y + 44])

    for i in 0...7 {
      painter.drawString(String(i), x: x + 43 + i * 10, y: y + 34)
    }

    painter.drawString("S", x: x + 119, y: y + 36)
    painter.drawString("E", x: x + 116, y: y + 43)

    // Enable.
    painter.drawPolyline(
      [x + 130, x + 130, x + 123], [y + height - AbstractTtlGate.pinHeight, y + 41, y + 41])
    painter.drawOval(x + 121, y + 40, 2, 2)

    // Select A.
    painter.drawPolyline([x + 110, x + 110, x + 112], [y + AbstractTtlGate.pinHeight, y + 9, y + 11])

    // Select B.
    painter.drawPolyline([x + 130, x + 130, x + 132], [y + AbstractTtlGate.pinHeight, y + 9, y + 11])

    // Select C.
    painter.drawPolyline([x + 150, x + 150, x + 148], [y + AbstractTtlGate.pinHeight, y + 9, y + 11])

    // Select bus.
    painter.withStrokeWidth(2) {
      painter.drawLine(x + 112, y + 11, x + 148, y + 11)
      painter.drawPolyline([x + 134, x + 134, x + 124], [y + 11, y + 34, y + 34])
    }
  }
}
