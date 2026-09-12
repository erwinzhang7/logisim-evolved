// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution, which is GPL-3.0-only. This port is a derivative work and is
// therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE SELECTION OUTLINE FOLLOWS THE MOVE PREVIEW, AND KEEPS THE COMPONENT'S SHAPE WHILE IT DOES.
//
// ── Where this came from ────────────────────────────────────────────────────────────────────
//
// Reported from real use, dragging a Pin: "the drag got worse not better. the highlight is not
// following the dragging preview. nor is it fitted to the object. u see how the input is like a
// sideways home plate? make the blue selected indicator the same shape."
//
// Two complaints, ONE cause, and the cause is not in the silhouette rule. A move preview hides
// the originals so the ghost is not drawn on top of them: `SelectTool.getHiddenComponents`, and
// `CanvasHiddenComponentTests` gates that it really removes their primitives. Removing their
// primitives removes their `SceneGroup`, and a `SceneGroup` is where `SelectionSilhouette` reads
// a component's shape from. So the moment the drag began:
//
//   * `groupsByTag` had no entry, the silhouette fell through to `.bounds` → a RECTANGLE;
//   * `.bounds` was `build.targets[…].bounds`, the committed position → LEFT BEHIND.
//
// `SelectionSilhouetteTests` passes throughout, because it never hides anything. That is the
// point of this file: the rule was right and was not being asked.
//
// ── Why these tests drive the surface ───────────────────────────────────────────────────────
//
// Because the fix is an ORDERING, and an ordering is invisible to a test that calls the pieces in
// its own order. `CircuitCanvasSurface.setToolOverlay` must capture the geometry *before* the
// rebuild that deletes it; move the capture two lines down and nothing fails to compile, nothing
// throws, and the capture is silently empty. So the tests below push a hidden set through the
// real `setToolOverlay` and then ask the real view what it will draw.
//
// And they ask it through `CircuitSceneView.selectionPath(for:camera:)`, the function
// `drawAdornments` itself calls, rather than rebuilding the trace-or-box decision here. A test
// that re-implements the thing it measures is free to agree with the canvas or not; this project
// has already paid for that once, in the corpus census that built its own clause-5 denominator.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import CoreGraphics
import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimStd
import Testing

@testable import LogisimUI

// MARK: - Fixture

/// A circuit holding one input Pin in the shipped appearance, plus a TTL chip.
///
/// Two components, because the two arms of the fix are different code: a Pin is TRACED (it is
/// the reported component, and its pentagon is what "fitted to the object" means) and a 7408
/// FALLS BACK to its box (clause 4; fourteen pin legs). Both have to follow the drag, and a fix
/// that only moved the traced arm would leave every boxed component behind.
@MainActor
private func dragFixture() throws -> (Circuit, pin: any Component, chip: any Component) {
  StdLibraries.registerAll()
  let circuit = try Circuit(name: "drag")

  let pinAttributes = Pin.factory.createAttributeSet()
  // The shipped default (`AppPreferences.NEW_INPUT_OUTPUT_SHAPES` = true), set explicitly because
  // a headless test loads no preferences and the CLASSIC pin really is a rectangle, which would
  // pass the "is it a pentagon" assertion for entirely the wrong reason.
  try pinAttributes.setValue(
    LogisimStd.ProbeAttributes.probeAppearance,
    LogisimStd.ProbeAttributes.appearEvolutionNew)
  let pin = try Pin.factory.createComponent(
    location: Location.create(200, 200, hasToSnap: false), attributes: pinAttributes)
  try circuit.mutatorAdd(pin)

  let chipFactory = try #require(ttlFactory(named: "7408"), "the TTL library has no 7408")
  let chip = try chipFactory.createComponent(
    location: Location.create(400, 400, hasToSnap: false),
    attributes: chipFactory.createAttributeSet())
  try circuit.mutatorAdd(chip)

  return (circuit, pin: pin, chip: chip)
}

@MainActor
private func ttlFactory(named name: String) -> (any ComponentFactory)? {
  for tool in BuiltinToolProviders.tools(forLibraryId: Builtin.ttlId) {
    guard let add = tool as? AddTool else { continue }
    if add.factory.name == name { return add.factory }
  }
  return nil
}

/// A surface with the fixture loaded and both components selected, plus the view it draws into.
@MainActor
private func loadedSurface() throws -> (
  CircuitCanvasSurface, CircuitSceneView, pin: any Component, chip: any Component
) {
  let (circuit, pin, chip) = try dragFixture()
  let surface = CircuitCanvasSurface()
  surface.setCircuit(circuit)
  let view = try #require(
    surface.renderView as? CircuitSceneView, "the surface's render view is not the scene view")
  surface.setSelection(
    [CircuitSceneSource.identity(of: pin), CircuitSceneSource.identity(of: chip)], haloed: nil)
  return (surface, view, pin: pin, chip: chip)
}

/// A deliberately non-unit camera. **Load-bearing:** the drag delta is in WORLD units, so it must
/// compose before the camera. At scale 1 an offset applied on the wrong side of the camera lands
/// in exactly the same place, so a unit camera cannot tell a correct fix from that one, and 100%
/// zoom is the only configuration anyone checks by hand.
private let camera = CGAffineTransform(scaleX: 3, y: 3)

/// The world delta the ghosts are drawn at, in the test.
private let dragDelta = CGSize(width: 40, height: 25)

/// Push one frame of a move preview through the real surface, exactly as
/// `CircuitEditorCanvas.renderOverlay` does.
@MainActor
private func beginDrag(
  _ surface: CircuitCanvasSurface, hiding components: [any Component], by offset: CGSize
) {
  surface.setToolOverlay(
    items: .empty, poke: nil,
    hidden: Set(components.map(ComponentRef.init)),
    previewOffset: offset)
}

// MARK: - Tests

@Suite("Selection outline — through a move preview")
@MainActor
struct SelectionFollowsDragTests {

  /// **The calibration, and without it every test below is vacuous.** It states the mechanism the
  /// defect came from: hiding a component takes its `SceneGroup` away, so anything reading the
  /// live build for its shape can only answer "rectangle". If a future change stops hiding the
  /// originals, this goes red and the rest of the file stops meaning anything, which is the
  /// signal wanted, because the fix would then be unnecessary rather than working.
  @Test("hiding a component really does take its shape out of the scene")
  func hidingRemovesTheShapeFromTheScene() throws {
    let (circuit, pin, _) = try dragFixture()
    let appearance = CanvasAppearance()
    let pinID = CircuitSceneSource.identity(of: pin)

    let visible = CircuitSceneSource.build(circuit: circuit, appearance: appearance)
    let index = try #require(visible.indexByID[pinID])
    #expect(
      SelectionSilhouette.groupsByTag(in: visible.scene)[UInt64(index + 1)] != nil,
      "the Pin has no scene group even when visible; this fixture cannot show anything")

    let hidden = CircuitSceneSource.build(
      circuit: circuit, appearance: appearance, hidden: [pinID])
    #expect(
      SelectionSilhouette.groupsByTag(in: hidden.scene)[UInt64(index + 1)] == nil,
      """
      a hidden Pin still has a scene group, so the defect's mechanism is gone and these tests \
      are measuring nothing.
      """)
    // The hit target survives, which is why the defect was a BOX and not a disappearance: the
    // rectangle fallback still had bounds to draw, at the unshifted position.
    #expect(hidden.indexByID[pinID] == index, "the target table stopped being index-aligned")
  }

  /// **Defect half one: the shape.** Mid-drag the outline must still be the Pin's pentagon.
  @Test("a dragged Pin keeps its pentagon instead of collapsing to a box")
  func aDraggedPinKeepsItsShape() throws {
    let (surface, view, pin, _) = try loadedSurface()
    beginDrag(surface, hiding: [pin], by: dragDelta)

    let adornment = try #require(
      view.selectionAdornment(for: CircuitSceneSource.identity(of: pin)))
    guard case .body(let shapes) = adornment.silhouette else {
      Issue.record(
        """
        the dragged Pin fell back to its bounding box. This is the reported defect: the outline \
        is traced from the component's scene group, the move preview hides the component, and a \
        hidden component has no scene group — so the shape has to be captured before the rebuild \
        that hides it.
        """)
      return
    }
    #expect(shapes.count == 1, "a Pin has one body shape; got \(shapes.count)")
    guard case .polygon(let points) = shapes[0].form else {
      Issue.record("the dragged Pin traced \(shapes[0].form), not `drawInputShape`'s polygon")
      return
    }
    #expect(points.count == 5, "the outline has \(points.count) corners, not the arrow's five")
  }

  /// **Defect half two: the position.** The outline must move with the ghost, by the drag delta
  /// scaled by the camera.
  @Test("a dragged Pin's outline moves with the ghost, in world units")
  func aDraggedPinsOutlineFollowsTheGhost() throws {
    let (surface, view, pin, _) = try loadedSurface()
    let pinID = CircuitSceneSource.identity(of: pin)

    let atRest = try #require(view.selectionPath(for: pinID, camera: camera)?.boundingBox)
    beginDrag(surface, hiding: [pin], by: dragDelta)
    let dragged = try #require(view.selectionPath(for: pinID, camera: camera)?.boundingBox)

    let moved = CGSize(width: dragged.minX - atRest.minX, height: dragged.minY - atRest.minY)
    #expect(
      abs(moved.width - dragDelta.width * 3) < 0.001
        && abs(moved.height - dragDelta.height * 3) < 0.001,
      """
      the outline moved by \(moved) and the ghost moved by \
      \(CGSize(width: dragDelta.width * 3, height: dragDelta.height * 3)) at this camera. \
      A move of (0, 0) is the reported defect — the outline left behind at the committed \
      position. A move of \(dragDelta) is the delta applied AFTER the camera instead of before \
      it, which is right only at 100% zoom.
      """)
    #expect(
      dragged.size.width == atRest.size.width && dragged.size.height == atRest.size.height,
      "the outline changed size as well as position: \(atRest.size) → \(dragged.size)")
  }

  /// The other arm. A 7408 is boxed by clause 4 and must follow the drag *as a box*; a fix that
  /// only moved the traced shapes would leave every fallback component behind, which is most of
  /// them.
  @Test("a component that falls back to its box drags its box along")
  func aBoxedComponentAlsoFollows() throws {
    let (surface, view, _, chip) = try loadedSurface()
    let chipID = CircuitSceneSource.identity(of: chip)

    let atRest = try #require(view.selectionAdornment(for: chipID))
    #expect(
      atRest.silhouette == .bounds,
      """
      the 7408 is being traced, so this test is exercising the same arm as the Pin's and gates \
      nothing extra. Pick a component that clause 4 still boxes.
      """)

    let restBox = try #require(view.selectionPath(for: chipID, camera: camera)?.boundingBox)
    beginDrag(surface, hiding: [chip], by: dragDelta)
    let draggedBox = try #require(view.selectionPath(for: chipID, camera: camera)?.boundingBox)

    #expect(
      abs((draggedBox.minX - restBox.minX) - dragDelta.width * 3) < 0.001
        && abs((draggedBox.minY - restBox.minY) - dragDelta.height * 3) < 0.001,
      "the boxed component's outline stayed at \(restBox) while its ghost moved by \(dragDelta)")
  }

  /// **The calibration for the two tests above.** With nothing hidden, the outline must not move
  /// ; otherwise "it follows the drag" could be satisfied by an outline that is simply displaced
  /// all the time, and both would still pass.
  @Test("with no drag in progress the outline does not move and is still traced")
  func nothingMovesWhenNothingIsDragged() throws {
    let (surface, view, pin, _) = try loadedSurface()
    let pinID = CircuitSceneSource.identity(of: pin)
    let before = try #require(view.selectionPath(for: pinID, camera: camera)?.boundingBox)

    // A frame of a tool that hides nothing: a marquee, a pending wire, an idle pointer.
    beginDrag(surface, hiding: [], by: .zero)

    let after = try #require(view.selectionPath(for: pinID, camera: camera)?.boundingBox)
    #expect(after == before, "the outline moved with no drag in progress: \(before) → \(after)")
    let adornment = try #require(view.selectionAdornment(for: pinID))
    #expect(adornment.offset == .zero, "a non-zero drag offset survived with nothing hidden")
    if case .bounds = adornment.silhouette {
      Issue.record("the undragged Pin is boxed, so the pentagon assertions prove nothing")
    }
  }

  /// **The one that stops the fix from being worse than the defect.** When the drag commits, the
  /// components come back into the scene at their NEW positions, so a capture that outlived the
  /// gesture would draw the outline shifted a second time, twice as far as the component went.
  @Test("the capture is dropped when the drag ends")
  func theCaptureIsDroppedWhenTheDragEnds() throws {
    let (surface, view, pin, _) = try loadedSurface()
    let pinID = CircuitSceneSource.identity(of: pin)
    let before = try #require(view.selectionPath(for: pinID, camera: camera)?.boundingBox)

    beginDrag(surface, hiding: [pin], by: dragDelta)
    #expect(view.dragPreview != nil, "the drag was never captured, so the release proves nothing")

    // Mouse up: the tool hides nothing any more. (The commit itself moves the component; this
    // fixture does not, which is exactly what makes the double-shift visible if it happens.)
    beginDrag(surface, hiding: [], by: .zero)

    #expect(view.dragPreview == nil, "the capture outlived the gesture")
    let after = try #require(view.selectionPath(for: pinID, camera: camera)?.boundingBox)
    #expect(
      after == before,
      """
      the outline stayed displaced after the drag ended: \(before) → \(after). A capture that is \
      not dropped applies the last delta forever, on top of the component's new position.
      """)
  }

  /// The attention halo marks the component the inspector is showing, which, during a drag, is
  /// almost always the component being dragged. It reads its rectangle through the same
  /// adornment, so it moves for the same reason; asserted rather than assumed, because the two
  /// used to read `build.targets` separately and only one of them would have been fixed.
  @Test("the attention halo follows the drag as well")
  func theHaloFollowsTheDrag() throws {
    let (surface, view, pin, _) = try loadedSurface()
    let pinID = CircuitSceneSource.identity(of: pin)
    surface.setSelection([pinID], haloed: pinID)

    let atRest = try #require(view.haloRect(camera: camera))
    beginDrag(surface, hiding: [pin], by: dragDelta)
    let dragged = try #require(view.haloRect(camera: camera))

    #expect(
      abs((dragged.minX - atRest.minX) - dragDelta.width * 3) < 0.001
        && abs((dragged.minY - atRest.minY) - dragDelta.height * 3) < 0.001,
      "the halo stayed at \(atRest) while the component's ghost moved by \(dragDelta)")
  }

  /// The calibration for it: with nothing haloed there is no rectangle at all, so the test above
  /// cannot be passing on a stale or invented one.
  @Test("nothing haloed means no halo rectangle")
  func noHaloWhenNothingIsHaloed() throws {
    let (surface, view, pin, _) = try loadedSurface()
    surface.setSelection([CircuitSceneSource.identity(of: pin)], haloed: nil)
    #expect(view.haloRect(camera: camera) == nil)
  }

  /// A preview that gains a rerouted wire mid-gesture must not lose the capture it already has.
  /// `SelectTool.hiddenComponents` adds the move engine's removals to the hidden set as the
  /// preview resolves, so the set genuinely changes shape during one drag, and re-capturing at
  /// that moment would read a component whose geometry has already gone.
  @Test("a hidden set that grows mid-drag keeps the captures it already has")
  func aGrowingHiddenSetKeepsEarlierCaptures() throws {
    let (surface, view, pin, chip) = try loadedSurface()
    let pinID = CircuitSceneSource.identity(of: pin)

    beginDrag(surface, hiding: [pin], by: dragDelta)
    let firstFrame = try #require(view.selectionPath(for: pinID, camera: camera)?.boundingBox)

    // The engine resolves a reroute: a second component joins the hidden set.
    beginDrag(surface, hiding: [pin, chip], by: dragDelta)
    let secondFrame = try #require(view.selectionPath(for: pinID, camera: camera)?.boundingBox)

    #expect(
      secondFrame == firstFrame,
      """
      the Pin's outline changed when an unrelated component joined the hidden set: \
      \(firstFrame) → \(secondFrame). Its capture was overwritten by a re-read of a scene it is \
      no longer in, which yields the bounding box.
      """)
    let adornment = try #require(view.selectionAdornment(for: pinID))
    if case .bounds = adornment.silhouette {
      Issue.record("the Pin's captured pentagon was replaced by a box on the second frame")
    }
  }
}

// MARK: - The delta's source

@Suite("ToolOverlay.previewOffset")
@MainActor
struct ToolOverlayPreviewOffsetTests {

  /// The seam between the tool and the surface. `SelectTool` puts the delta in
  /// `.selectionGhost`; this is what reads it back out.
  @Test("the move preview's delta is read off the selection ghost")
  func theGhostCarriesTheDelta() {
    let overlay = ToolOverlay(items: [.selectionGhost(dx: 40, dy: -25)])
    #expect(overlay.previewOffset == CGSize(width: 40, height: -25))
  }

  /// An overlay with no move preview reports no offset; otherwise every marquee and pending
  /// wire would displace the selection outline.
  @Test("an overlay with no selection ghost reports no offset")
  func noGhostMeansNoOffset() {
    #expect(ToolOverlay.empty.previewOffset == .zero)
    let marquee = ToolOverlay(items: [.marquee(Bounds.create(0, 0, 40, 40))])
    #expect(marquee.previewOffset == .zero)
  }

  /// Specifically NOT `unsatisfiedConnection`, which carries the same delta for a different
  /// reason and is drawn at both ends. Reading it here would let a red dot move the outline.
  @Test("an unsatisfied-connection marker is not mistaken for the move preview")
  func theUnsatisfiedMarkerIsNotTheGhost() {
    let overlay = ToolOverlay(
      items: [.unsatisfiedConnection(Location.create(10, 10, hasToSnap: false), dx: 40, dy: 25)])
    #expect(overlay.previewOffset == .zero)
  }
}
