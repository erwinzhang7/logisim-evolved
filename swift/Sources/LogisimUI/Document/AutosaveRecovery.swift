// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md at the repository root.
//
// ============================================================================
// OFFERING THE SIDECAR BACK.
//
// An autosave nobody is ever offered is a file that costs disk and saves nothing, so this is
// not optional garnish on `AutosaveController`; it is the half that makes it worth having.
//
// Upstream does it inside the model: `LogisimFile.load(File, Loader)`
// (`LogisimFile.java:217-234`) calls `Loader.findAutosaveFile`, pops an `OptionPane` with
// "load / discard", swaps the file it is about to read, and records `autosaveLoaded` on the
// result. D9 puts the dialog on this side of the line, and `LogisimFile` already has the seam
// for it: `LoaderUI.autosaveDisposition(for:autosave:)`, with an `ignore` answer that
// upstream lacks (see `Loader.swift:37-48`).
//
// **The shell cannot reach that seam.** `LogisimFileProjectHost.openProject` constructs its
// own `Loader()` (`LogisimFileProjectHost.swift:417`), which defaults `ui` to
// `HeadlessLoaderUI` (`Loader.swift:146`), and nothing assigns it. It then opens from `Data`
// via `openLogisimFile(data:)`, which is the overload that has no URL and therefore never
// looks for a sidecar at all. Both facts are recorded as defects in the milestone report;
// neither file is in this slice's ownership. Until they are fixed, the decision is made here,
// before the bytes are handed to the factory, which is a place the shell *does* own.
//
// ── THE PROCESS-GLOBAL, AND ITS `withCleared` ───────────────────────────────────────────────
//
// `prompt` is a seam in the shape this codebase already uses four times over
// (`Buzzer.audioSinkFactory`, `Tty.sendFromTtyHook`, `Tty.textMeasurer`,
// `TelnetServer.transportFactory`): declared here, defaulted to the answer that touches
// nothing, assigned once by the app. `nonisolated(unsafe)` is not decoration; board #75 is
// two seams that went uninstalled for a whole milestone because an actor-isolated `static var`
// cannot be assigned from the app's launch path.
//
// It ships with `withPrompt` and `withCleared` in the same file, both holding a lock across
// clear → body → restore, because four separate incidents on this project came from shared
// state restored less carefully than it was taken. `withCleared` restores the *previous*
// value, not the default: a test that ran after the app installed its AppKit prompt must put
// the AppKit prompt back, not nil.
// ============================================================================

import Foundation
import LogisimFile

public enum AutosaveRecovery {

  /// What the shell decided to open.
  public enum Resolution: Equatable {
    /// Open the bytes that were read from the document itself.
    case original
    /// Open the sidecar's bytes instead. The URL is the sidecar, kept so the caller can mark
    /// the document dirty against it and so the sidecar is not deleted out from under a user
    /// who has not saved yet.
    case recovered(from: URL, bytes: Data)
  }

  /// The four answers, mirroring `LogisimFile.AutosaveDisposition` one for one.
  ///
  /// **Why a mirror rather than the model's own enum.** `AutosaveDisposition` is declared in
  /// `LogisimFile`, which does not build under Swift 6 language mode, so the compiler refuses
  /// to infer `Sendable` for it across the module boundary however trivially payload-free it
  /// is; measured: `error: type 'AutosaveDisposition' does not conform to the 'Sendable'
  /// protocol`, twice, at the seam's storage and at the `MainActor.assumeIsolated` that runs
  /// the alert. The two ways out were `@preconcurrency import`, which downgrades *every*
  /// Sendable error from that module in the importing file including ones that would be real,
  /// and this. `disposition` below is the bridge, kept so that the day
  /// `LogisimFileProjectHost` installs a real `LoaderUI` this seam can answer
  /// `LoaderUI.autosaveDisposition` directly.
  public enum Answer: Sendable, Equatable {
    /// `AutosaveDisposition.load`, open the sidecar's bytes.
    case recover
    /// `AutosaveDisposition.ignore`: open the named file and leave the sidecar alone.
    case openSaved
    /// `AutosaveDisposition.discard`: delete the sidecar, then open the named file.
    case discard
    /// `AutosaveDisposition.cancel`; the dialog was dismissed without an answer.
    case cancel

    public var disposition: AutosaveDisposition {
      switch self {
      case .recover: return .load
      case .openSaved: return .ignore
      case .discard: return .discard
      case .cancel: return .cancel
      }
    }
  }

  public typealias Prompt = @Sendable (_ file: URL, _ autosave: URL) -> Answer

  private static let lock = NSRecursiveLock()
  nonisolated(unsafe) private static var promptStorage: Prompt?

  /// The installed prompt, or nil.
  ///
  /// nil is the correct default and the same one `LoaderUI` chose: with nobody to ask, the
  /// answer is `ignore`; open exactly the bytes that were named, and leave the sidecar alone.
  /// Both of the other answers are destructive (`discard` deletes the user's only copy of the
  /// unsaved work, `load` silently opens different bytes than the file that was double-clicked),
  /// so neither may ever be the default.
  public static var prompt: Prompt? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return promptStorage
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      promptStorage = newValue
    }
  }

  /// Run `body` with `prompt` installed, then restore exactly what was there.
  public static func withPrompt<T>(_ replacement: @escaping Prompt, _ body: () throws -> T)
    rethrows -> T
  {
    lock.lock()
    defer { lock.unlock() }
    let saved = promptStorage
    promptStorage = replacement
    defer { promptStorage = saved }
    return try body()
  }

  /// Run `body` with no prompt installed, then restore exactly what was there.
  public static func withCleared<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    let saved = promptStorage
    promptStorage = nil
    defer { promptStorage = saved }
    return try body()
  }

  // MARK: The decision

  /// Decide what to open for a document at `fileURL`, and carry out the destructive half of the
  /// answer (only `discard` has one).
  ///
  /// `original` is returned for every case that is not an explicit, successful `load`: no URL,
  /// no sidecar, no prompt installed, a cancelled dialog, or a sidecar that cannot be read.
  /// That last one matters; a sidecar truncated by the crash it exists because of must not be
  /// able to take a readable document's place.
  public static func resolve(fileURL: URL?) -> Resolution {
    guard let fileURL else { return .original }
    guard let sidecar = AutosaveSidecar.existingPath(besideFileAt: fileURL) else {
      return .original
    }
    guard isNewer(sidecar, than: fileURL) else { return .original }
    guard let ask = prompt else { return .original }

    switch ask(fileURL, sidecar) {
    case .recover:
      guard let bytes = try? Data(contentsOf: sidecar), !bytes.isEmpty else { return .original }
      return .recovered(from: sidecar, bytes: bytes)
    case .discard:
      AutosaveSidecar.remove(at: sidecar)
      return .original
    case .openSaved, .cancel:
      // Upstream treats a dismissed dialog as abandoning the whole open (`LogisimFile.java:222`
      // returns null and the window never appears). `DocumentGroup` has already created the
      // window by the time this runs and there is no supported way to un-create it, so cancel
      // collapses onto `ignore`: the named file opens, untouched, and the sidecar stays. That
      // is the non-destructive reading of "I did not answer".
      return .original
    }
  }

  /// Is the sidecar newer than the document it sits beside?
  ///
  /// **Upstream does not ask this, and it is a real hazard there.** `Loader.save` deletes the
  /// sidecar only when the save reached it through the loader that wrote it; a sidecar left by
  /// a crashed session, or one whose document was later saved by a different process, outlives
  /// the work it was a copy of. `LogisimFile.load` then offers that stale copy with no
  /// timestamp shown, and "recover" silently replaces newer work with older.
  ///
  /// It matters more here, not less: the shell's save goes through `ReferenceFileDocument`, so
  /// nothing on this side ever reaches `Loader.save` and its trailing `deleteAutosave()` at
  /// all. Without this comparison every saved document would be greeted by a recovery prompt
  /// for a sidecar it had already superseded.
  ///
  /// An unreadable timestamp on either side answers **no**; the prompt is only offered when
  /// there is positive evidence the sidecar is worth something.
  static func isNewer(_ sidecar: URL, than file: URL) -> Bool {
    func modified(_ url: URL) -> Date? {
      try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
    guard let sidecarDate = modified(sidecar), let fileDate = modified(file) else { return false }
    return sidecarDate > fileDate
  }
}
