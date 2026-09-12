// Switch.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.io.extra.Switch),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// A single on/off switch: input passed through to the output while "active" (closed), the
// output floats (`Value.createUnknown`) while "open". The `active` boolean lives in an
// `InstanceDataSingleton` that only `Poker` ever mutates.
//
// ── What did not come across ─────────────────────────────────────────────────────────────────
//
//   * `Logger`; the log-window value source (`getLogValue` just reads port 1); UI/M6.
//   (`paintInstance` / `paintGhost` ARE ported; see the Paint section at the end of this file.)
//   * `setKeyConfigurator`, UI.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.io.extra.Switch`.
public final class Switch: InstanceFactoryBase {

  /// `Switch._ID`.
  public static let id = "Switch"

  /// `Switch.Poker`. The whole component is a toggle: one release flips `active`, and upstream
  /// never looks at the event's coordinates; clicking anywhere on the body toggles.
  ///
  /// Upstream writes the flip as `setActive(state, data == null || !((Boolean) data.getValue()))`
  /// and then re-reads `getData()` inside `setActive`; that second read cannot see a different
  /// object (nothing between them mutates the state), so the two collapse into one lookup here.
  public final class Poker: InstancePoker {
    public init() {}

    public func mouseReleased(_ state: any InstanceState, _ event: PokeMouseEvent) {
      let data = state.data as? InstanceDataSingleton
      // `data == null || !value`; a missing state reads as "open", so the first poke closes it.
      let active = !((data?.value as? Bool) ?? false)
      if let data {
        data.value = active
      } else {
        state.setData(InstanceDataSingleton(active))
      }
      state.fireInvalidated()
    }
  }

  public init() {
    super.init(Switch.id)
    setAttributes([
      StdAttr.facing.binding(.east),
      StdAttr.width.binding(.one),
      IoLibrary.attrColor.binding(ColorSpec(red: 255, green: 255, blue: 255)),
      StdAttr.label.binding(""),
      StdAttr.labelLocation.binding(.north),
      StdAttr.labelFont.binding(StdAttr.defaultLabelFont),
    ])
    setFacingAttribute(StdAttr.facing)
  }

  public override func makePoker() -> (any InstancePoker)? { Poker() }

  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    let width = attributes.getValue(StdAttr.width) ?? .one
    let facing = attributes.getValue(StdAttr.facing) ?? .east
    let inputPort: Port
    switch facing {
    case .east: inputPort = Port(-20, 0, .input, width)
    case .west: inputPort = Port(20, 0, .input, width)
    case .north: inputPort = Port(0, 20, .input, width)
    case .south: inputPort = Port(0, -20, .input, width)
    }
    return [inputPort, Port(0, 0, .output, width)]
  }

  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let facing = attributes.getValue(StdAttr.facing) ?? .east
    return Bounds.create(-20, -15, 20, 30).rotate(from: .east, to: facing, xc: 0, yc: 0)
  }

  public override func propagate(_ state: any InstanceState) throws {
    let active = (state.data as? InstanceDataSingleton)?.value as? Bool ?? false
    let value: Value =
      active
      ? state.portValue(0)
      : Value.createUnknown(state.attributeValue(StdAttr.width, default: .one))
    state.setPort(1, value, 1)
  }

  // MARK: - Paint (D6)

  /// `Switch.DEPTH`.
  static let depth = 3

  /// `paint(InstancePainter, boolean)`: `Switch.java:133-295`.
  ///
  /// One routine for both the ghost and the real thing, exactly as upstream: `ghost` suppresses
  /// the fills, the ports, the label and the state read, leaving only the two outlines and the
  /// four detail strokes.
  ///
  /// The geometry is a rocker: a `color.darker()` body polygon with a lighter face polygon on
  /// top, tilted one way or the other by `DEPTH`, plus a centre line, a bevel edge, a short
  /// tick and a tiny "0" circle at the end that is currently down. There are four independent
  /// coordinate sets, {active, inactive} × {vertical facing, horizontal facing}, none of
  /// which is a reflection of any other in upstream's arithmetic, so all four are transcribed
  /// literally rather than derived from one. Note in particular that the `drawOval` calls swap
  /// which of `circle` / `circle - 1` is the width between the two orientations, making the "0"
  /// a one-pixel-flattened ellipse along a different axis in each.
  ///
  /// `painter.drawPort` is called **twice** with different indices, once before all the
  /// geometry and once after, so that whichever port sits under the body is painted first and
  /// covered, and the other sits on top. Which is which depends on the facing.
  private func paint(_ painter: any IoInstancePainter, ghost: Bool) {
    let bds = painter.bounds
    let x = bds.x
    let y = bds.y
    let w = bds.width
    let h = bds.height
    let circle = 4
    let depth = Switch.depth
    let facing = painter.attributeValue(StdAttr.facing, default: .east)
    let g = painter.scene

    if !ghost {
      // Under the drawing, deliberately.
      painter.drawPort((facing == .south || facing == .east) ? 0 : 1)
    }

    var active = false
    if painter.showState && !ghost {
      active = (painter.singletonData?.value as? Bool) ?? false
    }

    var color = painter.attributeValue(IoLibrary.attrColor, default: Switch.defaultColor)
    if !painter.shouldDrawColor {
      color = color.printGrey
    }

    let xp: [Int]
    let yp: [Int]
    let xr: [Int]
    let yr: [Int]

    if active {
      if facing == .north || facing == .west {
        let p = painter.location
        painter.withWidth(Switch.wireWidth) {
          g.color = .palette(.trueValue)
          if facing == .north {
            g.drawLine(p.x, p.y, p.x, p.y + 10)
          } else {
            g.drawLine(p.x, p.y, p.x + 10, p.y)
          }
        }
      }

      if facing == .north || facing == .south {
        xp = [x, x + w - depth, x + w, x + w, x]
        yp = [y + depth, y, y + depth, y + h, y + h]
        xr = [x, x + w - depth, x + w - depth, x]
        yr = [y + depth, y, y + h - depth, y + h]
      } else {
        xp = [x + depth, x + w, x + w, x + depth, x]
        yp = [y, y, y + h, y + h, y + depth]
        xr = [x, x + w - depth, x + w, x + depth]
        yr = [y + depth, y + depth, y + h, y + h]
      }
      if !ghost {
        g.color = .attribute(color.darker)
        g.fillPolygon(xp, yp)
        g.color = .attribute(color)
        g.fillPolygon(xr, yr)
        g.color = painter.componentColor
      }
      g.drawPolygon(xp, yp)
      g.drawPolygon(xr, yr)
      if facing == .north || facing == .south {
        g.drawLine(
          x + (w - depth) / 2, y + depth / 2 + 1,
          x + (w - depth) / 2, y + h - depth / 2 - 1)
        g.drawLine(x + w - depth, y + h - depth, x + w, y + h)
        g.drawLine(
          x + (w - depth) / 6, y + (h - depth) / 2 + (depth - depth / 6),
          x + (w - depth) / 3, y + (h - depth) / 2 + (depth - depth / 3))
        g.drawOval(
          x + (w - depth) * 3 / 4 - circle / 2,
          y + ((h - depth) / 2 - circle / 2) + 1 + depth / 4,
          circle, circle - 1)
      } else {
        g.drawLine(x + w - depth, y + depth, x + w, y)
        g.drawLine(
          x + depth / 2 + 1, y + (h - depth) / 2 + depth,
          x + w - depth / 2 - 1, y + (h - depth) / 2 + depth)
        g.drawLine(
          x + (w - depth) / 2 + (depth - depth / 6), y + (h - depth) * 5 / 6 + depth,
          x + (w - depth) / 2 + (depth - depth / 3), y + (h - depth) * 2 / 3 + depth)
        g.drawOval(
          x + depth / 4 + (w - depth - circle) / 2 + 1,
          y + ((h - depth) / 4 - circle / 2) + depth,
          circle - 1, circle)
      }
    } else {
      if facing == .north || facing == .south {
        xp = [x, x + depth, x + w, x + w, x]
        yp = [y + depth, y, y + depth, y + h, y + h]
        xr = [x + depth, x + w, x + w, x + depth]
        yr = [y, y + depth, y + h, y + h - depth]
      } else {
        xp = [x + depth, x + w, x + w, x + depth, x]
        yp = [y, y, y + h, y + h, y + h - depth]
        xr = [x + depth, x + w, x + w - depth, x]
        yr = [y, y, y + h - depth, y + h - depth]
      }
      if !ghost {
        g.color = .attribute(color.darker)
        g.fillPolygon(xp, yp)
        g.color = .attribute(color)
        g.fillPolygon(xr, yr)
        g.color = painter.componentColor
      }
      g.drawPolygon(xp, yp)
      g.drawPolygon(xr, yr)
      if facing == .north || facing == .south {
        g.drawLine(x + depth, y + h - depth, x, y + h)
        g.drawLine(
          x + (w - depth) / 2 + depth, y + depth / 2 + 1,
          x + (w - depth) / 2 + depth, y + h - depth / 2 - 1)
        // Note this pair uses `w / 6` and `w / 3`, not `(w - depth) / 6`; the only place in
        // the four blocks where the tick is measured off the full width.
        g.drawLine(
          x + depth + w / 6, y + (h - depth) / 2 + depth / 6,
          x + depth + w / 3, y + (h - depth) / 2 + depth / 3)
        g.drawOval(
          x + (w - depth) * 3 / 4 - circle / 2 + depth,
          y + ((h - depth) / 2 - circle / 2) + depth * 3 / 4 + 1,
          circle, circle - 1)
      } else {
        g.drawLine(
          x + depth / 2 + 1, y + (h - depth) / 2,
          x + w - depth / 2 - 1, y + (h - depth) / 2)
        g.drawLine(x + w - depth, y + h - depth, x + w, y + h)
        g.drawLine(
          x + (w - depth) / 2 + depth / 6, y + (h - depth) * 5 / 6,
          x + (w - depth) / 2 + depth / 3, y + (h - depth) * 2 / 3)
        g.drawOval(
          x + depth * 3 / 4 + (w - depth - circle) / 2 + 1,
          y + ((h - depth) / 4 - circle / 2),
          circle - 1, circle)
      }
    }

    if !ghost {
      painter.drawLabel()
      painter.drawPort((facing == .south || facing == .east) ? 1 : 0)
    }
  }

  /// `Wire.WIDTH`, for the true-value stub an active NORTH/WEST switch draws.
  static let wireWidth = 3

  /// The attribute-template default for `IoLibrary.ATTR_COLOR`: white.
  static let defaultColor = ColorSpec(red: 255, green: 255, blue: 255)
}

extension Switch: IoPaintable {
  /// `paintGhost(InstancePainter)`.
  public func paintGhost(_ painter: any IoInstancePainter) { paint(painter, ghost: true) }
  /// `paintInstance(InstancePainter)`.
  public func paintInstance(_ painter: any IoInstancePainter) { paint(painter, ghost: false) }
}

// MARK: - Label (board #78)

extension Switch: InstanceLabelProvider {

  /// `Instance.computeLabelTextField(Instance.AVOID_RIGHT | Instance.AVOID_LEFT)`:
  /// `Switch.java:110`, re-run at `:124`/`:129`. That pair is `Instance.AVOID_SIDES`, but the
  /// Java spells the two bits out here, so this does too.
  ///
  /// Two bits rather than one, so **both** an `EAST` and a `WEST` label get nudged up 2px onto
  /// `V_BOTTOM`, where the six plain-`AVOID_LEFT` io factories nudge exactly one edge. The pair
  /// is also invariant under the rotation for the east/west facings, `left|right` is `0b1010`,
  /// and a rotate-left by two maps it back onto itself, so unlike `AVOID_LEFT` the observable
  /// behaviour does not move when the facing does.
  public func labelPlacement(_ painter: InstancePainter) -> LabelPlacement? {
    LabelPlacement.computed(painter, avoid: [.right, .left])
  }
}
