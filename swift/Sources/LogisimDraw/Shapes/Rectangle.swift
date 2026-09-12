// Rectangle.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/draw/shapes/Rectangle.java. Copyright by the Logisim-evolution developers. This
// translation is a derivative work and is therefore licensed GPL-3.0-only. See LICENSE.md.

import LogisimKernel

/// `com.cburch.draw.shapes.Rectangle`.
public final class DrawRectangle: Rectangular {
  public override init(x: Int, y: Int, w: Int, h: Int) {
    super.init(x: x, y: y, w: w, h: h)
  }

  public override func containsRaw(x: Int, y: Int, w: Int, h: Int, at q: Location) -> Bool {
    isInRect(q.x, q.y, x, y, w, h)
  }

  public override var attributes: [AnyAttribute] { DrawAttr.fillAttributes(for: getPaintType()) }

  public override var displayName: String { "Rectangle" }

  public override func randomPoint(in bounds: Bounds, using rng: inout SystemRandomNumberGenerator)
    -> Location?
  {
    guard getPaintType() == DrawAttr.paintStroke else {
      return super.randomPoint(in: bounds, using: &rng)
    }
    let w = width
    let h = height
    guard w + h > 0 else { return nil }
    let u = Int.random(in: 0..<(2 * w + 2 * h), using: &rng)
    var x = self.x
    var y = self.y
    if u < w {
      x += u
    } else if u < 2 * w {
      x += (u - w)
      y += h
    } else if u < 2 * w + h {
      y += (u - 2 * w)
    } else {
      x += w
      y += (u - 2 * w - h)
    }
    let d = Int(getStrokeWidth())
    if d > 1 {
      x += Int.random(in: 0..<d, using: &rng) - d / 2
      y += Int.random(in: 0..<d, using: &rng) - d / 2
    }
    return Location.create(x, y, hasToSnap: false)
  }

  public override func matches(_ other: CanvasObject) -> Bool {
    guard let that = other as? DrawRectangle else { return false }
    return matchesRectangular(that)
  }

  public override func matchesHashCode() -> Int { matchesHashCodeRectangular() }

  public override func toSvgElement() -> SvgElement { SvgCreator.createRectangle(self) }

  public override func cloned() -> CanvasObject {
    let copy = DrawRectangle(x: x, y: y, w: width, h: height)
    copyRectangularFields(into: copy)
    return copy
  }
}
