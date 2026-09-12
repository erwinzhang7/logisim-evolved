// SplitterPainter.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.circuit.SplitterPainter),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// The most geometric component in the wiring family, and the one with the least slack: a
// splitter's fan-out lines have to land exactly on its port locations, which the propagator
// already computed from `SplitterParameters`. If the drawing and the port placement disagree by
// a pixel, every splitter in every schematic shows wires that visibly miss their stubs.
//
// So every coordinate below comes out of `SplitterParameters`, already ported, already the
// source of truth for `computeEnds`, and nothing here re-derives spacing.
//
// ── Two appearances, two completely separate routines ───────────────────────────────────────
//
// `APPEAR_LEGACY` (the 2.7-and-earlier look) is `drawLegacy`; the three modern ones
// (left/right/centre) are `drawLines` + `drawLabels`. They share no geometry, which is why
// upstream keeps them as two functions rather than one with branches, and why this does too.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.circuit.SplitterPainter`.
enum SplitterPainter {

  /// `SplitterPainter.SPINE_WIDTH`, `Wire.WIDTH + 2`.
  static let spineWidth = WiringPaint.wireWidth + 2

  /// `SplitterPainter.SPINE_DOT`, `Wire.WIDTH + 4`.
  static let spineDot = WiringPaint.wireWidth + 4

  // MARK: - drawLabels

  /// `drawLabels(ComponentDrawContext, SplitterAttributes, Location origin)`.
  ///
  /// The label for each end is the *range* of end-0 bit indices routed to it, built by walking
  /// `bitEnd` and closing a run whenever the destination changes. Two details are easy to lose:
  ///
  ///   * the loop runs to `n` **inclusive**, using a sentinel `-1` bit, so the final run is
  ///     closed by the same code path as every other one;
  ///   * a later run is prepended, not appended (`toAdd + "," + old`), so `"5-4,1"` reads
  ///     high-to-low the way the bits do.
  ///
  /// End 0 is skipped (`curEnd <= 0`), because end 0 *is* the combined side.
  static func drawLabels(
    _ painter: InstancePainter, _ attrs: SplitterAttributes, _ origin: Location
  ) {
    let fanout = Int(attrs.fanout)
    var ends = [String?](repeating: nil, count: max(fanout + 1, 1))
    var curEnd = -1
    var cur0 = 0
    let bitEnd = attrs.bitEnd
    let n = bitEnd.count
    for i in 0...n {
      let bit = i == n ? -1 : Int(bitEnd[i])
      if bit != curEnd {
        let cur1 = i - 1
        var toAdd: String?
        if curEnd <= 0 {
          toAdd = nil
        } else if cur0 == cur1 {
          toAdd = "\(cur0)"
        } else {
          toAdd = "\(cur1)-\(cur0)"
        }
        if let toAdd, curEnd >= 0, curEnd < ends.count {
          if let old = ends[curEnd] {
            ends[curEnd] = toAdd + "," + old
          } else {
            ends[curEnd] = toAdd
          }
        }
        curEnd = bit
        cur0 = i
      }
    }

    let g = painter.g
    let savedFont = g.font
    g.font = savedFont.withSize(7)

    let parms = attrs.parameters()
    var x = origin.x + parms.end0X + parms.endToSpineDeltaX
    var y = origin.y + parms.end0Y + parms.endToSpineDeltaY
    var dx = parms.endToEndDeltaX
    var dy = parms.endToEndDeltaY
    let rotated = parms.textAngle != 0
    if rotated {
      // `g.rotate(PI/2)` and then swap-and-negate the coordinates by hand, so that the labels
      // read along the spine. Both halves are needed: the rotation turns the glyphs, the swap
      // moves the anchor into the rotated frame.
      g.pushRotate(Double.pi / 2.0)
      var t = -x
      x = y
      y = t
      t = -dx
      dx = dy
      dy = t
    }
    let halign = parms.textHorzAlign
    let valign = parms.textVertAlign
    x += (halign == SplitterParameters.hRight ? -1 : 1) * (spineWidth / 2 + 1)
    y += valign == SplitterParameters.vTop ? 0 : -3
    for i in 0..<fanout {
      if i + 1 < ends.count, let text = ends[i + 1] {
        g.drawText(
          text, x: x, y: y,
          halign: SplitterPainter.hAlign(halign), valign: SplitterPainter.vAlign(valign))
      }
      x += dx
      y += dy
    }

    if rotated { g.popTransform() }
    g.font = savedFont
  }

  /// `SplitterParameters` stores `GraphicsUtil`'s raw ints; the emitter takes the enums. Same
  /// values, so this is a pure re-spelling.
  private static func hAlign(_ raw: Int) -> HAlign {
    HAlign(rawValue: raw) ?? .center
  }

  private static func vAlign(_ raw: Int) -> VAlign {
    VAlign(rawValue: raw) ?? .center
  }

  // MARK: - drawLegacy

  /// `drawLegacy(ComponentDrawContext, SplitterAttributes, Location origin)`; the pre-2.7 look.
  ///
  /// Note the fan-out threshold differs between the two orientations: the vertical branch tests
  /// `fanout > 3` and the horizontal one `fanout >= 3`, so a 3-way splitter draws a spine bar
  /// when facing east/west and a dot when facing north/south. That asymmetry is upstream's, and
  /// it is visible; it is not corrected here.
  static func drawLegacy(
    _ painter: InstancePainter, _ attrs: SplitterAttributes, _ origin: Location
  ) {
    let g = painter.g
    let facing = attrs.facing
    let fanout = Int(attrs.fanout)
    let parms = attrs.parameters()

    g.color = .palette(.multi)
    let x0 = origin.x
    let y0 = origin.y
    let x1 = x0 + parms.end0X
    let y1 = y0 + parms.end0Y
    let dx = parms.endToEndDeltaX
    let dy = parms.endToEndDeltaY
    if facing == .north || facing == .south {
      let ySpine = (y0 + y1) / 2
      g.strokeWidth = WiringPaint.wireWidth
      g.drawLine(x0, y0, x0, ySpine)
      var xi = x1
      var yi = y1
      for _ in 1...max(fanout, 1) where fanout >= 1 {
        if painter.showState {
          g.color = painter.color(
            of: painter.context.value(at: Location.create(xi, yi, hasToSnap: true)))
        }
        let xSpine = xi + (xi == x0 ? 0 : (xi < x0 ? 10 : -10))
        g.drawLine(xi, yi, xSpine, ySpine)
        xi += dx
        yi += dy
      }
      if fanout > 3 {
        g.strokeWidth = spineWidth
        g.color = .palette(.multi)
        g.drawLine(
          x1 + (dx > 0 ? 10 : -10), ySpine,
          x1 + (fanout - 1) * dx + (dx > 0 ? 10 : -10), ySpine)
      } else {
        g.color = .palette(.multi)
        g.fillOval(x0 - spineDot / 2, ySpine - spineDot / 2, spineDot, spineDot)
      }
    } else {
      let xSpine = (x0 + x1) / 2
      g.strokeWidth = WiringPaint.wireWidth
      g.drawLine(x0, y0, xSpine, y0)
      var xi = x1
      var yi = y1
      for _ in 1...max(fanout, 1) where fanout >= 1 {
        if painter.showState {
          g.color = painter.color(
            of: painter.context.value(at: Location.create(xi, yi, hasToSnap: true)))
        }
        let ySpine = yi + (yi == y0 ? 0 : (yi < y0 ? 10 : -10))
        g.drawLine(xi, yi, xSpine, ySpine)
        xi += dx
        yi += dy
      }
      if fanout >= 3 {
        g.strokeWidth = spineWidth
        g.color = .palette(.multi)
        g.drawLine(
          xSpine, y1 + (dy > 0 ? 10 : -10),
          xSpine, y1 + (fanout - 1) * dy + (dy > 0 ? 10 : -10))
      } else {
        g.color = .palette(.multi)
        g.fillOval(xSpine - spineDot / 2, y0 - spineDot / 2, spineDot, spineDot)
      }
    }
    g.strokeWidth = 1
  }

  // MARK: - drawLines

  /// `drawLines(ComponentDrawContext, SplitterAttributes, Location origin)`: the modern look.
  ///
  /// One coloured stub per end, then the spine. The spine has two forms:
  ///
  ///   * **centred** (`spine0 == spine1`, which is what `APPEAR_CENTER` produces): the spine is
  ///     rebuilt from the end positions and pulled in by one at each extremity, and a
  ///     quarter-length stub joins it to the combined end. A fanout of 1 leaves an empty spine,
  ///     which becomes a dot.
  ///   * **offset** (left/right): a three-point polyline straight from `SplitterParameters`.
  ///
  /// The `/ 4` on `spine1X`/`spine1Y` is upstream's and is not a typo for a half.
  static func drawLines(
    _ painter: InstancePainter, _ attrs: SplitterAttributes, _ origin: Location
  ) {
    let showState = painter.showState

    let parms = attrs.parameters()
    let x0 = origin.x
    let y0 = origin.y
    var x = x0 + parms.end0X
    var y = y0 + parms.end0Y
    let dx = parms.endToEndDeltaX
    let dy = parms.endToEndDeltaY
    let dxEndSpine = parms.endToSpineDeltaX
    let dyEndSpine = parms.endToSpineDeltaY

    let g = painter.g
    let oldColor = g.color
    g.strokeWidth = WiringPaint.wireWidth
    for _ in 0..<max(Int(attrs.fanout), 0) {
      if showState {
        g.color = painter.color(
          of: painter.context.value(at: Location.create(x, y, hasToSnap: true)))
      }
      g.drawLine(x, y, x + dxEndSpine, y + dyEndSpine)
      x += dx
      y += dy
    }
    g.strokeWidth = spineWidth
    g.color = .palette(.multi)
    var spine0x = x0 + parms.spine0X
    var spine0y = y0 + parms.spine0Y
    var spine1x = x0 + parms.spine1X
    var spine1y = y0 + parms.spine1Y
    if spine0x == spine1x && spine0y == spine1y {  // centered
      let fanout = Int(attrs.fanout)
      spine0x = x0 + parms.end0X + parms.endToSpineDeltaX
      spine0y = y0 + parms.end0Y + parms.endToSpineDeltaY
      spine1x = spine0x + (fanout - 1) * parms.endToEndDeltaX
      spine1y = spine0y + (fanout - 1) * parms.endToEndDeltaY
      if parms.endToEndDeltaX == 0 {  // vertical spine
        if spine0y < spine1y {
          spine0y += 1
          spine1y -= 1
        } else {
          spine0y -= 1
          spine1y += 1
        }
        g.drawLine(x0 + parms.spine1X / 4, y0, spine0x, y0)
      } else {
        if spine0x < spine1x {
          spine0x += 1
          spine1x -= 1
        } else {
          spine0x -= 1
          spine1x += 1
        }
        g.drawLine(x0, y0 + parms.spine1Y / 4, x0, spine0y)
      }
      if fanout <= 1 {  // spine is empty
        let diam = spineDot
        g.fillOval(spine0x - diam / 2, spine0y - diam / 2, diam, diam)
      } else {
        g.drawLine(spine0x, spine0y, spine1x, spine1y)
      }
    } else {
      g.drawPolyline(
        [spine0x, spine1x, x0 + parms.spine1X / 4],
        [spine0y, spine1y, y0 + parms.spine1Y / 4])
    }
    g.color = oldColor
  }
}
