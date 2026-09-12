// LogisimUITests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE REGISTRY ITSELF: BOUNDED, WEAK, RESTORABLE.
//
// `TransactionDeliveryTests` gates what the delivery *does*. This file gates the properties that
// make it safe to install permanently, each of which is a way the obvious implementation goes
// wrong:
//
//   * **Chaining closures into the single seam slot leaks.** One link per canvas, each retaining
//     the previous link and the selection it closed over. A long test run builds thousands of
//     canvases. `registryIsBoundedByLiveSelections` is the measurement that separates a weak
//     registry from a chain; it fails for a strong list and for a `deinit`-less one alike.
//   * **A closed document must stop receiving.** `deadObserversAreNeverCalled`.
//   * **Wiping process-global state in a test must restore it.** `withObserversCleared` exists
//     for that and is itself gated here; `BuiltinToolProviders.withRegistryCleared`'s header
//     tells the story of the three incidents that made this a standing rule.
//   * **A callback that deallocates another observer must not corrupt the traversal.**
//     `broadcastSurvivesAnObserverDyingInAnothersCallback`.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd
import Testing

@testable import LogisimUI

// MARK: - A minimal observer

/// Not a `Selection`: these tests are about the registry's own contract, and a `Selection` drags
/// in a project, a circuit and a canvas whose lifetimes would then be what is being measured.
@MainActor
private final class CountingObserver: CircuitTransactionObserver {
  private(set) var calls = 0
  /// Run inside `transactionDone`, which is how the "an observer dies mid-broadcast" case is
  /// staged without needing a real window to close.
  var onDelivery: (() -> Void)?

  func transactionDone(result: CircuitTransactionResult) {
    calls += 1
    onDelivery?()
  }
}

@Suite("CircuitTransactionObservers", .serialized)
struct CircuitTransactionObserverTests {

  // ── Registration mechanics ────────────────────────────────────────────────────────────────

  @Test("an observer is delivered to, once, and only while it is alive")
  @MainActor
  func deadObserversAreNeverCalled() throws {
    try CircuitTransactionObservers.withObserversCleared {
      let host = try #require(
        try LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
      let circuit = try #require(host.currentCircuitObject)

      let survivor = CountingObserver()
      var doomed: CountingObserver? = CountingObserver()
      CircuitTransactionObservers.register(survivor)
      CircuitTransactionObservers.register(try #require(doomed))
      #expect(CircuitTransactionObservers.registeredCount == 2)

      let pin = try Pin.factory.createComponent(
        location: Location.create(100, 100, hasToSnap: false),
        attributes: Pin.factory.createAttributeSet())
      let first = host.project.beginMutation(on: circuit)
      first.add(pin)
      try host.project.doAction(first.toAction("add a pin"))

      #expect(survivor.calls == 1)
      #expect(doomed?.calls == 1)

      // Drop the second one. The registry holds it weakly, so nothing else keeps it alive and
      // its `deinit` deregisters; both halves are load-bearing and both are checked: the count
      // proves the entry is gone, the call count proves the delivery is.
      doomed = nil
      #expect(CircuitTransactionObservers.registeredCount == 1)

      let second = host.project.beginMutation(on: circuit)
      second.remove(pin)
      try host.project.doAction(second.toAction("remove the pin"))
      #expect(survivor.calls == 2)
    }
  }

  @Test("registering the same observer twice registers it once")
  @MainActor
  func registrationIsIdempotent() {
    CircuitTransactionObservers.withObserversCleared {
      let observer = CountingObserver()
      CircuitTransactionObservers.register(observer)
      CircuitTransactionObservers.register(observer)
      #expect(CircuitTransactionObservers.registeredCount == 1)
      CircuitTransactionObservers.broadcast(FakeResults.empty())
      #expect(observer.calls == 1)
    }
  }

  /// The property that rules out closure chaining, measured rather than argued.
  ///
  /// Ten documents are opened and closed. If the registry were a strong list, or a chain of
  /// closures in the seam slot, the count would keep climbing for the rest of the process. It
  /// must come back to zero.
  ///
  /// Red-probed by dropping `weak` from the registry's box: this reports `10 == 0` failed, which
  /// is also the measurement of one selection per document (`makeRenderSurface()` builds the
  /// host's own `CircuitEditorCanvas`, and with it the one `Selection` that registers).
  @Test("the registry is bounded by the number of LIVE selections")
  @MainActor
  func registryIsBoundedByLiveSelections() throws {
    try CircuitTransactionObservers.withObserversCleared {
      #expect(CircuitTransactionObservers.registeredCount == 0)

      for _ in 0..<10 {
        let host = try #require(
          try LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
        _ = host.makeRenderSurface()
        #expect(CircuitTransactionObservers.registeredCount > 0)
      }

      // Every host above went out of scope at the end of its iteration.
      #expect(CircuitTransactionObservers.registeredCount == 0)
    }
  }

  /// A callback that drops another observer must not corrupt the broadcast.
  ///
  /// This is the "a canvas is deallocated mid-transaction" case, staged deterministically: the
  /// first observer releases the second while the broadcast is in flight. The snapshot
  /// `liveObservers()` takes is *strong*, so the second one is still alive and still delivered to
  /// for this round, the deallocation happens when the snapshot is released, and it is gone by
  /// the next round. Either answer would be defensible; what would not be is a crash or a
  /// half-visited list, so both counts are pinned.
  @Test("a broadcast survives an observer dying inside another observer's callback")
  @MainActor
  func broadcastSurvivesAnObserverDyingInAnothersCallback() {
    CircuitTransactionObservers.withObserversCleared {
      let first = CountingObserver()
      var second: CountingObserver? = CountingObserver()
      let secondsCalls = { second?.calls }

      CircuitTransactionObservers.register(first)
      CircuitTransactionObservers.register(second!)
      first.onDelivery = { second = nil }

      CircuitTransactionObservers.broadcast(FakeResults.empty())

      #expect(first.calls == 1)
      // `second` has been released by the closure above; the strong snapshot outlived it just
      // long enough to deliver. What matters is that the registry is now clean and the process
      // is still standing.
      #expect(secondsCalls() == nil)
      #expect(CircuitTransactionObservers.registeredCount == 1)

      CircuitTransactionObservers.broadcast(FakeResults.empty())
      #expect(first.calls == 2)
    }
  }

  // ── withObserversCleared ──────────────────────────────────────────────────────────────────

  /// Restores **exactly** what was there, including registrations this module could not name.
  ///
  /// The failure this forbids is the one `BuiltinToolProviders.withRegistryCleared` documents: a
  /// test clears shared state, puts back only what it knows how to build, and the loss outlives
  /// the window: green under `--filter`, red in a full run, in some unrelated suite.
  @Test("withObserversCleared restores every registration, and delivery resumes")
  @MainActor
  func withObserversClearedRestoresExactly() {
    let outer = CountingObserver()
    CircuitTransactionObservers.register(outer)
    defer { CircuitTransactionObservers.deregister(ObjectIdentifier(outer)) }
    let before = CircuitTransactionObservers.registeredCount

    CircuitTransactionObservers.withObserversCleared {
      #expect(CircuitTransactionObservers.registeredCount == 0)
      CircuitTransactionObservers.broadcast(FakeResults.empty())
      #expect(outer.calls == 0, "a cleared registry must deliver to nobody")

      let inner = CountingObserver()
      CircuitTransactionObservers.register(inner)
      #expect(CircuitTransactionObservers.registeredCount == 1)
    }

    #expect(CircuitTransactionObservers.registeredCount == before)
    CircuitTransactionObservers.broadcast(FakeResults.empty())
    #expect(outer.calls == 1, "the restored registration must be live, not merely counted")
  }

  /// The recursive lock, stated as behaviour.
  ///
  /// `withObserversCleared` holds its lock across the body, and a body that performs an edit
  /// re-enters through `broadcast`. With a non-recursive lock that is a self-deadlock on the same
  /// thread: a hang, which is the one failure mode a test suite reports worst.
  @Test("an edit inside withObserversCleared re-enters the lock instead of deadlocking")
  @MainActor
  func editInsideTheClearedWindowDoesNotDeadlock() throws {
    let observer = CountingObserver()
    CircuitTransactionObservers.register(observer)
    defer { CircuitTransactionObservers.deregister(ObjectIdentifier(observer)) }

    try CircuitTransactionObservers.withObserversCleared {
      let host = try #require(
        try LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
      let circuit = try #require(host.currentCircuitObject)
      let pin = try Pin.factory.createComponent(
        location: Location.create(100, 100, hasToSnap: false),
        attributes: Pin.factory.createAttributeSet())
      let mutation = host.project.beginMutation(on: circuit)
      mutation.add(pin)
      try host.project.doAction(mutation.toAction("add a pin"))
      #expect(circuit.nonWires.count == 1)
    }

    #expect(observer.calls == 0, "the cleared window must not have delivered")
  }

  // ── The install itself ────────────────────────────────────────────────────────────────────

  /// The seam is filled, and by something that actually reaches the registry.
  ///
  /// Deliberately *not* an `!= nil` assertion; `WireRepairSeamTests`' header records that the
  /// obvious "the seam is non-nil" check was green against exactly the installation worth
  /// rejecting. This drives a real transaction through a real host and asks a registered observer
  /// whether it heard about it.
  @Test("installProcessSeams routes transactionDone into the registry")
  @MainActor
  func theSeamIsInstalledAndReachesTheRegistry() throws {
    let host = try #require(
      try LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
    let circuit = try #require(host.currentCircuitObject)

    let observer = CountingObserver()
    CircuitTransactionObservers.register(observer)
    defer { CircuitTransactionObservers.deregister(ObjectIdentifier(observer)) }

    let pin = try Pin.factory.createComponent(
      location: Location.create(100, 100, hasToSnap: false),
      attributes: Pin.factory.createAttributeSet())
    let mutation = host.project.beginMutation(on: circuit)
    mutation.add(pin)
    try host.project.doAction(mutation.toAction("add a pin"))

    #expect(observer.calls == 1)
  }
}

// MARK: - A result to broadcast

/// A `CircuitTransactionResult` for the tests that only care that a broadcast happened.
///
/// Built by running an empty transaction rather than by faking one: `CircuitTransactionResult`'s
/// only initialiser takes a `CircuitMutatorImpl`, which is `internal`, and a stub that bypassed it
/// would be asserting against a type the product never produces.
private enum FakeResults {
  @MainActor
  static func empty() -> CircuitTransactionResult {
    EmptyTransaction().mutatorOnlyResult()
  }
}

/// A transaction that touches nothing. `accessedCircuits` is empty, so `execute()` acquires no
/// locks, modifies no circuit and produces a result whose `modifiedCircuits` is empty, which is
/// exactly the "this result is not about your circuit" case every observer must tolerate.
private final class EmptyTransaction: CircuitTransaction {
  override var accessedCircuits: [ObjectIdentifier: (circuit: Circuit, access: Access)] { [:] }
  override func run(_ mutator: any CircuitMutator) throws {}

  /// `execute()` also fires the *installed* seam, which would broadcast a second time and throw
  /// the call counts off. The tests here want a result object, not a delivery, so the seam is
  /// parked for the duration.
  @MainActor
  func mutatorOnlyResult() -> CircuitTransactionResult {
    let installed = CircuitTransaction.transactionDone
    CircuitTransaction.transactionDone = nil
    defer { CircuitTransaction.transactionDone = installed }
    // `execute()` cannot throw here: `run` does nothing and there are no circuits to lock.
    return try! execute()
  }
}
