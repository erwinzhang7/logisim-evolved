// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution, which is GPL-3.0-only. This port is a derivative work and is
// therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// Two defects an adversarial review found in the transaction-delivery install, after it had
// already passed its author's nine red probes and a completeness skeptic.
//
// ── 1. `MainActor.assumeIsolated` in the installed seam ──────────────────────────────────────
//
// The install shipped as `MainActor.assumeIsolated { … }`. `Project.swift:112-117` records that
// the transaction substrate is deliberately NOT `@MainActor` **because upstream takes real
// per-circuit locks there precisely so a transaction can run off the EDT**, and
// `CircuitTransaction.execute()` is a nonisolated method on a nonisolated open class. While the
// slot was nil outside a scoped window an off-main `execute()` was harmless; an assertion there
// makes it fatal.
//
// **Fatal literally, and invisibly.** `assumeIsolated` off the main thread traps the process with
// `EXC_BREAKPOINT` and *no test failure is reported, because the test binary dies with it*: the
// signature `ToolListenerIsolationTests` documents at length, a suite that exists only because
// this same mistake had to be fixed in `PokeTool`, `TextTool` and `EditTool`. This would have
// been the module's fourth instance, with the sanctioned helper (`onMainActor`) 1,450 lines below
// the install in the same file, its comment arguing against exactly this.
//
// It reddened nothing when it landed. Every `execute()` caller in `Sources` today is reached from
// a `@MainActor` type, so there is no live off-main transaction, which is the property that made
// the three `Tools/` instances expensive rather than cheap.
//
// ── 2. `withObserversCleared` replaced instead of restoring ──────────────────────────────────
//
// Its exit was `boxes = saved`, which discards every registration made *inside* the window. A
// `Selection` constructed during the body was permanently deregistered and silently stopped
// receiving transaction results; the very defect the registry exists to prevent, reintroduced by
// its own test helper.

import Foundation
import LogisimFile
import Testing

@testable import LogisimUI

@Suite("Transaction delivery — isolation and restore")
struct TransactionDeliveryIsolationTests {

  /// A minimal observer that records what it was handed.
  @MainActor
  private final class Recorder: CircuitTransactionObserver {
    var count = 0
    func transactionDone(result: CircuitTransactionResult) { count += 1 }
  }

  /// **The process-fatal one.** Runs a transaction off the main thread with the shipping seam
  /// installed. Before the fix this did not fail: it *terminated the test binary* with signal 5,
  /// reporting zero tests and zero failures, and no later suite ran at all.
  ///
  /// Reaching the final assertion is the whole claim. If this file ever stops appearing in the
  /// run, suspect this test rather than assuming it passed.
  @Test("a transaction executed off the main thread does not kill the process")
  @MainActor
  func offMainTransactionDoesNotTrap() async throws {
    LogisimFileProjectHostFactory.installProcessSeams()
    let result = IsolationProbeTransaction().resultWithoutDelivering()

    let done = ThreadFlag()
    let box = UncheckedSendableBox(result)
    let thread = Thread {
      // Deliberately NOT the main thread. The seam fires from wherever `execute()` runs, and
      // `Project.swift:112-117` documents that off-EDT execution is the substrate's design intent.
      CircuitTransaction.transactionDone?(box.value)
      done.signal()
    }
    thread.start()

    #expect(
      done.wait(seconds: 5),
      """
      the off-main delivery never completed. If the process died instead, this assertion was \
      never reached and the suite reported nothing — that is the `assumeIsolated` trap.
      """)
  }

  /// The calibration for the test above: the same call ON the main thread must also work, or the
  /// test would pass against a seam that does nothing at all.
  @Test("the same delivery on the main thread still reaches observers synchronously")
  @MainActor
  func mainThreadDeliveryIsSynchronous() throws {
    LogisimFileProjectHostFactory.installProcessSeams()
    let recorder = Recorder()
    let result = IsolationProbeTransaction().resultWithoutDelivering()
    CircuitTransactionObservers.withObserversCleared {
      CircuitTransactionObservers.register(recorder)
      CircuitTransaction.transactionDone?(result)
      #expect(
        recorder.count == 1,
        """
        the main-thread delivery did not arrive synchronously. A deferred hop lets the canvas \
        paint one frame with the pre-transaction selection, which is the "preview in completely \
        wrong places" symptom this whole change exists to remove.
        """)
    }
  }

  /// **Defect 2.** An observer registered *inside* the cleared window must still be registered
  /// when the window closes. Replacing rather than merging silently unhooks it forever.
  /// **The first version of this test asserted `registeredCount >= 1` and was worthless**: the
  /// outer observer satisfies that on its own, so restoring the replace-not-merge bug reddened
  /// nothing. It now asserts that the inner observer actually *receives a delivery* after its
  /// window closes, which is the property a dropped registration destroys and a count cannot see.
  @Test("an observer registered inside the cleared window still receives deliveries after it")
  @MainActor
  func registrationsInsideTheWindowSurvive() throws {
    LogisimFileProjectHostFactory.installProcessSeams()
    let result = IsolationProbeTransaction().resultWithoutDelivering()
    let outer = Recorder()
    let inner = Recorder()

    CircuitTransactionObservers.withObserversCleared {
      CircuitTransactionObservers.register(outer)
      CircuitTransactionObservers.withObserversCleared {
        CircuitTransactionObservers.register(inner)
      }

      // Both must be live here: `outer` was registered before the inner window and must be
      // restored; `inner` was registered inside it and must not be discarded by the restore.
      CircuitTransaction.transactionDone?(result)
      #expect(
        outer.count == 1,
        "the inner window's restore dropped an observer registered BEFORE it — the saved set")
      #expect(
        inner.count == 1,
        """
        the observer registered INSIDE the inner window never received a delivery after it \
        closed: the restore replaced the registry instead of merging, so it was silently \
        unhooked forever.
        """)
    }
  }

  /// The other half of the restore contract, so the merge above cannot be "fixed" by never
  /// clearing at all: inside the window, the previously-registered observers must NOT fire.
  @Test("the cleared window really is empty while it is open")
  @MainActor
  func theWindowIsActuallyCleared() throws {
    LogisimFileProjectHostFactory.installProcessSeams()
    let before = Recorder()
    let result = IsolationProbeTransaction().resultWithoutDelivering()
    CircuitTransactionObservers.register(before)

    CircuitTransactionObservers.withObserversCleared {
      CircuitTransaction.transactionDone?(result)
      #expect(before.count == 0, "an observer fired inside a window that claims to be cleared")
    }
  }
}

// MARK: - Support

/// A transaction that touches nothing, so `execute()` takes no locks and modifies no circuit.
/// Same idiom as `CircuitTransactionObserverTests`' `EmptyTransaction`: deliberately not shared,
/// because a helper both suites depend on is a helper that can be "fixed" for one and break the
/// other silently.
private final class IsolationProbeTransaction: CircuitTransaction {
  override var accessedCircuits: [ObjectIdentifier: (circuit: Circuit, access: Access)] { [:] }
  override func run(_ mutator: any CircuitMutator) throws {}

  /// `execute()` also fires the installed seam, which would deliver once before these tests get
  /// to choose where the delivery happens. Parked for the duration.
  @MainActor
  func resultWithoutDelivering() -> CircuitTransactionResult {
    let installed = CircuitTransaction.transactionDone
    CircuitTransaction.transactionDone = nil
    defer { CircuitTransaction.transactionDone = installed }
    return try! execute()
  }
}

/// A tiny cross-thread flag, rather than pulling in XCTest expectations.
private final class ThreadFlag: @unchecked Sendable {
  private let semaphore = DispatchSemaphore(value: 0)
  func signal() { semaphore.signal() }
  func wait(seconds: Int) -> Bool { semaphore.wait(timeout: .now() + .seconds(seconds)) == .success }
}
