// Selection.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.gui.main.Selection),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// `SelectionBase` holds the two sets and the operations on them. This subclass is the part that
// listens: it keeps the selection consistent when the circuit changes underneath it, and it
// restores the selection on undo.
//
// ── The two listener jobs, and why they are not the same job ────────────────────────────────
//
// **Transaction done.** A `CircuitMutation` can *replace* components; a move replaces every
// moved component with a new object at the new coordinates, and wire splitting replaces one wire
// with several. The selection is holding the old objects. `MyListener.circuitChanged` reads the
// transaction's replacement map and swaps them, re-deciding anchored-versus-floating by asking
// the circuit whether it contains each replacement. That last part is what makes
// `translateHelper`'s deliberately-messy hand-off work (see its comment).
//
// **Undo.** The selection is not part of the circuit, so undoing a circuit mutation does not
// restore it. Upstream snapshots the selection when each action *starts* and replays it on
// `UNDO_COMPLETE`. Again the anchored/floating split is re-derived from the circuit rather than
// trusted, because the undo may have put a formerly-floating component back into the circuit.
//
// ── Two seams this file cannot close on its own ─────────────────────────────────────────────
//
//   * **The transaction result is not on `CircuitEvent`.** Upstream's
//     `CircuitEvent.getResult().getReplacementMap(circuit)` is how the listener gets the swap
//     list, but the port's `CircuitEventData` has no case carrying a transaction result; the
//     transaction machinery is M3/Project work, and `CircuitEvent` lives one module down in
//     `LogisimFile`, which must not gain an edge to `LogisimUI` to carry it.
//
//     **CLOSED, and this used to say the delivery was "a direct call the mutation plumbing must
//     make".** It was, once, at exactly one call site (`SelectTool.commitMove`), which is how
//     redo, wire repair, paste and delete ended up with no delivery at all. It now arrives the
//     way upstream's does, from a listener list walked after every transaction:
//     `CircuitTransactionObservers`, which this class registers with in its own constructor and
//     which one permanent closure in `installProcessSeams()` feeds. The plain `CircuitListener`
//     conformance below stays empty and still documents the payload gap.
//   * **`SelectionAttributes`.** `Selection.getAttributeSet()` returns a live `SelectionAttributes`
//     ; the union attribute set the attribute table edits. That is a separate 351-line port and
//     is not in this slice; the slot is injectable so the clipboard's "which set was being
//     viewed" bookkeeping works the moment it lands.

import Foundation
import LogisimFile
import LogisimKernel

// `SelectionProjectEvent` used to sit here: a four-case enum modelling only the `ProjectEvent`
// constants `Selection.MyListener` reacts to, written while the Project/undo slice's real event
// type did not exist yet. It is gone; `ProjectEvent` is the Java type
// (`com.cburch.logisim.proj.ProjectEvent`) and `Selection` now conforms to `ProjectListener`
// directly, switching on the four actions exactly as upstream's listener does.
//
// The one thing that enum bought and this does not is exhaustiveness: it could not be handed an
// action `Selection` does not handle. The `default: break` arm below is where that goes, and it
// is upstream's shape; `MyListener.projectChanged` is a switch over 13 constants that names 4.

/// A ghost to draw: a component, and where it should appear.
///
/// `Selection.draw` and `drawGhostsShifted` are AWT (D6/D9, M6). What is *not* presentation is
/// which components are ghosted and at which coordinates: `drawGhostsShifted` snaps the drag
/// delta before applying it, and getting that wrong makes a drag preview disagree with where the
/// components actually land. That arithmetic stays here; the renderer consumes the result.
public struct GhostPlacement {
  public let component: any Component
  public let x: Int
  public let y: Int
}

/// `com.cburch.logisim.gui.main.Selection`.
@MainActor
public final class Selection: SelectionBase {

  /// `attrs`: upstream's `SelectionAttributes(canvas, this)`.
  ///
  /// Injectable rather than constructed here; see the file header. The clipboard uses it only to
  /// record which attribute set the attribute table was showing when the copy was taken.
  public var attributeSet: (any AttributeSet)?

  /// `MyListener.savedSelections`: a `WeakHashMap<Action, SelectionSave>`.
  ///
  /// D3 warns specifically against translating a Java weak map mechanically, because ARC pins
  /// the keys through the very cycles the weak map exists to escape. The eviction owner here is
  /// explicit and is upstream's own logic: an entry is dropped on `ACTION_COMPLETE` when the
  /// action left the selection untouched, moved on `ACTION_MERGE`, and every access purges
  /// entries whose action has been released by the undo stack.
  private var savedSelections = WeakActionKeyedSelectionSaves()

  public override init(project: Project? = nil) {
    super.init(project: project)
    // `Selection(Project, Canvas)` ends in `proj.addProjectListener(myListener)` +
    // `proj.addCircuitListener(myListener)` (4.1.0 bytecode offsets 40 and 48). This is the
    // second of those two. The first is still made by `CircuitEditorCanvas`, because the port's
    // `Selection` is handed an *optional* project and the canvas is the thing that always has
    // one; see the note there.
    //
    // Registered in the constructor, as upstream does, rather than by the canvas: a `Selection`
    // built by any other route, a test, a second view, then gets the same delivery, which is
    // the property that made the previous, per-call-site fix leak paths (redo, wire repair).
    CircuitTransactionObservers.register(self)
  }

  /// `EventSourceWeakSupport` drops a collected listener on its own; ARC has no such moment, so
  /// this is it.
  ///
  /// **Red-probed, and it reddens nothing; recorded rather than hidden.** Deleting this body
  /// leaves all 23 tests of `CircuitTransactionObserverTests`, `TransactionDeliveryTests`,
  /// `DragDuplicationTests` and `WireRepairSeamTests` green, because the registry's entries are
  /// weak *and* every traversal purges the dead ones, so the lazy path already delivers every
  /// property those tests measure. What this buys is promptness: without it a `Box` for a closed
  /// document survives until the next `register`/`broadcast`/`registeredCount`, and a registry
  /// whose only eviction is lazy is one measurement away from looking like a leak.
  ///
  /// It is not needed for identity safety either, which was the other candidate justification: an
  /// `ObjectIdentifier` can be reused by a later allocation, but `register` purges before its
  /// duplicate check, so the dead entry is gone before the new object's identity is compared.
  deinit {
    // The dying object must not escape `deinit`, and its own weak references already read `nil`
    // here, so the registry is keyed on the identity captured at registration.
    CircuitTransactionObservers.deregister(ObjectIdentifier(self))
  }

  // MARK: - Drawing decisions (the non-AWT half of draw / drawGhostsShifted)

  /// The ghosts `draw(ComponentDrawContext, Set<Component>)` paints: the **floating** components,
  /// at their own locations, minus anything the caller says is hidden.
  ///
  /// Only floating components are ghosted. An anchored component is drawn by the circuit itself
  /// and gets handles instead.
  public func ghostPlacements(hiding hidden: ComponentSet = ComponentSet()) -> [GhostPlacement] {
    lifted.components.compactMap { comp in
      guard !hidden.contains(comp) else { return nil }
      let loc = comp.location
      return GhostPlacement(component: comp, x: loc.x, y: loc.y)
    }
  }

  /// The components `draw` puts selection handles on: everything selected, minus the suppressed
  /// set and minus the hidden set.
  ///
  /// Whether a given component draws its own handles (`CustomHandles`) is the renderer's
  /// question, not this one.
  public func handleTargets(hiding hidden: ComponentSet = ComponentSet()) -> [any Component] {
    unionSet.components.filter { !suppressHandles.contains($0) && !hidden.contains($0) }
  }

  /// `drawGhostsShifted(ComponentDrawContext, int, int)`; the drag preview.
  ///
  /// The snap is applied to the **delta**, not to the resulting positions, and only when the
  /// selection snaps at all. That is upstream's order and it is not equivalent to snapping the
  /// destination: snapping the delta preserves each component's offset from the others, so a
  /// group keeps its shape while dragging.
  public func ghostPlacementsShifted(dx: Int, dy: Int) -> [GhostPlacement] {
    var dx = dx
    var dy = dy
    if shouldSnap {
      dx = SelectionBase.snapXToGrid(dx)
      dy = SelectionBase.snapYToGrid(dy)
    }
    return unionSet.components.map { comp in
      let loc = comp.location
      return GhostPlacement(component: comp, x: wrap32(loc.x &+ dx), y: wrap32(loc.y &+ dy))
    }
  }

  // MARK: - Equality

  /// `equals(Object)`; same anchored set and same floating set.
  ///
  /// Not an `Equatable` conformance: this is a *content* comparison on a reference type whose
  /// identity matters elsewhere, and D4's rule against silently value-comparing model objects
  /// applies to the thing holding them too. Callers say what they mean.
  public func hasSameContents(as other: Selection) -> Bool {
    selected.isSameSet(as: other.selected) && lifted.isSameSet(as: other.lifted)
  }

  // MARK: - MyListener: transactions

  /// `MyListener.circuitChanged(CircuitEvent)` for `TRANSACTION_DONE`.
  ///
  /// Called directly by the mutation plumbing rather than reached through `CircuitEvent`, because
  /// the port's event payload carries no transaction result; see the file header.
  ///
  /// Note what is re-derived and what is not: the replacement list comes from the transaction,
  /// but which half of the selection each replacement lands in is decided by asking the circuit.
  /// A replacement the circuit contains is anchored; one it does not is floating. Trusting the
  /// old component's half instead would anchor components that are not in the circuit, and the
  /// next `clear` would then fail to put them back.
  public func transactionDone(
    circuit: Circuit, result: CircuitTransactionResult
  ) {
    let replacements = result.replacementMap(for: circuit)
    var change = false

    // Snapshot first: the loop mutates both sets.
    let oldAnchored = unionSet.components
    for comp in oldAnchored {
      guard let replacedBy = replacements.replacements(for: comp) else { continue }
      change = true
      selected.remove(comp)
      lifted.remove(comp)
      for add in replacedBy {
        if circuit.contains(add) {
          selected.add(add)
        } else {
          lifted.add(add)
        }
      }
    }

    if change { fireSelectionChanged() }
  }

  // MARK: - MyListener: project events

  /// `MyListener.projectChanged(ProjectEvent)`.
  public func projectChanged(_ event: ProjectEvent) {
    switch (event.action, event.oldData, event.data) {
    case (.actionStart, _, .action(let action)):
      savedSelections.put(SelectionSave.create(self), for: action)

    case (.actionComplete, _, .action(let action)):
      // Forget the snapshot only when the action left the selection exactly as it found it;
      // there is then nothing for a later undo to restore. Note upstream removes on *same*, and
      // keeps on *different*, which reads backwards until you see that the kept snapshot is the
      // pre-action state an undo needs.
      if let save = savedSelections.get(for: action), save.isSame(as: self) {
        savedSelections.remove(for: action)
      }

    case (.actionMerge, .action(let old), .action(let merged)):
      // The coalesced action inherits the snapshot of the one it absorbed, so an undo of the
      // merged action restores the selection from before the *first* of them. Upstream stores
      // whatever `get(old)` returned, including null.
      //
      // `Action.append` can annihilate a pair and return nil, in which case `data` is `.none` and
      // there is no merged action to carry the snapshot to; the entry left the undo log, so the
      // snapshot has nothing to restore and is correctly dropped by the purge in `get`.
      savedSelections.put(savedSelections.get(for: old), for: merged)

    case (.undoComplete, _, .action(let action)):
      guard let save = savedSelections.get(for: action) else { return }
      let circuit = project?.currentCircuit

      lifted.removeAll()
      selected.removeAll()
      // Upstream's `for (i = 0; i < 2; i++)`: floating first, then anchored. The order is
      // observable: with the insertion-ordered sets this port uses, it fixes the resulting
      // iteration order.
      for components in [save.floatingComponents, save.anchoredComponents] {
        for comp in components {
          if circuit?.contains(comp) == true {
            selected.add(comp)
          } else {
            lifted.add(comp)
          }
        }
      }
      fireSelectionChanged()

    default:
      // Upstream's `MyListener.projectChanged` is a switch over 13 constants that names 4. This
      // is the other 9, plus the shapes where the payload is not an action, which cannot happen
      // for these four actions, since `Project.doAction`/`undoAction` always fire them with one.
      break
    }
  }
}

// MARK: - CircuitListener

/// `Selection.MyListener`'s `ProjectListener` half.
///
/// Java keeps this as an inner class rather than putting it on `Selection` itself. The conformance
/// is on `Selection` here because there is nothing else in it; the inner class exists in Java only
/// so one object can implement three unrelated listener interfaces, and Swift does not need the
/// indirection for that.
extension Selection: ProjectListener {}

// MARK: - CircuitTransactionObserver

/// The half of `Selection.MyListener`'s `CircuitListener` job that `CircuitEvent` cannot carry.
///
/// Upstream is registered on the **current circuit only** (`Project.addCircuitListener` adds the
/// listener to `getCurrentCircuit()`, and `setCurrentCircuit` moves it), so `event.getCircuit()`
/// is always the circuit this selection is a selection of. The registry broadcasts results for
/// every circuit instead, so the filter is here: the selection asks for the replacement map of
/// *its own* circuit, and a transaction that did not touch it yields an empty map and a no-op.
extension Selection: CircuitTransactionObserver {
  public func transactionDone(result: CircuitTransactionResult) {
    // `project` is weak (D3). A selection whose project has gone has nothing to swap against.
    // `currentCircuit` rather than a stored circuit for the same reason upstream re-registers on
    // `setCurrentCircuit`: the selection follows the project's current circuit, and
    // `SelectionActions.Translate.doItFirstTime` builds its mutation against exactly this value.
    guard let circuit = project?.currentCircuit else { return }
    transactionDone(circuit: circuit, result: result)
  }
}

extension Selection: CircuitListener {
  /// The port's `CircuitEvent` carries no transaction result, so the one action this listener
  /// cares about cannot be served from the event alone. Conformance is declared so the selection
  /// can be registered where upstream registers it, and `transactionDone(circuit:result:)` is the
  /// entry point that does the work.
  ///
  /// `nonisolated` because `CircuitListener` is declared in `LogisimFile`, which compiles in
  /// Swift 5 language mode (D1) and therefore has no isolation of its own; a main-actor method
  /// cannot satisfy it. That is sound precisely because the body does nothing; the moment it
  /// does, it must hop to the main actor first, and the compiler will say so.
  nonisolated public func circuitChanged(_ event: CircuitEvent) {
    // Deliberately empty. See `transactionDone(circuit:result:)`.
  }
}

// MARK: - The weak action-keyed map

/// `WeakHashMap<Action, SelectionSave>`.
///
/// D3 forbids the mechanical `NSMapTable.weakToStrongObjects()` translation and requires an
/// explicit eviction owner. Here it is: the action is held weakly, the snapshot strongly, and
/// every read purges entries whose action the undo stack has released. Entry counts are the depth
/// of the undo stack, so the linear purge is free.
@MainActor
final class WeakActionKeyedSelectionSaves {
  private struct Entry {
    weak var action: AnyObject?
    let save: SelectionSave?
  }

  private var entries: [ObjectIdentifier: Entry] = [:]

  func put(_ save: SelectionSave?, for action: Action) {
    purge()
    entries[ObjectIdentifier(action)] = Entry(action: action, save: save)
  }

  func get(for action: Action) -> SelectionSave? {
    purge()
    return entries[ObjectIdentifier(action)]?.save
  }

  func remove(for action: Action) {
    entries.removeValue(forKey: ObjectIdentifier(action))
  }

  private func purge() {
    entries = entries.filter { $0.value.action != nil }
  }
}
