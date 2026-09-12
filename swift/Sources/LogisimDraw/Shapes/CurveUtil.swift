// CurveUtil.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/draw/shapes/CurveUtil.java. Copyright by the Logisim-evolution developers. This
// translation is a derivative work and is therefore licensed GPL-3.0-only. See LICENSE.md.
//
// Upstream credits: `getBounds`/`findNearestPoint` translated from Olivier Besson's ActionScript
// Bezier collision-detection code; `interpolate` translated from Jim Armstrong's ActionScript
// (both credited in the original Java comments, reproduced here).

import Foundation
import LogisimKernel

/// `com.cburch.draw.shapes.CurveUtil`.
public enum CurveUtil {
  private static let zeroMax = 0.0000001

  private static func computeA(_ p0: (Double, Double), _ p1: (Double, Double)) -> (Double, Double) {
    (p1.0 - p0.0, p1.1 - p0.1)
  }

  private static func computeB(
    _ p0: (Double, Double), _ p1: (Double, Double), _ p2: (Double, Double)
  ) -> (Double, Double) {
    (p0.0 - 2 * p1.0 + p2.0, p0.1 - 2 * p1.1 + p2.1)
  }

  /// Note: `p0`/`p2` are the curve's endpoints, `p1` is the control point.
  public static func findNearestPoint(
    _ q: (Double, Double), _ p0: (Double, Double), _ p1: (Double, Double), _ p2: (Double, Double)
  ) -> (Double, Double)? {
    let A = computeA(p0, p1)
    let B = computeB(p0, p1, p2)
    let pos0 = (p0.0 - q.0, p0.1 - q.1)

    let a = B.0 * B.0 + B.1 * B.1
    let b = 3 * (A.0 * B.0 + A.1 * B.1)
    let c = 2 * (A.0 * A.0 + A.1 * A.1) + pos0.0 * B.0 + pos0.1 * B.1
    let d = pos0.0 * A.0 + pos0.1 * A.1
    guard let roots = solveCubic(a, b, c, d) else { return nil }

    var dist2Min = Double.greatestFiniteMagnitude
    var found = false
    var posMin = (0.0, 0.0)
    for root in roots {
      let t: Double
      if root < 0 {
        t = 0
      } else if root <= 1 {
        t = root
      } else {
        t = 1
      }
      let pos = getPos(t, p0, p1, p2)
      let lx = q.0 - pos.0
      let ly = q.1 - pos.1
      let dist2 = lx * lx + ly * ly
      if dist2 < dist2Min {
        found = true
        dist2Min = dist2
        posMin = pos
      }
    }
    return found ? posMin : nil
  }

  /// Note: `p0`/`p2` are the curve's endpoints, `p1` is the control point.
  public static func getBounds(
    _ p0: (Double, Double), _ p1: (Double, Double), _ p2: (Double, Double)
  ) -> Bounds {
    let A = computeA(p0, p1)
    let B = computeB(p0, p1, p2)

    var xMin = min(p0.0, min(p1.0, p2.0))
    var xMax = max(p0.0, max(p1.0, p2.0))
    var yMin = min(p0.1, min(p1.1, p2.1))
    var yMax = max(p0.1, max(p1.1, p2.1))

    if xMin == p1.0 || xMax == p1.0 {
      let u = -A.0 / B.0
      let uu = (1 - u) * (1 - u) * p0.0 + 2 * u * (1 - u) * p1.0 + u * u * p2.0
      if xMin == p1.0 { xMin = uu } else { xMax = uu }
    }
    if yMin == p1.1 || yMax == p1.1 {
      let u = -A.1 / B.1
      let uu = (1 - u) * (1 - u) * p0.1 + 2 * u * (1 - u) * p1.1 + u * u * p2.1
      if yMin == p1.1 { yMin = uu } else { yMax = uu }
    }

    // `javaInt`, not `Int(_:)`. A curve whose three control points share a y makes
    // `computeB(...).1` zero, `2 * (p0 - 2*p1 + p2)` with all three equal, so `u = -A.1 / B.1`
    // is NaN and `uu` with it. `Int(NaN)` is a **runtime trap in Swift**, so opening any `.circ`
    // holding a flat `<curve>` killed the app outright. Java does not crash: a narrowing cast of
    // NaN is defined to be 0, and the jar answers `(83,0): 117x100` for exactly this input.
    //
    // The same applies to the x branch above, and to values past `Int32`: `(int)` of an
    // out-of-range double saturates in Java rather than trapping. Reproducing that conversion is
    // the fix; clamping only the NaN would leave the overflow trap in place.
    //
    // ── `.rounded(.down)` on the minima is a DELIBERATE DIVERGENCE from 4.1.0 ──────────────────
    //
    // `CurveUtil.java:117-120` is `(int) xMin` / `(int) yMin` against `(int) Math.ceil(xMax)` /
    // `(int) Math.ceil(yMax)`. Java's `(int)` truncates **toward zero**, which equals `floor` only
    // for non-negative values, so upstream rounds the box outward on the max side and *inward* on
    // the min side whenever a minimum is negative and fractional. The box then fails to bound the
    // curve it was computed for, and a narrow one collapses to nothing.
    //
    // Measured against the jar, not read off the source; `com.cburch.draw.shapes.CurveUtil`
    // loaded from `logisim-evolution-4.1.0-all.jar` and called directly. Each pair below is the
    // same shape mirrored through x = 0, which is what makes this an arithmetic slip rather than an
    // intent: the two halves of a mirror pair get different treatment purely by sign.
    //
    //   p0            p1            p2            true xMin   4.1.0 box        here
    //   (100, 0)      (111, 50)     (100, 100)    +105.5      (100,0): 6x100  same
    //   (-100, 0)     (-111, 50)    (-100, 100)   -105.5      (-105,0): 5x100  (-106,0): 6x100
    //   (100, 100)    (99, 110)     (100, 120)    +99.5       (99,100): 1x20   same
    //   (-100, 100)   (-101, 110)   (-100, 120)   -100.5      (-100,100): 0x20 (-101,100): 1x20
    //
    // The third row is upstream getting it right, and the fourth is the same curve dragged 200
    // left getting a box of **zero width**; 0.5 units of curve on the wrong side of a one-unit
    // span is the whole span. D18's second arm applies: no gate can see this (bounds are never
    // serialised, `SvgCreator.createCurve` writes only the three points, and neither `-tty table`
    // nor `-tty stats` reads geometry), and a zero-width `Bounds` is inert in every consumer that
    // mediates through it, `AbstractCanvasObject.overlaps` returns false on `c.width == 0` and
    // `randomPoint(in:)` returns nil on `w <= 0`. This port reaches the negative side more readily
    // than upstream does, too: D19 removed the origin wall, and the appearance editor never had one
    // in either codebase (`com/cburch/draw/tools/SelectTool.java:437` takes the raw delta).
    //
    // "No gate can see it" is measured, not assumed. The corpus holds **688 quadratic `<appear>`
    // paths across 237 files and not one has a negative coordinate**, so for every curve any gate
    // actually loads `(int)` and `floor` are the same function. The corpus-backed appearance byte
    // gate ("every corpus file's `<appear>` survives the model byte-identically") passes unchanged.
    // The nearest thing to an exposed path is `CircuitAppearance.getBounds`, which unions
    // `obj.getBounds()` over every shape and so feeds a custom-appearance subcircuit's
    // `getOffsetBounds`; port *offsets* do not go through it, `getPortOffsets` reads only the
    // ports' own locations and the anchor, so the golden port geometry is independent of this.
    //
    // Flooring before `javaInt` rather than inside it keeps the crash fix above exactly as it was:
    // `floor(NaN)` is NaN, so a flat curve still lands on `javaInt`'s NaN → 0 arm and still answers
    // `(83,0): 117x100`, and flooring an out-of-range double leaves it out of range, so saturation
    // still triggers instead of trapping.
    let x = javaInt(xMin.rounded(.down))
    let y = javaInt(yMin.rounded(.down))
    let w = javaInt(xMax.rounded(.up)) - x
    let h = javaInt(yMax.rounded(.up)) - y
    return Bounds.create(x, y, w, h)
  }

  /// Java's `(int)` narrowing conversion of a `double` (JLS 5.1.3), which is total where Swift's
  /// `Int(_:)` traps: NaN becomes 0, and anything outside `Int32` saturates at its nearest bound.
  private static func javaInt(_ value: Double) -> Int {
    if value.isNaN { return 0 }
    if value >= Double(Int32.max) { return Int(Int32.max) }
    if value <= Double(Int32.min) { return Int(Int32.min) }
    return Int(value)
  }

  private static func getPos(
    _ t: Double, _ p0: (Double, Double), _ p1: (Double, Double), _ p2: (Double, Double)
  ) -> (Double, Double) {
    let a = (1 - t) * (1 - t)
    let b = 2 * t * (1 - t)
    let c = t * t
    return (a * p0.0 + b * p1.0 + c * p2.0, a * p0.1 + b * p1.1 + c * p2.1)
  }

  public static func interpolate(
    _ end0: (Double, Double), _ end1: (Double, Double), _ mid: (Double, Double)
  ) -> (Double, Double) {
    var dx = mid.0 - end0.0
    var dy = mid.1 - end0.1
    let d0 = (dx * dx + dy * dy).squareRoot()

    dx = mid.0 - end1.0
    dy = mid.1 - end1.1
    let d1 = (dx * dx + dy * dy).squareRoot()

    if d0 < zeroMax || d1 < zeroMax {
      return ((end0.0 + end1.0) / 2, (end0.1 + end1.1) / 2)
    }

    let t = d0 / (d0 + d1)
    let u = 1.0 - t
    let t2 = t * t
    let u2 = u * u
    let den = 2 * t * u

    let xNum = mid.0 - u2 * end0.0 - t2 * end1.0
    let yNum = mid.1 - u2 * end0.1 - t2 * end1.1
    return (xNum / den, yNum / den)
  }

  /// `CurveUtil.solveCubic`: a local, optimized transcription of
  /// `com.gludion.utils.MathUtils.thirdDegreeEquation`. Returns `nil` for "no real roots" and
  /// may return 1–3 roots otherwise (Java's comment: with `count == 1`, the 2nd/3rd slots may
  /// still hold garbage; this port only ever returns the roots that are actually meaningful).
  private static func solveCubic(_ aIn: Double, _ bIn: Double, _ cIn: Double, _ dIn: Double)
    -> [Double]?
  {
    if abs(aIn) > zeroMax {
      var z = aIn
      let a = bIn / z
      let b = cIn / z
      let c = dIn / z
      let p = b - a * a / 3
      let q = a * (2 * a * a - 9 * b) / 27 + c
      let p3 = p * p * p
      let D = q * q + 4 * p3 / 27
      let offset = -a / 3
      if D > zeroMax {
        z = D.squareRoot()
        var u = (-q + z) / 2
        var v = (-q - z) / 2
        u = (u >= 0) ? pow(u, 1.0 / 3) : -pow(-u, 1.0 / 3)
        v = (v >= 0) ? pow(v, 1.0 / 3) : -pow(-v, 1.0 / 3)
        return [u + v + offset]
      } else if D < -zeroMax {
        let u = 2 * (-p / 3).squareRoot()
        let v = acos(-((-27 / p3).squareRoot()) * q / 2) / 3
        return [
          u * cos(v) + offset,
          u * cos(v + 2 * Double.pi / 3) + offset,
          u * cos(v + 4 * Double.pi / 3) + offset,
        ]
      } else {
        let u = (q < 0) ? pow(-q / 2, 1.0 / 3) : -pow(q / 2, 1.0 / 3)
        return [2 * u + offset, -u + offset]
      }
    } else if abs(bIn) > zeroMax {
      let a = bIn
      let b = cIn
      let c = dIn
      var D = b * b - 4 * a * c
      if D <= -zeroMax {
        return nil
      } else if D > zeroMax {
        D = D.squareRoot()
        return [(-b - D) / (2 * a), (-b + D) / (2 * a)]
      } else {
        return [-b / (2 * a)]
      }
    } else if abs(cIn) > zeroMax {
      return [-dIn / cIn]
    } else {
      return nil
    }
  }
}
