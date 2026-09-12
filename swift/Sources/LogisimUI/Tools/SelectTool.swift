// SelectTool.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.tools.SelectTool),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import AppKit
import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.tools.SelectTool`: click, marquee, and drag-with-reroute.
///
/// The three states are upstream's `IDLE`/`MOVING`/`RECT_SELECT`, and which one a press enters is
/// decided by a three-way cascade in `mousePressed` that is easy to get subtly wrong:
///
///   1. pressed **inside the current selection** → move it (or, with the additive modifier, drop
///      the components under the pointer from the selection);
///   2. otherwise pressed **on some component** → replace or extend the selection with it, then
///      move;
///   3. otherwise pressed **on the background** → marquee.
///
/// Each branch may push a `SelectionActions` action before returning, so the undo stack sees the
/// selection change and the move as separate entries, which is what makes "undo" after a
/// mis-drag put the selection back rather than only the geometry.
@MainActor
public final class SelectTool: Tool, CanvasTool {

  /// `_ID`. Declared as `Tool.toolId`, the base class's overridable identity, so the
  /// `.circ` codec in `LogisimFile` can read it without hopping to the main actor.
  /// `CanvasTool.id` is the same string; see `CanvasTool`'s extension.
  public override nonisolated class var toolId: String { "Select Tool" }

  public var displayNameKey: String { "selectTool" }
  public var descriptionKey: String { "selectToolDesc" }

  private enum State {
    case idle
    case moving
    case rectangleSelect
  }

  private var start: Location?
  private var state: State = .idle
  /// The snapped drag delta. `internal` rather than `private` only so a test can name the same
  /// `(dx, dy)` the overlay is being built for; nothing outside this file writes them.
  private(set) var currentDx = 0
  private(set) var currentDy = 0
  private var drawConnections = false
  /// The reroute engine's state for the drag in progress, or nil outside one. Readable for the
  /// same reason `currentDx` is: `DragWirePreviewTests` measures `findResult` against the exact
  /// delta the preview was drawn for, and inferring the gesture from the overlay would measure
  /// the fix rather than the cache it is compensating for.
  private(set) var moveGesture: MoveGesture?

  /// The newest reroute the connector has produced for the drag in progress. See `previewResult`.
  private struct HeldMovePreview {
    /// Weak on purpose, and it is the structural half of "what clears it". A held preview can
    /// then never be drawn for a gesture that no longer exists, even if one of the explicit
    /// clears below is ever missed or a new one is forgotten. The explicit clears still earn
    /// their keep: without them this box keeps a `MoveResult`, and its `ReplacementMap` full of
    /// wires, alive from one drag to the next.
    weak var gesture: MoveGesture?
    let result: MoveResult
  }

  private var heldPreview: HeldMovePreview?

  /// Test seam for `DragWirePreviewClearingTests`: which gesture the held preview belongs to, and
  /// whether anything is held at all. The two differ once a gesture has been released, the weak
  /// reference above goes nil while the box does not, and a clearing test has to see both.
  var heldPreviewGestureForTesting: MoveGesture? { heldPreview?.gesture }
  var isHoldingPreviewForTesting: Bool { heldPreview != nil }

  /// `keyHandlers`: the per-component `KeyConfigurator` clones, rebuilt whenever the selection
  /// changes. Nil means "not built yet"; an empty map means "built, and nothing wants keys".
  private var keyHandlersAreStale = true

  private var selectionSubscription: ToolSubscription?

  /// `AppPreferences.MOVE_KEEP_CONNECT`. D9: pushed in by the shell rather than read from a
  /// preference store down here.
  public var keepsConnectionsWhenMoving = true

  public override init() {}

  public var cursor: NSCursor {
    switch state {
    case .idle: return .arrow
    case .rectangleSelect: return .crosshair
    // `MOVE_CURSOR`. AppKit has no exact equivalent; `openHand` is the platform's
    // "you are dragging this" cursor and is what every native canvas uses.
    case .moving: return .openHand
    }
  }

  public func attributeSet(for canvas: any ToolCanvas) -> (any AttributeSet)? {
    canvas.selection.attributeSet
  }

  /// `isAllDefaultValues` returns true unconditionally upstream (`SelectTool.java:336-338`), which
  /// is what stops the select tool's (nonexistent) prototype attributes being written to a file.
  public var hasOnlyDefaultAttributeValues: Bool { true }

  // MARK: Selection lifecycle

  public func select(_ canvas: any ToolCanvas) {
    // Upstream guards with `selectionsAdded`, a `HashSet<Selection>` that is never removed from:
    // a small permanent leak, and a bug: the guard tests the set but never adds to it, so a
    // listener is registered on every `select`. Holding one subscription and replacing it does
    // what the code meant and unsubscribes the old one (D3).
    selectionSubscription?.invalidate()
    selectionSubscription = canvas.selection.addSelectionListener(self)
  }

  public func deselect(_ canvas: any ToolCanvas) {
    moveGesture = nil
    heldPreview = nil
  }

  // MARK: Overlay

  /// The reroute to draw for the current drag delta; the connector's answer for exactly this
  /// delta when it has one, and otherwise **the answer it has produced for the nearest delta**.
  /// See the last section for why "nearest" and not "most recent", which is what this held before.
  ///
  /// ── A DELIBERATE DIVERGENCE FROM 4.1.0 ──────────────────────────────────────────────────────
  ///
  /// Upstream has no fallback. `MoveGesture.findResult` is a bare `HashMap.get` under the
  /// monitor, and both `SelectTool.draw` and `SelectTool.getHiddenComponents` branch on its null
  /// straight past every piece of drawing (`draw` offsets 76-78 `ifnull 286`;
  /// `getHiddenComponents` offsets 64-66 `ifnull 97`: 4.1.0 jar, `javap -c`). A frame whose
  /// delta the background thread has not reached yet therefore draws no proposed wire **and**
  /// un-hides the wires the reroute would remove, so the old wire flicks back into view.
  ///
  /// That is exactly the reported bug, and it is upstream's too. What hides it upstream is the
  /// paint rate: `CanvasPaintCoordinator.REPAINT_TIMESPANS` caps repaints at a jittered ~20 fps
  /// (`{47, 53, 49, 51, 50, 47, 53, 50, 48, 52}` ms), so most misses resolve inside a frame that
  /// is never painted. This port repaints per event, and the miss becomes visible. Matching
  /// upstream's throttle would hide the flicker without fixing it, and would put a 50 ms floor
  /// under a canvas that does not otherwise need one.
  ///
  /// ── WHY THE HELD RESULT IS DRAWN WHERE IT WAS COMPUTED, NOT SHIFTED ─────────────────────────
  ///
  /// The tempting refinement is to translate the held wires by `current delta - held delta` so
  /// they meet the ghost, which is always at the current delta. That is worse, twice over. Each
  /// proposed wire is anchored at one end to a component that is **not moving**, so shifting it
  /// tears that end off the circuit: and the whole path slides, which for a long route is far
  /// more visible than the few pixels of gap at the other end. And the routes are computed to
  /// *avoid* the components in the way; translating one can push it straight through a gate, so
  /// the preview stops being a route that the drop could actually produce.
  ///
  /// Unshifted, the preview is a real, valid, self-consistent reroute. It lags smoothly; it is
  /// never confidently wrong. The delta it was computed for is still deliberately not stored
  /// beside it; the result is drawn where it was computed, and the *selection* of which cached
  /// answer to draw is made against the gesture's own map, which is keyed by delta already.
  ///
  /// The unsatisfied-connection dots are the one thing that does take the current delta, and for
  /// the same reason: their second dot marks where the moving port is going, so it belongs on the
  /// ghost. Only the *set* of them lags. See the call site.
  ///
  /// ── WHICH ANSWER IS HELD: THE NEAREST, NOT THE LAST ONE READ ────────────────────────────────
  ///
  /// This used to hold "the last result this method returned on a hit", and that rule had a hole
  /// that is the whole of a second reported defect: *"that right bend was prev location so it
  /// maintained that despite increasing height. other direction works fine, if new bend is closer
  /// than the last."*
  ///
  /// The box could only ever be refreshed by a cache hit **at the delta the pointer was sitting on
  /// at that instant**. A drag that outruns the connector never gets one, every frame is a fresh
  /// delta, every fresh delta misses, so the held route stayed pinned at whichever delta last
  /// produced a hit, *for the entire drag*, while the ghost marched away from it. Measured, not
  /// argued: in `WireRerouteAsymmetryTests.heldPreviewAdvancesUnderABurst` the ghost took 25
  /// distinct positions over 25 frames and the preview took **one** shape over all 25; the route
  /// for the first delta. That is not a one-frame lag, it is a freeze, and the bend it freezes at
  /// is exactly "the previous location".
  ///
  /// The other direction "works fine" for a reason that is upstream's, not this port's:
  /// `MoveGesture` caches results per delta, so dragging back over ground the drag has already
  /// covered is a cache **hit** on every frame and is pixel-exact, needing no connector at all.
  /// Only new ground waits. Measured: out-and-back over the same eight deltas matched the
  /// committed route on 0/8 outbound frames and 7/7 return frames.
  ///
  /// The fix is not to stop holding, that is the flicker, back again, and not to translate the
  /// held route onto the ghost, for the two reasons above. It is that the connector never stopped
  /// answering; its answers were landing under deltas nobody asked for a second time. So the
  /// fallback now takes the **nearest** cached answer for this gesture rather than the last one
  /// read (`MoveGesture.nearestResult`). Every candidate is still a real, unshifted, self-
  /// consistent reroute of the same snapshot, so nothing is fabricated; the picture now advances
  /// every time the connector publishes anything, instead of only when it publishes for the one
  /// delta the pointer happens to be on.
  ///
  /// Two things were deliberately **not** done, because both trade away more than they buy:
  ///
  ///   * *Dropping the held result once the pointer moves more than some distance from it.* That
  ///     is a blanking rule with a threshold, and blanking is the flicker. On a circuit slow
  ///     enough to reach the threshold, a lagging preview is exactly what is wanted and a blank
  ///     one is exactly what is not.
  ///   * *Enqueuing drag requests with `priority: true` so the newest delta pre-empts the running
  ///     search.* This looks like the obvious freshness win and is a trap. `ConnectorThread` only
  ///     aborts a search when the override flag is set, and an aborted search **publishes
  ///     nothing** (`Connector.computeWires` returns nil, `ConnectorThread.main` skips
  ///     `notifyResult`). Today every drag request runs to completion and publishes, so the cache
  ///     , and therefore this preview, advances at exactly the rate the connector can compute.
  ///     Under override, a pointer moving faster than one search would abort every search before
  ///     it finished and the cache would never gain another entry: the preview would freeze at the
  ///     first answer permanently, which is a strictly worse version of the bug being fixed. It is
  ///     also upstream's policy, `ConnectorThread.enqueueRequest` stores `overrideRequest =
  ///     priority` verbatim (4.1.0 jar, offsets 29-33) and `MoveGesture.enqueueRequest` passes
  ///     `false` (offset 38, `iconst_0`), so changing it would diverge from 4.1.0 to make the
  ///     behaviour worse.
  private func previewResult(dx: Int, dy: Int) -> MoveResult? {
    guard let gesture = moveGesture, drawConnections else { return nil }
    if let fresh = gesture.findResult(dx: dx, dy: dy) {
      heldPreview = HeldMovePreview(gesture: gesture, result: fresh)
      return fresh
    }
    // The identity check is a **structural backstop and no test reddens when it is removed**,
    // because the three clears below already make a mismatch unreachable through the API. It
    // stays so that "a held preview belongs to exactly one gesture" is enforced here, in one
    // place, rather than being a property you can only establish by auditing every clear site,
    // which is precisely the audit that goes wrong when a fourth site is added.
    //
    // It is also what keeps the clearing rules meaningful now that the fallback consults the
    // gesture's cache: the cache is not cleared by `selectionChanged` and cannot be, so an empty
    // box, not an empty cache, is what "nothing may be drawn" means. Query the cache only once
    // past this gate. `clearingBeatsTheCache` is red without it; note that none of
    // `DragWirePreviewClearingTests` is, because those check the box and the overlay at the
    // pointer's own delta, and this leak is neither.
    //
    // On this path the box is a **gate, not the picture**: it is deliberately not re-pointed at
    // the answer being returned. Doing so was tried and reddens nothing; `nearestResult` is
    // recomputed on every call and answers the same thing either way, the gesture's cache already
    // owns every result's lifetime, and only the box's *gesture identity* is read above. A write
    // that no caller can observe is how the next reader is misled about what the box means.
    guard let held = heldPreview, held.gesture === gesture else { return nil }
    return gesture.nearestResult(dx: dx, dy: dy) ?? held.result
  }

  /// Test seam for `WireRerouteAsymmetryTests`. `previewResult` is the whole of the policy this
  /// file was changed for, and reaching it through the pointer is a race: the delta under test has
  /// to be one the connector has not answered *yet*, which is a stopwatch, not an assertion. This
  /// reads it directly for a delta of the test's choosing and enqueues nothing.
  func previewResultForTesting(dx: Int, dy: Int) -> MoveResult? {
    previewResult(dx: dx, dy: dy)
  }

  public func overlay(for canvas: any ToolCanvas) -> ToolOverlay {
    var items: [ToolOverlayItem] = []
    let dx = currentDx
    let dy = currentDy
    /// Resolved **once** per frame and handed to `hiddenComponents`, rather than each of them
    /// asking separately. The two must describe the same reroute, see `hiddenComponents(for:)`,
    /// and two calls cannot guarantee that: the connector publishes from its own thread, so the
    /// cache can gain an entry between them and the second call can legitimately answer with a
    /// different route from the first. The result is one frame that draws route A's wires while
    /// hiding route B's removals, which puts the old wire on screen underneath the new one. That
    /// window is narrow enough that **no test reddens when this is split back into two calls**,
    /// it is a data race on a background publish, not a reachable state, so this is a
    /// structural fix, not a measured one, and it also halves the per-frame cache scans.
    var preview: MoveResult?

    switch state {
    case .moving:
      items.append(.selectionGhost(dx: dx, dy: dy))
      if dx != 0 || dy != 0 {
        preview = previewResult(dx: dx, dy: dy)
      }
      if let result = preview {
        for wire in result.wiresToAdd {
          items.append(.proposedWire(start: wire.end0, end: wire.end1))
        }
        // `dx`/`dy`, not the delta the result was computed for: the second dot upstream draws
        // (`draw` offsets 260-280, `fillOval(x + curDx - 3, y + curDy - 3, 6, 6)`) marks where the
        // moving port is heading, and the ghost it must sit on is at the current delta.
        for location in result.unconnectedLocations {
          items.append(.unsatisfiedConnection(location, dx: dx, dy: dy))
        }
      }

    case .rectangleSelect:
      guard let start else { break }
      let bounds = marqueeBounds(from: start, dx: dx, dy: dy)
      items.append(.marquee(bounds))
      if let circuit = canvas.circuit {
        for component in circuit.allWithin(bounds) {
          items.append(.marqueeGhost(component: ComponentRef(component)))
        }
      }

    case .idle:
      break
    }
    return ToolOverlay(
      items: items, hiddenComponents: hiddenComponents(for: canvas, preview: preview))
  }

  /// The rectangle upstream builds by normalising left/right and top/bottom in `draw`
  /// (`SelectTool.java:200-214`) and again, differently, in `mouseReleased`
  /// (`SelectTool.java:525`). The release version is `Bounds.create(start).add(start + delta)`,
  /// which is the same rectangle; both are expressed here once.
  private func marqueeBounds(from start: Location, dx: Int, dy: Int) -> Bounds {
    Bounds.create(start).add(wrap32(start.x &+ dx), wrap32(start.y &+ dy))
  }

  /// `getHiddenComponents(Canvas)` (`SelectTool.java:277-299`).
  ///
  /// While moving, the selection is drawn shifted by the tool, so the real components must be
  /// suppressed; **and so must every wire the move engine is going to remove**, or the preview
  /// shows both the old and the rerouted wire at once.
  ///
  /// This reads `previewResult`, not `findResult`, and it has to be the *same* call as
  /// `overlay(for:)`'s: the two must agree about which reroute is on screen. Letting one hold the
  /// last answer while the other blanked would leave the removed wire drawn underneath the
  /// proposed one, which is the "both at once" failure the paragraph above is about. That is now
  /// literally one call, `overlay(for:)` resolves the preview and passes it down, rather than
  /// two calls that usually agree; see the local there.
  ///
  /// This entry point remains for the `CanvasTool` requirement and for `EditTool`, which forwards
  /// to it. Reached that way there is no frame in flight to be consistent with, so it resolves the
  /// preview itself.
  public func hiddenComponents(for canvas: any ToolCanvas) -> Set<ComponentRef> {
    guard state == .moving, currentDx != 0 || currentDy != 0 else {
      return hiddenComponents(for: canvas, preview: nil)
    }
    return hiddenComponents(
      for: canvas, preview: previewResult(dx: currentDx, dy: currentDy))
  }

  private func hiddenComponents(
    for canvas: any ToolCanvas, preview: MoveResult?
  ) -> Set<ComponentRef> {
    guard state == .moving else { return [] }
    if currentDx == 0 && currentDy == 0 { return [] }

    var hidden = Set(canvas.selection.components.map(ComponentRef.init))
    if let preview {
      for component in preview.replacements.removals {
        hidden.insert(ComponentRef(component))
      }
    }
    return hidden
  }

  // MARK: Mouse

  public func mousePressed(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent) {
    canvas.requestFocus()
    let project = canvas.project
    let selection = canvas.selection
    // Note: **not** snapped. The select tool works in raw coordinates and snaps the *delta*
    // instead, in `computeDxDy`, which is why dragging a selection that was already off-grid
    // keeps its offset rather than jumping onto the grid.
    let pressPoint = Location.create(event.x, event.y, hasToSnap: false)
    start = pressPoint
    currentDx = 0
    currentDy = 0
    moveGesture = nil
    // Redundant today and **not covered by any test**: every route into a press has already been
    // through `mouseReleased` or `deselect`, both of which clear. Kept because this block is the
    // gesture's reset, and a field silently left out of a reset is how the next stale-state bug
    // gets written. Deleting it reddens nothing; that is a known gap, not an oversight.
    heldPreview = nil

    // 1. Pressed inside the selection.
    let inSelection = selection.componentsContaining(pressPoint)
    if !inSelection.isEmpty {
      if !event.modifiers.isAdditiveSelection {
        setState(canvas, .moving)
        project.repaintCanvas()
        return
      }
      project.perform { try SelectionActions.drop(selection, inSelection) }
    }

    // 2. Pressed on a component outside the selection.
    guard let circuit = canvas.circuit else { return }
    let clicked = circuit.allContaining(pressPoint)
    if !clicked.isEmpty {
      if !event.modifiers.isAdditiveSelection {
        // The second containment test is upstream's and is not redundant: branch 1 may have just
        // dropped the components under the pointer, so the selection can have become empty here.
        if selection.componentsContaining(pressPoint).isEmpty {
          project.perform { try SelectionActions.dropAll(selection) }
        }
      }
      let inSelectionIdentities = Set(inSelection.map(ComponentRef.init))
      for component in clicked where !inSelectionIdentities.contains(ComponentRef(component)) {
        selection.add(component)
      }
      setState(canvas, .moving)
      project.repaintCanvas()
      return
    }

    // 3. Pressed on the background.
    if !event.modifiers.isAdditiveSelection {
      project.perform { try SelectionActions.dropAll(selection) }
    }
    setState(canvas, .rectangleSelect)
    project.repaintCanvas()
  }

  public func mouseDragged(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent) {
    let project = canvas.project
    switch state {
    case .moving:
      computeDxDy(canvas.selection, event)
      handleMoveDrag(canvas, dx: currentDx, dy: currentDy, modifiers: event.modifiers)
    case .rectangleSelect:
      guard let start else { return }
      currentDx = wrap32(event.x &- start.x)
      currentDy = wrap32(event.y &- start.y)
      project.repaintCanvas()
    case .idle:
      break
    }
  }

  public func mouseReleased(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent) {
    let project = canvas.project
    switch state {
    case .moving:
      setState(canvas, .idle)
      computeDxDy(canvas.selection, event)
      let dx = currentDx
      let dy = currentDy
      if dx != 0 || dy != 0 {
        commitMove(canvas, dx: dx, dy: dy, modifiers: event.modifiers)
      }
      moveGesture = nil
      heldPreview = nil
      project.repaintCanvas()

    case .rectangleSelect:
      guard let start, let circuit = canvas.circuit else { break }
      let bounds = marqueeBounds(from: start, dx: currentDx, dy: currentDy)
      let selection = canvas.selection
      let inSelection = selection.componentsWithin(bounds)
      let inSelectionIdentities = Set(inSelection.map(ComponentRef.init))
      for component in circuit.allWithin(bounds)
      where !inSelectionIdentities.contains(ComponentRef(component)) {
        selection.add(component)
      }
      // `drop` here is upstream's toggle: components that were already selected *and* fall inside
      // the new rectangle come back out again.
      project.perform { try SelectionActions.drop(selection, inSelection) }
      setState(canvas, .idle)
      project.repaintCanvas()

    case .idle:
      break
    }

    // A double-click on a single labelled component opens its label for editing. Deliberately
    // outside the switch, as upstream has it, so it fires after either gesture.
    if event.clickCount >= 2 {
      requestLabelEdit(canvas)
    }
  }

  /// The commit half of `mouseReleased`'s `MOVING` branch (`SelectTool.java:493-521`).
  ///
  /// This is the single call that writes a drag into the model, so it is where M7's gate looks.
  /// Three refusals come first and each leaves the model untouched: a read-only circuit, an
  /// exclusive-end conflict, and, implicitly, a zero delta, which the caller already filtered.
  private func commitMove(
    _ canvas: any ToolCanvas, dx: Int, dy: Int, modifiers: ToolModifiers
  ) {
    let project = canvas.project
    guard let circuit = canvas.circuit else { return }
    if !project.fileContains(circuit) {
      canvas.setStatusMessage(.cannotModify)
      return
    }
    if canvas.selection.hasConflictWhenMoved(dx: dx, dy: dy) {
      canvas.setStatusMessage(.exclusive)
      return
    }

    let connect = shouldConnect(modifiers)
    drawConnections = false
    var replacements: ReplacementMap?
    if connect {
      let gesture =
        moveGesture
        ?? MoveGesture(
          listener: makeMoveListener(canvas),
          circuit: circuit,
          selected: canvas.selection.anchoredComponents)
      canvas.setStatusMessage(.computingMove(dx: dx, dy: dy))
      // Blocks until the connector thread answers. See `MoveGesture.forceRequest` for why that is
      // upstream's design and what the port added to it.
      let result = gesture.forceRequest(dx: dx, dy: dy)
      clearComputingMessage(canvas, dx: dx, dy: dy)
      replacements = result.replacements
    }

    // ── COMPLETING THE HAND-OFF `translateHelper` DOCUMENTS ─────────────────────────────────
    //
    // `SelectionBase.translateHelper` deliberately leaves the *originals* in `selected` after
    // adding their replacements, and its own comment says why: upstream finishes the job in
    // `Selection.MyListener.circuitChanged`, which reads the transaction's `ReplacementMap` and
    // swaps the old objects for the new. Checked against 4.1.0 rather than taken on trust;
    // `javap -c -classpath logisim-evolution-4.1.0-all.jar com.cburch.logisim.gui.main
    // .SelectionBase` shows `translateHelper` doing exactly `CircuitMutation.replace(old, new)`
    // followed by `selected.add(new)`, and `Selection$MyListener.circuitChanged` branching on
    // action `6` (`TRANSACTION_DONE`) into `getResult().getReplacementMap(circuit)`.
    //
    // **There is deliberately no delivery code here.** There used to be: this call was wrapped
    // in a scoped `CircuitTransaction.transactionDone` install that captured the results and
    // handed them to `canvas.selection`. It fixed the forward drag and left every other
    // transaction, redo above all, with no delivery at all, because `Project.redoAction`
    // re-executes the cached `xnForward` and never comes through here. The delivery is now
    // permanent and lives where upstream's listener list does: `CircuitTransactionObservers`,
    // installed into the seam by `LogisimFileProjectHostFactory.installProcessSeams()`, with
    // `Selection` registering itself in its own constructor exactly as 4.1.0's does.
    //
    // Keeping the scoped install as well would apply the replacement map twice per drag. That
    // happens to be harmless; the map is keyed old→new, `append` guarantees the two sides are
    // disjoint, and by the second pass the selection holds only components that are not keys, so
    // `replacements(for:)` answers `nil` for every one of them and even `fireSelectionChanged()`
    // is skipped. Harmless by luck is not a design, so it is gone rather than left.
    project.perform {
      SelectionActions.translate(
        canvas.selection, dx: dx, dy: dy, replacements: replacements)
    }
  }

  /// `computeDxDy(Project, MouseEvent, Graphics)` (`SelectTool.java:143-162`).
  ///
  /// The snap is applied to the **delta**, not to the pointer, so an off-grid selection stays
  /// off-grid by the same offset instead of being pulled onto the grid.
  /// Takes the `Selection` rather than the `Project` it used to: `Project.getSelection()` is
  /// a reach-through to the canvas and is optional (`Project.java:397-402`), and this method
  /// wanted nothing else from the project.
  ///
  /// ── DELIBERATE DIVERGENCE: THE ORIGIN IS NOT A WALL ─────────────────────────────────────
  ///
  /// Upstream is:
  ///
  ///     dx = Math.max(e.getX() - start.getX(), -bds.getX());
  ///     dy = Math.max(e.getY() - start.getY(), -bds.getY());
  ///
  /// and this port had it verbatim. It limits the delta so the selection's bounding box can
  /// never cross the origin, which means a drag towards the top-left **silently stops** while
  /// the pointer keeps going. Reported from real use, with the pointer readout sitting at
  /// (78, −108) and the component refusing to follow: "there seems to be invisible limits to
  /// canvas size. this is the highest it will go but clearly tons of canvas left."
  ///
  /// It is a wall upstream needs and this port does not. Upstream's canvas is a `JScrollPane`
  /// over a component whose preferred size is the circuit bounds times the zoom
  /// (`Canvas.computeSize`), so the drawable sheet genuinely begins at the origin and there is
  /// nowhere above it to scroll to: issue #1262, quoted at length in `CanvasViewport`. This
  /// port's camera is `(center, zoom)` and is unbounded by construction, so the quadrant it was
  /// protecting does not exist here.
  ///
  /// Everything the change lets in was traced before it was made, and none of it was new
  /// ground: the grid snap already had a negative branch, `.circ` already round-trips a negative
  /// `loc`, `SpatialIndex` already buckets negative coordinates, and image export and print are
  /// already `circuit.bounds.expand(n)` rather than anything anchored at the origin.
  /// `NegativeCoordinateTraceTests` is that trace, kept.
  private func computeDxDy(_ selection: Selection, _ event: ToolMouseEvent) {
    guard let start else { return }
    var dx = wrap32(event.x &- start.x)
    var dy = wrap32(event.y &- start.y)

    if selection.shouldSnap {
      dx = CanvasGrid.snapXToGrid(dx)
      dy = CanvasGrid.snapYToGrid(dy)
    }
    currentDx = dx
    currentDy = dy
  }

  /// `handleMoveDrag(Canvas, int, int, int)` (`SelectTool.java:301-328`).
  private func handleMoveDrag(
    _ canvas: any ToolCanvas, dx: Int, dy: Int, modifiers: ToolModifiers
  ) {
    let connect = shouldConnect(modifiers)
    drawConnections = connect
    if connect, let circuit = canvas.circuit {
      let gesture =
        moveGesture
        ?? MoveGesture(
          listener: makeMoveListener(canvas),
          circuit: circuit,
          selected: canvas.selection.anchoredComponents)
      moveGesture = gesture
      if dx != 0 || dy != 0 {
        if gesture.enqueueRequest(dx: dx, dy: dy) {
          canvas.setStatusMessage(.computingMove(dx: dx, dy: dy))
          // Upstream's comment: the request may have been satisfied between the enqueue and
          // here, in which case the message we just set is already stale.
          if gesture.findResult(dx: dx, dy: dy) != nil {
            clearComputingMessage(canvas, dx: dx, dy: dy)
          }
        }
      }
    }
    canvas.repaintAll()
  }

  /// `SelectTool.MoveRequestHandler`.
  ///
  /// Upstream's runs on the connector thread and touches Swing from there; see
  /// `MoveRequestListener` for the note. The hop is here.
  ///
  /// **The `repaintCanvas` is not upstream's line, but it restores upstream's behaviour.**
  /// `MoveRequestHandler.requestSatisfied` is only `clearCanvasMessage(canvas, dx, dy)`, and
  /// `clearCanvasMessage` ends in `canvas.repaint()`, which in Swing re-enters `Tool.draw`
  /// during the paint, so the answer that just landed is on screen immediately. Here the overlay
  /// is a value rebuilt on events, and `ToolCanvas.repaintAll()` redraws the one the last event
  /// built rather than deriving a new one. Without a rebuild the connector's answer sat in the
  /// cache unseen until the user moved the mouse again, so a paused drag showed a stale preview
  /// indefinitely, and every frame that had missed the cache stayed blank longer than it needed
  /// to. `Project.repaintCanvas()` fires `.repaintRequest`, which is the one path that
  /// re-derives the overlay before painting.
  private func makeMoveListener(_ canvas: any ToolCanvas) -> MoveRequestListener {
    let reference = WeakToolCanvasRef(canvas)
    return { _, dx, dy in
      Task { @MainActor in
        guard let canvas = reference.value else { return }
        SelectTool.clearComputingMessage(canvas, dx: dx, dy: dy)
        canvas.project.repaintCanvas()
      }
    }
  }

  /// `clearCanvasMessage(Canvas, int, int)` (`SelectTool.java:132-140`).
  ///
  /// The delta comparison is the point: a result for a drag position the pointer has already left
  /// must not clear the message belonging to the current one.
  private func clearComputingMessage(_ canvas: any ToolCanvas, dx: Int, dy: Int) {
    SelectTool.clearComputingMessage(canvas, dx: dx, dy: dy)
  }

  private static func clearComputingMessage(_ canvas: any ToolCanvas, dx: Int, dy: Int) {
    guard case .computingMove(let messageDx, let messageDy) = canvas.statusMessage,
      messageDx == dx, messageDy == dy
    else { return }
    canvas.setStatusMessage(nil)
    canvas.repaintAll()
  }

  /// `shouldConnect(int)` (`SelectTool.java:639-643`): the preference, inverted while the
  /// modifier is held.
  private func shouldConnect(_ modifiers: ToolModifiers) -> Bool {
    modifiers.invertsKeepConnections ? !keepsConnectionsWhenMoving : keepsConnectionsWhenMoving
  }

  private func setState(_ canvas: any ToolCanvas, _ newState: State) {
    guard state != newState else { return }
    state = newState
    canvas.setCursor(cursor)
  }

  // MARK: Keys

  public func keyPressed(_ canvas: any ToolCanvas, _ event: inout ToolKeyEvent) {
    // Re-running the reroute when the modifier changes mid-drag is what makes the preview follow
    // the key rather than waiting for the next mouse move.
    if state == .moving && event.command == .keepConnectionsModifierChanged {
      handleMoveDrag(canvas, dx: currentDx, dy: currentDy, modifiers: event.modifiers)
      return
    }

    if event.command == .deleteSelection {
      guard !canvas.selection.isEmpty else { return }
      canvas.project.perform { SelectionActions.clear(canvas.selection) }
      event.consume()
      return
    }

    // What is deliberately not here yet: the component key-configurator dispatch
    // (`tools/key`, `GateKeyboardModifier`) and the auto-labeller (`util/AutoLabel`), which
    // upstream runs *before* the delete branch. Both are separate ports with their own files,
    // `tools/key` is eight classes and `AutoLabel` reaches into dialogs, and neither exists yet.
    // The hook is `keyConfiguratorDispatch`; see its doc comment for what has to change when it
    // lands, including the ordering, because upstream lets a component swallow Delete.
    keyConfiguratorDispatch(canvas, &event, phase: .pressed)
  }

  public func keyReleased(_ canvas: any ToolCanvas, _ event: inout ToolKeyEvent) {
    if state == .moving && event.command == .keepConnectionsModifierChanged {
      handleMoveDrag(canvas, dx: currentDx, dy: currentDy, modifiers: event.modifiers)
      return
    }
    keyConfiguratorDispatch(canvas, &event, phase: .released)
  }

  public func keyTyped(_ canvas: any ToolCanvas, _ event: inout ToolKeyEvent) {
    keyConfiguratorDispatch(canvas, &event, phase: .typed)
  }

  enum KeyConfigurationPhase {
    case pressed
    case released
    case typed
  }

  /// `processKeyEvent(Canvas, KeyEvent, int)` (`SelectTool.java:573-622`).
  ///
  /// **Not yet ported, and inert on purpose.** Upstream builds a per-component `KeyConfigurator`
  /// map, feeds it the event, collects the resulting attribute changes into one
  /// `SetAttributeAction` and pushes that. `SetAttributeAction` exists here; `KeyConfigurator` and
  /// its eight subclasses in `com.cburch.logisim.tools.key` do not, and inventing a stand-in
  /// would be worse than an honest gap; a wrong key configurator writes wrong attribute values
  /// into saved files, which is exactly the failure M7's gate is meant to catch.
  ///
  /// When `tools/key` lands, this method fills in and **the ordering in `keyPressed` has to be
  /// revisited**: upstream runs the configurators and the auto-labeller *before* the
  /// delete-selection branch, so a component that consumes a key can currently swallow Delete.
  /// The stale-map invalidation is already wired: `selectionChanged` sets `keyHandlersAreStale`.
  private func keyConfiguratorDispatch(
    _ canvas: any ToolCanvas, _ event: inout ToolKeyEvent, phase: KeyConfigurationPhase
  ) {
    if keyHandlersAreStale {
      keyHandlersAreStale = false
    }
  }

  /// The double-click branch of `mouseReleased` (`SelectTool.java:541-565`).
  ///
  /// Upstream opens a modal dialog through `AutoLabel.askAndSetLabel`. D9 keeps dialogs out of
  /// this layer, and `AutoLabel` is not ported, so what survives is the *decision*: exactly one
  /// component is selected and it carries a label attribute, so the shell should offer to edit it.
  private func requestLabelEdit(_ canvas: any ToolCanvas) {
    let components = canvas.selection.components
    guard components.count == 1, let component = components.first,
      component.attributeSet.containsAttribute(StdAttr.label),
      let circuit = canvas.circuit
    else { return }
    canvas.project.viewComponentAttributes(circuit, component)
  }
}

// `CapturedTransactionResults` used to sit here: a locked box that collected the results a
// scoped `CircuitTransaction.transactionDone` install caught around `commitMove`'s one
// `project.perform`. It is gone with that install; the delivery is permanent now and does not
// pass through this file. See `commitMove` for why the scoped version could not be kept.

extension SelectTool: SelectionListener {
  /// `SelectTool.Listener.selectionChanged`: invalidates the key-handler map, and drops the held
  /// drag preview.
  ///
  /// The preview is a reroute computed for one particular set of moving components. Once the
  /// selection is not that set, the picture is about components that are no longer being dragged,
  /// which is worse than the flicker it was introduced to remove. Upstream has nothing to drop
  /// here because it holds nothing.
  public func selectionChanged(_ selection: SelectionBase) {
    keyHandlersAreStale = true
    heldPreview = nil
  }
}
