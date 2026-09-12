// Joystick.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.io.Joystick),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Poker seam: see the ASSUMED CHASSIS ADDITION #1 note in Button.swift. `IoLibrary.attrColor` /
// `.attrBackground` / `.defaultBackground`: see the ASSUMED note in the same file.
//
// ── Not ported ────────────────────────────────────────────────────────────────────────────────
//
//   (`paintGhost`, `paintInstance`, `drawBall` and `Poker.paint` ARE ported; see the Paint
//   section at the end of this file. `Poker.paint` sits on an extension rather than on the
//   `InstancePoker` protocol, which has no draw hook in the stand-in this port assumes.)
//   * Tool tips (`joystickCoordinateX`/`Y`): `Port` carries none.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.io.Joystick`.
public final class Joystick: InstanceFactoryBase {
  /// `Joystick._ID`.
  public static let id = "Joystick"

  /// `Joystick.ATTR_WIDTH`.
  public static let width: Attribute<BitWidth> = Attributes.forBitWidth("bits", min: 2, max: 5)

  /// `Joystick.State`: the stick's raw pixel displacement from centre, clamped to ±14 by
  /// `updateState` before it is ever stored.
  private final class State: InstanceData {
    var xPos: Int
    var yPos: Int

    init(x: Int, y: Int) {
      xPos = x
      yPos = y
    }

    func cloneData() -> any InstanceData { State(x: xPos, y: yPos) }
  }

  /// `Joystick.Poker`. `paint` (the crosshair/ball redraw while dragging) is M6 and not ported;
  /// the state update it shares with `mouseDragged`/`mousePressed`/`mouseReleased` is.
  public final class Poker: InstancePoker {
    public init() {}

    public func mouseDragged(_ state: any InstanceState, _ event: PokeMouseEvent) {
      let loc = state.component.location
      let cx = loc.x - 15
      let cy = loc.y + 5
      updateState(state, event.x - cx, event.y - cy)
    }

    public func mousePressed(_ state: any InstanceState, _ event: PokeMouseEvent) {
      mouseDragged(state, event)
    }

    public func mouseReleased(_ state: any InstanceState, _ event: PokeMouseEvent) {
      updateState(state, 0, 0)
    }

    private func updateState(_ state: any InstanceState, _ dx0: Int, _ dy0: Int) {
      let dx = min(max(dx0, -14), 14)
      let dy = min(max(dy0, -14), 14)
      if let existing = state.data as? State {
        existing.xPos = dx
        existing.yPos = dy
      } else {
        state.setData(State(x: dx, y: dy))
      }
      state.fireInvalidated()
    }
  }

  public init() {
    super.init(Joystick.id)
    setAttributes([
      StdAttr.facing.binding(.east),
      Joystick.width.binding(BitWidth.known(4)),
      IoLibrary.attrColor.binding(ColorSpec(red: 255, green: 0, blue: 0)),
      IoLibrary.attrBackground.binding(IoLibrary.defaultBackground),
    ])
    setFacingAttribute(StdAttr.facing)
    setOffsetBounds(Bounds.create(-30, -10, 30, 30))
  }

  public override func makePoker() -> (any InstancePoker)? { Poker() }

  /// `updatePorts(Instance)`, folded into `ports(_:)`; see `PATTERNS.md`. Port 0 is the X
  /// coordinate, port 1 is Y, ten units further along the facing direction.
  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    let facing = attributes[StdAttr.facing, default: .east]
    let x0: Int, y0: Int, x1: Int, y1: Int
    switch facing {
    case .north: x0 = -20; y0 = -10; x1 = -10; y1 = -10
    case .south: x0 = -20; y0 = 20; x1 = -10; y1 = 20
    case .west: x0 = -30; y0 = 0; x1 = -30; y1 = 10
    case .east: x0 = 0; y0 = 0; x1 = 0; y1 = 10
    }
    return [
      Port(x0, y0, .output, Joystick.width),
      Port(x1, y1, .output, Joystick.width),
    ]
  }

  /// `propagate(InstanceState)`. Maps the clamped ±14 pixel displacement onto the attribute's
  /// bit width, biasing the upper half up by one step past 4 bits, transcribed exactly.
  public override func propagate(_ state: any InstanceState) throws {
    let bits = state.attributeValue(Joystick.width, default: BitWidth.known(4))
    let existing = state.data as? State
    var dx = existing?.xPos ?? 0
    var dy = existing?.yPos ?? 0

    let steps = (1 << bits.width) - 1
    dx = (dx + 14) * steps / 29 + 1
    dy = (dy + 14) * steps / 29 + 1
    if bits.width > 4 {
      if dx >= steps / 2 { dx += 1 }
      if dy >= steps / 2 { dy += 1 }
    }
    state.setPort(0, Value.createKnown(bits, Int64(dx)), 1)
    state.setPort(1, Value.createKnown(bits, Int64(dy)), 1)
  }

  // MARK: - Paint (D6)

  /// `Joystick.drawBall(Graphics, int, int, Color, boolean)`; `Joystick.java:125-135`.
  ///
  /// `inColor` is `shouldDrawColor()` from `paintInstance` but a hard `true` from the poker's
  /// live paint, so a joystick being dragged shows a coloured ball even in print view. That is
  /// upstream's, and it is why this takes the flag rather than reading the painter.
  ///
  /// Note the pen is left at width 1 on exit: Java's `switchToWidth(g, 1)` here is not
  /// bracketed, and the poker's paint below depends on the order (its 3-wide stick line is
  /// drawn *before* this call, not after).
  fileprivate static func drawBall(
    _ g: SceneBuilder, _ x: Int, _ y: Int, _ c: ColorSpec?, inColor: Bool,
    componentColor: SceneColor
  ) {
    if inColor {
      g.color = .attribute(c ?? ColorSpec(red: 255, green: 0, blue: 0))
    } else {
      // The `c == null` fallback is 128 directly, not `printGrey` of red: a null colour greys
      // to mid-grey rather than to red's luminance of 85.
      let hue: UInt8 = c.map { UInt8((Int($0.red) + Int($0.green) + Int($0.blue)) / 3) } ?? 128
      g.color = .rgba(RGBA(r: hue, g: hue, b: hue))
    }
    g.strokeWidth = 1
    g.fillOval(x - 4, y - 4, 8, 8)
    g.color = componentColor
    g.drawOval(x - 4, y - 4, 8, 8)
  }

  /// `paintGhost(InstancePainter)`: `Joystick.java:197-201`.
  ///
  /// Drawn in **offset** coordinates, unlike `paintInstance`: the ghost is painted under a
  /// translation the canvas has already applied, so the literal `-30, -10` is correct here and
  /// would be wrong in `paintInstance`.
  public func paintGhost(_ painter: any IoInstancePainter) {
    painter.withWidth(2) {
      painter.scene.drawRoundRect(-30, -10, 30, 30, 8, 8)
    }
  }

  /// `paintInstance(InstancePainter)`; `Joystick.java:203-221`.
  ///
  /// The ball is drawn **at rest**, at `(x - 15, y + 5)`, no matter where the stick actually is.
  /// The displaced stick and ball come from the poker's own `paint`, which the canvas calls only
  /// for the component currently being poked (see `Poker.paint` below). Drawing the live
  /// position here instead would double-draw the ball during a drag.
  public func paintInstance(_ painter: any IoInstancePainter) {
    let loc = painter.location
    let x = loc.x
    let y = loc.y

    let g = painter.scene
    g.color = .attribute(
      painter.attributeValue(IoLibrary.attrBackground, default: IoLibrary.defaultBackground))
    g.fillRoundRect(x - 30, y - 10, 30, 30, 8, 8)
    g.color = painter.componentColor
    g.drawRoundRect(x - 30, y - 10, 30, 30, 8, 8)
    g.drawRoundRect(x - 28, y - 8, 26, 26, 4, 4)
    Joystick.drawBall(
      g, x - 15, y + 5,
      painter.attributeValue(IoLibrary.attrColor),
      inColor: painter.shouldDrawColor,
      componentColor: painter.componentColor)
    painter.drawPorts()
  }
}

extension Joystick: IoPaintable {}

extension Joystick.Poker {

  /// `Joystick.Poker.paint(InstancePainter)`: `Joystick.java:64-89`.
  ///
  /// Not a member of the `InstancePoker` seam this port assumes (see `Button.swift`'s header):
  /// upstream's `InstancePoker` has a `paint` hook that the canvas calls for the component under
  /// the pointer, and that hook is not in the six-method stand-in. Left as a plain method so the
  /// geometry is ported and the seam only has to grow one requirement.
  ///
  /// The `x0`/`y0` nudges are asymmetric in Java and are transcribed rather than symmetrised:
  /// `dx` tests `> 5` / `< -5` but `dy` tests `> 5` / `< 0`, so the stick's base shifts up on
  /// *any* downward pull but only on a hard leftward one.
  public func paint(_ painter: any IoInstancePainter) {
    let state: Joystick.State
    if let existing = painter.data as? Joystick.State {
      state = existing
    } else {
      state = Joystick.State(x: 0, y: 0)
      painter.setData(state)
    }
    let loc = painter.location
    let x = loc.x
    let y = loc.y
    let g = painter.scene
    g.color = painter.componentColor
    g.fillOval(x - 19, y + 1, 8, 8)
    g.strokeWidth = 3
    let dx = state.xPos
    let dy = state.yPos
    let x0 = x - 15 + (dx > 5 ? 1 : dx < -5 ? -1 : 0)
    let y0 = y + 5 + (dy > 5 ? 1 : dy < 0 ? -1 : 0)
    let x1 = x - 15 + dx
    let y1 = y + 5 + dy
    g.drawLine(x0, y0, x1, y1)
    Joystick.drawBall(
      g, x1, y1,
      painter.attributeValue(IoLibrary.attrColor),
      inColor: true,
      componentColor: painter.componentColor)
  }
}
