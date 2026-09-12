// LogisimRender: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// Geometry value types for the retained scene.
//
// Coordinates are `Int32` and live on the schematic's integer grid, exactly as the Java's
// `Graphics` int overloads do. Keeping them integral is not a micro-optimisation: it is what
// makes `GridSnap` able to reproduce Java2D's pixelisation, and it is what lets the M9 Metal
// backend pack a vertex as two shorts.

import Foundation
import LogisimKernel

// MARK: - ScenePoint

public struct ScenePoint: Hashable, Sendable {
  public var x: Int32
  public var y: Int32

  public init(x: Int32, y: Int32) {
    self.x = x
    self.y = y
  }

  public init(_ x: Int, _ y: Int) {
    self.x = clampToInt32(x)
    self.y = clampToInt32(y)
  }

  public init(_ location: Location) {
    self.init(location.x, location.y)
  }
}

@inlinable
public func clampToInt32(_ v: Int) -> Int32 {
  if v > Int(Int32.max) { return Int32.max }
  if v < Int(Int32.min) { return Int32.min }
  return Int32(v)
}

@inlinable
public func clampToInt32(_ v: Double) -> Int32 {
  if v.isNaN { return 0 }
  if v >= Double(Int32.max) { return Int32.max }
  if v <= Double(Int32.min) { return Int32.min }
  return Int32(v)
}

// MARK: - SceneBounds

/// Half-open axis-aligned box, `[minX, maxX) x [minY, maxY)`, used for culling only.
///
/// Deliberately *not* `LogisimKernel.Bounds`: that type carries an empty-sentinel identity and
/// Java's `x/y/width/height` semantics, which are the wrong shape for the min/max unions the
/// spatial index does thousands of times per frame.
public struct SceneBounds: Hashable, Sendable, CustomStringConvertible {
  public var minX: Int32
  public var minY: Int32
  public var maxX: Int32
  public var maxY: Int32

  public init(minX: Int32, minY: Int32, maxX: Int32, maxY: Int32) {
    self.minX = minX
    self.minY = minY
    self.maxX = maxX
    self.maxY = maxY
  }

  /// The inverted box. Unioning anything with it yields that thing.
  public static let empty = SceneBounds(
    minX: Int32.max, minY: Int32.max, maxX: Int32.min, maxY: Int32.min)

  public static let infinite = SceneBounds(
    minX: Int32.min, minY: Int32.min, maxX: Int32.max, maxY: Int32.max)

  public var isEmpty: Bool { minX > maxX || minY > maxY }

  /// From Java-style `x, y, width, height`.
  public init(x: Int, y: Int, width: Int, height: Int) {
    let x0 = min(x, x + width)
    let x1 = max(x, x + width)
    let y0 = min(y, y + height)
    let y1 = max(y, y + height)
    self.init(minX: clampToInt32(x0), minY: clampToInt32(y0),
              maxX: clampToInt32(x1), maxY: clampToInt32(y1))
  }

  public init(_ bounds: Bounds) {
    self.init(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
  }

  public init(points: [ScenePoint]) {
    var b = SceneBounds.empty
    for p in points { b.formUnion(point: p) }
    self = b
  }

  public var width: Int32 { isEmpty ? 0 : maxX - minX }
  public var height: Int32 { isEmpty ? 0 : maxY - minY }

  public mutating func formUnion(_ other: SceneBounds) {
    if other.isEmpty { return }
    if isEmpty { self = other; return }
    minX = Swift.min(minX, other.minX)
    minY = Swift.min(minY, other.minY)
    maxX = Swift.max(maxX, other.maxX)
    maxY = Swift.max(maxY, other.maxY)
  }

  public func union(_ other: SceneBounds) -> SceneBounds {
    var c = self
    c.formUnion(other)
    return c
  }

  public mutating func formUnion(point p: ScenePoint) {
    if isEmpty {
      self = SceneBounds(minX: p.x, minY: p.y, maxX: p.x, maxY: p.y)
      return
    }
    minX = Swift.min(minX, p.x)
    minY = Swift.min(minY, p.y)
    maxX = Swift.max(maxX, p.x)
    maxY = Swift.max(maxY, p.y)
  }

  /// Grows by `d` on every side, saturating.
  public func inset(by d: Int32) -> SceneBounds {
    if isEmpty { return self }
    return SceneBounds(
      minX: clampToInt32(Int(minX) - Int(d)),
      minY: clampToInt32(Int(minY) - Int(d)),
      maxX: clampToInt32(Int(maxX) + Int(d)),
      maxY: clampToInt32(Int(maxY) + Int(d)))
  }

  public func intersects(_ other: SceneBounds) -> Bool {
    if isEmpty || other.isEmpty { return false }
    return minX <= other.maxX && other.minX <= maxX
      && minY <= other.maxY && other.minY <= maxY
  }

  public func contains(x: Int32, y: Int32) -> Bool {
    !isEmpty && x >= minX && x <= maxX && y >= minY && y <= maxY
  }

  /// Back to the kernel's Java-shaped `Bounds`.
  public var kernelBounds: Bounds {
    if isEmpty { return .empty }
    return Bounds.create(Int(minX), Int(minY), Int(maxX - minX), Int(maxY - minY))
  }

  public var description: String {
    isEmpty ? "SceneBounds(empty)" : "SceneBounds(\(minX),\(minY))-(\(maxX),\(maxY))"
  }
}

// MARK: - SceneTransform

/// A 2D affine transform, in the same `[a b c d tx ty]` convention as `CGAffineTransform`.
///
/// Present because upstream genuinely needs it: `AbstractGate`, `NotGate`, `Buffer`,
/// `ControlledBuffer`, `DipSwitch`, `PortIo`, `PowerOnReset`, `PullResistor`, `Clock`,
/// `Transistor`, `TransmissionGate`, `Pin` and the whole `std/ttl` family rotate by
/// `facing.toRadians()`, and `Probe`/`Pin` scale by 0.7 for the radix glyph.
///
/// Pure integer *translation* never becomes a transform: the builder bakes it into the
/// emitted coordinates, which keeps 222 of upstream's `g.translate` sites on the exact-integer
/// path and keeps the transform pool at essentially zero entries for a typical schematic.
public struct SceneTransform: Hashable, Sendable {
  public var a: Double
  public var b: Double
  public var c: Double
  public var d: Double
  public var tx: Double
  public var ty: Double

  public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
    self.a = a
    self.b = b
    self.c = c
    self.d = d
    self.tx = tx
    self.ty = ty
  }

  public static let identity = SceneTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

  public var isIdentity: Bool { self == .identity }

  public static func translation(_ dx: Double, _ dy: Double) -> SceneTransform {
    SceneTransform(a: 1, b: 0, c: 0, d: 1, tx: dx, ty: dy)
  }

  public static func scale(_ sx: Double, _ sy: Double) -> SceneTransform {
    SceneTransform(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0)
  }

  /// Java `Graphics2D.rotate(theta)`: positive theta rotates from +x toward +y, which is
  /// clockwise on screen because y grows downward.
  public static func rotation(_ radians: Double) -> SceneTransform {
    let s = sin(radians)
    let c = cos(radians)
    return SceneTransform(a: c, b: s, c: -s, d: c, tx: 0, ty: 0)
  }

  /// Java `Graphics2D.rotate(theta, x, y)`.
  public static func rotation(_ radians: Double, aroundX x: Double, y: Double) -> SceneTransform {
    SceneTransform.translation(-x, -y)
      .concatenating(.rotation(radians))
      .concatenating(.translation(x, y))
  }

  /// `self` first, then `other`: the same order as `CGAffineTransform.concatenating`.
  public func concatenating(_ other: SceneTransform) -> SceneTransform {
    SceneTransform(
      a: a * other.a + b * other.c,
      b: a * other.b + b * other.d,
      c: c * other.a + d * other.c,
      d: c * other.b + d * other.d,
      tx: tx * other.a + ty * other.c + other.tx,
      ty: tx * other.b + ty * other.d + other.ty)
  }

  public func apply(x: Double, y: Double) -> (x: Double, y: Double) {
    (a * x + c * y + tx, b * x + d * y + ty)
  }

  /// Conservative transformed box: transforms the four corners and rounds outward.
  public func transform(_ bounds: SceneBounds) -> SceneBounds {
    if bounds.isEmpty || isIdentity { return bounds }
    let corners = [
      (Double(bounds.minX), Double(bounds.minY)),
      (Double(bounds.maxX), Double(bounds.minY)),
      (Double(bounds.minX), Double(bounds.maxY)),
      (Double(bounds.maxX), Double(bounds.maxY)),
    ]
    var lo = (x: Double.greatestFiniteMagnitude, y: Double.greatestFiniteMagnitude)
    var hi = (x: -Double.greatestFiniteMagnitude, y: -Double.greatestFiniteMagnitude)
    for (px, py) in corners {
      let t = apply(x: px, y: py)
      lo.x = Swift.min(lo.x, t.x); lo.y = Swift.min(lo.y, t.y)
      hi.x = Swift.max(hi.x, t.x); hi.y = Swift.max(hi.y, t.y)
    }
    return SceneBounds(
      minX: clampToInt32(lo.x.rounded(.down)),
      minY: clampToInt32(lo.y.rounded(.down)),
      maxX: clampToInt32(hi.x.rounded(.up)),
      maxY: clampToInt32(hi.y.rounded(.up)))
  }
}

// MARK: - ScenePath

/// One segment of a free-form path. Mirrors `java.awt.geom.GeneralPath`, which is what the
/// shaped-gate painters use (`PainterShaped.PATH_NARROW/MEDIUM/WIDE`, `computeShield`).
///
/// Coordinates are `Float` because `GeneralPath` is float and the gate paths are the only
/// place in the codebase with genuinely non-integral geometry.
public enum PathOp: Hashable, Sendable {
  case move(Float, Float)
  case line(Float, Float)
  case quad(Float, Float, Float, Float)
  case cubic(Float, Float, Float, Float, Float, Float)
  case close
}

/// A free-form path, built the way `GeneralPath` is.
public struct ScenePath: Hashable, Sendable {
  public private(set) var ops: [PathOp] = []
  public private(set) var controlBounds: SceneBounds = .empty

  public init() {}

  public init(ops: [PathOp]) {
    for op in ops { append(op) }
  }

  public var isEmpty: Bool { ops.isEmpty }

  public mutating func move(to x: Double, _ y: Double) {
    append(.move(Float(x), Float(y)))
  }

  public mutating func line(to x: Double, _ y: Double) {
    append(.line(Float(x), Float(y)))
  }

  /// `GeneralPath.quadTo`.
  public mutating func quad(control cx: Double, _ cy: Double, to x: Double, _ y: Double) {
    append(.quad(Float(cx), Float(cy), Float(x), Float(y)))
  }

  /// `GeneralPath.curveTo`.
  public mutating func cubic(
    control1 c1x: Double, _ c1y: Double,
    control2 c2x: Double, _ c2y: Double,
    to x: Double, _ y: Double
  ) {
    append(.cubic(Float(c1x), Float(c1y), Float(c2x), Float(c2y), Float(x), Float(y)))
  }

  public mutating func close() {
    append(.close)
  }

  /// Appends `other`, optionally connecting with a line (`GeneralPath.append(shape, connect)`).
  public mutating func append(_ other: ScenePath, connect: Bool) {
    var first = true
    for op in other.ops {
      if first, connect, case .move(let x, let y) = op {
        append(.line(x, y))
        first = false
        continue
      }
      first = false
      append(op)
    }
  }

  private mutating func append(_ op: PathOp) {
    ops.append(op)
    switch op {
    case .move(let x, let y), .line(let x, let y):
      grow(x, y)
    case .quad(let cx, let cy, let x, let y):
      grow(cx, cy); grow(x, y)
    case .cubic(let a, let b, let c, let d, let x, let y):
      grow(a, b); grow(c, d); grow(x, y)
    case .close:
      break
    }
  }

  private mutating func grow(_ x: Float, _ y: Float) {
    // Control-point hull: conservative for culling, which is all these bounds are for.
    controlBounds.formUnion(
      SceneBounds(
        minX: clampToInt32(Double(x).rounded(.down)),
        minY: clampToInt32(Double(y).rounded(.down)),
        maxX: clampToInt32(Double(x).rounded(.up)),
        maxY: clampToInt32(Double(y).rounded(.up))))
  }
}

// MARK: - SceneImageRef

/// An opaque handle to a bitmap. The scene never holds a `CGImage`, so it stays `Sendable`
/// and backend-agnostic; the backend resolves the handle through a `SceneImageProvider`.
public struct SceneImageRef: Hashable, Sendable {
  public var id: UInt64
  public var pixelWidth: Int32
  public var pixelHeight: Int32

  public init(id: UInt64, pixelWidth: Int32, pixelHeight: Int32) {
    self.id = id
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
  }
}
