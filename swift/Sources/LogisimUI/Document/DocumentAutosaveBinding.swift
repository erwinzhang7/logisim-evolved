// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md at the repository root.
//
// ============================================================================
// THE JOIN, AND THE ONE DIALOG.
//
// `AutosaveController` reads three closures and `AutosaveRecovery` reads one; this file is
// where they meet the real project and the real AppKit. Kept apart from both so that the loop
// and the path rule stay testable without a host and without a screen.
// ============================================================================

import AppKit
import Foundation
import LogisimFile

extension AutosaveController.Subject {

  /// Bind the loop to a live project.
  ///
  /// ── WHY NOT `ProjectHost.serialize()` ─────────────────────────────────────────────────────
  ///
  /// It used not to be a pure read: `serialize()` ended with `project.setFileAsClean()`, so
  /// autosaving through it would have told the user their unsaved work was saved; the edited
  /// state would clear, the close prompt would stop appearing, and the next real save would
  /// think there was nothing to write. That was board #89 and it is now fixed: `serialize()`
  /// records a pending save and the flag moves only in `confirmSaveSucceeded()`.
  ///
  /// **This binding still does not use it, and the reason has changed rather than gone away.**
  /// `serialize()` now has a side effect of a different kind, it arms the pending save that
  /// `CircuitDocument` is waiting to confirm, so an autosave tick calling it would overwrite
  /// the fingerprint the user's real ⌘S is being judged against, and the sidecar's bytes would
  /// be confirmed as though they were the document's. Going straight to `LogisimFile.write`
  /// keeps the two writers independent, which is what the destination-relative library paths
  /// below need anyway.
  ///
  /// ── WHY THE LOCK ──────────────────────────────────────────────────────────────────────────
  ///
  /// `SimulationEngine.modelLock` is what `LogisimFileProjectHost.performOnModel` takes
  /// (`LogisimFileProjectHost.swift:982`), and it is the lock the propagation thread holds
  /// while mutating. Serializing without it is upstream's actual bug: its `AutosaveThread`
  /// walks the model concurrently with the EDT. `performOnModel` is `private`, so the same lock
  /// is taken directly here; it is an `NSRecursiveLock`, so nesting inside a call that already
  /// holds it is safe.
  ///
  /// The host is held weakly: the controller is owned by the document and the document outlives
  /// nothing in particular, so a strong capture here would be a retain cycle through the scene.
  @MainActor
  public static func project(
    host: @escaping () -> (any ProjectHost)?,
    url: @escaping () -> URL?
  ) -> AutosaveController.Subject {
    AutosaveController.Subject(
      baseURL: url,
      isDirty: {
        guard let concrete = host() as? LogisimFileProjectHost else {
          // A non-`LogisimFile` host (there is none today, but the seam allows one) has no
          // autosave-dirty flag to read. Reporting "not dirty" makes the loop a no-op for it
          // rather than making it write on every tick.
          return false
        }
        return concrete.file.isAutosaveDirty
      },
      bytes: { destination in
        guard let concrete = host() as? LogisimFileProjectHost else { return nil }
        concrete.engine.modelLock.lock()
        defer { concrete.engine.modelLock.unlock() }
        return concrete.file.write(loader: concrete.file.loader, destination: destination)
      })
  }
}

// MARK: - The AppKit prompt

public enum AutosaveRecoveryAlert {

  /// The dialog upstream shows from inside `LogisimFile.load`, moved to this side of D9.
  ///
  /// Three answers, in the order macOS wants them: the safe default first, the destructive one
  /// last and marked so. Upstream offers only "load" and "discard" and treats the close box as
  /// abandoning the open; `ignore` is the port's addition and is what the close box maps to
  /// here, because a window has already been created by the time this runs.
  ///
  /// `assumeIsolated`: `AutosaveRecovery.resolve` is called from `CircuitDocument.attachedHost`,
  /// which is `@MainActor`. The seam's type is a bare `@Sendable` closure because it has to be
  /// assignable from anywhere, so the isolation is asserted here rather than declared, and it
  /// is checked at runtime in debug builds, which is the point of using `assumeIsolated` over a
  /// comment.
  public static let prompt: AutosaveRecovery.Prompt = { file, autosave in
    MainActor.assumeIsolated { ask(file: file, autosave: autosave) }
  }

  @MainActor
  static func ask(file: URL, autosave: URL) -> AutosaveRecovery.Answer {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Recover unsaved changes to “\(file.lastPathComponent)”?"
    alert.informativeText =
      "Logisim saved a copy of this circuit that is newer than the version on disk — usually "
      + "because it quit unexpectedly.\n\nRecovered: \(modifiedDescription(of: autosave))"
      + "\nOn disk: \(modifiedDescription(of: file))"
    alert.addButton(withTitle: "Recover")
    alert.addButton(withTitle: "Open Saved Version")
    alert.addButton(withTitle: "Discard Recovered Copy")
    alert.buttons.last?.hasDestructiveAction = true

    switch alert.runModal() {
    case .alertFirstButtonReturn: return .recover
    case .alertSecondButtonReturn: return .openSaved
    case .alertThirdButtonReturn: return .discard
    default: return .cancel
    }
  }

  static func modifiedDescription(of url: URL) -> String {
    guard
      let date = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate
    else { return "unknown" }
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }
}
