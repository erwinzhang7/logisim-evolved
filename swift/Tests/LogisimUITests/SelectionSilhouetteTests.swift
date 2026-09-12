// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution, which is GPL-3.0-only. This port is a derivative work and is
// therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE SELECTION OUTLINE FOLLOWS THE COMPONENT'S OWN SHAPE.
//
// ── Where this came from ────────────────────────────────────────────────────────────────────
//
// Reported from real use, with a Pin selected: "my point is make it the same shape as the
// object, why rect around the funny shape?? colours fine double border size on the blue". A Pin
// in the shipped appearance is a PENTAGON, `Pin.drawInputShape` calls `g.drawPolygon` with five
// points, so a bounding rectangle around it is the wrong outline however tightly it hugs, which
// is why the previous round of tightening (`SelectionOutlineTests`, still live next door, still
// gating the rectangle FALLBACK) did not settle the complaint.
//
// ── Why these tests and not a screenshot ────────────────────────────────────────────────────
//
// Because the rule has five clauses and four of them exist to stop a specific bad outline, and
// none of those four is visible in a screenshot of the component that motivated the change. Each
// was found by measuring the whole builtin corpus, and each is asserted here by name:
//
//   clause 1  a NOT gate is a `polyline` plus a stroked `oval`. The first draft excluded
//             polylines, and a NOT gate came out outlined by its INVERSION BUBBLE ALONE: a
//             small circle floating off the gate's nose. `notGateTracesBothItsTriangleAndBubble`.
//   clause 2a every port marker is tagged `.connectionMarker` by the one thing that emits one.
//             Admitting them gave every component a rash of little blue rings on its pins.
//             `portMarkersAreNotTraced`. This clause used to say "markers are fills" instead,
//             which was true only while the marker was a disc; see the test for what that cost.
//   clause 2b a fill is ink, not boundary. Independent of 2a, and no longer the thing that keeps
//             markers out.
//   clause 3  a flip-flop's clock wedge sits inside its body. `interiorDetailIsNotTraced`.
//   clause 4  a 7408 draws a body, a notch and FOURTEEN pin-leg rectangles, all of which stick
//             out of the body and so survive clause 3. `aTtlChipFallsBackToItsBox`.
//   clause 5  a Transistor's body is drawn entirely in `line`s and contains one stroked oval;
//             without a coverage floor that oval becomes the whole outline.
//             `aComponentWhoseOnlyShapeIsADetailFallsBack`.
//
// A pixel test would answer none of these questions and would answer the one it could answer
// slowly and with a tolerance. The geometry is a pure function precisely so it can be stated
// exactly, which is the same reason `selectionOutline` was extracted in the first place.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import CoreGraphics
import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimStd
import Testing

@testable import LogisimUI

// MARK: - Fixtures

/// One component, alone in a circuit, walked into a real scene by the real renderer. Not a mock:
/// the thing under test is what the actual `paintInstance` implementations emit.
@MainActor
private func silhouetteFixture(
  of factory: any ComponentFactory,
  newPinAppearance: Bool = false
) throws -> (SelectionSilhouette, SceneGroup, RenderScene) {
  let fixture = try silhouetteFixtureWithComponent(of: factory, newPinAppearance: newPinAppearance)
  return (fixture.0, fixture.1, fixture.2)
}

/// The same fixture, plus the component itself.
///
/// Only `portMarkersAreNotTraced` needs the component, and it needs it for a specific reason:
/// that test gates clause 2a, so its fixture-adequacy check must be stated in terms of something
/// the rule under test cannot answer, the component's own PORT LOCATIONS, rather than in terms
/// of which primitives the rule admits. See the comment there.
@MainActor
private func silhouetteFixtureWithComponent(
  of factory: any ComponentFactory,
  newPinAppearance: Bool = false
) throws -> (SelectionSilhouette, SceneGroup, RenderScene, any Component) {
  StdLibraries.registerAll()
  let circuit = try Circuit(name: "silhouette")
  let attributes = factory.createAttributeSet()
  if newPinAppearance {
    // The shipped default (`AppPreferences.NEW_INPUT_OUTPUT_SHAPES` = true), set explicitly
    // because a headless test does not load the preference file and would otherwise measure the
    // CLASSIC pin, which really is a rectangle and would pass the pentagon test for the wrong
    // reason. Note this is `LogisimStd.ProbeAttributes`, not the same-named type in
    // `LogisimFile`: see the header on `ProbeAttributes.swift`.
    try attributes.setValue(
      LogisimStd.ProbeAttributes.probeAppearance,
      LogisimStd.ProbeAttributes.appearEvolutionNew)
  }
  let component = try factory.createComponent(
    location: Location.create(200, 200, hasToSnap: false), attributes: attributes)
  try circuit.mutatorAdd(component)

  let build = CircuitSceneSource.build(circuit: circuit, appearance: CanvasAppearance())
  let group = try #require(
    SelectionSilhouette.groupsByTag(in: build.scene)[1],
    "\(factory.name) emitted no scene group, so there is nothing to trace")
  return (
    SelectionSilhouette.of(group: group, in: build.scene), group, build.scene, component
  )
}

@MainActor
private func builtinFactory(named name: String) -> (any ComponentFactory)? {
  StdLibraries.registerAll()
  let libraryIds = [
    Builtin.gatesId, Builtin.wiringId, Builtin.arithmeticId, Builtin.memoryId,
    Builtin.ioId, Builtin.ttlId, Builtin.plexersId, Builtin.extraIoId, Builtin.fpArithmeticId,
  ]
  for id in libraryIds {
    for tool in BuiltinToolProviders.tools(forLibraryId: id) {
      guard let add = tool as? AddTool else { continue }
      if add.factory.name == name { return add.factory }
    }
  }
  return nil
}

private func shapeCount(_ silhouette: SelectionSilhouette) -> Int {
  if case .body(let shapes) = silhouette { return shapes.count }
  return 0
}

private func worldBox(_ primitive: ScenePrimitive) -> CGRect {
  primitive.bounds.isEmpty
    ? .null
    : CGRect(
      x: CGFloat(primitive.bounds.minX), y: CGFloat(primitive.bounds.minY),
      width: CGFloat(primitive.bounds.width), height: CGFloat(primitive.bounds.height))
}

/// The extent of the component's own SHAPE: the rule's OWN clause-5 denominator, called rather
/// than re-implemented.
///
/// The reference the "does the trace span the thing?" assertions below are really about, and
/// deliberately not `group.bounds`, which is the union of *everything* the component emitted.
/// Those assertions used `group.bounds` until `drawPinMarker` became a ring: the marker's
/// footprint grew from ±2 to ±4 around every port, every component's group silently got wider,
/// and two assertions about geometry that had not moved at all went red. A denominator a restyle
/// can move is not a denominator.
///
/// Calling `SelectionSilhouette.shapeExtent` rather than rebuilding the walk here is the point:
/// the corpus census used to rebuild it, with a different exclusion set from the rule's, and so
/// reported coverage numbers the rule never acted on, which meant no probe of the rule's
/// denominator could redden anything.
///
/// Not circular for the two span tests that use it: `shapeExtent` is clause 5's denominator, and
/// neither of those tests is testing clause 5: one tests clause 1 (polylines survive) and the
/// other tests `path(for:)`. The test that *does* gate clause 2a states its fixture in terms of
/// port locations instead, precisely so it never asks the rule under test whether its fixture is
/// adequate. See `portMarkersAreNotTraced`.
private func bodyExtent(_ group: SceneGroup, _ scene: RenderScene) -> CGRect {
  SelectionSilhouette.shapeExtent(of: group, in: scene)
}

// MARK: - The reported defect

@Suite("Selection silhouette — the shape of a selection")
struct SelectionSilhouetteTests {

  /// **THE DEFECT.** The whole reason this exists.
  @MainActor
  @Test("a Pin in the shipped appearance is traced as its pentagon, not boxed")
  func pinIsTracedAsAPentagon() throws {
    let (silhouette, _, _) = try silhouetteFixture(of: Pin.factory, newPinAppearance: true)
    guard case .body(let shapes) = silhouette else {
      Issue.record(
        """
        a Pin fell back to its bounding box — this is exactly the reported defect: \
        "make it the same shape as the object, why rect around the funny shape??"
        """)
      return
    }
    #expect(shapes.count == 1, "a Pin has one body shape; got \(shapes.count)")
    guard case .polygon(let points) = shapes[0].form else {
      Issue.record("a Pin's body is \(shapes[0].form), not the polygon `drawInputShape` emits")
      return
    }
    #expect(
      points.count == 5,
      """
      the traced shape has \(points.count) corners, not the five of `Pin.drawInputShape`'s \
      arrow — the outline is no longer the component's own silhouette
      """)
  }

  /// The other half of the ask: "double border size on the blue".
  @MainActor
  @Test("the selection pen is 2pt, and the rectangle fallback's inset follows it")
  func theSelectionPenIsDoubled() {
    #expect(
      CircuitSceneView.selectionStrokeWidth == 2,
      "the reported ask was to double the 1pt selection border")
    // The inset is derived, not written twice. A rectangle inset by half the pen puts the drawn
    // line ON the boundary; if the two ever drift apart the outline straddles or clears it.
    let box = CGRect(x: 100, y: 50, width: 40, height: 20)
    let rect = CircuitSceneView.selectionOutline(for: box, isWire: false)
    #expect(
      rect.minX - box.minX == CircuitSceneView.selectionStrokeWidth / 2,
      "the fallback rectangle's inset (\(rect.minX - box.minX)) is not half the pen")
  }
}

// MARK: - The five clauses

@Suite("Selection silhouette — the rule's five clauses")
struct SelectionSilhouetteRuleTests {

  /// **Clause 1.** The first draft excluded `polyline`, and this is what it cost.
  @MainActor
  @Test("a NOT gate traces both its triangle and its bubble, not the bubble alone")
  func notGateTracesBothItsTriangleAndBubble() throws {
    let (silhouette, group, scene) = try silhouetteFixture(of: NotGate.factory)
    guard case .body(let shapes) = silhouette else {
      Issue.record("a NOT gate fell back to a box")
      return
    }
    #expect(
      shapes.count == 2,
      """
      a NOT gate is a `polyline` triangle plus a stroked `oval` bubble; \(shapes.count) shape(s) \
      survived. One means the triangle was dropped and the outline is a lone circle off the \
      gate's nose — the defect the first draft of clause 1 had. More than two means something \
      that is not part of the gate's outline is being traced — two more, and it is the two port \
      markers, i.e. clause 2a has stopped firing.
      """)
    // …and the traced union must actually span the gate, which is what makes "two shapes" mean
    // the right two. Against the gate's own shape extent, NOT against `group.bounds`; see
    // `bodyExtent`. A NOT gate's two port markers stick out past both ends of it, so measuring
    // the trace against a box that includes them asks the trace to cover geometry it is
    // correctly refusing to trace.
    let width = bodyExtent(group, scene).width
    var union = CGRect.null
    for shape in shapes { union = union.union(shape.worldBounds) }
    #expect(
      union.width >= width * 0.9,
      "the traced shapes span \(union.width) of the gate's \(width) — they are not its outline")
  }

  /// **Clause 1, the other half.** An AND gate's three straight sides are an OPEN polyline, and
  /// closing them would draw a line straight down the middle of the gate.
  @MainActor
  @Test("an AND gate's open polyline stays open")
  func andGateSideIsNotClosed() throws {
    let (silhouette, _, _) = try silhouetteFixture(of: AndGate.factory)
    guard case .body(let shapes) = silhouette else {
      Issue.record("an AND gate fell back to a box")
      return
    }
    let hasOpenPolyline = shapes.contains {
      if case .polyline = $0.form { return true }
      return false
    }
    let hasClosedPolygon = shapes.contains {
      if case .polygon = $0.form { return true }
      return false
    }
    #expect(
      hasOpenPolyline && !hasClosedPolygon,
      """
      an AND gate's body is `drawArc` + an OPEN `drawPolyline`; promoting that polyline to a \
      closed polygon draws a chord across the gate's face
      """)
  }

  /// **Clause 2a.** A port marker is where the component connects, not where it ends.
  ///
  /// The fixture is deliberately the NEW-appearance Pin, and that is the whole test. This was
  /// first written against the classic Pin and **did not redden** when the clause was removed: a
  /// classic Pin is a rectangle whose bounds already enclose its port dot, so clause 3 dropped
  /// the dot and covered for the missing clause. The new-appearance Pin's port sits at the tip
  /// of the arrow, OUTSIDE the pentagon's bounds, so clause 3 cannot reach it and clause 2a is
  /// the only thing standing between the user and a little blue ring on the pin. Found by
  /// red-probing, which is the only reason the weakness was visible at all.
  ///
  /// ── WHY THIS TEST NO LONGER MENTIONS FILLS ─────────────────────────────────────────────────
  ///
  /// It used to say "every port marker is a `fillOval`" and check that no traced shape was
  /// marker-*sized*. Both halves were statements about the marker's current styling, and both
  /// broke the day the marker became a ring:
  ///
  ///   * the fixture guard looked for a FILL outside the stroked extent. A ring's rim is a stroke
  ///     that encloses its own hole, so the guard found nothing and the test declared its own
  ///     fixture inadequate, while the very defect it was written to catch was live.
  ///   * the size check (`> 8` units) was a proxy for "not a marker" that cannot be made to
  ///     work: `drawDongle` is a 9-unit `drawOval` and the biggest marker is 12, so any
  ///     threshold either admits markers or rejects a NOT gate's bubble.
  ///
  /// Both are now stated in terms of the component's own PORT LOCATIONS, which is a fact about
  /// the circuit rather than about this week's marker styling, so this test says the same thing
  /// whatever shape the marker is next drawn in, which is the property the ring collision was
  /// about.
  @MainActor
  @Test("port markers are ink, not boundary, and are never traced")
  func portMarkersAreNotTraced() throws {
    let (silhouette, group, scene, component) = try silhouetteFixtureWithComponent(
      of: Pin.factory, newPinAppearance: true)

    let ports = component.ends.map {
      CGPoint(x: CGFloat($0.location.x), y: CGFloat($0.location.y))
    }
    #expect(!ports.isEmpty, "a Pin with no ends cannot have a port marker")

    /// Centred on one of the component's ports. Half a unit of slack, not a size band: a marker
    /// is centred on its port by construction (`drawPinMarker` takes the port as its centre and
    /// stroke inflation is symmetric), and nothing else this Pin draws is; the pentagon's
    /// centre is offset because the port is at the arrow's TIP.
    func isAtAPort(_ box: CGRect) -> Bool {
      guard !box.isNull else { return false }
      return ports.contains { abs(box.midX - $0.x) <= 0.5 && abs(box.midY - $0.y) <= 0.5 }
    }

    // Fixture adequacy, in two parts, neither of which consults `isBodyOutline`: a guard that
    // asks the rule under test whether the fixture is adequate answers differently once the rule
    // is broken, and this one did, hiding the very probe that found the weakness.
    let markerPrimitives = group.range.map { scene.primitives[$0] }
      .filter { isAtAPort(worldBox($0)) }
    #expect(
      !markerPrimitives.isEmpty,
      "the fixture draws nothing centred on its port, so there is no marker to reject")

    // …and clause 3 must not be able to cover for clause 2a. Stated as clause 3's own literal
    // condition, "a shape whose bounds sit inside ANOTHER SHAPE's bounds is interior detail",
    // rather than as containment in the union of everything the component draws. The union is a
    // stricter test than clause 3 applies, and the difference is not academic: the union
    // includes the Pin's stub `line`, which reaches all the way to the port, and a marker small
    // enough to hide inside it would make this guard declare the fixture inadequate for a
    // component clause 3 could not actually reach. Lines and lettering are excluded here for the
    // same reason clause 3 never sees them: they are not candidate shapes.
    let otherShapes = group.range.map { scene.primitives[$0] }
      .filter { !isAtAPort(worldBox($0)) }
      .filter { $0.kind != .line && !SelectionSilhouette.isLettering($0) }
    #expect(
      markerPrimitives.contains { marker in
        !otherShapes.contains { worldBox($0).contains(worldBox(marker)) }
      },
      """
      every primitive at the Pin's port is enclosed by one of the component's own shapes, so \
      clause 3 would drop it anyway and this test cannot tell whether clause 2a is doing anything
      """)

    // The mechanism: the emitter tagged them. If this fails, `drawPinMarker` stopped stamping
    // `.connectionMarker` and the outcome assertion below is passing for some other reason.
    #expect(
      markerPrimitives.allSatisfy { SelectionSilhouette.isConnectionMarker($0) },
      "a primitive at the port is not tagged `.connectionMarker`; the role stamp was lost")

    // The outcome.
    guard case .body(let shapes) = silhouette else {
      Issue.record("a Pin fell back to a box")
      return
    }
    for shape in shapes {
      #expect(
        !isAtAPort(shape.worldBounds),
        """
        a shape centred on the Pin's port was traced (\(shape.worldBounds)) — that is the port \
        marker, and the user sees a little blue ring sitting on the pin
        """)
    }
  }

  /// **Clause 3.** A flip-flop's clock wedge is a polyline inside its body rectangle.
  @MainActor
  @Test("interior detail inside a body is not traced")
  func interiorDetailIsNotTraced() throws {
    let factory = try #require(builtinFactory(named: "D Flip-Flop"))
    let (silhouette, group, scene) = try silhouetteFixture(of: factory)

    // Count what clause 1+2 would have admitted, so the drop is demonstrated rather than assumed.
    let admitted = group.range.filter { SelectionSilhouette.isBodyOutline(scene.primitives[$0]) }
      .count
    #expect(admitted > shapeCount(silhouette), "nothing was dropped, so clause 3 did nothing here")
    #expect(shapeCount(silhouette) > 0, "a D flip-flop should still be traced")
  }

  /// **Clause 4.** The TTL case the brief warned about, measured rather than assumed.
  @MainActor
  @Test("a TTL chip falls back to its box rather than outlining fourteen pin legs")
  func aTtlChipFallsBackToItsBox() throws {
    let factory = try #require(builtinFactory(named: "7408"))
    let (silhouette, group, scene) = try silhouetteFixture(of: factory)
    #expect(
      silhouette == .bounds,
      """
      a 7408 was traced with \(shapeCount(silhouette)) shapes. Its body, its notch and its \
      fourteen pin legs all survive clause 3 because the legs stick out of the body, so tracing \
      it draws a tangle rather than a silhouette.
      """)
    // The cap must be what rejected it, not an empty candidate list; otherwise this test would
    // keep passing if the whole rule broke.
    let admitted = group.range.filter { SelectionSilhouette.isBodyOutline(scene.primitives[$0]) }
      .count
    #expect(
      admitted > SelectionSilhouette.maxShapes,
      "a 7408 offered only \(admitted) body outlines, so the legibility cap is not what fired")
  }

  /// **Clause 5.** Without it, a Transistor is marked by its gate circle alone.
  @MainActor
  @Test("a component whose only closed shape is a detail keeps its box")
  func aComponentWhoseOnlyShapeIsADetailFallsBack() throws {
    let factory = try #require(builtinFactory(named: "Transistor"))
    let (silhouette, group, scene) = try silhouetteFixture(of: factory)
    #expect(
      silhouette == .bounds,
      "a Transistor was traced by \(shapeCount(silhouette)) shape(s) — its body is all `line`s")

    // Prove clause 5 is what rejected it: there IS a candidate, it just does not represent the
    // part. Without this the test would pass against a rule that had stopped finding anything.
    var candidates: [SelectionBodyShape] = []
    var extent = CGRect.null
    for index in group.range {
      let primitive = scene.primitives[index]
      if SelectionSilhouette.isLettering(primitive) { continue }
      let b = primitive.bounds
      if !b.isEmpty {
        extent = extent.union(
          CGRect(
            x: CGFloat(b.minX), y: CGFloat(b.minY),
            width: CGFloat(b.width), height: CGFloat(b.height)))
      }
      if SelectionSilhouette.isBodyOutline(primitive),
        let shape = SelectionSilhouette.bodyShape(of: primitive, in: scene)
      {
        candidates.append(shape)
      }
    }
    #expect(candidates.count == 1, "the fixture no longer has the lone stroked oval")
    let cover = SelectionSilhouette.coverage(of: candidates, over: extent)
    #expect(
      cover < SelectionSilhouette.minimumCoverage,
      "the lone shape covers \(cover) of the part, so clause 5 is not what rejected it")
  }

  /// A wire has no geometry of its own, the whole wire layer shares one group, so it must take
  /// the rectangle path, where `selectionOutline` gives it the thickness it needs to be seen.
  @MainActor
  @Test("a wire has no group of its own and therefore no silhouette")
  func aWireHasNoSilhouette() throws {
    StdLibraries.registerAll()
    let circuit = try Circuit(name: "wire")
    try circuit.mutatorAdd(
      Wire.create(
        Location.create(100, 100, hasToSnap: false),
        Location.create(200, 100, hasToSnap: false)))
    let build = CircuitSceneSource.build(circuit: circuit, appearance: CanvasAppearance())
    let byTag = SelectionSilhouette.groupsByTag(in: build.scene)
    #expect(
      byTag[1] == nil,
      """
      a wire now has a component-tagged scene group. That is not automatically wrong, but the \
      selection code assumes it does not and hands wires to `selectionOutline` instead — if this \
      changed, `SelectionOutlineTests`' wire case has stopped being reachable.
      """)
    #expect(
      !byTag.keys.contains(CircuitRenderer.wireGroupTag),
      "the shared wire-layer group leaked into the per-component map")
  }
}

// MARK: - Path construction

@Suite("Selection silhouette — the path that gets stroked")
struct SelectionSilhouettePathTests {

  /// The geometry is only worth having if the path actually lands on the component. This checks
  /// the whole chain, primitive → shape → view-space `CGPath`, against the camera.
  @MainActor
  @Test("the stroked path lands on the component, at the camera's scale")
  func thePathLandsOnTheComponent() throws {
    let (silhouette, group, _) = try silhouetteFixture(
      of: Pin.factory, newPinAppearance: true)
    guard case .body(let shapes) = silhouette else {
      Issue.record("a Pin fell back to a box")
      return
    }
    let zoom: CGFloat = 2
    let camera = CGAffineTransform(scaleX: zoom, y: zoom)
    let path = SelectionSilhouette.path(for: shapes, worldToView: camera)
    #expect(!path.isEmpty, "the traced path is empty, so nothing would be stroked")

    let world = CGRect(
      x: CGFloat(group.bounds.minX), y: CGFloat(group.bounds.minY),
      width: CGFloat(group.bounds.width), height: CGFloat(group.bounds.height))
    let expected = world.applying(camera)
    let box = path.boundingBox
    #expect(
      expected.insetBy(dx: -2 * zoom, dy: -2 * zoom).contains(box),
      "the path \(box) is not inside the component's own extent \(expected) — it is misplaced")
    #expect(
      box.width >= expected.width * 0.5 && box.height >= expected.height * 0.5,
      "the path \(box) is far smaller than the component \(expected)")
  }

  /// **The arc.** An AND gate's body is an `arc` plus an open `polyline`: the polyline is the
  /// three straight sides and the arc is the whole curved right-hand face. If the arc never
  /// reaches the path, the outline is an open U that stops halfway across the gate.
  ///
  /// **Added because a red probe found nothing.** Deleting the `.arc` case from
  /// `SelectionSilhouette.path` left the entire suite green; every other assertion is about
  /// *which shapes survive the rule*, and the arc survives it perfectly well; the loss was in the
  /// step after, turning shapes into geometry. A probe that reddens nothing is a finding, and
  /// this is what it found.
  @MainActor
  @Test("an AND gate's traced path reaches its curved right-hand face")
  func theArcReachesTheStrokedPath() throws {
    let (silhouette, group, scene) = try silhouetteFixture(of: AndGate.factory)
    guard case .body(let shapes) = silhouette else {
      Issue.record("an AND gate fell back to a box")
      return
    }
    // The fixture must contain an arc, or this asserts nothing about arcs.
    #expect(
      shapes.contains {
        if case .arc = $0.form { return true }
        return false
      },
      "the AND gate fixture has no arc; `PainterShaped` must have changed")

    let path = SelectionSilhouette.path(for: shapes, worldToView: .identity)
    // The gate's own right-hand face, not `group.bounds.maxX`; see `bodyExtent`. An AND gate's
    // output port sits ON the rightmost point of the arc, so its marker always protrudes past
    // the face by whatever the marker's radius happens to be that week. Measuring the arc's
    // reach against a box the marker widened made this assertion fail by one unit when the
    // marker was restyled, with nothing about the arc or the path having changed.
    let gateRight = bodyExtent(group, scene).maxX
    #expect(
      path.boundingBox.maxX >= gateRight - 3,
      """
      the traced path reaches x=\(path.boundingBox.maxX) but the gate's curved face is at \
      x=\(gateRight). The arc is missing from the path, so the outline stops in the middle of \
      the gate and hangs open.
      """)
  }

  /// An empty shape list must produce an empty path rather than a stray subpath at the origin:
  /// the draw site guards on `path.isEmpty`, and a path with a phantom `moveTo` is not empty.
  @MainActor
  @Test("no shapes produces no path")
  func noShapesProducesNoPath() {
    #expect(SelectionSilhouette.path(for: [], worldToView: .identity).isEmpty)
  }

  /// A `GeneralPath` that opens with a `lineTo` is malformed, and `CGPath` traps on one. The
  /// canvas must not be a place where a bad component definition crashes the app.
  @MainActor
  @Test("a path that opens with a line does not trap")
  func aLeadingLineOpIsPromotedToAMove() {
    let shape = SelectionBodyShape(
      form: .path([.line(10, 10), .line(20, 20), .close]),
      transform: .identity,
      worldBounds: CGRect(x: 10, y: 10, width: 10, height: 10))
    let path = SelectionSilhouette.path(for: [shape], worldToView: .identity)
    #expect(!path.isEmpty)
  }
}

// MARK: - The whole builtin corpus

@Suite("Selection silhouette — every builtin component")
struct SelectionSilhouetteCorpusTests {

  /// The census that keeps the rule honest.
  ///
  /// Every clause here is a *threshold on the whole corpus*, not a single component, because
  /// every failure this rule has actually had was invisible on the component that motivated it
  /// and obvious across the set. In particular the lower bound on how many components get traced
  /// is what would redden if a future change quietly disabled tracing; the shape of failure
  /// that leaves a suite green because everything "still passes" with a box everywhere.
  @MainActor
  @Test("the corpus census: what is traced, what falls back, and how well it covers")
  func corpusCensus() throws {
    StdLibraries.registerAll()
    let libraryIds = [
      Builtin.gatesId, Builtin.wiringId, Builtin.arithmeticId, Builtin.memoryId,
      Builtin.ioId, Builtin.ttlId, Builtin.plexersId, Builtin.extraIoId, Builtin.fpArithmeticId,
    ]

    var traced = 0
    var fellBack = 0
    var drewNothing: [String] = []
    var worstTracedCoverage: (name: String, coverage: CGFloat) = ("", 1)

    for libraryId in libraryIds {
      for tool in BuiltinToolProviders.tools(forLibraryId: libraryId) {
        guard let add = tool as? AddTool else { continue }
        let factory = add.factory
        let circuit = try Circuit(name: "corpus")
        let attributes = factory.createAttributeSet()
        guard
          let component = try? factory.createComponent(
            location: Location.create(200, 200, hasToSnap: false), attributes: attributes)
        else { continue }
        try? circuit.mutatorAdd(component)
        guard !circuit.components.isEmpty else { continue }

        let build = CircuitSceneSource.build(circuit: circuit, appearance: CanvasAppearance())
        guard let group = SelectionSilhouette.groupsByTag(in: build.scene)[1] else {
          drewNothing.append(factory.name)
          continue
        }
        switch SelectionSilhouette.of(group: group, in: build.scene) {
        case .bounds:
          fellBack += 1
        case .body(let shapes):
          traced += 1
          // The SAME denominator clause 5 uses: lettering out, connection markers out. This
          // used to include markers while the rule excluded only lettering, so the number this
          // test reported was not the number the rule acted on, and the assertion below was
          // measuring a different quantity from the one it names.
          let cover = SelectionSilhouette.coverage(
            of: shapes, over: bodyExtent(group, build.scene))
          if cover < worstTracedCoverage.coverage {
            worstTracedCoverage = (factory.name, cover)
          }
          // The path has to be buildable for every one of them; a component that produced an
          // empty path would be selected and show nothing at all.
          let path = SelectionSilhouette.path(for: shapes, worldToView: .identity)
          #expect(!path.isEmpty, "\(factory.name) traced \(shapes.count) shapes into an empty path")
        }
      }
    }

    #expect(
      traced >= 30,
      """
      only \(traced) builtin components are traced by their own silhouette (was 42 when this was \
      written). A collapse here means the rule has stopped finding geometry and everything is \
      quietly getting a box again — which is the reported defect, restored, with a green suite.
      """)
    #expect(
      fellBack >= 60,
      """
      only \(fellBack) components fall back to a box (was 77). The TTL family alone is 70 of \
      them; if that number drops, the legibility cap has stopped firing and every 74xx chip is \
      being outlined leg by leg.
      """)
    #expect(
      worstTracedCoverage.coverage >= SelectionSilhouette.minimumCoverage,
      """
      \(worstTracedCoverage.name) is traced at coverage \(worstTracedCoverage.coverage), below \
      the floor — clause 5 is not being applied on the path the canvas takes.
      """)

    // ── THE EMPTY BAND, WHICH IS THE ONLY THING THAT JUSTIFIES 0.7 ────────────────────────────
    //
    // `minimumCoverage`'s comment says 0.7 sits INSIDE an empty band: the misfires this clause
    // catches are at 0.23–0.24, the components whose survivor really is their body start at 0.76
    // (`Pull Resistor`), and nothing traced lands in between. A bare `>= 0.7` cannot tell a
    // healthy corpus from one that has drifted down to touch the threshold, and drift is the
    // failure mode here: it does not break anything today, it just moves everything one small
    // change away from silently falling back to boxes.
    //
    // This is not hypothetical, and it is why the band is pinned rather than described. Leaving
    // connection markers in clause 5's denominator, which is how the rule read until the port
    // marker became a ring, puts `Pull Resistor` at 0.722. Still "passing", two points off the
    // floor, with nothing about any component's body having changed. That reads as green and is
    // not.
    #expect(
      worstTracedCoverage.coverage >= 0.75,
      """
      \(worstTracedCoverage.name) is traced at \(worstTracedCoverage.coverage), inside the band \
      that `minimumCoverage` documents as EMPTY (0.7 to 0.76). The threshold is only defensible \
      while the two populations are separated; something has moved the traced population down \
      toward the floor. Find out what, rather than lowering this.
      """)

    // NOT AN ASSERTION ABOUT THIS CHANGE: a standing note about a defect this sweep found.
    // See the report: the arithmetic, plexer and FP-arithmetic factories declare
    // `paintInstance(SceneBuilder, InstanceState)`, which does not satisfy
    // `InstancePaintable.paintInstance(InstancePainter)`, so `CircuitRenderer` skips them and
    // they draw nothing at all. They are counted, not asserted on, because the fix is not in
    // this file and pinning the number here would make someone else's fix red.
    if !drewNothing.isEmpty {
      print(
        "NOTE: \(drewNothing.count) builtin components draw no primitives at all: "
          + drewNothing.sorted().joined(separator: ", "))
    }
  }
}
