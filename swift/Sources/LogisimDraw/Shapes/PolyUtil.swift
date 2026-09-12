// PolyUtil.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/draw/shapes/PolyUtil.java. Copyright by the Logisim-evolution developers. This
// translation is a derivative work and is therefore licensed GPL-3.0-only. See LICENSE.md.
//
// `polygonContains` additionally ports the piece of `java.awt.geom.Path2D`/`sun.awt.geom.Curve`
// that Java's `Poly.contains` leans on for its filled hit-test (`GeneralPath.contains(x,y)`):
// the straight-line-segment crossing-number algorithm under the default `WIND_NON_ZERO` rule,
// including that Java implicitly closes the path (an extra crossing test back to the first
// point) even when the `GeneralPath` was never explicitly `closePath()`-ed, which is the case
// for every `Poly`, closed or not. So a `Poly(closed: false, …)`, a polyline, still tests as
// filled using its endpoints implicitly joined, exactly as Java's does. Verified against
// `java.awt.geom.Path2D.contains(double,double)` (`mask = WIND_NON_ZERO ? -1 : 1`, i.e.
// "crossings != 0") and `sun.awt.geom.Curve.pointCrossingsForLine`, both in the OpenJDK 21
// source (`lib/src.zip`).

import LogisimKernel

/// `com.cburch.draw.shapes.PolyUtil`.
public enum PolyUtil {
  public struct ClosestResult {
    public var distanceSq: Double = .greatestFiniteMagnitude
    public var location: Location?
    public var previousHandle: Handle?
    public var nextHandle: Handle?
  }

  public static func getClosestPoint(_ loc: Location, closed: Bool, _ handles: [Handle])
    -> ClosestResult?
  {
    let xq = Double(loc.x)
    let yq = Double(loc.y)
    var result = ClosestResult()
    if !handles.isEmpty {
      var h0 = handles[0]
      var x0 = Double(h0.x)
      var y0 = Double(h0.y)
      let stop = closed ? handles.count : handles.count - 1
      for i in 0..<stop {
        let h1 = handles[(i + 1) % handles.count]
        let x1 = Double(h1.x)
        let y1 = Double(h1.y)
        let d = LineUtil.ptDistSqSegment(x0, y0, x1, y1, xq, yq)
        if d < result.distanceSq {
          result.distanceSq = d
          result.previousHandle = h0
          result.nextHandle = h1
        }
        h0 = h1
        x0 = x1
        y0 = y1
      }
    }
    guard result.distanceSq != .greatestFiniteMagnitude, let h0 = result.previousHandle,
      let h1 = result.nextHandle
    else { return nil }
    let (px, py) = LineUtil.nearestPointSegment(xq, yq, Double(h0.x), Double(h0.y), Double(h1.x), Double(h1.y))
    result.location = Location.create(Int(px.rounded()), Int(py.rounded()), hasToSnap: false)
    return result
  }

  /// `sun.awt.geom.Curve.pointCrossingsForLine`.
  private static func pointCrossingsForLine(
    px: Double, py: Double, x0: Double, y0: Double, x1: Double, y1: Double
  ) -> Int {
    if py < y0 && py < y1 { return 0 }
    if py >= y0 && py >= y1 { return 0 }
    if px >= x0 && px >= x1 { return 0 }
    if px < x0 && px < x1 { return y0 < y1 ? 1 : -1 }
    let xintercept = x0 + (py - y0) * (x1 - x0) / (y1 - y0)
    if px >= xintercept { return 0 }
    return y0 < y1 ? 1 : -1
  }

  /// `GeneralPath(WIND_NON_ZERO).contains(x, y)` for a path built purely from `moveTo`/`lineTo`
  /// (exactly what `Poly.getPath()` builds): implicitly closed, per the file header.
  public static func polygonContains(_ points: [(x: Int, y: Int)], px: Int, py: Int) -> Bool {
    guard let first = points.first else { return false }
    let fx = Double(px)
    let fy = Double(py)
    var curx = Double(first.x)
    var cury = Double(first.y)
    let movx = curx
    let movy = cury
    var crossings = 0
    if points.count > 1 {
      for point in points.dropFirst() {
        let endx = Double(point.x)
        let endy = Double(point.y)
        crossings += pointCrossingsForLine(px: fx, py: fy, x0: curx, y0: cury, x1: endx, y1: endy)
        curx = endx
        cury = endy
      }
    }
    if cury != movy {
      crossings += pointCrossingsForLine(px: fx, py: fy, x0: curx, y0: cury, x1: movx, y1: movy)
    }
    return crossings != 0
  }
}
