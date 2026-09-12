// AddTool.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.tools.{AddTool, FactoryAttributes}),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import AppKit
import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.tools.FactoryAttributes`; the lazily-instantiated attribute set a tool
/// carries for the component it is about to place.
///
/// Upstream's reason for the laziness is that the explorer holds an `AddTool` for **every**
/// component in **every** loaded library, and instantiating each one's attribute set at load time
/// is measurable. The behaviour that matters beyond performance is `isFactoryInstantiated()`: a
/// tool whose set has never been touched reports "all default values", and
/// `LogisimFile`'s writer uses that to decide whether the tool needs an `<a>` block saved for it
/// at all. Get that wrong and every project file grows a tool block for every library component.
/// Deliberately **not** `@MainActor`: it is reached from `AddTool.attributeSet`, which overrides
/// a member of the non-isolated `LogisimFile.Tool` and so cannot be isolated either. See
/// `Tool.swift`'s header. `nonisolated(unsafe)` on the one mutable slot is the honest spelling of
/// what Java relies on; the whole tool graph is EDT-confined, and this port confines it to the
/// main actor by the same convention, with the *checked* isolation starting at `CanvasTool`.
public final class FactoryAttributes {
  private let factory: any ComponentFactory
  private nonisolated(unsafe) var storage: (any AttributeSet)?

  public init(factory: any ComponentFactory) {
    self.factory = factory
  }

  /// Adopt an attribute set that already exists instead of minting one on first access.
  ///
  /// This is what makes the explorer→canvas upgrade share the library tool's set rather than
  /// discard it. Java needs no equivalent because it has one `AddTool` object: the tool the
  /// inspector edits *is* the tool that places. Without this, a user's tool settings never reach
  /// the component they place; see `canvasTool(for:)`.
  ///
  /// `storage` is seeded, so `isFactoryInstantiated` is true from the start. That is the honest
  /// answer: the set exists and is shared, and the writer's question ("has anyone touched this
  /// tool's attributes?") is about the set's *contents*, which are the source's.
  public init(factory: any ComponentFactory, adopting existing: any AttributeSet) {
    self.factory = factory
    self.storage = existing
  }

  /// `getBase()`, instantiating on first access.
  public var base: any AttributeSet {
    if let storage { return storage }
    let created = factory.createAttributeSet()
    storage = created
    return created
  }

  /// `isFactoryInstantiated()`.
  public var isFactoryInstantiated: Bool { storage != nil }
}

/// `com.cburch.logisim.tools.AddTool`; one per placeable component.
///
/// The state machine is four-valued (`SHOW_NONE`, `SHOW_GHOST`, `SHOW_ADD`, `SHOW_ADD_NO`), and
/// the pairing is: `GHOST`/`NONE` is "hovering", `ADD`/`ADD_NO` is "the button is down"; the
/// `_NO` variants mean "the pointer has left the canvas". `setState` is not a plain assignment;
/// asking for `SHOW_GHOST` gets you `SHOW_NONE` when ghosts are switched off or the circuit is
/// read-only, which is how the whole ghost feature is disabled in one place.
///
/// **What did not come across, and why.** Three features are wired through this class upstream
/// and each depends on a subsystem that is not ported:
///
///   * `MatrixPlacerDialog`: a modal dialog that places an N×M grid of the component in one
///     action. D9 keeps dialogs out of this layer; the state (`matrixPlace`) and the placement
///     loop are here, driven by an injected `matrixPlacement` value, so the shell can supply the
///     dialog's answer without this file gaining a dialog.
///   * `AutoLabel`; auto-numbering labels as you place. It reaches into dialogs and into a
///     per-circuit numbering state that lives in `util`; not ported, and faking it would write
///     wrong `label` attributes into saved files.
///   * `KeyConfigurator` (`tools/key`); same gap as in `SelectTool.processKeyEvent`.
///
/// All three are marked at their call sites rather than silently absent.
///
/// ── Why this subclasses `LogisimFile.AddTool`, and the one seam that leaves open ────────────
///
/// Java has one `AddTool`. This port has two, because `LogisimFile` needed a placeable tool at M2
/// , every library in `LogisimStd` is ~200 literal `AddTool(factory:)` calls and `XmlWriter`
/// resolves a saved `<tool>` back through `AddTool.sharesSource`, long before a canvas existed
/// to drive one. That lower `AddTool` is the *identity* half: factory, attribute set, name,
/// `cloneTool`, `sharesSource`. This class is the *editing* half and inherits it, so there is one
/// factory, one attribute set, and one identity, and `XmlWriter.fromTool` resolves an instance of
/// this class exactly as it resolves a library's own.
///
/// **The join the split creates, and where it is made.** The tools sitting in a `Library` are
/// plain `AddTool`s from `LogisimFile`, and their `cloneTool()` returns another plain one, so a
/// tool taken straight out of the explorer is not a `CanvasTool` and cannot drive a canvas.
/// `canvasTool(for:)` below is the upgrade, and `CanvasToolController.upgrade(_:)` is the single
/// place that calls it, on the way from `Project.tool` to `activeTool`. Anything that sets the
/// active tool must go through there; setting `activeTool` from a raw `Tool` is now a type error
/// rather than a runtime surprise, which is the point.
///
/// The upgrade preserves `factory` identity, so the upgraded tool still answers `sharesSource`
/// the same way against the library's original, which is what `XmlWriter.fromTool` asks when it
/// saves a toolbar, and what would silently break if the upgrade built a fresh factory.
///
/// **What the lower `AddTool` does differently, for whoever owns `LogisimFile`:** it builds its
/// attribute set eagerly in `init` (`factory.createAttributeSet()`), where Java's is a lazy
/// `FactoryAttributes`. Upstream's reason is measured: the explorer holds an `AddTool` for every
/// component in every loaded library. `FactoryAttributes` is kept here because
/// `isFactoryInstantiated()` is also *behaviour*, the writer uses it to decide whether a tool
/// needs an `<a>` block at all, but with the base allocating its own set as well, the saving is
/// currently zero and each `AddTool` holds two attribute sets. Worth folding into
/// `LogisimFile.AddTool`; not this slice's file to change.
@MainActor
public final class CanvasAddTool: AddTool, CanvasTool {

  /// `AddTool` has no `_ID` of its own upstream: `getName()` forwards to the factory or the
  /// factory description, because the `.circ` file names the *component*, not the tool. The
  /// string exists only so `CanvasTool.id` has an answer.
  public override nonisolated class var toolId: String { "Add Tool" }

  /// `INVALID_COORD`. `nonisolated` because the stored-property defaults below are evaluated
  /// in an initialiser that overrides the non-isolated base class's.
  private nonisolated static let invalidCoordinate = Int(Int32.min)

  private enum State {
    case none
    case ghost
    case add
    case addOutsideCanvas
  }

  /// `nonisolated` because `attributeSet` overrides a member of the non-isolated base class and
  /// has to read it. See `Tool.swift`'s header on where the `@MainActor` boundary sits: the tool
  /// *object* is reachable from the file layer, only its canvas-facing half is isolated.
  private nonisolated(unsafe) let factoryAttributes: FactoryAttributes
  private var cachedBounds: Bounds?
  private let shouldSnap: Bool

  private var lastX = CanvasAddTool.invalidCoordinate
  private var lastY = CanvasAddTool.invalidCoordinate
  private var state: State = .ghost
  private weak var lastAddition: Action?
  private var matrixPlace = false

  /// `AppPreferences.ADD_SHOW_GHOSTS` and `ADD_AFTER`, pushed in by the shell (D9).
  ///
  /// `nonisolated(unsafe)` so `cloneTool()`, which overrides a non-isolated base member, can
  /// carry them across. Both are plain `Bool`s written once by the shell at startup and read
  /// thereafter; the alternative was to silently drop them on clone, which would reset a user's
  /// ghost and add-after preferences every time the explorer handed over a tool.
  public nonisolated(unsafe) var showsGhosts = true
  /// `ADD_AFTER_EDIT` is upstream's default (`AppPreferences.java:676`): after placing, switch
  /// back to the edit tool.
  public nonisolated(unsafe) var switchesToEditToolAfterAdding = true

  /// Where the matrix placement dialog's answer arrives from. `nil` means single placement, which
  /// is upstream's `new MatrixPlacerInfo(label)` with its 1×1 default.
  public var matrixPlacement: (() -> MatrixPlacement?)?

  /// The designated initialiser. `existing` is the attribute set this tool should use; `nil`
  /// mints a fresh lazy one, which is the plain `AddTool(factory:)` case.
  ///
  /// `nonisolated` so `cloneTool()`, which overrides a non-isolated base member, can call it.
  public nonisolated init(factory: any ComponentFactory, adopting existing: (any AttributeSet)?) {
    let attributes =
      existing.map { FactoryAttributes(factory: factory, adopting: $0) }
      ?? FactoryAttributes(factory: factory)
    self.factoryAttributes = attributes
    // `getFeature(SHOULD_SNAP, attrs)`; null means yes.
    //
    // Divergence worth knowing: Java passes the *unforced* `FactoryAttributes` here
    // (`AddTool.java:134`), and `getFeature` does not dereference it, so the set stays lazy.
    // Reading `.base` forces it. Harmless while the base class allocates eagerly anyway; it is
    // the second half of the note in the class comment and both should be fixed together.
    let value = factory.feature(.shouldSnap, attributes.base) as? Bool
    self.shouldSnap = value ?? true
    super.init(factory: factory)
  }

  public override nonisolated convenience init(factory: any ComponentFactory) {
    self.init(factory: factory, adopting: nil)
  }

  /// Upgrade a library's plain `AddTool` into one that can drive a canvas. See the class comment:
  /// this is the call the explorer→canvas wiring owes, and the reason it is a factory function
  /// rather than an initialiser is that a tool already of this class must be returned unchanged;
  /// re-wrapping would break the identity comparisons `sharesSource` and the toolbar depend on.
  public static func canvasTool(for tool: AddTool) -> CanvasAddTool {
    if let already = tool as? CanvasAddTool { return already }
    // Shares the source's attribute set rather than minting a fresh one. Java has no upgrade
    // step at all, the tool the inspector edits *is* the tool that places, so sharing, not
    // copying, is what reproduces it. Minting a fresh set silently dropped every tool attribute
    // the user configured before placing; the edit-parity gate's `10-tool-attributes` script is
    // the regression test.
    return CanvasAddTool(factory: tool.factory, adopting: tool.attributeSet)
  }

  public nonisolated var descriptionKey: String { "addToolText" }
  public var cursor: NSCursor { .crosshair }

  /// `getAttributeSet()`. Overrides the base's eagerly-built set with the lazy one; see the class
  /// comment.
  public override nonisolated var attributeSet: (any AttributeSet)? { factoryAttributes.base }

  /// `getFactory()`. `factory` itself is inherited and public on the base.
  public nonisolated var componentFactory: any ComponentFactory { factory }

  /// `cloneTool()`; the explorer's prototype is cloned before it is used on a canvas, so that
  /// editing the placed tool's attributes does not edit the library's.
  ///
  /// `nonisolated` to match the base. The two preference flags it carries across are plain `Bool`s
  /// declared `nonisolated(unsafe)` for exactly this call; see their declarations.
  ///
  /// `sharesSource` is **not** overridden here, and that is deliberate rather than an omission:
  /// `LogisimFile.AddTool`'s version already tests `other as? LogisimFile.AddTool` and compares
  /// factories by reference, so it matches a library's plain tool against this class's upgrade of
  /// it. The override this class used to carry tested `other as? AddTool` against the *UI* class
  /// and would have answered `false` for exactly that pair, which is the case that matters, since
  /// it is what `XmlWriter.fromTool` asks when saving a toolbar.
  public override nonisolated func cloneTool() -> Tool {
    // `new AddTool(this)` → `this.attrs = (AttributeSet) base.attrs.clone()` (AddTool.java:107).
    // A copy, not a share: cloning is what keeps editing a placed tool's attributes from editing
    // the library's, which is the whole reason the explorer clones its prototype.
    let copy = CanvasAddTool(factory: factory, adopting: attributeSet?.copy())
    copy.showsGhosts = showsGhosts
    copy.switchesToEditToolAfterAdding = switchesToEditToolAfterAdding
    return copy
  }

  // MARK: Overlay

  public func overlay(for canvas: any ToolCanvas) -> ToolOverlay {
    // Upstream's guard, attributed in its own comment to a repaint problem on OpenJDK/Ubuntu; it
    // is also simply correct; there is nothing to ghost before the pointer has been seen.
    guard lastX != CanvasAddTool.invalidCoordinate, lastY != CanvasAddTool.invalidCoordinate else {
      return .empty
    }
    let isCommitted: Bool
    switch state {
    case .ghost: isCommitted = false
    case .add: isCommitted = true
    case .none, .addOutsideCanvas: return .empty
    }

    let origin = Location.create(lastX, lastY, hasToSnap: false)
    var items: [ToolOverlayItem] = [
      .placementGhost(
        factory: ComponentFactoryRef(factory), at: origin, isCommitted: isCommitted,
        needsLabel: false)
    ]
    if matrixPlace {
      // The three extra ghosts upstream draws to preview a matrix, offset by the component's own
      // size plus 3.
      let bounds = factory.offsetBounds(factoryAttributes.base)
      let dx = wrap32(bounds.width &+ 3)
      let dy = wrap32(bounds.height &+ 3)
      for offset in [(dx, 0), (0, dy), (dx, dy)] {
        items.append(
          .placementGhost(
            factory: ComponentFactoryRef(factory),
            at: Location.create(
              wrap32(lastX &+ offset.0), wrap32(lastY &+ offset.1), hasToSnap: false),
            isCommitted: isCommitted, needsLabel: false))
      }
    }
    return ToolOverlay(items: items)
  }

  /// `getBounds()`: the repaint box, which is *twice* the component's size expanded by 5 so that
  /// a matrix preview is covered too.
  private var repaintBounds: Bounds {
    if let cachedBounds { return cachedBounds }
    let bounds = factory.offsetBounds(factoryAttributes.base)
    let doubled = Bounds.create(
      bounds.x, bounds.y, wrap32(bounds.width &* 2), wrap32(bounds.height &* 2))
    let result = doubled.expand(5)
    cachedBounds = result
    return result
  }

  // MARK: Mouse

  public func mouseEntered(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent) {
    switch state {
    case .ghost, .none:
      setState(canvas, .ghost)
      canvas.requestFocus()
    case .addOutsideCanvas:
      setState(canvas, .add)
      canvas.requestFocus()
    case .add:
      break
    }
  }

  public func mouseExited(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent) {
    switch state {
    case .ghost:
      moveTo(canvas, x: CanvasAddTool.invalidCoordinate, y: CanvasAddTool.invalidCoordinate)
      setState(canvas, .none)
    case .add:
      moveTo(canvas, x: CanvasAddTool.invalidCoordinate, y: CanvasAddTool.invalidCoordinate)
      setState(canvas, .addOutsideCanvas)
    case .none, .addOutsideCanvas:
      break
    }
  }

  public func mouseMoved(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent) {
    guard state != .none else { return }
    if shouldSnap { event.snapToGrid() }
    moveTo(canvas, x: event.x, y: event.y)
  }

  public func mouseDragged(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent) {
    guard state != .none else { return }
    if shouldSnap { event.snapToGrid() }
    moveTo(canvas, x: event.x, y: event.y)
  }

  public func mousePressed(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent) {
    guard let circuit = canvas.circuit else { return }
    guard canvas.project.fileContains(circuit) else {
      canvas.setStatusMessage(.cannotModify)
      return
    }
    // The subcircuit cycle check: placing a circuit inside itself, directly or transitively.
    if let subFactory = factory as? any SubcircuitFactory,
      let subcircuit = subFactory.subcircuit as? Circuit,
      !canvas.project.canAddSubcircuit(subcircuit, to: circuit)
    {
      canvas.setStatusMessage(.circular)
      return
    }

    if shouldSnap { event.snapToGrid() }
    moveTo(canvas, x: event.x, y: event.y)
    setState(canvas, .add)
  }

  public func mouseReleased(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent) {
    var added: [any Component] = []

    switch state {
    case .add:
      if let placed = performPlacement(canvas, &event) {
        added = placed
      }
      setState(canvas, .ghost)
      matrixPlace = false
    case .addOutsideCanvas:
      setState(canvas, .none)
    case .none, .ghost:
      break
    }

    // `determineNext(Project)`, the ADD_AFTER preference.
    guard switchesToEditToolAfterAdding, let next = canvas.project.editTool else { return }
    canvas.project.setTool(next)
    canvas.project.perform { try SelectionActions.dropAll(canvas.selection) }
    if !added.isEmpty {
      canvas.selection.addAll(added)
    }
  }

  /// The placement itself (`AddTool.java:497-609`).
  ///
  /// A refusal happens **inside** the loop and abandons the whole placement, matrix and all: an
  /// exclusive-end conflict returns before the mutation is pushed, so a partially-built matrix is
  /// never committed: worth preserving exactly, because the alternative silently leaves half a
  /// matrix on the sheet.
  ///
  /// ── DELIBERATE DIVERGENCE: the negative-coordinate refusal is gone ──────────────────────
  ///
  /// Upstream has a second refusal here, `if (bds.getX() < 0 || bds.getY() < 0)
  /// setErrorMessage(negativeCoordError)`, and it goes with the drag clamp in
  /// `SelectTool.computeDxDy`, for the reason recorded there: upstream's sheet begins at the
  /// origin because its canvas is a `JScrollPane` over a content-sized component, and this
  /// port's camera is unbounded. Keeping one without the other would give an app where a gate
  /// can be *dragged* above the origin but not *placed* there, which is worse than either
  /// choice on its own.
  /// `ToolStatusMessage.negativeCoordinate` was removed with it rather than left as a message
  /// nothing can produce.
  private func performPlacement(
    _ canvas: any ToolCanvas, _ event: inout ToolMouseEvent
  ) -> [any Component]? {
    guard let circuit = canvas.circuit, canvas.project.fileContains(circuit) else { return nil }
    if shouldSnap { event.snapToGrid() }
    moveTo(canvas, x: event.x, y: event.y)

    let attributes = factoryAttributes.base
    // `AutoLabel` is not ported; upstream would fill in an auto-numbered label here when the
    // auto-labeller is active. What survives is the plain case: whatever label the tool's own
    // attributes carry.
    let label: String? =
      attributes.containsAttribute(StdAttr.label) ? attributes[StdAttr.label] : nil

    let matrix = matrixPlace ? (matrixPlacement?() ?? .single) : .single

    let mutation = canvas.project.beginMutation(on: circuit)
    var added: [any Component] = []
    for x in 0..<matrix.copiesX {
      for y in 0..<matrix.copiesY {
        let location = Location.create(
          wrap32(event.x &+ wrap32(matrix.deltaX &* x)),
          wrap32(event.y &+ wrap32(matrix.deltaY &* y)),
          hasToSnap: true)
        let attributesCopy = attributes.copy()
        if let label {
          // D13: a set that rejects `label` is a broken factory, not bad input; the placement is
          // abandoned rather than the process.
          guard (try? attributesCopy.setValue(StdAttr.label, label)) != nil else { return nil }
        }
        guard
          let component = try? factory.createComponent(
            location: location, attributes: attributesCopy)
        else { return nil }

        if canvas.pointQueries.hasConflict(component) {
          canvas.setStatusMessage(.exclusive)
          return nil
        }
        mutation.add(component)
        added.append(component)
      }
    }

    let action = mutation.toAction(.addComponent(factory.displayName))
    // Recorded only when the edit actually went through: upstream's `proj.doAction` throwing
    // would skip this assignment, and Backspace must not claim an edit that did not happen.
    if canvas.project.perform({ action }) {
      lastAddition = action
    }
    canvas.repaintAll()
    return added
  }

  // MARK: Keys

  public func keyPressed(_ canvas: any ToolCanvas, _ event: inout ToolKeyEvent) {
    // `processKeyEvent`: the `tools/key` configurator dispatch. Same gap as
    // `SelectTool.keyConfiguratorDispatch`, and it runs *first* upstream, so a component that
    // binds a key here currently sees nothing.
    guard !event.isConsumed else { return }

    switch event.command {
    case .toggleMatrixPlacement:
      matrixPlace.toggle()
      canvas.repaintAll()

    case .face(let direction):
      setFacing(canvas, direction)

    case .rotatePendingComponent:
      // Upstream's cycle is N → E → S → W → N, with anything unrecognised falling to N.
      let next: Direction
      switch currentFacing {
      case .north: next = .east
      case .east: next = .south
      case .south: next = .west
      case .west: next = .north
      }
      setFacing(canvas, next)

    case .cancelPlacement:
      guard let editTool = canvas.project.editTool else { return }
      canvas.project.setTool(editTool)
      canvas.project.perform { try SelectionActions.dropAll(canvas.selection) }

    case .undoOwnLastPlacement:
      if let last = lastAddition, canvas.project.lastAction === last {
        canvas.project.undoActionReportingFailure()
        lastAddition = nil
      }

    default:
      break
    }
  }

  /// `getFacing()` / `setFacing(Canvas, Direction)`.
  ///
  /// Upstream pushes the change through `ToolAttributeAction`, so rotating the pending component
  /// is itself undoable. `SetAttributeAction` covers the same ground here; the tool's prototype
  /// is not in the circuit, so the write takes its direct branch and records the old value for
  /// the undo.
  private var currentFacing: Direction {
    let base = factoryAttributes.base
    guard let attribute = facingAttribute else { return .north }
    return base[attribute] ?? .north
  }

  private var facingAttribute: Attribute<Direction>? {
    factory.feature(.facingAttribute, factoryAttributes.base) as? Attribute<Direction>
  }

  private func setFacing(_ canvas: any ToolCanvas, _ facing: Direction) {
    guard let attribute = facingAttribute, let circuit = canvas.circuit else { return }
    // The prototype has no component to attach to, so the write is recorded against a synthetic
    // holder. `SetAttributeAction` keys on the component only to ask the circuit whether it
    // contains it; a tool prototype never does, so the direct branch always runs.
    let action = SetAttributeAction(circuit: circuit, name: .changeComponentAttributes)
    action.setToolAttribute(factoryAttributes.base, attribute, facing)
    canvas.project.perform { action }
    cachedBounds = nil
  }

  // MARK: State

  public func select(_ canvas: any ToolCanvas) {
    setState(canvas, .ghost)
    cachedBounds = nil
  }

  public func deselect(_ canvas: any ToolCanvas) {
    setState(canvas, .ghost)
    moveTo(canvas, x: CanvasAddTool.invalidCoordinate, y: CanvasAddTool.invalidCoordinate)
    cachedBounds = nil
    lastAddition = nil
    matrixPlace = false
  }

  /// `setState(Canvas, int)`; note the asymmetry: only `SHOW_GHOST` is filtered.
  private func setState(_ canvas: any ToolCanvas, _ value: State) {
    guard value == .ghost else {
      state = value
      return
    }
    let circuitIsWritable = canvas.circuit.map { canvas.project.fileContains($0) } ?? false
    state = (circuitIsWritable && showsGhosts) ? .ghost : .none
  }

  /// `moveTo(Canvas, Graphics, int, int)`: exposes the old and new ghost boxes for repaint.
  private func moveTo(_ canvas: any ToolCanvas, x: Int, y: Int) {
    if state != .none { expose(canvas, x: lastX, y: lastY) }
    lastX = x
    lastY = y
    if state != .none { expose(canvas, x: lastX, y: lastY) }
  }

  private func expose(_ canvas: any ToolCanvas, x: Int, y: Int) {
    guard x != CanvasAddTool.invalidCoordinate, y != CanvasAddTool.invalidCoordinate else { return }
    let bounds = repaintBounds
    canvas.repaint(
      Bounds.create(
        wrap32(x &+ bounds.x), wrap32(y &+ bounds.y), bounds.width, bounds.height))
  }
}

/// `com.cburch.logisim.tools.MatrixPlacerInfo`, reduced to the four numbers the placement loop
/// reads. The dialog that fills it in belongs to the shell (D9).
public struct MatrixPlacement: Hashable, Sendable {
  public var copiesX: Int
  public var copiesY: Int
  public var deltaX: Int
  public var deltaY: Int
  public var label: String?

  public init(copiesX: Int, copiesY: Int, deltaX: Int, deltaY: Int, label: String? = nil) {
    self.copiesX = copiesX
    self.copiesY = copiesY
    self.deltaX = deltaX
    self.deltaY = deltaY
    self.label = label
  }

  /// `new MatrixPlacerInfo(label)`, one copy, no offset.
  public static let single = MatrixPlacement(copiesX: 1, copiesY: 1, deltaX: 0, deltaY: 0)
}

extension SetAttributeAction {
  /// `ToolAttributeAction.create(Tool, Attribute, Object)`.
  ///
  /// A tool's prototype attribute set has no component behind it, so the component-keyed `set`
  /// does not fit. This records the write directly against the set, which is what
  /// `SetAttributeAction.doIt`'s not-in-circuit branch does anyway, so the undo behaviour is
  /// identical.
  public func setToolAttribute<V>(
    _ attributes: any AttributeSet, _ attribute: Attribute<V>, _ value: V?
  ) {
    setDirect(attributes, attribute, value)
  }
}
