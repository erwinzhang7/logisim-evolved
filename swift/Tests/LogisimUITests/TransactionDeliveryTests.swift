// LogisimUITests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// EVERY TRANSACTION'S REPLACEMENT MAP REACHES EVERY LIVE SELECTION
//
// `DragDuplicationTests` next door gates the *forward drag*: N drags of one component leave one
// component. That was fixed by scoping a `CircuitTransaction.transactionDone` install around the
// single `project.perform` in `SelectTool.commitMove`, which closed the path it wrapped and no
// other.
//
// This suite is the paths it did not wrap. Two independent reviews found the same hole and it is
// reproduced here first, as numbers, before anything else:
//
//     place a Pin, drag it, UNDO, REDO, then press where the redo vacated and drag
//     circuit.nonWires.count: 1 → 2          (scoped install)  /  1 → 1  (registry)
//
//     select a Pin, DELETE, UNDO, REDO, then press the empty spot and drag
//     circuit.nonWires.count: 0 → 1          (scoped install)  /  0 → 0  (registry)
//
// The cause is one line of `Project.redoAction`: it re-executes the cached `xnForward`
// (`SelectionActions.SelectedComponentsAction.redo`), which is nowhere near `commitMove`. After
// the redo the circuit held `Pin @ (160,100)` and the selection held `Pin @ (100,100)`: the
// selection highlight painting over empty canvas, which is the reporter's "preview in completely
// wrong places" symptom *reproduced after the first fix*. `SelectTool.mousePressed`'s branch 1
// tests `selection.componentsContaining(point)`, so a press on that empty patch starts a move of
// a component that is not there and the release commits it as an add.
//
// A third path, same cause: **wire repair**. `CircuitTransaction.execute`'s repair pass cuts a
// wire where a new component's end lands on it, through the mutator, so the cut is in the
// transaction's `ReplacementMap`: `WireRepairSeamTests.repairIsRecorded` already proves that
// much. Nothing consumed it, so a *selected* wire that got split stayed in the selection as a
// dead object: not in the circuit, drawn nowhere, and still draggable.
//
// The fix is not another scoped install. Upstream has a listener LIST, `Selection(Project,
// Canvas)` registers `myListener` with `Project.addCircuitListener` (4.1.0 bytecode offset 48)
// and every `TRANSACTION_DONE` walks it, so the port grows one too:
// `CircuitTransactionObservers`, fed by a single permanent closure in
// `LogisimFileProjectHostFactory.installProcessSeams()`.
//
// Every assertion below is written against the CIRCUIT and against object *identity*, never
// against the selection's internal counts alone: the selection is the bookkeeping that was
// wrong, and a test satisfied by tidier bookkeeping would not have caught either regression.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import AppKit
import CoreGraphics
import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimRenderBackend
import LogisimStd
import Testing

@testable import LogisimUI

// MARK: - Harness

/// The same shape as `DragDuplicationTests.DragRig`, and deliberately a second copy rather than a
/// shared one: that rig is `private` to its file, and this suite must keep compiling if that one
/// is rewritten. The question both ask is whether the *application's* canvas drives the tool, so
/// the project comes from `LogisimFileProjectHostFactory` rather than from hand-assembled parts.
@MainActor
private struct DeliveryRig {
  let host: LogisimFileProjectHost
  let project: Project
  let circuit: Circuit
  let surface: CircuitCanvasSurface
  let canvas: CircuitEditorCanvas
  let tool: SelectTool

  init() throws {
    let made = try LogisimFileProjectHostFactory().makeEmptyProject()
    host = try #require(made as? LogisimFileProjectHost)
    project = host.project
    circuit = try #require(host.currentCircuitObject)
    surface = try #require(host.makeRenderSurface() as? CircuitCanvasSurface)
    tool = SelectTool()
    canvas = CircuitEditorCanvas(
      project: project, surface: surface, circuit: circuit, initialTool: tool)
  }

  @discardableResult
  func add(_ factory: any ComponentFactory, at point: (Int, Int)) throws -> any Component {
    let component = try factory.createComponent(
      location: Location.create(point.0, point.1, hasToSnap: false),
      attributes: factory.createAttributeSet())
    try circuit.mutatorAdd(component)
    return component
  }

  /// Send a gesture the way `CanvasHostNSView` does.
  func pointer(_ phase: CanvasPointerEvent.Phase, _ x: Int, _ y: Int) {
    canvas.controller.canvasHandlePointer(
      CanvasPointerEvent(
        phase: phase,
        world: CGPoint(x: CGFloat(x), y: CGFloat(y)),
        modifiers: [],
        clickCount: 1,
        buttonNumber: 1,
        dragOriginWorld: nil))
  }

  /// A press and release with no movement, which is how the select tool is told "select this".
  func click(_ point: Location) {
    pointer(.down, point.x, point.y)
    pointer(.up, point.x, point.y)
  }

  /// One complete press-drag-release starting at `point`.
  ///
  /// Takes a raw point rather than a component on purpose: the whole question in this suite is
  /// what happens when the user presses somewhere the circuit has *nothing*, so the gesture must
  /// be expressible without naming a component.
  func dragFrom(_ point: Location, by delta: (Int, Int)) {
    pointer(.down, point.x, point.y)
    pointer(.dragged, point.x + delta.0, point.y + delta.1)
    pointer(.up, point.x + delta.0, point.y + delta.1)
  }

  func drag(_ component: any Component, by delta: (Int, Int)) throws {
    dragFrom(try #require(pointInside(component)), by: delta)
  }
}

/// A point the component actually reports as inside it.
///
/// Computed rather than assumed for the reason `DragDuplicationTests` records: a point the
/// component rejects takes `mousePressed`'s *background* arm and starts a marquee, which would
/// leave the circuit unchanged and make this suite pass for the wrong reason.
@MainActor
private func pointInside(_ component: any Component) -> Location? {
  let box = component.bounds
  guard box.width > 0, box.height > 0 else { return nil }
  for y in stride(from: box.y, through: box.y + box.height, by: 1) {
    for x in stride(from: box.x, through: box.x + box.width, by: 1) {
      let point = Location.create(x, y, hasToSnap: false)
      if component.contains(point) { return point }
    }
  }
  return nil
}

@MainActor
private func solePin(in circuit: Circuit) throws -> any Component {
  let matches = circuit.nonWires.filter { $0.factory === Pin.factory }
  #expect(matches.count == 1)
  return try #require(matches.first)
}

// MARK: - The gate

@Suite("Transaction result delivery", .serialized)
struct TransactionDeliveryTests {

  // ── 1. Redo, the path the scoped install could not reach ───────────────────────────────────

  /// The refutation of the first fix, as a test.
  ///
  /// `Project.redoAction` calls `action.doIt` again, and `SelectedComponentsAction.doIt` routes a
  /// second call into `redo`, which is a bare `xnForward?.execute()`. That is a full transaction
  /// with a full replacement map and it happens with no `SelectTool` on the stack at all.
  @Test("place → drag → undo → redo → press the vacated spot → drag leaves ONE component")
  @MainActor
  func redoThenDragOnTheVacatedSpotLeavesOne() throws {
    let rig = try DeliveryRig()
    let pin = try rig.add(Pin.factory, at: (100, 100))
    let originalSpot = try #require(pointInside(pin))

    try rig.drag(pin, by: (60, 0))
    #expect(try solePin(in: rig.circuit).location == Location.create(160, 100, hasToSnap: false))

    try rig.project.undoAction()
    #expect(try solePin(in: rig.circuit).location == Location.create(100, 100, hasToSnap: false))

    #expect(rig.project.canRedo)
    try rig.project.redoAction()
    #expect(rig.circuit.nonWires.count == 1)
    #expect(try solePin(in: rig.circuit).location == Location.create(160, 100, hasToSnap: false))

    // The redo VACATED (100,100). Nothing is drawn there any more…
    #expect(rig.circuit.allContaining(originalSpot).isEmpty)
    // …so the selection must hold nothing there either, or the next press drags a phantom.
    #expect(rig.canvas.selection.componentsContaining(originalSpot).isEmpty)

    rig.dragFrom(originalSpot, by: (40, 40))

    // Broken: 2; the phantom was committed as an add.
    #expect(rig.circuit.nonWires.count == 1)
    #expect(try solePin(in: rig.circuit).location == Location.create(160, 100, hasToSnap: false))
  }

  /// The same hole with a *removal* instead of a replacement, which is the worse face of it: the
  /// component comes back from the dead into a circuit that has nothing in it.
  ///
  /// `SelectionActions.Delete.doItFirstTime` empties the selection through `deleteAllHelper`, so
  /// the state after the redo is "circuit empty, selection holding one" only because the undo put
  /// the component back in the selection (`Selection.projectChanged`'s `UNDO_COMPLETE` arm) and
  /// the redo told the selection nothing.
  @Test("delete → undo → redo → press the empty spot → drag leaves the circuit EMPTY")
  @MainActor
  func redoOfADeleteDoesNotResurrectTheComponent() throws {
    let rig = try DeliveryRig()
    let pin = try rig.add(Pin.factory, at: (100, 100))
    let spot = try #require(pointInside(pin))

    rig.click(spot)
    #expect(rig.canvas.selection.components.count == 1)

    _ = rig.project.perform { SelectionActions.clear(rig.canvas.selection) }
    #expect(rig.circuit.nonWires.isEmpty)

    try rig.project.undoAction()
    #expect(rig.circuit.nonWires.count == 1)

    try rig.project.redoAction()
    #expect(rig.circuit.nonWires.isEmpty)

    // The circuit is empty, so the selection must be too; a selection holding a component no
    // circuit holds is exactly the phantom this whole change is about.
    #expect(rig.canvas.selection.componentsContaining(spot).isEmpty)

    rig.dragFrom(spot, by: (40, 40))

    // Broken: 1: a component deleted twice, undone once, dragged back into existence.
    #expect(rig.circuit.nonWires.isEmpty)
  }

  /// The bookkeeping stated directly, because the two tests above could in principle be satisfied
  /// by a fix that merely *emptied* the selection after a redo.
  ///
  /// Identity, not position: the redo re-executes the forward transaction, which replaces the
  /// original object with the copy `doItFirstTime` built. The selection must end up holding that
  /// copy, the same object the circuit holds, or the highlight is drawn from one set of
  /// coordinates and the schematic from another.
  @Test("after a redo the selection holds the very object the circuit holds")
  @MainActor
  func redoLeavesTheSelectionPointingAtTheCircuitsObject() throws {
    let rig = try DeliveryRig()
    let pin = try rig.add(Pin.factory, at: (100, 100))

    try rig.drag(pin, by: (60, 0))
    try rig.project.undoAction()
    try rig.project.redoAction()

    let inCircuit = try solePin(in: rig.circuit)
    #expect(rig.canvas.selection.components.count == 1)
    let selected = try #require(rig.canvas.selection.components.first)
    #expect(selected === inCircuit)
    // Anchored, not floating: it is in the circuit, so `transactionDone` must have put it in
    // `selected`. Getting that branch wrong leaves a component the next `clear` tries to re-add.
    #expect(rig.canvas.selection.anchoredComponents.count == 1)
    #expect(rig.canvas.selection.floatingComponents.isEmpty)
    // And the object the undo/redo cycle discarded is not still sitting beside it.
    #expect(!rig.canvas.selection.components.contains { $0 === pin })
  }

  /// Undo has the same shape as redo and is already delivered by the `UNDO_COMPLETE` snapshot
  /// (commit `2d87ac427`). Kept here so a future change that moves the delivery cannot silently
  /// trade one direction for the other.
  @Test("a full undo/redo/undo cycle never leaves the selection out of step")
  @MainActor
  func repeatedUndoRedoKeepsTheSelectionInStep() throws {
    let rig = try DeliveryRig()
    let pin = try rig.add(Pin.factory, at: (100, 100))
    try rig.drag(pin, by: (60, 0))

    for _ in 0..<3 {
      try rig.project.undoAction()
      #expect(rig.circuit.nonWires.count == 1)
      #expect(rig.canvas.selection.components.first === (try solePin(in: rig.circuit)))

      try rig.project.redoAction()
      #expect(rig.circuit.nonWires.count == 1)
      #expect(rig.canvas.selection.components.first === (try solePin(in: rig.circuit)))
    }
  }

  // ── 2. Wire repair, a second live instance of the same cause ───────────────────────────────

  /// A selected wire that the repair pass splits must not stay in the selection.
  ///
  /// The split goes through the mutator, `WireRepairSeamTests.repairIsRecorded` measures that
  /// the cut wire is in the transaction's `removals`, so the information needed to fix the
  /// selection was already being produced and thrown away. The transaction here is an ordinary
  /// component drop, made through `Project.doAction`; no `SelectTool` is involved, which is
  /// exactly why the scoped install could not reach it.
  @Test("a selected wire that wire repair splits leaves no dead object in the selection")
  @MainActor
  func wireRepairRemovesTheSplitWireFromTheSelection() throws {
    let rig = try DeliveryRig()

    let wire = Wire.create(
      Location.create(100, 200, hasToSnap: false),
      Location.create(180, 200, hasToSnap: false))
    try rig.circuit.mutatorAdd(wire)
    rig.canvas.selection.add(wire)
    #expect(rig.canvas.selection.components.count == 1)

    // Drop a pin in the middle of the wire. `CircuitTransaction.execute`'s repair pass cuts the
    // wire at the pin's end, through the mutator, so the cut is in the replacement map.
    let pin = try Pin.factory.createComponent(
      location: Location.create(140, 200, hasToSnap: false),
      attributes: Pin.factory.createAttributeSet())
    let mutation = rig.project.beginMutation(on: rig.circuit)
    mutation.add(pin)
    try rig.project.doAction(mutation.toAction("drop a pin on a wire"))

    // The premise: the repair really did happen and the original wire is gone from the circuit.
    #expect(!rig.circuit.wires.contains { $0 === wire })

    // The gate. Broken: the selection still holds `wire`, an object in no circuit, so it draws
    // handles over nothing, `bounds` reports a region that is not there, and a press inside it
    // starts a move of a component that does not exist.
    #expect(!rig.canvas.selection.components.contains { $0 === wire })
    for component in rig.canvas.selection.components {
      #expect(
        rig.circuit.contains(component),
        "the selection holds a component the circuit does not: \(type(of: component))")
    }
  }

  // ── 3. What a global broadcast must NOT do ────────────────────────────────────────────────
  //
  // Upstream never has this problem: `Project.addCircuitListener` registers the selection on the
  // *current circuit*, so an event for another circuit never reaches it. The port broadcasts one
  // result to every observer instead and the filter moves into the observer, so these two pin
  // the behaviour that replaces the registration.
  //
  // ── HONEST ABOUT WHAT THESE TWO DO AND DO NOT DISCRIMINATE ─────────────────────────────────
  //
  // **Both were red-probed by deleting the per-circuit filter**, replacing
  // `guard let circuit = project?.currentCircuit` with a loop over `result.modifiedCircuits`,
  // **and the probe reddened nothing.** That is a finding, not an omission, and the reason is
  // worth stating because it says how much the filter is actually load-bearing:
  //
  //   a `ReplacementMap` is keyed by component *identity*, and a component belongs to exactly
  //   one circuit, so a map built for circuit B can never name a component held by a selection
  //   of circuit A. The swap half of `Selection.transactionDone` is therefore self-filtering.
  //
  // What the circuit argument still decides is the *other* half: `circuit.contains(add)`, the
  // anchored-versus-floating branch. Discriminating that needs a single transaction that
  // modifies TWO circuits and replaces a component this selection holds: the subcircuit shape,
  // where changing B's pins rewrites A's port list and A's wires are repaired in the same
  // transaction. That test is not written; the gap is recorded rather than papered over.
  //
  // These two stay as characterisation: they hold the no-op and the cross-document independence
  // steady, and cross-document independence is a hazard the global registry *introduces* that
  // upstream's per-circuit listener list does not have.

  /// A transaction on ANOTHER circuit of the same file must leave this selection alone.
  @Test("a result for a different circuit does not disturb the selection")
  @MainActor
  func aResultForAnotherCircuitIsANoOp() throws {
    let rig = try DeliveryRig()
    let pin = try rig.add(Pin.factory, at: (100, 100))
    rig.click(try #require(pointInside(pin)))
    #expect(rig.canvas.selection.components.count == 1)

    // A second circuit in the same file, edited through the same project and the same undo stack.
    let other = try Circuit(name: "elsewhere", file: rig.host.file)
    rig.host.file.addCircuit(other)
    let strayPin = try Pin.factory.createComponent(
      location: Location.create(400, 400, hasToSnap: false),
      attributes: Pin.factory.createAttributeSet())
    let mutation = rig.project.beginMutation(on: other)
    mutation.add(strayPin)
    try rig.project.doAction(mutation.toAction("add a pin to the other circuit"))

    // Unchanged, by identity: the selection still holds the component it held, and nothing has
    // been lifted, dropped or swapped by a result that was never about it.
    #expect(rig.canvas.selection.components.count == 1)
    #expect(rig.canvas.selection.components.first === pin)
    #expect(rig.canvas.selection.floatingComponents.isEmpty)
    #expect(rig.circuit.nonWires.count == 1)
  }

  /// Two open documents share the one registry. An edit in the first must not touch the second.
  ///
  /// This is the risk a global broadcast *introduces* and per-circuit listener lists do not, so
  /// it is pinned even though upstream has no equivalent failure to port. It also states, as an
  /// assertion, that the first document's own selection still followed its move while the second
  /// was registered alongside it; i.e. that broadcasting to several observers does not make the
  /// delivery order or the observer count matter.
  @Test("an edit in one document does not disturb another document's selection")
  @MainActor
  func documentsDoNotDisturbEachOther() throws {
    let first = try DeliveryRig()
    let second = try DeliveryRig()

    let firstPin = try first.add(Pin.factory, at: (100, 100))
    let secondPin = try second.add(Pin.factory, at: (100, 100))
    second.click(try #require(pointInside(secondPin)))
    #expect(second.canvas.selection.components.first === secondPin)

    try first.drag(firstPin, by: (60, 0))

    // The first document's selection followed its own move…
    #expect(first.canvas.selection.components.first === (try solePin(in: first.circuit)))
    // …and the second document is exactly as it was.
    #expect(second.canvas.selection.components.count == 1)
    #expect(second.canvas.selection.components.first === secondPin)
    #expect(second.circuit.nonWires.count == 1)
    #expect(try solePin(in: second.circuit).location == Location.create(100, 100, hasToSnap: false))
  }

  // ── 4. The original defect, kept honest ───────────────────────────────────────────────────

  /// `DragDuplicationTests` owns this case; it is repeated once here so that a change to the
  /// delivery mechanism cannot regress the reported bug while this file's own gates stay green.
  @Test("four drags of one Pin still leave exactly one Pin")
  @MainActor
  func fourDragsStillLeaveOne() throws {
    let rig = try DeliveryRig()
    var current: any Component = try rig.add(Pin.factory, at: (200, 200))
    for _ in 0..<4 {
      try rig.drag(current, by: (20, 20))
      current = try solePin(in: rig.circuit)
    }
    #expect(rig.circuit.nonWires.count == 1)
    #expect(current.location == Location.create(280, 280, hasToSnap: false))
  }
}
