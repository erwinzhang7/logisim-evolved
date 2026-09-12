// Power.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.wiring.Power),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Not one of the four tools the M2 migration gate currently names, but the same "byte-visible
// defaults" rule applies (`decisions.md`): get `FACING`/`WIDTH`'s defaults wrong here and any
// corpus file placing a bare `Power` component mismatches the writer's default-suppression too.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.wiring.Power`.
public final class Power: InstanceFactoryBase {

  /// `Power._ID`. Do not change, `.circ` files reference it.
  public static let id = "Power"

  /// Java's `public static final InstanceFactory FACTORY`-equivalent naming used across this
  /// port (`Constant.factory`, `Clock.factory`, …), even though Java itself does not declare a
  /// `Power.FACTORY` constant; `WiringLibrary` builds `new AddTool(new Power())` inline. Kept
  /// for consistency with the rest of `std/wiring` and because `WiringLibrary`'s Swift port
  /// (a sibling file this task does not own) will want exactly one shared instance to register.
  public static let factory = Power()

  public init() {
    super.init(Power.id)
    setAttributes([
      StdAttr.facing.binding(.north),
      StdAttr.width.binding(.one),
    ])
    setFacingAttribute(StdAttr.facing)
    setPorts([Port(0, 0, .output, StdAttr.width)])
  }

  // NOT PORTED: `instanceAttributeChanged`; its only job (`FACING` -> `recomputeBounds()`) is
  // automatic; see `InstanceFactory.swift`'s file header and `PATTERNS.md` section 0.

  /// `getOffsetBounds(AttributeSet)`.
  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let facing = attributes[StdAttr.facing, default: .north]
    return Bounds.create(0, -8, 15, 16).rotate(from: .east, to: facing, xc: 0, yc: 0)
  }

  /// `Power.propagate(InstanceState)`. `Value.repeat` throws (D13; `BitWidth.create`/
  /// `Value.repeat` are among the seven `Value` sites converted from Java's catchable
  /// `RuntimeException`), so this does too.
  public override func propagate(_ state: any InstanceState) throws {
    let width = state.attributeValue(StdAttr.width, default: .one)
    state.setPort(0, try Value.repeat(.trueValue, width), 1)
  }

  // NOT PORTED: `AbstractConstantHdlGeneratorFactory`/`PowerHdlGeneratorFactory`; HDL backlog
  // (D11); the inner class computed the same all-ones constant `propagate` writes.

  // MARK: Painting (Power.java:70-118)

  /// `drawInstance(InstancePainter, boolean isGhost)`.
  ///
  /// `Ground`'s mirror image, and the differences are all here rather than assumed: the body is
  /// a 3-point triangle rather than three bars, its colour comes from `TRUE` repeated to the
  /// component's width, and the triangle is **stroked**, not filled, `g.drawPolygon`.
  private func drawInstance(_ painter: InstancePainter, isGhost: Bool) {
    let g = painter.g
    let loc = painter.location
    g.pushTranslate(loc.x, loc.y)

    let from = painter.attributeValue(StdAttr.facing, default: .north)
    g.pushRotate(WiringPaint.rotationRadians(from: from))

    g.strokeWidth = WiringPaint.wireWidth
    if !isGhost && painter.showState {
      g.color = painter.color(of: painter.portValue(0))
    }
    g.drawLine(0, 0, 5, 0)

    g.strokeWidth = 1
    if !isGhost && painter.shouldDrawColor {
      let width = painter.attributeValue(StdAttr.width, default: .one)
      if let v = try? Value.repeat(.trueValue, width) { g.color = painter.color(of: v) }
    }
    g.drawPolygon([6, 14, 6], [-8, 0, 8])

    g.popTransform()
    g.popTransform()
  }

  public func paintGhost(_ painter: InstancePainter) {
    drawInstance(painter, isGhost: true)
  }

  public func paintInstance(_ painter: InstancePainter) {
    drawInstance(painter, isGhost: false)
    painter.drawPorts()
  }
}

extension Power: InstancePaintable {}
