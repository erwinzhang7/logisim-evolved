// Ttl7413.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl7413),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// TTL 74x13: dual 4-input NAND gate (Schmitt trigger in the datasheet; Logisim does not model
/// hysteresis, so it behaves as a plain NAND).
///
/// `open`, not `final`: `Ttl7418` and `Ttl7420` extend this unchanged, and `Ttl7421` extends it
/// with `inverted = false` (dual 4-input AND).
open class Ttl7413: AbstractTtlGate {

  /// `Ttl7413._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.": upstream's own comment.
  ///
  /// **Deviation (mechanism).** `class var`, not `static let`: see `Ttl7400.id` for why:
  /// `Ttl7418`/`Ttl7420`/`Ttl7421` override it. No behavioural difference from Java's
  /// independent `_ID` fields.
  open class var id: String { "7413" }

  private static let pinCount = 14
  private static let outPorts = [6, 8]
  private static let unusedPorts = [3, 11]
  private static let portNames = [
    "A0", "B0", "C0", "D0", "Y0", "Y1", "D1", "C1", "B1", "A1",
  ]

  private let inverted: Bool

  /// Upstream field default (`inverted = true`), reached only by `super(_ID, ...)`-style
  /// no-arg construction.
  public convenience init() {
    self.init(Ttl7413.id, inverted: true)
  }

  /// `Ttl7413(String name)`; used by `Ttl7418`/`Ttl7420` (`inverted` keeps the default `true`).
  public convenience init(_ name: String) {
    self.init(name, inverted: true)
  }

  /// `Ttl7413(String name, boolean inv)`; used directly by `Ttl7421` (`inverted = false`).
  public init(_ name: String, inverted: Bool) {
    self.inverted = inverted
    super.init(
      name,
      pins: Ttl7413.pinCount,
      outputPorts: Ttl7413.outPorts,
      notUsedPins: Ttl7413.unusedPorts,
      portNames: Ttl7413.portNames)
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    var val =
      state.portValue(0)
      .and(state.portValue(1).and(state.portValue(2).and(state.portValue(3))))
    state.setPort(4, inverted ? val.not() : val, 3)

    val =
      state.portValue(6)
      .and(state.portValue(7).and(state.portValue(8).and(state.portValue(9))))
    state.setPort(5, inverted ? val.not() : val, 4)
  }

  open override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    paintBase(painter, state, drawName: false, ghost: false)
    Drawgates.paintAnd(painter, x + 125, y + 20, 10, 10, inverted)
    Drawgates.paintAnd(painter, x + 105, y + 40, 10, 10, inverted)
    let offset = inverted ? 0 : -4
    painter.drawLine(x + 129 + offset, y + 20, x + 130, y + 20)
    painter.drawLine(x + 130, y + AbstractTtlGate.pinHeight, x + 130, y + 20)
    painter.drawLine(x + 109 + offset, y + 40, x + 110, y + 40)
    painter.drawLine(x + 110, y + height - AbstractTtlGate.pinHeight, x + 110, y + 40)
    for i in 0..<5 where i != 2 {
      painter.drawLine(
        x + 10 + i * 20, y + height - AbstractTtlGate.pinHeight, x + 10 + i * 20, y + 36 + i * 2)
      painter.drawLine(x + 10 + i * 20, y + 36 + i * 2, x + 95, y + 36 + i * 2)
      painter.drawLine(
        x + 30 + i * 20, y + AbstractTtlGate.pinHeight, x + 30 + i * 20, y + 24 - i * 2)
      painter.drawLine(x + 30 + i * 20, y + 24 - i * 2, x + 115, y + 24 - i * 2)
    }
  }
}
