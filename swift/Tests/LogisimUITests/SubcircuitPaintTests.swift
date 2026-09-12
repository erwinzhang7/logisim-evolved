// SubcircuitPaintTests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// DOES A SUBCIRCUIT PLACEMENT DRAW?
//
// Measured before the fix, on a parent circuit holding exactly one placement:
//
//     PROBE parent components: 1
//     PROBE painted: 0
//     PROBE primitives: 0
//     PROBE contentBounds: (230.0, 290.0, 70.0, 60.0)
//     PROBE factory is InstancePaintable: false
//     PROBE comp is ComponentPaintable: false
//
// The bounds were already right, `offsetBounds` had been fixed a milestone earlier, and
// nothing drew. `CircuitRenderer.render` dispatches on two casts and a subcircuit matched
// neither, so every hierarchical schematic showed blank space where its blocks were.
//
// EVERY assertion here is on PRIMITIVE COUNTS out of `SceneBuilder`, or on inked pixels out of
// the rasteriser. `painted` alone cannot distinguish a working painter from a stub, it went to
// 1 the instant the conformance existed, while the scene was still empty, so it is asserted
// alongside the primitive count and never instead of it. The rasteriser check is the second
// half of that argument: a scene full of primitives that all draw in the background colour is
// still a blank canvas.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import CoreGraphics
import Foundation
import LogisimDraw
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimRenderBackend
import LogisimStd
import Testing

@testable import LogisimUI

// MARK: - Fixtures

/// A circuit with the named pins, in the evolution default appearance.
@MainActor
private func innerCircuit(
  name: String = "inner",
  inputs: [String] = ["a", "b"],
  outputs: [String] = ["y"],
  fixedSize: Bool = false,
  appearance: AttributeOption = CircuitAttributes.appearEvolution
) throws -> Circuit {
  StdLibraries.registerAll()
  let circuit = try Circuit(name: name, defaultAppearance: appearance)
  try circuit.staticAttributes.setValue(CircuitAttributes.appearance, appearance)
  try circuit.staticAttributes.setValue(
    CircuitAttributes.namedCircuitBoxFixedSize, fixedSize)

  var y = 100
  for label in inputs {
    let attrs = Pin.factory.createAttributeSet()
    try attrs.setValue(Pin.attrType, Pin.input)
    try attrs.setValue(StdAttr.label, label)
    try circuit.mutatorAdd(
      try Pin.factory.createComponent(
        location: Location.create(100, y, hasToSnap: true), attributes: attrs))
    y += 40
  }
  y = 100
  for label in outputs {
    let attrs = Pin.factory.createAttributeSet()
    try attrs.setValue(Pin.attrType, Pin.output)
    try attrs.setValue(StdAttr.label, label)
    try circuit.mutatorAdd(
      try Pin.factory.createComponent(
        location: Location.create(300, y, hasToSnap: true), attributes: attrs))
    y += 40
  }
  return circuit
}

/// A parent circuit holding one placement of `inner`, plus the placement itself.
@MainActor
private func parentWithPlacement(
  _ inner: Circuit,
  at location: Location = Location.create(300, 300, hasToSnap: true),
  configure: (any AttributeSet) throws -> Void = { _ in }
) throws -> (parent: Circuit, placement: any Component) {
  let parent = try Circuit(name: "parent")
  let factory = inner.subcircuitFactory
  let attributes = factory.createAttributeSet()
  try configure(attributes)
  let placement = try factory.createComponent(location: location, attributes: attributes)
  try parent.mutatorAdd(placement)
  return (parent, placement)
}

@MainActor
private func build(_ circuit: Circuit) -> CircuitSceneBuild {
  CircuitSceneSource.build(circuit: circuit, appearance: CanvasAppearance())
}

private func drawnStrings(_ scene: RenderScene) -> [String] {
  scene.texts.map(\.string)
}

/// Pixels that differ from the canvas background; the same measure `CanvasDrawsTests` uses.
private func inkedPixelCount(_ bitmap: SceneBitmap, background: LogisimRender.RGBA) -> Int {
  var count = 0
  for y in 0..<bitmap.height {
    for x in 0..<bitmap.width {
      let p = bitmap.pixel(x: x, y: y)
      if p.r != background.r || p.g != background.g || p.b != background.b { count += 1 }
    }
  }
  return count
}

// MARK: - The regression

@Suite("Subcircuit paint — the placement draws")
struct SubcircuitPaintDrawsTests {

  /// The measurement this whole file exists for.
  @Test("a subcircuit placement emits primitives")
  @MainActor
  func placementEmitsPrimitives() throws {
    let inner = try innerCircuit()
    let (parent, _) = try parentWithPlacement(inner)
    let scene = build(parent)

    #expect(scene.paintedComponentCount == 1, "CircuitRenderer dispatched no painter")
    // Was 0. The box alone is two rectangles; with three pin stubs, three labels, a title and
    // three port markers there is no plausible correct value near zero.
    #expect(
      scene.scene.primitives.count >= 10,
      "placement painted but emitted \(scene.scene.primitives.count) primitives")
  }

  /// The dispatch arm, named. `CircuitRenderer` tries `ComponentPaintable` first and
  /// `InstancePaintable` second; a subcircuit must take the second.
  @Test("the factory takes the InstancePaintable arm")
  @MainActor
  func factoryIsInstancePaintable() throws {
    let inner = try innerCircuit()
    #expect(inner.subcircuitFactory as? any InstancePaintable != nil)
  }

  /// The default box carries the circuit's name in its title bar and every pin's label beside
  /// its stub. Four text runs for a two-in/one-out circuit.
  @Test("the default box draws its title and every pin label")
  @MainActor
  func defaultBoxDrawsTitleAndPinLabels() throws {
    let inner = try innerCircuit(name: "alu", inputs: ["a", "b"], outputs: ["y"])
    let (parent, _) = try parentWithPlacement(inner)
    let scene = build(parent)

    #expect(Set(drawnStrings(scene.scene)) == ["alu", "a", "b", "y"])
  }

  /// A pin with no label contributes no text run; upstream's `EditableLabel.paint` on an empty
  /// string draws nothing, and this is the one case where a *missing* primitive is correct.
  @Test("an unlabelled pin draws a stub and no label")
  @MainActor
  func unlabelledPinDrawsNoText() throws {
    let inner = try innerCircuit(name: "n", inputs: [""], outputs: [""])
    let (parent, _) = try parentWithPlacement(inner)
    let scene = build(parent)

    #expect(drawnStrings(scene.scene) == ["n"], "only the title should be drawn")
    #expect(scene.scene.primitives.count > 1, "the box and stubs must still be there")
  }

  /// A circuit with no pins at all still draws a box; upstream's `height` has a
  /// `10 + thight` arm precisely so the degenerate case is a real rectangle.
  @Test("a pinless circuit still draws its box")
  @MainActor
  func pinlessCircuitDrawsBox() throws {
    let inner = try innerCircuit(name: "empty", inputs: [], outputs: [])
    let (parent, _) = try parentWithPlacement(inner)
    let scene = build(parent)

    #expect(scene.paintedComponentCount == 1)
    #expect(scene.scene.primitives.count >= 3, "outline + title bar + title")
    #expect(drawnStrings(scene.scene) == ["empty"])
  }

  /// Two placements of the same circuit are two independent drawings, not one shared one.
  @Test("two placements draw twice, at different places")
  @MainActor
  func twoPlacementsDrawIndependently() throws {
    let inner = try innerCircuit()
    let parent = try Circuit(name: "parent")
    let factory = inner.subcircuitFactory
    for x in [200, 500] {
      try parent.mutatorAdd(
        try factory.createComponent(
          location: Location.create(x, 300, hasToSnap: true),
          attributes: factory.createAttributeSet()))
    }

    let scene = build(parent)
    #expect(scene.paintedComponentCount == 2)
    #expect(drawnStrings(scene.scene).filter { $0 == "inner" }.count == 2)
  }
}

// MARK: - Geometry

@Suite("Subcircuit paint — the ink lands inside the component's own bounds")
struct SubcircuitPaintGeometryTests {

  /// **The failure this catches is the one a primitive count cannot.** If the painter forgot
  /// `paintBase`'s `g.translate(loc)`, or applied the anchor offset twice, every subcircuit in a
  /// schematic would stack near the origin: a scene full of primitives, none of them where the
  /// component is. So: the scene's content bounds must agree with the component's bounds.
  @Test("the drawing lands on the component, not at the origin")
  @MainActor
  func drawingIsTranslatedToTheComponent() throws {
    let inner = try innerCircuit()
    let (parent, placement) = try parentWithPlacement(
      inner, at: Location.create(400, 500, hasToSnap: true))
    let scene = build(parent)

    let bounds = placement.bounds
    let content = scene.contentBounds
    #expect(!content.isNull)
    // The pin *labels* legitimately overhang the box (upstream draws them 15px outside the
    // stub), so the test is containment of the box's centre and rough agreement on origin,
    // not equality.
    #expect(
      abs(Int(content.minX) - bounds.x) < 60,
      "content x \(content.minX) is nowhere near the component's \(bounds.x)")
    #expect(
      abs(Int(content.minY) - bounds.y) < 60,
      "content y \(content.minY) is nowhere near the component's \(bounds.y)")
  }

  /// Rotating the placement must move the ink. `paintSubcircuit` rotates by
  /// `defaultFacing.toRadians() - facing.toRadians()`; drop that and a north-facing subcircuit
  /// draws its east-west box unchanged while its ends sit on the rotated ones.
  @Test("a rotated placement draws rotated")
  @MainActor
  func facingRotatesTheDrawing() throws {
    let inner = try innerCircuit()
    let (east, _) = try parentWithPlacement(inner) { attrs in
      try attrs.setValue(StdAttr.facing, .east)
    }
    let (north, _) = try parentWithPlacement(inner) { attrs in
      try attrs.setValue(StdAttr.facing, .north)
    }

    let eastScene = build(east)
    let northScene = build(north)
    #expect(eastScene.paintedComponentCount == 1)
    #expect(northScene.paintedComponentCount == 1)
    #expect(
      eastScene.contentBounds != northScene.contentBounds,
      "rotating the placement did not change what was drawn")
  }

  /// `configureLabel`, measured rather than eyeballed. `LABEL_LOCATION_ATTR == EAST` puts the
  /// instance label at `bds.x + bds.width + 2`, left-aligned; the default (north) puts it at
  /// `bds.y - 2`. Two different placements, and the label run must move with them.
  @Test("the instance label follows LABEL_LOCATION_ATTR")
  @MainActor
  func instanceLabelFollowsItsLocationAttribute() throws {
    let inner = try innerCircuit()

    func labelRun(_ location: Direction) throws -> TextRun {
      let (parent, _) = try parentWithPlacement(inner) { attrs in
        try attrs.setValue(StdAttr.label, "U1")
        try attrs.setValue(CircuitAttributes.labelLocationAttribute, location)
      }
      let scene = build(parent)
      guard let run = scene.scene.texts.first(where: { $0.string == "U1" }) else {
        Issue.record("the instance label 'U1' was not drawn at all for \(location)")
        throw CancellationError()
      }
      return run
    }

    let north = try labelRun(Direction.north)
    let east = try labelRun(Direction.east)
    let south = try labelRun(Direction.south)

    // EAST is to the right of NORTH's centred x; SOUTH is below NORTH's y.
    #expect(east.boxX > north.boxX, "east label x \(east.boxX) not right of north's \(north.boxX)")
    #expect(
      south.baselineY > north.baselineY,
      "south label y \(south.baselineY) not below north's \(north.baselineY)")
  }

  /// The circuit-wide `clabel` is a *separate* label from the placement's `StdAttr.LABEL`, and
  /// upstream draws both. Before this painter existed neither was drawn.
  @Test("the circuit label (clabel) draws, and is not the instance label")
  @MainActor
  func circuitLabelDraws() throws {
    let inner = try innerCircuit()
    try inner.staticAttributes.setValue(CircuitAttributes.circuitLabelAttribute, "CLK DIV")

    let (parent, _) = try parentWithPlacement(inner) { attrs in
      try attrs.setValue(StdAttr.label, "U7")
    }
    let scene = build(parent)
    let strings = drawnStrings(scene.scene)

    #expect(strings.contains("CLK DIV"), "the circuit label was not drawn: \(strings)")
    #expect(strings.contains("U7"), "the instance label was not drawn: \(strings)")
  }

  /// `drawCircuitLabel`'s escape handling. A `clabel` of `a\nb`, a literal backslash then `n`,
  /// which is what a `.circ` stores, is TWO drawn lines, not one run containing a backslash.
  @Test("a clabel with an escaped newline draws two runs")
  @MainActor
  func circuitLabelSplitsOnEscapedNewline() throws {
    let inner = try innerCircuit()
    try inner.staticAttributes.setValue(
      CircuitAttributes.circuitLabelAttribute, #"top\nbottom"#)

    let (parent, _) = try parentWithPlacement(inner)
    let strings = drawnStrings(build(parent).scene)

    #expect(strings.contains("top"), "\(strings)")
    #expect(strings.contains("bottom"), "\(strings)")
    #expect(!strings.contains(#"top\nbottom"#), "the escape was not interpreted")
  }

  /// And a doubled backslash collapses to one *without* splitting; upstream's `backs` flag.
  /// A `split(on: "\\n")` transcription passes the test above and fails this one.
  @Test("a clabel with an escaped backslash collapses and does not split")
  @MainActor
  func circuitLabelCollapsesEscapedBackslash() throws {
    let inner = try innerCircuit()
    try inner.staticAttributes.setValue(
      CircuitAttributes.circuitLabelAttribute, #"a\\nb"#)

    let (parent, _) = try parentWithPlacement(inner)
    let strings = drawnStrings(build(parent).scene)

    #expect(strings.contains(#"a\nb"#), "expected one collapsed run, got \(strings)")
  }
}

// MARK: - The drag preview

@Suite("Subcircuit paint — the ghost")
struct SubcircuitGhostTests {

  /// `paintGhost` is what a drag preview draws. Two things about it are pinned here, and the
  /// second is the one that would have shipped broken.
  ///
  /// 1. It draws at all: same primitive count as the real thing, since it is `paintBase` under
  ///    a 50% group.
  /// 2. **It draws at the ORIGIN, not at the ghost's location.** Upstream's
  ///    `InstanceFactory.drawGhost` already does `gfx.translate(x, y)` before calling
  ///    `paintGhost`, and `InstancePainter.getLocation()` returns `(0, 0)` when there is no
  ///    component (`InstancePainter.java:169-171`), so upstream's `paintBase` translate is a
  ///    no-op for a ghost. This port's `InstancePainter.location` deliberately returns the
  ///    ghost's real location instead, so without an explicit guard every drag preview would be
  ///    drawn at twice the cursor offset. A count-only test passes either way.
  @Test("a ghost draws, and draws at the origin rather than twice the offset")
  @MainActor
  func ghostDrawsAtTheOrigin() throws {
    let inner = try innerCircuit()
    let factory = try #require(inner.subcircuitFactory as? any InstancePaintable)
    let attributes = inner.subcircuitFactory.createAttributeSet()

    let builder = SceneBuilder(measurer: NominalTextMeasurer())
    let painter = InstancePainter(g: builder, context: StaticPaintContext(componentColor: .black))
    // `setFactory` cannot be used: it takes an `any InstanceFactory` and
    // `CircuitSubcircuitFactory` is not one; see the finding in
    // `docs/experiments/subcircuit-paint.md`. `setComponent(nil)` puts the painter in the same
    // ghost state (`isGhost` is `component == nil`), which is the condition `paintBase` reads.
    painter.setComponent(nil)
    factory.paintGhost(painter)
    let scene = builder.finish()

    #expect(scene.primitives.count > 0, "the ghost drew nothing")
    // Anchor-relative: the box's own frame. With an east port the anchor sits at the box's right
    // edge, so the drawing spans negative x and lands ON the origin: never a full box-width past
    // it, which is what a double translate would produce.
    let minX = scene.primitives.map { Int($0.bounds.minX) }.min() ?? 0
    let maxX = scene.primitives.map { Int($0.bounds.maxX) }.max() ?? 0
    #expect(
      minX < 0 && maxX <= 40,
      "ghost spans x \(minX)...\(maxX) — that is not the offset frame, it looks translated twice")
  }

  /// **The ghost is written and the canvas cannot reach it.** Recorded as a measurement rather
  /// than a claim, because it is a finding handed back rather than fixed here.
  ///
  /// `ToolOverlayScene.drawFactoryGhost` and `drawComponentGhost` both guard on
  /// `factory as? any InstanceFactory` before they will paint anything, and fall back to
  /// `strokeOffsetBounds`, a bare outline, when the cast fails. `CircuitSubcircuitFactory`
  /// descends from `AbstractComponentFactory` in `LogisimFile` and is not an `InstanceFactory`,
  /// so dragging a subcircuit shows an empty rectangle where upstream shows the symbol
  /// (upstream's `SubcircuitFactory extends InstanceFactory`, so its ghost is the real thing).
  ///
  /// This assertion is the root cause, pinned. When `ToolOverlayScene` is widened to guard on
  /// `InstancePaintable` instead, which is all `paint` actually needs, this test will start
  /// failing, and that is the correct signal to delete it.
  @Test("the canvas ghost path cannot reach a subcircuit — the cast it guards on fails")
  @MainActor
  func ghostPathCannotReachASubcircuit() throws {
    let inner = try innerCircuit()
    let factory = inner.subcircuitFactory

    #expect(
      factory as? any InstancePaintable != nil,
      "the ghost implementation exists")
    #expect(
      factory as? any InstanceFactory == nil,
      "ToolOverlayScene's guard now passes — widen it and delete this test")
  }
}

// MARK: - Appearance modes

@Suite("Subcircuit paint — default vs custom appearance")
struct SubcircuitAppearanceModeTests {

  /// `isDefaultAppearance()` is `!= APPEAR_CUSTOM`, so a `classic`-styled circuit takes the
  /// DEFAULT arm. That polarity is easy to invert; inverting it would make classic circuits
  /// draw whatever stale shapes their `<appear>` happened to hold.
  @Test("a classic-styled circuit takes the default arm, not the custom one")
  @MainActor
  func classicStyleIsStillADefaultAppearance() throws {
    let inner = try innerCircuit(appearance: CircuitAttributes.appearClassic)
    let (parent, _) = try parentWithPlacement(inner)
    let scene = build(parent)

    #expect(scene.paintedComponentCount == 1)
    #expect(scene.scene.primitives.count >= 3)
    #expect(drawnStrings(scene.scene).contains("inner"))
  }

  /// The custom arm, driven end to end through the real reader: a `.circ` whose `<appear>`
  /// holds drawn shapes must paint THOSE, not the default box.
  ///
  /// The discriminator is the title: the default box always draws the circuit's name, and a
  /// custom appearance built from a rectangle and a port draws no text at all. So "did the
  /// custom arm run" is answerable without pixel comparison.
  @Test("a custom <appear> paints its own shapes instead of the default box")
  @MainActor
  func customAppearancePaintsItsOwnShapes() throws {
    StdLibraries.registerAll()

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("subcircuit-paint-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("custom.circ")
    try customAppearanceCirc.write(to: url, atomically: true, encoding: .utf8)

    let file = try Loader().openLogisimFile(url)
    let parent = try #require(file.circuits.first { $0.name == "main" })
    let child = try #require(file.circuits.first { $0.name == "blk" })

    #expect(
      child.staticAttributes[CircuitAttributes.appearance] == CircuitAttributes.appearCustom,
      "the fixture did not load as a custom appearance")

    let scene = build(parent)
    #expect(scene.paintedComponentCount >= 1)
    #expect(scene.scene.primitives.count > 0, "the custom appearance drew nothing")
    // The custom `<appear>` below holds a rectangle and one circ-port and no `<text>`, so the
    // absence of the circuit's name is what proves the default box did NOT run.
    #expect(
      !drawnStrings(scene.scene).contains("blk"),
      "the default box drew its title — the custom arm did not run")
  }

  /// A circuit marked `custom` whose `<appear>` yielded no shapes at all must still draw
  /// something. Upstream seeds the custom list with `DefaultCustomAppearance.build`, so it is
  /// never empty; the port falls back to the default box, which is a visible symbol either way.
  /// The failure mode being pinned is "custom means blank".
  @Test("a custom appearance with no shapes falls back to a visible box")
  @MainActor
  func emptyCustomAppearanceStillDraws() throws {
    let inner = try innerCircuit(appearance: CircuitAttributes.appearCustom)
    let (parent, _) = try parentWithPlacement(inner)
    let scene = build(parent)

    #expect(scene.paintedComponentCount == 1)
    #expect(scene.scene.primitives.count >= 3, "a custom-marked circuit rendered blank")
  }
}

// MARK: - All the way to pixels

@Suite("Subcircuit paint — the rasterised placement is not blank")
struct SubcircuitPaintRasterTests {

  /// A scene whose primitives all draw in the background colour is still a blank canvas, so the
  /// primitive count alone is not the end of the argument. This goes to the bitmap.
  @Test("a placement rasterises to real ink")
  @MainActor
  func placementRasterisesToInk() throws {
    let inner = try innerCircuit()
    let (parent, _) = try parentWithPlacement(inner)

    var appearance = CanvasAppearance()
    appearance.antialiasing = false
    let scene = CircuitSceneSource.build(circuit: parent, appearance: appearance)

    let world = scene.contentBounds.insetBy(dx: -20, dy: -20)
    let raster = try #require(
      CircuitSceneRasterizer.bitmap(
        build: scene, worldRect: world, scale: 2, appearance: appearance))

    #expect(raster.stats.primitivesDrawn > 0)
    let inked = inkedPixelCount(
      raster.bitmap, background: appearance.palette[.canvasBackground].sceneRGBA)
    #expect(inked > 200, "the subcircuit rasterised blank: \(inked) inked pixels")
  }

  /// The title bar is a FILLED black rectangle and the title is drawn on it in WHITE. If
  /// `setForFill`/`setForStroke` were transcribed wrongly, the easy mistake is treating a
  /// missing `PAINT_TYPE` as stroke-only, the bar would be an empty outline and the white
  /// title would land on the background, invisible.
  ///
  /// Measured as: the raster contains near-black pixels (the filled bar) AND pixels lighter
  /// than the background is dark, i.e. white glyphs sitting inside that bar.
  @Test("the title bar fills, so the white title is visible")
  @MainActor
  func titleBarIsFilled() throws {
    let inner = try innerCircuit(name: "WIDE NAME HERE")
    let (parent, _) = try parentWithPlacement(inner)

    var appearance = CanvasAppearance()
    appearance.antialiasing = false
    let scene = CircuitSceneSource.build(circuit: parent, appearance: appearance)
    let world = scene.contentBounds.insetBy(dx: -20, dy: -20)
    let raster = try #require(
      CircuitSceneRasterizer.bitmap(
        build: scene, worldRect: world, scale: 2, appearance: appearance))

    var black = 0
    var white = 0
    for y in 0..<raster.bitmap.height {
      for x in 0..<raster.bitmap.width {
        let p = raster.bitmap.pixel(x: x, y: y)
        if p.r < 40 && p.g < 40 && p.b < 40 { black += 1 }
        if p.r > 215 && p.g > 215 && p.b > 215 { white += 1 }
      }
    }
    // The filled bar alone is (width - 20) x 20 world units at scale 2, i.e. > 1,000 px.
    #expect(black > 500, "the title bar did not fill: only \(black) dark pixels")
    #expect(white > 0, "no light pixels at all — the raster is not a filled bar with text on it")
  }
}

// MARK: - The custom-appearance fixture

/// A minimal two-circuit `.circ` where `blk` carries an `APPEAR_CUSTOM` `<appear>` holding one
/// drawn rectangle plus the anchor and one port. Written in 4.1.0's own spelling
/// (`circ-port dir=/pin=/x=/y=`), which is what `CircuitAppearanceSvgLoader` reads.
private let customAppearanceCirc = """
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<project source="4.1.0" version="1.0">
  <lib desc="#Wiring" name="0"/>
  <lib desc="#Base" name="1"/>
  <main name="main"/>
  <circuit name="main">
    <a name="circuit" val="main"/>
    <comp lib="" loc="(300,300)" name="blk"/>
  </circuit>
  <circuit name="blk">
    <a name="circuit" val="blk"/>
    <a name="appearance" val="custom"/>
    <appear>
      <rect fill="none" height="40" stroke="#000000" stroke-width="2" width="60" x="50" y="50"/>
      <circ-anchor facing="east" height="6" width="6" x="107" y="57"/>
      <circ-port dir="in" pin="120,100" x="47" y="57"/>
    </appear>
    <comp lib="0" loc="(120,100)" name="Pin">
      <a name="label" val="in0"/>
    </comp>
  </circuit>
</project>
"""
