// SimulatedCircuit.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.circuit.Circuit: the simulation half),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Why this is a wrapper and not `extension Circuit: SimCircuit` ───────────────────────────
//
// The five `Component` conformances in `ComponentSimulationSeams.swift` *are* plain extensions,
// because every answer they give is derived; no new storage. `SimCircuit` cannot be done that
// way: it needs a `CircuitWires` (the connectivity engine, which is stateful and must be kept in
// step with the component set) and a listener registry that hands back subscription tokens.
// Swift extensions cannot add stored properties, and the alternative, a global side table keyed
// by `ObjectIdentifier(circuit)`, is precisely the pattern D3 warns about: it has no eviction
// owner, so every circuit ever simulated stays alive for the life of the process.
//
// `LogisimFile.Circuit` is owned by another slice and is, by its own header, the *inert netlist*:
// it has a `CircuitWireStore` (the storage half of `CircuitWires`) and deliberately no
// connectivity engine. So the simulation half is attached from outside, with an explicit owner;
// the `SimulationSession` that made it. When `Circuit` eventually absorbs `CircuitWires`
// directly, this class collapses into an extension and nothing above it changes.
//
// ── LIVE EDITS, AND THE DEFECT THAT CAME OF NOT TRACKING THEM ───────────────────────────────
//
// This file used to end its header with: *"A headless `-tty table` run never edits, so the
// registry below is wired and correct but nothing fires it yet; connecting `Circuit.fireEvent`
// to it is the editing-path job, not this one."* That was true when it was written and it became
// the whole of a user-visible defect the day the canvas was connected to the simulator:
// **"poke tool seems to not do jack actually."**
//
// The wire map below was loaded once, in `init`, and never again. `wireStore.add` had exactly one
// call site in the entire tree, the loop in that initialiser, and `CircuitWires.remove` had
// none at all. (The three `wireStore.add/remove` hits in `LogisimFile/Circuit.swift` are a
// *different object with a confusingly similar name*: `Circuit`'s storage-only
// `CircuitWireStore`, not the simulation's connectivity engine. So the netlist's bookkeeping was
// kept current and the simulation's was not.) `SimulationSession` caches one wrapper per
// `Circuit` for the life of the host, so even rebuilding the root state, Reset, or switching
// circuits, handed back the same frozen map.
//
// Everything a user drew *after opening the document* was therefore invisible to the simulation's
// connectivity, which is every component in a circuit they are building. Traced end to end:
// `Pin.propagate` ran and `setPort` really did write a value; `Propagator.setValue` queued it and
// `stepInternal` drained it; and `CircuitWires.propagate` then discarded it at
// `guard let vb = state.busAt[p] else { continue }`, because with an empty map there is no bus at
// the pin's port. `CircuitState.getValue` fell through to `Value.createUnknown(circuit.width(at:
// p))`, and `width(at:)` on an unknown point is **0**: a width-0 UNKNOWN, which renders as `-`.
// That is exactly the reported symptom, four layers below where it was first looked for.
//
// ── Why keeping the map in step also restores dirty marking ─────────────────────────────────
//
// `CircuitState.handleCircuitEvent`'s `.add` arm is a deliberate no-op, verbatim from upstream:
// *"Nothing to do: CircuitWires.Connectivity will be voided, causing everything to be marked
// dirty."* That is not a shortcut, it is the mechanism. `CircuitWires.add` voids the connectivity
// map, and the next `CircuitWires.propagate` notices the map changed and does the marking itself.
// Measured: with the map stale the host's propagations ran with an empty event queue because
// nothing was ever dirty; with it repaired the same propagation reports work and the values
// appear.
//
// ── Not by rebuilding the wrapper ───────────────────────────────────────────────────────────
//
// The tempting fix is to drop the session's cache entry on every edit and build a fresh wrapper.
// It is wrong: a new `CircuitState` discards `componentData`, so every RAM, ROM, register and
// counter would be wiped on each edit, and substate identity would break (D4). Upstream is
// incremental, `Circuit.mutatorAdd` calls `wires.add(c)` and then fires, and so is this.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.circuit.Circuit`, as the simulation kernel sees it.
///
/// One of these per `Circuit` per session. Identity matters: `CircuitState` keys its substates
/// and dirty lists on the objects it is handed, so a second wrapper around the same `Circuit`
/// would be a second, silently divergent circuit. `SimulationSession` is the cache that prevents
/// that.
public final class SimulatedCircuit: SimCircuit {

  /// The inert netlist this wraps.
  ///
  /// **Strong.** D3's owning direction is `Circuit -> components`; nothing in a `Circuit` reaches
  /// back to a `SimulatedCircuit`, so this closes no cycle, and the wrapper must keep the circuit
  /// it is simulating alive exactly as `CircuitState.circuit` does.
  public let circuit: Circuit

  /// `circuit.wires`: the connectivity engine (`CircuitWires`), not the netlist's storage-only
  /// `CircuitWireStore`.
  ///
  /// `private(set) var` rather than `let` because `ACTION_CLEAR` **replaces** the object rather
  /// than emptying it, which is what upstream does (`Circuit.java:905`, `wires = new
  /// CircuitWires()`). A cleared-in-place map and a fresh one are not the same thing to
  /// `CircuitWires.propagate`, which compares connectivity identity to decide whether to remark
  /// everything dirty.
  private let wireStoreLock = NSLock()
  private var storedWireStore: CircuitWires

  public private(set) var wireStore: CircuitWires {
    get {
      wireStoreLock.lock()
      defer { wireStoreLock.unlock() }
      return storedWireStore
    }
    set {
      wireStoreLock.lock()
      storedWireStore = newValue
      wireStoreLock.unlock()
    }
  }

  private let listeners = CircuitListenerRegistry()

  /// Keeps `wireStore` in step with the netlist, and forwards the event to `CircuitState`.
  ///
  /// **Held strongly, and that is the whole lifetime story.** `Circuit`'s listener list is a
  /// `WeakListenerList`, so the wrapper must own its listener or the subscription would evaporate
  /// at the next collection; and because the listener's back-reference is `weak`, the
  /// subscription dies with the wrapper and closes no cycle. Same nested-listener shape
  /// `CircuitWires.TunnelListener` already uses, rather than a closure capturing `self`.
  private var editListener: EditListener?

  /// Edits seen by the editing thread and not yet applied by the propagation thread.
  ///
  /// Guarded because the two ends genuinely run on different threads; the lock is held only for
  /// the append and the swap, never across a `CircuitWires` mutation, so it can never be the lock
  /// a propagation waits on.
  private var pendingEdits: [PendingEdit] = []
  private let pendingLock = NSLock()

  /// Builds the wrapper and loads the netlist into a fresh `CircuitWires`.
  ///
  /// The order matches `Circuit.mutatorAdd`: every component, wires included, goes through
  /// `CircuitWires.add`, which sorts it into the wire/splitter/tunnel/pull/plain bucket its
  /// `wireRole` names. Connectivity itself is computed lazily on first `getConnectivity()`, as
  /// upstream does.
  public init(_ circuit: Circuit) {
    self.circuit = circuit
    self.storedWireStore = CircuitWires()
    for component in circuit.components {
      if let simComponent = component as? any SimComponent {
        wireStore.add(simComponent)
      }
    }
    // …and stay in step from here on. See the header: loading once was the defect.
    let listener = EditListener(owner: self)
    editListener = listener
    circuit.addCircuitListener(listener)
  }

  deinit {
    // `Circuit` holds listeners weakly, so this is belt and braces rather than load-bearing,
    // but an explicit removal keeps the registry from carrying a tombstone until its next sweep.
    if let editListener { circuit.removeCircuitListener(editListener) }
  }

  // MARK: - Live edits

  /// `Circuit.mutatorAdd` / `mutatorRemove` / `mutatorClear`, as the simulation needs to see them.
  ///
  /// Queue on the editing thread and drain at the propagation boundary. This protects event
  /// ordering and CircuitState updates; CircuitWires owns its topology synchronization, and
  /// wireStoreLock protects replacement of the map itself on clear. Component attribute edits
  /// still require the enclosing model lock.
  private func circuitDidChange(_ event: CircuitEvent) {
    guard let action = SimulatedCircuit.simAction(for: event.action) else {
      // Nothing the simulation reads. Upstream's `MyCircuitListener` ignores these too.
      return
    }
    // **Queue, do not apply.** This runs on whichever thread made the edit, the main actor for a
    // tool gesture, a loader thread for a file, a test's thread for a rig, while the propagation
    // thread owns CircuitState event handling. See `SimCircuit.applyPendingEdits`.
    pendingLock.lock()
    pendingEdits.append(PendingEdit(action: action, component: eventComponent(event)))
    pendingLock.unlock()
  }

  /// Drains the queue on the propagation thread. See `SimCircuit.applyPendingEdits`.
  ///
  /// The wire map is updated **before** the event is forwarded, which is upstream's order;
  /// `Circuit.mutatorAdd` does `wires.add(c)` and then `fireEvent(ACTION_ADD, c)`, and
  /// `CircuitState.handleCircuitEvent`'s `.add` arm is a deliberate no-op *because* the
  /// connectivity has already been voided by the time it runs.
  public func applyPendingEdits() {
    pendingLock.lock()
    let edits = pendingEdits
    pendingEdits.removeAll(keepingCapacity: true)
    pendingLock.unlock()
    guard !edits.isEmpty else { return }

    for edit in edits {
      switch edit.action {
      case .add:
        if let component = edit.component { wireStore.add(component) }
      case .remove:
        if let component = edit.component { wireStore.remove(component) }
      case .clear:
        // Replace, do not empty, see `wireStore`.
        wireStore = CircuitWires()
      case .invalidate, .transactionDone:
        break
      }
      fireCircuitEvent(SimCircuitEvent(action: edit.action, component: edit.component))
    }
  }

  private struct PendingEdit {
    let action: SimCircuitEventAction
    let component: (any SimComponent)?
  }

  private func eventComponent(_ event: CircuitEvent) -> (any SimComponent)? {
    guard case .component(let component) = event.data else { return nil }
    return component as? any SimComponent
  }

  private static func simAction(for action: CircuitEventAction) -> SimCircuitEventAction? {
    switch action {
    case .add: return .add
    case .remove: return .remove
    case .clear: return .clear
    case .invalidate: return .invalidate
    case .transactionDone: return .transactionDone
    default: return nil
    }
  }

  /// **`weak`, not `unowned`, and that distinction was measured rather than reasoned.**
  ///
  /// This started as `unowned let owner`, copying the shape `CircuitWires.TunnelListener` uses,
  /// on the argument that the wrapper owns the listener and the circuit holds it weakly, so the
  /// listener can never outlive its owner. That argument is wrong by one step:
  /// `WeakListenerList.fire` takes a **strong snapshot** of its listeners before calling them, so
  /// between the snapshot and the call the listener is alive on the stack while the last reference
  /// to the wrapper can go. `owner` is then a dangling `unowned` and reading it aborts the process
  /// with *"Attempted to read an unowned reference but object … was already destroyed"*, which is
  /// exactly what one suite run in three produced.
  ///
  /// Twice in one day, on two different objects. The rule this project should take from it: an
  /// `unowned` reference is only safe when the owner's lifetime *strictly contains* every call
  /// site, and a listener registry that snapshots is a call site whose lifetime you do not
  /// control. `weak` costs a branch and turns a process abort into the correct no-op; a circuit
  /// whose simulation wrapper has gone has nothing to keep in step.
  private final class EditListener: CircuitListener {
    weak var owner: SimulatedCircuit?

    init(owner: SimulatedCircuit) { self.owner = owner }

    func circuitChanged(_ event: CircuitEvent) { owner?.circuitDidChange(event) }
  }

  // MARK: - SimCircuit

  /// `getName()`.
  public var circuitName: String { circuit.name }

  /// `getNonWires()`.
  ///
  /// Insertion-ordered rather than Java's `HashSet` order; see `SimCircuit`'s note. This is the
  /// order components are first marked dirty in, so it must be reproducible across runs.
  public var nonWireComponents: [any SimComponent] {
    circuit.nonWires.compactMap { $0 as? any SimComponent }
  }

  /// `getClocks()`.
  public var clockComponents: [any SimComponent] {
    circuit.clocks.compactMap { $0 as? any SimComponent }
  }

  /// `getWidth(Location)`.
  public func width(at point: Location) -> BitWidth {
    wireStore.getWidth(point)
  }

  /// `isConnected(Location, Component)`:
  ///
  /// ```java
  /// public boolean isConnected(Location loc, Component ignore) {
  ///   for (final var o : wires.points.getComponents(loc)) {
  ///     if (o != ignore) return true;
  ///   }
  ///   return false;
  /// }
  /// ```
  ///
  /// D4: `!=` on components is reference identity, hence `!==`.
  public func isConnected(_ location: Location, ignoring component: any SimComponent) -> Bool {
    wireStore.pointStore.getComponents(location).contains { $0 !== component }
  }

  /// `addCircuitListener(CircuitListener)`.
  public func addCircuitListener(_ listener: any SimCircuitListener) -> CircuitSubscription {
    listeners.add(listener)
  }

  /// `fireEvent(CircuitEvent)`; the driver for the registry above. See the file header for why
  /// nothing calls it on the headless path yet.
  public func fireCircuitEvent(_ event: SimCircuitEvent) {
    listeners.fire(event)
  }
}

extension SimulatedCircuit: CustomStringConvertible {
  public var description: String { "SimulatedCircuit[\(circuit.name)]" }
}
