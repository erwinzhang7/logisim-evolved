// CircuitTransactionObservers.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.proj.Project's circuit-listener list, as
// com.cburch.logisim.gui.main.Selection registers into it),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Ported from the **4.1.0** tree (D16).
//
// ══ WHAT THIS STANDS FOR, AND WHY IT IS A REGISTRY RATHER THAN A CALL ═══════════════════════
//
// Upstream delivers a transaction's `ReplacementMap` to **every live selection, after every
// transaction**. The mechanism is two ordinary listener lists:
//
//   * `Selection(Project, Canvas)` registers its `MyListener` with `Project.addProjectListener`
//     *and* `Project.addCircuitListener`: `javap -c -classpath
//     logisim-evolution-4.1.0-all.jar com.cburch.logisim.gui.main.Selection`, bytecode offsets
//     40 and 48 of the constructor.
//   * `Project.addCircuitListener` adds the listener to the project's own weak list **and to the
//     current circuit** (`javap -c … com.cburch.logisim.proj.Project`, `addCircuitListener`
//     offsets 0-19), and `setCurrentCircuit` moves it when the current circuit changes. So a
//     selection hears `TRANSACTION_DONE` for the circuit it is a selection *of*, and for no
//     other.
//   * `Selection$MyListener.circuitChanged` branches on action `6` (`TRANSACTION_DONE`) into
//     `getResult().getReplacementMap(circuit)` and swaps the selection's components.
//
// The port cannot reproduce that chain literally: `CircuitEventData` (in `LogisimFile`) has no
// case that can carry a `CircuitTransactionResult` (in `LogisimUI`), and the lower module must
// not gain an edge to the upper one. `CircuitTransaction.transactionDone` is the seam that
// carries the payload instead, and it is a **single process-global closure**, one slot, where
// upstream has a list.
//
// This file is the list. One closure is installed into that slot, permanently, in
// `LogisimFileProjectHostFactory.installProcessSeams()`, and it broadcasts to whoever is
// registered here.
//
// ── Why not simply chain closures at each canvas's construction ─────────────────────────────
//
// That is what `SelectTool.commitMove` did while the delivery was scoped to one `perform`, and
// it is correct for a scoped install and wrong for a permanent one. A chain grows by one link
// per canvas; a long test run builds thousands of canvases, so the chain becomes O(n) work per
// transaction and every link retains the previous one and the selection it closed over; an
// unbounded leak of exactly the objects a closed document is supposed to release. A registry
// with weak entries is bounded by the number of *live* selections instead.
//
// ── D3: weak, and with an explicit eviction owner ───────────────────────────────────────────
//
// Entries hold their observer weakly, so a closed document's selection is neither kept alive nor
// delivered to. Deregistration is belt and braces:
//
//   * `Selection.deinit` calls `deregister(_:)`, which is why the entry disappears promptly
//     rather than at the next traversal; and
//   * every traversal purges entries whose weak reference has gone `nil` anyway, so a future
//     observer that forgets to deregister still cannot accumulate.
//
// The identity is captured *at registration* (`ObjectIdentifier`), because inside `deinit` the
// object's own weak references already read `nil` and an entry could not otherwise be matched.
//
// **Deallocation during a broadcast is safe by construction**: `liveObservers()` resolves every
// weak reference to a *strong* local array under the lock and releases the lock before calling
// out, so an observer cannot vanish between the `nil` check and the call, and a callback that
// deallocates some other observer (closing a window, say) cannot mutate the list being iterated.
// The deallocation it triggers simply happens when the strong snapshot is released.

import Foundation

/// The port's stand-in for "registered with `Project.addCircuitListener`, and therefore reached
/// by `TRANSACTION_DONE`".
///
/// Deliberately narrower than `CircuitListener`: that protocol lives in `LogisimFile` and its
/// event cannot carry a `CircuitTransactionResult`, which is the whole payload this exists to
/// deliver. `Selection` conforms to both; the `CircuitListener` half stays empty and says so.
@MainActor
public protocol CircuitTransactionObserver: AnyObject {
  /// `Selection$MyListener.circuitChanged`'s `TRANSACTION_DONE` arm.
  ///
  /// The result describes the whole transaction, which may have touched circuits this observer
  /// has nothing to do with. Upstream's per-circuit registration filters those out; here the
  /// observer filters them itself, and `CircuitTransactionResult.replacementMap(for:)` makes that
  /// cheap; it answers an empty map for a circuit the transaction did not modify, so the handler
  /// is a no-op rather than a special case.
  func transactionDone(result: CircuitTransactionResult)
}

/// Every live `CircuitTransactionObserver`, and the one broadcast that feeds them.
///
/// `enum` as a namespace, matching `BuiltinToolProviders` and `SelectionActions`.
public enum CircuitTransactionObservers {

  /// One registration: the observer, held weakly, beside the identity it had when it registered.
  private final class Box {
    /// Captured at registration. Inside `deinit` a weak reference to the dying object already
    /// reads `nil`, so `observer === x` cannot match there and this is what `deregister` uses.
    let id: ObjectIdentifier
    weak var observer: (any CircuitTransactionObserver)?

    init(_ observer: any CircuitTransactionObserver) {
      self.id = ObjectIdentifier(observer)
      self.observer = observer
    }
  }

  /// `nonisolated(unsafe)` + a lock rather than `@MainActor` isolation, for the same reason
  /// `CircuitTransaction.seams` is: the seam that reads this is a `@Sendable` closure with no
  /// isolation of its own, and `deregister` is called from a `deinit`, which is never isolated.
  /// The invariant is enforced by `lock`, and `@unchecked`-style annotations are the honest way
  /// to say so.
  private nonisolated(unsafe) static var boxes: [Box] = []

  /// **Recursive, and that is load-bearing.** `withObserversCleared` holds this across its body,
  /// and a body that performs an edit re-enters through `broadcast`. With a plain `NSLock` that
  /// is a self-deadlock on the same thread; with this it re-enters, sees the cleared list, and
  /// delivers to nobody, which is what "cleared" is supposed to mean. Same reasoning, and the
  /// same lock type, as `BuiltinToolProviders.lock`.
  private static let lock = NSRecursiveLock()

  // MARK: - Registration

  /// `Project.addCircuitListener(myListener)`, as `Selection`'s constructor calls it.
  ///
  /// Idempotent. Upstream's `EventSourceWeakSupport.add` is not, it will hold and fire the same
  /// listener twice, but nothing registers twice, and a duplicate here would apply a replacement
  /// map twice to one selection. That happens to be harmless (see `Selection.transactionDone`),
  /// and relying on it would be relying on luck.
  public static func register(_ observer: any CircuitTransactionObserver) {
    lock.lock()
    defer { lock.unlock() }
    registerLocked(observer)
  }

  /// `register`'s body with the lock already held, so `withObserversCleared`'s restore can re-add
  /// the observers that arrived during its window without re-entering. The lock is recursive, so
  /// calling `register` there would also work, but relying on recursion to paper over a
  /// double-acquire is how a later switch to a plain `NSLock` turns into a deadlock, and that
  /// exact substitution is already a red probe on this file.
  private static func registerLocked(_ observer: any CircuitTransactionObserver) {
    purgeLocked()
    let id = ObjectIdentifier(observer)
    guard !boxes.contains(where: { $0.id == id }) else { return }
    boxes.append(Box(observer))
  }

  /// Drop the registration for the object that had this identity.
  ///
  /// Takes an `ObjectIdentifier` rather than the object because the only caller is a `deinit`,
  /// where handing the dying object to another function is precisely what one must not do.
  public static func deregister(_ id: ObjectIdentifier) {
    lock.lock()
    defer { lock.unlock() }
    boxes.removeAll { $0.id == id || $0.observer == nil }
  }

  // MARK: - Delivery

  /// Hand one transaction's result to every live observer.
  ///
  /// Not `public`: the only caller is the seam closure in `installProcessSeams`, and a second
  /// caller would mean a result delivered twice.
  @MainActor
  static func broadcast(_ result: CircuitTransactionResult) {
    for observer in liveObservers() {
      observer.transactionDone(result: result)
    }
  }

  /// A **strong** snapshot, taken under the lock and returned after it is released. See the file
  /// header for why the strength and the release order are both deliberate.
  private static func liveObservers() -> [any CircuitTransactionObserver] {
    lock.lock()
    defer { lock.unlock() }
    purgeLocked()
    return boxes.compactMap(\.observer)
  }

  private static func purgeLocked() {
    boxes.removeAll { $0.observer == nil }
  }

  // MARK: - Test support

  /// Run `body` with no observers registered, then restore **exactly** what was there.
  ///
  /// New process-global state gets its `withCleared` in the same commit it is introduced. Three
  /// separate incidents in this tree came from a test wiping shared state and putting back less
  /// than it took: `BuiltinToolProviders.withRegistryCleared`'s header tells that story at
  /// length, and this is the same shape: snapshot, clear, restore under one lock, so no caller
  /// can observe the empty window and nothing is lost even when the caller cannot name what was
  /// registered.
  public static func withObserversCleared<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }

    let saved = boxes
    // Registered second so it runs first (defers are LIFO): i.e. still under the lock.
    //
    // **MERGE, do not replace.** This was `boxes = saved`, which discards every registration made
    // *inside* the window, so a `Selection` constructed during the body was permanently
    // deregistered and silently never received another transaction result again, which is the
    // very defect this registry exists to prevent. The doc above promises to restore "exactly what
    // was there"; that is a claim about not LOSING the prior set, not a licence to delete a live
    // observer that arrived later.
    //
    // Appending rather than unioning is safe because `register` already refuses duplicates by
    // identity, and `purgeLocked` drops dead boxes on every traversal, so a re-registered
    // observer cannot appear twice and a dead one cannot survive.
    defer {
      let arrivedDuringBody = boxes
      boxes = saved
      for box in arrivedDuringBody {
        guard let observer = box.observer else { continue }
        registerLocked(observer)
      }
    }

    boxes = []
    return try body()
  }

  /// How many live observers are registered. The measurement that tells "the registry is bounded
  /// by live canvases" apart from "the registry grows forever", which is the property the whole
  /// weak/deinit apparatus exists to provide.
  public static var registeredCount: Int {
    lock.lock()
    defer { lock.unlock() }
    purgeLocked()
    return boxes.count
  }
}
