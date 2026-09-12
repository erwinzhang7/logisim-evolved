// Ttl74153.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl74153),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// TTL 74x153: dual 4-line to 1-line data selector. Model based on
// https://www.ti.com/lit/ds/symlink/sn74ls153.pdf (74LS153 datasheet).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

public final class Ttl74153: AbstractTtlGate {

  /// `Ttl74153._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.", upstream's own comment.
  public static let id = "74153"

  private static let delay = 1

  // IC pin indices as specified in the datasheet.
  private static let s0 = 14
  private static let s1 = 2
  private static let l1En = 1
  private static let l1D = [6, 5, 4, 3]  // D0..D3
  private static let l2En = 15
  private static let l2D = [10, 11, 12, 13]  // D0..D3
  private static let l1Y = 7
  private static let l2Y = 9
  private static let gnd = 8

  public init() {
    super.init(
      Ttl74153.id,
      pins: 16,
      outputPorts: [Ttl74153.l1Y, Ttl74153.l2Y],
      portNames: [
        "n1E", "S1", "1D3", "1D2", "1D1", "1D0", "1Y",
        "2Y", "2D0", "2D1", "2D2", "2D3", "S0", "n2E",
      ],
      height: 80)
  }

  /// IC pin indices are datasheet based (1-indexed), but ports are 0-indexed with GND/VCC
  /// omitted: the port-index contract every chip in this family shares
  /// (`AbstractTtlGate.swift`'s header).
  private func pinNrToPortNr(_ dsPinNr: Int) -> Int {
    dsPinNr <= Ttl74153.gnd ? dsPinNr - 1 : dsPinNr - 2
  }

  private func getPort(_ state: any InstanceState, _ dsPinNr: Int) -> Bool {
    state.portValue(pinNrToPortNr(dsPinNr)) == .trueValue
  }

  private func setPort(_ state: any InstanceState, _ dsPinNr: Int, _ b: Bool) {
    state.setPort(pinNrToPortNr(dsPinNr), b ? .trueValue : .falseValue, Ttl74153.delay)
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    let data1 = Ttl74153.l1D.map { getPort(state, $0) }
    let data2 = Ttl74153.l2D.map { getPort(state, $0) }
    let select = (getPort(state, Ttl74153.s1) ? 2 : 0) + (getPort(state, Ttl74153.s0) ? 1 : 0)

    setPort(state, Ttl74153.l1Y, !getPort(state, Ttl74153.l1En) && data1[select])
    setPort(state, Ttl74153.l2Y, !getPort(state, Ttl74153.l2En) && data2[select])
  }

  /// `drawMux(Graphics2D, int, int, int, int, Direction)`. `x`/`y` are the trapezoid's
  /// bottom-left corner; `top`/`bottom` are the package's own edges; `pointingNorth` selects
  /// which of upstream's two `Direction` branches (only NORTH/SOUTH are supported) to draw.
  private func drawMux(
    _ painter: SceneBuilder, x: Int, y: Int, top: Int, bottom: Int, pointingNorth: Bool
  ) {
    let mux: [(Int, Int)] =
      pointingNorth
      ? [(x, y), (x + 80, y), (x + 74, y - 18), (x + 6, y - 18)]
      : [(x, y), (x + 80, y), (x + 74, y + 18), (x + 6, y + 18)]

    painter.withStrokeWidth(2) {
      painter.drawPolygon(mux.map { $0.0 }, mux.map { $0.1 })
    }

    let metrics = painter.fontMetrics()
    let height = metrics.ascent

    for i in 0..<4 {
      let str = String(3 - i)
      let width = painter.textBoundsInUserSpace(str, x: 0, y: 0).width

      if pointingNorth {
        painter.drawLine(x + 10 + i * 20, bottom - AbstractTtlGate.pinHeight, x + 10 + i * 20, y + 1)
        painter.drawString(str, x: x + 10 + i * 20 - width / 2, y: y - 1)
      } else {
        painter.drawLine(x + 10 + i * 20, top + AbstractTtlGate.pinHeight, x + 10 + i * 20, y - 1)
        painter.drawString(str, x: x + 10 + i * 20 - width / 2, y: y + height - 1)
      }
    }

    let sWidth = painter.textBoundsInUserSpace("S", x: 0, y: 0).width
    let eWidth = painter.textBoundsInUserSpace("E", x: 0, y: 0).width
    if pointingNorth {
      painter.drawString("S", x: x + 1 + sWidth / 2, y: y - 8 + height / 2)
      painter.drawString("E", x: x + 3 + eWidth / 2, y: y - 14 + height / 2)
      painter.drawOval(x - 3 + eWidth / 2, y - 18 + height / 2, 4, 4)
      painter.drawLine(x + 40, y - 19, x + 40, y - 22)
    } else {
      painter.drawString("S", x: x + 1 + sWidth / 2, y: y + 2 + height)
      painter.drawString("E", x: x + 3 + eWidth / 2, y: y + 8 + height)
      painter.drawOval(x - 3 + eWidth / 2, y + 18 - height, 4, 4)
      painter.drawLine(x + 40, y + 19, x + 40, y + 22)
    }
  }

  public override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    paintBase(painter, state, drawName: false, ghost: false)

    drawMux(painter, x: x + 40, y: y + 65, top: y, bottom: y + height, pointingNorth: true)
    // Y1.
    painter.drawPolyline(
      [x + 80, x + 130, x + 130],
      [y + height - 37, y + height - 37, y + height - AbstractTtlGate.pinHeight])
    // E1.
    painter.drawPolyline(
      [x + 10, x + 10, x + 38],
      [y + height - AbstractTtlGate.pinHeight, y + height - 28, y + height - 28])

    drawMux(painter, x: x + 60, y: y + 15, top: y, bottom: y + height, pointingNorth: false)
    // Y2.
    painter.drawPolyline([x + 100, x + 150, x + 150], [y + 37, y + 37, y + AbstractTtlGate.pinHeight])
    // E2.
    painter.drawPolyline([x + 30, x + 30, x + 58], [y + AbstractTtlGate.pinHeight, y + 28, y + 28])

    // Bus entries for S0, S1.
    painter.drawPolyline(
      [x + 30, x + 30, x + 33], [y + height - AbstractTtlGate.pinHeight, y + 68, y + 65])
    painter.drawPolyline([x + 50, x + 50, x + 53], [y + AbstractTtlGate.pinHeight, y + 12, y + 15])

    // S bus.
    painter.withStrokeWidth(2) {
      painter.drawPolyline([x + 33, x + 33, x + 53, x + 53], [y + 65, y + 40, y + 40, y + 15])
      painter.drawLine(x + 33, y + height - 22, x + 41, y + height - 22)
      painter.drawLine(x + 53, y + 22, x + 61, y + 22)
    }
  }
}
