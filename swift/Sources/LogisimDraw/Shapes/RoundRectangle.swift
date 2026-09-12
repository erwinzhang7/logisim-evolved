// RoundRectangle.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/draw/shapes/RoundRectangle.java. Copyright by the Logisim-evolution developers.
// This translation is a derivative work and is therefore licensed GPL-3.0-only. See LICENSE.md.

import Foundation
import LogisimKernel

/// `com.cburch.draw.shapes.RoundRectangle`.
public final class RoundRectangle: Rectangular {
  private var radiusValue: Int32 = 10

  public override init(x: Int, y: Int, w: Int, h: Int) {
    super.init(x: x, y: y, w: w, h: h)
  }

  private static func inCircle(
    _ qx: Int, _ qy: Int, _ cx: Int, _ cy: Int, _ rx: Int, _ ry: Int
  ) -> Bool {
    let dx = Double(qx - cx)
    let dy = Double(qy - cy)
    let sum = (dx * dx) / (4 * Double(rx) * Double(rx)) + (dy * dy) / (4 * Double(ry) * Double(ry))
    return sum <= 0.25
  }

  public override func containsRaw(x: Int, y: Int, w: Int, h: Int, at q: Location) -> Bool {
    let qx = q.x
    let qy = q.y
    var rx = Int(radiusValue)
    var ry = Int(radiusValue)
    if 2 * rx > w { rx = w / 2 }
    if 2 * ry > h { ry = h / 2 }
    if !isInRect(qx, qy, x, y, w, h) {
      return false
    } else if qx < x + rx {
      if qy < y + ry { return Self.inCircle(qx, qy, x + rx, y + ry, rx, ry) }
      if qy < y + h - ry { return true }
      return Self.inCircle(qx, qy, x + rx, y + h - ry, rx, ry)
    } else if qx < x + w - rx {
      return true
    } else {
      if qy < y + ry { return Self.inCircle(qx, qy, x + w - rx, y + ry, rx, ry) }
      if qy < y + h - ry { return true }
      return Self.inCircle(qx, qy, x + w - rx, y + h - ry, rx, ry)
    }
  }

  public override var attributes: [AnyAttribute] {
    DrawAttr.roundRectAttributes(for: getPaintType())
  }

  public override var displayName: String { "Round Rectangle" }

  public override func randomPoint(in bounds: Bounds, using rng: inout SystemRandomNumberGenerator)
    -> Location?
  {
    guard getPaintType() == DrawAttr.paintStroke else {
      return super.randomPoint(in: bounds, using: &rng)
    }
    let w = width
    let h = height
    let r = Int(radiusValue)
    let horz = max(0, w - 2 * r)
    let vert = max(0, h - 2 * r)
    let len = Double(2 * horz + 2 * vert) + 2 * Double.pi * Double(r)
    guard len > 0 else { return nil }
    var u = len * Double.random(in: 0..<1, using: &rng)
    var x = self.x
    var y = self.y

    if u < Double(horz) {
      x += r + Int(u)
    } else if u < Double(2 * horz) {
      x += r + Int(u - Double(horz))
      y += h
    } else if u < Double(2 * horz + vert) {
      y += r + Int(u - Double(2 * horz))
    } else if u < Double(2 * horz + 2 * vert) {
      x += w
      y += Int(u - Double(2 * w) - Double(h))
    } else {
      var rx = Int(radiusValue)
      var ry = Int(radiusValue)
      if 2 * rx > w { rx = w / 2 }
      if 2 * ry > h { ry = h / 2 }
      u = 2 * Double.pi * Double.random(in: 0..<1, using: &rng)
      let dx = Int((Double(rx) * cos(u)).rounded())
      let dy = Int((Double(ry) * sin(u)).rounded())
      x += (dx < 0) ? (r + dx) : (r + horz + dx)
      y += (dy < 0) ? (r + dy) : (r + vert + dy)
    }

    let d = Int(getStrokeWidth())
    if d > 1 {
      x += Int.random(in: 0..<d, using: &rng) - d / 2
      y += Int.random(in: 0..<d, using: &rng) - d / 2
    }
    return Location.create(x, y, hasToSnap: false)
  }

  public override func rawValue(_ attribute: AnyAttribute) -> AttributeValue? {
    if attribute === DrawAttr.cornerRadius { return .integer(radiusValue) }
    return super.rawValue(attribute)
  }

  public override func setRawValue(_ attribute: AnyAttribute, _ value: AttributeValue?) throws {
    if attribute === DrawAttr.cornerRadius {
      guard case .integer(let radius)? = value else { return }
      radiusValue = radius
    } else {
      try super.setRawValue(attribute, value)
    }
  }

  public override func matches(_ other: CanvasObject) -> Bool {
    guard let that = other as? RoundRectangle else { return false }
    return matchesRectangular(that) && self.radiusValue == that.radiusValue
  }

  public override func matchesHashCode() -> Int {
    matchesHashCodeRectangular() &* 31 &+ Int(radiusValue)
  }

  public override func toSvgElement() -> SvgElement { SvgCreator.createRoundRectangle(self) }

  public var cornerRadius: Int32 { radiusValue }

  public override func cloned() -> CanvasObject {
    let copy = RoundRectangle(x: x, y: y, w: width, h: height)
    copyRectangularFields(into: copy)
    copy.radiusValue = radiusValue
    return copy
  }
}
