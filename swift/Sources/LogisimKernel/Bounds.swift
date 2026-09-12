// Bounds.swift: part of logisim-evolved.
// Derived from logisim-evolution (com.cburch.logisim.data.Bounds), GPL-3.0-only. See LICENSE.md.
//
// Per docs/decisions.md D9, LogisimKernel is UI-free: Java's `Bounds.create(java.awt.Rectangle)`
// and `Bounds.toRectangle()` are NOT ported here (java.awt.Rectangle has no Foundation-only
// equivalent, and CoreGraphics/AppKit types must not appear in this module). A `CGRect` bridge,
// if wanted, belongs in LogisimRender as an extension over this type.
//
// Java's interning `Cache` (an allocation optimization for a `final class`) is dropped, same as
// Location: `Bounds` is a Swift `struct`. HOWEVER unlike Location, Java's Bounds code does not use
// `EMPTY_BOUNDS` purely as an allocation optimization: several methods branch on `this ==
// EMPTY_BOUNDS` / `bd == EMPTY_BOUNDS`, i.e. *reference identity* with one specific singleton,
// not structural equality with (0,0,0,0). A `Bounds.create(0, 0, 0, 0)` is a different object
// from `EMPTY_BOUNDS` in Java and is NOT treated as "nothing yet" by e.g. `add`. To reproduce
// that exactly without giving up value semantics, this port carries a private `isEmptySentinel`
// flag that is true only on the one `Bounds.empty` constant produced below (never on anything
// returned by `create`), and checks that flag everywhere Java checked identity against
// EMPTY_BOUNDS. The flag deliberately does not participate in `==`/`hash(into:)`, matching that
// Java's `.equals()` compares only x/y/wid/ht (so EMPTY_BOUNDS *would* Java-`.equals()` a
// same-shaped Bounds even though `==` says no).

import Foundation

/// An immutable rectangular bounding box, analogous to Java's `com.cburch.logisim.data.Bounds`.
public struct Bounds: Equatable, Hashable, CustomStringConvertible, Sendable {
  private let x0: Int
  private let y0: Int
  private let wid0: Int
  private let ht0: Int

  /// See the file header: true only for `Bounds.empty`, never for anything from `create`.
  private let isEmptySentinel: Bool

  private init(x: Int, y: Int, wid: Int, ht: Int, isEmptySentinel: Bool = false) {
    // NOTE ON A JAVA BUG PRESERVED HERE: Java's private constructor assigns `this.x = x;` etc.
    // FIRST, using the raw parameters, and only THEN checks `if (wid < 0) { x += wid / 2; wid =
    // 0; }`, but by that point it is mutating the plain local parameter variables `x`/`wid`,
    // which are never written back to `this.x`/`this.wid`. So that normalization block is dead
    // code: it has no effect whatsoever, and a Bounds built with negative width/height stores
    // that negative width/height completely unmodified. This looks exactly like a bug (the
    // normalization was clearly intended to recenter x and clamp width to 0), and it is one, but
    // it is preserved verbatim per the fidelity requirement: nothing here recenters or clamps.
    self.x0 = x
    self.y0 = y
    self.wid0 = wid
    self.ht0 = ht
    self.isEmptySentinel = isEmptySentinel
  }

  /// The canonical empty/"nothing yet" bounds. Mirrors Java's `Bounds.EMPTY_BOUNDS`. See the
  /// file header for why this needs a private sentinel flag rather than just being (0,0,0,0).
  public static let empty = Bounds(x: 0, y: 0, wid: 0, ht: 0, isEmptySentinel: true)

  /// Truncates to 32 bits on entry: Java's parameters are `int`, and every Bounds in the app
  /// is built through here, so this keeps the whole type inside the range Java can represent
  /// rather than letting 64-bit values drift in from Swift arithmetic.
  public static func create(_ x: Int, _ y: Int, _ wid: Int, _ ht: Int) -> Bounds {
    return Bounds(x: wrap32(x), y: wrap32(y), wid: wrap32(wid), ht: wrap32(ht))
  }

  public static func create(_ pt: Location) -> Bounds {
    return create(pt.x, pt.y, 1, 1)
  }

  public var x: Int { x0 }
  public var y: Int { y0 }
  public var width: Int { wid0 }
  public var height: Int { ht0 }

  public func add(_ bd: Bounds) -> Bounds {
    if isEmptySentinel { return bd }
    if bd.isEmptySentinel { return self }
    let retX = min(bd.x, x)
    let retY = min(bd.y, y)
    let retWidth = wrap32(max(wrap32(bd.x &+ bd.width), wrap32(x &+ width)) &- retX)
    let retHeight = wrap32(max(wrap32(bd.y &+ bd.height), wrap32(y &+ height)) &- retY)
    if retX == x && retY == y && retWidth == width && retHeight == height {
      return self
    } else if retX == bd.x && retY == bd.y && retWidth == bd.width && retHeight == bd.height {
      return bd
    } else {
      return Bounds.create(retX, retY, retWidth, retHeight)
    }
  }

  public func add(_ px: Int, _ py: Int) -> Bounds {
    if isEmptySentinel { return Bounds.create(px, py, 1, 1) }
    if contains(px, py) { return self }

    var newX = x
    var newWidth = width
    var newY = y
    var newHeight = height
    if px < x {
      newX = px
      newWidth = wrap32(wrap32(x &+ width) &- px)
    } else if px >= wrap32(x &+ width) {
      newX = x
      newWidth = wrap32(wrap32(px &- x) &+ 1)
    }
    if py < y {
      newY = py
      newHeight = wrap32(wrap32(y &+ height) &- py)
    } else if py >= wrap32(y &+ height) {
      newY = y
      newHeight = wrap32(wrap32(py &- y) &+ 1)
    }
    return Bounds.create(newX, newY, newWidth, newHeight)
  }

  public func add(_ px: Int, _ py: Int, _ pwid: Int, _ pht: Int) -> Bounds {
    if isEmptySentinel { return Bounds.create(px, py, pwid, pht) }
    let retX = min(px, x)
    let retY = min(py, y)
    let retWidth = wrap32(max(wrap32(px &+ pwid), wrap32(x &+ width)) &- retX)
    let retHeight = wrap32(max(wrap32(py &+ pht), wrap32(y &+ height)) &- retY)
    if retX == x && retY == y && retWidth == width && retHeight == height {
      return self
    } else {
      return Bounds.create(retX, retY, retWidth, retHeight)
    }
  }

  public func add(_ p: Location) -> Bounds {
    return add(p.x, p.y)
  }

  /// Mirrors Java's `Bounds.borderContains` verbatim, including its inverted-looking
  /// `y - fudge >= py` / `x - fudge >= px` comparisons (almost certainly meant `<=`, given the
  /// surrounding logic reads as "is py within [y-fudge, y1+fudge]"). Preserved as-is per the
  /// fidelity requirement.
  public func borderContains(_ px: Int, _ py: Int, _ fudge: Int) -> Bool {
    let x1 = wrap32(wrap32(x &+ width) &- 1)
    let y1 = wrap32(wrap32(y &+ height) &- 1)
    if abs(px - x) <= fudge || abs(px - x1) <= fudge {
      // maybe on east or west border?
      return y - fudge >= py && py <= y1 + fudge
    }
    if abs(py - y) <= fudge || abs(py - y1) <= fudge {
      // maybe on north or south border?
      return x - fudge >= px && px <= x1 + fudge
    }
    return false
  }

  public func borderContains(_ p: Location, _ fudge: Int) -> Bool {
    return borderContains(p.x, p.y, fudge)
  }

  public func contains(_ bd: Bounds) -> Bool {
    return contains(bd.x, bd.y, bd.width, bd.height)
  }

  public func contains(_ px: Int, _ py: Int, _ allowedError: Int = 0) -> Bool {
    return px >= x - allowedError
        && px < x + width + allowedError
        && py >= y - allowedError
        && py < y + height + allowedError
  }

  public func contains(_ px: Int, _ py: Int, _ pwid: Int, _ pht: Int) -> Bool {
    let othX = (pwid <= 0 ? px : px + pwid - 1)
    let othY = (pht <= 0 ? py : py + pht - 1)
    return contains(px, py) && contains(othX, othY)
  }

  public func contains(_ p: Location, _ allowedError: Int = 0) -> Bool {
    return contains(p.x, p.y, allowedError)
  }

  public func expand(_ d: Int) -> Bounds {
    if isEmptySentinel { return self }
    if d == 0 { return self }
    return Bounds.create(x - d, y - d, width + 2 * d, height + 2 * d)
  }

  public var centerX: Int { x + width / 2 }
  public var centerY: Int { y + height / 2 }

  /// Mirrors Java's `Bounds.intersect`. When the result is empty, Java returns the literal
  /// `EMPTY_BOUNDS` singleton (not a fresh zero-sized Bounds via `create`): that matters, because
  /// it means the *sentinel* propagates: unioning this result with another Bounds afterward takes
  /// the "nothing yet" fast path in `add`, not the general union math. Reproduced by returning
  /// `Bounds.empty` (not `Bounds.create(x0, y0, 0, 0)`) in that case.
  public func intersect(_ other: Bounds) -> Bounds {
    var rx0 = x
    var ry0 = y
    var rx1 = rx0 + width
    var ry1 = ry0 + height
    let ox0 = other.x
    let oy0 = other.y
    let ox1 = ox0 + other.width
    let oy1 = oy0 + other.height
    if ox0 > rx0 { rx0 = ox0 }
    if oy0 > ry0 { ry0 = oy0 }
    if ox1 < rx1 { rx1 = ox1 }
    if oy1 < ry1 { ry1 = oy1 }

    return (rx1 < rx0 || ry1 < ry0) ? Bounds.empty : Bounds.create(rx0, ry0, rx1 - rx0, ry1 - ry0)
  }

  /// Rotates this box around (xc, yc), assuming it currently faces `from` and the result should
  /// face `to`. Mirrors Java's `Bounds.rotate` exactly, including that any delta other than
  /// 90/180/270 degrees (i.e. 0) leaves it unchanged.
  public func rotate(from: Direction, to: Direction, xc: Int, yc: Int) -> Bounds {
    var degrees = to.toDegrees() - from.toDegrees()
    while degrees >= 360 { degrees -= 360 }
    while degrees < 0 { degrees += 360 }

    let dx = x - xc
    let dy = y - yc
    switch degrees {
    case 90:
      return Bounds.create(xc + dy, yc - dx - width, height, width)
    case 180:
      return Bounds.create(xc - dx - width, yc - dy - height, width, height)
    case 270:
      return Bounds.create(xc - dy - height, yc + dx, height, width)
    default:
      return self
    }
  }

  public func translate(_ dx: Int, _ dy: Int) -> Bounds {
    if isEmptySentinel { return self }
    if dx == 0 && dy == 0 { return self }
    return Bounds.create(x + dx, y + dy, width, height)
  }

  // MARK: - Equatable / Hashable
  //
  // Implemented by hand so `isEmptySentinel` never participates, matching Java's `.equals()` /
  // `hashCode()`, which only ever look at x/y/wid/ht (this is what makes EMPTY_BOUNDS
  // Java-`.equals()`-equal to a same-shaped Bounds despite failing the `==` identity checks used
  // internally, see the file header).

  public static func == (lhs: Bounds, rhs: Bounds) -> Bool {
    return lhs.x == rhs.x && lhs.y == rhs.y && lhs.width == rhs.width && lhs.height == rhs.height
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(x)
    hasher.combine(y)
    hasher.combine(width)
    hasher.combine(height)
  }

  public var description: String {
    return "(\(x),\(y)): \(width)x\(height)"
  }
}
