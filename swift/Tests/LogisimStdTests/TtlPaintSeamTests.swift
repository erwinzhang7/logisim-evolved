// LogisimStdTests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE TTL PAINT SEAM, MEASURED RATHER THAN COMPILED
//
// `AbstractTtlGate` conformed to neither `InstancePaintable` nor `ComponentPaintable`: the two
// protocols `CircuitRenderer.render` (`CircuitRenderer.swift:117,121`) and `ToolOverlayScene`
// (`:290,313`) cast to. Its paint entry points existed and were complete, but carried bespoke
// signatures no protocol named:
//
//     paintInstance(_ painter: SceneBuilder, _ state: any InstanceState)
//     paintGhost(_ painter: SceneBuilder, attributes: any AttributeSet, bounds: Bounds)
//
// so both casts failed and every one of the 61 74xx chips drew nothing, along with the 45
// `paintInternal` overrides and the 61/61 correct label placements behind them.
//
// This suite measures the join instead of trusting the build. Two things in it are deliberately
// stronger than "the scene is non-empty", because a non-empty scene is exactly what a partially
// wired seam produces:
//
//   * `sevenFourHundredEmitsTheExactPrimitiveCensus` pins the *derived* primitive count by kind
//     and style for one chip in its default appearance: 36 of the chip's own geometry plus 2
//     per port, 60 in all, every one accounted for by a line of `AbstractTtlGate.paintInstance`.
//     A regression that drops the pin stubs, or the DIP body, or the Vcc/GND legends still
//     leaves a non-empty scene; it cannot leave this census intact.
//   * `theLabelJoinActuallyHappens` reads the emitted `TextRun` back and checks the string, the
//     alignment and the exact placement coordinates against `AbstractTtlGate.labelPlacement`.
//
// ── NUMBERS (this branch, measured by reverting one token at a time) ─────────────────────────
//
//   probe                                                  | what reddens
//   -------------------------------------------------------|----------------------------------
//   `AbstractTtlGate: TtlPaintable` → deleted                | 61/61 factories undispatchable,
//                                                           | 0/61 painted, 0 primitives
//   `state.drawPorts()` → deleted from paintInstance         | census 60 → 36 (12 pin markers,
//                                                           | 2 primitives each since the ring)
//   `state.drawLabel()` → deleted from paintInstance         | label never drawn
//   `paintGhost` body → emptied                              | ghost falls back to a bare box
//
// The exact figures each probe produced are in the task report; the assertions below are what
// keeps them from drifting back.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import Testing

@testable import LogisimStd

// MARK: - Harness

/// `StdLibraries.registerAll()`, at most once per process, and **only where a `.circ` is loaded**.
///
/// Same rule as `MemPaintSeamTests`: `registerAll` writes into process-global dictionaries no
/// test target unwinds, so only the corpus test, which needs the builtin libraries to resolve a
/// file off disk, calls it. Everything else builds `TtlLibrary()` directly.
private let ttlLibrariesRegistered: Void = {
  StdLibraries.registerAll()
}()

private func ensureTtlLibrariesRegistered() { _ = ttlLibrariesRegistered }

/// Every TTL factory this port has, taken from `TtlLibrary` rather than listed by hand so a chip
/// added later is covered automatically instead of escaping the gate.
private func ttlFactories() -> [any ComponentFactory] {
  TtlLibrary().tools.compactMap { ($0 as? AddTool)?.factory }
}

/// Renders `circuit` through the real walker. Both halves are reported: `painted` can rise while
/// the scene stays empty, and the scene can be non-empty from the wire layer alone.
private func measureTtl(_ circuit: Circuit) -> (painted: Int, primitives: Int, total: Int) {
  let builder = SceneBuilder(measurer: NominalTextMeasurer())
  let painted = CircuitRenderer.render(circuit, into: builder, context: StaticPaintContext())
  return (painted, builder.finish().primitives.count, circuit.components.count)
}

/// One component per factory, spaced so nothing overlaps.
private func ttlCircuit(of factories: [any ComponentFactory], named name: String) throws -> Circuit
{
  let result = try Circuit(name: name)
  for (index, factory) in factories.enumerated() {
    let component = try factory.createComponent(
      location: Location.create(400 * (index % 8), 400 * (index / 8), hasToSnap: false),
      attributes: factory.createAttributeSet())
    try result.mutatorAdd(component)
  }
  return result
}

/// Renders exactly one component and hands back the whole scene, so a test can read primitives
/// and text runs rather than just count them.
private func renderOne(
  _ factory: any ComponentFactory, at location: Location = Location.create(
    100, 100, hasToSnap: false),
  configure: (any AttributeSet) throws -> Void = { _ in }
) throws -> RenderScene {
  let attributes = factory.createAttributeSet()
  try configure(attributes)
  let circuit = try Circuit(name: "ttl-one-\(factory.name)")
  try circuit.mutatorAdd(
    try factory.createComponent(location: location, attributes: attributes))
  let builder = SceneBuilder(measurer: NominalTextMeasurer())
  CircuitRenderer.render(circuit, into: builder, context: StaticPaintContext())
  return builder.finish()
}

/// `(kind, style) -> count` over a scene, which is the shape every census assertion below reads.
private func census(_ scene: RenderScene) -> [String: Int] {
  var result: [String: Int] = [:]
  for primitive in scene.primitives {
    result["\(primitive.kind)/\(primitive.style)", default: 0] += 1
  }
  return result
}

/// The same census restricted to the chip's own geometry; everything except the port markers.
///
/// ── WHY THE CENSUSES BELOW ARE SPLIT ───────────────────────────────────────────────────────
///
/// A port marker used to be one `fillOval` and is now a ring: a knocked-out hole plus a stroked
/// rim, two primitives (`SceneBuilder.drawPinMarker`). That legitimately changes every count
/// below, and the lazy way to absorb it is to paste in whatever the code now emits, which turns
/// a derived-from-source fidelity pin into a rubber stamp.
///
/// So each census is asserted twice instead. The body census is what `AbstractTtlGate`'s own
/// paint path emits and is **unchanged, to the primitive**, by the ring; the marker census is
/// stated separately as `2 × ports`. A regression that drops the DIP body still fails the first;
/// a regression that drops `drawPorts` still fails the second; and the ring's contribution is
/// visible as a number with a derivation rather than as twelve extra ovals in a bag.
///
/// The split also removes a real ambiguity in the internal-structure case, where the chip draws
/// four stroked ovals of its own (the NAND bubbles). Merged, its `oval/stroke` count is 16 and
/// says nothing; split, it is 4 body + 12 marker, and each half is separately falsifiable.
private func bodyCensus(_ scene: RenderScene) -> [String: Int] {
  var result: [String: Int] = [:]
  for primitive in scene.primitives where primitive.role != .connectionMarker {
    result["\(primitive.kind)/\(primitive.style)", default: 0] += 1
  }
  return result
}

/// The primitives `drawPinMarker` emitted, by `(kind, style)`.
private func markerCensus(_ scene: RenderScene) -> [String: Int] {
  var result: [String: Int] = [:]
  for primitive in scene.primitives where primitive.role == .connectionMarker {
    result["\(primitive.kind)/\(primitive.style)", default: 0] += 1
  }
  return result
}

/// What one port marker costs, derived from `SceneBuilder.drawPinMarker`: a filled hole and a
/// stroked rim. Written once so the arithmetic below is a derivation and not a literal.
private let markerCensusPerPort = ["oval/fill": 1, "oval/stroke": 1]

private func expectedMarkerCensus(ports: Int) -> [String: Int] {
  markerCensusPerPort.mapValues { $0 * ports }
}

private func ttlCorpusDirectory() -> URL? {
  guard let path = ProcessInfo.processInfo.environment["LOGISIM_CORPUS"] else { return nil }
  var isDirectory: ObjCBool = false
  guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
    isDirectory.boolValue
  else { return nil }
  return URL(fileURLWithPath: path)
}

// MARK: - The gate

@Suite("TTL paint seam", .serialized)
struct TtlPaintSeamTests {

  /// The one-line statement of the seam. This was `false` for **all 61** factories.
  @Test("every TTL factory dispatches through the renderer's protocol")
  func everyTtlFactoryIsPaintable() {
    let factories = ttlFactories()
    #expect(factories.count == 61)
    let undispatchable = factories.filter { !($0 is any InstancePaintable) }.map(\.name).sorted()
    #expect(
      undispatchable.isEmpty,
      "TTL factories the renderer cannot dispatch to: \(undispatchable.joined(separator: ", "))")
  }

  /// The painter half. Erased to `Any` on purpose: written against the concrete type the
  /// compiler folds the check away as always-true, so deleting the conformance would delete a
  /// *warning* rather than fail a test.
  @Test("the concrete painter satisfies the TTL painter protocol")
  func painterConformsToTtlPainter() {
    let builder = SceneBuilder(measurer: NominalTextMeasurer())
    let erased: Any = InstancePainter(g: builder, context: StaticPaintContext())
    #expect(erased is any TtlPainter)
  }

  /// The whole family, through the real walker.
  @Test("a circuit of all 61 TTL chips paints and emits geometry")
  func ttlComponentsPaint() throws {
    let factories = ttlFactories()
    let result = measureTtl(try ttlCircuit(of: factories, named: "ttl-all"))
    #expect(result.total == 61)
    #expect(
      result.painted == result.total, "\(result.painted) of \(result.total) TTL chips painted")
    #expect(result.primitives > 0, "TTL chips reported painted but emitted no geometry")
    print("ttl paint seam: \(result.painted)/\(result.total) painted, \(result.primitives) prims")
  }

  /// Per factory, so one silently inert chip cannot hide inside a healthy total.
  @Test("no single TTL factory is silently inert")
  func noTtlFactoryIsInert() throws {
    var silent: [String] = []
    var counts: [String: Int] = [:]
    for factory in ttlFactories() {
      let result = measureTtl(try ttlCircuit(of: [factory], named: "ttl-\(factory.name)"))
      counts[factory.name] = result.primitives
      if result.painted != 1 || result.primitives == 0 { silent.append(factory.name) }
    }
    #expect(silent.isEmpty, "TTL chips that emitted nothing: \(silent.joined(separator: ", "))")
    // A floor as well as a non-zero: the smallest chip in the family is a 14-pin package, whose
    // outline alone is 28 pin rectangles + 4 body round-rects + 1 notch arc + 3 legends.
    let thin = counts.filter { $0.value < 20 }.keys.sorted()
    #expect(thin.isEmpty, "TTL chips with implausibly little geometry: \(thin.joined(separator: ", "))")
  }

  /// **The strong assertion.** Every primitive one chip emits, derived from the source rather
  /// than observed, so a partial regression cannot pass by still being non-empty.
  ///
  /// `Ttl7400` at its defaults, FACING east, VCC_GND off, DRAW_INTERNAL_STRUCTURE off, no label
  /// , placed at (100, 100). `offsetBounds` is `Bounds(0, -30, 14 * 10, 60)`, so the component
  /// box is `(100, 70, 140, 60)`.
  ///
  /// | source line                                          | primitives |
  /// |------------------------------------------------------|------------|
  /// | pin loop, 14 iterations of `fillRect` + `drawRect`    | 14 filled + 14 stroked rects |
  /// | body at `i == pinNumber / 2`: two `fillRoundRect`, | 2 filled + 2 stroked round-rects |
  /// | two `drawRoundRect`                                   |            |
  /// | the orientation notch, `fillArc`                      | 1 filled arc |
  /// | the part number, then `Vcc` and `GND`                 | 3 text runs |
  ///
  /// 36 of the chip's own geometry, plus `state.drawPorts()`: one marker per end, and a 14-pin
  /// chip with VCC_GND off has 14 − 2 = 12 ports.
  ///
  /// ── THE MARKER ROW MOVED, AND IT MOVED FOR A REASON ────────────────────────────────────────
  ///
  /// That row used to read "12 filled ovals" and total 48. `SceneBuilder.drawPinMarker` now draws
  /// a ring rather than a filled disc, a knocked-out hole plus a stroked rim, so it is 24
  /// primitives and the total is 60. Checked row by row against the emitted scene before the
  /// number was changed: **the 36 above are byte-for-byte the same primitives they were**, and
  /// the entire delta is 12 stroked ovals, one per port, none of which existed before. Nothing
  /// else in the chip's paint path emits a stroked oval in this appearance, which is why the
  /// arithmetic closes exactly.
  ///
  /// Asserted as two censuses rather than one, so "the ring costs one more primitive per port"
  /// stays a derivation. See `bodyCensus`.
  @Test("7400 emits the exact primitive census its paint path derives")
  func sevenFourHundredEmitsTheExactPrimitiveCensus() throws {
    let scene = try renderOne(Ttl7400())

    // The chip's own geometry: unchanged by the ring, and every row of the table above.
    let body = bodyCensus(scene)
    let expectedBody = [
      "rect/fill": 14,
      "rect/stroke": 14,
      "roundRect/fill": 2,
      "roundRect/stroke": 2,
      "arc/fill": 1,
      "text/fill": 3,
    ]
    #expect(body == expectedBody, "7400 body census was \(body.sorted(by: { $0.key < $1.key }))")
    #expect(body.values.reduce(0, +) == 36)

    // The ports, stated as a rate rather than a total.
    let ports = 12
    #expect(
      markerCensus(scene) == expectedMarkerCensus(ports: ports),
      "7400 marker census was \(markerCensus(scene).sorted(by: { $0.key < $1.key }))")

    // …and the two together are the whole scene, so nothing escaped both censuses.
    let seen = census(scene)
    var expected = expectedBody
    for (key, value) in expectedMarkerCensus(ports: ports) {
      expected[key, default: 0] += value
    }
    #expect(seen == expected, "7400 census was \(seen.sorted(by: { $0.key < $1.key }))")
    #expect(scene.primitives.count == 60)

    // The three legends, by content; a census alone cannot tell "7400/Vcc/GND" from three
    // empty strings.
    let strings = Set(scene.primitives.compactMap { scene.textRun($0)?.string })
    #expect(strings == ["7400", "Vcc", "GND"])
  }

  /// The Vcc/GND port pair is an attribute, and it changes the *port count*, which is the one
  /// number `drawPorts` reads. Turning it on must add exactly two markers and nothing else.
  ///
  /// Written against the role split rather than against `oval/fill`, which was only ever a proxy
  /// for "a marker" and stopped being one when the marker became a ring: with the rim also an
  /// oval, the old exemption let `oval/stroke` through as an unexplained change. The claim in the
  /// test's own name, *two more markers, no other geometry*, is now stated directly.
  @Test("VCC_GND adds exactly two pin markers and no other geometry")
  func vccGndAddsTwoMarkers() throws {
    let offScene = try renderOne(Ttl7400())
    let onScene = try renderOne(Ttl7400()) { try $0.setValue(TtlLibraryAttributes.vccGnd, true) }

    #expect(markerCensus(offScene) == expectedMarkerCensus(ports: 12))
    #expect(markerCensus(onScene) == expectedMarkerCensus(ports: 14))
    // "and no other geometry": the chip's own primitives are identical, kind for kind.
    #expect(
      bodyCensus(onScene) == bodyCensus(offScene),
      "VCC_GND changed the chip's own geometry: \(bodyCensus(onScene)) vs \(bodyCensus(offScene))")
  }

  /// **The label join, which is the part that silently does not happen.**
  ///
  /// The 61 chips already had correct placements (`AbstractTtlGate.labelPlacement`, measured
  /// 61/61 conforming by `TtlTunnelLabelPlacementTests`) and `InstancePainter.drawLabel` already
  /// knew how to use them, but nothing called it, because `paintInstance` was never dispatched
  /// *and* did not call it even when reached. Both halves are asserted here: the string is
  /// emitted, and it lands where `labelPlacement` says.
  @Test("a TTL chip's label is drawn, at the placement labelPlacement computes")
  func theLabelJoinActuallyHappens() throws {
    let scene = try renderOne(Ttl7400()) { try $0.setValue(StdAttr.label, "U7") }
    let runs = scene.primitives.compactMap { scene.textRun($0) }
    let label = try #require(
      runs.first { $0.string == "U7" },
      "no label text run; the drawLabel join did not happen (runs: \(runs.map(\.string)))")

    // `AbstractTtlGate.labelPlacement`, east arm: x = bds.x + bds.width + 3, y = bds.y +
    // bds.height / 2, H_LEFT / V_CENTER_OVERALL. Box is (100, 70, 140, 60).
    #expect(label.boxX == Int32(100 + 140 + 3))
    #expect(label.halign == .left)
    #expect(label.valign == .centerOverall)

    // And the negative: an empty label emits no fourth text run, so the assertion above is
    // about the label and not about any text the body happens to draw.
    let unlabelled = try renderOne(Ttl7400())
    #expect(unlabelled.primitives.compactMap { unlabelled.textRun($0)?.string }.count == 3)
  }

  /// A label must draw for **every** chip, not just the one above. `labelPlacement` lives on
  /// `AbstractTtlGate` and `drawLabel` reaches it through `factory as? InstanceLabelProvider`, so
  /// a chip that somehow lost the conformance would be invisible to the test above.
  @Test("every TTL chip draws its label")
  func everyChipDrawsItsLabel() throws {
    var missing: [String] = []
    for factory in ttlFactories() {
      let scene = try renderOne(factory) { try $0.setValue(StdAttr.label, "LBL") }
      let found = scene.primitives.contains { scene.textRun($0)?.string == "LBL" }
      if !found { missing.append(factory.name) }
    }
    #expect(missing.isEmpty, "TTL chips whose label never drew: \(missing.joined(separator: ", "))")
  }

  /// The other paint path. `DRAW_INTERNAL_STRUCTURE` switches `paintInstance` from the DIP
  /// photograph to `paintInternalBase`, which fans out over each chip's own `paintInternal`;
  /// 45 separate overrides that the default appearance never reaches. A conformance that worked
  /// for one appearance and trapped in the other would pass every test above.
  @Test("the internal-structure appearance draws too, for every chip")
  func internalStructureDrawsForEveryChip() throws {
    var silent: [String] = []
    for factory in ttlFactories() {
      let scene = try renderOne(factory) {
        try $0.setValue(TtlLibraryAttributes.drawInternalStructure, true)
      }
      if scene.primitives.isEmpty { silent.append(factory.name) }
    }
    #expect(
      silent.isEmpty,
      "TTL chips whose internal structure drew nothing: \(silent.joined(separator: ", "))")

    // And it is genuinely a different picture, not the same one relabelled, derived the same
    // way as the census above, for `Ttl7400` (`drawGates: true`, four output pins, so
    // `numberOfGatesToDraw == 4`):
    //
    // | source                                                     | primitives |
    // |------------------------------------------------------------|------------|
    // | `paintBase(drawName: false)`, the outline only, no fills   | 14 stroked rects, 1 stroked
    // |                                                            | round-rect, 1 stroked arc,
    // |                                                            | 2 texts (`Vcc`, `GND`) |
    // | 4 × `Ttl7400.paintInternal`. Per gate: `Drawgates.paintAnd` | 4 stroked ovals (the NAND
    // | negated, an oval, a centred arc, a polyline, and no        | bubbles), 4 arcs,
    // | `drawLine` since `height > width` is false at 15 × 15, | 4 × 4 = 16 polylines |
    // | plus `paintOutputgate` (1 polyline) and                     |            |
    // | `paintDoubleInputgate` (2 polylines): 4 polylines a gate    |            |
    // | `state.drawPorts()`                                        | 12 markers |
    //
    // The part number is NOT drawn in this appearance (`drawName: false`), which is why there
    // are two texts here and three above.
    //
    // ── THE ROLE SPLIT EARNS ITS KEEP HERE ─────────────────────────────────────────────────────
    //
    // This appearance draws four stroked ovals of its own; the NAND bubbles. Once the port
    // marker became a ring it draws twelve more, and a merged census reports `oval/stroke: 16`,
    // which is a number that cannot fail informatively: lose all four bubbles, gain four ports,
    // and it still reads 16. Split, the bubbles are pinned at 4 and the markers at 12, and each
    // is separately falsifiable. That is the reason this census went from one assertion to two,
    // rather than from `4` to `16`.
    let internalScene = try renderOne(Ttl7400()) {
      try $0.setValue(TtlLibraryAttributes.drawInternalStructure, true)
    }
    let internalBody = bodyCensus(internalScene)
    #expect(
      internalBody == [
        "oval/stroke": 4, "rect/stroke": 14, "roundRect/stroke": 1,
        "arc/stroke": 5, "polyline/stroke": 16, "text/fill": 2,
      ], "7400 internal body census was \(internalBody.sorted(by: { $0.key < $1.key }))")
    #expect(
      markerCensus(internalScene) == expectedMarkerCensus(ports: 12),
      "7400 internal marker census was \(markerCensus(internalScene))")
    // The package body is no longer filled, so this is a schematic and not the DIP photograph.
    // Stated over the whole scene, markers included: the ring's hole IS a fill, and this has to
    // keep meaning "no filled round-rect" rather than "no fills at all".
    #expect(census(internalScene)["roundRect/fill"] == nil)
  }

  /// The ghost. Unlike the memory family, upstream **does** override `paintGhost` here
  /// (`AbstractTtlGate.java:281-284`), so a dragged chip previews its outline rather than the
  /// bare offset-bounds rectangle `AbstractComponentFactory.drawGhost` strokes.
  ///
  /// The ghost painter has no component, so this also exercises the `bounds`-from-factory arm of
  /// `InstancePainter`; the one that returns unlocated offset bounds.
  @Test("ghost painting a TTL chip draws the package outline")
  func ghostPaintingDrawsTheOutline() throws {
    var silent: [String] = []
    for factory in ttlFactories() {
      guard let paintable = factory as? any InstancePaintable else {
        silent.append(factory.name)
        continue
      }
      let builder = SceneBuilder(measurer: NominalTextMeasurer())
      let painter = InstancePainter(g: builder, context: StaticPaintContext())
      painter.setFactory(
        factory as? any InstanceFactory, factory.createAttributeSet(),
        at: Location.create(0, 0, hasToSnap: false))
      paintable.paintGhost(painter)
      if builder.finish().primitives.isEmpty { silent.append(factory.name) }
    }
    #expect(silent.isEmpty, "TTL ghosts that drew nothing: \(silent.joined(separator: ", "))")

    // By census, so "it drew something" cannot pass on a stray pixel: the ghost is
    // `paintBase(drawName: true, ghost: true)`: 14 stroked pin rectangles, one stroked
    // round-rect, one stroked notch arc, and three texts (part number, Vcc, GND). Nothing is
    // filled, which is what makes it read as a ghost.
    //
    // Reached through `as? any InstancePaintable` rather than by calling `Ttl7400.paintGhost`
    // directly, and that is not stylistic: a direct call binds to the two-argument method on the
    // class and would keep compiling with the conformance deleted, turning the probe for this
    // seam into a green test. Through the cast, deleting the conformance fails the test.
    let builder = SceneBuilder(measurer: NominalTextMeasurer())
    let painter = InstancePainter(g: builder, context: StaticPaintContext())
    let chip = Ttl7400()
    painter.setFactory(chip, chip.createAttributeSet(), at: Location.create(0, 0, hasToSnap: false))
    try #require(chip as? any InstancePaintable).paintGhost(painter)
    let ghost = census(builder.finish())
    #expect(
      ghost == [
        "rect/stroke": 14, "roundRect/stroke": 1, "arc/stroke": 1, "text/fill": 3,
      ], "ghost census was \(ghost.sorted(by: { $0.key < $1.key }))")
  }

  // MARK: Corpus

  /// The join, survived by a file that came off disk.
  ///
  /// The synthetic circuits above build factories with a `new`; this one uses the factories a
  /// `BuiltinLibraryShell` materialises while parsing XML, with attributes read out of the file.
  /// Different objects reaching the same cast.
  ///
  /// **Sizing, measured before this test was written.** Of the 576 harvested `.circ`, 340 declare
  /// the `#TTL` library and only **20 actually place a chip**: 283 placements of 18 distinct
  /// part numbers, led by 7432 (54), 7408 (47) and 74245 (35). So this is live, not vestigial
  /// (contrast the SoC survey: 337 files declaring `#Soc`, one placing a component), but it is a
  /// 3.5% tail of the corpus rather than something every file exercises.
  @Test("a corpus circuit's TTL chips paint")
  func corpusTtlPaints() throws {
    guard let corpus = ttlCorpusDirectory() else {
      print("LOGISIM_CORPUS unset — corpus TTL render skipped")
      return
    }
    ensureTtlLibrariesRegistered()
    let ttlNames = Set(ttlFactories().map(\.name))

    let files =
      (FileManager.default.enumerator(at: corpus, includingPropertiesForKeys: nil)?
      .compactMap { $0 as? URL }
      .filter { $0.pathExtension == "circ" }
      .sorted { $0.path < $1.path } ?? [])

    // The `file` is held deliberately alongside the circuit: releasing it would release every
    // OTHER circuit in the file, including subcircuits the winner places, and the `unowned` D3
    // back-edges then trap during paint. Same hazard `MemPaintSeamTests` records.
    var best: (name: String, file: LogisimFile, circuit: Circuit, ttlCount: Int)?
    for url in files {
      guard let file = try? Loader().openLogisimFile(url) else { continue }
      for circuit in file.circuits {
        let count = circuit.components.filter {
          ttlNames.contains($0.factory.name) && $0.factory is AbstractTtlGate
        }.count
        if count > (best?.ttlCount ?? 0) {
          best = ("\(url.lastPathComponent)/\(circuit.name)", file, circuit, count)
        }
      }
    }

    let chosen = try #require(best, "no corpus circuit places a TTL chip")
    let result = measureTtl(chosen.circuit)
    print(
      "corpus TTL render: \(chosen.name) — \(chosen.ttlCount) TTL of \(result.total) components, "
        + "\(result.painted) painted, \(result.primitives) primitives")

    // Per component, not `painted >= ttlCount`: with the conformance reverted a mixed circuit
    // still reports a healthy painted count from everything that is not a TTL chip, which is how
    // this defect class survives a floor assertion. (Measured on the memory seam: 89 painted
    // against 64 memory components, all 64 of them blank.)
    let undispatched = Set(
      chosen.circuit.components
        .filter { $0.factory is AbstractTtlGate }
        .filter { !($0.factory is any InstancePaintable) }
        .map(\.factory.name))
    #expect(
      undispatched.isEmpty,
      "TTL components the renderer cannot dispatch to: \(undispatched.sorted().joined(separator: ", "))")
    #expect(result.painted >= chosen.ttlCount)
    #expect(result.primitives > 0)
  }
}
