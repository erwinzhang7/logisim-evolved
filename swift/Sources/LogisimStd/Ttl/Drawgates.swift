// Drawgates.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.ttl.Drawgates),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Small shared drawing primitives used by roughly a third of the TTL chips' `paintInternal`
// (AND/OR/NOT/XOR gate glyphs, single/double-input wire routing, the port-name label box).
//
// **Deviation (mechanism).** Every upstream method branches on
// `AppPreferences.GATE_SHAPE.get().equals(AppPreferences.SHAPE_RECTANGULAR)` to choose between
// the ANSI ("shaped") and IEC ("rectangular") gate glyph. That preference is UI state (D9) and
// has no bridge into `LogisimStd` yet; the `Gates` family's shaped-vs-rectangular rendering
// has the same gap. `shaped` defaults to `true`, matching `AppPreferences.GATE_SHAPE`'s own
// default (`SHAPE_SHAPED`), so default-preference rendering is exact; a rectangular-preference
// render is not reachable until that bridge exists.
//
// `x`/`y` name the coordinates of the gate's OUTPUT point, exactly as upstream documents.

import LogisimRender

enum Drawgates {

  /// `paintAnd(Graphics, int, int, int, int, boolean)`.
  static func paintAnd(
    _ painter: SceneBuilder, _ x: Int, _ y: Int, _ width: Int, _ height: Int, _ negated: Bool,
    shaped: Bool = true
  ) {
    if negated { paintNegatedOutput(painter, x, y) }
    if !shaped {
      painter.drawRect(x - width, y - height / 2, width, height)
      painter.drawCenteredText("&", x: x - width / 2, y: y)
    } else {
      let xp = [x - width / 2, x - width, x - width, x - width / 2]
      let yp = [y - width / 2, y - width / 2, y + width / 2, y + width / 2]
      painter.drawCenteredArc(x - width / 2, y, width / 2, -90, 180)
      painter.drawPolyline(xp, yp)
      if height > width {
        painter.drawLine(x - width, y - height / 2, x - width, y + height / 2)
      }
    }
  }

  /// `paintBuffer(Graphics, int, int, int, int)`.
  static func paintBuffer(_ painter: SceneBuilder, _ x: Int, _ y: Int, _ width: Int, _ height: Int) {
    let xp = [x - 4, x - width, x - width, x - 4]
    let yp = [y, y - height / 2, y + height / 2, y]
    painter.drawPolyline(xp, yp)
  }

  /// `paintDoubleInputgate(Graphics, int, int, int, int, int, boolean, boolean, int)`.
  static func paintDoubleInputgate(
    _ painter: SceneBuilder, rightPinX: Int, y: Int, inputX: Int, outputY: Int,
    portHeight: Int, up: Bool, rightToLeft: Bool, height: Int
  ) {
    var xPoints =
      !rightToLeft
      ? [rightPinX, rightPinX, rightPinX - 10, rightPinX - 10, inputX]
      : [rightPinX - 20, rightPinX - 20, rightPinX - 10, rightPinX - 10, inputX]

    var yPoints =
      !up
      ? [
        y + height - AbstractTtlGate.pinHeight,
        y + height - AbstractTtlGate.pinHeight - (10 - AbstractTtlGate.pinHeight),
        y + height - AbstractTtlGate.pinHeight - (10 - AbstractTtlGate.pinHeight),
        outputY + portHeight / 3,
        outputY + portHeight / 3,
      ]
      : [
        y + AbstractTtlGate.pinHeight,
        y + AbstractTtlGate.pinHeight + (10 - AbstractTtlGate.pinHeight),
        y + AbstractTtlGate.pinHeight + (10 - AbstractTtlGate.pinHeight),
        outputY - portHeight / 3,
        outputY - portHeight / 3,
      ]
    painter.drawPolyline(xPoints, yPoints)

    xPoints = !rightToLeft ? [rightPinX - 20, rightPinX - 20, inputX] : [rightPinX, rightPinX, inputX]
    yPoints =
      !up
      ? [y + height - AbstractTtlGate.pinHeight, outputY - portHeight / 3, outputY - portHeight / 3]
      : [y + AbstractTtlGate.pinHeight, outputY + portHeight / 3, outputY + portHeight / 3]
    painter.drawPolyline(xPoints, yPoints)
  }

  /// `paintNegatedOutput(Graphics, int, int)`.
  private static func paintNegatedOutput(_ painter: SceneBuilder, _ x: Int, _ y: Int) {
    painter.drawOval(x, y - 2, 4, 4)
  }

  /// `paintNot(Graphics, int, int, int, int)`.
  static func paintNot(
    _ painter: SceneBuilder, _ x: Int, _ y: Int, _ width: Int, _ height: Int, shaped: Bool = true
  ) {
    paintNegatedOutput(painter, x - 4, y)
    if !shaped {
      painter.drawRect(x - width, y - (width - 4) / 2, width - 4, width - 4)
      painter.drawCenteredText("1", x: x - 4 - (width - 4) / 2, y: y)
    } else {
      let xp = [x - 4, x - width, x - width, x - 4]
      let yp = [y, y - height / 2, y + height / 2, y]
      painter.drawPolyline(xp, yp)
    }
  }

  /// `paintOr(Graphics, int, int, int, int, boolean, boolean)`.
  static func paintOr(
    _ painter: SceneBuilder, _ x: Int, _ y: Int, _ width: Int, _ height: Int,
    _ negated: Bool, _ rightToLeft: Bool, shaped: Bool = true
  ) {
    let offset = rightToLeft ? -4 : 0
    if negated { paintNegatedOutput(painter, x + offset, y) }
    if !shaped {
      if !rightToLeft {
        painter.drawRect(x - width, y - height / 2, width, height)
        painter.drawCenteredText("\u{2265}1", x: x - width / 2, y: y)
      } else {
        painter.drawRect(x, y - height / 2, width, height)
        painter.drawCenteredText("\u{2265}1", x: x + width / 2, y: y)
      }
    } else {
      if !rightToLeft {
        painter.drawCenteredArc(x - 14, y - 10, 17, -90, 54)
        painter.drawCenteredArc(x - 14, y + 10, 17, 90, -54)
        painter.drawCenteredArc(x - 28, y, 15, -27, 54)
      } else {
        painter.drawCenteredArc(x + 14, y - 10, 17, -90, -54)
        painter.drawCenteredArc(x + 14, y + 10, 17, 90, 54)
        painter.drawCenteredArc(x + 28, y, 15, 153, 54)
      }
    }
  }

  /// `paintOutputgate(Graphics, int, int, int, int, boolean, int)`.
  static func paintOutputgate(
    _ painter: SceneBuilder, xpin: Int, y: Int, xoutput: Int, youtput: Int, up: Bool, height: Int
  ) {
    let xPoints = [xoutput, xpin, xpin]
    let yPoints =
      !up
      ? [youtput, youtput, y + height - AbstractTtlGate.pinHeight]
      : [youtput, youtput, y + AbstractTtlGate.pinHeight]
    painter.drawPolyline(xPoints, yPoints)
  }

  /// `paintPortNames(InstancePainter, int, int, int, String[])`.
  static func paintPortNames(
    _ painter: SceneBuilder, x: Int, y: Int, height: Int, portNames: [String]
  ) {
    let portsPerRow = portNames.count / 2
    painter.drawRect(
      x + 10, y + AbstractTtlGate.pinHeight + 10,
      portNames.count * 10, height - 2 * AbstractTtlGate.pinHeight - 20)
    for i in 0..<2 {
      for j in 0..<portsPerRow {
        painter.drawCenteredText(
          portNames[j + i * portsPerRow],
          x: i == 0 ? x + 10 + j * 20 : x + 20 * portsPerRow - j * 20 + 10,
          y: y + height - AbstractTtlGate.pinHeight - 7
            - i * (height - 2 * AbstractTtlGate.pinHeight - 11))
      }
    }
  }

  /// `paintSingleInputgate(Graphics, int, int, int, int, boolean, int)`.
  static func paintSingleInputgate(
    _ painter: SceneBuilder, xpin: Int, y: Int, xinput: Int, youtput: Int, up: Bool, height: Int
  ) {
    let xPoints = [xpin, xpin, xinput]
    let yPoints =
      !up
      ? [y + height - AbstractTtlGate.pinHeight, youtput, youtput]
      : [y + AbstractTtlGate.pinHeight, youtput, youtput]
    painter.drawPolyline(xPoints, yPoints)
  }

  /// `paintXor(Graphics, int, int, int, int, boolean)`.
  static func paintXor(
    _ painter: SceneBuilder, _ x: Int, _ y: Int, _ width: Int, _ height: Int, _ negated: Bool,
    shaped: Bool = true
  ) {
    if !shaped {
      if negated { paintNegatedOutput(painter, x, y) }
      painter.drawRect(x - width, y - height / 2, width, height)
      painter.drawCenteredText("=1", x: x - width / 2, y: y)
    } else {
      paintOr(painter, x, y, width, height, negated, false, shaped: shaped)
      painter.drawCenteredArc(x - 32, y, 15, -27, 54)
    }
  }

  /// Shared by `Ttl74138`/`Ttl74139`/`Ttl74157`'s `paintInternal`: tooltip-length port names
  /// (e.g. `"nG2A Enable (active LOW)"`) don't fit the internal diagram, so the first
  /// whitespace-separated token is taken and truncated to 4 characters.
  static func shortenPortNames(_ names: [String]) -> [String] {
    names.map { name in
      let first = name.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
      return first.count <= 4 ? first : String(first.prefix(4))
    }
  }

  /// `paintOpenCollector(Graphics, int, int)`: the open-collector/open-drain output symbol.
  static func paintOpenCollector(_ painter: SceneBuilder, _ x: Int, _ y: Int) {
    painter.drawPolyline([x, x + 3, x + 6, x + 3, x], [y, y + 3, y, y - 3, y])
    painter.drawLine(x, y + 3, x + 6, y + 3)
  }
}
