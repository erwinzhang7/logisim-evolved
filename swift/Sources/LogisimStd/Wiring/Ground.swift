// Ground.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.wiring.Ground),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// `Ground` is `Power`'s mirror image: same attribute shape, `Value.FALSE` instead of `TRUE`,
// `SOUTH` instead of `NORTH` as the default facing, and a slightly different offset-bounds size
// (14 wide, not 15). Every difference below is transcribed, not assumed from `Power`.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.wiring.Ground`.
public final class Ground: InstanceFactoryBase {

  /// `Ground._ID`. Do not change, `.circ` files reference it.
  public static let id = "Ground"

  /// See `Power.factory`'s comment; Java has no `Ground.FACTORY` constant either;
  /// `WiringLibrary` builds `new AddTool(new Ground())` inline.
  public static let factory = Ground()

  public init() {
    super.init(Ground.id)
    setAttributes([
      StdAttr.facing.binding(.south),
      StdAttr.width.binding(.one),
    ])
    setFacingAttribute(StdAttr.facing)
    setPorts([Port(0, 0, .output, StdAttr.width)])
  }

  // NOT PORTED: `instanceAttributeChanged`; its only job (`FACING` -> `recomputeBounds()`) is
  // automatic; see `InstanceFactory.swift`'s file header and `PATTERNS.md` section 0.

  /// `getOffsetBounds(AttributeSet)`. Note the width is **14**, not `Power`'s 15: transcribed
  /// exactly, not "fixed" to match.
  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let facing = attributes[StdAttr.facing, default: .south]
    return Bounds.create(0, -8, 14, 16).rotate(from: .east, to: facing, xc: 0, yc: 0)
  }

  /// `Ground.propagate(InstanceState)`. `Value.repeat` throws (D13).
  public override func propagate(_ state: any InstanceState) throws {
    let width = state.attributeValue(StdAttr.width, default: .one)
    state.setPort(0, try Value.repeat(.falseValue, width), 1)
  }

  // NOT PORTED: `AbstractConstantHdlGeneratorFactory`: HDL backlog (D11). Unlike `Power`,
  // `Ground` passes the *shared* `AbstractConstantHdlGeneratorFactory` base directly (it returns
  // `0` for any width, the correct all-zero constant), rather than a per-component subclass.

  // MARK: Painting (Ground.java:58-108)

  /// `drawInstance(InstancePainter, boolean isGhost)`.
  ///
  /// Two colours, from two different sources, and the split matters: the 5-long lead is drawn
  /// in the *port's live value* colour (so a ground shorted against a driven wire goes red),
  /// while the three bars are drawn in the colour `FALSE` repeated to the component's width
  /// would have: a fixed property of the component, not of the circuit.
  private func drawInstance(_ painter: InstancePainter, isGhost: Bool) {
    let g = painter.g
    let loc = painter.location
    g.pushTranslate(loc.x, loc.y)

    let from = painter.attributeValue(StdAttr.facing, default: .south)
    let degrees = Direction.east.toDegrees() - from.toDegrees()
    let radians = Double((degrees + 360) % 360) * Double.pi / 180.0
    g.pushRotate(radians)

    g.strokeWidth = WiringPaint.wireWidth
    if !isGhost && painter.showState {
      g.color = painter.color(of: painter.portValue(0))
    }
    g.drawLine(0, 0, 5, 0)

    g.strokeWidth = 1
    if !isGhost && painter.shouldDrawColor {
      let width = painter.attributeValue(StdAttr.width, default: .one)
      if let v = try? Value.repeat(.falseValue, width) { g.color = painter.color(of: v) }
    }
    g.drawLine(6, -8, 6, 8)
    g.drawLine(9, -5, 9, 5)
    g.drawLine(12, -2, 12, 2)

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

extension Ground: InstancePaintable {}
