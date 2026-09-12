// FileActionUndoTests.swift: part of logisim-evolved.
// SPDX-License-Identifier: GPL-3.0-only
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// Board #95: the six structural file operations, driven THROUGH THE HOST.
//
// Every test here calls `LogisimFileProjectHost.perform(_:)` with a real `ProjectCommand`, then
// `perform(.undo)`, then `perform(.redo)`. None of them constructs a `LogisimFileActions` object
// directly, and that is the whole point of the suite: an action class can be flawless while
// nothing pushes it onto `Project.undoLog`, and "the Action is right but nothing calls it" is the
// seam shape this project has hit twenty-eight times. What the user experiences is
// menu → command → undo stack, so that is what is asserted.
//
// The assertions are deliberately about the *file*, not about the action: circuit count, tool
// order, `mainCircuit` identity, library membership, and the SoC binder's eviction; the four
// things `LogisimFile.removeCircuit` destroys plus the one the port has to own itself.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimFile
import LogisimKernel
import Testing

@testable import LogisimUI

@MainActor
private func newHost() throws -> LogisimFileProjectHost {
  LogisimFileProjectHostFactory.registerBuiltinLibrariesIfNeeded()
  return try #require(
    LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
}

/// The tool-list positions of the file's circuits, by name. `indexOfCircuit` indexes the *tool*
/// list, which is what `addCircuit(_:at:)` consumes, so this is the thing a restored circuit has
/// to land back in.
@MainActor
private func toolOrder(_ host: LogisimFileProjectHost) -> [String] {
  host.file.circuits.map(\.name)
}

@Suite("File-level actions — add and remove a circuit are undoable")
struct FileActionAddRemoveTests {

  @Test("adding a circuit lands on the undo stack, and undo removes it again")
  @MainActor
  func addCircuitUndoes() throws {
    let host = try newHost()
    #expect(host.file.circuitCount == 1)
    #expect(host.isDirty == false)
    #expect(host.canPerform(.undo) == false)

    try host.perform(.addCircuit)
    #expect(host.file.circuitCount == 2)
    #expect(host.isDirty == true)
    // The Edit menu's label, which is what tells the user undo is available at all.
    #expect(host.undoStatus.undoStack.first == "Add Circuit")
    #expect(host.canPerform(.undo) == true)

    let added = try #require(host.currentCircuitObject)
    #expect(added.name == "circuit_1")

    try host.perform(.undo)
    #expect(host.file.circuitCount == 1)
    #expect(host.file.contains(circuit: added) == false)
    // `Project` derives dirtiness from the undo-stack state, so undoing back to the last saved
    // state must make the file clean again. If the arm had kept `setForcedDirty()` this would
    // stay true forever -- that flag has no way back down -- which is why the arm no longer
    // forces it.
    #expect(host.isDirty == false)

    try host.perform(.redo)
    #expect(host.file.circuitCount == 2)
    // D4/D3: the *same object* comes back, not a structurally identical replacement. The undo
    // stack is what kept it alive; a rebuilt circuit would silently lose every piece of state
    // keyed on identity.
    #expect(host.file.circuits.contains { $0 === added })
  }

  @Test("undoing an add moves the canvas off the circuit that just vanished")
  @MainActor
  func undoingAddLeavesTheCanvasOnALiveCircuit() throws {
    let host = try newHost()
    let main = try #require(host.file.mainCircuit)

    try host.perform(.addCircuit)
    let added = try #require(host.currentCircuitObject)
    #expect(added !== main)

    try host.perform(.undo)
    // Without the reconciliation in `afterUndoStackChanged` the canvas would keep drawing a
    // circuit the file no longer contains: a live editor over a detached object graph.
    #expect(host.currentCircuitObject === main)
    #expect(host.file.contains(circuit: try #require(host.currentCircuitObject)))
  }

  @Test("undoing a removal restores the circuit at its original position in the tool list")
  @MainActor
  func removeCircuitRestoresPosition() throws {
    let host = try newHost()
    try host.perform(.addCircuit)
    try host.perform(.addCircuit)
    #expect(toolOrder(host) == ["main", "circuit_1", "circuit_2"])

    // The middle one: a restore that appends instead of inserting would still pass on the last.
    let victim = try #require(host.file.circuits.first { $0.name == "circuit_1" })
    let id = try #require(host.outline.circuits.first { $0.name == "circuit_1" }?.id)
    let index = host.file.indexOfCircuit(victim)

    try host.perform(.removeCircuit(id))
    #expect(toolOrder(host) == ["main", "circuit_2"])
    #expect(host.undoStatus.undoStack.first == "Remove Circuit")

    try host.perform(.undo)
    #expect(toolOrder(host) == ["main", "circuit_1", "circuit_2"])
    #expect(host.file.indexOfCircuit(victim) == index)
    #expect(host.file.circuits.contains { $0 === victim })
    // The other direction of `RemoveCircuitAction`'s `wasMain` guard: restoring a circuit that
    // was *not* main must not make it main. A guard that always restores main would satisfy
    // "undoing the removal of the main circuit restores main-circuit status" just as well, which
    // is why both directions are asserted.
    #expect(host.file.mainCircuit?.name == "main")

    try host.perform(.redo)
    #expect(toolOrder(host) == ["main", "circuit_2"])
  }

  @Test("undoing the removal of the main circuit restores main-circuit status")
  @MainActor
  func removeMainCircuitRestoresMain() throws {
    let host = try newHost()
    try host.perform(.addCircuit)
    let main = try #require(host.file.mainCircuit)
    #expect(main.name == "main")
    let id = try #require(host.outline.circuits.first { $0.name == "main" }?.id)

    try host.perform(.removeCircuit(id))
    // `LogisimFile.removeCircuit` reassigns `main` to the first remaining tool's circuit.
    #expect(host.file.mainCircuit !== main)

    try host.perform(.undo)
    // Upstream's `RemoveCircuit.undo` does NOT do this; see the divergence note in
    // `LogisimFileActions.RemoveCircuitAction.undo`. This assertion is what pins the divergence;
    // if it is ever reverted for fidelity, this is the test that says so.
    #expect(host.file.mainCircuit === main)
    #expect(host.outline.circuits.filter(\.isMain).count == 1)
  }

  @Test("the SoC binding is evicted on removal and restored on undo")
  @MainActor
  func socBindingFollowsMembership() throws {
    let host = try newHost()
    try host.perform(.addCircuit)
    let added = try #require(host.currentCircuitObject)
    let id = try #require(host.outline.circuits.first { $0.name == added.name }?.id)

    // Attached when created; Java gets this from `Circuit`'s constructor.
    #expect(host.socBinder.manager(for: added) != nil)

    try host.perform(.removeCircuit(id))
    // The action holds `added` strongly, so `SocCircuitBinder.prune` cannot reclaim it; the
    // eviction has to be explicit, and it has to happen at the moment membership changes rather
    // than at the command arm, because the same transition now happens again on redo.
    #expect(host.socBinder.manager(for: added) == nil)

    try host.perform(.undo)
    #expect(host.socBinder.manager(for: added) != nil)

    try host.perform(.redo)
    #expect(host.socBinder.manager(for: added) == nil)
  }
}

@Suite("File-level actions — rename, reorder, main circuit, unload")
struct FileActionStructureTests {

  @Test("renaming a circuit is undoable and redoable")
  @MainActor
  func renameUndoes() throws {
    let host = try newHost()
    let circuit = try #require(host.file.mainCircuit)
    let id = try #require(host.outline.circuits.first?.id)

    try host.perform(.renameCircuit(id, "top_level"))
    #expect(circuit.name == "top_level")
    #expect(host.outline.circuits.first?.name == "top_level")
    #expect(host.undoStatus.undoStack.first == "Rename Circuit")

    try host.perform(.undo)
    #expect(circuit.name == "main")
    #expect(host.outline.circuits.first?.name == "main")
    #expect(host.isDirty == false)

    try host.perform(.redo)
    #expect(circuit.name == "top_level")
  }

  @Test("a name another circuit already has is still refused, and pushes nothing")
  @MainActor
  func renameConflictStillRefused() throws {
    let host = try newHost()
    try host.perform(.addCircuit)
    let depth = host.undoStatus.undoStack.count
    let id = try #require(host.outline.circuits.first { $0.name == "circuit_1" }?.id)

    #expect(throws: ProjectHostError.self) {
      try host.perform(.renameCircuit(id, "main"))
    }
    #expect(host.file.circuits.map(\.name) == ["main", "circuit_1"])
    // The refusal must not cost an undo entry either.
    #expect(host.undoStatus.undoStack.count == depth)
  }

  @Test("reordering a circuit is undoable, and a run of moves coalesces into one entry")
  @MainActor
  func moveCircuitUndoesAndCoalesces() throws {
    let host = try newHost()
    try host.perform(.addCircuit)
    try host.perform(.addCircuit)
    #expect(toolOrder(host) == ["main", "circuit_1", "circuit_2"])
    let depthBefore = host.undoStatus.undoStack.count

    let id = try #require(host.outline.circuits.first { $0.name == "circuit_2" }?.id)
    try host.perform(.moveCircuitUp(id))
    #expect(toolOrder(host) == ["main", "circuit_2", "circuit_1"])
    #expect(host.undoStatus.undoStack.first == "Reorder Circuits")

    try host.perform(.moveCircuitUp(id))
    #expect(toolOrder(host) == ["circuit_2", "main", "circuit_1"])
    // `MoveCircuitAction.shouldAppendTo` compares the AddTool by reference, exactly as
    // `LogisimFileActions.MoveCircuit:513` compares `circ.tool == this.tool`. Two moves of the
    // same circuit are one gesture and must be one entry; otherwise dragging a circuit three
    // places up the sidebar costs three Cmd-Zs.
    #expect(host.undoStatus.undoStack.count == depthBefore + 1)

    try host.perform(.undo)
    // One undo rewinds the whole run, back to where the run started.
    #expect(toolOrder(host) == ["main", "circuit_1", "circuit_2"])

    try host.perform(.redo)
    #expect(toolOrder(host) == ["circuit_2", "main", "circuit_1"])
  }

  @Test("setting the main circuit is undoable")
  @MainActor
  func setMainCircuitUndoes() throws {
    let host = try newHost()
    try host.perform(.addCircuit)
    let main = try #require(host.file.mainCircuit)
    let other = try #require(host.file.circuits.first { $0 !== main })
    let id = try #require(host.outline.circuits.first { $0.name == other.name }?.id)

    try host.perform(.setMainCircuit(id))
    #expect(host.file.mainCircuit === other)
    #expect(host.undoStatus.undoStack.first == "Set Main Circuit")

    try host.perform(.undo)
    #expect(host.file.mainCircuit === main)

    try host.perform(.redo)
    #expect(host.file.mainCircuit === other)
  }

  @Test("unloading a library is undoable and puts the same library object back")
  @MainActor
  func unloadLibraryUndoes() throws {
    let host = try newHost()
    // Whichever library the file will actually let go of; `unloadLibraryMessage` refuses one
    // whose tools are placed or on the toolbar, and that refusal is not what this test is about.
    let candidate = host.outline.libraries.compactMap { item -> (LibraryID, Library)? in
      guard let library = host.handles.libraries[item.id],
        host.file.unloadLibraryMessage(library) == nil
      else { return nil }
      return (item.id, library)
    }.first
    let (id, library) = try #require(candidate, "no unloadable library in the default template")

    let namesBefore = host.file.libraries.map(\.name)
    try host.perform(.unloadLibrary(id))
    #expect(host.file.libraries.contains { $0 === library } == false)
    #expect(host.undoStatus.undoStack.first == "Unload Library")

    try host.perform(.undo)
    #expect(host.file.libraries.contains { $0 === library })
    // Order is NOT restored; upstream appends and so does this; see `UnloadLibraryAction.undo`.
    // Asserted as a set so the test states what is guaranteed rather than over-promising.
    #expect(Set(host.file.libraries.map(\.name)) == Set(namesBefore))
    #expect(host.isDirty == false)

    try host.perform(.redo)
    #expect(host.file.libraries.contains { $0 === library } == false)
  }
}
