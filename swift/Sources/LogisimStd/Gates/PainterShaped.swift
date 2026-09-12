// PainterShaped.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.gates.PainterShaped),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// The curved MIL-STD/ANSI gate bodies: `AppPreferences.SHAPE_SHAPED`, which is upstream's
// default and therefore what nearly every screenshot of Logisim shows.
//
// ── Why the six constant paths are transcribed digit for digit ──────────────────────────────
//
// `PATH_NARROW/MEDIUM/WIDE` and `SHIELD_NARROW/MEDIUM/WIDE` are the OR/XOR silhouettes. They
// are `GeneralPath`, i.e. **float**, and D16's geometry rule applies: `ScenePath` stores
// `Float`, so the quad control points round exactly as Java's do. Using `Double` here and
// narrowing later would move a control point by an ulp and bend the curve.
//
// ── `getInputLineLengths` is a point-in-path search ──────────────────────────────────────────
//
// The one genuinely non-obvious routine. For an OR/NOR/XOR/XNOR gate, the input leads have to
// stop where they meet the *concave* left edge of the body, and the length of each lead
// depends on how far in the curve has bowed at that input's y. Upstream finds it by brute
// force: start at the input, step right one pixel at a time, and stop the first time the point
// is no longer inside the shield path: capped at 15 steps, and a cap hit means "zero".
//
// `java.awt.geom.Path2D.contains` is therefore load-bearing geometry, not a utility call, so
// it is reimplemented here (`ShieldPath`) rather than approximated. The quads are flattened at
// a resolution far finer than the one-pixel step the search takes, and the crossing count uses
// the non-zero rule, which is `GeneralPath`'s default winding rule.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.gates.PainterShaped`.
public enum PainterShaped {

  // MARK: - The six constant silhouettes

  /// `PATH_NARROW`: the closed OR body for `size < 40`.
  static let pathNarrow: ScenePath = {
    var p = ScenePath()
    p.move(to: 0, 0)
    p.quad(control: -10, -15, to: -30, -15)
    p.quad(control: -22, 0, to: -30, 15)
    p.quad(control: -10, 15, to: 0, 0)
    p.close()
    return p
  }()

  /// `PATH_MEDIUM`, `40 <= size < 60`.
  static let pathMedium: ScenePath = {
    var p = ScenePath()
    p.move(to: 0, 0)
    p.quad(control: -20, -25, to: -50, -25)
    p.quad(control: -37, 0, to: -50, 25)
    p.quad(control: -20, 25, to: 0, 0)
    p.close()
    return p
  }()

  /// `PATH_WIDE`, `size >= 60`.
  static let pathWide: ScenePath = {
    var p = ScenePath()
    p.move(to: 0, 0)
    p.quad(control: -25, -35, to: -70, -35)
    p.quad(control: -50, 0, to: -70, 35)
    p.quad(control: -25, 35, to: 0, 0)
    p.close()
    return p
  }()

  /// `SHIELD_NARROW`; the bare concave left edge, open, no closing segment.
  static let shieldNarrow: ScenePath = {
    var p = ScenePath()
    p.move(to: -30, -15)
    p.quad(control: -22, 0, to: -30, 15)
    return p
  }()

  /// `SHIELD_MEDIUM`.
  static let shieldMedium: ScenePath = {
    var p = ScenePath()
    p.move(to: -50, -25)
    p.quad(control: -37, 0, to: -50, 25)
    return p
  }()

  /// `SHIELD_WIDE`.
  static let shieldWide: ScenePath = {
    var p = ScenePath()
    p.move(to: -70, -35)
    p.quad(control: -50, 0, to: -70, 35)
    return p
  }()

  // MARK: - computeShield

  /// `computeShield(int width, int height)`.
  ///
  /// Note the integer divisions are Java's and truncate toward zero, and that
  /// `-(width + height) / 4` negates *before* dividing: for an odd sum that is not the same
  /// as `-((width + height) / 4)`, and the wing control point moves by a pixel if you get it
  /// backwards.
  static func computeShield(_ width: Int, _ height: Int) -> ScenePath {
    let base: ScenePath
    if width < 40 {
      base = shieldNarrow
    } else if width < 60 {
      base = shieldMedium
    } else {
      base = shieldWide
    }

    if height <= width { return base }  // no wings

    let wingHeight = (height - width) / 2
    let dx = min(20, wingHeight / 4)

    var path = ScenePath()
    path.move(to: Double(-width), Double(-height / 2))
    path.quad(
      control: Double(-width + dx), Double(-(width + height) / 4),
      to: Double(-width), Double(-width / 2))
    path.append(base, connect: true)
    path.quad(
      control: Double(-width + dx), Double((width + height) / 4),
      to: Double(-width), Double(height / 2))
    return path
  }

  // MARK: - Input line lengths

  /// `INPUT_LENGTHS`: upstream's static memo, keyed `inputs * 31 + mainHeight`.
  ///
  /// Not thread-safe upstream either; painting is single-threaded on both sides (D1 keeps the
  /// simulation thread out of here entirely).
  private nonisolated(unsafe) static var inputLengths: [Int: [Int]] = [:]

  /// `getInputLineLengths(GateAttributes attrs, AbstractGate factory)`.
  ///
  /// Upstream's oddest quirk is preserved: the `factory` argument is accepted and then ignored,
  /// so every offset comes from `OrGate.FACTORY` regardless of which gate is painting.
  ///
  /// **One deliberate difference.** Java inserts the freshly allocated `int[]` into the memo
  /// *before* filling it, so a re-entrant call would observe zeros. Swift arrays are values, so
  /// that aliasing cannot be reproduced and the memo is written after the fill instead. Nothing
  /// observable changes: painting is single-threaded on both sides and this function does not
  /// re-enter.
  static func inputLineLengths(_ attrs: GateAttributes, _ factory: AbstractGate) -> [Int] {
    let inputs = Int(attrs.inputCount)
    let mainHeight = attrs.sizeValue
    let key = inputs * 31 + mainHeight
    if let hit = inputLengths[key] { return hit }

    // `attrs.clone()` with `facing = EAST`, so the offsets come out along +x whatever the
    // gate's actual facing is.
    var probe = attrs
    if attrs.facing != .east {
      guard let cloned = attrs.copy() as? GateAttributes else { return [Int](repeating: 0, count: inputs) }
      cloned.facing = .east
      probe = cloned
    }

    var lengths = [Int](repeating: 0, count: max(inputs, 0))
    guard inputs > 0 else {
      inputLengths[key] = lengths
      return lengths
    }

    let or = OrGate.factory
    let loc0 = or.inputOffset(probe, 0)
    let locn = or.inputOffset(probe, inputs - 1)
    var totalHeight = 10 + loc0.manhattanDistance(to: locn)
    if totalHeight < mainHeight { totalHeight = mainHeight }

    let path = ShieldPath(computeShield(mainHeight, totalHeight))
    for i in 0..<inputs {
      let loci = or.inputOffset(probe, i)
      var px = Double(loci.x + 1)
      let py = Double(loci.y)
      var iters = 0
      while path.contains(px, py) && iters < 15 {
        iters += 1
        px += 1
      }
      if iters >= 15 { iters = 0 }
      lengths[i] = iters
    }
    inputLengths[key] = lengths
    return lengths
  }

  // MARK: - Shapes

  /// `paintAnd(InstancePainter, int width, int height)`.
  ///
  /// The flat back plus a half-circle nose. `drawCenteredArc(g, -width/2, 0, width/2, -90, 180)`
  /// is the nose; the polyline is the three straight edges.
  static func paintAnd(_ painter: InstancePainter, _ width: Int, _ height: Int) {
    let g = painter.g
    g.strokeWidth = 2
    let xp = [-width / 2, -width + 1, -width + 1, -width / 2]
    let yp = [-width / 2, -width / 2, width / 2, width / 2]
    g.drawCenteredArc(-width / 2, 0, width / 2, -90, 180)
    g.drawPolyline(xp, yp)
    if height > width {
      g.drawLine(-width + 1, -height / 2, -width + 1, height / 2)
    }
  }

  /// `paintOr(InstancePainter, int width, int height)`.
  static func paintOr(_ painter: InstancePainter, _ width: Int, _ height: Int) {
    let g = painter.g
    g.strokeWidth = 2
    let path: ScenePath
    if width < 40 {
      path = pathNarrow
    } else if width < 60 {
      path = pathMedium
    } else {
      path = pathWide
    }
    g.strokePath(path)
    if height > width {
      paintShield(g, 0, width, height)
    }
  }

  /// `paintShield(Graphics g, int xlate, int width, int height)`.
  private static func paintShield(_ g: SceneBuilder, _ xlate: Int, _ width: Int, _ height: Int) {
    g.strokeWidth = 2
    // `g.translate(xlate, 0); draw(...); g.translate(-xlate, 0)`; the translation has to reach
    // the path ops, which is exactly what `SceneBuilder.emitPath` bakes in.
    g.withTranslate(xlate, 0) {
      g.strokePath(computeShield(width, height))
    }
  }

  /// `paintXor(InstancePainter, int width, int height)`: an OR body ten narrower, plus a
  /// second shield offset ten to its left.
  static func paintXor(_ painter: InstancePainter, _ width: Int, _ height: Int) {
    paintOr(painter, width - 10, width - 10)
    paintShield(painter.g, -10, width - 10, height)
  }

  /// `paintNot(InstancePainter)`: the inverter triangle and its bubble. Two hard-coded
  /// polylines, one per `NotGate.ATTR_SIZE` option.
  static func paintNot(_ painter: InstancePainter) {
    let g = painter.g
    g.strokeWidth = 2
    if painter.attributeValue(NotGate.size) == NotGate.sizeNarrow {
      g.strokeWidth = 2
      g.drawPolyline([-7, -19, -19, -7], [-1, -6, 6, 1])
      g.drawOval(-6, -3, 6, 6)
    } else {
      g.drawPolyline([-10, -29, -29, -10], [0, -7, 7, 0])
      g.drawOval(-9, -4, 9, 9)
    }
  }

  // MARK: - Input lines

  /// `paintInputLines(InstancePainter, AbstractGate)`.
  ///
  /// Only OR/NOR (`setPaintInputLines(true)`) reach this. The ghost branch draws negation
  /// bubbles and nothing else; the live branch draws each lead in its port's value colour, at
  /// stroke width 3, and re-asserts width 3 after every bubble because `drawDongle` leaves the
  /// pen at 2.
  static func paintInputLines(_ painter: InstancePainter, _ factory: AbstractGate) {
    let loc = painter.location
    let printView = painter.isPrintView
    guard let attrs = painter.attributeSet as? GateAttributes else { return }
    let facing = attrs.facing
    let inputs = Int(attrs.inputCount)
    let negated = attrs.negated

    let lengths = inputLineLengths(attrs, factory)
    guard lengths.count >= inputs else { return }
    let g = painter.g

    if painter.isGhost {
      for i in 0..<inputs where javaLongBitAt(negated, i) == 1 {
        let offs = factory.inputOffset(attrs, i)
        let loci = loc.translate(offs.x, offs.y)
        let cent = loci.translate(facing, lengths[i] + 5)
        painter.drawDongle(cent.x, cent.y)
      }
      return
    }

    let baseColor = g.color
    g.strokeWidth = 3
    for i in 0..<inputs {
      let offs = factory.inputOffset(attrs, i)
      let src = loc.translate(offs.x, offs.y)
      let len = lengths[i]
      if len != 0 && (!printView || painter.isPortConnected(i + 1)) {
        g.color = painter.showState ? painter.color(of: painter.portValue(i + 1)) : baseColor
        let dst = src.translate(facing, len)
        g.drawLine(src.x, src.y, dst.x, dst.y)
      }
      if javaLongBitAt(negated, i) == 1 {
        let cent = src.translate(facing, lengths[i] + 5)
        g.color = baseColor
        painter.drawDongle(cent.x, cent.y)
        g.strokeWidth = 3
      }
    }
    g.color = baseColor
  }
}

// MARK: - ShieldPath

/// `java.awt.geom.Path2D.contains(Point2D)` for the shield paths, and nothing more.
///
/// Exists because `getInputLineLengths` genuinely needs point-in-path, and `ScenePath` is a
/// record of drawing operations with no geometry queries on it (correctly; D6 keeps the scene
/// dumb).
///
/// Java's `Path2D` closes an unclosed path implicitly when counting crossings, which matters
/// here: `SHIELD_*` is a bare `moveTo`+`quadTo` and would enclose nothing otherwise. The
/// winding rule is non-zero, `GeneralPath`'s default.
struct ShieldPath {
  /// Flattened polygon, one sub-path.
  private var polylines: [[(x: Double, y: Double)]] = []

  /// Quads are flattened into this many segments. Two orders of magnitude finer than the
  /// one-pixel step the caller searches with, so the flattening never changes an answer that
  /// `Path2D` would give; only an exactly-on-the-boundary point could differ, and the search
  /// starts one pixel *inside*.
  private static let steps = 256

  init(_ path: ScenePath) {
    var current: [(x: Double, y: Double)] = []
    var cursor = (x: 0.0, y: 0.0)

    func flush() {
      if current.count >= 2 { polylines.append(current) }
      current = []
    }

    for op in path.ops {
      switch op {
      case .move(let x, let y):
        flush()
        cursor = (Double(x), Double(y))
        current = [cursor]
      case .line(let x, let y):
        cursor = (Double(x), Double(y))
        current.append(cursor)
      case .quad(let cx, let cy, let x, let y):
        let p0 = cursor
        let c = (x: Double(cx), y: Double(cy))
        let p1 = (x: Double(x), y: Double(y))
        for s in 1...ShieldPath.steps {
          let t = Double(s) / Double(ShieldPath.steps)
          let mt = 1 - t
          current.append(
            (x: mt * mt * p0.x + 2 * mt * t * c.x + t * t * p1.x,
             y: mt * mt * p0.y + 2 * mt * t * c.y + t * t * p1.y))
        }
        cursor = p1
      case .cubic(let ax, let ay, let bx, let by, let x, let y):
        let p0 = cursor
        let c1 = (x: Double(ax), y: Double(ay))
        let c2 = (x: Double(bx), y: Double(by))
        let p1 = (x: Double(x), y: Double(y))
        for s in 1...ShieldPath.steps {
          let t = Double(s) / Double(ShieldPath.steps)
          let mt = 1 - t
          current.append(
            (x: mt * mt * mt * p0.x + 3 * mt * mt * t * c1.x + 3 * mt * t * t * c2.x + t * t * t * p1.x,
             y: mt * mt * mt * p0.y + 3 * mt * mt * t * c1.y + 3 * mt * t * t * c2.y + t * t * t * p1.y))
        }
        cursor = p1
      case .close:
        if let first = current.first {
          current.append(first)
          cursor = first
        }
        flush()
      }
    }
    flush()
  }

  /// Non-zero winding test, with each sub-path implicitly closed.
  func contains(_ px: Double, _ py: Double) -> Bool {
    var winding = 0
    for poly in polylines {
      guard poly.count >= 2 else { continue }
      var previous = poly[poly.count - 1]  // implicit close
      for point in poly {
        winding += ShieldPath.crossing(previous, point, px, py)
        previous = point
      }
    }
    return winding != 0
  }

  /// +1 for an upward crossing of the ray `y == py, x > px`, -1 for a downward one.
  private static func crossing(
    _ a: (x: Double, y: Double), _ b: (x: Double, y: Double), _ px: Double, _ py: Double
  ) -> Int {
    if a.y <= py {
      if b.y > py, isLeft(a, b, px, py) > 0 { return 1 }
    } else if b.y <= py, isLeft(a, b, px, py) < 0 {
      return -1
    }
    return 0
  }

  /// > 0 if `(px, py)` is left of the directed segment `a -> b`.
  private static func isLeft(
    _ a: (x: Double, y: Double), _ b: (x: Double, y: Double), _ px: Double, _ py: Double
  ) -> Double {
    (b.x - a.x) * (py - a.y) - (px - a.x) * (b.y - a.y)
  }
}
