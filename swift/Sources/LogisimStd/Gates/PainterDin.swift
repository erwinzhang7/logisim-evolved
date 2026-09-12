// PainterDin.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.gates.PainterDin),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── This is dead code in 4.1.0, and that is deliberate ──────────────────────────────────────
//
// `AppPreferences.SHAPE_DIN40700` is commented out (`AppPreferences.java:507`) and absent from
// the `GATE_SHAPE` option array (`:512`), and `AbstractGate.paintBase`'s dispatch arm for it is
// commented out too (`AbstractGate.java:404-406`). So no user can select the DIN shape in
// 4.1.0 and none of this runs.
//
// It is ported anyway because every gate still declares `paintDinShape` upstream, the
// abstract method still exists, and the alternative, a family of empty overrides, would lose
// the geometry and make re-enabling the shape a fresh port rather than uncommenting one line.
// `AbstractGate.paintBase` keeps the arm commented in exactly the same place, so the Swift and
// the Java disagree about nothing.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.gates.PainterDin`.
enum PainterDin {

  static let and = 0
  static let or = 1
  static let xor = 2
  static let xnor = 3

  /// `orLenArrays`: upstream's static memo, keyed `r << 4 | inputs`.
  private nonisolated(unsafe) static var orLenArrays: [Int: [Int]] = [:]

  /// `paint(InstancePainter, int width, int height, boolean drawBubble, int dinType)`.
  ///
  /// Transcribed literally, including that `xMid` is mutated at the very end (`xMid += 4`)
  /// after nothing reads it again: an upstream leftover, kept so the two files line up.
  private static func paint(
    _ painter: InstancePainter, _ width: Int, _ height: Int, _ drawBubble: Bool, _ dinType: Int
  ) {
    let g = painter.g
    var width = width
    let xMid = -width
    let y0 = -height / 2
    if drawBubble { width -= 8 }
    let diam = min(height, 2 * width)

    switch dinType {
    case and:
      break  // nothing to do
    case or:
      paintOrLines(painter, width, height, drawBubble)
    case xor, xnor:
      let elen = min(diam / 2 - 10, 20)
      let ex0 = xMid + (diam / 2 - elen) / 2
      let ex1 = ex0 + elen
      g.drawLine(ex0, -5, ex1, -5)
      g.drawLine(ex0, 0, ex1, 0)
      g.drawLine(ex0, 5, ex1, 5)
      if dinType == xor {
        let exMid = ex0 + elen / 2
        g.drawLine(exMid, -8, exMid, 8)
      }
    default:
      // Java throws IllegalArgumentException("unrecognized shape"); the four callers are the
      // only ones and all pass a constant, so this is unreachable. D13: no trap for a case
      // that cannot arise from data.
      return
    }

    g.strokeWidth = 2
    let x0 = xMid - diam / 2
    let oldColor = g.color
    if painter.showState {
      g.color = painter.color(of: painter.portValue(0))
    }
    g.drawLine(x0 + diam, 0, 0, 0)
    g.color = oldColor
    if height <= diam {
      g.drawArc(x0, y0, diam, diam, -90, 180)
    } else {
      let x1 = x0 + diam
      let yy0 = -(height - diam) / 2
      let yy1 = (height - diam) / 2
      g.drawArc(x0, y0, diam, diam, 0, 90)
      g.drawLine(x1, yy0, x1, yy1)
      g.drawArc(x0, y0 + height - diam, diam, diam, -90, 90)
    }
    g.drawLine(xMid, y0, xMid, y0 + height)
    if drawBubble {
      g.fillOval(x0 + diam - 4, -4, 8, 8)
    }
  }

  static func paintAnd(
    _ painter: InstancePainter, _ width: Int, _ height: Int, _ drawBubble: Bool
  ) {
    paint(painter, width, height, drawBubble, and)
  }

  static func paintOr(
    _ painter: InstancePainter, _ width: Int, _ height: Int, _ drawBubble: Bool
  ) {
    paint(painter, width, height, drawBubble, or)
  }

  static func paintXor(
    _ painter: InstancePainter, _ width: Int, _ height: Int, _ drawBubble: Bool
  ) {
    paint(painter, width, height, drawBubble, xor)
  }

  static func paintXnor(
    _ painter: InstancePainter, _ width: Int, _ height: Int, _ drawBubble: Bool
  ) {
    paint(painter, width, height, drawBubble, xnor)
  }

  /// `paintOrLines(InstancePainter, int width, int height, boolean hasBubble)`.
  ///
  /// Upstream's `printView` local is `isPrintView() && getInstance() != null`, and note it
  /// then tests `isPortConnected(i)` with the *input index*, not `i + 1`, so it asks about
  /// the output port for input 0. That is an upstream off-by-one in a branch that only runs in
  /// print view; preserved, because "fixing" it changes which leads print.
  private static func paintOrLines(
    _ painter: InstancePainter, _ width: Int, _ height: Int, _ hasBubble: Bool
  ) {
    guard let baseAttrs = painter.attributeSet as? GateAttributes else { return }
    let inputs = Int(baseAttrs.inputCount)
    guard let attrs = OrGate.factory.createAttributeSet() as? GateAttributes else { return }
    attrs.inputCount = Int32(inputs)
    attrs.sizeOption = baseAttrs.sizeOption

    let g = painter.g
    let r = min(height / 2, width)
    let hash = r << 4 | inputs
    var lens = orLenArrays[hash]
    if lens == nil {
      var built = [Int](repeating: 0, count: max(inputs, 0))
      let yCurveStart = height / 2 - r
      for i in 0..<max(inputs, 0) {
        var y = OrGate.factory.inputOffset(attrs, i).y
        if y < 0 { y = -y }
        if y <= yCurveStart {
          built[i] = r
        } else {
          let dy = y - yCurveStart
          // `(int) (Math.sqrt(r * r - dy * dy) + 0.5)`: truncation of a +0.5, i.e. Java's
          // round-half-up for a non-negative argument.
          built[i] = Int((Double(r * r - dy * dy).squareRoot() + 0.5))
        }
      }
      orLenArrays[hash] = built
      lens = built
    }
    guard let lens, lens.count >= inputs else { return }

    let factory: AbstractGate = hasBubble ? NorGate.factory : OrGate.factory
    let printView = painter.isPrintView && !painter.isGhost
    g.strokeWidth = 2
    for i in 0..<max(inputs, 0) where !printView || painter.isPortConnected(i) {
      let loc = factory.inputOffset(attrs, i)
      g.drawLine(loc.x, loc.y, loc.x + lens[i], loc.y)
    }
  }
}
