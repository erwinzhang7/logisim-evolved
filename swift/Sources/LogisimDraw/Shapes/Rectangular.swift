// Rectangular.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/draw/shapes/Rectangular.java. Copyright by the Logisim-evolution developers. This
// translation is a derivative work and is therefore licensed GPL-3.0-only. See LICENSE.md.
//
// `draw(Graphics, x, y, w, h)` is dropped (no drawing code here); the geometry it would have
// painted is exactly `getX()`/`getY()`/`getWidth()`/`getHeight()` plus the per-shape
// `containsRaw` test, which the renderer already has to consult for hit-testing and can equally
// use to know what to draw.

import LogisimKernel

/// `com.cburch.draw.shapes.Rectangular`: abstract base for `Rectangle`, `Oval`, and
/// `RoundRectangle`.
open class Rectangular: FillableCanvasObject {
  private var boundsValue: Bounds

  public init(x: Int, y: Int, w: Int, h: Int) {
    boundsValue = Bounds.create(x, y, w, h)
    super.init()
  }

  open override func canMoveHandle(_ handle: Handle) -> Bool { true }

  /// `Rectangular.contains(int,int,int,int,Location)`: the per-shape raw hit test against an
  /// axis-aligned box `(x,y,w,h)`. Abstract in Java; overridden by `Rectangle` (box test),
  /// `Oval` (ellipse test), and `RoundRectangle` (rounded-box test).
  open func containsRaw(x: Int, y: Int, w: Int, h: Int, at q: Location) -> Bool {
    fatalError("Rectangular subclasses must override `containsRaw(x:y:w:h:at:)`")
  }

  open override func contains(_ loc: Location, assumeFilled: Bool) -> Bool {
    var type = getPaintType()
    if assumeFilled && type == DrawAttr.paintStroke { type = DrawAttr.paintStrokeFill }
    let b = boundsValue
    let x = b.x
    let y = b.y
    let w = b.width
    let h = b.height
    let qx = loc.x
    let qy = loc.y
    if type == DrawAttr.paintFill {
      return isInRect(qx, qy, x, y, w, h) && containsRaw(x: x, y: y, w: w, h: h, at: loc)
    } else if type == DrawAttr.paintStroke {
      let stroke = Int(getStrokeWidth())
      let tol2 = max(2 * Line.onLineThresh, stroke)
      let tol = tol2 / 2
      return isInRect(qx, qy, x - tol, y - tol, w + tol2, h + tol2)
        && containsRaw(x: x - tol, y: y - tol, w: w + tol2, h: h + tol2, at: loc)
        && !containsRaw(x: x + tol, y: y + tol, w: w - tol2, h: h - tol2, at: loc)
    } else if type == DrawAttr.paintStrokeFill {
      let strokeWidth = Int(getStrokeWidth())
      let tol = strokeWidth / 2
      return isInRect(qx, qy, x - tol, y - tol, w + strokeWidth, h + strokeWidth)
        && containsRaw(x: x - tol, y: y - tol, w: w + strokeWidth, h: h + strokeWidth, at: loc)
    }
    return false
  }

  open override var bounds: Bounds {
    let wid = Int(getStrokeWidth())
    let type = getPaintType()
    return (wid < 2 || type == DrawAttr.paintFill) ? boundsValue : boundsValue.expand(wid / 2)
  }

  private func handleArray(_ gesture: HandleGesture?) -> [Handle] {
    let bds = boundsValue
    let x0 = bds.x
    let y0 = bds.y
    let x1 = x0 + bds.width
    let y1 = y0 + bds.height

    guard let gesture else {
      return [
        Handle(self, x0, y0), Handle(self, x1, y0), Handle(self, x1, y1), Handle(self, x0, y1),
      ]
    }

    let hx = gesture.handle.x
    let hy = gesture.handle.y
    let dx = gesture.deltaX
    let dy = gesture.deltaY
    var newX0 = x0 == hx ? x0 + dx : x0
    var newY0 = y0 == hy ? y0 + dy : y0
    var newX1 = x1 == hx ? x1 + dx : x1
    var newY1 = y1 == hy ? y1 + dy : y1

    if gesture.isShiftDown {
      if gesture.isAltDown {
        if x0 == hx { newX1 -= dx }
        if x1 == hx { newX0 -= dx }
        if y0 == hy { newY1 -= dy }
        if y1 == hy { newY0 -= dy }

        let w = abs(newX1 - newX0)
        let h = abs(newY1 - newY0)
        if w > h {
          let dw = (w - h) / 2
          newX0 -= (newX0 > newX1 ? 1 : -1) * dw
          newX1 -= (newX1 > newX0 ? 1 : -1) * dw
        } else {
          let dh = (h - w) / 2
          newY0 -= (newY0 > newY1 ? 1 : -1) * dh
          newY1 -= (newY1 > newY0 ? 1 : -1) * dh
        }
      } else {
        let w = abs(newX1 - newX0)
        let h = abs(newY1 - newY0)
        if w > h {
          if x0 == hx { newX0 = newX1 + (newX0 > newX1 ? 1 : -1) * h }
          if x1 == hx { newX1 = newX0 + (newX1 > newX0 ? 1 : -1) * h }
        } else {
          if y0 == hy { newY0 = newY1 + (newY0 > newY1 ? 1 : -1) * w }
          if y1 == hy { newY1 = newY0 + (newY1 > newY0 ? 1 : -1) * w }
        }
      }
    } else if gesture.isAltDown {
      if x0 == hx { newX1 -= dx }
      if x1 == hx { newX0 -= dx }
      if y0 == hy { newY1 -= dy }
      if y1 == hy { newY0 -= dy }
    }

    return [
      Handle(self, newX0, newY0), Handle(self, newX1, newY0), Handle(self, newX1, newY1),
      Handle(self, newX0, newY1),
    ]
  }

  open override func handles(_ gesture: HandleGesture?) -> [Handle] { handleArray(gesture) }

  public var height: Int { boundsValue.height }
  public var width: Int { boundsValue.width }
  public var x: Int { boundsValue.x }
  public var y: Int { boundsValue.y }

  func isInRect(_ qx: Int, _ qy: Int, _ x0: Int, _ y0: Int, _ w: Int, _ h: Int) -> Bool {
    qx >= x0 && qx < x0 + w && qy >= y0 && qy < y0 + h
  }

  /// Base structural comparison shared by `Rectangle`/`Oval`/`RoundRectangle`: bounds plus the
  /// inherited fillable-attribute comparison. Leaf classes call this from their own `matches`
  /// after checking their own runtime type (and, for `RoundRectangle`, the corner radius).
  public func matchesRectangular(_ other: Rectangular) -> Bool {
    boundsValue == other.boundsValue && matchesFillable(other)
  }

  public func matchesHashCodeRectangular() -> Int {
    boundsValue.hashValue &* 31 &+ matchesHashCodeFillable()
  }

  open override func moveHandle(_ gesture: HandleGesture) -> Handle? {
    let oldHandles = handleArray(nil)
    let newHandles = handleArray(gesture)
    let moved = gesture.handle
    var result: Handle?
    var x0 = Int.max
    var x1 = Int.min
    var y0 = Int.max
    var y1 = Int.min
    for (i, h) in newHandles.enumerated() {
      if oldHandles[i] == moved { result = h }
      if h.x < x0 { x0 = h.x }
      if h.x > x1 { x1 = h.x }
      if h.y < y0 { y0 = h.y }
      if h.y > y1 { y1 = h.y }
    }
    boundsValue = Bounds.create(x0, y0, x1 - x0, y1 - y0)
    return result
  }

  open override func translate(_ dx: Int, _ dy: Int) {
    boundsValue = boundsValue.translate(dx, dy)
  }

  /// Copies the raw (unexpanded) bounds into a freshly-constructed sibling, exactly like
  /// `copyFillableFields`; used by leaf `cloned()` overrides.
  public func copyRectangularFields(into other: Rectangular) {
    copyFillableFields(into: other)
    other.boundsValue = boundsValue
  }
}
