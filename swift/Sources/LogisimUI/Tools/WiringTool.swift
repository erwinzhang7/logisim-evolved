// WiringTool.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.tools.WiringTool),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── This is where the geometry has to be exact ──────────────────────────────────────────────
//
// Almost every wire in every `.circ` file was produced by this class, so its arithmetic *is* the
// file format's content. Four rules decide the coordinates that get written, and all four are
// reproduced literally rather than rationalised:
//
//   1. **Snapping.** The event is snapped through `Canvas.snapXToGrid`/`snapYToGrid` at four
//      separate points: press, move, drag and release. See `ToolGeometry.swift` for why the
//      integer arithmetic there cannot be replaced with rounding.
//   2. **The elbow.** A drag that is neither horizontal nor vertical becomes *two* wires meeting
//      at a corner, and which corner depends on `direction`, a three-state latch updated by
//      `computeMove`. The latch is sticky: once a drag has committed to horizontal-first it stays
//      horizontal-first even if the pointer later moves mostly vertically, and it only resets by
//      passing back through the start row or column.
//   3. **Repair.** `checkForRepairs` will move a wire's endpoint by one grid step onto a
//      component that asks for it, so a released endpoint and a saved endpoint are not always the
//      same point.
//   4. **Shortening.** Dragging back along an existing wire shortens or deletes it instead of
//      drawing a new one, which is a `replace` or a `remove` in the mutation rather than an `add`.
//
// The zero-length guard in rule (2) is the one that is easy to lose: each of the two wires is
// added **only if its length is positive**, so a drag that is exactly axis-aligned after snapping
// produces one wire, not one wire plus a degenerate one. `Circuit.mutatorAdd` would drop a
// degenerate wire anyway, but the mutation would still carry it and the undo label would say
// "Add Wires" rather than "Add Wire".

import AppKit
import Foundation
import LogisimFile
import LogisimKernel
// `WireRepairData` lives in `LogisimStd` beside the components that answer it; see
// `LogisimStd/Instance/WireRepair.swift` for why it could not stay in this module and could not
// go to `LogisimFile` either. `checkForRepairs` below is its only consumer in the app.
import LogisimStd

/// `com.cburch.logisim.tools.WiringTool`.
@MainActor
public final class WiringTool: Tool, CanvasTool {

  /// Written into `.circ` files as a tool reference. Upstream's warning applies verbatim: do not
  /// change it or projects stop loading.
  /// `_ID`. Declared as `Tool.toolId`, the base class's overridable identity, so the
  /// `.circ` codec in `LogisimFile` can read it without hopping to the main actor.
  /// `CanvasTool.id` is the same string; see `CanvasTool`'s extension.
  public override nonisolated class var toolId: String { "Wiring Tool" }

  public var displayNameKey: String { "wiringTool" }
  public var descriptionKey: String { "wiringToolDesc" }
  public var cursor: NSCursor { .crosshair }

  /// `HORIZONTAL` / `VERTICAL` / 0, upstream's three-state `direction` latch.
  private enum DragAxis {
    case undecided
    case horizontal
    case vertical
  }

  private var exists = false
  private var inCanvas = false
  private var start = Location.create(0, 0, hasToSnap: true)
  private var current = Location.create(0, 0, hasToSnap: true)
  private var hasDragged = false
  /// True when the press landed on an existing wire endpoint, which is the precondition for the
  /// shorten gesture.
  private var startShortening = false
  private var shortening: Wire?
  /// The action this tool last pushed, compared **by identity** so that the undo shortcut only
  /// fires while it is still on top of the stack.
  private weak var lastAction: Action?
  private var direction: DragAxis = .undecided

  /// Set by the shell when `AppPreferences.ADD_SHOW_GHOSTS` changes. D9: the model layer may not
  /// read preferences, so the preference is pushed in; the same treatment `Circuit.hdlType` gets.
  public var showsGhosts = true

  public override init() {}

  // MARK: Overlay

  public func overlay(for canvas: any ToolCanvas) -> ToolOverlay {
    var items: [ToolOverlayItem] = []
    if exists {
      var end0 = start
      var end1 = current
      if let shortenBefore = willShorten(start, current) {
        guard let shortened = shortenResult(shortenBefore, start, current) else {
          // Upstream returns early and draws nothing: the drag would collapse the wire to a
          // point, so there is no preview to show.
          return ToolOverlay(items: [], hiddenComponents: hiddenComponents(for: canvas))
        }
        end0 = shortened.end0
        end1 = shortened.end1
      }
      let elbow: Location?
      switch direction {
      case .horizontal:
        elbow = Location.create(end1.x, end0.y, hasToSnap: false)
      case .vertical:
        elbow = Location.create(end0.x, end1.y, hasToSnap: false)
      case .undecided:
        elbow = nil
      }
      items.append(.pendingWire(start: end0, elbow: elbow, end: end1))
    } else if showsGhosts && inCanvas {
      items.append(.cursorDot(current))
    }
    return ToolOverlay(items: items, hiddenComponents: hiddenComponents(for: canvas))
  }

  /// `getHiddenComponents(Canvas)`; the wire being shortened must not be drawn, because the tool
  /// is drawing its shortened form.
  public func hiddenComponents(for canvas: any ToolCanvas) -> Set<ComponentRef> {
    guard let shorten = willShorten(start, current) else { return [] }
    return [ComponentRef(shorten)]
  }

  // MARK: Mouse

  public func mouseEntered(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent) {
    inCanvas = true
    canvas.project.repaintCanvas()
  }

  public func mouseExited(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent) {
    inCanvas = false
    canvas.project.repaintCanvas()
  }

  public func mouseMoved(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent) {
    if exists {
      mouseDragged(canvas, &event)
    } else {
      event.snapToGrid()
      inCanvas = true
      if current.x != event.x || current.y != event.y {
        current = Location.create(event.x, event.y, hasToSnap: true)
      }
      canvas.project.repaintCanvas()
    }
  }

  public func mousePressed(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent) {
    guard let circuit = canvas.circuit, canvas.project.fileContains(circuit) else {
      exists = false
      canvas.setStatusMessage(.cannotModify)
      return
    }
    event.snapToGrid()
    start = Location.create(event.x, event.y, hasToSnap: true)
    current = start
    exists = true
    hasDragged = false

    startShortening = !canvas.pointQueries.wires(at: start).isEmpty
    shortening = nil

    canvas.project.repaintCanvas()
  }

  public func mouseDragged(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent) {
    guard exists else { return }
    event.snapToGrid()
    let currentX = event.x
    let currentY = event.y
    guard computeMove(newX: currentX, newY: currentY) else { return }
    hasDragged = true

    // The repaint rectangle upstream builds spans the old and new positions plus a 3-unit margin.
    var repaintBounds = Bounds.create(start).add(current).add(currentX, currentY)
    repaintBounds = repaintBounds.expand(3)

    current = Location.create(currentX, currentY, hasToSnap: true)

    // Which wire (if any) this drag is shortening. Note the two passes are not symmetrical:
    // the first only runs when the press landed on a wire end, and it looks for a wire at the
    // *start* that contains the current point; the second looks for a wire at the *current* point
    // that contains the start. Together they cover dragging inward from either end.
    var shorten: Wire?
    if startShortening {
      for wire in canvas.pointQueries.wires(at: start) where wire.contains(current) {
        shorten = wire
        break
      }
    }
    if shorten == nil {
      for wire in canvas.pointQueries.wires(at: current) where wire.contains(start) {
        shorten = wire
        break
      }
    }
    shortening = shorten

    canvas.repaint(repaintBounds)
  }

  public func mouseReleased(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent) {
    guard exists else { return }
    guard let circuit = canvas.circuit else { return }

    event.snapToGrid()
    let currentX = event.x
    let currentY = event.y
    if computeMove(newX: currentX, newY: currentY) {
      current = Location.create(currentX, currentY, hasToSnap: true)
    }
    guard hasDragged else { return }
    exists = false

    var wires: [Wire] = []
    if current.y == start.y || current.x == start.x {
      // A single straight run. `Wire.create(cur, start)`; note the argument order is upstream's;
      // `Wire.create` normalises the endpoints, so it does not affect the saved geometry, but the
      // two `checkForRepairs` calls that follow use `end0`/`end1` of the *normalised* wire and
      // would look at different ends if the order changed.
      var wire = Wire.create(current, start)
      wire = checkForRepairs(canvas, wire, end: wire.end0)
      wire = checkForRepairs(canvas, wire, end: wire.end1)
      if performShortening(canvas, circuit: circuit, drag0: start, drag1: current) { return }
      if wire.length > 0 { wires.append(wire) }
    } else {
      // An elbow. The corner is on the start's row for a horizontal-first drag and on the start's
      // column otherwise, which is the whole job of the `direction` latch.
      let corner: Location =
        direction == .horizontal
        ? Location.create(current.x, start.y, hasToSnap: true)
        : Location.create(start.x, current.y, hasToSnap: true)
      var wire0 = Wire.create(start, corner)
      var wire1 = Wire.create(corner, current)
      wire0 = checkForRepairs(canvas, wire0, end: start)
      wire1 = checkForRepairs(canvas, wire1, end: current)
      if wire0.length > 0 { wires.append(wire0) }
      if wire1.length > 0 { wires.append(wire1) }
    }

    guard !wires.isEmpty else { return }
    let mutation = canvas.project.beginMutation(on: circuit)
    mutation.addAll(wires)
    let action = mutation.toAction(wires.count == 1 ? .addWire : .addWires)
    // See `CanvasAddTool.add`: recorded only on success, matching what a throw out of
    // `proj.doAction` does upstream.
    if canvas.project.perform({ action }) {
      lastAction = action
    }
  }

  // MARK: Keys

  public func keyPressed(_ canvas: any ToolCanvas, _ event: inout ToolKeyEvent) {
    guard event.command == .undoOwnLastPlacement else { return }
    if let last = lastAction, canvas.project.lastAction === last {
      canvas.project.undoActionReportingFailure()
      lastAction = nil
    }
  }

  // MARK: Selection lifecycle

  public func select(_ canvas: any ToolCanvas) {
    lastAction = nil
    reset()
  }

  /// `resetClick()`: package-private upstream, called by `EditTool` when a wiring drag turns out
  /// to have been a click.
  func resetClick() {
    exists = false
  }

  private func reset() {
    exists = false
    inCanvas = false
    start = Location.create(0, 0, hasToSnap: true)
    current = Location.create(0, 0, hasToSnap: true)
    startShortening = false
    shortening = nil
    direction = .undecided
  }

  // MARK: Geometry

  /// `computeMove(int, int)` (`WiringTool.java:91-105`).
  ///
  /// Returns false, meaning "nothing changed, do not repaint", when the pointer has not left the
  /// grid point it was on. Otherwise it updates the sticky axis latch. Read the three `else if`
  /// branches as: the drag stays on the axis it chose until it crosses back onto the start's row
  /// or column, at which point it either flips axis or goes back to undecided.
  private func computeMove(newX: Int, newY: Int) -> Bool {
    if current.x == newX && current.y == newY { return false }
    let start = self.start
    switch direction {
    case .undecided:
      if newX != start.x {
        direction = .horizontal
      } else if newY != start.y {
        direction = .vertical
      }
    case .horizontal where newX == start.x:
      direction = (newY == start.y) ? .undecided : .vertical
    case .vertical where newY == start.y:
      direction = (newX == start.x) ? .undecided : .horizontal
    default:
      break
    }
    return true
  }

  /// `checkForRepairs(Canvas, Wire, Location)` (`WiringTool.java:65-89`).
  ///
  /// The rule, and it runs the opposite way to what the name suggests: if a wire has been dragged
  /// one grid step *past* a component's port and into its body, pull the loose end back onto the
  /// port. `Wire.create` normalises its endpoints, so `end0` is the lower coordinate and the
  /// candidate for `end0` is `end0 + 10`: one step back toward the middle of the wire, never
  /// outward. Repair therefore **shortens**. Measured, not inferred: `WireRepairComponentTests`
  /// drags to a splitter's `(110,80)` and the wire that lands ends at `(120,80)`.
  ///
  /// The three guards in order, the wire must be longer than one grid step, nothing may already
  /// be at the loose end, and the candidate point one step further on must hold a component whose
  /// bounds contain the loose end within a 2-unit fudge, are what confine it to that overshoot.
  ///
  /// This is a *silent coordinate change*: the wire that gets saved does not end where the user
  /// released the mouse. Worth naming explicitly, because a byte-exact gate that ignores it will
  /// look like a snapping bug.
  ///
  /// Note what an *unrepaired* overshoot leaves behind, since it is easy to read as a repair that
  /// misfired: the wire runs through the port, and `Circuit.mutatorAdd` splits it there, so the
  /// circuit ends up with two wires meeting at the pin instead of one stopping on it.
  private func checkForRepairs(_ canvas: any ToolCanvas, _ wire: Wire, end: Location) -> Wire {
    // Don't repair a short wire to nothing.
    if wire.length <= 10 { return wire }
    if !canvas.pointQueries.nonWires(at: end).isEmpty { return wire }

    let delta = (end == wire.end0) ? 10 : -10
    let candidate: Location =
      wire.isVertical
      ? Location.create(end.x, wrap32(end.y &+ delta), hasToSnap: true)
      : Location.create(wrap32(end.x &+ delta), end.y, hasToSnap: true)

    for component in canvas.pointQueries.nonWires(at: candidate) {
      guard component.bounds.contains(end, 2) else { continue }
      guard let repair = component.wireRepairFeature() else {
        continue
      }
      if repair.shouldRepairWire(WireRepairData(wire: wire, point: candidate)) {
        let repaired = Wire.create(wire.otherEnd(from: end), candidate)
        canvas.repaint(
          Bounds.create(wrap32(end.x &- 13), wrap32(end.y &- 13), 26, 26))
        return repaired
      }
    }
    return wire
  }

  /// `willShorten(Location, Location)` (`WiringTool.java:395-403`).
  private func willShorten(_ drag0: Location, _ drag1: Location) -> Wire? {
    guard let shorten = shortening else { return nil }
    return (shorten.endsAt(drag0) || shorten.endsAt(drag1)) ? shorten : nil
  }

  /// `getShortenResult(Wire, Location, Location)` (`WiringTool.java:169-184`).
  ///
  /// Returns nil for "the shortened wire would be a point", which the caller reads as "delete it
  /// instead".
  private func shortenResult(_ shorten: Wire, _ drag0: Location, _ drag1: Location) -> Wire? {
    let end0: Location
    let end1: Location
    if shorten.endsAt(drag0) {
      end0 = drag1
      end1 = shorten.otherEnd(from: drag0)
    } else if shorten.endsAt(drag1) {
      end0 = drag0
      end1 = shorten.otherEnd(from: drag1)
    } else {
      return nil
    }
    return end0 == end1 ? nil : Wire.create(end0, end1)
  }

  /// `performShortening(Canvas, Location, Location)` (`WiringTool.java:357-372`).
  ///
  /// Returns true when it handled the release, which is why `mouseReleased` checks it *before*
  /// adding the straight wire it already built; a shorten and an add are mutually exclusive.
  private func performShortening(
    _ canvas: any ToolCanvas, circuit: Circuit, drag0: Location, drag1: Location
  ) -> Bool {
    guard let shorten = willShorten(drag0, drag1) else { return false }
    let mutation = canvas.project.beginMutation(on: circuit)
    let actionName: ToolActionName
    if let result = shortenResult(shorten, drag0, drag1) {
      mutation.replace(shorten, with: result)
      actionName = .shortenWire
    } else {
      mutation.remove(shorten)
      actionName = .removeComponent(shorten.factory.displayName)
    }
    canvas.project.perform { mutation.toAction(actionName) }
    return true
  }
}
