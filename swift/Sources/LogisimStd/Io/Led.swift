// Led.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.io.Led),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Not ported ──────────────────────────────────────────────────────────────────────────────
//
//   * `setIcon`: the toolbar/attribute-table icon, UI (D9). `paintInstance`/`paintGhost` ARE
//     ported; see the Paint section at the end of this file.
//   * `DynamicElementProvider`/`createDynamicElement` (`LedShape`): appearance editor, M7.
//   * `Led.Logger` (`InstanceLogger`); the Log-window value probe. `InstanceFactory.swift`'s
//     header already records `setInstanceLogger` as unported: it takes a `Class<?>` and
//     instantiates it reflectively, with no AOT-Swift equivalent; pokers/loggers are M6 work.
//   * `setKeyConfigurator`; UI (D9).
//   * `StdAttr.MAPINFO`; omitted; see `SevenSegment.swift`'s file header for why.
//
// Needs `StdAttr.labelLocation`: see `SevenSegment.swift`'s file header; same gap, same fix.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.io.Led`.
public final class Led: InstanceFactoryBase {

  /// `Led._ID`.
  public static let id = "LED"

  /// `Led()`.
  public init() {
    super.init(Led.id, requiresLabel: true)
    setAttributes([
      StdAttr.facing.binding(.west),
      IoLibrary.onColor.binding(ColorSpec(red: 240, green: 0, blue: 0)),
      IoLibrary.offColor.binding(ColorSpec(red: 64, green: 64, blue: 64)),  // Color.DARK_GRAY
      IoLibrary.active.binding(true),
      StdAttr.label.binding(""),
      StdAttr.labelLocation.binding(.east),
      StdAttr.labelFont.binding(StdAttr.defaultLabelFont),
      StdAttr.labelColor.binding(StdAttr.defaultLabelColor),
      StdAttr.labelVisibility.binding(true),
    ])
    setFacingAttribute(StdAttr.facing)
    setPorts([Port(0, 0, .input, 1)])
  }

  // MARK: ComponentFactory

  /// `activeOnHigh(AttributeSet)`.
  public override func activeOnHigh(_ attributes: any AttributeSet) -> Bool {
    attributes[IoLibrary.active, default: true]
  }

  /// `getOffsetBounds(AttributeSet)`: a 20×20 box facing west, rotated to the instance's facing.
  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let facing = attributes[StdAttr.facing, default: .west]
    return Bounds.create(0, -10, 20, 20).rotate(from: .west, to: facing, xc: 0, yc: 0)
  }

  // MARK: InstanceFactory

  /// `propagate(InstanceState)`.
  public override func propagate(_ state: any InstanceState) throws {
    let value = state.portValue(0)
    if let data = state.data as? InstanceDataSingleton {
      data.value = value
    } else {
      state.setData(InstanceDataSingleton(value))
    }
  }
}

// MARK: - Paint (D6)

extension Led: IoPaintable {

  /// `paintGhost(InstancePainter)`, `Led.java:126-131`.
  public func paintGhost(_ painter: any IoInstancePainter) {
    let bds = painter.bounds
    painter.withWidth(2) {
      painter.scene.drawOval(bds.x + 1, bds.y + 1, bds.width - 2, bds.height - 2)
    }
  }

  /// `paintInstance(InstancePainter)`; `Led.java:133-153`.
  ///
  /// Note the outline is drawn on the **inset** `bds`, not on `painter.bounds`: Java reuses the
  /// one `bds` local for the fill and the outline, so the ring sits 1px inside the component
  /// box on every side. Drawing it on the un-inset bounds would make every LED in the corpus
  /// two pixels wider than the reference.
  public func paintInstance(_ painter: any IoInstancePainter) {
    let value = painter.singletonData?.value as? Value ?? .falseValue
    let bds = painter.bounds.expand(-1)
    let g = painter.scene

    if painter.showState {
      let onColor = painter.attributeValue(IoLibrary.onColor, default: Led.defaultOnColor)
      let offColor = painter.attributeValue(IoLibrary.offColor, default: Led.defaultOffColor)
      let active = painter.attributeValue(IoLibrary.active, default: true)
      let desired: Value = active ? .trueValue : .falseValue
      g.color = .attribute(value == desired ? onColor : offColor)
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

extension Led {
  /// The attribute-template defaults, so a painter reading an attribute set that somehow lacks
  /// them falls back to what the constructor installs rather than to an arbitrary colour.
  static let defaultOnColor = ColorSpec(red: 240, green: 0, blue: 0)
  /// `Color.DARK_GRAY`.
  static let defaultOffColor = ColorSpec(red: 64, green: 64, blue: 64)
}

// MARK: - Label (board #78)

extension Led: InstanceLabelProvider {

  /// `Instance.computeLabelTextField(Instance.AVOID_LEFT)`: `Led.java:108`, re-run from
  /// `instanceAttributeChanged` at `:121` and `:123`. This port recomputes the placement on
  /// demand rather than caching it on the component, so the two re-runs need no transcription.
  public func labelPlacement(_ painter: InstancePainter) -> LabelPlacement? {
    LabelPlacement.computed(painter, avoid: .left)
  }
}
