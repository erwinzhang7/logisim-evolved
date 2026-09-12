// LogisimUITests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ============================================================================
// THE SIX COMMANDS THAT BELONG TO THE APPEARANCE EDITOR.
//
// `CommandSurfaceAuditTests` measures the whole 63-case surface and pins the inert set, but it
// runs each command once against a fixture and buckets the result. That is the right shape for a
// census and the wrong shape for a *rule*: the audit would stay green if `canPerform` returned
// false for the wrong reason, or if the interception moved somewhere a real menu item cannot
// reach. This file gates the rule itself, in both directions.
//
// Every test below reddens if a specific line is deleted. The mapping is spelled out on each,
// because a test whose failure mode nobody has checked is a test nobody can trust.
// ============================================================================

import Foundation
import LogisimFile
import Testing
import UniformTypeIdentifiers

@testable import LogisimUI

private let fixture = """
  <?xml version="1.0" encoding="UTF-8" standalone="no"?>
  <project source="4.1.0" version="1.0">
    <lib desc="#Base" name="0"/>
    <lib desc="#Wiring" name="1"/>
    <lib desc="#Gates" name="2"/>
    <main name="alpha"/>
    <circuit name="alpha">
      <comp lib="1" loc="(80,80)" name="Pin"/>
      <comp lib="2" loc="(160,80)" name="AND Gate"/>
      <wire from="(80,80)" to="(120,80)"/>
    </circuit>
  </project>
  """

@Suite("Appearance-editor commands in layout mode")
struct LayoutModeEditCommandTests {

  @MainActor
  private func makeModel() throws -> EditorModel {
    let host = try LogisimFileProjectHostFactory().openProject(
      data: Data(fixture.utf8), url: nil, contentType: LogisimDocumentType.circuit)
    return EditorModel(host: host)
  }

  /// The six, as `ProjectCommand`, paired with the `SelectionEditCommand` they must map to.
  private static let six: [(ProjectCommand, SelectionEditCommand)] = [
    (.raise, .raise),
    (.lower, .lower),
    (.raiseToTop, .raiseTop),
    (.lowerToBottom, .lowerBottom),
    (.addControlPoint, .addControlPoint),
    (.removeControlPoint, .removeControlPoint),
  ]

  // MARK: - The rule

  /// Reddens if `SelectionEditHandler.isDisabledInLayoutMode` stops returning `true` for any of
  /// the six, which is the single source of the 4.1.0 decision.
  ///
  /// Stated over `CaseIterable` rather than as six literals so that adding a case to
  /// `SelectionEditCommand` without classifying it is a compile error in the switch and a
  /// failure here, not a silent default.
  @Test("isDisabledInLayoutMode matches LayoutEditHandler.computeEnabled for all 12 commands")
  func ruleCoversEveryCommand() {
    let expectedDisabled: Set<SelectionEditCommand> = [
      .raise, .lower, .raiseTop, .lowerBottom, .addControlPoint, .removeControlPoint,
    ]
    for command in SelectionEditCommand.allCases {
      #expect(
        SelectionEditHandler.isDisabledInLayoutMode(command)
          == expectedDisabled.contains(command),
        "\(command.rawValue) is on the wrong side of LayoutEditHandler.computeEnabled")
    }
    #expect(SelectionEditCommand.allCases.count == 12, "the LogisimMenuBar.EDIT_ITEMS inventory")
  }

  /// The instance path, `LayoutEditHandler.computeEnabled()` asked one command at a time, must
  /// read the same rule rather than restating it.
  ///
  /// Reddens if `isEnabled`'s ordering arm goes back to a bare `return false`: that would pass
  /// today and drift the moment the static changes, which is the exact split this change removed.
  /// A `nil` project and selection is deliberate: upstream consults neither for these six, so a
  /// handler with nothing attached must still answer `false`.
  @Test("SelectionEditHandler.isEnabled defers to the shared rule, with no project attached")
  @MainActor
  func instanceDefersToRule() {
    let handler = SelectionEditHandler(project: nil, selection: nil)
    for command in SelectionEditCommand.allCases
    where SelectionEditHandler.isDisabledInLayoutMode(command) {
      #expect(handler.isEnabled(command) == false, "\(command.rawValue) must be disabled")
    }
  }

  // MARK: - The reader

  /// Reddens if the `layoutModeEditCommand` interception is deleted from `EditorModel.canPerform`:
  /// `LogisimFileProjectHost.canPerform` answers `!selection.isEmpty` for four of the six, so with
  /// a selection in hand it returns `true` and this fails on `raise`, `lower`, `raiseToTop` and
  /// `lowerToBottom`.
  ///
  /// **The selection is the point.** Asserting `false` on an empty selection would pass against
  /// the unfixed host and gate nothing; the probe has to put the host in the state where its
  /// wrong rule says yes.
  @Test("canPerform refuses all six even with a full selection")
  @MainActor
  func canPerformRefusesWithSelection() throws {
    let model = try makeModel()
    model.perform(.selectAll)
    #expect(!model.selection.componentIDs.isEmpty, "the probe needs a non-empty selection")
    #expect(
      model.canPerform(.delete),
      "calibration: a genuinely selection-dependent command must be enabled here")

    for (command, _) in Self.six {
      #expect(model.canPerform(command) == false, "\(command) must be refused in layout mode")
    }
  }

  /// The mapping itself. Reddens if a case is dropped from `layoutModeEditCommand`'s switch,
  /// which is how one of the six would quietly fall back to the host's answer.
  @Test("layoutModeEditCommand maps exactly the six, and nothing else")
  @MainActor
  func mappingIsExact() {
    for (command, expected) in Self.six {
      #expect(EditorModel.layoutModeEditCommand(for: command) == expected, "\(command)")
    }
    // The commands that must NOT be intercepted, because their enablement is a real fact about
    // the document and belongs to whoever holds the file.
    for command: ProjectCommand in [.cut, .copy, .paste, .delete, .duplicate, .selectAll, .undo] {
      #expect(EditorModel.layoutModeEditCommand(for: command) == nil, "\(command)")
    }
  }

  // MARK: - What a click does

  /// The half the audit cannot see. Reddens if the interception is deleted from
  /// `EditorModel.perform`: the command reaches the host, throws `notImplemented`, and the shell
  /// appends a `.warning` titled "Command unavailable", which is the defect being fixed, not a
  /// pass.
  ///
  /// Asserting on the severity and title rather than merely "an issue appeared" is what makes the
  /// two outcomes distinguishable; both paths append exactly one issue.
  @Test("a click on a layout-mode-disabled item explains itself instead of erroring")
  @MainActor
  func performExplainsRatherThanErroring() throws {
    for (command, _) in Self.six {
      let model = try makeModel()
      model.perform(.selectAll)
      let before = model.issues.count

      model.perform(command)

      #expect(model.transientError == nil, "\(command) must not leave an error banner")
      #expect(model.issues.count == before + 1, "\(command) must say exactly one thing")
      let issue = try #require(model.issues.last)
      #expect(issue.severity == .info, "\(command) reported \(issue.severity), not .info")
      #expect(
        issue.title != "Command unavailable",
        "\(command) still reaches the host's notImplemented arm")
      #expect(
        issue.detail?.contains("appearance editor") == true,
        "\(command) must name where the command does work")
    }
  }

  /// Nothing was mutated on the way past. The six are refused, and a refusal that dirties the
  /// document or pushes an undo entry would be worse than the banner it replaced.
  @Test("refusing the six leaves the document and the undo stack untouched")
  @MainActor
  func refusalIsInert() throws {
    let model = try makeModel()
    model.perform(.selectAll)
    let selection = model.selection
    #expect(!model.isDirty, "the fixture opens clean")

    for (command, _) in Self.six { model.perform(command) }

    #expect(!model.isDirty, "a refused command must not dirty the file")
    #expect(model.undoStatus.undoStack.isEmpty, "a refused command must not be undoable")
    #expect(model.selection == selection, "a refused command must not disturb the selection")
  }

  // MARK: - The port inventions, held in place

  /// Rotate and the two mirrors have **no counterpart in 4.1.0**: `LogisimMenuBar.EDIT_ITEMS`
  /// contains twelve items and none of them is a rotate or a mirror, and the shipping jar has no
  /// mirror class at all. They are not part of the six and must not be swept in with them; if
  /// they ever acquire a real implementation it has to be a deliberate, documented divergence,
  /// not a side effect of this interception widening.
  ///
  /// Reddens if someone adds them to `layoutModeEditCommand`, which would grey a menu item on a
  /// fabricated 4.1.0 citation.
  @Test("rotate and mirror are not swept into the appearance-editor rule")
  @MainActor
  func inventionsAreNotIntercepted() {
    let inventions: [ProjectCommand] = [
      .rotateSelection(quarterTurns: 1), .rotateSelection(quarterTurns: -1),
      .mirrorSelectionHorizontally, .mirrorSelectionVertically,
    ]
    for command in inventions {
      #expect(EditorModel.layoutModeEditCommand(for: command) == nil, "\(command)")
    }
  }
}
