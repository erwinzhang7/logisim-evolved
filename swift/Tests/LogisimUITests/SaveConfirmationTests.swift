// LogisimUI tests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md at the repository root.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// Board #89: the dirty flag across a real save, including one that does not happen.
//
// The sequence in `savedThenEditedThenFailedSave` is the whole suite in miniature and the
// reason it exists: edit → dirty, save → clean, edit → dirty, **failed save → still dirty**.
// The last leg is the one that was wrong. `serialize()` ended with `project.setFileAsClean()`,
// so the flag cleared when the bytes were *produced*; a read-only volume then left a document
// that reported itself saved with nothing on disk to show for it, and every indicator drawn
// from that flag would have repeated the claim.
//
// ORACLE. Upstream 4.1.0 is right about this and the bytecode is the citation, from the
// shipping jar rather than from this repo's `src/main/java` (which is upstream *main*):
//
//   javap -c -p -cp /Applications/Logisim-evolution.app/Contents/app/\
//   logisim-evolution-4.1.0-all.jar com.cburch.logisim.proj.ProjectActions
//
//   doSave(Project, File):
//     24: invokevirtual  Loader.save:(…)Z    ← boolean
//     31: ifeq  42                           ← false jumps PAST the block
//     39: invokevirtual  Project.setFileAsClean:()V
//
// `setFileAsClean()` is inside the `ifeq` branch. That ordering is what these tests pin.
//
// NO FAKE HOSTS. Every test drives a real `LogisimFileProjectHost` and, where a file is
// involved, a real file in a real temporary directory. The defect was precisely that a save
// could report success without a file existing, so a suite that mocked the filesystem would
// have been unable to see it.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimFile
import Testing
import UniformTypeIdentifiers

@testable import LogisimUI

@MainActor
private func newHost() throws -> LogisimFileProjectHost {
  LogisimFileProjectHostFactory.registerBuiltinLibrariesIfNeeded()
  return try #require(
    LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
}

@MainActor
private func scratch(_ name: String = UUID().uuidString) throws -> URL {
  let url = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("save89-" + name, isDirectory: true)
  try? FileManager.default.removeItem(at: url)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

// MARK: - The flag, at the host

@Suite("Board #89 — the dirty flag moves on the write, not on the snapshot")
struct SaveDirtyFlagTests {

  /// THE test. Four legs, and the fourth is the defect.
  @Test("edit → dirty, save → clean, edit → dirty, FAILED save → still dirty")
  @MainActor
  func savedThenEditedThenFailedSave() throws {
    let host = try newHost()
    #expect(host.isDirty == false)

    // 1. Edit → dirty.
    try host.perform(.addCircuit)
    #expect(host.isDirty == true)

    // 2. Save → clean. Two steps now, and that separation IS the fix: producing the bytes
    //    leaves the document dirty, and only the confirmation clears it.
    _ = try host.serialize()
    #expect(
      host.isDirty == true,
      "serialize() must be a pure read — the bytes exist but nothing has stored them yet")
    #expect(host.hasPendingSave == true)
    host.confirmSaveSucceeded()
    #expect(host.isDirty == false)
    #expect(host.hasPendingSave == false)

    // 3. Edit → dirty again.
    try host.perform(.addCircuit)
    #expect(host.isDirty == true)

    // 4. A save whose write does NOT happen. Upstream's `ifeq 42`: `setFileAsClean` is skipped
    //    and the project stays dirty. Before this change the document went clean right here,
    //    on the `serialize()` line, and stayed clean with nothing on disk.
    _ = try host.serialize()
    host.confirmSaveFailed()
    #expect(host.isDirty == true, "a save that did not reach the disk must leave work marked unsaved")
    #expect(host.hasPendingSave == false)
  }

  @Test("a stray confirmation cannot invent a clean document")
  @MainActor
  func confirmationWithoutASnapshotDoesNothing() throws {
    let host = try newHost()
    try host.perform(.addCircuit)
    #expect(host.isDirty == true)

    // No `serialize()` has run, so there is nothing to confirm. Guarding this matters because
    // the shell polls speculatively: `reconcileSaveState()` is called on signals that are not
    // themselves proof a save happened.
    host.confirmSaveSucceeded()
    #expect(host.isDirty == true)

    host.confirmSaveSucceeded()
    host.confirmSaveSucceeded()
    #expect(host.isDirty == true)
  }

  /// The window between taking the bytes and storing them is not zero here, `fileWrapper`
  /// runs off the main thread, so an edit can land inside it. `setFileAsClean()` records the
  /// model's current undo-stack state as the saved state, so clearing on that path would swallow
  /// the edit. Upstream cannot hit this: its `doSave` runs to completion on the EDT.
  @Test("an edit made after the snapshot survives the confirmation")
  @MainActor
  func editDuringTheWriteKeepsTheDocumentDirty() throws {
    let host = try newHost()
    try host.perform(.addCircuit)
    _ = try host.serialize()

    try host.perform(.addCircuit)  // lands while the write is in flight
    host.confirmSaveSucceeded()

    #expect(
      host.isDirty == true,
      "the confirmed bytes predate this edit, so the document still has unsaved work")
  }

  /// A DELIBERATE D18 DIVERGENCE, written after the release-blocker audit showed that the
  /// verified upstream behaviour silently loses work.
  ///
  /// Upstream 4.1.0 leaves the document *clean* after undoing back past a confirmed save, even
  /// though the model no longer matches the bytes on disk. The bytecode is the measured oracle:
  ///
  ///     1: getfield  undoMods:I
  ///     4: ifgt      14          <- strictly greater than zero
  ///     8: getfield  forcedDirty:Z
  ///
  /// `setFileAsClean()` zeroes `undoMods`, so one undo takes it to -1 and `ifgt` is false. The
  /// release-blocker audit traced the consequences through `canPerform(.save)`,
  /// `canPerform(.revert)` and the autosave sidecar: the undo had no representation in Save,
  /// Revert, autosave or disk. D18's second arm applies -- GUI-only behaviour, invisible to the
  /// gates, plainly data-loss-shaped -- so the port now records the saved state by undo-stack
  /// serial instead of reproducing `ifgt`.
  @Test("undoing back past a confirmed save is unsaved work — D18 divergence from `ifgt`")
  @MainActor
  func undoPastTheSavePointIsUnsavedWork() throws {
    let host = try newHost()
    try host.perform(.addCircuit)
    _ = try host.serialize()
    host.confirmSaveSucceeded()
    #expect(host.isDirty == false)

    try host.perform(.undo)
    #expect(host.isDirty == true)

    // Redo returns to the state whose bytes were confirmed on disk, so it is clean again. The
    // answer is now about document state rather than about the number of edit commands.
    try host.perform(.redo)
    #expect(host.isDirty == false)

    // A fresh edit past the save point is unsaved work.
    try host.perform(.addCircuit)
    #expect(host.isDirty == true)
  }

  /// `canPerform(.save)` is `isDirty` (`LogisimFileProjectHost.swift:1191`), so the fix moves
  /// the File ▸ Save enablement too. Before, one ⌘S greyed the item out whether or not it wrote.
  @Test("File ▸ Save stays enabled after a save that did not reach the disk")
  @MainActor
  func saveCommandStaysEnabledAfterAFailedWrite() throws {
    let host = try newHost()
    try host.perform(.addCircuit)
    #expect(host.canPerform(.save) == true)

    _ = try host.serialize()
    host.confirmSaveFailed()
    #expect(host.canPerform(.save) == true, "the user must be able to try again")

    _ = try host.serialize()
    host.confirmSaveSucceeded()
    #expect(host.canPerform(.save) == false)
  }

  /// `LogisimFile.setDirty(false)` clears `autosaveDirtyFlag` as well as `dirtyFlag`; the
  /// "deliberate asymmetry" at `LogisimFile.swift:645-651`. Board #89 recorded "there is no way
  /// to clear `isAutosaveDirty`"; there is, and it is this path. Asserted rather than assumed,
  /// because it is now reachable only through a *confirmed* save.
  @Test("a confirmed save clears the autosave-dirty flag too")
  @MainActor
  func confirmedSaveClearsAutosaveDirty() throws {
    let host = try newHost()
    try host.perform(.addCircuit)
    #expect(host.file.isAutosaveDirty == true)

    _ = try host.serialize()
    #expect(host.file.isAutosaveDirty == true, "still unsaved — the bytes have not landed")

    host.confirmSaveSucceeded()
    #expect(host.file.isAutosaveDirty == false)
  }

  @Test("a save that did not reach the disk leaves the autosave sidecar's reason to exist intact")
  @MainActor
  func failedSaveKeepsAutosaveDirty() throws {
    let host = try newHost()
    try host.perform(.addCircuit)
    _ = try host.serialize()
    host.confirmSaveFailed()
    // If this cleared, the sidecar, the only remaining copy of the work, would stop being
    // written on the next tick.
    #expect(host.file.isAutosaveDirty == true)
  }
}

// MARK: - The evidence

@Suite("SaveVerification — only bytes actually on disk count as a save")
struct SaveVerificationTests {

  @Test("bytes written to the destination verify")
  @MainActor
  func writtenBytesVerify() throws {
    let dir = try scratch()
    let file = dir.appendingPathComponent("adder.circ")
    let data = Data("<project/>".utf8)
    try data.write(to: file)
    #expect(SaveVerification.bytesReached(file, fingerprint: SaveVerification.fingerprint(data)))
  }

  @Test("every way a write can fail to happen answers false")
  @MainActor
  func failuresDoNotVerify() throws {
    let dir = try scratch()
    let data = Data("<project/>".utf8)
    let print = SaveVerification.fingerprint(data)

    // Untitled: there is no destination at all.
    #expect(SaveVerification.bytesReached(nil, fingerprint: print) == false)

    // Nothing at the path; the read-only-volume case.
    #expect(
      SaveVerification.bytesReached(dir.appendingPathComponent("missing.circ"), fingerprint: print)
        == false)

    // A partial write. This is the case that makes a size-or-timestamp heuristic wrong, and it
    // is the shape of upstream's zero-length-file recovery dance in `Loader.save`.
    let truncated = dir.appendingPathComponent("truncated.circ")
    try data.prefix(4).write(to: truncated)
    #expect(SaveVerification.bytesReached(truncated, fingerprint: print) == false)

    // Empty.
    let empty = dir.appendingPathComponent("empty.circ")
    try Data().write(to: empty)
    #expect(SaveVerification.bytesReached(empty, fingerprint: print) == false)

    // Somebody else's bytes at our path.
    let other = dir.appendingPathComponent("other.circ")
    try Data("<project><different/></project>".utf8).write(to: other)
    #expect(SaveVerification.bytesReached(other, fingerprint: print) == false)

    // A directory where the file should be.
    let asDirectory = dir.appendingPathComponent("dir.circ")
    try FileManager.default.createDirectory(at: asDirectory, withIntermediateDirectories: true)
    #expect(SaveVerification.bytesReached(asDirectory, fingerprint: print) == false)
  }

  @Test("a file overwritten after verifying stops verifying")
  @MainActor
  func staleFileStopsVerifying() throws {
    let dir = try scratch()
    let file = dir.appendingPathComponent("adder.circ")
    let mine = Data("<project><mine/></project>".utf8)
    try mine.write(to: file)
    let print = SaveVerification.fingerprint(mine)
    #expect(SaveVerification.bytesReached(file, fingerprint: print))

    try Data("<project><theirs/></project>".utf8).write(to: file)
    #expect(SaveVerification.bytesReached(file, fingerprint: print) == false)
  }
}

// MARK: - The document, end to end

@Suite("CircuitDocument — ⌘S clears the flag only when the bytes are found on disk")
struct DocumentSaveConfirmationTests {

  /// Build a document with a real host attached and the automatic poll off, so the moment the
  /// flag moves is the line that moves it rather than a timer.
  @MainActor
  private func makeDocument(at url: URL) throws -> (CircuitDocument, LogisimFileProjectHost) {
    LogisimFileProjectHostFactory.registerBuiltinLibrariesIfNeeded()
    let document = CircuitDocument()
    document.confirmsSavesAutomatically = false
    document.currentURL = url
    let host = try #require(document.attachedHost(fileURL: url) as? LogisimFileProjectHost)
    return (document, host)
  }

  /// The real ⌘S path: `snapshot(contentType:)` → `fileWrapper(snapshot:configuration:)` →
  /// the system writes → the shell verifies. Here the "system writes" step is done by hand so
  /// the *unwritten* case can be tested at all.
  @Test("a ⌘S whose bytes reach the disk clears the flag")
  @MainActor
  func writtenSaveClearsTheFlag() throws {
    let dir = try scratch()
    let file = dir.appendingPathComponent("adder.circ")
    let (document, host) = try makeDocument(at: file)

    try host.perform(.addCircuit)
    #expect(host.isDirty == true)

    let bytes = try document.snapshot(contentType: LogisimDocumentType.circuit)
    #expect(host.isDirty == true, "producing bytes is not saving")
    #expect(document.hasPendingSave == true)
    #expect(document.lastConfirmedSave == nil)

    // Nothing on disk yet; reconciling now must NOT clear anything.
    #expect(document.reconcileSaveState() == false)
    #expect(host.isDirty == true)

    // The system's half of the save.
    try bytes.write(to: file)

    #expect(document.reconcileSaveState() == true)
    #expect(host.isDirty == false)
    #expect(document.hasPendingSave == false)
    #expect(document.lastConfirmedSave != nil)
  }

  /// The defect, at the level the user meets it.
  @Test("a ⌘S whose write never happens leaves the document dirty")
  @MainActor
  func unwrittenSaveLeavesItDirty() throws {
    let dir = try scratch()
    let file = dir.appendingPathComponent("adder.circ")
    let (document, host) = try makeDocument(at: file)

    try host.perform(.addCircuit)
    _ = try document.snapshot(contentType: LogisimDocumentType.circuit)

    // Reconcile as often as anything in the shell might: the answer never changes, because
    // the file is not there.
    for _ in 0..<5 { #expect(document.reconcileSaveState() == false) }
    #expect(host.isDirty == true)
    #expect(document.lastConfirmedSave == nil)
    #expect(FileManager.default.fileExists(atPath: file.path) == false)

    document.abandonPendingSave()
    #expect(host.isDirty == true)
    #expect(document.hasPendingSave == false)
  }

  /// A read-only directory is the real-world version of the above, and it is the one that
  /// actually happened to somebody: a `.circ` opened from a mounted image or a locked folder.
  /// `0o500` does not stop uid 0, so as root the write would succeed and this would report a
  /// failure that says nothing about the code. Skipped rather than left to misfire; a suite
  /// that cries wolf in one environment gets ignored in all of them.
  @Test(
    "a save into a read-only directory does not clear the flag",
    .enabled(if: getuid() != 0, "chmod does not constrain root"))
  @MainActor
  func readOnlyDestinationLeavesItDirty() throws {
    let dir = try scratch()
    let file = dir.appendingPathComponent("adder.circ")
    let (document, host) = try makeDocument(at: file)
    try host.perform(.addCircuit)

    let bytes = try document.snapshot(contentType: LogisimDocumentType.circuit)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    #expect(throws: (any Error).self) { try bytes.write(to: file) }
    #expect(document.reconcileSaveState() == false)
    #expect(host.isDirty == true, "the volume refused the write; the work is still only in memory")
  }

  @Test("the poll resolves true once the bytes appear and false when they never do")
  @MainActor
  func pollResolvesBothWays() async throws {
    let dir = try scratch()
    let file = dir.appendingPathComponent("adder.circ")
    let (document, host) = try makeDocument(at: file)
    try host.perform(.addCircuit)

    // Never written: the poll runs out of attempts and reports that it could not confirm.
    _ = try document.snapshot(contentType: LogisimDocumentType.circuit)
    let unconfirmed = await document.confirmSaveWhenWritten(delaysMilliseconds: [0, 1, 1])
    #expect(unconfirmed == false)
    #expect(host.isDirty == true)

    // Written before the poll starts: confirmed on the first attempt.
    let bytes = try document.snapshot(contentType: LogisimDocumentType.circuit)
    try bytes.write(to: file)
    let confirmed = await document.confirmSaveWhenWritten(delaysMilliseconds: [0, 1, 1])
    #expect(confirmed == true)
    #expect(host.isDirty == false)
  }

  /// Save As. The bytes go to the *new* URL, and the shell has to be looking at the new one,
  /// which is the half of board #89 about `fileURL` going stale.
  @Test("after a Save As the confirmation follows the document to its new URL")
  @MainActor
  func saveAsFollowsTheDocument() throws {
    let dir = try scratch()
    let original = dir.appendingPathComponent("adder.circ")
    let renamed = dir.appendingPathComponent("adder-v2.circ")
    let (document, host) = try makeDocument(at: original)
    try host.perform(.addCircuit)

    let bytes = try document.snapshot(contentType: LogisimDocumentType.circuit)
    try bytes.write(to: renamed)

    // Still pointed at the old name: the bytes are not there, so nothing is confirmed.
    #expect(document.reconcileSaveState() == false)
    #expect(host.isDirty == true)

    // What `DocumentRoot.onChange(of: fileURL)` does.
    document.currentURL = renamed
    host.documentMoved(to: renamed)

    #expect(document.reconcileSaveState() == true)
    #expect(host.isDirty == false)
    #expect(host.fileURL == renamed, "board #89: fileURL was assigned once in init and went stale")
  }
}

// MARK: - The banner

@Suite("SaveBanner — what the confirmation says, and how long it stays")
struct SaveBannerTests {

  /// A failure that dismisses itself is a failure the user can miss, and missing it is how the
  /// work is lost. The asymmetry is the point of the type.
  @Test("a success auto-dismisses and an unconfirmed save does not")
  func onlySuccessAutoDismisses() {
    #expect(SaveBanner.duration(for: .saved) != nil)
    #expect(SaveBanner.duration(for: .notWritten) == nil)
  }

  /// The wording carries the honesty of the mechanism: the poll running out proves we did not
  /// *see* the write, not that it did not happen. Claiming failure would be the same lie as
  /// board #89 pointed the other way.
  @Test("the unconfirmed message claims uncertainty, not failure")
  func unconfirmedWordingDoesNotOverclaim() {
    let title = SaveBanner.title(for: .notWritten)
    #expect(title.lowercased().contains("could not confirm"))
    #expect(title.lowercased().contains("failed") == false)
    let detail = try? #require(SaveBanner.detail(for: .notWritten))
    #expect(detail?.contains("unsaved changes") == true)
    // A success needs no explanation; a second line would make it something to read.
    #expect(SaveBanner.detail(for: .saved) == nil)
  }
}
