// RgbLed.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.io.RgbLed),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Not ported ──────────────────────────────────────────────────────────────────────────────
//
//   * `setIcon`; UI (D9). `paintInstance`/`paintGhost` ARE ported; see the Paint section below.
//   * `DynamicElementProvider`/`createDynamicElement` (`RgbLedShape`): appearance editor, M7.
//   * `RgbLed.Logger`: Log-window probe; see `Led.swift`'s header, same reasoning.
//   * `setKeyConfigurator`; UI (D9).
//   * `StdAttr.MAPINFO`; omitted; see `SevenSegment.swift`'s file header for why.
//
// Needs `StdAttr.labelLocation`: see `SevenSegment.swift`'s file header; same gap, same fix.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.io.RgbLed`.
public final class RgbLed: InstanceFactoryBase {

  /// `RgbLed._ID`.
  public static let id = "RGBLED"

  public static let red = 0
  public static let green = 1
  public static let blue = 2

  /// `RgbLed.getLabels()`. FPGA board-mapping labels; kept as pure data (see
  /// `SevenSegment.swift`'s file header for why `MAPINFO` itself is not ported).
  public static func labels() -> [String] {
    var result = [String](repeating: "", count: 3)
    result[red] = "RED"
    result[green] = "GREEN"
    result[blue] = "BLUE"
    return result
  }

  /// `RgbLed()`.
  public init() {
    super.init(RgbLed.id, displayName: "RGB LED", requiresLabel: true)
    setAttributes([
      StdAttr.facing.binding(.west),
      IoLibrary.active.binding(true),
      StdAttr.label.binding(""),
      StdAttr.labelLocation.binding(.east),
      StdAttr.labelFont.binding(StdAttr.defaultLabelFont),
      StdAttr.labelColor.binding(StdAttr.defaultLabelColor),
      StdAttr.labelVisibility.binding(true),
    ])
    setFacingAttribute(StdAttr.facing)
  }

  // MARK: Ports — `updatePorts(Instance)`
  //
  // Three 1-bit input ports (RED/GREEN/BLUE) whose offsets rotate with `StdAttr.FACING`,
  // transcribed verbatim from the Java `cx`/`cy`/`dx`/`dy` table.

  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    let facing = attributes[StdAttr.facing, default: .west]
    var cx = 0
    var cy = 0
    var dx = 0
    var dy = 0
    switch facing {
    case .north:
      cy = 10
      dx = 10
    case .east:
      cx = -10
      dy = 10
    case .south:
      cy = -10
      dx = -10
    case .west:
      cx = 10
      dy = -10
    }
    // Indices match `RED`/`GREEN`/`BLUE` above.
    return [
      Port(0, 0, .input, 1),
      Port(cx + dx, cy + dy, .input, 1),
      Port(cx - dx, cy - dy, .input, 1),
    ]
  }

  // MARK: ComponentFactory

  /// `activeOnHigh(AttributeSet)`.
  public override func activeOnHigh(_ attributes: any AttributeSet) -> Bool {
    attributes[IoLibrary.active, default: true]
  }

  /// `getOffsetBounds(AttributeSet)`: identical to `Led`'s: a 20×20 box facing west, rotated.
  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let facing = attributes[StdAttr.facing, default: .west]
    return Bounds.create(0, -10, 20, 20).rotate(from: .west, to: facing, xc: 0, yc: 0)
  }

  // MARK: InstanceFactory

  /// `propagate(InstanceState)`.
  public override func propagate(_ state: any InstanceState) throws {
    var summary: Int32 = 0
    for i in 0..<3 {
      if state.portValue(i) == .trueValue {
        summary |= Int32(1) << Int32(i)
      }
    }
    if let data = state.data as? InstanceDataSingleton {
      data.value = summary
    } else {
      state.setData(InstanceDataSingleton(summary))
    }
  }
}

// MARK: - Paint (D6)

extension RgbLed: IoPaintable {

  /// `paintGhost(InstancePainter)`: `RgbLed.java:169-174`. Identical to `Led`'s.
  public func paintGhost(_ painter: any IoInstancePainter) {
    let bds = painter.bounds
    painter.withWidth(2) {
      painter.scene.drawOval(bds.x + 1, bds.y + 1, bds.width - 2, bds.height - 2)
    }
  }

  /// `paintInstance(InstancePainter)`; `RgbLed.java:176-197`.
  ///
  /// The LED colour here comes from the *simulation value*, not from an attribute: each of the
  /// three channels is on-or-off, so the face is one of the eight corners of the RGB cube.
  /// `ATTR_ACTIVE == false` inverts all three (`mask = 7`, `sum ^= mask`), which is why an
  /// inactive-high RGB LED with no input reads white rather than black.
  public func paintInstance(_ painter: any IoInstancePainter) {
    var sum = Int(painter.singletonData?.value as? Int32 ?? 0)
    let bds = painter.bounds.expand(-1)
    let g = painter.scene

    if painter.showState {
      let active = painter.attributeValue(IoLibrary.active, default: true)
      let mask = active ? 0 : 7
      sum ^= mask
      let red = UInt8(((sum >> RgbLed.red) & 1) * 0xFF)
      let green = UInt8(((sum >> RgbLed.green) & 1) * 0xFF)
      let blue = UInt8(((sum >> RgbLed.blue) & 1) * 0xFF)
      g.color = .rgba(RGBA(r: red, g: green, b: blue))
      g.fillOval(bds.x, bds.y, bds.width, bds.height)
    }

    g.color = painter.componentColor
    painter.withWidth(2) {
      g.drawOval(bds.x, bds.y, bds.width, bds.height)
    }
    painter.drawLabel()
    painter.drawPorts()
  }
}

// MARK: - Label (board #78)

extension RgbLed: InstanceLabelProvider {

  /// `Instance.computeLabelTextField(Instance.AVOID_LEFT)`: `RgbLed.java:155`, re-run at
  /// `:169`/`:171`.
  public func labelPlacement(_ painter: InstancePainter) -> LabelPlacement? {
    LabelPlacement.computed(painter, avoid: .left)
  }
}
