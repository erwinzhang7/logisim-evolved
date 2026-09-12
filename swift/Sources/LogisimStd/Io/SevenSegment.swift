// SevenSegment.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.io.SevenSegment),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Not ported ──────────────────────────────────────────────────────────────────────────────
//
//   * `setIcon`; UI (D9). `paintInstance`/`drawBase` ARE ported; see the Paint section below.
//     `SEGMENTS` was always plain grid data rather than a drawing call, and is unchanged.
//   * `DynamicElementProvider`/`createDynamicElement` (`SevenSegmentShape`); the appearance
//     editor's live-indicator elements. That editor is an M7 backlog item; nothing at M5 reads it.
//   * `setKeyConfigurator`: the attribute-table key handler, UI (D9).
//   * `StdAttr.MAPINFO`; omitted from the attribute template. It is FPGA board-mapping metadata
//     (`ComponentMapInformationContainer`, `com.cburch.logisim.fpga.data`) that this port has not
//     touched at all; the attribute is hidden and never saved upstream
//     (`Attributes.forMap()`/`isToSave() == false`), so dropping it changes nothing observable
//     until board mapping itself is ported. `getLabels()`/`getOutputLabel()` are kept anyway
//     (cheap, pure data, and `HexDigit` reuses `getLabels()`) even though nothing calls them yet.
//
// ── A dependency this file needs that it does not own ──────────────────────────────────────
//
// `instance.getAttributeValue(StdAttr.LABEL_LOC)` (Java) has no port yet; `StdAttr.swift`'s own
// header records `LABEL_LOC` as deliberately deferred ("nothing in this milestone needs it").
// This component needs it now, so it is referenced here as `StdAttr.labelLocation` /
// `StdAttr.LabelLocation` as if already present; see this slice's final report for the exact
// addition `LogisimFile/StdAttr.swift` needs.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.io.SevenSegment`.
public final class SevenSegment: InstanceFactoryBase {

  /// `SevenSegment._ID`.
  public static let id = "7-Segment Display"

  // MARK: Segment indices — `Segment_A` … `Segment_G`, `DP`

  public static let segmentA = 0
  public static let segmentB = 1
  public static let segmentC = 2
  public static let segmentD = 3
  public static let segmentE = 4
  public static let segmentF = 5
  public static let segmentG = 6
  public static let decimalPointIndex = 7

  /// `SevenSegment.getLabels()`. FPGA board-mapping labels; see the file header for why nothing
  /// currently calls this.
  public static func labels() -> [String] {
    var result = [String](repeating: "", count: 8)
    result[segmentA] = "Segment_A"
    result[segmentB] = "Segment_B"
    result[segmentC] = "Segment_C"
    result[segmentD] = "Segment_D"
    result[segmentE] = "Segment_E"
    result[segmentF] = "Segment_F"
    result[segmentG] = "Segment_G"
    result[decimalPointIndex] = "DecimalPoint"
    return result
  }

  /// `SevenSegment.getOutputLabel(int)`.
  public static func outputLabel(_ id: Int) -> String {
    let names = labels()
    guard id >= 0, id <= names.count else { return "Undefined" }
    return names[id]
  }

  /// `SevenSegment.ATTR_DP`.
  public static let attrDecimalPoint: Attribute<Bool> = Attributes.forBoolean("decimalPoint")

  /// `SevenSegment.DEFAULT_OFF`, `new Color(220, 220, 220)`.
  public static let defaultOff = ColorSpec(red: 220, green: 220, blue: 220)

  /// `SevenSegment.SEGMENTS`: factory-relative segment rectangles, `ensureSegments()` inlined
  /// since there is no lazy-static race to guard against here. Read only by `drawBase` below.
  public static let segmentBounds: [Bounds] = [
    Bounds.create(3, 8, 19, 4),
    Bounds.create(23, 10, 4, 19),
    Bounds.create(23, 30, 4, 19),
    Bounds.create(3, 47, 19, 4),
    Bounds.create(-2, 30, 4, 19),
    Bounds.create(-2, 10, 4, 19),
    Bounds.create(3, 28, 19, 4),
  ]

  /// `SevenSegment()`.
  public init() {
    super.init(SevenSegment.id, requiresLabel: true)
    setAttributes([
      IoLibrary.onColor.binding(ColorSpec(red: 240, green: 0, blue: 0)),
      IoLibrary.offColor.binding(SevenSegment.defaultOff),
      IoLibrary.background.binding(IoLibrary.defaultBackground),
      IoLibrary.active.binding(true),
      SevenSegment.attrDecimalPoint.binding(true),
      StdAttr.label.binding(""),
      StdAttr.labelLocation.binding(.east),
      StdAttr.labelFont.binding(StdAttr.defaultLabelFont),
      StdAttr.labelVisibility.binding(false),
    ])
    setOffsetBounds(Bounds.create(-5, 0, 40, 60))
  }

  // MARK: Ports — `updatePorts(Instance)`

  /// `updatePorts(Instance)`. dx/dy transcribed verbatim; only `DP`'s presence depends on the
  /// attribute, and the chassis recomputes-and-diffs on every attribute change (see
  /// `InstanceFactory.swift`'s header), so no `instanceAttributeChanged` override is needed for
  /// `ATTR_DP`.
  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    let hasDp = attributes[SevenSegment.attrDecimalPoint, default: true]
    var ports: [Port] = [
      Port(20, 0, .input, 1),  // Segment_A
      Port(30, 0, .input, 1),  // Segment_B
      Port(20, 60, .input, 1),  // Segment_C
      Port(10, 60, .input, 1),  // Segment_D
      Port(0, 60, .input, 1),  // Segment_E
      Port(10, 0, .input, 1),  // Segment_F
      Port(0, 0, .input, 1),  // Segment_G
    ]
    if hasDp {
      ports.append(Port(30, 60, .input, 1))  // DP
    }
    return ports
  }

  // MARK: ComponentFactory

  /// `activeOnHigh(AttributeSet)`.
  public override func activeOnHigh(_ attributes: any AttributeSet) -> Bool {
    attributes[IoLibrary.active, default: true]
  }

  // MARK: Paint (D6) — `drawBase(InstancePainter, boolean)`, shared with `HexDigit`

  /// `SevenSegment.drawBase(InstancePainter, boolean)`; `SevenSegment.java:46-81`.
  ///
  /// `static` because `HexDigit.paintInstance` is literally
  /// `SevenSegment.drawBase(painter, painter.getAttributeValue(SevenSegment.ATTR_DP))`: one
  /// glyph renderer, two factories, differing only in how the segment bit set was computed
  /// during `propagate`.
  ///
  /// Two details that are easy to lose and are visible at any zoom:
  ///
  ///   * the segment rectangles are anchored at `bounds.x + 5`, **not** `bounds.x`. The offset
  ///     bounds are 40 wide while the glyph is 30 wide, so the 5 is what centres it; the DP is
  ///     then at `x + 28`, i.e. `bounds.x + 33`.
  ///   * when `showState` is false the pen stays `DARK_GRAY` for all eight segments, so the
  ///     inert preview is a solid "8." rather than a blank. Upstream sets the colour *inside*
  ///     the loop only under `getShowState()`, and never resets it, which is what produces
  ///     that.
  public static func drawBase(_ painter: any IoInstancePainter, drawPoint: Bool) {
    let summ = Int(painter.singletonData?.value as? Int32 ?? 0)
    let active = painter.attributeValue(IoLibrary.active, default: true)
    let desired = active ? 1 : 0

    let bds = painter.bounds
    let x = bds.x + 5
    let y = bds.y

    let g = painter.scene
    let onColor = painter.attributeValue(IoLibrary.onColor, default: defaultOnColor)
    let offColor = painter.attributeValue(IoLibrary.offColor, default: defaultOff)
    let bgColor = painter.attributeValue(IoLibrary.background, default: IoLibrary.defaultBackground)

    if painter.shouldDrawColor && bgColor.alpha != 0 {
      g.color = .attribute(bgColor)
      g.fillRect(bds.x, bds.y, bds.width, bds.height)
      g.color = .black
    }
    painter.drawBounds()
    g.color = .darkGray
    for i in 0...7 {
      if painter.showState {
        g.color = .attribute(((summ >> i) & 1) == desired ? onColor : offColor)
      }
      if i < 7 {
        let seg = segmentBounds[i]
        g.fillRect(x + seg.x, y + seg.y, seg.width, seg.height)
      } else if drawPoint {
        g.fillOval(x + 28, y + 48, 5, 5)
      }
    }
    g.color = .black
    painter.drawLabel()
    painter.drawPorts()
  }

  /// `SevenSegment.DEFAULT_ON` is not a named constant upstream; it is the `new Color(240, 0, 0)`
  /// literal in the attribute template. Named here only so the painter has a fallback.
  static let defaultOnColor = ColorSpec(red: 240, green: 0, blue: 0)

  // MARK: InstanceFactory

  /// `propagate(InstanceState)`.
  public override func propagate(_ state: any InstanceState) throws {
    let hasDp = state.attributeValue(SevenSegment.attrDecimalPoint, default: true)
    let max = hasDp ? 8 : 7
    var summary: Int32 = 0
    for i in 0..<max {
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

extension SevenSegment: IoPaintable {
  /// `paintInstance(InstancePainter)`, `SevenSegment.java:260-263`.
  public func paintInstance(_ painter: any IoInstancePainter) {
    SevenSegment.drawBase(
      painter, drawPoint: painter.attributeValue(SevenSegment.attrDecimalPoint, default: true))
  }
}

// MARK: - Label (board #78)

extension SevenSegment: InstanceLabelProvider {

  /// `SevenSegment.computeTextField(Instance)`: `SevenSegment.java:202-234`, an explicit
  /// `setTextField` rather than a `computeLabelTextField` call.
  ///
  /// It is **not** `computeLabelTextField(AVOID_LEFT)`, and the difference is observable.
  /// The two agree on the shape of the rule, nudge when the label sits on the edge the
  /// component faces, since rotating `AVOID_LEFT` (0b1000) by the facing gives west→left,
  /// north→top, east→right, south→bottom, but they disagree on what happens when there is no
  /// facing at all, and `SevenSegment` **has no `StdAttr.FACING` in its attribute template**
  /// (`SevenSegment.java:140-166`; the `attributeValueChanged` arm at `:251` that tests for it
  /// is dead for this factory). `getAttributeValue(StdAttr.FACING)` therefore returns null,
  /// `labelLoc == facing` is false for all five locations, and no label is ever nudged,
  /// whereas the generic routine treats a null facing as the identity rotation and would still
  /// nudge a `WEST` label. Measured: `WEST` here is `(bds.x - 2, centre-y, H_RIGHT, V_CENTER)`,
  /// where an `AVOID_LEFT` factory gives `V_BOTTOM` two pixels higher.
  ///
  /// The `LABEL_CENTER` arm is absent upstream too, and falls through to the same centred
  /// defaults the generic routine computes when `AVOID_CENTER` is unset.
  public func labelPlacement(_ painter: InstancePainter) -> LabelPlacement? {
    SevenSegment.computeTextField(painter)
  }

  /// `SevenSegment.computeTextField(Instance)`: **static upstream too**, and that is why this is
  /// factored out rather than left inline: `HexDigit.java:110` and `:116` call this very method,
  /// so `Hex Digit Display` shares `SevenSegment`'s placement exactly. Duplicating the arithmetic
  /// into `HexDigit` would let the two drift, when upstream guarantees they cannot.
  ///
  /// It reads nothing from `self`, which is what makes the extraction free.
  public static func computeTextField(_ painter: InstancePainter) -> LabelPlacement? {
    let facing = painter.attributeValue(StdAttr.facing)
    let labelLoc = painter.attributeValue(StdAttr.labelLocation)

    let bds = painter.bounds
    var x = bds.x + bds.width / 2
    var y = bds.y + bds.height / 2
    var halign = HAlign.center
    var valign = VAlign.center
    switch labelLoc {
    case .north:
      y = bds.y - 2
      valign = .bottom
    case .south:
      y = bds.y + bds.height + 2
      valign = .top
    case .east:
      x = bds.x + bds.width + 2
      halign = .left
    case .west:
      x = bds.x - 2
      halign = .right
    case .center, nil:
      break
    }

    // `if (labelLoc == facing)`: an `Object == Direction` comparison in Java, so
    // `LABEL_CENTER` never matches and a null facing never matches either. The port's
    // `LabelLocation` is a separate enum from `Direction`, so the identity is spelled out.
    let sameSide: Bool
    switch (labelLoc, facing) {
    case (.north, .north), (.south, .south), (.east, .east), (.west, .west): sameSide = true
    default: sameSide = false
    }
    if sameSide {
      if labelLoc == .north || labelLoc == .south {
        x += 2
        halign = .left
      } else {
        y -= 2
        valign = .bottom
      }
    }
    return LabelPlacement(x: x, y: y, halign: halign, valign: valign)
  }
}
