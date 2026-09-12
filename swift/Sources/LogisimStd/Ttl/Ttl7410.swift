// Ttl7410.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Ttl7410),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// TTL 74x10: triple 3-input NAND gate.
///
/// `open`, not `final`: `Ttl7411` (triple 3-input AND) and `Ttl7427` (triple 3-input NOR) both
/// extend this class, reusing its geometry and `propagateTtl` and only changing the
/// `inverted`/`isOR` flags via the constructor.
open class Ttl7410: AbstractTtlGate {

  /// `Ttl7410._ID`. "Unique identifier of the tool, used as reference in project files. Do NOT
  /// change as it will prevent project files from loading.": upstream's own comment.
  ///
  /// **Deviation (mechanism).** `class var`, not `static let`: see `Ttl7400.id` for why:
  /// `Ttl7411`/`Ttl7427` override it. No behavioural difference from Java's independent `_ID`
  /// fields.
  open class var id: String { "7410" }

  private static let pinCount = 14
  private static let outPorts = [6, 8, 12]

  private let inverted: Bool
  private let isAND: Bool

  /// Plain NAND (upstream's field defaults: `inverted = true`, `isAND = true`).
  public convenience init() {
    self.init(Ttl7410.id, inverted: true, isOR: false)
  }

  /// `Ttl7410(String val, boolean inverted)`; `isAND` keeps upstream's field default (`true`).
  /// Unused within this file set, but a public upstream constructor, so ported for parity.
  public convenience init(_ name: String, inverted: Bool) {
    self.init(name, inverted: inverted, isOR: false)
  }

  /// `Ttl7410(String val, boolean inverted, boolean isOR)`.
  public init(_ name: String, inverted: Bool, isOR: Bool) {
    self.inverted = inverted
    self.isAND = !isOR
    super.init(
      name,
      pins: Ttl7410.pinCount,
      outputPorts: Ttl7410.outPorts)
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    var val =
      isAND
      ? state.portValue(2).and(state.portValue(3).and(state.portValue(4)))
      : state.portValue(2).or(state.portValue(3).or(state.portValue(4)))
    state.setPort(5, inverted ? val.not() : val, 2)

    val =
      isAND
      ? state.portValue(0).and(state.portValue(1).and(state.portValue(11)))
      : state.portValue(0).or(state.portValue(1).or(state.portValue(11)))
    state.setPort(10, inverted ? val.not() : val, 2)

    val =
      isAND
      ? state.portValue(7).and(state.portValue(8).and(state.portValue(9)))
      : state.portValue(7).or(state.portValue(8).or(state.portValue(9)))
    state.setPort(6, inverted ? val.not() : val, 2)
  }

  /// `drawGates` is `false` for this chip, so `paintInternalBase` never draws the DIP outline
  /// on our behalf: draw it ourselves, as Java's `super.paintBase(painter, false, false)` does.
  ///
  /// **Deviation (mechanism):** the `LineOffset` term is Java's
  /// `AppPreferences.GATE_SHAPE.get().equals(SHAPE_SHAPED)` check; `shaped` defaults to `true`
  /// (see `Drawgates.swift`'s header), matching the preference's own default.
  open override func paintInternal(
    _ painter: SceneBuilder, _ state: any TtlPainter, x: Int, y: Int, height: Int, up: Bool
  ) {
    paintBase(painter, state, drawName: false, ghost: false)
    let shaped = true
    let lineOffset = (!isAND && shaped) ? -4 : 0
    if isAND {
      Drawgates.paintAnd(painter, x + 45, y + 20, 10, 10, inverted)
      Drawgates.paintAnd(painter, x + 125, y + 20, 10, 10, inverted)
      Drawgates.paintAnd(painter, x + 105, y + 40, 10, 10, inverted)
    } else {
      Drawgates.paintOr(painter, x + 45, y + 20, 10, 10, inverted, false)
      Drawgates.paintOr(painter, x + 125, y + 20, 10, 10, inverted, false)
      Drawgates.paintOr(painter, x + 105, y + 40, 10, 10, inverted, false)
    }
    let offset = inverted ? 0 : -4
    var xpos = [x + 49 + offset, x + 50, x + 50]
    var ypos = [y + 20, y + 20, y + AbstractTtlGate.pinHeight]
    painter.drawPolyline(xpos, ypos)
    xpos[0] = x + 129 + offset
    xpos[1] = x + 130
    xpos[2] = x + 130
    painter.drawPolyline(xpos, ypos)
    xpos[0] = x + 109 + offset
    xpos[1] = x + 110
    xpos[2] = x + 110
    ypos[0] = y + 40
    ypos[1] = y + 40
    ypos[2] = y + height - AbstractTtlGate.pinHeight
    painter.drawPolyline(xpos, ypos)

    xpos = [x + 30, x + 30, x + 35 + lineOffset]
    ypos = [y + AbstractTtlGate.pinHeight, y + 17, y + 17]
    painter.drawPolyline(xpos, ypos)
    xpos = [x + 10, x + 10, x + 35 + lineOffset]
    ypos = [y + height - AbstractTtlGate.pinHeight, y + 20, y + 20]
    painter.drawPolyline(xpos, ypos)
    xpos = [x + 30, x + 30, x + 35 + lineOffset]
    ypos = [y + height - AbstractTtlGate.pinHeight, y + 23, y + 23]
    painter.drawPolyline(xpos, ypos)

    for i in 0..<3 {
      xpos = [x + 70 + i * 20, x + 70 + i * 20, x + 115 + lineOffset]
      ypos = [y + AbstractTtlGate.pinHeight, y + 23 - i * 3, y + 23 - i * 3]
      painter.drawPolyline(xpos, ypos)
      xpos = [x + 50 + i * 20, x + 50 + i * 20, x + 95 + lineOffset]
      ypos = [y + height - AbstractTtlGate.pinHeight, y + 37 + i * 3, y + 37 + i * 3]
      painter.drawPolyline(xpos, ypos)
    }
  }
}
