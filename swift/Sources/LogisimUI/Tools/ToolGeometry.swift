// ToolGeometry.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.gui.main.Canvas: the static coordinate
// helpers only), https://github.com/logisim-evolution/logisim-evolution. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Why grid snapping lives here and not in the canvas host ─────────────────────────────────
//
// M6/M7 both state it: "reproduce integer grid snapping exactly or every file looks subtly
// off-grid". Snapping is not a display convenience: it decides the integer coordinates that
// end up in `<wire from="(x,y)" to="(x,y)"/>`, so it is part of the edit, not part of the
// chrome. `RenderSeam.CanvasPointerEvent` already carries a `snappedWorld`, but that is the
// *shell's* snapping, computed in `Double`, and the shell is free to change it. The tools
// therefore snap for themselves, from the raw world point, using the exact Java integer
// arithmetic below.
//
// Upstream applies these in three places that all matter to the model:
//   * `Canvas.snapToGrid(MouseEvent)`: mutates the event in place before the tool sees it
//     (`Canvas.java:199-205`). Every tool that places geometry calls it explicitly.
//   * `SelectTool.computeDxDy`: snaps the *delta*, not the point (`SelectTool.java:156-159`).
//   * `EditTool.updateLocation`: snaps, then measures the residual to decide whether the
//     pointer is close enough to a grid intersection to count as a wiring point
//     (`EditTool.java:429-441`).

import CoreGraphics
import Foundation
import LogisimKernel

/// The two static coordinate helpers `com.cburch.logisim.gui.main.Canvas` exposes, plus the
/// pixel→circuit conversion its `zoomEvent` performs.
public enum CanvasGrid {

  /// The grid pitch, in circuit units. Upstream hard-codes `10` at every one of these sites; it
  /// is named here so the three uses cannot drift apart, not because it is configurable.
  public static let spacing = 10

  /// `Canvas.snapXToGrid(int)` (`Canvas.java:210-214`).
  ///
  /// The negative branch is written out rather than relying on division, because Java's `/`
  /// truncates toward zero: `(-5 + 5) / 10 * 10` would be `0`, but upstream wants `-10`. Swift's
  /// `/` truncates the same way, so negating first reproduces it exactly. Both operands are
  /// non-negative inside each branch, which is what makes the two languages agree.
  ///
  /// `&+`/`&*` and `wrap32` are D15's rule: Java's `int` wraps at 32 bits and Swift's `Int`
  /// traps at 64. A pointer coordinate never gets near the boundary, but this function is also
  /// applied to *deltas* by `SelectTool`, and a delta is a difference of two coordinates.
  public static func snapXToGrid(_ x: Int) -> Int {
    x < 0
      ? wrap32(-(((wrap32(-x &+ 5)) / spacing) &* spacing))
      : wrap32(((wrap32(x &+ 5)) / spacing) &* spacing)
  }

  /// `Canvas.snapYToGrid(int)` (`Canvas.java:216-220`). Identical to the x form; upstream keeps
  /// them separate and so does this, because a future non-square grid would change one only.
  public static func snapYToGrid(_ y: Int) -> Int {
    snapXToGrid(y)
  }

  /// `Canvas.snapToGrid(MouseEvent)` (`Canvas.java:199-205`), as a value transform rather than
  /// an in-place mutation of the event.
  public static func snapToGrid(_ point: ToolPoint) -> ToolPoint {
    ToolPoint(x: snapXToGrid(point.x), y: snapYToGrid(point.y))
  }

  /// The integer circuit coordinate upstream's `Canvas.zoomEvent` produces:
  /// `(int) Math.round(pixel / zoom)` (`Canvas.java:677-678`).
  ///
  /// The shell hands tools a `CGPoint` already in world units, so the division is done; what is
  /// left is Java's `Math.round`, which is `floor(x + 0.5)`: **not** Swift's
  /// `.toNearestOrAwayFromZero`. They disagree on every negative half-integer: Java rounds
  /// `-2.5` to `-2`, Swift's default rounds it to `-3`. On a 10-unit grid that is a whole grid
  /// step of divergence for a circuit placed at negative coordinates.
  public static func circuitCoordinate(_ worldValue: Double) -> Int {
    guard worldValue.isFinite else { return 0 }
    let rounded = (worldValue + 0.5).rounded(.down)
    // ── A DELIBERATE, MEASURED DIVERGENCE, CORRECTLY DESCRIBED ────────────────────────────
    //
    // The clamp below is the PORT's rule, not upstream's, and the two differ out of range.
    // An earlier version of this comment said Java "saturates at Integer.MIN/MAX_VALUE".
    // That is true of `(int)` applied to a *double*, but upstream does not do that. It does
    // `(int) Math.round(px / zoom)`, and `Math.round(double)` returns a **long**; the
    // narrowing here is long -> int, which **truncates to the low 32 bits** rather than
    // saturating. Measured on JDK 21 against 4.1.0's `Canvas.zoomEvent`:
    //
    //     input           Math.round (long)       (int) of it     this port
    //     NaN             0                       0               0             agree
    //     -Infinity      -9223372036854775808     0               0             agree
    //     +Infinity       9223372036854775807    -1               2147483647    DIFFER
    //     -2147483648.6  -2147483649              2147483647     -2147483648    DIFFER
    //
    // Left as a clamp on purpose. Reaching a differing row needs a world coordinate past
    // ±2^31 or a non-finite viewport scale, and `RenderViewport` sanitises the scale before
    // any of this runs, so the divergence is unreachable, while a trap on this path would
    // take the editor down mid-gesture. `GridSnapParityTests` deliberately does NOT assert
    // these rows: pinning the port's current answer would build a change detector that fires
    // on the correct fix rather than a test of upstream's behaviour.
    if rounded <= Double(Int32.min) { return Int(Int32.min) }
    if rounded >= Double(Int32.max) { return Int(Int32.max) }
    return Int(rounded)
  }

  /// The whole conversion, world `CGPoint` → integer circuit point, as the tools want it.
  public static func circuitPoint(_ world: CGPoint) -> ToolPoint {
    ToolPoint(x: circuitCoordinate(world.x), y: circuitCoordinate(world.y))
  }
}

/// An integer point in circuit coordinates.
///
/// Deliberately *not* `Location`: upstream's tools work in raw `MouseEvent` ints and only build
/// a `Location` at the moment they commit geometry, and D14 makes `Location` carry a snap mode
/// that would otherwise be applied twice. Keeping the pre-commit coordinate in a plain pair
/// makes the one place that converts (and the snap flag it passes) explicit.
public struct ToolPoint: Hashable, Sendable, CustomStringConvertible {
  public var x: Int
  public var y: Int

  public init(x: Int, y: Int) {
    self.x = x
    self.y = y
  }

  /// `Location.create(x, y, hasToSnap)`. `hasToSnap` is spelled at every call site rather than
  /// defaulted, because D14 records that upstream's answer depends on it and the port's does
  /// too, only deterministically.
  public func location(snapping: Bool) -> Location {
    Location.create(x, y, hasToSnap: snapping)
  }

  public var description: String { "(\(x),\(y))" }
}

extension Location {
  /// The inverse of `ToolPoint.location(snapping:)`.
  public var toolPoint: ToolPoint { ToolPoint(x: x, y: y) }
}
