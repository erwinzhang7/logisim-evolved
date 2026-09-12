// ConnectorThread.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.tools.move.ConnectorThread),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Why this stays a real background thread ─────────────────────────────────────────────────
//
// The obvious "modernisation" is to make `computeWires` an `async` function on a task. It is the
// wrong move for the same reason D1 keeps the simulation kernel off Swift Concurrency: the
// structure is not incidental, it is the feature. A reroute is a bounded-but-slow A* over the
// whole circuit, run **once per pixel of drag**, and it is deliberately *interruptible*; a newer
// request sets `overrideRequest`, and the running search notices within 64 expansions and
// abandons itself. Making it synchronous stalls the canvas on every large circuit, which is
// precisely what M7's brief rules out.
//
// One thread, one pending request, latest-wins. There is no queue: a drag generates results far
// faster than they can be consumed, so anything but the newest position is already stale.
//
// ── Threading contract for the whole `Move/` directory ──────────────────────────────────────
//
//   * `MoveGesture` is created on the main actor and snapshots the circuit there. Nothing below
//     this line ever touches a live `Circuit`.
//   * `Connector`, `AvoidanceMap`, `SearchNode` and `ReplacementMap` run entirely on this thread.
//   * `MoveGesture.notifyResult` publishes under the gesture's `NSCondition`; the main actor
//     reads results through `findResult`/`forceRequest` under the same condition.
//   * `isOverrideRequested` is read from inside the search loop, which already holds the
//     gesture's lock at times. It therefore uses its own leaf lock and never takes any other;
//     the alternative (reusing the queue lock) is an ABBA deadlock against `forceRequest`, which
//     takes the queue lock and *then* the gesture lock.

import Foundation

/// `com.cburch.logisim.tools.move.ConnectorThread`.
final class ConnectorThread: Thread, @unchecked Sendable {

  private static let instance = ConnectorThread()

  /// Guards the pending/processing request pair. Held only for the handful of statements
  /// upstream's `synchronized (lock)` blocks cover.
  private let queueCondition = NSCondition()
  private var nextRequest: MoveRequest?
  private var processingRequest: MoveRequest?

  /// A leaf lock, taken while holding `queueCondition` but never the other way round, and never
  /// while holding a gesture's lock. See the header.
  private let overrideLock = NSLock()
  private var overrideRequestFlag = false

  private static let startLock = NSLock()
  /// `nonisolated(unsafe)` because the safety is `startLock`, which the compiler cannot see. This
  /// is the same bargain D1 strikes for the whole kernel: Foundation's locks, used the way the
  /// Java uses `synchronized`.
  private nonisolated(unsafe) static var didStart = false

  private override init() {
    super.init()
    name = "tools-move-ConnectorThread"
    // Upstream inherits the EDT's priority by default; a reroute is strictly best-effort work
    // behind a live drag, so it yields to the UI here.
    qualityOfService = .userInitiated
  }

  /// Java starts the singleton from a static initialiser. Swift has no equivalent hook that is
  /// guaranteed to run, so the thread starts on first use, which is the first drag with
  /// reconnection enabled, and never at all in a headless process.
  private static func startIfNeeded() {
    startLock.lock()
    defer { startLock.unlock() }
    guard !didStart else { return }
    didStart = true
    instance.start()
  }

  /// `enqueueRequest(MoveRequest, boolean)`.
  ///
  /// The `!= processingRequest` guard is upstream's and matters: re-enqueuing the request that is
  /// already running would abandon a search that is about to answer the very question being
  /// asked.
  static func enqueue(_ request: MoveRequest, priority: Bool) {
    startIfNeeded()
    let thread = instance
    thread.queueCondition.lock()
    if request != thread.processingRequest {
      thread.nextRequest = request
      thread.setOverrideRequested(priority)
      thread.queueCondition.broadcast()
    }
    thread.queueCondition.unlock()
  }

  /// `isOverrideRequested()`.
  static var isOverrideRequested: Bool {
    instance.overrideRequested
  }

  private var overrideRequested: Bool {
    overrideLock.lock()
    defer { overrideLock.unlock() }
    return overrideRequestFlag
  }

  private func setOverrideRequested(_ value: Bool) {
    overrideLock.lock()
    overrideRequestFlag = value
    overrideLock.unlock()
  }

  /// `run()`.
  ///
  /// Upstream catches `Exception`, prints the stack trace, and, **only if the failed request was
  /// a priority one**, publishes an empty result so that the EDT blocked in
  /// `MoveGesture.forceRequest` is released (`ConnectorThread.java:81-88`). A non-priority failure
  /// publishes nothing, because nobody is waiting. That asymmetry is deliberate and is preserved.
  ///
  /// Swift has no catchable equivalent of an arbitrary runtime exception, so the port does not
  /// manufacture one: the engine's ordinary failure modes are `nil` returns (aborted search, no
  /// route), which `computeWires` already reports. It does have **one** real throw,
  /// `ReplacementMap`'s frozen check, which `Connector.processPath` can reach, and that is what
  /// the `catch` below is for. The asymmetry is upstream's and is preserved exactly: a failed
  /// **priority** request publishes an empty result so the EDT blocked in
  /// `MoveGesture.forceRequest` is released, and a failed background request publishes nothing,
  /// because nobody is waiting on it.
  ///
  /// `MoveGesture.forceRequest` also carries its own deadline, which upstream lacks, so a wait
  /// cannot outlive a thread that stops answering even if this path is somehow missed.
  override func main() {
    while true {
      let request: MoveRequest
      queueCondition.lock()
      processingRequest = nil
      while nextRequest == nil {
        queueCondition.wait()
      }
      request = nextRequest!
      // `wasOverride`; read *before* the flag is cleared, which is upstream's ordering and the
      // only reason the catch below can tell a priority request from a background one
      // (`ConnectorThread.java:69-71`).
      let wasOverride = overrideRequested
      nextRequest = nil
      setOverrideRequested(false)
      processingRequest = request
      queueCondition.unlock()

      do {
        if let result = try Connector.computeWires(request) {
          request.gesture.notifyResult(request, result)
        }
      } catch {
        // `ConnectorThread.java:81-88`. A background failure publishes nothing, nobody is
        // waiting, and a priority failure publishes an empty result so the main actor blocked in
        // `MoveGesture.forceRequest` is released. The drag then commits without a reroute and the
        // canvas marks every connection as unsatisfied, which is upstream's behaviour and is the
        // same answer `forceRequest`'s own deadline produces if this is ever missed.
        guard wasOverride else { continue }
        let gesture = request.gesture
        let empty = MoveResult(
          replacements: ReplacementMap(),
          unsatisfiedConnections: gesture.connections(),
          totalDistance: 0)
        gesture.notifyResult(request, empty)
      }
    }
  }
}
