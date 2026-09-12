// Poly.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/draw/shapes/Poly.java. Copyright by the Logisim-evolution developers. This
// translation is a derivative work and is therefore licensed GPL-3.0-only. See LICENSE.md.
//
// Java caches the `GeneralPath` and the running-length table (`lens`, used by
// `getRandomPoint`) and invalidates them in `setHandles`. This port recomputes both on demand
// instead: behaviourally identical, just without the memoisation, which matters only for
// per-frame paint cost and this module does not paint (see `AbstractCanvasObject`'s header).

import Foundation
import LogisimKernel

/// Java's `Poly(boolean, List<Location>)` ends in `recomputeBounds()`, which reads `handles[0]`
/// with no length check (`Poly.java:369`). Handed an empty point list it therefore raises
/// `ArrayIndexOutOfBoundsException`: unchecked, but entirely catchable, and the appearance
/// loader that turns a `.circ` `<appear>` section into shapes does catch it, so the file is
/// reported as a load error rather than killing the JVM. `<polygon points=""/>` (or
/// `<polyline points=""/>`) in a saved file reaches it directly. Per D13 that becomes a Swift
/// `throw`, never a trap: a malformed appearance must not take the process down with the user's
/// unsaved work in it.
public enum PolyError: Error, CustomStringConvertible, Equatable {
  case noPoints(closed: Bool)

  public var description: String {
    switch self {
    case .noPoints(let closed):
      return "\(closed ? "polygon" : "polyline") has no points"
    }
  }
}

/// `com.cburch.draw.shapes.Poly`: a polygon (`closed == true`) or polyline (`closed == false`).
public final class Poly: FillableCanvasObject {
  private let closedValue: Bool
  private var handlesValue: [Handle]
  private var boundsValue: Bounds

  /// Throws `PolyError.noPoints` where Java's constructor lets `recomputeBounds()` raise
  /// `ArrayIndexOutOfBoundsException` on an empty point list. See `PolyError`.
  public init(closed: Bool, locations: [Location]) throws {
    self.closedValue = closed
    self.handlesValue = []
    self.boundsValue = .empty
    super.init()
    self.handlesValue = locations.map { Handle(self, $0.x, $0.y) }
    try recomputeBounds()
  }

  private init(closed: Bool) {
    self.closedValue = closed
    self.handlesValue = []
    self.boundsValue = .empty
    super.init()
  }

  public var isClosed: Bool { closedValue }

  public override func canDeleteHandle(_ loc: Location) -> Handle? {
    let minHandles = closedValue ? 3 : 2
    let hs = handlesValue
    guard hs.count > minHandles else { return nil }
    let qx = Double(loc.x)
    let qy = Double(loc.y)
    let w = Double(max(Line.onLineThresh, Int(getStrokeWidth()) / 2))
    for h in hs {
      // Bug-for-bug: Java compares a *linear* distance to a *squared* threshold
      // (`LineUtil.distance(...) < w * w`), not `distanceSquared(...) < w * w` as the surrounding
      // code elsewhere in this file does. Preserved verbatim.
      if LineUtil.distance(qx, qy, Double(h.x), Double(h.y)) < w * w {
        return h
      }
    }
    return nil
  }

  public override func canInsertHandle(_ desired: Location) -> Handle? {
    guard let result = PolyUtil.getClosestPoint(desired, closed: closedValue, handlesValue) else {
      return nil
    }
    let thresh = Double(max(Line.onLineThresh, Int(getStrokeWidth()) / 2))
    guard result.distanceSq < thresh * thresh, let resLoc = result.location else { return nil }
    if result.previousHandle?.isAt(resLoc) == true || result.nextHandle?.isAt(resLoc) == true {
      return nil
    }
    return Handle(self, resLoc)
  }

  public override func canMoveHandle(_ handle: Handle) -> Bool { true }

  public override func contains(_ loc: Location, assumeFilled: Bool) -> Bool {
    var type = getPaintType()
    if assumeFilled && type == DrawAttr.paintStroke { type = DrawAttr.paintStrokeFill }
    if type == DrawAttr.paintStroke {
      let thresh = Double(max(Line.onLineThresh, Int(getStrokeWidth()) / 2))
      guard let result = PolyUtil.getClosestPoint(loc, closed: closedValue, handlesValue) else {
        return false
      }
      return result.distanceSq < thresh * thresh
    } else if type == DrawAttr.paintFill {
      return pathContains(loc)
    } else {
      if pathContains(loc) { return true }
      let width = Double(getStrokeWidth())
      guard let result = PolyUtil.getClosestPoint(loc, closed: closedValue, handlesValue) else {
        return false
      }
      return result.distanceSq < (width * width) / 4
    }
  }

  private func pathContains(_ loc: Location) -> Bool {
    PolyUtil.polygonContains(handlesValue.map { ($0.x, $0.y) }, px: loc.x, py: loc.y)
  }

  public override func deleteHandle(_ handle: Handle) -> Handle? {
    let hs = handlesValue
    var result: [Handle] = []
    result.reserveCapacity(hs.count - 1)
    var previous: Handle?
    var deleted = false
    for h in hs {
      if deleted {
        result.append(h)
      } else if h == handle {
        if previous == nil { previous = hs[hs.count - 1] }
        deleted = true
      } else {
        previous = h
        result.append(h)
      }
    }
    setHandles(result)
    return previous
  }

  public override var attributes: [AnyAttribute] { DrawAttr.fillAttributes(for: getPaintType()) }

  public override var bounds: Bounds { boundsValue }

  public override var displayName: String { closedValue ? "Polygon" : "Polyline" }

  public override func handles(_ gesture: HandleGesture?) -> [Handle] {
    let hs = handlesValue
    guard let gesture else { return hs }

    let g = gesture.handle
    let n = hs.count
    var result: [Handle] = hs
    for (i, h) in hs.enumerated() where h == g {
      let x = h.x + gesture.deltaX
      let y = h.y + gesture.deltaY
      var r: Location
      if gesture.isShiftDown {
        var prev: Location? = hs[(i + n - 1) % n].location
        var next: Location? = hs[(i + 1) % n].location
        if !closedValue {
          if i == 0 { prev = nil }
          if i == n - 1 { next = nil }
        }
        if let prev, let next {
          let to = Location.create(x, y, hasToSnap: false)
          let a = LineUtil.snapTo8Cardinals(prev, x, y)
          let b = LineUtil.snapTo8Cardinals(next, x, y)
          let ad = a.manhattanDistance(to: to)
          let bd = b.manhattanDistance(to: to)
          r = ad < bd ? a : b
        } else if let next, prev == nil {
          r = LineUtil.snapTo8Cardinals(next, x, y)
        } else if let prev {
          r = LineUtil.snapTo8Cardinals(prev, x, y)
        } else {
          r = Location.create(x, y, hasToSnap: false)
        }
      } else {
        r = Location.create(x, y, hasToSnap: false)
      }
      result[i] = Handle(self, r)
    }
    return result
  }

  public override func randomPoint(in bounds: Bounds, using rng: inout SystemRandomNumberGenerator)
    -> Location?
  {
    guard getPaintType() == DrawAttr.paintStroke else {
      return super.randomPoint(in: bounds, using: &rng)
    }
    guard var ret = randomBoundaryPoint(using: &rng) else { return nil }
    let w = Int(getStrokeWidth())
    if w > 1 {
      let dx = Int.random(in: 0..<w, using: &rng) - w / 2
      let dy = Int.random(in: 0..<w, using: &rng) - w / 2
      ret = ret.translate(dx, dy)
    }
    return ret
  }

  private func randomBoundaryPoint(using rng: inout SystemRandomNumberGenerator) -> Location? {
    let hs = handlesValue
    guard !hs.isEmpty else { return nil }
    var lens = [Double](repeating: 0, count: hs.count + (closedValue ? 1 : 0))
    var total = 0.0
    for i in 0..<lens.count {
      let j = (i + 1) % hs.count
      total += LineUtil.distance(Double(hs[i].x), Double(hs[i].y), Double(hs[j].x), Double(hs[j].y))
      lens[i] = total
    }
    guard let last = lens.last, last > 0 else { return nil }
    let pos = last * Double.random(in: 0..<1, using: &rng)
    for i in 0..<lens.count where pos < lens[i] {
      let p = hs[i]
      let q = hs[(i + 1) % hs.count]
      let u = Double.random(in: 0..<1, using: &rng)
      let x = Int((Double(p.x) + u * Double(q.x - p.x)).rounded())
      let y = Int((Double(p.y) + u * Double(q.y - p.y)).rounded())
      return Location.create(x, y, hasToSnap: false)
    }
    return nil
  }

  public override func insertHandle(_ desired: Handle, after previous: Handle?) throws {
    let loc = desired.location
    let hs = handlesValue
    let prev: Handle
    if let previous {
      prev = previous
    } else {
      guard let closest = PolyUtil.getClosestPoint(loc, closed: closedValue, hs),
        let closestPrev = closest.previousHandle
      else {
        throw CanvasModelError.insertHandleTargetMissing
      }
      prev = closestPrev
    }
    var result: [Handle] = []
    result.reserveCapacity(hs.count + 1)
    var inserted = false
    for h in hs {
      if inserted {
        result.append(h)
      } else if h == prev {
        inserted = true
        result.append(h)
        result.append(desired)
      } else {
        result.append(h)
      }
    }
    guard inserted else { throw CanvasModelError.insertHandleTargetMissing }
    setHandles(result)
  }

  public override func matches(_ other: CanvasObject) -> Bool {
    guard let that = other as? Poly else { return false }
    let a = self.handlesValue
    let b = that.handlesValue
    guard self.closedValue == that.closedValue, a.count == b.count else { return false }
    for i in 0..<a.count where a[i] != b[i] { return false }
    return matchesFillable(that)
  }

  public override func matchesHashCode() -> Int {
    var ret = matchesHashCodeFillable()
    ret = ret &* 3 &+ (closedValue ? 1 : 0)
    for h in handlesValue { ret = ret &* 31 &+ h.hashValue }
    return ret
  }

  public override func moveHandle(_ gesture: HandleGesture) -> Handle? {
    setHandles(handles(gesture))
    return nil
  }

  /// `recomputeBounds()`. Java indexes `hs[0]` unguarded; see `PolyError` for why the empty case
  /// is a `throw` here instead of the trap Swift's own bounds check would give.
  private func recomputeBounds() throws {
    let hs = handlesValue
    guard let first = hs.first else { throw PolyError.noPoints(closed: closedValue) }
    var x0 = first.x
    var y0 = first.y
    var x1 = x0
    var y1 = y0
    for h in hs.dropFirst() {
      if h.x < x0 { x0 = h.x }
      if h.x > x1 { x1 = h.x }
      if h.y < y0 { y0 = h.y }
      if h.y > y1 { y1 = h.y }
    }
    let bds = Bounds.create(x0, y0, x1 - x0 + 1, y1 - y0 + 1)
    let stroke = Int(getStrokeWidth())
    boundsValue = stroke < 2 ? bds : bds.expand(stroke / 2)
  }

  /// `setHandles(Handle[])`. Unlike the constructor this can never be handed an empty array: the
  /// only caller that shrinks `handles` is `deleteHandle`, which the canvas invokes only after
  /// `canDeleteHandle` has proved there are strictly more than `minHandles` (3 closed, 2 open) of
  /// them; `insertHandle` grows, and `moveHandle`/`translate` preserve the count. With the
  /// constructor now rejecting an empty list, no `.circ` file can reach this, which is exactly
  /// the "internal invariant a caller cannot violate from a file" case D13 leaves trapping.
  private func setHandles(_ hs: [Handle]) {
    handlesValue = hs
    do {
      try recomputeBounds()
    } catch {
      preconditionFailure("Poly.setHandles: \(error)")
    }
  }

  public override func toSvgElement() -> SvgElement { SvgCreator.createPoly(self) }

  public override func translate(_ dx: Int, _ dy: Int) {
    setHandles(handlesValue.map { Handle(self, $0.x + dx, $0.y + dy) })
  }

  /// `getHandles(null)`, in bottom-to-top order; used directly by `SvgCreator.createPoly`.
  public var currentHandles: [Handle] { handlesValue }

  public override func cloned() -> CanvasObject {
    let copy = Poly(closed: closedValue)
    copy.handlesValue = handlesValue.map { Handle(copy, $0.x, $0.y) }
    copy.boundsValue = boundsValue
    copyFillableFields(into: copy)
    return copy
  }
}
