// PlaRom.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.io.extra.PlaRom),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Reads the real `Mem.ATTR_SELECTION`/`SEL_HIGH`/`SEL_LOW`/`DELAY` from the `std/memory` slice
// (`LogisimStd/Memory/Mem.swift`), which landed while this file was in progress; `PlaRom` does
// not extend `Mem` upstream either, it just imports these four shared constants.
//
// ── What did not come across ─────────────────────────────────────────────────────────────────
//
//   * `ContentsAttribute.getCellEditor` / `ContentsCell` / `PlaMenu` (`MenuExtender`): the Swing
//     matrix editor and its context-menu entry point. UI/M6; `PlaRomData` (this component's
//     model-level content) is fully ported.
//   * `Logger`; log-window value source; UI/M6.
//   (`paintInstance` IS ported; see the Paint section at the end of the factory.)
//   * `setIcon(new ArithmeticIcon(...))`: a painter-time icon, not a `.gif`; UI either way.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.io.extra.PlaRom`.
public final class PlaRom: InstanceFactoryBase {

  public static let id = "PlaRom"

  private static let inputPort = 0
  private static let outputPort = 1
  private static let chipSelectPort = 2

  public static let attrInputs: Attribute<Int32> = Attributes.forIntegerRange(
    "inputs", start: 1, end: 32)
  public static let attrAnd: Attribute<Int32> = Attributes.forIntegerRange(
    "and", start: 1, end: 32)
  public static let attrOutputs: Attribute<Int32> = Attributes.forIntegerRange(
    "outputs", start: 1, end: 32)
  /// `PlaRom.CONTENTS_ATTR`: upstream's hand-written `Attribute<String>` subclass, minus its
  /// `getCellEditor` override (UI). `parse` is the identity function upstream, matching
  /// `Attributes.forString`'s default scrub (content is always digits/`*`/spaces, so the scrub
  /// is a no-op in practice).
  public static let attrContents: Attribute<String> = Attributes.forString("Contents")

  public init() {
    super.init(PlaRom.id, displayName: "PLA")
    setAttributes([
      PlaRom.attrInputs.binding(4),
      PlaRom.attrAnd.binding(4),
      PlaRom.attrOutputs.binding(4),
      StdAttr.label.binding(""),
      StdAttr.labelFont.binding(StdAttr.defaultLabelFont),
      StdAttr.labelVisibility.binding(true),
      PlaRom.attrContents.binding(""),
      Mem.selection.binding(Mem.selLow),
    ])
    setOffsetBounds(Bounds.create(0, -30, 60, 60))
  }

  /// `PlaRom.getPlaRomData(InstanceState)`. `throws` because `decodeSavedData` does (D13); Java
  /// declares nothing either, but its `NumberFormatException` propagates out of here to
  /// `propagate` and on to `Simulator.recordException` exactly the same way.
  private static func data(for state: any InstanceState) throws -> PlaRomData {
    let inputs = Int(state.attributeValue(PlaRom.attrInputs, default: 4))
    let outputs = Int(state.attributeValue(PlaRom.attrOutputs, default: 4))
    let and = Int(state.attributeValue(PlaRom.attrAnd, default: 4))
    if let existing = state.data as? PlaRomData {
      if existing.updateSize(inputs: inputs, outputs: outputs, and: and) {
        try? state.attributeSet.setValue(PlaRom.attrContents, existing.getSavedData())
      }
      return existing
    }
    let fresh = PlaRomData(inputs: inputs, outputs: outputs, and: and)
    try fresh.decodeSavedData(state.attributeValue(PlaRom.attrContents))
    state.setData(fresh)
    return fresh
  }

  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    let inputWidth = Int(attributes.getValue(PlaRom.attrInputs) ?? 4)
    let outputWidth = Int(attributes.getValue(PlaRom.attrOutputs) ?? 4)
    return [
      Port(0, 0, .input, inputWidth),
      Port(60, 0, .output, outputWidth),
      Port(30, 30, .input, 1),
    ]
  }

  public override func propagate(_ state: any InstanceState) throws {
    let data = try PlaRom.data(for: state)
    let chipSelect = state.portValue(PlaRom.chipSelectPort)
    let selection = state.attributeValue(Mem.selection, default: Mem.selLow) == Mem.selHigh
    let active = !((chipSelect == .falseValue && selection) || (chipSelect == .trueValue && !selection))
    if !active {
      state.setPort(
        PlaRom.outputPort, Value.createUnknown(BitWidth.known(data.outputs)), Mem.delay)
      return
    }
    // `PlaRom.propagate` reverses the input bus before feeding it to the matrix, and
    // `PlaRomData.reversedOutputValues()` reverses it back on the way out (MSB-first matrix
    // column order ↔ LSB-first port bit order).
    var inputs = state.portValue(PlaRom.inputPort).getAll()
    inputs.reverse()
    data.setInputsValue(inputs)
    state.setPort(PlaRom.outputPort, try Value.create(data.reversedOutputValues()), Mem.delay)
  }

  // MARK: - Paint (D6)

  /// The paint-path twin of `data(for:)`.
  ///
  /// The `setValue` that `data(for:)` performs on a resize is deliberately **not** repeated
  /// here. Writing the contents attribute back from inside a paint would mutate the document
  /// while drawing it, and `data(for:)` on the propagate path already does it; the only cost is
  /// that a resize noticed first by a repaint saves on the next propagation instead.
  private static func data(painting painter: any IoInstancePainter) -> PlaRomData {
    let inputs = Int(painter.attributeValue(PlaRom.attrInputs, default: 4))
    let outputs = Int(painter.attributeValue(PlaRom.attrOutputs, default: 4))
    let and = Int(painter.attributeValue(PlaRom.attrAnd, default: 4))
    if let existing = painter.data as? PlaRomData {
      _ = existing.updateSize(inputs: inputs, outputs: outputs, and: and)
      return existing
    }
    let fresh = PlaRomData(inputs: inputs, outputs: outputs, and: and)
    try? fresh.decodeSavedData(painter.attributeValue(PlaRom.attrContents))
    painter.setData(fresh)
    return fresh
  }

  /// `paintInstance(InstancePainter)`: `PlaRom.java:290-311`.
  ///
  /// A white rounded box with the caption "PLA ROM" over the matrix dimensions. The caption is
  /// suppressed when the component carries a label, so the two do not overlap, but the size
  /// string is always drawn.
  ///
  /// `bds.height / 3` and `bds.height / 3 * 2 - 3` are integer divisions in that order; the
  /// second is *not* `2 * height / 3`, so at a height of 50 the two lines sit at 16 and 29
  /// rather than at 16 and 33.
  public func paintInstance(_ painter: any IoInstancePainter) {
    let data = PlaRom.data(painting: painter)
    let g = painter.scene
    g.color = painter.componentColor
    // `drawRoundBounds(Color.WHITE)`: white is the one colour the helper refuses to fill with,
    // so this outlines only; the box is transparent, not white.
    painter.drawRoundBounds(painter.bounds, .white)
    let bds = painter.bounds
    g.font = SceneFont(family: .named("sans serif"), size: 11, bold: true)
    let label = painter.attributeValue(StdAttr.label, default: "")
    if label.isEmpty {
      g.drawCenteredText("PLA ROM", x: bds.x + bds.width / 2, y: bds.y + bds.height / 3)
    }
    g.drawCenteredText(
      data.sizeString, x: bds.x + bds.width / 2, y: bds.y + bds.height / 3 * 2 - 3)
    painter.drawPort(PlaRom.inputPort)
    painter.drawPort(PlaRom.outputPort)
    painter.drawPort(PlaRom.chipSelectPort, "sel", .south)
    painter.drawLabel()
  }
}

extension PlaRom: IoPaintable {}

// MARK: - Label (board #78)

extension PlaRom: InstanceLabelProvider {

  /// `instance.setTextField(StdAttr.LABEL, StdAttr.LABEL_FONT, bds.getX() + bds.getWidth() / 2,`
  /// `bds.getY() + bds.getHeight() / 3, H_CENTER, V_CENTER_OVERALL)`: `PlaRom.java:267-274`.
  ///
  /// **Inside** the body, at one third of its height; the same anchor `paintInstance` uses for
  /// the "PLA ROM" placeholder it draws only when the label is empty (`PlaRom.swift:153`), which
  /// is exactly upstream's arrangement: the label replaces the placeholder in place.
  public func labelPlacement(_ painter: InstancePainter) -> LabelPlacement? {
    let bds = painter.bounds
    return LabelPlacement(
      x: bds.x + bds.width / 2, y: bds.y + bds.height / 3, halign: .center,
      valign: .centerOverall)
  }
}
