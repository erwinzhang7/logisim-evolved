// AppearanceTranslateAction.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.draw.actions.ModelTranslateAction and
// com.cburch.logisim.gui.appear.CanvasActionAdapter),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE ONE WRITER
//
// Nothing else in `Appearance/` mutates a shape. That is the whole point:
//
//   * `Project.doAction` puts the edit on the undo stack, so Cmd-Z works and the file is marked
//     dirty by the same mechanism every other edit uses.
//   * `Project.modelGuard` takes `SimulationEngine.modelLock` around it. `ProjectModelGuardTests`
//     exists because the tool path once did **not** take that lock, and an appearance edit is a
//     strictly worse offender than a schematic one: `CircuitAppearance.portOffsets` is read by
//     `SubcircuitFactory.computePorts`, which runs on the propagation thread. Mutating a shape
//     list outside `doAction` is a data race with no oracle.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// UPSTREAM'S TWO LAYERS, AND WHY THEY COLLAPSE INTO ONE HERE
//
// Upstream stacks a `com.cburch.draw.undo.UndoAction` (`ModelTranslateAction`) inside a
// `com.cburch.logisim.proj.Action` (`CanvasActionAdapter`), because the draw package is a
// standalone widget with its own undo stack and logisim wraps it. `AppearanceCanvas.doAction`
// does the wrapping and `CanvasActionAdapter.doIt` chooses between calling the inner action
// directly and running it inside a `CircuitTransaction`:
//
// ```java
// public void doIt(Project proj) {
//   if (affectsPorts()) { new ActionTransaction(true).execute(); }
//   else                { canvasAction.doIt(); }
// }
// ```
//
// The port has one undo stack, not two, `LogisimDraw/Undo/UndoAction.swift` is the protocol and
// nothing implements it, so the two layers are one class here. **The `affectsPorts` branch is
// kept verbatim**, because it is not a refactor detail: moving a `circ-port` changes the ends of
// every placement of this circuit in every parent, and doing that outside a transaction edits
// circuits whose locks were never taken.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// COALESCING
//
// `shouldAppendTo` is why `Action` is a class (see `Action.swift`'s header). A drag emits one
// translate per mouse-moved sample; without coalescing, Cmd-Z rewinds one mouse sample. The
// override compares the **shape set by identity**, D4's rule applied to the draw model, and
// unwraps `JoinedAction` first, which is the trap `Action.swift` spells out: by the third sample
// the action on top of the log is already a `JoinedAction`, so a naive cast returns nil and
// coalescing stops after exactly one merge.

import Foundation
import LogisimDraw
import LogisimFile
import LogisimKernel

/// `ModelTranslateAction` + `CanvasActionAdapter`, as one `Project` action.
@MainActor
final class AppearanceTranslateAction: Action {

  private let model: AppearanceEditorModel
  /// D4: identity, and strong; the shapes must outlive an undo that is still on the stack.
  private let shapes: [CanvasObject]
  private var dx: Int
  private var dy: Int

  init(model: AppearanceEditorModel, shapes: [CanvasObject], dx: Int, dy: Int) {
    self.model = model
    self.shapes = shapes
    self.dx = dx
    self.dy = dy
  }

  /// `ModelTranslateAction.getName()`, "Move Selection" / "Move <shape>".
  override var name: String {
    shapes.count == 1 ? "Move \(shapes[0].displayName)" : "Move Selection"
  }

  override func doIt(_ project: Project) throws {
    try apply(dx: dx, dy: dy)
  }

  override func undo(_ project: Project) throws {
    try apply(dx: -dx, dy: -dy)
  }

  /// `CanvasActionAdapter.affectsPorts()`:
  ///
  /// ```java
  /// for (final var obj : action.getObjects())
  ///   if (obj instanceof AppearanceElement) return true;
  /// ```
  private var affectsPorts: Bool {
    shapes.contains { $0 is AppearanceElement }
  }

  private func apply(dx: Int, dy: Int) throws {
    guard dx != 0 || dy != 0 else { return }
    if affectsPorts, let circuit = model.circuit, !circuit.circuitsUsingThisCircuit.isEmpty {
      try PortMoveTransaction(circuit: circuit) { [self] in
        model.drawing.translateObjects(shapes, dx: dx, dy: dy)
      }.execute()
    } else {
      model.drawing.translateObjects(shapes, dx: dx, dy: dy)
    }
    model.commit()
  }

  /// `ModelTranslateAction`'s coalescing, via `Action.shouldAppendTo`.
  ///
  /// Same model, same shape set by identity. Two separate drags of the same shape *do* merge,
  /// which is upstream's behaviour too, since `SelectionActions.Move` compares only the
  /// selection, and the undo entry is then the net displacement, which is what a user reading
  /// "Undo Move Selection" expects.
  override func shouldAppendTo(_ other: Action) -> Bool {
    let previous = (other as? JoinedAction)?.lastAction ?? other
    guard let translate = previous as? AppearanceTranslateAction,
      translate.model === model,
      translate.shapes.count == shapes.count
    else { return false }
    for (a, b) in zip(translate.shapes, shapes) where a !== b { return false }
    return true
  }

  /// Merging in place rather than through `JoinedAction`: two translates of the same shapes are
  /// one translate by the sum, so the undo log holds one entry per gesture rather than one
  /// wrapper per sample.
  ///
  /// Returns `nil` when the pair annihilates, a drag out and back to the start, which
  /// `Project.doAction` treats as "drop the entry entirely". `Action.append`'s doc comment names
  /// exactly this case; this is the first implementation to produce it.
  override func append(_ other: Action) -> Action? {
    guard let translate = other as? AppearanceTranslateAction, translate.model === model else {
      return JoinedAction(self, other)
    }
    dx += translate.dx
    dy += translate.dy
    return (dx == 0 && dy == 0) ? nil : self
  }
}

// MARK: - The transaction

/// `CanvasActionAdapter.ActionTransaction`.
///
/// ```java
/// protected Map<Circuit, Integer> getAccessedCircuits() {
///   final var accessMap = new HashMap<Circuit, Integer>();
///   for (final var supercirc : circuit.getCircuitsUsingThis())
///     accessMap.put(supercirc, READ_WRITE);
///   return accessMap;
/// }
/// ```
///
/// Note which circuits are listed: the **parents**, not the circuit being edited. Moving a port
/// does not change this circuit's components at all; it changes the ends of every placement of
/// it, which live in the parents, and those are the wires that may need repairing.
/// **Not `@MainActor`**, and that is `CircuitTransaction`'s design rather than an oversight: its
/// header says the transaction substrate is deliberately non-isolated "because upstream takes real
/// per-circuit locks there precisely so a transaction can run off the EDT". A `@MainActor`
/// subclass cannot override its `nonisolated` members.
///
/// D1's corollary governs the `assumeIsolated` below. The rule there is *assert only where the
/// call site can be shown to originate on the main actor and nothing in the kernel can reach it*,
/// and to say which. Here: `execute()` is called from `AppearanceTranslateAction.apply`, which is
/// `@MainActor`; `execute()` calls `run` **synchronously**, on the calling thread, with no queue
/// hop and no kernel involvement (`CircuitLocker.acquireLocks` → `run` → `releaseLocks`, all in
/// one stack frame). There is no path by which propagation reaches this type: it is constructed,
/// executed and released inside one main-actor call, and nothing retains it.
private final class PortMoveTransaction: CircuitTransaction {
  private let circuit: Circuit
  private let body: @MainActor () -> Void

  init(circuit: Circuit, body: @escaping @MainActor () -> Void) {
    self.circuit = circuit
    self.body = body
    super.init()
  }

  override var accessedCircuits: [ObjectIdentifier: (circuit: Circuit, access: Access)] {
    var map: [ObjectIdentifier: (circuit: Circuit, access: Access)] = [:]
    for parent in circuit.circuitsUsingThisCircuit {
      map[ObjectIdentifier(parent)] = (parent, .readWrite)
    }
    return map
  }

  override func run(_ mutator: any CircuitMutator) throws {
    // The local binding is load-bearing, not style: closing over `self` would send a
    // non-`Sendable` class across the isolation boundary, which Swift 6 rejects. The closure is
    // `@MainActor` already, so only it crosses.
    let body = self.body
    MainActor.assumeIsolated { body() }
  }
}
