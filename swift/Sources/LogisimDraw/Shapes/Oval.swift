// Oval.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/draw/shapes/Oval.java. Copyright by the Logisim-evolution developers. This
// translation is a derivative work and is therefore licensed GPL-3.0-only. See LICENSE.md.

import Foundation
import LogisimKernel

/// `com.cburch.draw.shapes.Oval`.
public final class Oval: Rectangular {
  public override init(x: Int, y: Int, w: Int, h: Int) {
    super.init(x: x, y: y, w: w, h: h)
  }

  public override func containsRaw(x: Int, y: Int, w: Int, h: Int, at q: Location) -> Bool {
    let qx = Double(q.x)
    let qy = Double(q.y)
    let dx = qx - (Double(x) + 0.5 * Double(w))
    let dy = qy - (Double(y) + 0.5 * Double(h))
    let sum = (dx * dx) / (Double(w) * Double(w)) + (dy * dy) / (Double(h) * Double(h))
    return sum <= 0.25
  }

  public override var attributes: [AnyAttribute] { DrawAttr.fillAttributes(for: getPaintType()) }

  public override var displayName: String { "Oval" }

  public override func randomPoint(in bounds: Bounds, using rng: inout SystemRandomNumberGenerator)
    -> Location?
  {
    guard getPaintType() == DrawAttr.paintStroke else {
      return super.randomPoint(in: bounds, using: &rng)
    }
    let rx = Double(width) / 2.0
    let ry = Double(height) / 2.0
    let u = 2 * Double.pi * Double.random(in: 0..<1, using: &rng)
    var x = Int((Double(self.x) + rx + rx * cos(u)).rounded())
    var y = Int((Double(self.y) + ry + ry * sin(u)).rounded())
    let d = Int(getStrokeWidth())
    if d > 1 {
      x += Int.random(in: 0..<d, using: &rng) - d / 2
      y += Int.random(in: 0..<d, using: &rng) - d / 2
    }
    return Location.create(x, y, hasToSnap: false)
  }

  public override func matches(_ other: CanvasObject) -> Bool {
    guard let that = other as? Oval else { return false }
    return matchesRectangular(that)
  }

  public override func matchesHashCode() -> Int { matchesHashCodeRectangular() }

  public override func toSvgElement() -> SvgElement { SvgCreator.createOval(self) }

  public override func cloned() -> CanvasObject {
    let copy = Oval(x: x, y: y, w: width, h: height)
    copyRectangularFields(into: copy)
    return copy
  }
}
