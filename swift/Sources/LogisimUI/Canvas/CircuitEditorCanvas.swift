// CircuitEditorCanvas.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.gui.main.Canvas, the half
// com.cburch.logisim.tools.Tool talks to), https://github.com/logisim-evolution/logisim-evolution.
// Copyright by the Logisim-evolution developers. This translation is a derivative work and is
// therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ══ SEAM #19: `ToolCanvas` HAD 124 REFERENCES AND NO CONFORMER ══════════════════════════════
//
// Eleven files were written against `ToolCanvas`, all six tools, `CanvasToolController`,
// `Project`, `LogisimFileProjectHost`, `Tool.swift`, `ToolSeams.swift`, and nothing implemented
// it. Every editing gesture in the port was a design with no substrate, which is the same shape
// as the eighteen seams before it: each half correct on its own, nothing owning the join.
//
// This is the conformer. It is a **new object rather than a conformance on
// `CircuitCanvasSurface`**, and that is a decision worth stating because the obvious move is the
// other one:
//
//   * `CircuitCanvasSurface` is the *render* surface. It owns the `CircuitSceneBuild`, hit
//     testing, culling and the offscreen rasteriser, and it deliberately knows nothing about a
//     `Project`, a `Selection` or an undo stack. `ToolCanvas` needs all three; `project` and
//     `selection` are 82 of the 124 references between them.
//   * Upstream's `Canvas` is the union of both: painting *and* selection ownership *and* the
//     tool's error strip. Splitting it is what D6 and `RenderSeam.swift` already decided; the
//     tool half had simply never been built.
//
// So this holds a surface, a project and a selection, and satisfies `ToolCanvas` out of the
// three. `CircuitCanvasSurface` is untouched.
//
// ── What upstream's Canvas has that is deliberately NOT here ────────────────────────────────
//
//   * **The camera.** `RenderSeam.swift` records why at length: upstream entangles zoom and pan
//     with the painting component's preferred size, so every camera change is also a layout
//     change (issue #1262). Tools ask for repaints by world rectangle and never learn the zoom.
//     `ToolCanvas` has no camera member and this adds none.
//   * **The popup menu, the tick counter, the `AutoLabel` bookkeeping.** All shell concerns;
//     `CanvasHostView` already owns the contextual menu and `EditorModel` the tick display.
//   * **A live `CircuitState`.** `circuitState` is a settable slot that stays `nil` in the
//     application today, and that is not laziness: `Project.swift:90-105` records that root
//     `CircuitState`s are created *on the propagation thread*, `SimulationHost` captures
//     `Thread.current` as the thread `Propagator` asserts against at 62 sites (D1), so handing
//     a main-actor object a reference to one would compile and be a data race. Poking is
//     therefore inert in the app, exactly as upstream is with the simulator stopped, and the
//     slot is where that work plugs in when the propagation-thread boundary is decided. A test
//     fills it directly, which is how the poke path below is exercised at all.
//
// ── D3 ──────────────────────────────────────────────────────────────────────────────────────
//
// The canvas holds the project strongly and the project holds the canvas weakly
// (`Project.canvas` is `weak`, and its doc comment says this is "the single most important weak
// edge in the app"). That direction is preserved here by construction: `init` assigns
// `project.canvas = self`.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import AppKit
import CoreGraphics
import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimRenderBackend
import LogisimStd

@MainActor
final class CircuitEditorCanvas: ToolCanvas, ProjectListener {

  // MARK: Collaborators

  let project: Project
  /// The render surface. Strong: the canvas is what owns the drawing half of upstream's
  /// `Canvas`, and nothing else retains the surface once the shell has taken its `renderView`.
  let surface: CircuitCanvasSurface
  /// `getSelection()`. **The canvas owns it and the project reaches through**
  /// (`Project.java:397-402`), which is why `Project.selection` is a computed optional and this
  /// is a stored `let`.
  let selection: Selection

  /// Routes input to the active tool. Constructed here so that a caller gets a canvas that is
  /// already drivable rather than one that needs a second assembly step; the assembly step
  /// being missing is precisely how this seam stayed open.
  private(set) var controller: CanvasToolController!

  private var projectSubscription: ProjectListenerClosure?

  // MARK: - ToolCanvas state

  private(set) var circuit: Circuit?
  private(set) var pointQueries: any CircuitPointQueries
  private(set) var statusMessage: ToolStatusMessage?
  /// `setHighlightedWires(WireSet)`. Stored and pushed to the surface; see `applyHighlight`.
  private(set) var highlightedWires: [Wire]?
  /// The last overlay the active tool asked for, unrendered.
  private(set) var toolOverlay: ToolOverlay = .empty
  /// What that overlay actually produced. This is the number that distinguishes "wired" from
  /// "wired and drawing nothing".
  private(set) var overlayResult = ToolOverlaySceneBuilder.Result()
  private(set) var currentCursor: NSCursor = .arrow

  var circuitState: (any ToolCircuitState)?

  /// `Canvas.getComponentDrawContext()`, narrowed. Derived from the surface's appearance so a
  /// poke highlight is themed like the schematic under it.
  var overlayPaintContext: any PaintContext {
    CircuitSceneSource.paintContext(for: appearance)
  }

  /// **Derived, not stored.** This was `private var appearance = CanvasAppearance()` and nothing
  /// ever assigned it: `CanvasHostNSView.pushAppearance()` resolves the live palette and pushes it
  /// to the *surface* only, and `setAppearance(_:)` below had no callers in `Sources` at all. So
  /// the canvas's idea of the appearance was permanently `.light`, whose `componentStroke` is
  /// `0x000000`, and every tool overlay was built with black ink. Measured on a dark canvas:
  /// preview `#FF000000`, committed wire `#FFE4E4E7`. In light mode both are black, which is why
  /// this survived until someone opened the app in dark mode. The doc comment above already
  /// claimed this value was "derived from the surface's appearance"; now it is.
  private var appearance: CanvasAppearance { surface.appearance }

  // MARK: Instrumentation
  //
  // Counters, not booleans. A repaint that happens once and a repaint that happens on every
  // mouse move are both "true", and the difference is the whole cost model of the canvas.

  private(set) var repaintAllCount = 0
  private(set) var repaintedRects: [Bounds] = []
  private(set) var focusRequestCount = 0

  // MARK: - Construction

  /// The window onto the running simulation, or nil when there is none.
  ///
  /// Nil is the honest state for a test rig and for a canvas built before a document exists; the
  /// app always passes one. See `CanvasSimulation.swift` for why this is a three-member protocol
  /// rather than a reference to `SimulationEngine`.
  private let simulation: (any CanvasSimulationAccess)?

  init(
    project: Project,
    surface: CircuitCanvasSurface,
    circuit: Circuit?,
    initialTool: any CanvasTool,
    simulation: (any CanvasSimulationAccess)? = nil
  ) {
    self.project = project
    self.surface = surface
    self.simulation = simulation
    self.selection = Selection(project: project)
    self.circuit = circuit
    self.pointQueries =
      circuit.map { ScanningCircuitPointQueries(circuit: $0) as any CircuitPointQueries }
      ?? EmptyCircuitPointQueries()

    // D3: the project's edge back is weak, so this cannot make a cycle.
    project.canvas = self
    surface.setCircuit(circuit)

    // **The seam that was never joined.** `circuitState` stayed `nil` in the shipping app because
    // nothing assigned it, the only two assignments in the repository were in test files, so
    // `PokeTool` handed every poker a nil state and poking did nothing at all. Assigned here
    // rather than made a computed property so a test can still substitute its own.
    if let simulation {
      self.circuitState = EngineToolCircuitState(access: simulation)
    }

    controller = CanvasToolController(canvas: self, initialTool: initialTool)
    // Re-theme an overlay that is already on screen. The computed property above fixes the colour
    // of every overlay built *after* a theme change; this fixes the one built *before* it.
    surface.appearanceDidChange = { [weak self] in
      guard let self, !self.toolOverlay.items.isEmpty || self.toolOverlay.scene != nil
      else { return }
      self.renderOverlay()
    }

    // `Project.repaintCanvas()` fires a `.repaintRequest` project event rather than calling the
    // canvas directly (`Project.swift:818-820`), which is upstream's shape. Every tool calls it,
    // so without this subscription two thirds of the tool layer's repaints would go nowhere.
    let listener = ProjectListenerClosure { [weak self] event in
      self?.projectChanged(event)
    }
    projectSubscription = listener
    project.addProjectListener(listener)

    // ── THE SELECTION'S OWN LISTENER, WHICH NOTHING HAD REGISTERED ─────────────────────────
    //
    // Upstream does this in `Selection`'s constructor, not in `Canvas`': `javap -c -classpath
    // logisim-evolution-4.1.0-all.jar com.cburch.logisim.gui.main.Selection` shows
    // `Selection(Project, Canvas)` registering `myListener` with `Project.addProjectListener`
    // (offset 40) *and* `Project.addCircuitListener` (offset 48). The port's `Selection` is
    // constructed without a project reference to register with, `Selection(project:)` takes one
    // but `SelectionBase` holds it weakly for `currentCircuit` lookups only, so the
    // registration landed nowhere and `Selection.projectChanged` was unreachable.
    //
    // What that dead handler does is the undo half of `Selection.MyListener`: it snapshots the
    // selection on `ACTION_START` and replays it on `UNDO_COMPLETE`. Without it, undoing a move
    // leaves the selection holding the component the undo just took *out* of the circuit,
    // which is the same stale-selection defect `SelectTool.commitMove` fixes for the forward
    // direction, reached the other way round. It is user-visible and is not merely cosmetic:
    // `SelectTool.mousePressed`'s first branch tests `selection.componentsContaining(point)`, so
    // a press on the empty patch of canvas where the undone component used to be starts a move
    // of a component that is not there, and releasing commits it as an add. Measured: one drag,
    // one undo, one press-drag on the vacated spot took `circuit.nonWires.count` from 1 to 2.
    //
    // Only the `ProjectListener` half is registered here. Upstream's `CircuitListener` half
    // needs `CircuitEvent.getResult()`, and the port's `CircuitEventData` has no case that can
    // carry a `CircuitTransactionResult`; `Selection.circuitChanged` is empty and says so, and
    // registering it here would add a listener that provably does nothing.
    //
    // That half is delivered by `CircuitTransactionObservers`, which `Selection` registers with
    // **in its own constructor**, exactly where 4.1.0 makes the `addCircuitListener` call
    // (offset 48), so it is not repeated here. It used to be delivered by
    // `SelectTool.commitMove` instead, one call site out of many; see that method for the two
    // measured paths (redo, wire repair) that reached and left stale.
    project.addProjectListener(selection)
  }

  /// `Canvas.setCircuit`: points the whole stack at a different circuit.
  func setCircuit(_ newCircuit: Circuit?) {
    guard circuit !== newCircuit else { return }
    circuit = newCircuit
    pointQueries =
      newCircuit.map { ScanningCircuitPointQueries(circuit: $0) as any CircuitPointQueries }
      ?? EmptyCircuitPointQueries()
    // `Canvas.MyProjectListener.projectChanged`'s `ACTION_SET_CURRENT` arm
    // (`Canvas.java:1065-1069`) clears the error strip and nothing else. Note what it does NOT
    // do: it does not clear the selection. Checked rather than assumed, because clearing looks
    // obviously right and would silently discard floating components that no transaction has
    // re-anchored; `SelectionBase.clear`'s own doc comment is emphatic about that case.
    statusMessage = nil
    setToolOverlay(.empty)
    surface.setCircuit(newCircuit)
    repaintAll()
  }

  /// Palette / grid / gate shape. Pushed through to the surface *and* kept, because the overlay
  /// scene is themed from it too.
  /// Kept, though nothing in `Sources` calls it; the live path is
  /// `CanvasHostNSView.pushAppearance()` → `surface.setAppearance(_:)`, and this canvas now
  /// *derives* from the surface, so the theme reaches the overlay either way. It stays because
  /// a caller pushing an appearance through the canvas is a legitimate thing to want, and it is
  /// now correct rather than a second source of truth that silently disagreed.
  func setAppearance(_ value: CanvasAppearance) {
    guard appearance != value else { return }
    // No local store: `appearance` reads through to the surface, so this IS the assignment.
    surface.setAppearance(value)
    // Re-render the overlay in the new palette. Cheap: it is a handful of primitives, and not
    // doing it leaves a light-mode marquee on a dark canvas after a theme flip (#2661's shape).
    if !toolOverlay.items.isEmpty || toolOverlay.scene != nil {
      renderOverlay()
    }
  }

  // MARK: - ToolCanvas

  func setStatusMessage(_ message: ToolStatusMessage?) {
    statusMessage = message
  }

  /// Mutual exclusion with the propagation thread, for the duration of one poke interaction.
  /// See `ToolCanvas.withSimulation` for why a poke needs it and a proxy cannot replace it.
  func withSimulation<T>(_ body: () -> T) -> T {
    guard let simulation else { return body() }
    return simulation.withModelLock(body)
  }

  /// A poke changed an input; ask the propagation thread to settle the circuit again.
  ///
  /// Called with the model lock **released**; the propagation thread needs that lock to do the
  /// work being requested, so asking for it while holding the lock would queue work behind the
  /// very thing holding it up.
  func simulationDidChange() {
    simulation?.requestPropagate()
  }

  func repaintAll() {
    repaintAllCount += 1
    surface.invalidate(worldRect: nil)
  }

  func repaint(_ bounds: Bounds) {
    repaintedRects.append(bounds)
    surface.invalidate(
      worldRect: CGRect(
        x: CGFloat(bounds.x), y: CGFloat(bounds.y),
        width: CGFloat(bounds.width), height: CGFloat(bounds.height)))
  }

  func requestFocus() {
    focusRequestCount += 1
    // `requestFocusInWindow()`. No window in a test, and no window before the view is attached;
    // both are the same no-op, which is why the counter above exists.
    let view = surface.renderView
    view.window?.makeFirstResponder(view)
  }

  func setHighlightedWires(_ wires: [Wire]?) {
    highlightedWires = wires
    applyHighlight()
  }

  func setToolOverlay(_ overlay: ToolOverlay) {
    toolOverlay = overlay
    renderOverlay()
  }

  func setCursor(_ cursor: NSCursor) {
    currentCursor = cursor
    surface.renderView.window?.invalidateCursorRects(for: surface.renderView)
  }

  // MARK: - Overlay

  private func renderOverlay() {
    overlayResult = ToolOverlaySceneBuilder.build(
      toolOverlay, selectionComponents: selection.components, appearance: appearance)
    surface.setToolOverlay(
      items: overlayResult.itemScene, poke: overlayResult.pokeScene,
      hidden: toolOverlay.hiddenComponents,
      previewOffset: toolOverlay.previewOffset)
  }

  /// `setHighlightedWires(WireSet)`: the poke tool's bus highlight.
  ///
  /// Mapped onto the surface's existing selection channel rather than a second one: a highlighted
  /// run and a selected run are drawn the same way by `CircuitSceneView.drawAdornments`, and
  /// giving the poke tool its own adornment pass would be a third code path drawing a rectangle
  /// round a wire. Stated because it is a *divergence*: upstream draws the highlight in
  /// `Wire.HIGHLIGHTED_STROKE`, a dashed pen, and this draws it as a selection outline.
  private func applyHighlight() {
    guard let wires = highlightedWires, !wires.isEmpty else {
      surface.setHighlight([])
      return
    }
    surface.setHighlight(Set(wires.map { CircuitSceneSource.identity(of: $0) }))
  }

  // MARK: - ProjectListener

  nonisolated func projectChanged(_ event: ProjectEvent) {
    // `ProjectListener` is `@MainActor` (`ProjectEvent.swift:93-96`) and `Project.fireEvent` is
    // called from main-actor code only, so this is a plain isolated call: no hop, no assertion.
    // Kept `nonisolated` so the shape matches `CircuitListener`'s and a reader does not have to
    // check which of the two kinds of listener this is.
    MainActor.assumeIsolated { handle(event) }
  }

  private func handle(_ event: ProjectEvent) {
    switch event.action {
    case .repaintRequest:
      // Re-derive the overlay first: a tool asks for a repaint *after* changing the state the
      // overlay is computed from, so painting before rebuilding would show the previous frame's
      // marquee. This is the single line that makes a drag visible.
      setToolOverlay(controller.activeTool.overlay(for: self))
      repaintAll()
    case .setTool:
      // `Canvas.java:1081-1090`: clear the error strip, then take the tool's cursor. The
      // upgrade from `LogisimFile.Tool` to `CanvasTool` is `CanvasToolController.upgrade`, and
      // a tool with no editing behaviour leaves the current one selected rather than replacing
      // a working tool with an inert one.
      statusMessage = nil
      if let tool = event.tool {
        controller.setActiveTool(fromLibrary: tool)
      } else {
        setCursor(.arrow)
      }
    case .setCurrent:
      statusMessage = nil
    default:
      break
    }
  }
}

// MARK: - EmptyCircuitPointQueries

/// The three `CircuitPoints` queries when there is no circuit.
///
/// `ToolCanvas.pointQueries` is non-optional on purpose; `WiringTool`'s repair and shortening
/// rules are *defined* in terms of these three queries and a nil-check at each of the eight call
/// sites would be eight chances to get the empty case wrong. Answering emptily is the correct
/// behaviour for "no circuit": no wire ends anywhere, nothing conflicts.
@MainActor
final class EmptyCircuitPointQueries: CircuitPointQueries {
  func components(at location: Location) -> [any Component] { [] }
  func nonWires(at location: Location) -> [any Component] { [] }
  func wires(at location: Location) -> [Wire] { [] }
  func hasConflict(_ component: any Component) -> Bool { false }
  func wireSet(containing wire: Wire) -> [Wire] { [wire] }
}
