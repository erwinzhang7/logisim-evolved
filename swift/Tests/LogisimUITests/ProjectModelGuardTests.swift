// LogisimUITests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// DO THE TWO EDIT PATHS TAKE THE SAME LOCK?
//
// The app has two ways to mutate the model and until now they disagreed:
//
//   host  →  performOnModel { … }  →  takes SimulationEngine.modelLock
//   tool  →  Project.doAction(…)   →  took nothing at all
//
// The second is reached from inside `mouseReleased`, so routing the live canvas through the tool
// layer, the whole point of `CircuitEditorCanvas`, would have raced the propagation thread.
// Silently, in the shipping app, with no oracle.
//
// ── HOW THIS IS MEASURED, AND THE INSTRUMENT THAT DID NOT WORK ───────────────────────────────
//
// The obvious test is: run an action, and from another thread ask `modelLock.try()` whether the
// lock is held. That test was written, it passed, and it was worthless. Sampling the lock at
// three moments, before `doAction`, inside `doIt`, and after it returned, reported
// `free=false` every time, with the probe thread confirmed to have actually run. **The
// propagation thread holds `modelLock` around every `run`, so it is held nearly always
// regardless of what `doAction` does.** A pass-through guard (`{ body in try body() }`, i.e. the
// exact seam this file is supposed to catch: installed but taking nothing) passed all three
// assertions.
//
// So the instrument here is not "is it held" but "does `doAction` WAIT FOR IT". Another thread
// takes `modelLock` and holds it for a fixed interval; a `doAction` that genuinely acquires the
// lock cannot return before that interval elapses, and one that does not will return in
// microseconds. The discriminator is ~300ms against ~0, and it is one-sided: contention with the
// propagation thread can only make the guarded case wait LONGER, never shorter.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd
import Testing

@testable import LogisimUI

@Suite("Project model guard", .serialized)
struct ProjectModelGuardTests {

  /// How long the foreign thread holds `modelLock`. Long enough to dwarf scheduling noise, short
  /// enough that the suite stays quick.
  private static let holdInterval: TimeInterval = 0.30

  /// Anything below this and `doAction` cannot have waited for the lock.
  private static let threshold: TimeInterval = 0.20

  private final class ProbeAction: Action {
    var ran = false
    override var name: String { "probe" }
    override func doIt(_ project: Project) throws { ran = true }
    override func undo(_ project: Project) throws {}
  }

  @Test("doAction blocks on the engine's lock, so a tool edit cannot race propagation")
  @MainActor
  func doActionWaitsForTheModelLock() throws {
    let host = try #require(
      try LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)

    // Necessary, and nowhere near sufficient: a guard that is installed and takes nothing
    // satisfies this line. The timing assertion below is what actually discriminates.
    #expect(host.project.modelGuard != nil)

    let held = DispatchSemaphore(value: 0)
    let lock = host.engine.modelLock
    let holder = Thread {
      lock.lock()
      held.signal()
      Thread.sleep(forTimeInterval: Self.holdInterval)
      lock.unlock()
    }
    holder.start()
    #expect(held.wait(timeout: .now() + 5) == .success, "holder thread never took the lock")

    let action = ProbeAction()
    let started = Date()
    try host.project.doAction(action)
    let elapsed = Date().timeIntervalSince(started)

    #expect(action.ran)
    #expect(
      elapsed >= Self.threshold,
      """
      doAction returned in \(String(format: "%.3f", elapsed))s while another thread held \
      modelLock, so it did not wait for it — the tool edit path races the propagation thread
      """)
  }

  @Test("the lock is given back, so a following edit does not wait")
  @MainActor
  func lockIsReleasedAfterwards() throws {
    let host = try #require(
      try LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)

    try host.project.doAction(ProbeAction())

    // A missing `defer { unlock() }` shows up here rather than as a hang: the second edit would
    // block on a lock the first never returned, and the propagation thread would be wedged too.
    let started = Date()
    try host.project.doAction(ProbeAction())
    let elapsed = Date().timeIntervalSince(started)

    #expect(
      elapsed < Self.threshold,
      "second doAction took \(String(format: "%.3f", elapsed))s — modelLock was not released")
  }

  @Test("an unguarded Project still performs — headless and the CLI have no propagation thread")
  @MainActor
  func unguardedProjectStillPerforms() throws {
    let file = try LogisimFile.createNew(loader: Loader())
    let project = Project(file: file)
    #expect(project.modelGuard == nil)

    let action = ProbeAction()
    try project.doAction(action)

    // `nil` must mean "run it directly", not "skip it". A guard clause that returned early on the
    // unguarded path would make every headless edit a silent no-op.
    #expect(action.ran)
    #expect(project.canUndo)
  }
}
