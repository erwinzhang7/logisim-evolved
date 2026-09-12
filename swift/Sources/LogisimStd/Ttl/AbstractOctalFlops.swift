// AbstractOctalFlops.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.AbstractOctalFlops),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Backs `Ttl74273` (octal D flip-flop with async clear, `hasWe == false`) and `Ttl74377`
// (octal D flip-flop with clock enable, `hasWe == true`); each just supplies the pin table and
// calls `setWe` from its own `init`, exactly as the Java constructors call `super.setWe(...)`
// after `super(...)`.
//
// `propagateTtl` addresses fixed port indices (0-17), same reasoning as
// `AbstractOctalBuffers.swift`'s header: both chips share the 20-pin layout with no unused pins
// and `VCC_GND` off by default, so the squeeze always produces this numbering.
//
// ── Not ported ──────────────────────────────────────────────────────────────────────────────
//
//   * `Poker` (mouse-driven bit toggling on the internal register): depends on
//     `getTranslatedTtlXY`, which is itself paint-only and not ported (`AbstractTtlGate.swift`'s
//     header). No `Ttl*.swift` file in this family ports a poker; consistent with that.
//   * `checkForGatedClocks`/`clockPinIndex`, HDL/FPGA backlog (D11).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.ttl.AbstractOctalFlops`.
open class AbstractOctalFlops: AbstractTtlGate {

  private var hasWe = false

  public init(_ name: String, pins: Int, outputPorts: [Int], portNames: [String]) {
    super.init(name, pins: pins, outputPorts: outputPorts, portNames: portNames, height: 80)
  }

  /// `setWe(boolean)`.
  public func setWe(_ haswe: Bool) {
    hasWe = haswe
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    let data: TtlRegisterData
    if let existing = state.data as? TtlRegisterData {
      data = existing
    } else {
      data = TtlRegisterData(width: BitWidth.known(8))
      state.setData(data)
    }
    var changed = false
    let triggered = try data.clock.updateClock(state.portValue(9))
    var values = data.getValue().getAll()
    if hasWe {
      if triggered && state.portValue(0) == .falseValue {
        changed = true
        values[0] = state.portValue(2)
        values[1] = state.portValue(3)
        values[2] = state.portValue(6)
        values[3] = state.portValue(7)
        values[4] = state.portValue(11)
        values[5] = state.portValue(12)
        values[6] = state.portValue(15)
        values[7] = state.portValue(16)
      }
    } else {
      if state.portValue(0) == .falseValue {
        values = Value.createKnown(8, 0).getAll()
        changed = true
      } else if triggered {
        changed = true
        values[0] = state.portValue(2)
        values[1] = state.portValue(3)
        values[2] = state.portValue(6)
        values[3] = state.portValue(7)
        values[4] = state.portValue(11)
        values[5] = state.portValue(12)
        values[6] = state.portValue(15)
        values[7] = state.portValue(16)
      }
    }
    if changed {
      data.setValue(try Value.create(values))
    }
    state.setPort(1, data.getValue().get(0), 8)
    state.setPort(4, data.getValue().get(1), 8)
    state.setPort(5, data.getValue().get(2), 8)
    state.setPort(8, data.getValue().get(3), 8)
    state.setPort(10, data.getValue().get(4), 8)
    state.setPort(13, data.getValue().get(5), 8)
    state.setPort(14, data.getValue().get(6), 8)
    state.setPort(17, data.getValue().get(7), 8)
  }

  public override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    paintBase(painter, state, drawName: false, ghost: false)
    for i in 0..<8 {
      painter.drawRect(x + 90 + i * 10, y + 25, 10, 30)
    }
    painter.drawLine(x + 85, y + 30, x + 90, y + 30)
    painter.drawLine(x + 85, y + 50, x + 90, y + 50)
    painter.drawLine(x + 85, y + 25, x + 85, y + 30)
    painter.drawLine(x + 85, y + 50, x + 85, y + 55)
    painter.drawLine(x + 65, y + 55, x + 85, y + 55)
    painter.drawLine(x + 65, y + 25, x + 85, y + 25)
    painter.drawLine(x + 65, y + 25, x + 65, y + 55)
    painter.drawOval(x + 68, y + 55, 4, 4)

    painter.drawLine(x + 78, y + 55, x + 80, y + 50)
    painter.drawLine(x + 82, y + 55, x + 80, y + 50)
    painter.drawLine(x + 190, y + AbstractTtlGate.pinHeight, x + 190, y + 60)
    painter.drawLine(x + 180, y + 60, x + 190, y + 60)
    painter.drawLine(x + 180, y + 60, x + 180, y + 70)
    painter.drawLine(x + 80, y + 70, x + 180, y + 70)
    painter.drawLine(x + 80, y + 55, x + 80, y + 70)
    painter.drawLine(x + 10, y + height - AbstractTtlGate.pinHeight, x + 10, y + 60)
    painter.drawLine(x + 10, y + 60, x + 70, y + 60)
    painter.drawLine(x + 70, y + 59, x + 70, y + 60)

    painter.withTransform(.rotation(-Double.pi / 2, aroundX: Double(x), y: Double(y))) {
      if hasWe {
        painter.drawString("1C2", x: x - 49, y: y + 83)
        painter.drawString("G1", x: x - 54, y: y + 73)
        painter.drawString("2D", x: x - 54, y: y + 98)
      } else {
        painter.drawString("C1", x: x - 49, y: y + 83)
        painter.drawString("R", x: x - 54, y: y + 73)
        painter.drawString("1D", x: x - 54, y: y + 98)
      }
    }

    for i in 0..<8 {
      painter.drawLine(x + 95 + i * 10, y + 20, x + 95 + i * 10, y + 25)
      painter.drawLine(x + 95 + i * 10, y + 20, x + 95 + i * 10 + 3, y + 17)
      painter.drawLine(x + 95 + i * 10, y + 55, x + 95 + i * 10, y + 60)
      painter.drawLine(x + 95 + i * 10, y + 60, x + 95 + i * 10 + 3, y + 63)
    }
    let dincr = [20, 60, 20, 0]
    var dpos1 = 50
    var dpos2 = 150
    let qincr = [60, 20, 60, 0]
    var qpos1 = 30
    var qpos2 = 170
    for i in 0..<4 {
      painter.drawLine(x + dpos1, y + height - AbstractTtlGate.pinHeight, x + dpos1, y + 66)
      painter.drawLine(x + dpos1, y + 66, x + dpos1 + 3, y + 63)
      dpos1 += dincr[i]
      painter.drawLine(x + dpos2, y + AbstractTtlGate.pinHeight, x + dpos2, y + 10)
      painter.drawLine(x + dpos2, y + 10, x + dpos2 + 3, y + 13)
      dpos2 -= dincr[i]
      painter.drawLine(x + qpos1, y + height - AbstractTtlGate.pinHeight, x + qpos1, y + 70)
      painter.drawLine(x + qpos1, y + 70, x + qpos1 + 3, y + 67)
      qpos1 += qincr[i]
      painter.drawLine(x + qpos2, y + AbstractTtlGate.pinHeight, x + qpos2, y + 14)
      painter.drawLine(x + qpos2, y + 14, x + qpos2 + 3, y + 17)
      qpos2 -= qincr[i]
    }
    painter.withStrokeWidth(2) {
      painter.drawLine(x + 33, y + 17, x + 173, y + 17)
      painter.drawLine(x + 33, y + 67, x + 173, y + 67)
      painter.drawLine(x + 30, y + 20, x + 33, y + 17)
      painter.drawLine(x + 30, y + 64, x + 33, y + 67)
      painter.drawLine(x + 30, y + 20, x + 30, y + 64)
      painter.drawLine(x + 53, y + 13, x + 153, y + 13)
      painter.drawLine(x + 53, y + 63, x + 168, y + 63)
      painter.drawLine(x + 46, y + 20, x + 53, y + 13)
      painter.drawLine(x + 46, y + 57, x + 53, y + 63)
      painter.drawLine(x + 46, y + 20, x + 46, y + 57)
    }
    drawState(painter, x: x, y: y, data: state.data as? TtlRegisterData)
  }

  /// `drawState(Graphics2D, int, int, TtlRegisterData)`.
  ///
  /// **Deviation (mechanism).** Upstream's second `g.rotate(-Math.PI/2, x, y)` does not undo the
  /// first, both rotate by the same sign, leaving the context at -180°, but nothing draws
  /// through this `g` afterward in `paintInternal`, so the double rotation is unobservable.
  /// `withTransform` brackets the whole function to the *correct* single -90° instead, which
  /// renders identically for this call and additionally can't leak a stray rotation into a
  /// sibling component in the shared scene.
  private func drawState(_ painter: SceneBuilder, x: Int, y: Int, data: TtlRegisterData?) {
    guard let data else { return }
    painter.withTransform(.rotation(-Double.pi / 2, aroundX: Double(x), y: Double(y))) {
      for i in 0..<8 {
        let bit = data.getValue().get(i)
        painter.withColor(.palette(bit.paletteIndex)) {
          painter.fillOval(x - 44, y + 91 + i * 10, 8, 8)
        }
        painter.withColor(.white) {
          painter.drawCenteredText(bit.toDisplayString(), x: x - 41, y: y + 94 + i * 10)
        }
      }
    }
  }
}
