// LineUtil.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/draw/shapes/LineUtil.java. Copyright by the Logisim-evolution developers. This
// translation is a derivative work and is therefore licensed GPL-3.0-only. See LICENSE.md.

import Foundation
import LogisimKernel

/// `com.cburch.draw.shapes.LineUtil`.
public enum LineUtil {
  /// "small enough to treat as zero", for degenerate double-root cases.
  private static let zeroMax = 0.0000001

  public static func distance(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Double {
    distanceSquared(x0, y0, x1, y1).squareRoot()
  }

  public static func distanceSquared(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double)
    -> Double
  {
    let dx = x1 - x0
    let dy = y1 - y0
    return dx * dx + dy * dy
  }

  private static func nearestPoint(
    _ xq: Double, _ yq: Double, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double,
    isSegment: Bool
  ) -> (Double, Double) {
    let dx = x1 - x0
    let dy = y1 - y0
    let len2 = dx * dx + dy * dy
    if len2 < zeroMax * zeroMax {
      return ((x0 + x1) / 2, (y0 + y1) / 2)
    }

    let num = (xq - x0) * dx + (yq - y0) * dy
    var u: Double
    if isSegment {
      if num < 0 { u = 0 } else if num < len2 { u = num / len2 } else { u = 1 }
    } else {
      u = num / len2
    }
    return (x0 + u * dx, y0 + u * dy)
  }

  public static func nearestPointInfinite(
    _ xq: Double, _ yq: Double, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double
  ) -> (Double, Double) {
    nearestPoint(xq, yq, x0, y0, x1, y1, isSegment: false)
  }

  public static func nearestPointSegment(
    _ xq: Double, _ yq: Double, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double
  ) -> (Double, Double) {
    nearestPoint(xq, yq, x0, y0, x1, y1, isSegment: true)
  }

  public static func ptDistSqSegment(
    _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ xq: Double, _ yq: Double
  ) -> Double {
    let dx = x1 - x0
    let dy = y1 - y0
    let len2 = dx * dx + dy * dy
    if len2 < zeroMax * zeroMax {
      return distanceSquared(xq, yq, (x0 + x1) / 2, (y0 + y1) / 2)
    }
    let u = ((xq - x0) * dx + (yq - y0) * dy) / len2
    if u <= 0 { return distanceSquared(xq, yq, x0, y0) }
    if u >= 1 { return distanceSquared(xq, yq, x1, y1) }
    return distanceSquared(xq, yq, x0 + u * dx, y0 + u * dy)
  }

  public static func snapTo8Cardinals(_ from: Location, _ mx: Int, _ my: Int) -> Location {
    let px = from.x
    let py = from.y
    if mx != px && my != py {
      let ang = atan2(Double(my - py), Double(mx - px))
      let d45 = (abs(mx - px) + abs(my - py)) / 2
      let d = Int(4 * ang / Double.pi + 4.5)
      switch d {
      case 0, 8, 4:
        return Location.create(mx, py, hasToSnap: false)
      case 2, 6:
        return Location.create(px, my, hasToSnap: false)
      case 1:
        return Location.create(px - d45, py - d45, hasToSnap: false)
      case 3:
        return Location.create(px + d45, py - d45, hasToSnap: false)
      case 5:
        return Location.create(px + d45, py + d45, hasToSnap: false)
      case 7:
        return Location.create(px - d45, py + d45, hasToSnap: false)
      default:
        break
      }
    }
    return Location.create(mx, my, hasToSnap: false)
  }
}
