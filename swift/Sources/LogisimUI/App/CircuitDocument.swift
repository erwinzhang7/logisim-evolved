// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ============================================================================
// THE DOCUMENT.
//
// The shell owns no file format. It moves `Data` between the system's document
// machinery and `ProjectHostFactory`, which the codec team implements. That is the whole
// of it; this file has no XML in it and never will.
//
// Using `DocumentGroup` rather than a hand-rolled window controller buys, for free, every
// piece of Mac document behaviour upstream reimplements badly or not at all: Open Recent
// (upstream hand-maintains `OpenRecent.java` with its own preference list), autosave and
// versions, iCloud/Files placement, proxy-icon drag, "Move To…", rename in the title bar,
// duplicate, revert, and the untitled-window-on-launch policy. Upstream's `MenuFile` has
// to build all of that itself, and its close/quit path is a `WindowAdapter` on
// `DO_NOTHING_ON_CLOSE` that pops its own "save changes?" dialogue (`Frame.java:118-119`).
//
// Threading note. `ReferenceFileDocument` splits saving in two on purpose:
// `snapshot(contentType:)` runs on the main thread while the model is quiescent, and
// `fileWrapper(snapshot:configuration:)` runs off it. That maps exactly onto the seam,
// `ProjectHost` is `@MainActor`, `Data` is `Sendable`, so the snapshot is where we cross
// and nothing else has to.
// ============================================================================

import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

public final class CircuitDocument: ReferenceFileDocument, @unchecked Sendable {

  public typealias Snapshot = Data

  /// Bytes as they were read. Held only until a `ProjectHost` is attached; after that the
  /// host is the truth. Immutable, so the nonisolated protocol requirements can touch it.
  public let loadedData: Data?
  public let loadedContentType: UTType?

  /// The live project. `@MainActor` on the stored property is what lets this class stay
  /// `Sendable` while still owning a main-actor-isolated model: the isolation is on the
  /// property, so no cross-actor access can be written by accident.
  @MainActor public var host: (any ProjectHost)?

  /// The document's URL as the scene currently knows it, kept fresh by `DocumentRoot`.
  ///
  /// `ProjectHost.fileURL` is `private(set)` and assigned once in `init`, so it is stale from
  /// the first Save As onward; `DocumentGroup` hands the live one to the scene on every body
  /// evaluation. The autosave sidecar has to follow the file, so it reads this.
  @MainActor public var currentURL: URL?

  /// Non-nil once `startAutosaving` has run. One per document, matching upstream's one
  /// `AutosaveThread` per `LogisimFile`.
  @MainActor public private(set) var autosave: AutosaveController?

  /// Set when the bytes actually opened came from a recovered sidecar rather than from the
  /// file itself, so the caller can say so and can decline to delete the sidecar until the
  /// user has really saved.
  @MainActor public private(set) var recoveredFrom: URL?

  public init() {
    loadedData = nil
    loadedContentType = nil
  }

  public init(configuration: ReadConfiguration) throws {
    loadedData = configuration.file.regularFileContents
    loadedContentType = configuration.contentType
  }

  public static var readableContentTypes: [UTType] { LogisimDocumentType.readable }
  public static var writableContentTypes: [UTType] { [LogisimDocumentType.circuit] }

  /// Bind a host to this document, creating one from the loaded bytes on first use.
  ///
  /// `fileURL` is new and load-bearing twice over. It is what lets the sidecar from an
  /// interrupted session be offered back before the bytes are committed to a host, the last
  /// point at which a *different* set of bytes can still be opened, and it is what the
  /// autosave loop aims at afterwards. It defaults to nil so that the untitled path and every
  /// existing caller keep working unchanged.
  @MainActor
  public func attachedHost(fileURL: URL? = nil) throws -> any ProjectHost {
    if let host { return host }
    currentURL = fileURL ?? currentURL
    let factory = ProjectHostFactoryRegistry.shared.factory
    let made: any ProjectHost
    if let loadedData {
      var bytes = loadedData
      if case let .recovered(sidecar, recoveredBytes) = AutosaveRecovery.resolve(
        fileURL: currentURL)
      {
        bytes = recoveredBytes
        recoveredFrom = sidecar
      }
      // `url:` stays nil: it is threaded straight into `LogisimFileProjectHost.fileURL` and
      // nothing else, and passing the *recovered* document's URL there would be a lie. The
      // loader-side use of a URL, `setMainFile`, which is what makes library descriptors
      // relative, is not reachable from this module at all; see the milestone report.
      made = try factory.openProject(
        data: bytes, url: nil, contentType: loadedContentType ?? LogisimDocumentType.circuit)
    } else {
      made = try factory.makeEmptyProject()
    }
    host = made
    return made
  }

  /// Start this document's autosave loop. Idempotent.
  ///
  /// Upstream starts the thread in `LogisimFile`'s constructor, gated on
  /// `AppPreferences.AUTOSAVE_ENABLED` read once and never again. Here the loop always exists
  /// and re-reads the preference every tick, so turning "Save automatically" on in Settings
  /// takes effect on the next interval rather than on the next launch, and D9 keeps the
  /// preference out of the model, where upstream reads it.
  @MainActor
  public func startAutosaving(preferences: EditorPreferences) {
    guard autosave == nil else { return }
    let controller = AutosaveController(
      subject: .project(host: { [weak self] in self?.host }, url: { [weak self] in
        self?.currentURL
      }),
      isEnabled: { preferences.autosaveEnabled },
      intervalSeconds: { preferences.autosaveIntervalSeconds })
    autosave = controller
    controller.start()
  }

  /// Stop the loop.
  ///
  /// `deleteSidecar` is Java's `stopAutosaveThread(boolean delete)` argument and the two call
  /// sites are not interchangeable: a document closing with no unsaved work has nothing to
  /// recover and should leave nothing behind, while one closing *with* unsaved work is the
  /// only case the sidecar exists for. A document opened from a recovered sidecar and not yet
  /// saved keeps it too, for the same reason.
  @MainActor
  public func stopAutosaving(deleteSidecar: Bool) {
    autosave?.stop(deleteSidecar: deleteSidecar && recoveredFrom == nil)
    autosave = nil
  }

  public func snapshot(contentType: UTType) throws -> Data {
    // Documented to run on the main thread with the model quiescent; that is precisely
    // the contract `assumeIsolated` is for, and it is checked at runtime in debug.
    try MainActor.assumeIsolated {
      let data: Data
      if let host { data = try host.serialize() } else { data = loadedData ?? Data() }
      // Board #89. This used to be the moment the document went clean, because `serialize()`
      // ended with `setFileAsClean()`. It is now the moment a save becomes *pending*: the bytes
      // exist, nothing has stored them, and the dirty flag does not move until something has
      // seen them at the destination. See `Document/SaveConfirmation.swift`.
      pendingFingerprint = SaveVerification.fingerprint(data)
      if confirmsSavesAutomatically { startConfirmationPoll() }
      return data
    }
  }

  /// Whether producing a snapshot also starts watching for it to land.
  ///
  /// On in the app, because `snapshot(contentType:)` is the only place the shell is told a save
  /// is happening at all; the system calls it, and nothing calls the shell. Off in tests that
  /// want to drive `reconcileSaveState()` by hand and assert on the exact moment the flag moves.
  @MainActor public var confirmsSavesAutomatically = true

  /// Called on the main actor when a pending save resolves: `true` when the bytes were found at
  /// the destination, `false` when they never turned up. This is the only honest input to a
  /// "Saved" confirmation, because it is the only one that has read the file back.
  @MainActor public var onSaveResolved: ((Bool) -> Void)?

  @MainActor private var confirmationTask: Task<Void, Never>?

  @MainActor
  private func startConfirmationPoll() {
    confirmationTask?.cancel()
    confirmationTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let confirmed = await self.confirmSaveWhenWritten()
      self.onSaveResolved?(confirmed)
    }
  }

  public func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws
    -> FileWrapper
  {
    FileWrapper(regularFileWithContents: snapshot)
  }

  // MARK: - Confirming the write (board #89)

  /// Fingerprint of the bytes handed to the document machinery and not yet found on disk.
  @MainActor private var pendingFingerprint: Int?

  /// Non-nil once a save has been confirmed, and the thing a "Saved" confirmation is drawn
  /// from. Never set by producing bytes: only by finding them at the destination.
  @MainActor public private(set) var lastConfirmedSave: Date?

  @MainActor public var hasPendingSave: Bool { pendingFingerprint != nil }

  /// Look for the pending save's bytes at the document's current URL and, if they are there,
  /// clear the dirty flag.
  ///
  /// Idempotent and cheap to call speculatively: with no pending save it does nothing, and it
  /// only ever moves the flag from dirty to clean when it has read the bytes back. The one
  /// direction it will not go is the dangerous one.
  @discardableResult
  @MainActor
  public func reconcileSaveState() -> Bool {
    guard let expected = pendingFingerprint else { return false }
    guard SaveVerification.bytesReached(currentURL, fingerprint: expected) else { return false }
    pendingFingerprint = nil
    lastConfirmedSave = Date()
    (host as? any SaveConfirming)?.confirmSaveSucceeded()
    return true
  }

  /// Give up on the pending save, leaving the document dirty.
  ///
  /// The `ifeq 42` arm of upstream's `ProjectActions.doSave`. Called when the poll below has
  /// run out of attempts, and directly by a caller that already knows the write threw.
  @MainActor
  public func abandonPendingSave() {
    guard pendingFingerprint != nil else { return }
    pendingFingerprint = nil
    (host as? any SaveConfirming)?.confirmSaveFailed()
  }

  /// Watch for the pending save to land, then stop.
  ///
  /// A poll, and it is a poll for a reason worth stating rather than apologising for.
  /// `ReferenceFileDocument` has exactly two save-side members and both run *before* the
  /// bytes reach the disk (SDK, not memory: `SwiftUI.swiftinterface:7572-7573`), and
  /// `ReferenceFileDocumentConfiguration` exposes only `document`, `fileURL` and `isEditable`
  /// (ibid. :7594-7611). There is no `didSave` to subscribe to, so the shell either polls for
  /// the evidence or trusts a claim nobody checked, and trusting the claim is the defect this
  /// is fixing.
  ///
  /// The schedule is bounded and front-loaded because the write is already in flight when this
  /// starts; the later attempts exist for a slow or networked volume. Running out of attempts
  /// is not treated as proof of failure; `abandonPendingSave` only drops the pending save, and
  /// the document stays dirty either way, so the worst outcome is one redundant ⌘S.
  public static let confirmationDelaysMilliseconds: [Int] = [0, 30, 100, 250, 600, 1500]

  @MainActor
  public func confirmSaveWhenWritten(
    delaysMilliseconds: [Int] = CircuitDocument.confirmationDelaysMilliseconds
  ) async -> Bool {
    for delay in delaysMilliseconds {
      if delay > 0 {
        try? await Task.sleep(for: .milliseconds(delay))
      }
      guard pendingFingerprint != nil else { return false }
      if reconcileSaveState() { return true }
    }
    abandonPendingSave()
    return false
  }
}
