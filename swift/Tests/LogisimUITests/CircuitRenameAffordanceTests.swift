// CircuitRenameAffordanceTests.swift: part of logisim-evolved.
// SPDX-License-Identifier: GPL-3.0-only
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// Rename a circuit FROM THE CIRCUIT; the shell half.
//
// `ProjectCommand.renameCircuit` was implemented, undoable and tested (`FileActionUndoTests`)
// while nothing in the shell produced it: the explorer's circuit context menu offered Set as Main,
// Analyze, Statistics, Move Up, Move Down and Remove, and the only way to rename anything was to
// find the NAME row in the attribute inspector. This suite covers the piece that closes that gap.
//
// WHAT IS ASSERTED, AND WHAT IS NOT. The affordance is a SwiftUI `Button` inside a `.contextMenu`
// with an `.alert`, and there is no honest way to assert from a test that a menu item is drawn or
// that an alert presents. So the decision was deliberately pulled *out* of the view into
// `CircuitRenameRequest`, and what is asserted is the pair that actually carries the behaviour:
//
//   1. the request produces the right `ProjectCommand`, with the right payload, and produces
//      *none* in every case where sending one would be wrong; and
//   2. the command it produces, handed to a real `LogisimFileProjectHost`, renames the circuit,
//      lands on the undo stack, and is refused when upstream would refuse it.
//
// UNASSERTED, and stated rather than papered over: that `Button("Rename…")` appears in the menu,
// that the alert presents on macOS, and that the alert's Rename button's `.disabled` binding
// tracks `command == nil` on screen. Those are wiring between two things each tested here.
// `renameGuardIsLoadBearing` below is the closest a test can get: it shows what reaches the model
// when the guard is absent, which is the whole reason the guard is not in the view.
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

/// The id of the freshly-made project's one circuit, named `main`.
@MainActor
private func mainCircuitID(_ host: LogisimFileProjectHost) throws -> CircuitID {
  try #require(host.outline.circuits.first { $0.name == "main" }?.id)
}

@Suite("Rename Circuit — what the menu decides to send")
struct CircuitRenameRequestTests {

  /// The ordinary case. The payload has to be the *new* name and the *right* circuit; a request
  /// that produced `.renameCircuit(id, originalName)` would look green in a test that only
  /// checked `command != nil`.
  @Test("a new name produces renameCircuit carrying that name and that circuit")
  @MainActor
  func newNameProducesTheCommand() throws {
    let id = CircuitID(rawValue: 7)
    let request = CircuitRenameRequest(id: id, originalName: "main", proposedName: "top_level")

    #expect(request.rejectionReason == nil)
    #expect(request.command == .renameCircuit(id, "top_level"))
  }

  /// `CircuitAttributes$StaticListener.attributeValueChanged` (4.1.0 jar, `javap -c`) refuses an
  /// empty name with `EmptyNameError` and reverts. Refusing here, before a command exists, is the
  /// same outcome without upstream's phantom undo entry.
  @Test("an empty name is refused with a reason and produces no command")
  @MainActor
  func emptyNameIsRefused() {
    let request = CircuitRenameRequest(id: CircuitID(rawValue: 1), originalName: "main", proposedName: "")

    #expect(request.rejectionReason != nil)
    #expect(request.command == nil)
  }

  /// Upstream's own empty test is `String.isEmpty()`, so `"   "` gets past it, and is then thrown
  /// out one line later by `SyntaxChecker`'s `^([a-zA-Z]+\w*)` under `matches()`. That syntax check
  /// is a recorded gap in this port, so refusing whitespace here is what preserves 4.1.0's
  /// accepted set. Without the trim this name would reach the model and be *accepted*.
  @Test("a whitespace-only name is refused too, which upstream's SyntaxChecker is what does")
  @MainActor
  func whitespaceOnlyNameIsRefused() {
    let request = CircuitRenameRequest(
      id: CircuitID(rawValue: 1), originalName: "main", proposedName: "   \n ")

    #expect(request.rejectionReason != nil)
    #expect(request.command == nil)
  }

  /// Same reason: `" Foo "` is not a legal 4.1.0 circuit name, and the port's model would take it
  /// verbatim. Trimming lands on the name the user meant instead of on one upstream rejects.
  @Test("surrounding whitespace is trimmed out of the payload rather than renamed into the file")
  @MainActor
  func surroundingWhitespaceIsTrimmed() {
    let id = CircuitID(rawValue: 3)
    let request = CircuitRenameRequest(id: id, originalName: "main", proposedName: "  adder  ")

    #expect(request.normalizedName == "adder")
    #expect(request.command == .renameCircuit(id, "adder"))
  }

  /// `attributeValueChanged` opens with `if (newName.equals(oldName)) return;` (4.1.0 jar,
  /// `javap -c`, offsets 38–43). Sending the command anyway would push a "Rename Circuit" entry
  /// that undoes to the same name; an undo step for an edit that never happened.
  @Test("renaming to the name it already has is a no-op, not an error")
  @MainActor
  func unchangedNameProducesNothing() {
    let request = CircuitRenameRequest(
      id: CircuitID(rawValue: 1), originalName: "main", proposedName: "main")

    // Nothing to complain about; the user simply has not changed anything yet.
    #expect(request.rejectionReason == nil)
    #expect(request.command == nil)
    // And the same holds once whitespace is normalised away.
    #expect(
      CircuitRenameRequest(id: CircuitID(rawValue: 1), originalName: "main", proposedName: " main ")
        .command == nil)
  }

  /// Deliberately *not* pre-checked in the shell. `LogisimFile.circuitNameConflicts` matches any
  /// tool in any loaded library as well as any other circuit, and re-deriving that from the
  /// outline would be a second source of truth. The request hands the command over; the host
  /// refuses it. `conflictingNameIsRefusedByTheHost` below is the other half.
  @Test("a name already in use still produces a command — the conflict check belongs to the host")
  @MainActor
  func conflictIsDelegatedNotDuplicated() {
    let id = CircuitID(rawValue: 2)
    let request = CircuitRenameRequest(id: id, originalName: "circuit_1", proposedName: "main")

    #expect(request.rejectionReason == nil)
    #expect(request.command == .renameCircuit(id, "main"))
  }
}

@Suite("Rename Circuit — the command the menu sends, through a real host")
struct CircuitRenameThroughHostTests {

  /// The join the suite exists for: the exact value `CircuitRenameRequest` hands to
  /// `EditorModel.perform` is a command a real host honours, and the result is undoable. Building
  /// the command by hand here would test `LogisimFileProjectHost` twice and the affordance zero
  /// times.
  @Test("the request's command renames the circuit and lands on the undo stack")
  @MainActor
  func requestCommandRenamesThroughTheHost() throws {
    let host = try newHost()
    let circuit = try #require(host.file.mainCircuit)
    let id = try mainCircuitID(host)

    let request = CircuitRenameRequest(id: id, originalName: "main", proposedName: "top_level")
    let command = try #require(request.command)
    try host.perform(command)

    #expect(circuit.name == "top_level")
    #expect(host.outline.circuits.first?.name == "top_level")
    #expect(host.undoStatus.undoStack.first == "Rename Circuit")

    try host.perform(.undo)
    #expect(circuit.name == "main")
  }

  /// Upstream refuses a duplicate in `LogisimFile.circuitChanged` (4.1.0 jar, `javap -c`) with
  /// `circuitNameExists`. Here the host throws instead, and `EditorModel.perform` turns the throw
  /// into `transientError` plus a visible issue, so the refusal reaches the user rather than
  /// vanishing, which is the property being pinned.
  @Test("a conflicting name is refused by the host, visibly, and costs no undo entry")
  @MainActor
  func conflictingNameIsRefusedByTheHost() throws {
    let host = try newHost()
    try host.perform(.addCircuit)
    let depth = host.undoStatus.undoStack.count
    let id = try #require(host.outline.circuits.first { $0.name == "circuit_1" }?.id)

    let request = CircuitRenameRequest(id: id, originalName: "circuit_1", proposedName: "main")
    let command = try #require(request.command)

    let model = EditorModel(host: host)
    model.perform(command)

    // Not renamed, and the user was told.
    #expect(host.file.circuits.map(\.name) == ["main", "circuit_1"])
    #expect(model.transientError != nil)
    #expect(model.issues.contains { $0.title == "Command unavailable" })
    #expect(host.undoStatus.undoStack.count == depth)
  }

  /// THE DEFECT THIS TEST WAS WRITTEN TO DOCUMENT IS NOW FIXED, and the test moved with the fix.
  ///
  /// It used to assert the opposite of everything below: sending `.renameCircuit(id, "")` past the
  /// shell's guard threw nothing, reported nothing, left the name unchanged: `circuitNameConflicts`
  /// returns false for `""`, faithfully, because upstream's `isNameInUse` does too: and still
  /// pushed a "Rename Circuit" entry onto the undo stack for an edit that did not happen. It said
  /// so in its own doc: *"if this test ever starts throwing, the host grew a check and the shell's
  /// can be reconsidered."* The host grew the check (`LogisimFileProjectHost.renameCircuit`), so
  /// this now pins the fix instead of the defect.
  ///
  /// The shell's guard is kept. It is no longer the only defence, but it stops a pointless
  /// round trip through the command layer and keeps the alert's Rename button correctly disabled.
  @Test("an empty rename is refused by the host, reported, and pushes no undo entry")
  @MainActor
  func renameGuardIsLoadBearing() throws {
    let host = try newHost()
    let id = try mainCircuitID(host)
    let depth = host.undoStatus.undoStack.count

    let model = EditorModel(host: host)
    // Deliberately bypassing `CircuitRenameRequest`, which is what makes this a probe of the HOST.
    model.perform(.renameCircuit(id, ""))

    #expect(host.file.mainCircuit?.name == "main")
    #expect(model.transientError != nil, "the empty rename was refused silently")
    #expect(model.issues.contains { $0.title == "Command unavailable" })
    #expect(
      host.undoStatus.undoStack.count == depth,
      "a refused rename still grew the undo stack: \(host.undoStatus.undoStack)")

    // …and the guarded path still sends nothing at all, so it never reaches the host.
    #expect(
      CircuitRenameRequest(id: id, originalName: "main", proposedName: "").command == nil)
  }

  /// Whitespace-only is the same case, and it is asserted separately because the host TRIMS rather
  /// than syntax-checks: upstream's literal `isEmpty()` lets `"   "` through and `SyntaxChecker`
  /// kills it one line later, and that checker is excluded from this port under D9. Trimming
  /// reproduces 4.1.0's accepted SET without reproducing its line of code, but only if something
  /// asserts the whitespace case, which nothing did before.
  @Test("a whitespace-only rename is refused by the host too")
  @MainActor
  func whitespaceOnlyRenameIsRefusedByTheHost() throws {
    let host = try newHost()
    let id = try mainCircuitID(host)
    let depth = host.undoStatus.undoStack.count

    let model = EditorModel(host: host)
    model.perform(.renameCircuit(id, "   "))

    #expect(host.file.mainCircuit?.name == "main")
    #expect(model.transientError != nil, "a whitespace-only name was accepted by the host")
    #expect(host.undoStatus.undoStack.count == depth)
  }

  /// Why the menu item is hidden for a VHDL entity rather than merely disabled: the command has no
  /// arm for one. `LogisimFileProjectHost`'s `.renameCircuit` opens
  /// `guard let circuit = handles.circuits[id] else { return }`, and `ProjectHandles` keeps VHDL
  /// entities in a *different* dictionary; `record(vhdl:)` writes only `vhdl[id]`, never
  /// `circuits[id]` (`ProjectOutlineBuilder.swift:63-67`). So a VHDL entity's `CircuitID` misses
  /// that guard and the command does nothing at all. 4.1.0 splits the same way:
  /// `Popups$VhdlPopup` (jar, `javap -p`) has only `edit` and `remove`.
  ///
  /// Asserted through an id the host cannot resolve rather than through a real entity, because
  /// `.addVhdlEntity` is `ProjectHostError.notImplemented` in this host; there is no way to make
  /// one here. That is a narrower claim than "a VHDL entity is not renamed", and it is the
  /// narrower one on purpose: it exercises the exact `guard` line, and the step it does not cover
  /// (that a VHDL id is such an id) is the structural fact cited above rather than a behaviour.
  @Test("renameCircuit is a silent no-op for an id handles.circuits does not resolve")
  @MainActor
  func renamingAnUnresolvableCircuitDoesNothing() throws {
    let host = try newHost()
    let depth = host.undoStatus.undoStack.count
    let names = host.file.circuits.map(\.name)
    // No circuit was ever recorded under this handle.
    let stranger = CircuitID(rawValue: .max)
    #expect(host.outline.circuits.contains { $0.id == stranger } == false)

    try host.perform(.renameCircuit(stranger, "renamed"))

    #expect(host.file.circuits.map(\.name) == names)
    #expect(host.undoStatus.undoStack.count == depth)
  }
}
