// CircuitTransaction.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.circuit.{CircuitTransaction, CircuitLocker}),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// Ported from the **4.1.0** tree (D16).
//
// ── What a transaction is for ───────────────────────────────────────────────────────────────
//
// Two things, and only the first is obvious:
//
//   1. It locks every circuit the edit will touch, in a global order, before touching any of
//      them. An edit to a subcircuit's pins rewrites the port list of every circuit that
//      instantiates it, and the simulation thread may be walking those circuits at the time.
//   2. It gives the edit a single commit point. The `ReplacementMap` that reaches
//      `TRANSACTION_DONE`, and the reverse transaction that reaches the undo log, both describe
//      the *whole* edit rather than its steps. That is what lets a five-component paste undo as
//      one action and lets the simulator carry component data across a wire split.
//
// ── Nesting is real and load-bearing ────────────────────────────────────────────────────────
//
// `CircuitLocker.execute` is the subtle part. If the calling thread already holds the write lock
// on a circuit, a transaction on that circuit does **not** run standalone; it runs its `run`
// directly against the *outer* transaction's mutator. Consequences, both of which are the point:
//
//   * its changes land in the outer mutator's log, so the whole nest undoes as one entry;
//   * it produces no `CircuitTransactionResult` of its own, so the simulator is told once, at
//     the end, rather than seeing a half-finished intermediate state.
//
// `execute()`'s post-run loop preserves the other half of that: for a circuit whose locker is
// held by a *different* mutator, it skips wire repair and calls `markModified` on the owning
// mutator instead, deferring the repair to whoever commits last.

import Foundation
import LogisimFile

/// `com.cburch.logisim.circuit.CircuitTransaction`.
///
/// An abstract class rather than a protocol because `execute()` is the whole algorithm and must
/// not be overridable: subclasses supply only `accessedCircuits` and `run`, exactly as Java's
/// `final execute()` / `abstract getAccessedCircuits()` / `abstract run()` split does.
open class CircuitTransaction {

  /// `READ_ONLY` / `READ_WRITE`.
  public enum Access {
    case readOnly
    case readWrite
  }

  public init() {}

  /// `getAccessedCircuits()`.
  ///
  /// D4: keyed by identity, with the circuit carried alongside; `Circuit` has no `Hashable`
  /// conformance and must not gain one.
  open var accessedCircuits: [ObjectIdentifier: (circuit: Circuit, access: Access)] {
    fatalError("CircuitTransaction is abstract; override accessedCircuits")
  }

  /// `run(CircuitMutator)`.
  open func run(_ mutator: any CircuitMutator) throws {
    fatalError("CircuitTransaction is abstract; override run(_:)")
  }

  /// `execute()`.
  ///
  /// Returns `nil` never; upstream's `CircuitAction.doIt` null-checks the result because
  /// `CircuitLocker.execute` can route to `run` instead, which returns nothing. That routing is
  /// expressed here by `Project`/`CircuitAction` calling `executeThroughLocker`, so this method
  /// itself always produces a result.
  @discardableResult
  public final func execute() throws -> CircuitTransactionResult {
    let mutator = CircuitMutatorImpl()
    let locks = CircuitLocker.acquireLocks(self, mutator)
    defer { CircuitLocker.releaseLocks(locks) }

    try run(mutator)

    // `CircuitMutatorImpl.setForCircuit`'s tail:
    //
    // ```java
    // if (attr == CircuitAttributes.NAME_ATTR
    //     || attr == CircuitAttributes.NAMED_CIRCUIT_BOX_FIXED_SIZE) {
    //   circuit.getAppearance().recomputeDefaultAppearance();
    // }
    // ```
    //
    // Upstream runs that INLINE, mid-`run`. The port queues it (`appearanceRecomputeRequests`)
    // and drains it here, which is the one deviation: a transaction nested inside another logs
    // into the OUTER mutator, so its recompute happens when the outer transaction commits rather
    // than immediately. Both orders still put the recompute before the wire-repair pass below,
    // which is the ordering the appearance work actually depends on.
    //
    // **This is not cosmetic; measured.** `namedCircuitBoxFixedSize` is the half of that `if`
    // with no other route home: `.changeDefaultBoxAppearance` is declared in `CircuitEvent`, is
    // handled by `CircuitSubcircuitFactory.observeSource`, and is FIRED NOWHERE in Sources or
    // Tests. So toggling it through the editor moved the drawn box (`offsetBounds` reads the
    // attribute live) and left the placement's ENDS where the old box was; a west port 150px
    // inside its own box. `AppearanceRecomputeSeamTests` is that measurement.
    //
    // **Do not "fix" that by firing `.changeDefaultBoxAppearance`.** Upstream declares
    // `CircuitEvent.CHANGE_DEFAULT_BOX_APPEARANCE = 7` and fires it nowhere either: checked with
    // `git grep` over 4.1.0's `src/main/java`, two hits, both the declaration and its `toString`.
    // The port reproduces a dead constant faithfully; what it was missing is the call upstream
    // actually relies on, which is this drain. Firing the event would be a divergence dressed up
    // as a repair, and would double the recompute on the rename path.
    //
    // The `nameAttribute` half is a different story and the queue is genuinely redundant for it:
    // `CircuitStaticAttributeListener` fires `.setName`, which `observeSource` already handles.
    // Draining both anyway is upstream's behaviour and is idempotent; `computePorts` returns
    // early when the ends are unchanged.
    for circuit in mutator.appearanceRecomputeRequests {
      CircuitTransaction.appearanceRecompute?(circuit)
    }

    let modified = mutator.modified

    // Upstream's first pass: let each subcircuit's appearance update its port locations before
    // wires are repaired, because moving a port can split a wire.
    //
    // SEAM (board #22): `Circuit.getAppearance().getCircuitPins().transactionCompleted(repl)`.
    //
    // **This comment used to say `CircuitAppearance` "does not exist yet; the `<appear>` element
    // is round-tripped verbatim at M2 rather than parsed". Both halves are now false.**
    // `LogisimFile/CircuitAppearance.swift` exists, `CircuitAppearanceReader`/`Writer` parse and
    // emit the element against the `LogisimDraw` shape model, and `portOffsets(facing:)` is
    // ported. What is genuinely missing is narrower: the `CircuitPins.transactionCompleted`
    // half, which reconciles pin components against the appearance's port shapes after a
    // replacement.
    //
    // Corrected rather than left, because a stale "does not exist" is precisely how the `Text`
    // painter stayed missing for a milestone -- the file next to it said the work was blocked.
    //
    // **`appearanceHook` is now ASSIGNED**, in `LogisimFileProjectHostFactory
    // .registerBuiltinLibrariesIfNeeded`, to `CircuitSubcircuitFactory
    // .refreshPortsAfterSourceChanged()` -- which is the port's `PortManager.updatePorts`, the
    // exact call `CircuitPins.transactionCompleted` ends in.
    //
    // Honest about what that buys, because it is less than it looks: for an EDITOR edit it is
    // redundant. `Circuit.mutatorAdd`/`mutatorRemove` fire `.add`/`.remove`, `observeSource`
    // handles both, and the recompute has already happened by the time `run` returns. Measured:
    // `AppearanceRecomputeSeamTests.pinAddedThroughATransactionMovesThePorts` passes with this
    // hook cleared. It is installed because it is upstream's guarantee and because the
    // incremental listeners are the thing that could regress -- not because it repairs a
    // symptom visible today. The load path's version of that symptom is real and is why
    // `refreshPortsAfterSourceChanged` exists at all; see its doc comment.
    for circuit in modified {
      guard CircuitLocker.locker(for: circuit).mutator === mutator else { continue }
      guard let repl = mutator.replacementMap(for: circuit) else { continue }
      CircuitTransaction.appearanceHook?(circuit, repl)
    }

    // Second pass: repair each affected circuit's wires.
    for circuit in modified {
      let locker = CircuitLocker.locker(for: circuit)
      if locker.mutator === mutator {
        try CircuitTransaction.wireRepair?(circuit, mutator)
      } else {
        // A transaction executed within a transaction: defer the repair to the outer one.
        locker.mutator?.markModified(circuit)
      }
    }

    let result = CircuitTransactionResult(mutator: mutator)
    for circuit in result.modifiedCircuits {
      // SEAM: `CircuitEventData` has no case carrying a `CircuitTransactionResult`: see
      // `LogisimFile/CircuitEvent.swift`, which declares `.transactionDone` and says so. The
      // event is still fired so listeners that only care *that* a transaction completed behave
      // correctly, and the result is delivered separately below to anyone who needs the payload.
      circuit.fireEvent(.transactionDone, .none)
    }
    CircuitTransaction.transactionDone?(result)
    return result
  }

  // MARK: - Installable seams

  /// `CircuitAppearance.getCircuitPins().transactionCompleted(repl)`: board #22, installed #25.
  ///
  /// Assigned in `LogisimFileProjectHostFactory.registerBuiltinLibrariesIfNeeded`, beside
  /// `wireRepair`. The `ReplacementMap` argument is unused by the handler: upstream's
  /// `CircuitPins` walks it only to maintain its own pin set and its per-pin listeners, both of
  /// which the port derives on demand from `circuit.nonWires` instead
  /// (`CircuitAppearance.circuitPins()`), so the whole body collapses to the
  /// `PortManager.updatePorts` it ends in. The parameter is kept because dropping it would make
  /// the seam stop naming the upstream call it stands for.
  ///
  /// A settable hook rather than a direct call because `CircuitSubcircuitFactory` is the thing
  /// being reached and the installation point is the one place that owns "which runtime is this".
  public static var appearanceHook: (@Sendable (Circuit, ReplacementMap) -> Void)? {
    get { seams.withLock { $0.appearanceHook } }
    set { seams.withLock { $0.appearanceHook = newValue } }
  }

  /// `CircuitAppearance.recomputeDefaultAppearance()`, as `CircuitMutatorImpl.setForCircuit`
  /// reaches it; board #25.
  ///
  /// Separate from `appearanceHook` because upstream has two distinct calls here and they are
  /// not interchangeable: this one is driven by a static-attribute write and has no
  /// `ReplacementMap` to offer, and folding it into the other by inventing an empty map would
  /// mean the seam no longer names anything real. Both happen to resolve to the same handler in
  /// this port; that is a fact about `CircuitSubcircuitFactory`, not about upstream.
  ///
  /// Drained from `mutator.appearanceRecomputeRequests` in `execute()`. See the note there for
  /// which half of it is load-bearing and which half is redundant, both measured.
  public static var appearanceRecompute: (@Sendable (Circuit) -> Void)? {
    get { seams.withLock { $0.appearanceRecompute } }
    set { seams.withLock { $0.appearanceRecompute = newValue } }
  }

  /// `new WireRepair(circuit).run(mutator)`.
  ///
  /// **This was a real, unfilled hole in the M7 byte-exact gate. It is filled**:
  /// `registerBuiltinLibrariesIfNeeded` routes it through `CircuitWireRepairPass` and into the
  /// mutator, and `WireRepairSeamTests` holds the measurement. The two claims this comment used
  /// to make, that the pass "cannot be ported in this slice" because `CircuitPoints`
  /// connectivity was M3, and that a two-segment wire therefore saves as two `<wire>` elements,
  /// are both false now, and are corrected rather than deleted because a differential failure on
  /// a wire-drawing sequence really was checked against them.
  ///
  /// What still holds: `WireRepair` merges collinear abutting wires and splits a wire where a
  /// new component end lands on it, and it MUST go through the mutator, or the cuts never enter
  /// the `ReplacementMap`. See the installation site for why the one-line version is wrong.
  public static var wireRepair: (@Sendable (Circuit, any CircuitMutator) throws -> Void)? {
    get { seams.withLock { $0.wireRepair } }
    set { seams.withLock { $0.wireRepair = newValue } }
  }

  /// Delivers the `CircuitTransactionResult` that `CircuitEvent`'s payload enum cannot yet
  /// carry.
  ///
  /// **ASSIGNED**, permanently, in `LogisimFileProjectHostFactory.installProcessSeams()`: it
  /// broadcasts to `CircuitTransactionObservers`, whose one live conformer is `Selection`. That
  /// is upstream's `Project.addCircuitListener` list, which every `TRANSACTION_DONE` walks;
  /// `CircuitState`'s handler is the other intended consumer and is still M3.
  ///
  /// **One slot, many listeners, so do not treat this as yours to own.** Anything installing
  /// here must chain the existing closure and RESTORE it, not `nil` it: dropping it switches off
  /// the delivery that keeps every open document's selection in step with its circuit, and the
  /// symptom shows up in some unrelated suite that happens to run afterwards.
  /// `WireRepairSeamTests.repairIsRecorded` is the worked example, and reverting its `defer` to
  /// `= nil` was measured to redden three whole suites.
  public static var transactionDone: (@Sendable (CircuitTransactionResult) -> Void)? {
    get { seams.withLock { $0.transactionDone } }
    set { seams.withLock { $0.transactionDone = newValue } }
  }

  private struct Seams {
    var appearanceHook: (@Sendable (Circuit, ReplacementMap) -> Void)?
    var appearanceRecompute: (@Sendable (Circuit) -> Void)?
    var wireRepair: (@Sendable (Circuit, any CircuitMutator) throws -> Void)?
    var transactionDone: (@Sendable (CircuitTransactionResult) -> Void)?
  }

  private static let seams = LockedBox(Seams())
}

// MARK: - CircuitLocker

/// `com.cburch.logisim.circuit.CircuitLocker`.
///
/// ── Why this is a side table and not a stored property ──────────────────────────────────────
///
/// Upstream keeps a `CircuitLocker` field on `Circuit`. `Circuit.swift` belongs to the M2 codec
/// slice and its header explicitly defers `getLocker` to M3, so this slice attaches lockers from
/// the outside instead of editing a file it does not own.
///
/// D3 flags exactly this shape as the trap that leaks everything: a map keyed on an object,
/// holding that object, is a permanent retain. So the key is an `ObjectIdentifier`, the circuit
/// is held **weakly**, and the eviction owner is explicit; `locker(for:)` purges entries whose
/// circuit has gone before it does anything else. That is the same pattern
/// `Circuit.circuitsUsingThis` already uses, and it is why this is safe where an
/// `NSMapTable.weakToStrongObjects()` would not be.
public final class CircuitLocker {

  /// `serialNumber`. Locks are always acquired in ascending serial order, which is what makes
  /// a multi-circuit transaction deadlock-free: two threads locking overlapping sets acquire
  /// the shared circuits in the same sequence, so neither can hold what the other needs next.
  public let serialNumber: Int

  /// `circuitLock`. Java uses a `ReentrantReadWriteLock`; `pthread_rwlock_t` is the closest
  /// primitive available. It is *not* reentrant, which is fine because upstream never
  /// re-acquires: `acquireLocks` checks `mutatingThread == curThread` first and does nothing
  /// when the thread already owns the write lock.
  private let lock = ReadWriteLock()

  /// `mutatingThread` / `mutatingMutator`. Read from other threads to answer `hasWriteLock`,
  /// so both go through the registry's lock.
  fileprivate var mutatingThread: Thread?
  fileprivate var mutatingMutator: CircuitMutatorImpl?

  fileprivate init(serialNumber: Int) {
    self.serialNumber = serialNumber
  }

  /// `getMutator()`.
  public var mutator: CircuitMutatorImpl? {
    CircuitLocker.registry.withLock { _ in mutatingMutator }
  }

  /// `hasWriteLock()`.
  public var hasWriteLock: Bool {
    CircuitLocker.registry.withLock { _ in mutatingThread === Thread.current }
  }

  /// `checkForWritePermission(String, Circuit)`.
  ///
  /// D13: throws rather than trapping. Upstream's `LockException` extends
  /// `IllegalStateException` and is caught and *rethrown* with diagnostics by both
  /// `CircuitTransaction.execute` and `Project.doAction`, so it is a reportable condition in
  /// Java too; trapping here would turn a tool bug into a process death with unsaved work lost.
  public func checkForWritePermission(_ operation: String, _ circuit: Circuit) throws {
    guard hasWriteLock else {
      throw CircuitMutationError.writeWithoutLock(circuitName: circuit.name)
    }
  }

  /// `execute(CircuitTransaction)`; the nesting entry point. See the file header for why this
  /// is not just a call to `execute()`.
  @discardableResult
  public func execute(_ transaction: CircuitTransaction) throws -> CircuitTransactionResult? {
    if let outer = CircuitLocker.registry.withLock({ _ -> CircuitMutatorImpl? in
      mutatingThread === Thread.current ? mutatingMutator : nil
    }) {
      try transaction.run(outer)
      return nil
    }
    return try transaction.execute()
  }

  // MARK: - The registry

  /// `acquireLocks(CircuitTransaction, CircuitMutatorImpl)`.
  fileprivate static func acquireLocks(
    _ transaction: CircuitTransaction, _ mutator: CircuitMutatorImpl
  ) -> [(circuit: Circuit, locker: CircuitLocker, isWrite: Bool)] {
    let requests = transaction.accessedCircuits
    var acquired: [(circuit: Circuit, locker: CircuitLocker, isWrite: Bool)] = []

    // Ascending serial order: the deadlock-avoidance invariant. See `serialNumber`.
    let ordered = requests.values
      .map { (circuit: $0.circuit, access: $0.access, locker: locker(for: $0.circuit)) }
      .sorted { $0.locker.serialNumber < $1.locker.serialNumber }

    for request in ordered {
      let locker = request.locker
      switch request.access {
      case .readOnly:
        locker.lock.lockRead()
        acquired.append((request.circuit, locker, false))
      case .readWrite:
        // Already owned by this thread: nothing to do, and crucially nothing to *release*
        // either, or the outer transaction would find itself unlocked.
        let alreadyOwned = registry.withLock { _ in locker.mutatingThread === Thread.current }
        if alreadyOwned { continue }
        locker.lock.lockWrite()
        registry.withLock { _ in
          locker.mutatingThread = Thread.current
          locker.mutatingMutator = mutator
        }
        acquired.append((request.circuit, locker, true))
      }
    }
    return acquired
  }

  /// `releaseLocks(Map<Circuit, Lock>)`.
  fileprivate static func releaseLocks(
    _ locks: [(circuit: Circuit, locker: CircuitLocker, isWrite: Bool)]
  ) {
    for entry in locks {
      registry.withLock { _ in
        if entry.locker.mutatingThread === Thread.current {
          entry.locker.mutatingThread = nil
          entry.locker.mutatingMutator = nil
        }
      }
      entry.locker.lock.unlock()
    }
  }

  /// `Circuit.getLocker()`, from the outside. Creates the locker on first ask.
  public static func locker(for circuit: Circuit) -> CircuitLocker {
    registry.withLock { state in
      state.purge()
      let key = ObjectIdentifier(circuit)
      if let existing = state.entries[key]?.locker { return existing }
      let created = CircuitLocker(serialNumber: state.nextSerialNumber)
      state.nextSerialNumber &+= 1
      state.entries[key] = Registry.Entry(circuit: circuit, locker: created)
      return created
    }
  }

  private struct Registry {
    struct Entry {
      weak var circuit: Circuit?
      let locker: CircuitLocker
    }
    var entries: [ObjectIdentifier: Entry] = [:]
    /// `nextSerialNumber`, an `AtomicInteger` upstream; the registry lock serialises it here.
    /// `&+=` because a `.circ` session cannot plausibly reach 2^63 circuits but the wrap is
    /// free and a trap would be absurd.
    var nextSerialNumber: Int = 0

    /// The explicit eviction owner D3 requires. Cheap: it runs on locker lookup, which happens
    /// once per circuit per transaction, not per component.
    mutating func purge() {
      entries = entries.filter { $0.value.circuit != nil }
    }
  }

  private static let registry = LockedBox(Registry())
}

/// A minimal `pthread_rwlock_t` wrapper; the standard library has no reader/writer lock and
/// Java's `ReentrantReadWriteLock` is what the algorithm above is written against.
///
/// Not reentrant, deliberately: see `CircuitLocker.lock`.
private final class ReadWriteLock: @unchecked Sendable {
  private var handle = pthread_rwlock_t()

  init() {
    pthread_rwlock_init(&handle, nil)
  }

  deinit {
    pthread_rwlock_destroy(&handle)
  }

  func lockRead() { pthread_rwlock_rdlock(&handle) }
  func lockWrite() { pthread_rwlock_wrlock(&handle) }
  func unlock() { pthread_rwlock_unlock(&handle) }
}

/// The registry and the seam table are shared mutable state reachable from both the editing
/// thread and (at M3) the propagation thread, so they are lock-guarded rather than isolated.
/// `@unchecked Sendable` is the honest annotation: the invariant is enforced by the lock, not
/// by the type system.
final class LockedBox<Value>: @unchecked Sendable {
  private var value: Value
  private let lock = NSLock()

  init(_ value: Value) { self.value = value }

  func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
    lock.lock()
    defer { lock.unlock() }
    return try body(&value)
  }
}
