// Line.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/draw/shapes/Line.java. Copyright by the Logisim-evolution developers. This
// translation is a derivative work and is therefore licensed GPL-3.0-only. See LICENSE.md.

import LogisimKernel

/// `com.cburch.draw.shapes.Line`.
public final class Line: AbstractCanvasObject {
  /// `Line.ON_LINE_THRESH`; package-visible in Java (`Rectangular` reads it too); `public`
  /// here since Swift has no package-private, but it is not part of the intended external API.
  public static let onLineThresh = 2

  private var x0Value: Int
  private var y0Value: Int
  private var x1Value: Int
  private var y1Value: Int
  private var boundsValue: Bounds
  private var strokeWidthValue: Int32 = 1
  private var strokeColorValue: ColorSpec = .black

  public init(x0: Int, y0: Int, x1: Int, y1: Int) {
    self.x0Value = x0
    self.y0Value = y0
    self.x1Value = x1
    self.y1Value = y1
    self.boundsValue = Bounds.create(x0, y0, 0, 0).add(x1, y1)
    super.init()
  }

  public override func canMoveHandle(_ handle: Handle) -> Bool { true }

  public override func contains(_ loc: Location, assumeFilled: Bool) -> Bool {
    let d = LineUtil.ptDistSqSegment(
      Double(x0Value), Double(y0Value), Double(x1Value), Double(y1Value), Double(loc.x),
      Double(loc.y))
    let thresh = Double(max(Line.onLineThresh, Int(strokeWidthValue) / 2))
    return d < thresh * thresh
  }

  public override var attributes: [AnyAttribute] { DrawAttr.attrsStroke }

  public override var bounds: Bounds { boundsValue }

  public override var displayName: String { "Line" }

  public var end0: Location { Location.create(x0Value, y0Value, hasToSnap: false) }
  public var end1: Location { Location.create(x1Value, y1Value, hasToSnap: false) }

  public override func handles(_ gesture: HandleGesture?) -> [Handle] {
    guard let gesture else {
      return [Handle(self, x0Value, y0Value), Handle(self, x1Value, y1Value)]
    }
    let h = gesture.handle
    let dx = gesture.deltaX
    let dy = gesture.deltaY
    let p0 =
      h.isAt(x0Value, y0Value)
      ? Location.create(x0Value + dx, y0Value + dy, hasToSnap: false)
      : Location.create(x0Value, y0Value, hasToSnap: false)
    let p1 =
      h.isAt(x1Value, y1Value)
      ? Location.create(x1Value + dx, y1Value + dy, hasToSnap: false)
      : Location.create(x1Value, y1Value, hasToSnap: false)
    return [Handle(self, p0), Handle(self, p1)]
  }

  public override func randomPoint(in bounds: Bounds, using rng: inout SystemRandomNumberGenerator)
    -> Location?
  {
    let u = Double.random(in: 0..<1, using: &rng)
    var x = Int((Double(x0Value) + u * Double(x1Value - x0Value)).rounded())
    var y = Int((Double(y0Value) + u * Double(y1Value - y0Value)).rounded())
    let w = Int(strokeWidthValue)
    if w > 1 {
      x += Int.random(in: 0..<w, using: &rng) - w / 2
      y += Int.random(in: 0..<w, using: &rng) - w / 2
    }
    return Location.create(x, y, hasToSnap: false)
  }

  public override func rawValue(_ attribute: AnyAttribute) -> AttributeValue? {
    if attribute === DrawAttr.strokeColor { return .color(strokeColorValue) }
    if attribute === DrawAttr.strokeWidth { return .integer(strokeWidthValue) }
    return nil
  }

  public override func setRawValue(_ attribute: AnyAttribute, _ value: AttributeValue?) throws {
    if attribute === DrawAttr.strokeColor {
      guard case .color(let color)? = value else { return }
      strokeColorValue = color
    } else if attribute === DrawAttr.strokeWidth {
      guard case .integer(let width)? = value else { return }
      strokeWidthValue = width
    }
  }

  /// `Line.matches`: note the Java source compares `y0 == that.x1` (not `that.y0`), which
  /// looks like a typo but is what upstream ships; a fidelity port does not silently correct it.
  /// In practice this makes `matches` almost never return true for two distinct `Line`
  /// instances unless `y0 == x1` for both, which only matters to `MatchingSet` deduplication:
  /// never to file I/O.
  public override func matches(_ other: CanvasObject) -> Bool {
    guard let that = other as? Line else { return false }
    return self.x0Value == that.x0Value
      && self.y0Value == that.x1Value
      && self.x1Value == that.y0Value
      && self.y1Value == that.y1Value
      && self.strokeWidthValue == that.strokeWidthValue
      && self.strokeColorValue == that.strokeColorValue
  }

  public override func matchesHashCode() -> Int {
    var ret = x0Value &* 31 &+ y0Value
    ret = ret &* 31 &* 31 &+ x1Value &* 31 &+ y1Value
    ret = ret &* 31 &+ Int(strokeWidthValue)
    ret = ret &* 31 &+ strokeColorValue.hashValue
    return ret
  }

  public override func moveHandle(_ gesture: HandleGesture) -> Handle? {
    let h = gesture.handle
    let dx = gesture.deltaX
    let dy = gesture.deltaY
    var result: Handle?
    if h.isAt(x0Value, y0Value) {
      x0Value += dx
      y0Value += dy
      result = Handle(self, x0Value, y0Value)
    }
    if h.isAt(x1Value, y1Value) {
      x1Value += dx
      y1Value += dy
      result = Handle(self, x1Value, y1Value)
    }
    boundsValue = Bounds.create(x0Value, y0Value, 0, 0).add(x1Value, y1Value)
    return result
  }

  /// Bug-for-bug: Java's `Line.translate` updates the endpoint fields but never recomputes
  /// `bounds`; only `moveHandle` does that. `getBounds()` is therefore stale after a plain
  /// translate until the next handle move. Preserved verbatim; not fixed here.
  public override func translate(_ dx: Int, _ dy: Int) {
    x0Value += dx
    y0Value += dy
    x1Value += dx
    y1Value += dy
  }

  public override func toSvgElement() -> SvgElement { SvgCreator.createLine(self) }

  public override func cloned() -> CanvasObject {
    let copy = Line(x0: x0Value, y0: y0Value, x1: x1Value, y1: y1Value)
    copy.strokeWidthValue = strokeWidthValue
    copy.strokeColorValue = strokeColorValue
    return copy
  }
}
