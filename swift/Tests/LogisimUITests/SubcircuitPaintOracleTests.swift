// SubcircuitPaintOracleTests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE DIFFERENTIAL CHECK: every drawn shape, against the shipped 4.1.0 jar
//
// "It rasterises to ink" proves the canvas is not blank. It does not prove the box is the box
// upstream draws. So the numbers below are not derived from the port and they are not eyeballed
// off a screenshot; they were **dumped out of the 4.1.0 jar**, from
// `circuit.getAppearance().getObjectsFromBottom()` with every location made relative to the
// anchor, which is precisely the list and the frame `CircuitAppearance.paintSubcircuit` walks.
//
// The fixture is `sample_block_2345678`, hand-authored here so the suite runs with no corpus.
//
// It began as a real circuit from the corpus, reproduced pin for pin. That is not something to
// publish: the corpus is coursework, and a lab block rebuilt with its own labels and geometry is
// the exercise. The fixture was rebuilt neutrally, and the substitution was chosen so that **not
// one coordinate below changed**: the recorded geometry depends on the number of ports, their
// widths, their vertical order, and whether a port is a clock, never on what the labels say.
//
// The one label that is not free is the clock. `PinAttributes.isClock` is a case-insensitive
// substring test for "clk" or "clock" on the *label*, so a port named anything else loses its
// triangle and shifts its text 8px left. It is named `clk` for that reason and not for tidiness.
//
// The dump below is the jar's, with the label strings replaced. Every number in it was
// re-verified against the rebuilt circuit.
//
//     CIRCUIT sample_block_2345678 default=true facing=east offsetBounds=(-220,-11,221,102) anchor=(270,60)
//       Rectangle box=(-220,-2,10,4)   paint=fill   stroke=1 fill=Color[0,0,0]
//       Text text="data"   at=(-205,4)   halign=2 valign=10 fill=Color[64,64,64]  font=Courier 10 Pitch plain 12
//       Rectangle box=(-220,19,10,3)   paint=fill   stroke=1 fill=Color[0,0,0]
//       Text text="sel1" at=(-205,24)  halign=2 valign=10 fill=Color[64,64,64]
//       Rectangle box=(-220,39,10,3)   paint=fill   stroke=1 fill=Color[0,0,0]
//       Text text="sel0" at=(-205,44)  halign=2 valign=10 fill=Color[64,64,64]
//       Rectangle box=(-220,59,10,3)   paint=fill   stroke=1 fill=Color[0,0,0]
//       Poly polyline pts=(-209,56)(-202,60)(-209,64) paint=stroke stroke=2
//       Text text="clk"   at=(-197,64)  halign=2 valign=10 fill=Color[64,64,64]
//       Rectangle box=(-10,-1,10,3)    paint=fill   stroke=1 fill=Color[0,0,0]
//       Text text="out"  at=(-15,4)    halign=4 valign=10 fill=Color[64,64,64]
//       Rectangle box=(-210,70,200,20) paint=fill   stroke=1 fill=Color[0,0,0]
//       Rectangle box=(-211,-11,202,102) paint=stroke stroke=2
//       Text text="sample_block_2345678" at=(-110,84) halign=0 valign=10 fill=Color[255,255,255] font=... bold 14
//
// Two of those lines need reading rather than copying, and both are recorded here because a
// future reader will otherwise "fix" the test to match them:
//
//   * **The outline's reported box is stroke-EXPANDED.** `Rectangle.getBounds()` inflates by half
//     the pen, so a stroke-2 rectangle at `(-210,-10,200,100)` reports `(-211,-11,202,102)`. The
//     *drawn* rectangle, `new Rectangle(rx + 10, ry, width - 20, height)`, is the un-expanded
//     one, and that is what a `drawRect` primitive carries.
//   * **`getOffsetBounds()` is the union of every object including that halo and the port
//     elements**, which is why it reads `(-220,-11,221,102)` while the *build* box this port
//     computes is `(-220,-10,220,100)`. `CircuitSubcircuitFactory.swift`'s own header already
//     documents that ≤2 px difference. It does not move a single shape: every coordinate below
//     is derived from `rx`/`ry`/`width`/`height`, which the two agree on exactly.
//
// The bridge that produced the dump is `docs/experiments/subcircuit-paint.md`; it is a ~70-line
// Java main against the shipped jar, kept out of `tools/` because that directory was not this
// work's to add to.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimStd
import Testing

@testable import LogisimUI

// MARK: - The fixture

/// The fixture, placed at the origin so that scene coordinates and the jar's anchor-relative
/// coordinates are the same numbers.
@MainActor
private func sampleBlockPlacement() throws -> (build: CircuitSceneBuild, inner: Circuit, parent: Circuit) {
  StdLibraries.registerAll()

  let inner = try Circuit(name: "sample_block_2345678", defaultAppearance: CircuitAttributes.appearEvolution)
  try inner.staticAttributes.setValue(
    CircuitAttributes.appearance, CircuitAttributes.appearEvolution)
  // The source file leaves the attribute at its default, which `isNamedBoxShapedFixedSize()`
  // reads as `true`; that is what makes `textWidth` the fixed `25 * 8` and the box 220 wide.
  // Setting it explicitly rather than relying on the default is the point: if the port's default
  // ever flipped, this test would catch it as a 50 px width change rather than silently passing.
  try inner.staticAttributes.setValue(CircuitAttributes.namedCircuitBoxFixedSize, true)

  func pin(_ label: String, _ type: AttributeOption, width: Int, y: Int, x: Int) throws {
    let attrs = Pin.factory.createAttributeSet()
    try attrs.setValue(Pin.attrType, type)
    try attrs.setValue(StdAttr.label, label)
    try attrs.setValue(StdAttr.width, try BitWidth.create(width))
    try inner.mutatorAdd(
      try Pin.factory.createComponent(
        location: Location.create(x, y, hasToSnap: true), attributes: attrs))
  }

  // Y order is what `Location.sortVertical` reads, and therefore the order the west column is
  // laid out in. Transposing two of these silently moves two labels.
  try pin("data", Pin.input, width: 4, y: 100, x: 100)
  try pin("sel1", Pin.input, width: 1, y: 140, x: 100)
  try pin("sel0", Pin.input, width: 1, y: 180, x: 100)
  try pin("clk", Pin.input, width: 1, y: 220, x: 100)
  try pin("out", Pin.output, width: 1, y: 100, x: 400)

  let parent = try Circuit(name: "parent")
  let factory = inner.subcircuitFactory
  try parent.mutatorAdd(
    try factory.createComponent(
      location: Location.create(0, 0, hasToSnap: true),
      attributes: factory.createAttributeSet()))

  // `inner` and `parent` come back so the caller can keep them alive: D3 makes
  // `CircuitSubcircuitFactory.source` an `unowned` back-edge, so a parent circuit does NOT
  // retain the child it instantiates, in the app `LogisimFile` owns both. Dropping `inner`
  // here and then painting reads a destroyed reference.
  return (CircuitSceneSource.build(circuit: parent, appearance: CanvasAppearance()), inner, parent)
}

/// Every `rect` primitive as `(x, y, w, h, isFill, strokeWidth)`.
private func rects(_ scene: RenderScene) -> [(x: Int, y: Int, w: Int, h: Int, fill: Bool, pen: Int)]
{
  scene.primitives.filter { $0.kind == .rect }.map {
    (Int($0.a), Int($0.b), Int($0.c), Int($0.d), $0.style == .fill, Int($0.pen.width))
  }
}

private func text(_ scene: RenderScene, _ string: String) -> TextRun? {
  scene.texts.first { $0.string == string }
}

// MARK: - The gate

@Suite("Subcircuit paint — shape-for-shape against the 4.1.0 jar")
struct SubcircuitPaintOracleTests {

  /// The box itself: a stroke-2 outline and a filled title bar, at the jar's exact coordinates.
  @Test("the outline and the title bar match the jar exactly")
  @MainActor
  func boxMatchesTheJar() throws {
    let all = rects(try sampleBlockPlacement().build.scene)

    #expect(
      all.contains { $0 == (-210, -10, 200, 100, false, 2) },
      "outline (-210,-10,200,100) stroke 2 not found; rects were \(all)")
    #expect(
      all.contains { $0 == (-210, 70, 200, 20, true, 1) },
      "filled title bar (-210,70,200,20) not found; rects were \(all)")
  }

  /// The five pin stubs, including the two widths: `Wire.WIDTH_BUS = 4` for the 4-bit `SW` and
  /// `Wire.WIDTH = 3` for the rest, each centred on its port by `offset = height >> 1`.
  @Test("every pin stub matches the jar, bus and single-bit alike")
  @MainActor
  func pinStubsMatchTheJar() throws {
    let all = rects(try sampleBlockPlacement().build.scene)

    // The jar's five, verbatim.
    let expected: [(Int, Int, Int, Int, Bool, Int)] = [
      (-220, -2, 10, 4, true, 1), // SW: 4 bits, so height 4 and offset 2
      (-220, 19, 10, 3, true, 1),  // KEY1
      (-220, 39, 10, 3, true, 1),  // KEY0
      (-220, 59, 10, 3, true, 1),  // Clk
      (-10, -1, 10, 3, true, 1), // LEDR, east, so x - 10
    ]
    for stub in expected {
      #expect(all.contains { $0 == stub }, "stub \(stub) not found; rects were \(all)")
    }
  }

  /// The clock indicator. `Pin.isClockPin` is label-sniffing, so this also pins that a pin
  /// labelled `Clk` gets a triangle and the other three do not.
  @Test("the clock pin's triangle matches the jar, and only the clock pin has one")
  @MainActor
  func clockTriangleMatchesTheJar() throws {
    let fixture = try sampleBlockPlacement()
    let scene = fixture.build.scene
    defer { _ = fixture.inner }
    let polylines = scene.primitives.filter { $0.kind == .polyline }

    #expect(polylines.count == 1, "expected exactly one clock indicator, got \(polylines.count)")
    let poly = try #require(polylines.first)
    let points = poly.pointRange.map { "\(scene.points[$0].x),\(scene.points[$0].y)" }
    #expect(
      points == ["-209,56", "-202,60", "-209,64"],
      "clock triangle was \(points)")
    #expect(poly.pen.width == 2)
    #expect(poly.style == .stroke)
  }

  /// The five pin labels and the title, at the jar's coordinates.
  ///
  /// `baselineY` is asserted exactly for all six: `valign` is BASELINE, and `TextLayout.textBox`
  /// leaves the baseline at the requested `y` for that alignment, so the number is
  /// measurement-independent. `boxX` is asserted exactly only for the LEFT-aligned runs, where
  /// the box origin *is* the requested `x`; the centred title and the right-aligned `LEDR` have
  /// a measured width in their origin and are checked on alignment instead.
  @Test("the pin labels and the title sit where the jar puts them")
  @MainActor
  func labelsMatchTheJar() throws {
    let fixture = try sampleBlockPlacement()
    let scene = fixture.build.scene
    defer { _ = fixture.inner }

    // West labels: `x + 15`, LEFT-aligned, baseline at `y + sdy` where `sdy = (9 - 1) >> 1 = 4`.
    for (string, x, y) in [("data", -205, 4), ("sel1", -205, 24), ("sel0", -205, 44)] {
      let run = try #require(text(scene, string), "\(string) was not drawn")
      #expect(run.halign == .left, "\(string) halign \(run.halign)")
      #expect(run.valign == .baseline)
      #expect(Int(run.boxX) == x, "\(string) x \(run.boxX) != \(x)")
      #expect(Int(run.baselineY) == y, "\(string) baseline \(run.baselineY) != \(y)")
    }

    // The clock label is shifted a further +8 to clear the triangle: `-220 + 15 + 8 = -197`.
    let clk = try #require(text(scene, "clk"))
    #expect(Int(clk.boxX) == -197, "clk x \(clk.boxX) != -197 — the +8 clock shift is missing")
    #expect(Int(clk.baselineY) == 64)

    // East label: RIGHT-aligned at `x - 15`, so its box origin depends on the measured width.
    let eastLabel = try #require(text(scene, "out"))
    #expect(eastLabel.halign == .right)
    #expect(Int(eastLabel.baselineY) == 4)

    // The title: CENTER-aligned at `rx + (width >> 1)`, baseline `ry + height - descent - 5`.
    let title = try #require(text(scene, "sample_block_2345678"))
    #expect(title.halign == .center)
    #expect(Int(title.baselineY) == 84, "title baseline \(title.baselineY) != 84")
    #expect(title.font.isBold, "the title must use DEFAULT_NAME_FONT, which is bold")
    #expect(Int(title.font.size) == 14)
  }

  /// A count, so a *duplicated* shape fails too. The jar's list for this circuit is 5 stubs +
  /// 1 title bar + 1 outline = 7 rectangles, 1 polyline, 6 texts; plus the 5 port markers
  /// `painter.drawPorts()` adds, which the appearance list deliberately does not contain
  /// (`paintSubcircuit` skips every `AppearanceElement`).
  ///
  /// The marker row is counted by ROLE, not by `kind == .oval`, and that is the whole difference
  /// between a claim and a coincidence. It used to read "5 ovals" because a marker happened to be
  /// one `fillOval`; `SceneBuilder.drawPinMarker` now draws a ring, a knocked-out hole plus a
  /// stroked rim, so the same five markers are ten ovals. What this test is comparing against the
  /// jar is *five ports, each marked once*, which has not changed and must not be restated as a
  /// count of this week's shapes. The appearance's own contribution is asserted separately, so a
  /// duplicated appearance oval still fails exactly as it did before.
  @Test("the shape inventory matches the jar's, with no duplicates")
  @MainActor
  func inventoryMatchesTheJar() throws {
    let fixture = try sampleBlockPlacement()
    let build = fixture.build
    let scene = build.scene
    defer { _ = fixture.inner }

    #expect(rects(scene).count == 7, "expected 7 rectangles, got \(rects(scene).count)")
    #expect(scene.texts.count == 6, "expected 6 text runs, got \(scene.texts.map(\.string))")
    #expect(scene.primitives.filter { $0.kind == .polyline }.count == 1)

    // `drawPorts` draws one marker per end; the ring is two primitives per marker.
    let markers = scene.primitives.filter { $0.role == .connectionMarker }
    #expect(markers.count == 5 * 2, "expected 5 port markers, got \(markers.count) primitives")
    // …and the appearance itself contributes no oval at all, which is what the jar's list says.
    #expect(
      scene.primitives.filter { $0.kind == .oval && $0.role != .connectionMarker }.isEmpty,
      "the appearance drew an oval of its own; the jar's shape list for this circuit has none")
  }

  /// And the port geometry the drawing is derived from: the component's ends must land on the
  /// same five points the stubs are drawn at, or the schematic shows wires meeting nothing.
  @Test("the ends and the drawn stubs agree")
  @MainActor
  func endsAgreeWithStubs() throws {
    let fixture = try sampleBlockPlacement()
    let placement = try #require(fixture.build.components.first)
    defer { _ = fixture.inner }
    let ends = Set(placement.ends.map { ($0.location.x, $0.location.y) }.map { "\($0.0),\($0.1)" })

    #expect(ends == ["-220,0", "-220,20", "-220,40", "-220,60", "0,0"], "ends were \(ends)")
    #expect(placement.bounds == Bounds.create(-220, -10, 220, 100), "\(placement.bounds)")
  }
}
