// Curve.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/draw/shapes/Curve.java. Copyright by the Logisim-evolution developers. This
// translation is a derivative work and is therefore licensed GPL-3.0-only. See LICENSE.md.
//
// `getCurve(gesture).contains(x,y)` (Java's fill hit-test, via `java.awt.geom.QuadCurve2D`) is
// reproduced by `quadCurveContains` below: a direct transcription of
// `QuadCurve2D.contains(double,double)` from the OpenJDK 21 source (`lib/src.zip`), which is a
// closed-form algebraic test (intersect the curve with the line through the query point parallel
// to the curve's second derivative), not a generic path-crossing test. No drawing type is
// involved; `QuadCurve2D` here is only ever used as shape-intersection math.

import Foundation
import LogisimKernel

/// `java.awt.geom.QuadCurve2D.contains(double, double)`, transcribed directly (see file header).
/// Free function, not shape-specific: it operates on three raw points.
func quadCurveContains(
  x1: Double, y1: Double, xc: Double, yc: Double, x2: Double, y2: Double, x: Double, y: Double
) -> Bool {
  let kx = x1 - 2 * xc + x2
  let ky = y1 - 2 * yc + y2
  let dx = x - x1
  let dy = y - y1
  let dxl = x2 - x1
  let dyl = y2 - y1

  let t0 = (dx * ky - dy * kx) / (dxl * ky - dyl * kx)
  if !(t0 >= 0 && t0 <= 1) { return false }  // also catches NaN, matching `t0 != t0`

  let xb = kx * t0 * t0 + 2 * (xc - x1) * t0 + x1
  let yb = ky * t0 * t0 + 2 * (yc - y1) * t0 + y1
  let xl = dxl * t0 + x1
  let yl = dyl * t0 + y1

  return (x >= xb && x < xl) || (x >= xl && x < xb) || (y >= yb && y < yl) || (y >= yl && y < yb)
}

/// `com.cburch.draw.shapes.Curve`, a quadratic Bézier.
public final class Curve: FillableCanvasObject {
  private var p0Value: Location
  private var p1Value: Location  // control point
  private var p2Value: Location
  private var boundsValue: Bounds

  public init(end0: Location, end1: Location, control: Location) {
    self.p0Value = end0
    self.p1Value = control
    self.p2Value = end1
    self.boundsValue = CurveUtil.getBounds(
      (Double(end0.x), Double(end0.y)), (Double(control.x), Double(control.y)),
      (Double(end1.x), Double(end1.y)))
    super.init()
  }

  public override func canMoveHandle(_ handle: Handle) -> Bool { true }

  public override func contains(_ loc: Location, assumeFilled: Bool) -> Bool {
    var type = getPaintType()
    if assumeFilled && type == DrawAttr.paintStroke { type = DrawAttr.paintStrokeFill }
    if type != DrawAttr.paintFill {
      let q = (Double(loc.x), Double(loc.y))
      let p0 = (Double(p0Value.x), Double(p0Value.y))
      let p1 = (Double(p1Value.x), Double(p1Value.y))
      let p2 = (Double(p2Value.x), Double(p2Value.y))
      if let p = CurveUtil.findNearestPoint(q, p0, p1, p2) {
        let stroke = Double(getStrokeWidth())
        let thr = type == DrawAttr.paintStroke ? max(Double(Line.onLineThresh), stroke / 2) : stroke / 2
        if LineUtil.distanceSquared(p.0, p.1, q.0, q.1) < thr * thr { return true }
      }
    }
    guard type != DrawAttr.paintStroke else { return false }
    let handles = handleArray(nil)
    return quadCurveContains(
      x1: Double(handles[0].x), y1: Double(handles[0].y), xc: Double(handles[1].x),
      yc: Double(handles[1].y), x2: Double(handles[2].x), y2: Double(handles[2].y),
      x: Double(loc.x), y: Double(loc.y))
  }

  public override var attributes: [AnyAttribute] { DrawAttr.fillAttributes(for: getPaintType()) }

  public override var bounds: Bounds { boundsValue }

  public var control: Location { p1Value }
  public var end0: Location { p0Value }
  public var end1: Location { p2Value }

  public override var displayName: String { "Curve" }

  private func handleArray(_ gesture: HandleGesture?) -> [Handle] {
    guard let gesture else {
      return [Handle(self, p0Value), Handle(self, p1Value), Handle(self, p2Value)]
    }

    let g = gesture.handle
    var gx = g.x + gesture.deltaX
    var gy = g.y + gesture.deltaY
    var ret = [Handle(self, p0Value), Handle(self, p1Value), Handle(self, p2Value)]

    if g.isAt(p0Value) {
      ret[0] =
        gesture.isShiftDown
        ? Handle(self, LineUtil.snapTo8Cardinals(p2Value, gx, gy)) : Handle(self, gx, gy)
    } else if g.isAt(p2Value) {
      ret[2] =
        gesture.isShiftDown
        ? Handle(self, LineUtil.snapTo8Cardinals(p0Value, gx, gy)) : Handle(self, gx, gy)
    } else if g.isAt(p1Value) {
      if gesture.isShiftDown {
        let x0 = p0Value.x
        let y0 = p0Value.y
        let x1 = p2Value.x
        let y1 = p2Value.y
        let midx = (x0 + x1) / 2
        let midy = (y0 + y1) / 2
        let dx = x1 - x0
        let dy = y1 - y0
        let p = LineUtil.nearestPointInfinite(
          Double(gx), Double(gy), Double(midx), Double(midy), Double(midx - dy), Double(midy + dx))
        gx = Int(p.0.rounded())
        gy = Int(p.1.rounded())
      }
      if gesture.isAltDown {
        let e0 = (Double(p0Value.x), Double(p0Value.y))
        let e1 = (Double(p2Value.x), Double(p2Value.y))
        let mid = (Double(gx), Double(gy))
        let ct = CurveUtil.interpolate(e0, e1, mid)
        gx = Int(ct.0.rounded())
        gy = Int(ct.1.rounded())
      }
      ret[1] = Handle(self, gx, gy)
    }
    return ret
  }

  public override func handles(_ gesture: HandleGesture?) -> [Handle] { handleArray(gesture) }

  public override func matches(_ other: CanvasObject) -> Bool {
    guard let that = other as? Curve else { return false }
    return self.p0Value == that.p0Value && self.p1Value == that.p1Value
      && self.p2Value == that.p2Value && matchesFillable(that)
  }

  public override func matchesHashCode() -> Int {
    var ret = p0Value.hashValue
    ret = ret &* 31 &* 31 &+ p1Value.hashValue
    ret = ret &* 31 &* 31 &+ p2Value.hashValue
    ret = ret &* 31 &+ matchesHashCodeFillable()
    return ret
  }

  public override func moveHandle(_ gesture: HandleGesture) -> Handle? {
    let hs = handleArray(gesture)
    var result: Handle?
    if hs[0].location != p0Value {
      p0Value = hs[0].location
      result = hs[0]
    }
    if hs[1].location != p1Value {
      p1Value = hs[1].location
      result = hs[1]
    }
    if hs[2].location != p2Value {
      p2Value = hs[2].location
      result = hs[2]
    }
    boundsValue = CurveUtil.getBounds(
      (Double(p0Value.x), Double(p0Value.y)), (Double(p1Value.x), Double(p1Value.y)),
      (Double(p2Value.x), Double(p2Value.y)))
    return result
  }

  public override func toSvgElement() -> SvgElement { SvgCreator.createCurve(self) }

  public override func translate(_ dx: Int, _ dy: Int) {
    p0Value = p0Value.translate(dx, dy)
    p1Value = p1Value.translate(dx, dy)
    p2Value = p2Value.translate(dx, dy)
    boundsValue = boundsValue.translate(dx, dy)
  }

  public override func cloned() -> CanvasObject {
    let copy = Curve(end0: p0Value, end1: p2Value, control: p1Value)
    copy.boundsValue = boundsValue
    copyFillableFields(into: copy)
    return copy
  }
}
