// LogisimStdTests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE MEMORY FAMILY'S LABELS; board #78
//
// Upstream 4.1.0 installs a `StdAttr.LABEL` text field on 39 factories. Eleven of them are the
// memory family, reached through six declarations: `Mem` (the base of `Ram`, `Rom`, `DualRam`),
// `Register`, `Counter`, `ShiftRegister`, `Random`, and `AbstractFlipFlop` (the base of the four
// flip-flops). None of the eleven conformed to `InstanceLabelProvider` before this suite, so
// every one of them had a label attribute that NEITHER DREW NOR EDITED; `drawLabel()` returns
// on its first `guard` for a non-conformer, and `InstanceTextFieldSpec.resolve` returns `nil`.
//
// Three things are measured here, and they fail for different reasons:
//
//   1. THE PLACEMENT, as absolute integers. Nothing here recomputes the upstream arithmetic from
//      the component's own bounds; that would pass against a placement that is internally
//      consistent and wrong. The bounds are asserted too, so a change to `offsetBounds` breaks
//      this suite loudly rather than silently dragging the label with it.
//
//   2. THE DRAWING. Placement is a pure function; a returned struct proves nothing about the
//      raster. So the label is looked for in a real `RenderScene`, and compared against the
//      `TextRun` a `drawText` at the placement produces: same builder, same font, same
//      measurer. That ties `paintInstance` -> `drawLabel` -> the scene to `labelPlacement`.
//
//   3. THE EDITING. `InstanceTextFieldSpec.resolve` derives the six upstream `setTextField`
//      arguments from the *same* `labelPlacement`, which is what makes drawing and editing
//      unable to drift. Asserted rather than assumed, because the `containsAttribute(LABEL)`
//      pre-check in `resolve` is a second, independent way for a component to end up with no
//      editable field even once its factory conforms.
//
// THE TWO TRAPS, both real:
//
//   * `Mem` is NOT the same placement as the other four `setTextField` cases. `Mem.java:142` is
//     `bds.y - 2` / `V_BOTTOM`; `Counter.java:142`, `ShiftRegister.java:146`, `Random.java:172`
//     and `AbstractFlipFlop.java:233` are all `bds.y - 3` / `V_BASELINE`. One pixel and a
//     different baseline rule: invisible to a reviewer, visible in the raster.
//     `memIsNotTheOtherFour` asserts the difference directly so a bulk edit cannot flatten it.
//
//   * `Register` uses `computeLabelTextField(AVOID_SIDES)` at THREE call sites, Register.java:254
//     (`configureNewInstance`), :361 and :363 (`instanceAttributeChanged`), because upstream's
//     field is stored and must be re-derived when `WIDTH`/`APPEARANCE` resize the body or
//     `LABEL_LOC` moves it. `registerPlacementFollowsAttributeChanges` drives all three.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import Testing

@testable import LogisimStd

// MARK: - Harness

/// One component of `factory` at the origin, so `bounds == offsetBounds` and the expected
/// numbers below read as the upstream arithmetic rather than as arithmetic plus an offset.
private func placed(
  _ factory: any ComponentFactory, label: String = "Q7",
  configure: ((any AttributeSet) throws -> Void)? = nil
) throws -> StdInstanceComponent {
  let attributes = factory.createAttributeSet()
  try configure?(attributes)
  try attributes.setValue(StdAttr.label, label)
  let component = try factory.createComponent(
    location: Location.create(0, 0, hasToSnap: false), attributes: attributes)
  return try #require(
    component as? StdInstanceComponent,
    "\(factory.name) does not produce a StdInstanceComponent, so no label can attach to it")
}

/// The placement the painter and the text field both consult.
private func placement(of component: StdInstanceComponent) throws -> LabelPlacement {
  let provider = try #require(
    component.factory as? InstanceLabelProvider,
    "\(component.factory.name) does not conform to InstanceLabelProvider: label neither draws nor edits")
  let painter = InstancePainter(
    g: SceneBuilder(measurer: NominalTextMeasurer()), context: StaticPaintContext(),
    component: component)
  return try #require(
    provider.labelPlacement(painter), "\(component.factory.name) returned no placement")
}

/// Every memory factory, taken from the library so a later addition is covered automatically.
private func memoryFactories() -> [any ComponentFactory] {
  MemoryLibrary().tools.compactMap { ($0 as? AddTool)?.factory }
}

private func factory(_ name: String) throws -> any ComponentFactory {
  try #require(memoryFactories().first { $0.name == name }, "no memory factory named \(name)")
}

/// What the placement claims, flattened for a table-driven comparison.
private struct Placed: Equatable, CustomStringConvertible {
  var bounds: Bounds
  var x: Int
  var y: Int
  var halign: HAlign
  var valign: VAlign

  var description: String {
    "bds=\(bounds) label=(\(x), \(y), \(halign), \(valign))"
  }
}

private func measured(_ name: String) throws -> Placed {
  let component = try placed(try factory(name))
  let p = try placement(of: component)
  return Placed(
    bounds: component.bounds, x: p.x, y: p.y, halign: p.halign, valign: p.valign)
}

// MARK: - The gate

@Suite("Memory label placement — board #78")
struct MemoryLabelPlacementTests {

  // ── 1. Conformance. The one-line statement of the gap. ───────────────────────────────────

  /// Before this slice every one of these was in the failure list. `MemoryLibrary` has eleven
  /// factories and upstream installs a label field on all eleven, so the expected count is the
  /// whole library.
  @Test("every memory factory provides a label placement")
  func everyMemoryFactoryProvidesALabelPlacement() throws {
    let factories = memoryFactories()
    #expect(factories.count == 11)
    let missing =
      factories
      .filter { !($0 is InstanceLabelProvider) }
      .map(\.name)
      .sorted()
    #expect(
      missing.isEmpty,
      "memory factories whose label neither draws nor edits: \(missing.joined(separator: ", "))")
  }

  // ── 2. The placements, as absolute integers. ─────────────────────────────────────────────

  /// `Counter.java:142`, `(bds.x + bds.width / 2, bds.y - 3, H_CENTER, V_BASELINE)`.
  /// Default width 8 and the evolution appearance give `getSymbolWidth(8) + 40 == 190` wide.
  @Test("Counter places its label 3px above the top edge, centred, on the baseline")
  func counterPlacement() throws {
    #expect(
      try measured("Counter")
        == Placed(
          bounds: Bounds.create(0, 0, 190, 270), x: 95, y: -3, halign: .center, valign: .baseline))
  }

  /// `ShiftRegister.java:146`, identical arithmetic. `SymbolWidth + 20 == 120` wide at the
  /// default length of 8.
  @Test("Shift Register places its label 3px above the top edge, centred, on the baseline")
  func shiftRegisterPlacement() throws {
    #expect(
      try measured("Shift Register")
        == Placed(
          bounds: Bounds.create(0, 0, 120, 240), x: 60, y: -3, halign: .center, valign: .baseline))
  }

  /// `Random.java:172`, identical arithmetic, over the evolution body `(0, 0, 80, 90)`.
  @Test("Random places its label 3px above the top edge, centred, on the baseline")
  func randomPlacement() throws {
    #expect(
      try measured("Random")
        == Placed(
          bounds: Bounds.create(0, 0, 80, 90), x: 40, y: -3, halign: .center, valign: .baseline))
  }

  /// `AbstractFlipFlop.java:233`; identical arithmetic. The evolution body is `(-10, 0, 60, 60)`,
  /// so the centre is at `-10 + 30 == 20`, not at 30: the negative origin is the reason this is
  /// asserted absolutely rather than as "half the width".
  ///
  /// All four flip-flops are checked, because `configureNewInstance` sits in upstream's
  /// "concrete methods not intended to be overridden" block and none of them overrides it, so
  /// the port's inheritance of the conformance has to reach all four too.
  @Test("all four flip-flops inherit AbstractFlipFlop's placement")
  func flipFlopPlacement() throws {
    let expected = Placed(
      bounds: Bounds.create(-10, 0, 60, 60), x: 20, y: -3, halign: .center, valign: .baseline)
    for name in ["D Flip-Flop", "T Flip-Flop", "J-K Flip-Flop", "S-R Flip-Flop"] {
      #expect(try measured(name) == expected, "\(name) disagrees")
    }
  }

  /// **Trap 1.** `Mem.java:142` is `bds.y - 2` and `V_BOTTOM`, not `bds.y - 3` and `V_BASELINE`.
  ///
  /// All three of `Ram`, `Rom` and `DualRam` call `super.configureNewInstance(instance)`
  /// (Ram.java:107, Rom.java:132, DualRam.java:108) and install nothing of their own, so all
  /// three must inherit this.
  @Test("RAM, ROM and Dual Port RAM take Mem's -2 / V_BOTTOM placement, not the family's -3")
  func memPlacement() throws {
    // All three bodies are `Mem.SymbolWidth + 40 == 240` wide, so all three centres are 120;
    // only the heights differ. The x agreement is the point; it is inherited, not repeated.
    #expect(
      try measured("RAM")
        == Placed(
          bounds: Bounds.create(0, 0, 240, 250), x: 120, y: -2, halign: .center, valign: .bottom))
    #expect(
      try measured("ROM")
        == Placed(
          bounds: Bounds.create(0, 0, 240, 220), x: 120, y: -2, halign: .center, valign: .bottom))
    #expect(
      try measured("DualRAM")
        == Placed(
          bounds: Bounds.create(0, 0, 240, 500), x: 120, y: -2, halign: .center, valign: .bottom))
  }

  /// **Trap 1, stated as the difference rather than as two absolutes.** A bulk edit that
  /// unified the six factories onto one placement would leave every absolute assertion above
  /// green for five of the six and only redden `memPlacement`; this says the thing directly, so
  /// the intent survives a future refactor that changes the bodies' sizes.
  @Test("Mem's placement is deliberately NOT the placement the other four share")
  func memIsNotTheOtherFour() throws {
    let mem = try placement(of: try placed(try factory("ROM")))
    let counter = try placement(of: try placed(try factory("Counter")))
    #expect(mem.valign == .bottom)
    #expect(counter.valign == .baseline)
    #expect(mem.valign != counter.valign)
    // Both bodies start at y == 0 here, so the raw y values are the two upstream constants.
    #expect(mem.y == -2)
    #expect(counter.y == -3)
  }

  /// `Register.java:254`, `computeLabelTextField(Instance.AVOID_SIDES)`. With the shipped
  /// defaults (`LABEL_LOC == north`, and a register carries no `StdAttr.FACING` so the avoid
  /// mask does not rotate, leaving `AVOID_TOP` clear) `Instance.java:143-149` resolves to
  /// `(bds.x + bds.width / 2, bds.y - 2, H_CENTER, V_BOTTOM)` over the evolution body
  /// `(0, 0, 60, 90)`.
  @Test("Register resolves computeLabelTextField(AVOID_SIDES) to the north edge")
  func registerPlacement() throws {
    #expect(
      try measured("Register")
        == Placed(
          bounds: Bounds.create(0, 0, 60, 90), x: 30, y: -2, halign: .center, valign: .bottom))
  }

  // ── 3. Trap 2: Register's placement must FOLLOW an attribute change. ─────────────────────

  /// Upstream needs three call sites because its text field is stored state. This port computes
  /// on demand, so the claim to verify is that each of the three triggers actually moves the
  /// placement: a `labelPlacement` that ignored `LABEL_LOC`, or that was computed once from a
  /// cached bounds, would pass `registerPlacement` above and fail here.
  ///
  /// Each arm is a distinct upstream branch:
  ///   * `StdAttr.APPEARANCE` -> `recomputeBounds` + `computeLabelTextField` (Register.java:358-361)
  ///   * `StdAttr.WIDTH`      -> the same branch
  ///   * `Register.labelLocation` (upstream `StdAttr.LABEL_LOC`) -> Register.java:362-363
  @Test("Register's placement follows appearance, width and label-location changes")
  func registerPlacementFollowsAttributeChanges() throws {
    let evolution = try measured("Register")
    #expect(
      evolution
        == Placed(
          bounds: Bounds.create(0, 0, 60, 90), x: 30, y: -2, halign: .center, valign: .bottom))

    // APPEARANCE: the classic body is `(-30, -20, 30, 40)`, so the label moves to a negative
    // origin; a cached placement would still claim (30, -2).
    let classic = try placed(try factory("Register")) {
      try $0.setValue(StdAttr.appearance, StdAttr.appearClassic)
    }
    let classicPlacement = try placement(of: classic)
    #expect(classic.bounds == Bounds.create(-30, -20, 30, 40))
    #expect(classicPlacement.x == -15)
    #expect(classicPlacement.y == -22)
    #expect(classicPlacement.valign == .bottom)

    // WIDTH: the evolution register's bounds are width-independent (Register.java:243-247 returns
    // a fixed `(0, 0, 60, 90)`), so this arm asserts the *invariance* upstream also has. Stated
    // rather than skipped: a placement that keyed off the width would be wrong here.
    let wide = try placed(try factory("Register")) {
      try $0.setValue(StdAttr.width, BitWidth.known(32))
    }
    #expect(try placement(of: wide) == LabelPlacement(x: 30, y: -2, halign: .center, valign: .bottom))

    // LABEL_LOC: each of the other four locations lands somewhere different, and `east`/`west`
    // are the two the `AVOID_SIDES` mask actually bites on (`Instance.java:157-170` nudges y by
    // 2 and switches to `V_BOTTOM` there).
    let expectations: [(AttributeOption, LabelPlacement)] = [
      (Register.labelLocationSouth, LabelPlacement(x: 30, y: 92, halign: .center, valign: .top)),
      (Register.labelLocationEast, LabelPlacement(x: 62, y: 43, halign: .left, valign: .bottom)),
      (Register.labelLocationWest, LabelPlacement(x: -2, y: 43, halign: .right, valign: .bottom)),
      (Register.labelLocationCenter, LabelPlacement(x: 30, y: 45, halign: .center, valign: .center)),
    ]
    for (option, expected) in expectations {
      let component = try placed(try factory("Register")) {
        try $0.setValue(Register.labelLocation, option)
      }
      #expect(try placement(of: component) == expected, "label location \(option.name) disagrees")
    }
  }

  // ── 4. The drawing half. ─────────────────────────────────────────────────────────────────

  /// A placement struct is not a pixel. This renders the component through the real
  /// `paintInstance` and looks for the label in the resulting `RenderScene`, then compares that
  /// `TextRun` against the one a `drawText` at the placement produces on an identical builder.
  ///
  /// Byte-equality of the two runs is the assertion, so it covers the anchor, the resolved
  /// baseline, the measured box and both alignments at once: without this test re-deriving any
  /// of the layout arithmetic itself.
  ///
  /// `RAM`, `ROM` and `DualRAM` are deliberately absent, see `ramRomAndDualRamEditButDoNotDraw`.
  @Test("the label actually reaches the scene, at the placement")
  func theLabelDrawsAtThePlacement() throws {
    for name in [
      "Register", "Counter", "Shift Register", "Random",
      "D Flip-Flop", "T Flip-Flop", "J-K Flip-Flop", "S-R Flip-Flop",
    ] {
      let component = try placed(try factory(name), label: "Q7")
      let paintable = try #require(
        component.factory as? any InstancePaintable, "\(name) is not paintable")

      let builder = SceneBuilder(measurer: NominalTextMeasurer())
      let painter = InstancePainter(
        g: builder, context: StaticPaintContext(), component: component)
      paintable.paintInstance(painter)
      let scene = builder.finish()

      let labelRuns = scene.texts.filter { $0.string == "Q7" }
      #expect(labelRuns.count == 1, "\(name) drew \(labelRuns.count) runs of the label, expected 1")
      guard let drawn = labelRuns.first else { continue }

      // The same call `drawLabel` makes, on a fresh builder, from the placement under test.
      let p = try placement(of: component)
      let reference = SceneBuilder(measurer: NominalTextMeasurer())
      reference.font = InstancePainter.sceneFont(
        component.attributeSet.getValue(StdAttr.labelFont) ?? StdAttr.defaultLabelFont)
      reference.drawText("Q7", x: p.x, y: p.y, halign: p.halign, valign: p.valign)
      let expected = try #require(reference.finish().texts.first)

      #expect(drawn.baselineX == expected.baselineX, "\(name) baselineX")
      #expect(drawn.baselineY == expected.baselineY, "\(name) baselineY")
      #expect(drawn.boxX == expected.boxX, "\(name) boxX")
      #expect(drawn.boxY == expected.boxY, "\(name) boxY")
      #expect(drawn.boxWidth == expected.boxWidth, "\(name) boxWidth")
      #expect(drawn.boxHeight == expected.boxHeight, "\(name) boxHeight")
      #expect(drawn.halign == expected.halign, "\(name) halign")
      #expect(drawn.valign == expected.valign, "\(name) valign")
      #expect(drawn.font == expected.font, "\(name) font")
    }
  }

  /// **A verified upstream asymmetry, reproduced rather than fixed (D18).**
  ///
  /// `Mem.configureNewInstance` installs a text field on RAM, ROM and Dual Port RAM
  /// (Mem.java:135-143), so in 4.1.0 their labels are clickable and editable. But
  /// `Ram.paintInstance` (Ram.java:219-225), `Rom.paintInstance` (Rom.java:206) and
  /// `DualRam.paintInstance` (DualRam.java:221) delegate straight to `RamAppearance.drawRam*`,
  /// and `grep -n drawLabel Ram.java Rom.java DualRam.java Mem.java RamAppearance.java` in the
  /// 4.1.0 tree returns **nothing**; the only two `painter.drawLabel()` call sites in the whole
  /// upstream source are `SubcircuitFactory.java:358` and `InstancePainter.java:69` itself.
  /// So a labelled RAM in 4.1.0 edits and never draws.
  ///
  /// This port reproduces that exactly, and for the same structural reason: its `Ram`/`Rom`/
  /// `DualRam` painters do not call `drawLabel()` either. Asserted so that "adding the missing
  /// `drawLabel()` call", which looks like an obvious completion of this task, cannot land
  /// silently as a divergence from the jar.
  @Test("RAM, ROM and Dual Port RAM edit their label but do not draw it — as 4.1.0 does not")
  func ramRomAndDualRamEditButDoNotDraw() throws {
    for name in ["RAM", "ROM", "DualRAM"] {
      let component = try placed(try factory(name), label: "Q7")

      // The editing half is live: the field exists and sits at Mem's placement.
      let spec = try #require(
        InstanceTextFieldSpec.resolve(for: component, measurer: NominalTextMeasurer()),
        "\(name) lost its editable field")
      #expect(spec.y == -2)
      #expect(spec.valign == .bottom)

      // The drawing half is deliberately absent.
      let paintable = try #require(component.factory as? any InstancePaintable)
      let builder = SceneBuilder(measurer: NominalTextMeasurer())
      paintable.paintInstance(
        InstancePainter(g: builder, context: StaticPaintContext(), component: component))
      let drawn = builder.finish().texts.filter { $0.string == "Q7" }
      #expect(
        drawn.isEmpty,
        "\(name) drew its label; 4.1.0 does not, because its paintInstance never calls drawLabel()")
    }
  }

  /// The negative control for the arm above. An empty label must draw nothing at all:
  /// `drawLabel` guards on it, and a text run of `""` in the scene would mean the guard moved.
  @Test("an unlabelled memory component draws no label run")
  func anUnlabelledComponentDrawsNothing() throws {
    let component = try placed(try factory("Register"), label: "")
    let paintable = try #require(component.factory as? any InstancePaintable)
    let builder = SceneBuilder(measurer: NominalTextMeasurer())
    paintable.paintInstance(
      InstancePainter(g: builder, context: StaticPaintContext(), component: component))
    #expect(builder.finish().texts.allSatisfy { !$0.string.isEmpty })
  }

  // ── 5. The editing half. ─────────────────────────────────────────────────────────────────

  /// `InstanceTextFieldSpec.resolve` is what makes a label clickable. It recomputes the six
  /// upstream `setTextField` arguments from the same `labelPlacement`, so this asserts the
  /// agreement rather than a second copy of the numbers: and, separately, that the spec exists
  /// at all, which the `containsAttribute(StdAttr.label)` pre-check can independently deny.
  @Test("every memory component's editable field sits exactly where its label draws")
  func theEditableFieldAgreesWithTheDrawnLabel() throws {
    for name in [
      "RAM", "ROM", "DualRAM", "Register", "Counter", "Shift Register", "Random",
      "D Flip-Flop", "T Flip-Flop", "J-K Flip-Flop", "S-R Flip-Flop",
    ] {
      let component = try placed(try factory(name))
      let spec = try #require(
        InstanceTextFieldSpec.resolve(for: component, measurer: NominalTextMeasurer()),
        "\(name) has no editable text field, so its label cannot be clicked")
      let p = try placement(of: component)
      #expect(spec.x == p.x, "\(name) field x")
      #expect(spec.y == p.y, "\(name) field y")
      #expect(spec.halign == p.halign, "\(name) field halign")
      #expect(spec.valign == p.valign, "\(name) field valign")
      #expect(spec.textAttribute === StdAttr.label, "\(name) edits the wrong attribute")
      #expect(spec.fontAttribute === StdAttr.labelFont, "\(name) uses the wrong font attribute")
    }
  }
}
