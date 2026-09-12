// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md at the repository root.
//
// ============================================================================
// THE AUTOSAVE TIMER; the half `LogisimFile` deliberately did not port.
//
// `Sources/LogisimFile/LogisimFile.swift:11-15` says it plainly: upstream's `AutosaveThread`
// starts a background thread per open file that calls `loader.autosave(file)` on a timer,
// unsynchronised with the EDT, which is a data race on the model in Java too. The *state* it
// drives, `isAutosaveDirty`, `autosaveLoaded`, `stopAutosaveThread(delete:)`, was ported
// exactly, "and owning the timer is the app shell's [job]".
//
// Nothing owned it. Measured before this file existed:
//   * `autosaveIfDirty`, `stopAutosaveThread`, `isAutosaveDirty`, `deleteAutosave` and
//     `setAutosavePath` had **zero** callers outside `Sources/LogisimFile/` and one assertion
//     in `Tests/LogisimFileTests/FileModelTests.swift`.
//   * `EditorPreferences.autosaveEnabled` and `.autosaveIntervalSeconds` had **zero** readers
//     anywhere; the only mentions were their own declarations, their persistence, and the two
//     controls in `SettingsWindow.swift:58-66`.
// So the Settings window offered "Save automatically", with an interval picker, over nothing
// at all. This is the object that makes that true.
//
// WHY NOT `LogisimFile.autosaveIfDirty()`, which is right there and already tested?
// Because it aims through `Loader.autosave`, which aims through the loader's `mainFileURL`,
// which `LogisimUI` cannot set; see the header of `AutosaveSidecar.swift`. Calling it would
// scatter timestamped sidecars through the user's home directory instead of putting one
// beside each document. The loop body here is the same body with the target supplied by the
// shell, which is the only object that knows a document's URL.
//
// THREADING. This is `@MainActor`, and the serialize step takes `SimulationEngine.modelLock`
// exactly as `LogisimFileProjectHost.performOnModel` does (`LogisimFileProjectHost.swift:982`),
// so an autosave cannot interleave with a propagation-thread mutation. That is strictly better
// than upstream, whose autosave thread reads the model with no lock at all.
//
// NO PROCESS-GLOBAL STATE. One controller per document, owned by the document. The only
// global in this slice is `AutosaveRecovery.prompt`, which ships with its `withPrompt` /
// `withCleared` pair in the same file it is declared in.
// ============================================================================

import Foundation

@MainActor
public final class AutosaveController {

  /// Everything the loop needs from a document, as closures rather than a protocol: the two
  /// things it reads live on types this slice does not own (`LogisimFileProjectHost.file`,
  /// `EditorPreferences`), and a closure pair is the join that neither file has to know about.
  public struct Subject {
    /// The document's URL *now*; not the one it was opened with. A Save As moves the sidecar,
    /// and `ProjectHost.fileURL` is `private(set)` and assigned only in `init`, so it is the
    /// wrong source. `CircuitDocument.currentURL`, which the scene keeps fresh, is the right one.
    public var baseURL: () -> URL?
    /// `LogisimFile.isAutosaveDirty`.
    public var isDirty: () -> Bool
    /// Serialize for the given destination. The destination matters: `XmlWriter` relativises
    /// library descriptors against it, which is what Java's `file.write(fwrite, this,
    /// autosaveFile, null)` does in `Loader.autosave`.
    public var bytes: (URL) -> Data?

    public init(
      baseURL: @escaping () -> URL?,
      isDirty: @escaping () -> Bool,
      bytes: @escaping (URL) -> Data?
    ) {
      self.baseURL = baseURL
      self.isDirty = isDirty
      self.bytes = bytes
    }
  }

  public enum Outcome: Equatable, CustomStringConvertible {
    /// The preference is off. Upstream decides this once, when the `LogisimFile` is
    /// constructed, and never revisits it; here it is re-read every tick, so toggling the
    /// preference takes effect on the next interval instead of on the next app launch.
    case disabled
    /// Nothing has changed since the last real save.
    case notDirty
    /// Dirty, but the bytes are identical to the ones already in the sidecar.
    case unchanged
    case wrote(URL)
    /// No target could be computed. Only reachable in the untitled case, when the timestamped
    /// name in the home directory is already taken; upstream returns false here too.
    case noTarget
    /// The serializer returned nil. `LogisimFile.write` has already reported through
    /// `LoaderUI.showError` by the time this is seen.
    case couldNotSerialize
    case failed(String)
    /// A previous tick failed. Upstream sets `run = false` and the thread exits; the same
    /// latch is here, and `resume()` is the only way out of it.
    case stopped

    public var description: String {
      switch self {
      case .disabled: return "disabled"
      case .notDirty: return "notDirty"
      case .unchanged: return "unchanged"
      case .wrote(let url): return "wrote(\(url.lastPathComponent))"
      case .noTarget: return "noTarget"
      case .couldNotSerialize: return "couldNotSerialize"
      case .failed(let why): return "failed(\(why))"
      case .stopped: return "stopped"
      }
    }
  }

  // MARK: Configuration

  private let subject: Subject
  private let isEnabled: () -> Bool
  private let intervalSeconds: () -> Double
  private let report: (String) -> Void

  /// Upstream sleeps `AUTOSAVE_INTERVAL` seconds, and `PrefMonitorInt` will happily hand back
  /// zero or a negative if the stored value is junk, which turns the loop into a spin. One
  /// second is the floor here; there is no ceiling, because a long interval is only a weak
  /// autosave, not a broken one.
  static let minimumIntervalSeconds: Double = 1

  // MARK: State

  /// The sidecar currently on disk, so a Save As can delete the old one: Java's
  /// `if (oldAutosave != null && !oldAutosave.equals(autosaveFile)) oldAutosave.delete()`.
  public private(set) var currentSidecar: URL?
  /// Digest of the last bytes written, so a document that is dirty but unchanged (the user
  /// edited once and then went to lunch) does not rewrite the same bytes every interval.
  ///
  /// CORRECTED, board #89. This used to say "there is no public way to clear
  /// `LogisimFile.isAutosaveDirty` from outside `LogisimFile`". There is:
  /// `LogisimFile.setDirty(_:)` is public and clears `autosaveDirtyFlag` alongside `dirtyFlag`
  /// , the deliberate asymmetry at `LogisimFile.swift:645-651`, and `Project.setFileAsClean()`
  /// reaches it. `SaveDirtyFlagTests.confirmedSaveClearsAutosaveDirty` pins that path.
  ///
  /// The digest stays, because it is not a substitute for the flag and never was. It answers a
  /// different question: the flag says "the model changed since the last *save*", while this
  /// says "the bytes differ from what is already in the *sidecar*". A document saved, edited
  /// and edited back to identical bytes is dirty by the flag and pointless to rewrite by the
  /// digest, and only the digest can tell.
  private var lastWrittenDigest: Int?
  private var stopped = false
  private var loop: Task<Void, Never>?

  public private(set) var tickCount = 0
  public private(set) var lastOutcome: Outcome?
  public private(set) var writeCount = 0

  public init(
    subject: Subject,
    isEnabled: @escaping () -> Bool,
    intervalSeconds: @escaping () -> Double,
    report: @escaping (String) -> Void = { _ in }
  ) {
    self.subject = subject
    self.isEnabled = isEnabled
    self.intervalSeconds = intervalSeconds
    self.report = report
  }

  // MARK: The loop body

  /// One iteration of `AutosaveThread.run()`, with no sleeping in it.
  ///
  /// Kept separate from the timer on purpose: a test that has to wait a real interval to learn
  /// anything is a test that will be deleted the first time it flakes. Every behaviour in this
  /// object is reachable by calling `tick()` directly.
  @discardableResult
  public func tick() -> Outcome {
    tickCount += 1
    let outcome = body()
    lastOutcome = outcome
    return outcome
  }

  private func body() -> Outcome {
    if stopped { return .stopped }
    guard isEnabled() else { return .disabled }
    guard subject.isDirty() else { return .notDirty }

    guard let target = AutosaveSidecar.path(besideFileAt: subject.baseURL()) else {
      return .noTarget
    }
    guard let data = subject.bytes(target) else { return .couldNotSerialize }

    // The digest gate is deliberately *after* serialization, not before: there is nothing
    // cheaper than the bytes themselves to compare, and the alternative, trusting a dirty flag
    // this module cannot clear, rewrites the same file forever.
    var digest = Hasher()
    digest.combine(data)
    digest.combine(target.path)
    let fingerprint = digest.finalize()
    if fingerprint == lastWrittenDigest, FileManager.default.fileExists(atPath: target.path) {
      return .unchanged
    }

    do {
      try AutosaveSidecar.write(data, to: target)
    } catch {
      // Upstream: `file.loader.showError(S.get("autosaveError", file.name)); run = false`.
      // One report, then silence for the session; an autosave that cannot write is almost
      // always a permission or a full disk, and neither is fixed by asking again in 30 seconds.
      stopped = true
      let detail = String(describing: error)
      report(detail)
      return .failed(detail)
    }

    if let previous = currentSidecar, previous.path != target.path {
      AutosaveSidecar.remove(at: previous)
    }
    currentSidecar = target
    lastWrittenDigest = fingerprint
    writeCount += 1
    return .wrote(target)
  }

  // MARK: The timer

  /// Start ticking. Idempotent; a second call while running is ignored, so a view that
  /// re-appears does not end up with two loops on one document.
  public func start() {
    guard loop == nil else { return }
    loop = Task { [weak self] in
      while !Task.isCancelled {
        guard let interval = self?.sleepInterval() else { return }
        try? await Task.sleep(for: .seconds(interval))
        if Task.isCancelled { return }
        guard let self else { return }
        self.tick()
      }
    }
  }

  private func sleepInterval() -> Double {
    max(Self.minimumIntervalSeconds, intervalSeconds())
  }

  /// Java `AutosaveThread.abort(boolean delete)`.
  ///
  /// `delete: true` is the "the document was saved or closed cleanly, there is nothing to
  /// recover" case; `false` is "the app is going away with unsaved work", which is exactly
  /// when the sidecar has to survive. Java joins the thread before deleting so a straggling
  /// write cannot resurrect the file; the same ordering holds here because `stop` cancels the
  /// loop and *then* deletes, and both run on the main actor, where `tick()` also runs.
  public func stop(deleteSidecar: Bool) {
    loop?.cancel()
    loop = nil
    guard deleteSidecar else { return }
    if let current = currentSidecar {
      AutosaveSidecar.remove(at: current)
      currentSidecar = nil
      lastWrittenDigest = nil
    }
    // Cover the case where this controller never wrote but a sidecar from a previous session
    // is still sitting beside the file: upstream's `deleteAutosave` only knows the path it
    // last wrote, which is why a stale sidecar there outlives the save that made it obsolete.
    if let base = subject.baseURL(), let stale = AutosaveSidecar.existingPath(besideFileAt: base) {
      AutosaveSidecar.remove(at: stale)
    }
  }

  /// Clear the failure latch. Upstream has no counterpart; its thread has exited by now and
  /// nothing restarts it, so an autosave failure is permanent until the app is relaunched.
  /// This exists so that "the volume was ejected, the user reconnected it" is recoverable, and
  /// so a test can assert the latch is a latch rather than a coincidence.
  public func resume() {
    stopped = false
  }

  public var isStopped: Bool { stopped }
  public var isRunning: Bool { loop != nil }
}
