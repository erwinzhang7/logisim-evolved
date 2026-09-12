// ToolSeams.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.gui.main.{Canvas, Selection,
// SelectionActions}, com.cburch.logisim.proj.Project, com.cburch.logisim.circuit.CircuitMutation),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── What this file is, and why it exists ────────────────────────────────────────────────────
//
// The six tools were ported in parallel with the Project/undo and Selection/clipboard slices, so
// they were written against protocols standing in for four types that did not exist yet,
// `Canvas`, `Project`, `Selection` and `CircuitMutation`, in the style `Seams/ProjectSeam.swift`
// and `Seams/RenderSeam.swift` established for the shell/renderer boundary.
//
// **Three of those four have since landed, and the stand-ins are gone.** `ToolProject`,
// `ToolSelection`, `ToolSelectionActions`, `ToolSelectionListener`, `EditorAction` and
// `CircuitMutating` were deleted when the slices were reconciled; the tools now use `Project`,
// `Selection`, `SelectionActions`, `Action` and `CircuitMutation` directly, which is where Java
// puts them (`com.cburch.logisim.proj.{Project, Action}`,
// `com.cburch.logisim.gui.main.{Selection, SelectionActions}`,
// `com.cburch.logisim.circuit.CircuitMutation`). Their doc comments moved onto those types rather
// than being dropped: the notes on `getComponents()` versus `getAnchoredComponents()`, on
// `getLastAction()` being identity-compared, and on `SelectionActions`' nil returns are all
// findings that cost real effort and are now recorded at the thing they describe.
//
// What survives here is the genuinely invented vocabulary with no ported counterpart: the canvas
// seam (`ToolCanvas`, `ToolCircuitState`), the `CircuitPoints` queries M3 will supply, action
// names, status messages, and the two concurrency boxes the move engine needs.
//
// **The byte-exact rule and where it lands.** M7's pass condition is that a scripted edit
// sequence saved to `.circ` byte-matches Java's. That means the *order and identity* of the
// model mutations must match, not the code that issues them. So the tools build the same
// `CircuitMutation` in the same order Java does, and hand it to `doAction` at the same moment.
// The seam is allowed to differ; what crosses it is not.
//
// ── D9 ──────────────────────────────────────────────────────────────────────────────────────
//
// Nothing here pushes a UI type downward: these protocols live in `LogisimUI`, and their
// parameters are `LogisimKernel`/`LogisimFile` model types plus value types declared here.
// `NSCursor` appears in `CanvasTool.cursor` because a cursor is UI and this *is* the UI layer.

import AppKit
import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

// MARK: - Action names

/// `com.cburch.logisim.util.StringGetter`, restricted to what the tools produce.
///
/// Upstream's action names are lazily-resolved resource-bundle lookups, because an undo-stack
/// label has to follow a language change made after the action was recorded. Localisation is a
/// UI concern that this port has not built yet (D5 makes the same call for attribute display
/// names), so what is carried is the *key and its arguments*: enough for the UI to resolve, and
/// enough for a differential test to assert which action was produced without depending on a
/// translation.
public struct ToolActionName: Hashable, Sendable {
  /// The `Strings.S` key, e.g. `"addWireAction"`.
  public var key: String
  /// Arguments upstream passes as further `StringGetter`s, already resolved to their keys or
  /// literal display names.
  public var arguments: [String]

  public init(_ key: String, _ arguments: String...) {
    self.key = key
    self.arguments = arguments
  }

  public init(key: String, arguments: [String]) {
    self.key = key
    self.arguments = arguments
  }

  // The exact set the six tools raise. Kept as constants so a typo is a compile error rather
  // than a wrong undo label.
  public static let addWire = ToolActionName("addWireAction")
  public static let addWires = ToolActionName("addWiresAction")
  public static let shortenWire = ToolActionName("shortenWireAction")
  public static let changeComponentAttributes =
    ToolActionName("changeComponentAttributesAction")
  public static let selectionReface = ToolActionName("selectionRefaceAction")
  public static func addComponent(_ displayName: String) -> ToolActionName {
    ToolActionName("addComponentAction", displayName)
  }
  public static func removeComponent(_ displayName: String) -> ToolActionName {
    ToolActionName("removeComponentAction", displayName)
  }
  /// `MenuTool`'s rotate items (`tools.properties:30`, `rotateComponentAction = Rotate %s`).
  /// Distinct from `selectionReface`, which is `EditTool`'s whole-selection turn.
  public static func rotateComponent(_ displayName: String) -> ToolActionName {
    ToolActionName("rotateComponentAction", displayName)
  }

  /// What `Action.name` reports; the Edit menu's "Undo <name>".
  ///
  /// `Action.name` is a plain `String` because `com.cburch.logisim.proj.Action.getName()` is, and
  /// because localisation is a UI-layer concern this port has not built (D5's closing note). So a
  /// `ToolActionName` has to render itself at the moment it becomes an `Action`, which loses the
  /// re-resolve-on-language-change property upstream's `StringGetter` has. That is a known,
  /// bounded gap: it costs an undo label that does not re-translate until the next edit, and it
  /// buys keeping the structured key available to a differential test right up to the boundary.
  /// The English rendering is upstream's `en` bundle for these seven keys.
  public var displayName: String {
    switch key {
    case "addWireAction": return "Add Wire"
    case "addWiresAction": return "Add Wires"
    case "shortenWireAction": return "Shorten Wire"
    case "changeComponentAttributesAction": return "Change Attribute"
    // `std.properties:403`. Without this arm the Edit menu reads "Undo changeLabelAction";
    // `default` returns the raw key, so a missing case is a user-visible string, not a fallback.
    case "changeLabelAction": return "Change Label"
    case "selectionRefaceAction": return "Reface Selection"
    case "addComponentAction": return "Add \(arguments.first ?? "Component")"
    case "removeComponentAction": return "Remove \(arguments.first ?? "Component")"
    case "rotateComponentAction": return "Rotate \(arguments.first ?? "Component")"
    default: return key
    }
  }
}

/// The messages upstream shows in the canvas status strip via `Canvas.setErrorMessage`.
///
/// D9 again: the model-side decision ("this edit is refused, and why") is behaviour and comes
/// across; rendering it is the shell's. `computing` carries its delta because
/// `SelectTool.clearCanvasMessage` compares the delta before clearing; a message for a *stale*
/// drag position must not clear the current one (`SelectTool.java:132-140`).
public enum ToolStatusMessage: Hashable, Sendable {
  /// `cannotModifyError`; the circuit is not part of this project's file.
  case cannotModify
  /// `exclusiveError`; an exclusive end would collide.
  case exclusive
  // `negativeCoordError` is deliberately absent. Upstream raises it when a placement would sit
  // at a negative coordinate; this port has no origin wall (see `SelectTool.computeDxDy`), so
  // nothing can produce it and a case nothing can produce is an inert surface.
  /// `circularError`; placing this subcircuit would create a cycle.
  case circular
  /// `moveWorkingMsg`: upstream's `SelectTool.ComputingMessage`, drawn in green.
  case computingMove(dx: Int, dy: Int)
  /// An already-rendered message with no case of its own.
  ///
  /// The selection slice raises its refusals as plain strings (`Project.setErrorMessage`), which
  /// is what `Frame.getCanvas().setErrorMessage(StringGetter)` receives upstream. Keeping the
  /// five *tool* refusals as cases and giving everything else this one arm preserves the property
  /// that matters, a test can assert `.circular` without matching on English, without forcing
  /// the whole paste path to enumerate its messages before anything renders them.
  case literal(String)
}

// MARK: - Subscriptions

/// D3's standard shape: the publisher holds this weakly, the token holds the listener strongly,
/// dropping the token unsubscribes. Same contract as `AttributeSubscription` and
/// `ComponentSubscription` in the layers below.
@MainActor
public final class ToolSubscription {
  private var cancel: (() -> Void)?

  public init(cancel: @escaping () -> Void) {
    self.cancel = cancel
  }

  public func invalidate() {
    cancel?()
    cancel = nil
  }

  deinit { /* the owner calls invalidate(); deinit cannot hop to the main actor */ }
}

/// A weak reference to a main-actor object that may be captured by a `@Sendable` closure.
///
/// The move engine's completion callback is `@Sendable` because it is invoked from the connector
/// thread, but all it wants to do is hop back and touch the canvas. Capturing a `@MainActor`
/// existential directly is (correctly) rejected; boxing it and only ever *reading* the box on the
/// main actor is the sanctioned shape. The `@unchecked` covers the weak slot itself, which is
/// written once at construction and never again.
/// Not generic: `any ToolCanvas` is an existential, and an existential does not satisfy a
/// `T: AnyObject` constraint even when the protocol is class-bound. A `weak` stored property of
/// the existential type is fine, so the box is written concretely.
public final class WeakToolCanvasRef: @unchecked Sendable {
  private weak var stored: (any ToolCanvas)?

  public init(_ value: (any ToolCanvas)?) { stored = value }

  @MainActor
  public var value: (any ToolCanvas)? { stored }
}

/// Carries a value across an `assumeIsolated` hop that the compiler cannot prove is safe.
///
/// Used only where a `LogisimFile` listener callback, which is declared non-isolated because
/// that target is in Swift 5 language mode per D1, delivers a non-`Sendable` event that this
/// layer knows is being fired on the main actor. `assumeIsolated` is synchronous and stays on the
/// calling thread, so nothing actually crosses a boundary; the box exists to say so out loud.
public struct UncheckedSendableBox<T>: @unchecked Sendable {
  public let value: T
  public init(_ value: T) { self.value = value }
}

// MARK: - Canvas

/// `com.cburch.logisim.gui.main.Canvas`, restricted to what the six tools use.
///
/// The camera deliberately is not here. `RenderSeam.swift` records why: upstream entangles zoom
/// and pan with the painting component's preferred size, so every camera change is also a layout
/// change (issue #1262). Tools ask for repaints by *world rectangle* and never learn the zoom.
@MainActor
public protocol ToolCanvas: AnyObject {
  var project: Project { get }
  /// `getCircuit()`.
  var circuit: Circuit? { get }
  /// `getSelection()`: the same object as `project.selection`; both spellings exist upstream
  /// and the tools use both, so both are kept rather than silently normalised. Note the direction
  /// of the dependency in 4.1.0: `Project.getSelection()` is `frame.getCanvas().getSelection()`
  /// (`Project.java:397-402`), so the canvas owns it and the project reaches through.
  var selection: Selection { get }

  /// The location queries `CircuitPoints` answers. See `CircuitPointQueries`.
  var pointQueries: any CircuitPointQueries { get }

  /// `setErrorMessage(StringGetter)` / `setErrorMessage(StringGetter, Color)`.
  func setStatusMessage(_ message: ToolStatusMessage?)
  /// `getErrorMessage()`; read back by `SelectTool.clearCanvasMessage`.
  var statusMessage: ToolStatusMessage? { get }

  /// `repaint()`, whole canvas.
  func repaintAll()
  /// `repaint(int, int, int, int)` in circuit coordinates.
  func repaint(_ bounds: Bounds)
  /// `requestFocusInWindow()`.
  func requestFocus()

  /// `setHighlightedWires(WireSet)`: the poke tool's bus highlight. Nil clears it.
  func setHighlightedWires(_ wires: [Wire]?)

  /// What the active tool wants drawn over the schematic this frame. Replaces upstream's
  /// `Tool.draw(Canvas, ComponentDrawContext)`: D6 forbids a component, or a tool, from
  /// touching a drawing context, so a tool *describes* its overlay and the render surface draws
  /// it. See `ToolOverlay`.
  func setToolOverlay(_ overlay: ToolOverlay)

  /// `setCursor(Cursor)`. Called when a tool's internal state changes the cursor mid-gesture,
  /// which `SelectTool.setState` does.
  func setCursor(_ cursor: NSCursor)

  /// The `PaintContext` a component-authored overlay paints against:
  /// `Canvas.getComponentDrawContext()`, narrowed to the half D6 allows across.
  ///
  /// Only `PokeTool` uses it, and only to ask a live `InstancePoker` to draw its highlight
  /// (`ToolOverlay.scene`). It is on the canvas rather than passed down from the shell because
  /// the context depends on the canvas's *appearance*, gate shape, value colours, print view,
  /// which is exactly what `CanvasAppearance` carries and no tool should have to know about.
  var overlayPaintContext: any PaintContext { get }

  /// The simulation state the poke tool drives. Nil while nothing is simulating; poking is then
  /// inert, exactly as upstream is when `getCircuitState()` has no value for a wire.
  var circuitState: (any ToolCircuitState)? { get }

  /// Run `body` where the live simulation state may safely be touched, and return its result.
  ///
  /// **A poke mutates objects the propagation thread owns.** Not through a proxy that could
  /// marshal them, `PinPoker.handleBitPress` pulls a `PinState` out of the `InstanceState` and
  /// assigns to it directly, so the only thing that can make it safe is mutual exclusion with
  /// the propagation thread. `CircuitEditorCanvas` implements this by taking the simulation's
  /// model lock, the same one the propagation thread holds for one request and the same one
  /// `LogisimFileProjectHost` already takes around every `CircuitMutation`.
  ///
  /// The default runs `body` inline, which is correct for every canvas with no simulation behind
  /// it: a test rig, or the app before a document is open.
  func withSimulation<T>(_ body: () -> T) -> T

  /// Ask the simulation to settle again, after a poke has changed an input.
  ///
  /// Separate from `withSimulation` because it must happen *after* the lock is released: it
  /// queues work for the propagation thread, and that thread needs the lock to do it.
  func simulationDidChange()
}

extension ToolCanvas {
  public func withSimulation<T>(_ body: () -> T) -> T { body() }
  public func simulationDidChange() {}
}

/// The two things `PokeTool` needs from `CircuitState` (M3). Kept minimal on purpose: the poke
/// protocol proper is `LogisimStd.InstancePoker`, which the tool drives directly.
@MainActor
public protocol ToolCircuitState: AnyObject {
  /// `getValue(Location)`, what a `WireCaret` displays.
  func value(at location: Location) -> Value?
  /// The `InstanceState` to hand a component's poker: `LogisimStd`'s protocol, not a new one.
  func instanceState(for component: any Component) -> (any InstanceState)?
}

// MARK: - CircuitPoints

/// The three location queries `com.cburch.logisim.circuit.CircuitPoints` answers, which
/// `Circuit` exposes as `getComponents(Location)`, `getNonWires(Location)` and
/// `getWires(Location)`.
///
/// `Circuit.swift` records these as M3 work, because the real index is built and invalidated by
/// `CircuitWires` as part of the connectivity model. The tools cannot wait for that, the wiring
/// tool's repair and shortening rules are *defined* in terms of them, so this protocol names the
/// three queries, and `ScanningCircuitPointQueries` below answers them by scanning. When M3
/// lands, `CircuitWires` conforms and the scanning implementation is deleted.
///
/// **The semantics that matter, and that a naive implementation gets wrong.** A point registers
/// a component only where the component has an *end*. For a wire that is its two endpoints and
/// nothing in between (`CircuitPoints.java:41-52`). So `getWires(loc)` is "wires that *end* at
/// loc", **not** "wires that pass through loc": the wiring tool relies on that difference when
/// it decides whether a drag shortens an existing wire.
@MainActor
public protocol CircuitPointQueries: AnyObject {
  /// `Circuit.getComponents(Location)`: every component with an end at exactly this point.
  func components(at location: Location) -> [any Component]
  /// `Circuit.getNonWires(Location)`.
  func nonWires(at location: Location) -> [any Component]
  /// `Circuit.getWires(Location)`.
  func wires(at location: Location) -> [Wire]
  /// `Circuit.hasConflict(Component)`: an exclusive end already claimed at one of this
  /// component's end locations.
  func hasConflict(_ component: any Component) -> Bool
  /// `Circuit.getWireSet(Wire)`: the connected run a poke highlights.
  func wireSet(containing wire: Wire) -> [Wire]
}

/// A `CircuitPointQueries` that scans the circuit. Correct, O(n) per query, and explicitly
/// temporary; see the protocol's doc comment.
///
/// It is not merely a stand-in for tests: without it the wiring tool cannot be exercised at all
/// until M3 lands, and an unexercised wiring tool is exactly how off-grid geometry gets into
/// files unnoticed.
@MainActor
public final class ScanningCircuitPointQueries: CircuitPointQueries {
  private unowned let circuit: Circuit

  public init(circuit: Circuit) {
    self.circuit = circuit
  }

  public func components(at location: Location) -> [any Component] {
    // Upstream's `locData.components` is an `ArrayList` filled in the order components reached
    // `CircuitPoints`, i.e. circuit insertion order. `Circuit.components` is non-wires in
    // insertion order followed by wires, which agrees for every query the tools make: all three
    // callers either test emptiness or apply an order-independent rule (see
    // `MoveGesture.findWire`, which returns a result only when there is exactly one candidate).
    circuit.components.filter { $0.endsAt(location) }
  }

  public func nonWires(at location: Location) -> [any Component] {
    circuit.nonWires.filter { $0.endsAt(location) }
  }

  public func wires(at location: Location) -> [Wire] {
    circuit.wires.filter { $0.endsAt(location) }
  }

  public func hasConflict(_ component: any Component) -> Bool {
    // `CircuitPoints.hasConflict` (`CircuitPoints.java:179-190`): true when any *exclusive* end
    // of the candidate lands where an exclusive end already is.
    if component is Wire { return false }
    for end in component.ends where end.isExclusive {
      for other in circuit.nonWires where other !== component {
        for otherEnd in other.ends
        where otherEnd.isExclusive && otherEnd.location == end.location {
          return true
        }
      }
    }
    return false
  }

  public func wireSet(containing wire: Wire) -> [Wire] {
    // `Circuit.getWireSet` walks the connected run through `CircuitWires`. A scan gives the same
    // set: repeatedly absorb wires that share an endpoint with anything already in the run.
    var result: [Wire] = [wire]
    var seen: Set<ObjectIdentifier> = [ObjectIdentifier(wire)]
    var frontier: [Wire] = [wire]
    let all = circuit.wires
    while let current = frontier.popLast() {
      for candidate in all where !seen.contains(ObjectIdentifier(candidate)) {
        if candidate.sharesEnd(with: current) {
          seen.insert(ObjectIdentifier(candidate))
          result.append(candidate)
          frontier.append(candidate)
        }
      }
    }
    return result
  }
}
