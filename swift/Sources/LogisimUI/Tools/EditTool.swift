// EditTool.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.tools.EditTool),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import AppKit
import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.tools.EditTool`: the default tool, which is really a router.
///
/// It owns a `SelectTool` and a `WiringTool` and decides, on every press, which one gets the
/// gesture. The decision is `isWiringPoint`: if the snapped point under the cursor is somewhere a
/// wire could attach, the press starts wiring; otherwise it starts selecting. Everything else in
/// the class exists to make that decision cheap and to show the user which way it will go.
///
/// Three details are worth reading before the code:
///
///   * **The eligibility radius.** A pointer counts as being on a grid intersection only if it is
///     within √36 = 6 units of one (`dx*dx + dy*dy < 36`). Outside that, the point is reported as
///     `(-1, -1)` and no wiring indicator shows. Holding the override modifier bypasses the test
///     entirely.
///   * **The cache.** `isWiringPoint` walks every wire in the circuit, and it is called on every
///     mouse-move, so results are memoised per snapped point in a 32-entry insertion-ordered map
///     and thrown away wholesale whenever the circuit or the selection changes.
///   * **Click versus drag.** A press-and-release within 2 units is a *click*, and a click that
///     went to the wiring tool is retracted and replayed into the select tool
///     (`EditTool.java:392-400`), which is how clicking on a wire selects it instead of starting
///     a zero-length wire.
@MainActor
public final class EditTool: Tool, CanvasTool {

  /// `_ID`. Declared as `Tool.toolId`, the base class's overridable identity, so the
  /// `.circ` codec in `LogisimFile` can read it without hopping to the main actor.
  /// `CanvasTool.id` is the same string; see `CanvasTool`'s extension.
  public override nonisolated class var toolId: String { "Edit Tool" }

  public var displayNameKey: String { "editTool" }
  public var descriptionKey: String { "editToolDesc" }

  private static let cacheMaximumSize = 32
  /// `NULL_LOCATION`: `Integer.MIN_VALUE` in both coordinates, used as a sentinel rather than an
  /// optional so that `repaintIndicators` can compare two of them.
  private static let nullLocation = Location.create(
    Int(Int32.min), Int(Int32.min), hasToSnap: false)

  /// Named `selectTool`/`wiringTool` rather than upstream's `select`/`wiring` because `select` is
  /// also a `Tool` method here, and `current = select` would then be ambiguous between the stored
  /// tool and a reference to the method.
  /// `nonisolated(unsafe)` only so the `attributeSet` override, which is non-isolated,
  /// matching the base class, can forward to the select tool's. Both are written once in
  /// `init` and never again.
  ///
  /// Internal rather than private so `BaseToolReachabilityTests` can assert that the EditTool the
  /// toolbar hands out delegates to the SAME instances the toolbar hands out directly. Two
  /// separate instances compile and behave almost right, diverging only when a gesture starts
  /// under one and continues under the other, which is not a thing a type check can catch.
  nonisolated(unsafe) let selectTool: SelectTool
  nonisolated(unsafe) let wiringTool: WiringTool
  /// The tool currently receiving events. Typed `any CanvasTool`, not `Tool`: the whole job
  /// of this field is to forward mouse and key events, and those live on `CanvasTool`.
  private var current: any CanvasTool

  /// `cache`: a `LinkedHashMap`, so eviction is oldest-first. Swift has no ordered dictionary in
  /// the standard library, so the order is kept alongside.
  private var cache: [Location: Bool] = [:]
  private var cacheOrder: [Location] = []

  private weak var lastCanvas: (any ToolCanvas)?

  // ── THREE SENTINELS UPSTREAM CAN AFFORD AND THIS PORT CANNOT ─────────────────────────────
  //
  // Upstream keeps each of the three positions below as a pair of ints and spells "unset" as a
  // negative x: `pressX = -1` (`EditTool.java:102,241,343,349`), `lastX = -1` (`:59,67,100`),
  // `lastRawX` tested with `if (x >= 0)` (`:486-487`). That is sound *there*: `MouseEvent.getX()`
  // is a pixel offset inside the `JScrollPane`'s view component, whose sheet begins at the origin,
  // so it is never negative. Here a tool is handed a **world** coordinate, and D19 removed the
  // origin wall, so the value the sentinel calls impossible is now an ordinary place to click.
  //
  // Two of the three were live defects, both measured in `EditToolNegativePressTests` before this
  // was changed: clicking an unselected wire at x = −100 selected **nothing**, because `isClick`
  // read the press as absent and the click-to-select replay never ran; and the wiring indicator
  // stopped tracking the pointer altogether on the negative side, because every recompute that
  // starts from the last pointer position, the Option override, and `invalidate` after a circuit
  // or selection change, bailed out on `lastRawX`.
  //
  // The third, `lastComputedPoint`, was **latent**: it is only ever compared against a *snapped*
  // coordinate, and `CanvasGrid.snapXToGrid` always returns a multiple of 10, so a literal −1
  // could never equal one. It is an optional anyway. The idiom is what failed, and leaving the
  // last instance of it in place is how half a fix survives into the next edit.
  //
  // One negative coordinate deliberately stays a sentinel, for the same multiple-of-10 reason
  // read the other way: `updateLocation` reports an ineligible pointer as the snapped point
  // (−1, −1) (`EditTool.java:438-441`), which no genuine snapped point can equal. `nullLocation`
  // (Int32.min in both coordinates) stays too; it is a `Location`, compared with `Location`s that
  // only ever come out of the snapper, and the snapper cannot produce it.

  /// The last pointer position seen, in raw unsnapped tool coordinates, or nil before the first
  /// mouse event. `updateLocationFromKey` re-evaluates the wiring decision here, which is what
  /// makes pressing the override modifier update the indicator without moving the mouse.
  private var lastRawPoint: ToolPoint?
  /// The snapped point at which the wiring decision was last computed. nil means "not computed",
  /// which forces the next `updateLocation` to do the work rather than trust `wireLocation`.
  private var lastComputedPoint: ToolPoint?
  private var lastModifiers: ToolModifiers = []
  /// Where to draw the wiring indicator, or `nullLocation`.
  private var wireLocation = EditTool.nullLocation
  /// Where the mouse was last pressed, for the click test, or nil for "no press".
  private var pressPoint: ToolPoint?

  private var listener: EditToolListener?
  private var selectionSubscription: ToolSubscription?

  public init(select: SelectTool, wiring: WiringTool) {
    self.selectTool = select
    self.wiringTool = wiring
    self.current = select
  }

  public var cursor: NSCursor { selectTool.cursor }
  /// `nonisolated` because it overrides a member of the non-isolated `LogisimFile.Tool`,
  /// which the `.circ` codec reads. See `Tool.swift`'s header on the boundary.
  public override nonisolated var attributeSet: (any AttributeSet)? { selectTool.attributeSet }

  public func attributeSet(for canvas: any ToolCanvas) -> (any AttributeSet)? {
    canvas.selection.attributeSet
  }

  public func setAttributeSet(_ attributes: any AttributeSet) {
    selectTool.setAttributeSet(attributes)
  }

  // MARK: Lifecycle

  public func select(_ canvas: any ToolCanvas) {
    current = selectTool
    lastCanvas = canvas
    clearCache()
    let listener = EditToolListener(tool: self)
    self.listener = listener
    canvas.circuit?.addCircuitListener(listener)
    selectionSubscription?.invalidate()
    selectionSubscription = canvas.selection.addSelectionListener(listener)
    selectTool.select(canvas)
  }

  public func deselect(_ canvas: any ToolCanvas) {
    current = selectTool
    canvas.selection.clearSuppressHandles()
    clearCache()
    if let listener { canvas.circuit?.removeCircuitListener(listener) }
    selectionSubscription?.invalidate()
    selectionSubscription = nil
    listener = nil
  }

  // MARK: Overlay

  public func overlay(for canvas: any ToolCanvas) -> ToolOverlay {
    var items: [ToolOverlayItem] = []
    // The indicator is suppressed while the wiring tool is actually drawing, because the wire
    // preview already says where the wire will attach.
    if wireLocation != EditTool.nullLocation && !(current === wiringTool) {
      items.append(.wiringPointIndicator(wireLocation))
    }
    let inner = current.overlay(for: canvas)
    items.append(contentsOf: inner.items)
    return ToolOverlay(items: items, hiddenComponents: inner.hiddenComponents)
  }

  public func hiddenComponents(for canvas: any ToolCanvas) -> Set<ComponentRef> {
    current.hiddenComponents(for: canvas)
  }

  // MARK: Mouse

  public func mouseEntered(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent) {
    pressPoint = nil
    current.mouseEntered(canvas, &event)
  }

  public func mouseExited(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent) {
    pressPoint = nil
    current.mouseExited(canvas, &event)
  }

  public func mouseMoved(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent) {
    _ = updateLocation(canvas, x: event.x, y: event.y, modifiers: event.modifiers)
    selectTool.mouseMoved(canvas, &event)
  }

  public func mousePressed(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent) {
    canvas.requestFocus()
    let isWire = updateLocation(canvas, x: event.x, y: event.y, modifiers: event.modifiers)
    let oldWireLocation = wireLocation
    wireLocation = EditTool.nullLocation
    // Upstream writes `Integer.MIN_VALUE` here and `-1` in the listener (`EditTool.java:365`
    // against `:59,67`); both mean the same thing, "recompute next time", and both are nil now.
    lastComputedPoint = nil

    if isWire {
      current = wiringTool
      let selection = canvas.selection
      // Selected wires that pass through the point being extended have their handles hidden, so
      // the handle dots do not draw on top of the new wire.
      var suppress: [any Component]?
      if let circuit = canvas.circuit {
        let selectedIdentities = Set(selection.anchoredComponents.map(ComponentRef.init))
        for wire in circuit.wires
        where selectedIdentities.contains(ComponentRef(wire)) && wire.contains(oldWireLocation) {
          if suppress == nil { suppress = [] }
          suppress?.append(wire)
        }
      }
      selection.setSuppressHandles(suppress)
    } else {
      current = selectTool
    }
    pressPoint = event.point
    current.mousePressed(canvas, &event)
  }

  public func mouseDragged(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent) {
    _ = isClick(event)
    current.mouseDragged(canvas, &event)
  }

  public func mouseReleased(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent) {
    let wasClick = isClick(event) && current === wiringTool
    canvas.selection.clearSuppressHandles()
    current.mouseReleased(canvas, &event)
    if wasClick {
      // A click that went to the wiring tool is retracted and replayed as a select press+release.
      // Note the event handed on has already been snapped to the grid by `WiringTool`, because
      // upstream's `MouseEvent` is mutated in place; see `ToolMouseEvent`'s doc comment. That is
      // why these two calls take the same `inout` event rather than a fresh one.
      wiringTool.resetClick()
      selectTool.mousePressed(canvas, &event)
      selectTool.mouseReleased(canvas, &event)
    }
    current = selectTool
    clearCache()
    _ = updateLocation(canvas, x: event.x, y: event.y, modifiers: event.modifiers)
  }

  /// `isClick(MouseEvent)` (`EditTool.java:231-245`).
  ///
  /// Note the side effect: once the pointer has moved more than 2 units from the press, the press
  /// is forgotten and the gesture can never be a click again, even if the pointer comes back.
  ///
  /// Upstream's test is `pressX < 0`, which conflates "no press" with "pressed left of the
  /// origin". That is the whole of the defect `EditToolNegativePressTests` pins: the press itself
  /// is fine, it goes to the wiring tool exactly as it should, but a gesture that is never a click
  /// is never retracted and replayed into the select tool: so on the negative side a click on a
  /// wire selected nothing at all.
  private func isClick(_ event: ToolMouseEvent) -> Bool {
    guard let press = pressPoint else { return false }
    let dx = wrap32(event.x &- press.x)
    let dy = wrap32(event.y &- press.y)
    if wrap32(wrap32(dx &* dx) &+ wrap32(dy &* dy)) <= 4 { return true }
    pressPoint = nil
    return false
  }

  // MARK: Keys

  public func keyPressed(_ canvas: any ToolCanvas, _ event: inout ToolKeyEvent) {
    switch event.command {
    case .deleteSelection:
      if !canvas.selection.isEmpty {
        canvas.project.perform { SelectionActions.clear(canvas.selection) }
        event.consume()
      } else {
        // With nothing selected, Delete means "undo the wire I just drew".
        wiringTool.keyPressed(canvas, &event)
      }

    case .duplicateSelection:
      canvas.project.perform { SelectionActions.duplicate(canvas.selection) }
      event.consume()

    case .face(let direction):
      attemptReface(canvas, facing: direction, &event)

    case .wiringOverrideModifierChanged:
      _ = updateLocationFromKey(canvas, modifiers: event.modifiers)
      event.consume()

    case .rotateSelection:
      attemptRotate(canvas, &event)

    default:
      selectTool.keyPressed(canvas, &event)
    }
  }

  public func keyReleased(_ canvas: any ToolCanvas, _ event: inout ToolKeyEvent) {
    if event.command == .wiringOverrideModifierChanged {
      _ = updateLocationFromKey(canvas, modifiers: event.modifiers)
      event.consume()
    } else {
      selectTool.keyReleased(canvas, &event)
    }
  }

  public func keyTyped(_ canvas: any ToolCanvas, _ event: inout ToolKeyEvent) {
    selectTool.keyTyped(canvas, &event)
  }

  /// `attemptReface(Canvas, Direction, KeyEvent)` (`EditTool.java:130-147`).
  private func attemptReface(
    _ canvas: any ToolCanvas, facing: Direction, _ event: inout ToolKeyEvent
  ) {
    guard let circuit = canvas.circuit else { return }
    let action = SetAttributeAction(circuit: circuit, name: .selectionReface)
    for component in canvas.selection.components where !(component is Wire) {
      guard let attribute = facingAttribute(of: component) else { continue }
      action.set(component, attribute, facing)
    }
    guard !action.isEmpty else { return }
    canvas.project.perform { action }
    event.consume()
  }

  /// `attemptRotate(Canvas, KeyEvent)` (`EditTool.java:108-128`).
  ///
  /// Upstream's own comment notes this duplicates `attemptReface`. It is kept separate because
  /// the two differ in a way the comment glosses over: rotate reads each component's *current*
  /// facing and turns it right, and it skips a component whose facing is null: so a mixed
  /// selection rotates each part about its own axis rather than all snapping to one direction.
  private func attemptRotate(_ canvas: any ToolCanvas, _ event: inout ToolKeyEvent) {
    guard let circuit = canvas.circuit else { return }
    let action = SetAttributeAction(circuit: circuit, name: .selectionReface)
    for component in canvas.selection.components where !(component is Wire) {
      let attribute = facingAttribute(of: component)
      guard let facing = component.attributeSet[StdAttr.facing] else { continue }
      let turned = facing.getRight()
      if let attribute {
        action.set(component, attribute, turned)
      }
    }
    guard !action.isEmpty else { return }
    canvas.project.perform { action }
    event.consume()
  }

  /// `getFacingAttribute(Component)`; the factory names which of its attributes is the facing
  /// one, because it is not always `StdAttr.FACING`.
  private func facingAttribute(of component: any Component) -> Attribute<Direction>? {
    let attributes = component.attributeSet
    let feature = component.factory.feature(.facingAttribute, attributes)
    return feature as? Attribute<Direction>
  }

  // MARK: The wiring-point decision

  /// `isWiringPoint(Canvas, Location, int)` (`EditTool.java:247-278`).
  ///
  /// Reads as a chain of special cases, and the shape is: **the override modifier flips the
  /// answer**. Without it, a point on or at a component is a wiring point and bare canvas is not;
  /// with it, the answers swap, so the user can select a wire by clicking its middle instead of
  /// splicing into it.
  private func isWiringPoint(
    _ canvas: any ToolCanvas, _ point: Location, modifiers: ToolModifiers
  ) -> Bool {
    let wiringAnswer = !modifiers.forcesWiringPoint
    let selectAnswer = !wiringAnswer

    // A selected wire's *middle* is a select target even without the modifier; dragging it moves
    // the wire rather than splicing it.
    for component in canvas.selection.components {
      if let wire = component as? Wire, wire.contains(point), !wire.endsAt(point) {
        return selectAnswer
      }
    }

    guard let circuit = canvas.circuit else { return false }
    if !canvas.pointQueries.components(at: point).isEmpty { return wiringAnswer }
    for wire in circuit.wires where wire.contains(point) { return wiringAnswer }
    return selectAnswer
  }

  /// `updateLocation(Canvas, int, int, int)` (`EditTool.java:429-483`).
  @discardableResult
  private func updateLocation(
    _ canvas: any ToolCanvas, x: Int, y: Int, modifiers: ToolModifiers
  ) -> Bool {
    var snapX = CanvasGrid.snapXToGrid(x)
    var snapY = CanvasGrid.snapYToGrid(y)
    let dx = wrap32(x &- snapX)
    let dy = wrap32(y &- snapY)
    // Within 6 units of a grid intersection, or the override modifier is down.
    var isEligible = wrap32(wrap32(dx &* dx) &+ wrap32(dy &* dy)) < 36
    if modifiers.forcesWiringPoint { isEligible = true }
    if !isEligible {
      snapX = -1
      snapY = -1
    }
    let modifiersUnchanged = lastModifiers == modifiers
    lastCanvas = canvas
    lastRawPoint = ToolPoint(x: x, y: y)
    lastModifiers = modifiers

    let snappedPoint = ToolPoint(x: snapX, y: snapY)
    if lastComputedPoint == snappedPoint && modifiersUnchanged {
      return wireLocation != EditTool.nullLocation
    }

    let snapped = Location.create(snapX, snapY, hasToSnap: false)
    if modifiersUnchanged {
      if let cached = cache[snapped] {
        lastComputedPoint = snappedPoint
        let oldWireLocation = wireLocation
        wireLocation = cached ? snapped : EditTool.nullLocation
        repaintIndicators(canvas, oldWireLocation, wireLocation)
        return cached
      }
    } else {
      clearCache()
    }

    let oldWireLocation = wireLocation
    let result = isEligible && isWiringPoint(canvas, snapped, modifiers: modifiers)
    wireLocation = result ? snapped : EditTool.nullLocation
    if cache[snapped] == nil { cacheOrder.append(snapped) }
    cache[snapped] = result
    evictCacheOverflow()

    lastComputedPoint = snappedPoint
    repaintIndicators(canvas, oldWireLocation, wireLocation)
    return result
  }

  /// `updateLocation(Canvas, KeyEvent)` (`EditTool.java:485-492`): re-evaluates at the last known
  /// pointer position, which is what makes pressing the override modifier update the indicator
  /// without moving the mouse.
  ///
  /// Upstream's guard is `if (x >= 0)` on `lastRawX`, and this is the second half of the same
  /// defect as `isClick`'s: with the pointer left of the origin, every recompute that starts here
  /// refused to run. Both callers matter. The override modifier is the visible one; the other is
  /// `invalidate`, so a wire deleted from under the cursor left its wiring indicator drawn over
  /// bare canvas until the mouse moved again.
  @discardableResult
  private func updateLocationFromKey(
    _ canvas: any ToolCanvas, modifiers: ToolModifiers
  ) -> Bool {
    guard let point = lastRawPoint else { return false }
    return updateLocation(canvas, x: point.x, y: point.y, modifiers: modifiers)
  }

  private func evictCacheOverflow() {
    var toRemove = cacheOrder.count - EditTool.cacheMaximumSize
    while toRemove > 0, !cacheOrder.isEmpty {
      let oldest = cacheOrder.removeFirst()
      cache.removeValue(forKey: oldest)
      toRemove -= 1
    }
  }

  private func clearCache() {
    cache.removeAll()
    cacheOrder.removeAll()
  }

  /// `repaintIndicators(Canvas, Location, Location)`: a 12×12 box around each end of the change.
  private func repaintIndicators(_ canvas: any ToolCanvas, _ a: Location, _ b: Location) {
    guard a != b else { return }
    if a != EditTool.nullLocation {
      canvas.repaint(Bounds.create(wrap32(a.x &- 6), wrap32(a.y &- 6), 12, 12))
    }
    if b != EditTool.nullLocation {
      canvas.repaint(Bounds.create(wrap32(b.x &- 6), wrap32(b.y &- 6), 12, 12))
    }
  }

  /// `EditTool.Listener.circuitChanged` / `.selectionChanged`: both throw the cache away and
  /// recompute at the last pointer position. The `ACTION_INVALIDATE` exemption is upstream's:
  /// an invalidation is a repaint hint, not a topology change, and honouring it would clear the
  /// cache on every simulation step.
  fileprivate func invalidate(dueTo action: CircuitEventAction?) {
    if let action, action == .invalidate { return }
    lastComputedPoint = nil
    clearCache()
    guard let canvas = lastCanvas else { return }
    _ = updateLocationFromKey(canvas, modifiers: lastModifiers)
  }
}

/// `EditTool.Listener`, which is both a `CircuitListener` and a `Selection.Listener`.
@MainActor
final class EditToolListener: CircuitListener, SelectionListener {
  private weak var tool: EditTool?

  init(tool: EditTool) { self.tool = tool }

  nonisolated func circuitChanged(_ event: CircuitEvent) {
    // `onMainActor`, not `MainActor.assumeIsolated`; D1's corollary. `EditTool` subscribes to
    // the circuit for the whole time it is the selected tool, and `.invalidate` is posted from
    // the SIMULATION thread by `InstanceComponent.fireInvalidated()` via
    // `SubcircuitPropagation.substate`. Asserting isolation there kills the process with
    // EXC_BREAKPOINT and reports nothing, because the test binary dies with it. Note the action
    // is extracted first and is a plain `Sendable` enum, so no box is needed here.
    let action = event.action
    onMainActor { [weak self] in
      self?.tool?.invalidate(dueTo: action)
    }
  }

  func selectionChanged(_ selection: SelectionBase) {
    tool?.invalidate(dueTo: nil)
  }
}
