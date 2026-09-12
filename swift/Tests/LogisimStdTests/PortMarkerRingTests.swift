// LogisimStdTests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE PORT MARKER IS A RING, AND THE RULE FOR *WHEN* IT APPEARS DID NOT MOVE
//
// Asked for from real use: "those joints between wire and whatnot, id make it white donut
// instead of black dot. white ring so its clear its not the wire itself." That is a styling
// change, and the trap in a styling change is that it is easy to alter *when* a marker appears
// while claiming only to have altered *how* it looks: a fidelity regression hiding inside a
// cosmetic one. So this suite pins three separate things:
//
//   1. SHAPE; the marker is now an annulus (a filled hole plus a stroked rim) where 4.1.0
//      filled a solid disc. `javap -c com.cburch.logisim.comp.ComponentDrawContext` against
//      /Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar shows
//      `drawPinMarker` as one `g.fillOval(x - offs, y - offs, rad, rad)` and nothing else.
//
//   2. COLOUR; the rim still carries whatever colour the caller left on the builder. That is
//      the part that could have destroyed information: `ComponentDrawContext.drawPin` sets that
//      colour from `Value.getColor()` when `getShowState()`, so a flat white ring would have
//      erased the high/low/error/unknown signal at every port in the schematic. Only the
//      interior is knocked out.
//
//   3. INCIDENCE: one marker per port, centred exactly on the port, for a component with N
//      ends. Unchanged, because no call site moved; asserted anyway, because "unchanged by
//      construction" is exactly the claim that stops being true the next time someone edits
//      this.
//
// Every assertion here reads the emitted primitives, not the drawing code, so deleting the ring
// and putting the disc back reddens this file rather than passing it.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import Testing

@testable import LogisimStd

// MARK: - Harness

/// Every primitive a fresh builder emits while `body` draws.
private func emitted(_ body: (SceneBuilder) -> Void) -> RenderScene {
  let builder = SceneBuilder(measurer: NominalTextMeasurer())
  body(builder)
  return builder.finish()
}

/// `(kind, style)` for each primitive, in draw order.
private func shapes(_ scene: RenderScene) -> [String] {
  scene.primitives.map { "\($0.kind)/\($0.style)" }
}

/// The `(x, y, width, height)` box a boxed primitive was emitted with.
private func box(_ primitive: ScenePrimitive) -> (x: Int, y: Int, w: Int, h: Int) {
  (Int(primitive.a), Int(primitive.b), Int(primitive.c), Int(primitive.d))
}

/// The two primitives one marker is made of.
///
/// `#require`s the count rather than subscripting, and that is not fussiness: the first red
/// probe run for this file put upstream's single `fillOval` back, and the bare `primitives[1]`
/// these tests used to do trapped on index-out-of-range and took the whole test *process* down
/// , which hid four of the failures the probe was supposed to demonstrate. A probe you cannot
/// read is not a probe.
private func ring(_ scene: RenderScene) throws -> (hole: ScenePrimitive, rim: ScenePrimitive) {
  try #require(scene.primitives.count == 2, "expected one ring, got \(shapes(scene))")
  return (scene.primitives[0], scene.primitives[1])
}

/// A component with real `ends`, built without touching the process-global library registry.
private func ttlChip() throws -> any Component {
  let factory = Ttl7400()
  return try factory.createComponent(
    location: Location.create(100, 100, hasToSnap: false),
    attributes: factory.createAttributeSet())
}

// MARK: - Shape

@Suite("Port marker ring — shape")
struct PortMarkerRingShapeTests {

  /// 4.1.0 emits exactly one primitive here and it is a fill. This port emits two, and only one
  /// of them is a fill; the hole. If the ring is ever reverted to a disc, this is the assertion
  /// that says so.
  @Test("the marker is a filled hole plus a stroked rim, not a single filled disc")
  func markerIsAnAnnulus() {
    let scene = emitted { $0.drawPinMarker(0, 0) }
    #expect(shapes(scene) == ["oval/fill", "oval/stroke"], "was \(shapes(scene))")
  }

  /// The hole and the rim have to be the same circle or the "donut" is an eccentric smear.
  @Test("hole and rim share one box")
  func holeAndRimShareOneBox() throws {
    let (hole, rim) = try ring(emitted { $0.drawPinMarker(40, 70) })
    #expect(box(hole) == box(rim))
  }

  /// The rim is stroked at width 1, the same pen this renderer strokes a wire with, so the
  /// ring reads as a *circle* six times the wire's thickness across rather than as a fat blob.
  @Test("the rim is a hairline, so the ring reads as an outline")
  func rimIsAHairline() throws {
    #expect(try ring(emitted { $0.drawPinMarker(0, 0) }).rim.pen.width == 1)
  }

  /// Upstream's box is `(x - offs, y - offs, rad, rad)` for `(rad, offs)` of `(4,2)`, `(6,3)`,
  /// `(8,4)`, `(10,5)`. Ours grows that by one unit on every side, which is the *only* way to
  /// gain visible ring thickness while keeping the box integer-centred on the port for all four
  /// sizes. Both halves are asserted: the growth, and the centring.
  @Test(
    "the ring is upstream's box grown by one unit a side, still centred on the port",
    arguments: PinAppearance.allCases)
  func ringGeometry(_ appearance: PinAppearance) throws {
    let (radius, offset) = appearance.marker
    let context = StaticPaintContext(pinAppearance: appearance)
    let builder = SceneBuilder(measurer: NominalTextMeasurer())
    InstancePainter(g: builder, context: context).drawPinMarker(60, 90)
    let scene = builder.finish()

    let rim = box(try ring(scene).rim)
    #expect(rim.w == radius + 2 && rim.h == radius + 2, "size was \(rim.w)x\(rim.h)")
    #expect(rim.x == 60 - (offset + 1) && rim.y == 90 - (offset + 1))
    // Integer-centred: the box's midpoint is the port itself, not half a unit off it.
    #expect(rim.x * 2 + rim.w == 120 && rim.y * 2 + rim.h == 180)
  }

  /// ── A CONSEQUENCE THAT IS PINNED RATHER THAN QUIETLY ACCEPTED ────────────────────────────
  ///
  /// This started life as "no appearance grows the marker past the 10-unit grid pitch" and it
  /// went red on `dot-bigger`; the growth makes it 12 across on a 10-unit pitch, so adjacent
  /// port rings overlap. That is a real consequence and it is kept, not clamped, for two
  /// reasons.
  ///
  /// First, clamping to 10 would make `dot-big` and `dot-bigger` render identically, i.e. it
  /// would turn a live `AppPreferences.PinAppearance` setting into a no-op; the precise defect
  /// class three separate audits have been removing from this app. Growth has to be even to stay
  /// integer-centred, so +2 or nothing; there is no clamp that both fits the pitch and keeps the
  /// four sizes distinct.
  ///
  /// Second, upstream is already at the limit there: 4.1.0's `dot-bigger` disc is exactly 10
  /// across, so adjacent markers already touch and a row of pins already reads as a solid bar.
  /// Two *rings* that cross still read as two circles, which is if anything the better of the
  /// two failures.
  ///
  /// So the rule is uniform +2, and the assertion records exactly where that lands.
  @Test("growth is uniform, and only dot-bigger exceeds the grid pitch",
    arguments: PinAppearance.allCases)
  func ringGrowthAgainstTheGridPitch(_ appearance: PinAppearance) {
    let outer = appearance.marker.radius + 2
    let fits = outer <= 10
    #expect(fits == (appearance != .dotBigger), "\(appearance) ring is \(outer) units across")
  }
}

// MARK: - Colour

@Suite("Port marker ring — colour")
struct PortMarkerRingColourTests {

  /// The load-bearing one. `drawPort` colours the marker from the live value when `showState`;
  /// if the ring had been flattened to a fixed white, every port in a running simulation would
  /// have stopped reporting its value. The rim must still be the value's palette entry.
  @Test("the rim keeps the live value colour")
  func rimKeepsValueColour() throws {
    let component = try ttlChip()
    let context = ValuePaintContext(value: Value.trueValue)
    let builder = SceneBuilder(measurer: NominalTextMeasurer())
    let painter = InstancePainter(g: builder, context: context)
    painter.setComponent(component)
    painter.drawPort(0)
    let scene = builder.finish()

    let rim = try ring(scene).rim
    #expect(rim.style == .stroke)
    #expect(
      scene.colorIndex(of: rim.color) == PaletteIndex(Value.trueValue.paletteIndex),
      "rim resolved to \(scene.colorIndex(of: rim.color))")
  }

  /// ...and the hole must NOT, or the marker becomes a value-coloured disc again by another
  /// route. The hole is ground, the rim is ink.
  @Test("the hole is ground, not the value colour")
  func holeIsNotTheValueColour() throws {
    let component = try ttlChip()
    let context = ValuePaintContext(value: Value.trueValue)
    let builder = SceneBuilder(measurer: NominalTextMeasurer())
    let painter = InstancePainter(g: builder, context: context)
    painter.setComponent(component)
    painter.drawPort(0)
    let scene = builder.finish()

    let hole = try ring(scene).hole
    #expect(hole.style == .fill)
    #expect(scene.colorIndex(of: hole.color) != PaletteIndex(Value.trueValue.paletteIndex))
    #expect(scene.color(of: hole.color) == .white)
  }

  /// `LogisimStd` cannot see `CircuitPalette`, so it infers the canvas ground from the ink it
  /// *can* see. Light canvas (near-black ink) → white hole; dark canvas (near-white ink) → black
  /// hole. Both are checked, because a rule that only works on one theme is the failure this
  /// derivation exists to avoid.
  @Test("the hole is the opposite of the ink")
  func holeOpposesInk() {
    #expect(PortMarkerRing.holeColor(ink: .black) == .white)
    #expect(PortMarkerRing.holeColor(ink: .white) == .black)
    // The two real palettes: `CircuitPalette.light`'s componentStroke, and `.dark`'s.
    #expect(PortMarkerRing.holeColor(ink: .rgb(0x1C_1C1E)) == .white)
    #expect(PortMarkerRing.holeColor(ink: .rgb(0xE4_E4E7)) == .black)
  }

  /// A `.palette` ink is a simulation colour that is re-themed *after* the scene is sealed, so
  /// its luminance is not knowable here. It falls back rather than guessing.
  @Test("a re-themable ink falls back to white rather than guessing")
  func palettedInkFallsBack() {
    #expect(PortMarkerRing.holeColor(ink: .palette(.trueValue)) == .white)
  }

  /// The derivation is a default, not a mandate: a context that knows the real canvas ground
  /// must be able to say so. This is the hook the canvas should eventually use.
  @Test("an explicit hole colour wins over the derivation")
  func explicitHoleColourWins() throws {
    let inferred = StaticPaintContext(componentColor: .black)
    #expect(inferred.markerHoleColor == .white)
    let explicit = StaticPaintContext(componentColor: .black)
    explicit.markerHoleColorOverride = .rgb(0x12_3456)
    #expect(explicit.markerHoleColor == .rgb(0x12_3456))

    let scene = emitted { builder in
      InstancePainter(g: builder, context: explicit).drawPinMarker(0, 0)
    }
    #expect(scene.color(of: try ring(scene).hole.color) == RGBA(javaRGB: 0x12_3456))
  }
}

// MARK: - Incidence

@Suite("Port marker ring — incidence")
struct PortMarkerRingIncidenceTests {

  /// One ring per port and not one more. Two primitives per marker is the ring's own arithmetic;
  /// what this pins is the multiplier: `ends.count`, unchanged from the disc.
  @Test("one marker per port, and nothing else")
  func oneMarkerPerPort() throws {
    let component = try ttlChip()
    let builder = SceneBuilder(measurer: NominalTextMeasurer())
    let painter = InstancePainter(g: builder, context: StaticPaintContext())
    painter.setComponent(component)
    painter.drawPorts()
    let scene = builder.finish()

    // 12, not 14: the 7400 package has 14 legs but Vcc and GND are not circuit `ends`, so the
    // count is spelled out rather than inferred; an `ends.count * 2` assertion alone would pass
    // just as happily on a component that lost all its ports.
    #expect(component.ends.count == 12, "Ttl7400 has 12 signal pins; got \(component.ends.count)")
    #expect(scene.primitives.count == component.ends.count * 2)
    #expect(scene.primitives.allSatisfy { $0.kind == .oval })
  }

  /// Each ring is centred on the port it belongs to. The disc was; a ring that drifted by the
  /// growth offset would be a real regression and would look almost right.
  @Test("every marker is centred on its own port")
  func markersSitOnTheirPorts() throws {
    let component = try ttlChip()
    let builder = SceneBuilder(measurer: NominalTextMeasurer())
    let painter = InstancePainter(g: builder, context: StaticPaintContext())
    painter.setComponent(component)
    painter.drawPorts()
    let scene = builder.finish()

    var centres: [String] = []
    for primitive in scene.primitives where primitive.style == .stroke {
      let b = box(primitive)
      #expect(b.w % 2 == 0 && b.h % 2 == 0, "odd box cannot be integer-centred: \(b)")
      centres.append("\(b.x + b.w / 2),\(b.y + b.h / 2)")
    }
    let ports = component.ends.map { "\($0.location.x),\($0.location.y)" }
    #expect(Set(centres) == Set(ports), "centres \(Set(centres)) vs ports \(Set(ports))")
  }
}

// MARK: - Support

/// A `PaintContext` with the simulator "running": every port reads one fixed value, which is
/// what makes the value-colour assertions above reachable at all; `StaticPaintContext` has
/// `showState == false` and would take the `componentColor` branch of `drawPort` instead.
private final class ValuePaintContext: PaintContext {
  let value: Value

  init(value: Value) { self.value = value }

  var showState: Bool { true }
  var shouldDrawColor: Bool { true }
  var isPrintView: Bool { false }
  var gateShape: GateShape { .shaped }
  var pinAppearance: PinAppearance { .dotSmall }
  var componentColor: SceneColor { .black }
  var tickCount: Int { 0 }
  var isCircuitRoot: Bool { true }
  var projectOptions: any AttributeSet { StaticPaintContext().projectOptions }

  func value(at location: Location) -> Value { value }
  func isConnected(_ location: Location, excluding component: (any Component)?) -> Bool { false }
  func data(for component: any Component) -> (any InstanceData)? { nil }
  func setData(_ data: (any InstanceData)?, for component: any Component) {}
}
