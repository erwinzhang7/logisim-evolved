// TextTool.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.tools.TextTool),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import AppKit
import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimStd

/// `com.cburch.logisim.tools.TextTool`: edits an existing text-bearing component's text, or
/// creates a free-standing text label.
///
/// **The whole tool is one state machine around a caret, and the interesting part is what happens
/// when editing stops.** Three outcomes, and each produces a different model mutation, which is
/// exactly the sort of thing M7's gate measures:
///
///   * created a new label and the text is non-empty → **add** the component;
///   * an existing free-standing `Text` component whose text is now empty → *meant* to remove it,
///     and upstream instead emits an add that does nothing. See `editingStopped`: the bug is
///     reproduced deliberately, with the reasoning written out there;
///   * anything else → ask the component for its own commit action, which is typically a
///     `SetAttributeAction` on its label attribute.
///
/// The second case applies only to components whose *factory is `Text`*; emptying the label of a
/// gate leaves the gate alone.
@MainActor
public final class TextTool: Tool, CanvasTool {

  /// `_ID`. Declared as `Tool.toolId`, the base class's overridable identity, so the
  /// `.circ` codec in `LogisimFile` can read it without hopping to the main actor.
  /// `CanvasTool.id` is the same string; see `CanvasTool`'s extension.
  public override nonisolated class var toolId: String { "Text Tool" }

  public var displayNameKey: String { "textTool" }
  public var descriptionKey: String { "textToolDesc" }
  public var cursor: NSCursor { .iBeam }

  /// The prototype attribute set new labels are created from; `Text.FACTORY.createAttributeSet()`
  /// upstream. Injected because `std.base.Text` belongs to the component library (M4/M5) and this
  /// slice must not depend on it having landed; the shell supplies the factory it finds in the
  /// base library, which is also how `AddTool` is constructed.
  private let textFactory: (any ComponentFactory)?
  private nonisolated(unsafe) let prototypeAttributes: (any AttributeSet)?

  private var caret: (any Caret)?
  private var isCreatingText = false
  private weak var caretCanvas: (any ToolCanvas)?
  private var caretCircuit: Circuit?
  private var caretComponent: (any Component)?
  private var caretListener: TextCaretListener?

  public init(textFactory: (any ComponentFactory)? = nil) {
    self.textFactory = textFactory
    self.prototypeAttributes = textFactory?.createAttributeSet()
  }

  /// `nonisolated` because it overrides a member of the non-isolated `LogisimFile.Tool`,
  /// which the `.circ` codec reads. See `Tool.swift`'s header on the boundary.
  public override nonisolated var attributeSet: (any AttributeSet)? { prototypeAttributes }

  /// The `Graphics` argument both of `mousePressed`'s lookups take; see there.
  ///
  /// A named member rather than a local so the measurer is assertable. It is the one thing about
  /// this fix no output can check: swapping `canvasMeasurer` for `NominalTextMeasurer` here
  /// changes the hit box by a pixel or two and reddens *nothing*, measured, board #84's probe 5
  /// , because every scripted click lands well inside the box either way. The failure it would
  /// cause is the user-visible one that no gate sees: a click that finds the component and is
  /// then refused by `textCaret`, which measures with `canvasMeasurer`, so the caret never opens
  /// and the click appears to do nothing.
  static var hitTestMetrics: StdComponentTextFieldMetrics {
    StdComponentTextFieldMetrics(measurer: InstanceTextField.canvasMeasurer)
  }

  // MARK: Overlay

  public func overlay(for canvas: any ToolCanvas) -> ToolOverlay {
    // `scene:` is not optional decoration: `ToolOverlayItem` is a closed enum of nine fixed tool
    // shapes and cannot express a text caret, so the edit box, selection band and cursor rule all
    // travel through `overlayScene`; the same vehicle `InstancePokerCaret` uses. Dropping it left
    // the caret fully live but *invisible*: typing, selection and commit all worked and nothing
    // drew.
    guard let caret else { return .empty }
    return ToolOverlay(
      items: caret.overlayItems,
      scene: caret.overlayScene(context: canvas.overlayPaintContext))
  }

  // MARK: Mouse

  public func mousePressed(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent) {
    let project = canvas.project
    guard let circuit = canvas.circuit else { return }

    // Upstream's comment: "This is made to remove an annoying bug that do not unselect current
    // selection". It drops the whole selection on every press, unconditionally, *before* the
    // read-only check: so pressing in a library circuit still clears the selection.
    project.perform { try SelectionActions.dropAll(canvas.selection) }

    guard project.fileContains(circuit) else {
      caret?.cancelEditing()
      canvas.setStatusMessage(.cannotModify)
      return
    }

    // Maybe the user is clicking within the current caret.
    if let existing = caret {
      if existing.bounds.contains(event.x, event.y) {
        existing.mousePressed(&event)
        project.repaintCanvas()
        return
      }
      existing.stopEditing()
      // `stopEditing` runs the listener below, which clears `caret`.
    }

    let point = Location.create(event.x, event.y, hasToSnap: false)
    let userEvent = ComponentUserEvent(x: event.x, y: event.y, state: canvas.circuitState)

    // First search in the selection, then in the circuit. The order is upstream's and it matters
    // when two text-bearing components overlap: the selected one wins.
    //
    // **Both scans take the TWO-argument `contains`**: `Selection.getComponentsContaining(loc,
    // g)` at `TextTool.java:267` and `Circuit.getAllContaining(loc, g)` at `:282`. That is the
    // predicate that is true for a point inside a component's *label box*, and it is the only
    // reason clicking a label edits that label: for most factories the label is drawn above the
    // body and is therefore nowhere inside `bounds`. With the one-argument predicate both scans
    // come back empty and control falls into `createTextComponent` below, dropping a stray `Text`
    // annotation where the user meant to retype a label. See `ComponentTextFieldMetrics`.
    //
    // `hitTestMetrics` measures with `canvasMeasurer`: the one `InstanceTextField.textCaret`
    // hit-tests the caret with and the one the canvas draws with, so the box a click has to land
    // in is the box the user is looking at. See that property for why it is a named member.
    let metrics = TextTool.hitTestMetrics
    // `Selection.getComponentsContaining(Location, Graphics)`. Spelled out here rather than added
    // to `SelectionBase` because that file belongs to another slice; the body is its
    // one-argument sibling with the predicate swapped, over the same `unionSet` order.
    let inSelection = canvas.selection.components.filter { metrics.contains($0, point) }
    if let found = findEditable(in: inSelection, userEvent) {
      adopt(found, circuit: circuit, project: project, creating: false)
    } else if let found = findEditable(in: circuit.allContaining(point, metrics: metrics), userEvent)
    {
      adopt(found, circuit: circuit, project: project, creating: false)
    } else if let created = createTextComponent(at: point, userEvent: userEvent) {
      adopt(created, circuit: circuit, project: project, creating: true)
    }

    if caret != nil {
      caretCanvas = canvas
      caretCircuit = circuit
      let listener = TextCaretListener(tool: self)
      caretListener = listener
      caret?.addCaretListener(listener)
      circuit.addCircuitListener(listener)
    }
    project.repaintCanvas()
  }

  public func mouseDragged(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent) {
    guard let circuit = canvas.circuit else { return }
    guard canvas.project.fileContains(circuit) else {
      caret?.cancelEditing()
      canvas.setStatusMessage(.cannotModify)
      return
    }
    guard let caret else { return }
    caret.mouseDragged(&event)
    canvas.project.repaintCanvas()
  }

  public func mouseReleased(_ canvas: any ToolCanvas, _ event: inout ToolMouseEvent) {
    guard let circuit = canvas.circuit else { return }
    guard canvas.project.fileContains(circuit) else {
      caret?.cancelEditing()
      canvas.setStatusMessage(.cannotModify)
      return
    }
    guard let caret else { return }
    caret.mouseReleased(&event)
    canvas.project.repaintCanvas()
  }

  // MARK: Keys

  public func keyPressed(_ canvas: any ToolCanvas, _ event: inout ToolKeyEvent) {
    guard let caret else { return }
    caret.keyPressed(&event)
    canvas.project.repaintCanvas()
  }

  public func keyReleased(_ canvas: any ToolCanvas, _ event: inout ToolKeyEvent) {
    guard let caret else { return }
    caret.keyReleased(&event)
    canvas.project.repaintCanvas()
  }

  public func keyTyped(_ canvas: any ToolCanvas, _ event: inout ToolKeyEvent) {
    guard let caret else { return }
    caret.keyTyped(&event)
    canvas.project.repaintCanvas()
  }

  // MARK: Lifecycle

  public func deselect(_ canvas: any ToolCanvas) {
    caret?.stopEditing()
    caret = nil
  }

  // MARK: Caret plumbing

  private struct Adoption {
    let component: any Component
    let caret: any Caret
  }

  private func findEditable(
    in components: [any Component], _ event: ComponentUserEvent
  ) -> Adoption? {
    for component in components {
      guard let editable = component.feature((any TextEditable).self, key: .textEditable) else {
        continue
      }
      if let caret = editable.textCaret(event) {
        return Adoption(component: component, caret: caret)
      }
    }
    return nil
  }

  /// The "if nothing found, create a new label" branch (`TextTool.java:296-307`).
  ///
  /// **Upstream's negative-coordinate guard is deliberately gone**, with the two in `AddTool` and
  /// `SelectTool` and for the same reason (recorded in `SelectTool.computeDxDy`). Its
  /// justification here was that a label above the origin sits "off the top-left of the sheet,
  /// where nothing can ever select it again", which was true of a sheet that begins at the
  /// origin, and is not true of an unbounded camera that can simply be panned there.
  private func createTextComponent(
    at point: Location, userEvent: ComponentUserEvent
  ) -> Adoption? {
    guard let factory = textFactory, let prototype = prototypeAttributes else { return nil }
    let attributes = prototype.copy()
    // D13: `createComponent` throws in this port where upstream does not, because a malformed
    // attribute set is reachable from a `.circ` file. Here the set is a fresh copy of the tool's
    // own prototype, so a failure is a broken factory rather than bad input; the label simply is
    // not created, and the user sees nothing happen, which beats taking the app down.
    guard let component = try? factory.createComponent(location: point, attributes: attributes)
    else { return nil }
    guard let editable = component.feature((any TextEditable).self, key: .textEditable),
      let caret = editable.textCaret(userEvent)
    else { return nil }
    return Adoption(component: component, caret: caret)
  }

  private func adopt(
    _ adoption: Adoption, circuit: Circuit, project: Project, creating: Bool
  ) {
    caret = adoption.caret
    caretComponent = adoption.component
    isCreatingText = creating
    project.viewComponentAttributes(circuit, adoption.component)
  }

  /// `MyListener.editingStopped(CaretEvent)` (`TextTool.java:78-123`).
  fileprivate func editingStopped(_ event: CaretEvent) {
    guard let caret, event.caret === caret else {
      // A stale caret reporting in. Upstream unsubscribes and returns.
      if let listener = caretListener { event.caret.removeCaretListener(listener) }
      return
    }
    detachListener()

    let value = caret.text
    let isEmpty = value.isEmpty
    let canvas = caretCanvas
    let circuit = caretCircuit
    let component = caretComponent
    let creating = isCreatingText

    clearCaretState()

    guard let canvas, let circuit, let component else { return }
    let project = canvas.project

    var action: Action?
    if creating {
      if !isEmpty {
        let mutation = project.beginMutation(on: circuit)
        mutation.add(component)
        action = mutation.toAction(.addComponent(component.factory.displayName))
      } else {
        // Don't add the blank text field.
        action = nil
      }
    } else if isEmpty, isTextFactory(component.factory) {
      // ── Ported bug-for-bug. Read this before "fixing" it. ────────────────────────────────
      //
      // Upstream writes `xn.add(caretComponent)` here and labels the action
      // `removeComponentAction` (`TextTool.java:101-104`): an **add** where the branch, the
      // action name and the user's gesture all say remove. The component is already in the
      // circuit, so `Circuit.mutatorAdd` takes its duplicate early return and the mutation does
      // nothing: emptying a text label leaves the blank label in the file, and the undo stack
      // gains an entry called "Remove Text" that removed nothing.
      //
      // It is an obvious one-word bug and it is still reproduced, because M7's pass condition is
      // that a scripted edit sequence byte-matches Java's output. Changing `add` to `remove` here
      // makes the port *better* and makes the gate *fail*; the saved file would be short one
      // `<comp name="Text">` for this gesture. The divergence would also be invisible in review,
      // which is precisely the class of "improvement" that makes a differential port untrustworthy.
      //
      // If this is ever changed, it must be changed together with the gate's expected output and
      // recorded in docs/decisions.md as a deliberate divergence, in the way D8 and D14 are.
      let mutation = project.beginMutation(on: circuit)
      mutation.add(component)
      action = mutation.toAction(.removeComponent(component.factory.displayName))
    } else if let editable = component.feature((any TextEditable).self, key: .textEditable) {
      action = editable.commitAction(
        circuit: circuit, oldText: event.oldText, newText: event.text)
    } else {
      // "should never happen", upstream's own comment.
      action = nil
    }

    project.perform { action }
  }

  /// `MyListener.editingCanceled(CaretEvent)`.
  fileprivate func editingCanceled(_ event: CaretEvent) {
    guard let caret, event.caret === caret else {
      if let listener = caretListener { event.caret.removeCaretListener(listener) }
      return
    }
    detachListener()
    clearCaretState()
  }

  /// `MyListener.circuitChanged(CircuitEvent)`.
  fileprivate func circuitChanged(_ event: CircuitEvent) {
    guard let circuit = caretCircuit, event.circuit === circuit else {
      if let listener = caretListener { event.circuit.removeCircuitListener(listener) }
      return
    }
    switch event.action {
    case .remove:
      if case .component(let removed) = event.data, let component = caretComponent,
        removed === component
      {
        caret?.cancelEditing()
      }
    case .clear:
      if caretComponent != nil { caret?.cancelEditing() }
    default:
      break
    }
  }

  private func detachListener() {
    guard let listener = caretListener else { return }
    caret?.removeCaretListener(listener)
    caretCircuit?.removeCircuitListener(listener)
    caretListener = nil
  }

  private func clearCaretState() {
    caretCircuit = nil
    caretComponent = nil
    isCreatingText = false
    caret = nil
  }

  /// Whether a factory is `std.base.Text`. Identity against the injected factory rather than a
  /// type check, because the component library is not a dependency of this slice.
  private func isTextFactory(_ factory: any ComponentFactory) -> Bool {
    guard let textFactory else { return false }
    return factory === textFactory
  }
}

/// `TextTool.MyListener`, which is both a `CaretListener` and a `CircuitListener`.
@MainActor
final class TextCaretListener: CaretListener, CircuitListener {
  private weak var tool: TextTool?

  init(tool: TextTool) { self.tool = tool }

  func editingCanceled(_ event: CaretEvent) {
    tool?.editingCanceled(event)
  }

  func editingStopped(_ event: CaretEvent) {
    tool?.editingStopped(event)
  }

  nonisolated func circuitChanged(_ event: CircuitEvent) {
    // See `CircuitPokeListener.circuitChanged` for why the box is here rather than a plain
    // capture, and for why this is `onMainActor` and not `MainActor.assumeIsolated`: a kernel
    // `.invalidate` reaches circuit listeners on the propagation thread, where asserting
    // isolation traps the process with no test failure reported (D1's corollary).
    let boxed = UncheckedSendableBox(event)
    onMainActor { [weak self] in
      self?.tool?.circuitChanged(boxed.value)
    }
  }
}
