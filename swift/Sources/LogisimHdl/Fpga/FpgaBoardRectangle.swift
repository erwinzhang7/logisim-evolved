// FpgaBoardRectangle.swift: part of logisim-evolved.
//
// Derived from logisim-evolution `com/cburch/logisim/fpga/data/BoardRectangle.java` (205 lines),
// reference tree `upstream-java-4.1.0` (D16). GPL-3.0-only. See LICENSE.md.

import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.fpga.data.BoardRectangle`; one clickable region of the board photo.
///
/// ── Why the name differs from upstream's ────────────────────────────────────────────────────
///
/// `LogisimFile` **already exports a type called `BoardRectangle`**
/// (`XmlReaderSupport.swift`): an immutable four-`Int32` value struct, split out earlier so that
/// `XmlReader.loadMap` could parse a `.circ`'s `<mc>` mapping elements without the FPGA
/// subsystem existing. This module imports `LogisimFile`, so reusing the name here would make
/// every unqualified mention ambiguous.
///
/// The two are not interchangeable. Upstream's class is a **mutable reference type** carrying
/// four more fields (`label`, `nrBits`, `value`, `isActiveHigh`) and is shared by reference:
/// `FpgaIoInformationContainer.set(…)` calls `rect.setLabel(label)` and expects the board's copy
/// to change. A value struct cannot express that.
///
/// So this is the full class, and `reduced` / `init(reduced:)` convert. Unifying the two is an
/// integrator decision, because the fix is to widen `LogisimFile`'s struct; a module this task
/// does not own.
///
/// ── Equality ────────────────────────────────────────────────────────────────────────────────
///
/// Upstream's `equals` compares **only** the four coordinates and ignores label, bits, value and
/// activity, and that is load-bearing, not sloppy: `BoardInformation.getComponent(rect)` looks
/// a component up by geometry alone, and a `.circ` map stores geometry only. `==` and `hash(into:)`
/// therefore follow it exactly. Note upstream declares no `hashCode()` alongside its `equals`,
/// so a Java `HashSet<BoardRectangle>` misbehaves; nothing puts one in a hash container, and this
/// port is consistent rather than reproducing the latent bug.
public final class FpgaBoardRectangle: Hashable, CustomStringConvertible {

  public private(set) var xPosition: Int
  public private(set) var yPosition: Int
  public private(set) var width: Int
  public private(set) var height: Int

  /// `isActiveHigh`, default `true`.
  public var isActiveOnHigh: Bool = true
  /// `nrBits`, default 0.
  public var numberOfBits: Int = 0
  /// `value`, a Java `Long` that is genuinely nullable.
  public var value: Int64?
  /// `label`, likewise nullable.
  public var label: String?

  /// `BoardRectangle(int x, int y, int w, int h)`.
  public init(x: Int, y: Int, width: Int, height: Int) {
    // `set` normalises a negative extent by moving the origin, so the four stored fields are
    // assigned through it rather than directly.
    self.xPosition = 0
    self.yPosition = 0
    self.width = 0
    self.height = 0
    set(x: x, y: y, width: width, height: height)
  }

  /// Bridges from `BoardRectangle` (from `LogisimFile`), the reduced form the `.circ` reader produces.
  public convenience init(reduced: BoardRectangle) {
    self.init(
      x: Int(reduced.x), y: Int(reduced.y),
      width: Int(reduced.width), height: Int(reduced.height))
  }

  /// The reduced form, for handing a rectangle back to `.circ` map code.
  ///
  /// The four fields are `Int32` there and `Int` here; every value that reaches this type comes
  /// from `Integer.parseUnsignedInt` on a board file or from a `.circ`, both of which are 32-bit
  /// in Java, so `wrap32` is the faithful narrowing rather than a trap (D13).
  public var reduced: BoardRectangle {
    BoardRectangle(
      x: Int32(truncatingIfNeeded: wrap32(xPosition)),
      y: Int32(truncatingIfNeeded: wrap32(yPosition)),
      width: Int32(truncatingIfNeeded: wrap32(width)),
      height: Int32(truncatingIfNeeded: wrap32(height)))
  }

  /// `private void set(int x, int y, int w, int h)`; a negative width or height is normalised
  /// by shifting the origin, so `(10, 10, -4, -4)` becomes `(6, 6, 4, 4)`.
  private func set(x: Int, y: Int, width w: Int, height h: Int) {
    if w < 0 {
      xPosition = wrap32(x &+ w)
      width = -w
    } else {
      xPosition = x
      width = w
    }
    if h < 0 {
      yPosition = wrap32(y &+ h)
      height = -h
    } else {
      yPosition = y
      height = h
    }
  }

  /// `updateRectangle(BoardRectangle)`: copies geometry only, deliberately leaving label,
  /// bits, value and activity alone.
  public func updateRectangle(_ other: FpgaBoardRectangle) {
    xPosition = other.xPosition
    yPosition = other.yPosition
    width = other.width
    height = other.height
  }

  /// `isPointInside(int, int)`. Note the bounds are **inclusive on all four sides**, so a
  /// zero-size rectangle still contains its own corner, which is what makes `overlap` treat
  /// merely touching rectangles as overlapping.
  public func isPointInside(x: Int, y: Int) -> Bool {
    x >= xPosition && x <= (xPosition &+ width)
      && y >= yPosition && y <= (yPosition &+ height)
  }

  /// `overlap(BoardRectangle)`, transcribed branch for branch.
  ///
  /// The three-stage shape (corners of the other inside me, corners of me inside the other, then
  /// two blocks of cross-overlap tests) is upstream's and is kept even though the last two
  /// blocks are largely redundant: the board editor uses this to reject a newly drawn region
  /// that touches an existing one, and any simplification risks changing which drawings are
  /// accepted.
  public func overlaps(_ rect: FpgaBoardRectangle) -> Bool {
    let xl = rect.xPosition
    let xr = xl &+ rect.width
    let yt = rect.yPosition
    let yb = yt &+ rect.height

    var result = isPointInside(x: xl, y: yt)
    result = result || isPointInside(x: xl, y: yb)
    result = result || isPointInside(x: xr, y: yt)
    result = result || isPointInside(x: xr, y: yb)

    result = result || rect.isPointInside(x: xPosition, y: yPosition)
    result = result || rect.isPointInside(x: xPosition &+ width, y: yPosition)
    result = result || rect.isPointInside(x: xPosition, y: yPosition &+ height)
    result = result || rect.isPointInside(x: xPosition &+ width, y: yPosition &+ height)

    if !result {
      result =
        (xl >= xPosition) && (xl <= (xPosition &+ width))
        && (yt <= yPosition) && (yb >= (yPosition &+ height))
      result =
        result
        || ((xr >= xPosition) && (xr <= (xPosition &+ width))
          && (yt <= yPosition) && (yb >= (yPosition &+ height)))
      result =
        result
        || ((xl <= xPosition) && (xr >= (xPosition &+ width))
          && (yt >= yPosition) && (yt <= (yPosition &+ height)))
      result =
        result
        || ((xl <= xPosition) && (xr >= (xPosition &+ width))
          && (yb >= yPosition) && (yb <= (yPosition &+ height)))
    }
    if !result {
      result =
        (xPosition >= xl) && (xPosition <= xr)
        && (yPosition <= yt) && ((yPosition &+ height) >= yb)
      result =
        result
        || (((xPosition &+ width) >= xl) && ((xPosition &+ width) <= xr)
          && (yPosition <= yt) && ((yPosition &+ height) >= yb))
      result =
        result
        || ((xPosition <= xl) && ((xPosition &+ width) >= xr)
          && (yPosition >= yt) && (yPosition <= yb))
      result =
        result
        || ((xPosition <= xl) && ((xPosition &+ width) >= xr)
          && ((yPosition &+ height) >= yt) && ((yPosition &+ height) <= yb))
    }
    return result
  }

  public static func == (lhs: FpgaBoardRectangle, rhs: FpgaBoardRectangle) -> Bool {
    lhs.height == rhs.height && lhs.width == rhs.width
      && lhs.xPosition == rhs.xPosition && lhs.yPosition == rhs.yPosition
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(xPosition)
    hasher.combine(yPosition)
    hasher.combine(width)
    hasher.combine(height)
  }

  public var description: String { "\(xPosition),\(yPosition),\(width),\(height)" }
}
