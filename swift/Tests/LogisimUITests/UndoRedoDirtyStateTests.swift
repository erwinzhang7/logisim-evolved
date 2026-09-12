// LogisimUI tests -- part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md at the repository root.
//
// =============================================================================
// THE DIRTY PREDICATE NAMES ONE DOCUMENT STATE, NOT A NET EDIT COUNT.
//
// Board #89 fixed when the dirty flag moves: on the write, not on the snapshot. This suite fixes
// what it means. The bug is a D18 second-arm divergence: upstream 4.1.0 is the measured oracle,
// and it is wrong in GUI-only behavior that can cost a user real work.
//
// Upstream bytecode from the shipping 4.1.0 jar:
//
//   javap -p -c -cp /Applications/Logisim-evolution.app/Contents/app/\
//   logisim-evolution-4.1.0-all.jar com.cburch.logisim.proj.Project
//
//   isFileDirty():           1: getfield undoMods:I / 4: ifgt 14 / 8: getfield forcedDirty:Z
//   redoAction():           29: getfield undoMods:I / 32: iconst_1 / 33: iadd
//                          103: Action.doIt / 106..118: fireEvent(12)       (no setDirty)
//   undoAction():           99: Action.isModification / 103: ifeq 116 / 113: putfield undoMods
//                          136..144: file.setDirty(isFileDirty())
//   discardAllEdits():      16: putfield undoMods:I / 19..31: fireEvent(6)  (no setDirty)
//
// NO FAKE HOSTS. The reproductions below drive a real `LogisimFileProjectHost`; the autosave
// probes drive a real `AutosaveController` against a real temporary directory.
// =============================================================================

import Foundation
import LogisimFile
import Testing

@testable import LogisimUI

@MainActor
private func newDirtyStateHost() throws -> LogisimFileProjectHost {
  LogisimFileProjectHostFactory.registerBuiltinLibrariesIfNeeded()
  return try #require(
    LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
}

@MainActor
private func dirtyStateScratch(_ name: String = UUID().uuidString) throws -> URL {
  let url = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("dirty-state-" + name, isDirectory: true)
  try? FileManager.default.removeItem(at: url)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

@MainActor
private func completeSave(_ host: LogisimFileProjectHost) throws {
  _ = try host.serialize()
  host.confirmSaveSucceeded()
}

@MainActor
private func autosaveController(
  for host: LogisimFileProjectHost,
  at fileURL: URL
) -> AutosaveController {
  AutosaveController(
    subject: .project(host: { host }, url: { fileURL }),
    isEnabled: { true },
    intervalSeconds: { 1 })
}

@MainActor
private final class ShowOnlyAction: Action {
  private(set) var applications = 0
  override var name: String { "showOnly" }
  override var isModification: Bool { false }
  override func shouldAppendTo(_ other: Action) -> Bool { false }
  override func doIt(_ project: Project) throws { applications += 1 }
  override func undo(_ project: Project) throws { applications -= 1 }
}

private enum DirtyStateProbeError: Error {
  case expected
}

@MainActor
private final class ThrowingAction: Action {
  private(set) var didRun = false
  override var name: String { "throwing" }
  override func shouldAppendTo(_ other: Action) -> Bool { false }
  override func doIt(_ project: Project) throws {
    didRun = true
    throw DirtyStateProbeError.expected
  }
  override func undo(_ project: Project) throws {}
}

@MainActor
private final class CountingAction: Action {
  override var name: String { "counting" }
  override func shouldAppendTo(_ other: Action) -> Bool { false }
  override func doIt(_ project: Project) throws {}
  override func undo(_ project: Project) throws {}
}

@MainActor
private final class CoalescingAction: Action {
  override var name: String { "coalescing" }
  override func shouldAppendTo(_ other: Action) -> Bool { true }
  override func doIt(_ project: Project) throws {}
  override func undo(_ project: Project) throws {}
}

@Suite("Undo/redo dirty state -- one definition")
struct UndoRedoDirtyStateTests {

  @Test("save, then undo reports unsaved bytes everywhere")
  @MainActor
  func undoPastASaveIsUnsavedWork() throws {
    let directory = try dirtyStateScratch()
    let fileURL = directory.appendingPathComponent("save-undo.circ")
    let host = try newDirtyStateHost()
    let controller = autosaveController(for: host, at: fileURL)
    let sidecar = try #require(AutosaveSidecar.path(besideFileAt: fileURL))

    try host.perform(.addCircuit)
    #expect(controller.tick() == .wrote(sidecar))
    try completeSave(host)
    #expect(host.isDirty == false)
    #expect(host.file.isAutosaveDirty == false)

    try host.perform(.undo)

    #expect(host.isDirty == true, "File > Save and close prompting read this flag")
    #expect(host.canPerform(.save) == true)
    #expect(host.canPerform(.revert) == true)
    #expect(host.file.isDirty == true, "LogisimFile must mirror the project")
    #expect(host.file.isAutosaveDirty == true, "the undo exists only in memory until autosave runs")
    #expect(controller.tick() == .wrote(sidecar))
  }

  @Test("redo from a clean document re-arms autosave")
  @MainActor
  func redoRearmsTheAutosaveLoop() throws {
    let directory = try dirtyStateScratch()
    let fileURL = directory.appendingPathComponent("redo.circ")
    let host = try newDirtyStateHost()
    let controller = autosaveController(for: host, at: fileURL)

    try host.perform(.addCircuit)
    try host.perform(.undo)
    try host.perform(.redo)

    #expect(host.isDirty == true, "the redone circuit has never been saved")
    #expect(host.file.isDirty == true)
    #expect(host.file.isAutosaveDirty == true, "autosave must read the same truth as Save")

    let sidecar = try #require(AutosaveSidecar.path(besideFileAt: fileURL))
    #expect(controller.tick() == .wrote(sidecar))
    #expect(FileManager.default.fileExists(atPath: sidecar.path))
  }

  @Test("undo past a save, then make a different edit is dirty")
  @MainActor
  func undoThenADifferentEditIsNotClean() throws {
    let host = try newDirtyStateHost()
    try host.perform(.addCircuit)
    try completeSave(host)

    try host.perform(.undo)
    try host.perform(.addCircuit)

    #expect(
      host.isDirty == true,
      "the net count is zero here, but circuit B exists only in memory")
    #expect(host.canPerform(.save) == true)
    #expect(host.file.isAutosaveDirty == true)
  }

  @Test("Edit > Clear Undo History does not claim the document was saved")
  @MainActor
  func clearUndoHistoryDoesNotClaimASave() throws {
    let host = try newDirtyStateHost()
    try host.perform(.addCircuit)
    #expect(host.isDirty == true)

    try host.perform(.clearUndoHistory)

    #expect(host.isDirty == true, "forgetting how to undo an edit does not write it to disk")
    #expect(host.canPerform(.save) == true)
    #expect(host.file.isDirty == true)
    #expect(host.file.isAutosaveDirty == true)
  }

  @Test("redoing back to the saved state is clean again")
  @MainActor
  func redoBackToTheSavePointIsClean() throws {
    let host = try newDirtyStateHost()
    try host.perform(.addCircuit)
    try completeSave(host)

    try host.perform(.undo)
    #expect(host.isDirty == true)

    try host.perform(.redo)
    #expect(host.isDirty == false, "the model is the state that was confirmed on disk")
    #expect(host.file.isDirty == false)
    #expect(host.file.isAutosaveDirty == false)
  }

  @Test("undoing an edit made after a save is clean again")
  @MainActor
  func undoingBackToTheSavePointIsClean() throws {
    let host = try newDirtyStateHost()
    try host.perform(.addCircuit)
    try completeSave(host)

    try host.perform(.addCircuit)
    #expect(host.isDirty == true)

    try host.perform(.undo)
    #expect(host.isDirty == false, "the second circuit is gone; the first is still saved")
  }

  @Test("a show-only action never dirties the document")
  @MainActor
  func showOnlyActionNeverDirties() throws {
    let host = try newDirtyStateHost()
    try host.perform(.addCircuit)
    try completeSave(host)

    let action = ShowOnlyAction()
    try host.project.doAction(action)
    #expect(action.applications == 1)
    #expect(host.isDirty == false)

    try host.project.undoAction()
    #expect(host.isDirty == false)

    try host.project.redoAction()
    #expect(action.applications == 1)
    #expect(host.isDirty == false, "a clipboard-style action does not change the file")
    #expect(host.file.isAutosaveDirty == false)
  }

  @Test("a throwing edit leaves no phantom dirty state")
  @MainActor
  func throwingEditDoesNotAdvanceDirtyState() throws {
    let directory = try dirtyStateScratch()
    let fileURL = directory.appendingPathComponent("throwing.circ")
    let host = try newDirtyStateHost()
    let controller = autosaveController(for: host, at: fileURL)
    try completeSave(host)

    let action = ThrowingAction()
    #expect(throws: DirtyStateProbeError.self) {
      try host.project.doAction(action)
    }

    #expect(action.didRun == true)
    #expect(host.project.canUndo == false, "a failed edit must not leave a fake undo entry")
    #expect(host.isDirty == false)
    #expect(host.file.isDirty == false)
    #expect(host.file.isAutosaveDirty == false)
    #expect(controller.tick() == .notDirty)
  }
}

@Suite("Undo/redo dirty state -- stack edges")
struct DirtyStateStackEdgeTests {

  @Test("undoing everything is clean when the trim ate only the saved entry")
  @MainActor
  func trimDoesNotStrandTheSavePoint() throws {
    let host = try newDirtyStateHost()
    try host.perform(.addCircuit)
    try completeSave(host)
    #expect(host.isDirty == false)

    for _ in 0..<Project.maxUndoSize { try host.project.doAction(CountingAction()) }
    #expect(host.project.undoActions.count == Project.maxUndoSize)
    #expect(host.isDirty == true)

    while host.project.canUndo { try host.project.undoAction() }
    #expect(host.isDirty == false)
    #expect(host.file.isDirty == false)
  }

  @Test("a trimmed-away edit past the save point keeps the document unsaved")
  @MainActor
  func trimPastTheSavePointStaysDirty() throws {
    let host = try newDirtyStateHost()
    try host.perform(.addCircuit)
    try completeSave(host)

    for _ in 0..<(Project.maxUndoSize + 6) { try host.project.doAction(CountingAction()) }
    while host.project.canUndo { try host.project.undoAction() }

    #expect(host.isDirty == true, "irreversible edits sit between the model and the saved bytes")
    try completeSave(host)
    #expect(host.isDirty == false)
  }

  @Test("a coalesced edit after a save still reports unsaved work")
  @MainActor
  func coalescingDoesNotHideAnEditPastTheSavePoint() throws {
    let host = try newDirtyStateHost()
    try host.project.doAction(CoalescingAction())
    try completeSave(host)
    #expect(host.isDirty == false)

    try host.project.doAction(CoalescingAction())
    #expect(host.project.undoActions.count == 1, "the two samples really did coalesce")
    #expect(host.isDirty == true, "the second sample is not on disk")

    try host.project.undoAction()
    #expect(
      host.isDirty == true,
      "undoing the merged pair reverses the saved half too, so this is not the saved state")
  }
}

@Suite("Undo/redo dirty state -- file mirror")
struct DirtyStateMirrorTests {

  @Test("every path that can change the predicate publishes it")
  @MainActor
  func everyMutatorPublishesTheDirtyState() throws {
    let host = try newDirtyStateHost()
    let project = host.project
    let file = host.file

    func check(_ step: String) {
      #expect(
        file.isDirty == project.isFileDirty,
        "after \(step): file.isDirty=\(file.isDirty) project.isFileDirty=\(project.isFileDirty)")
    }

    check("open")
    try host.perform(.addCircuit)
    check("doAction")
    try host.perform(.undo)
    check("undoAction")
    try host.perform(.redo)
    check("redoAction")
    try completeSave(host)
    check("setFileAsClean")
    try host.perform(.undo)
    check("undo past save")
    project.setForcedDirty()
    check("setForcedDirty")
    project.discardAllEdits()
    check("discardAllEdits")
    #expect(project.isFileDirty == true)

    try completeSave(host)
    check("save after discard")
    #expect(project.isFileDirty == false)
  }

  @Test("installing a different file does not inherit forced dirtiness")
  @MainActor
  func installingAFileClearsInheritedDirtiness() throws {
    let host = try newDirtyStateHost()
    host.project.setForcedDirty()
    #expect(host.isDirty == true)

    let replacement = try LogisimFile.createNew(loader: Loader(ui: HeadlessLoaderUI()))
    host.project.setLogisimFile(replacement)

    #expect(host.project.isFileDirty == false, "a freshly installed file has no unsaved work")
    #expect(replacement.isDirty == false)
    #expect(replacement.isAutosaveDirty == false)
  }
}
