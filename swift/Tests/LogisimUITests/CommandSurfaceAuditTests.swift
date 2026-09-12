// LogisimUITests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import Foundation
import LogisimFile
import Testing
import UniformTypeIdentifiers

@testable import LogisimUI

private let commandAuditFixture = """
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
    <circuit name="beta">
      <comp lib="1" loc="(100,120)" name="Pin"/>
      <comp lib="2" loc="(180,120)" name="NOT Gate"/>
    </circuit>
  </project>
  """

@Suite("ProjectCommand surface audit")
struct CommandSurfaceAuditTests {
  private enum Bucket: String { case wired = "WIRED", refused = "HONESTLY REFUSED", inert = "INERT", other = "OTHER", untestable = "UNTESTABLE" }

  private struct Probe {
    var name: String
    var command: ProjectCommand
    var prepare: @MainActor (EditorModel) -> Void = { _ in }
    var exportWithoutPanel = false
    var printWithoutPanel = false
  }

  private struct Result {
    var name: String
    var canPerform: Bool
    var outcome: String
    var bucket: Bucket
  }

  @MainActor
  private func makeModel() throws -> EditorModel {
    let host = try LogisimFileProjectHostFactory().openProject(
      data: Data(commandAuditFixture.utf8), url: nil,
      contentType: LogisimDocumentType.circuit)
    return EditorModel(host: host)
  }

  @Test("CommandSurfaceAudit runs and reports all 63 ProjectCommand cases")
  @MainActor
  func commandSurfaceAudit() throws {
    let selectComponents: @MainActor (EditorModel) -> Void = { model in
      model.perform(.selectAll)
    }
    let seedUndo: @MainActor (EditorModel) -> Void = { $0.perform(.addCircuit) }
    let seedRedo: @MainActor (EditorModel) -> Void = {
      $0.perform(.addCircuit)
      $0.perform(.undo)
    }
    let seedPaste: @MainActor (EditorModel) -> Void = {
      $0.perform(.selectAll)
      $0.perform(.copy)
    }
    /// `.analyzeCircuit`'s real presenter ends in `NSApp.activate()`, which
    /// `AnalyzerWindowController.show`'s own comment forbids a test from reaching; the suite
    /// would steal focus from whoever is at the keyboard, and it would leave a window open for
    /// the rest of the run. Stubbing it is not weakening the probe: what this audit measures is
    /// whether `perform` still reports the command unimplemented, and the stub cannot make that
    /// answer come out right. `AnalyzeCommandTests` asserts what reaches the presenter.
    let stubAnalyzer: @MainActor (EditorModel) -> Void = { $0.analyzerPresenter = { _, _ in } }
    /// Same reason as `stubAnalyzer`: the real presenter ends in `NSApp.activate()`. The command
    /// audit only needs to know whether `.circuitStatistics` still reports itself unimplemented;
    /// `CircuitStatisticsCommandTests` asserts the report that reaches this hand-off.
    let stubStatistics: @MainActor (EditorModel) -> Void = {
      $0.circuitStatisticsPresenter = { _ in }
    }

    let probes: [Probe] = [
      Probe(name: "newProject", command: .newProject),
      Probe(name: "openProject", command: .openProject),
      Probe(name: "mergeProject", command: .mergeProject),
      Probe(name: "closeProject", command: .closeProject),
      Probe(name: "save", command: .save, prepare: seedUndo),
      Probe(name: "saveAs", command: .saveAs),
      Probe(name: "revert", command: .revert, prepare: seedUndo),
      Probe(name: "exportProject", command: .exportProject),
      Probe(name: "extractRunProject", command: .extractRunProject),
      Probe(name: "exportImage", command: .exportImage, exportWithoutPanel: true),
      Probe(name: "print", command: .print, printWithoutPanel: true),
      Probe(name: "undo", command: .undo, prepare: seedUndo),
      Probe(name: "redo", command: .redo, prepare: seedRedo),
      Probe(name: "clearUndoHistory", command: .clearUndoHistory, prepare: seedUndo),
      Probe(name: "cut", command: .cut, prepare: selectComponents),
      Probe(name: "copy", command: .copy, prepare: selectComponents),
      Probe(name: "paste", command: .paste, prepare: seedPaste),
      Probe(name: "delete", command: .delete, prepare: selectComponents),
      Probe(name: "duplicate", command: .duplicate, prepare: selectComponents),
      Probe(name: "selectAll", command: .selectAll),
      Probe(name: "deselectAll", command: .deselectAll, prepare: selectComponents),
      Probe(name: "raise", command: .raise, prepare: selectComponents),
      Probe(name: "lower", command: .lower, prepare: selectComponents),
      Probe(name: "raiseToTop", command: .raiseToTop, prepare: selectComponents),
      Probe(name: "lowerToBottom", command: .lowerToBottom, prepare: selectComponents),
      Probe(name: "addControlPoint", command: .addControlPoint),
      Probe(name: "removeControlPoint", command: .removeControlPoint),
      Probe(name: "rotateSelection(1)", command: .rotateSelection(quarterTurns: 1), prepare: selectComponents),
      Probe(name: "mirrorSelectionHorizontally", command: .mirrorSelectionHorizontally, prepare: selectComponents),
      Probe(name: "mirrorSelectionVertically", command: .mirrorSelectionVertically, prepare: selectComponents),
      Probe(name: "addCircuit", command: .addCircuit),
      Probe(name: "addVhdlEntity", command: .addVhdlEntity),
      Probe(name: "importVhdl", command: .importVhdl),
      Probe(name: "removeCircuit(beta)", command: .removeCircuit(CircuitID(rawValue: 0))),
      Probe(name: "renameCircuit(alpha,audited)", command: .renameCircuit(CircuitID(rawValue: 0), "audited")),
      Probe(name: "setMainCircuit(beta)", command: .setMainCircuit(CircuitID(rawValue: 0))),
      Probe(name: "moveCircuitUp(beta)", command: .moveCircuitUp(CircuitID(rawValue: 0))),
      Probe(name: "moveCircuitDown(alpha)", command: .moveCircuitDown(CircuitID(rawValue: 0))),
      Probe(name: "setCurrentCircuit(beta)", command: .setCurrentCircuit(CircuitID(rawValue: 0))),
      Probe(name: "editLayout", command: .editLayout),
      Probe(name: "editAppearance", command: .editAppearance),
      Probe(name: "toggleLayoutAppearance", command: .toggleLayoutAppearance),
      Probe(name: "revertAppearance", command: .revertAppearance),
      Probe(name: "analyzeCircuit", command: .analyzeCircuit, prepare: stubAnalyzer),
      Probe(name: "circuitStatistics", command: .circuitStatistics, prepare: stubStatistics),
      Probe(name: "projectOptions", command: .projectOptions),
      Probe(name: "loadBuiltinLibrary", command: .loadBuiltinLibrary),
      Probe(name: "loadLogisimLibrary", command: .loadLogisimLibrary),
      Probe(name: "loadJarLibrary", command: .loadJarLibrary),
      Probe(name: "unloadLibrary(real)", command: .unloadLibrary(LibraryID(rawValue: 0))),
      Probe(name: "reloadLibrary(real)", command: .reloadLibrary(LibraryID(rawValue: 0))),
      Probe(name: "selectTool(real)", command: .selectTool(ToolID(rawValue: 0))),
      Probe(name: "revealComponent(real)", command: .revealComponent(ComponentID(rawValue: 0))),
      Probe(name: "openLogWindow", command: .openLogWindow),
      Probe(name: "openTestWindow", command: .openTestWindow),
      Probe(name: "openChronogram", command: .openChronogram),
      Probe(name: "openAssemblyWindow", command: .openAssemblyWindow),
      Probe(name: "openFpgaWindow", command: .openFpgaWindow),
      Probe(name: "openUserGuide", command: .openUserGuide),
      Probe(name: "openLibraryReference", command: .openLibraryReference),
      Probe(name: "openTutorial", command: .openTutorial),
      Probe(name: "openProjectWebsite", command: .openProjectWebsite),
      Probe(name: "showLicence", command: .showLicence),
    ]
    #expect(probes.count == 63, "the audit inventory must remain exhaustive")

    var results: [Result] = []
    for probe in probes {
      let model = try makeModel()
      probe.prepare(model)
      let alpha = try #require(model.outline.circuits.first(where: { $0.name == "alpha" })?.id)
      let beta = try #require(model.outline.circuits.first(where: { $0.name == "beta" })?.id)
      let tool = try #require(
        (model.outline.editingTools + model.outline.libraries.flatMap(\.tools)).first?.id)
      let library = try #require(model.outline.libraries.first?.id)
      var command = probe.command
      switch probe.name {
      case "removeCircuit(beta)": command = .removeCircuit(beta)
      case "renameCircuit(alpha,audited)": command = .renameCircuit(alpha, "audited")
      case "setMainCircuit(beta)": command = .setMainCircuit(beta)
      case "moveCircuitUp(beta)": command = .moveCircuitUp(beta)
      case "moveCircuitDown(alpha)": command = .moveCircuitDown(alpha)
      case "setCurrentCircuit(beta)": command = .setCurrentCircuit(beta)
      case "unloadLibrary(real)": command = .unloadLibrary(library)
      case "reloadLibrary(real)": command = .reloadLibrary(library)
      case "selectTool(real)": command = .selectTool(tool)
      case "revealComponent(real)":
        model.perform(.selectAll)
        command = .revealComponent(try #require(model.selection.componentIDs.first))
      default: break
      }
      let canPerform = model.canPerform(command)
      let beforeIssues = model.issues.count
      let beforeError = model.transientError
      var outcome = "returned"

      if probe.exportWithoutPanel {
        var exportedJob: ExportImageJob?
        CircuitExportImageCommand.withRunnerForTesting(
          { job in
            exportedJob = job
            return true
          },
          body: {
            model.perform(command)
          })
        if let exportedJob {
          outcome = "export runner received \(exportedJob.circuits.count) circuit(s)"
        } else if model.issues.count > beforeIssues {
          outcome = model.issues.last?.detail ?? "issued an error without detail"
        } else if model.transientError != beforeError, let error = model.transientError {
          outcome = error
        }
      } else if probe.printWithoutPanel {
        let job = model.printJob()
        outcome = "printJob returned \(job.circuits.count) page(s); modal deliberately bypassed"
      } else {
        model.perform(command)
        if model.issues.count > beforeIssues {
          outcome = model.issues.last?.detail ?? "issued an error without detail"
        } else if model.transientError != beforeError, let error = model.transientError {
          outcome = error
        }
      }

      let bucket: Bucket
      if !canPerform {
        bucket = .refused
      } else if outcome.hasSuffix(" is not implemented yet.") {
        bucket = .inert
      } else if outcome == "returned" || probe.exportWithoutPanel || probe.printWithoutPanel {
        bucket = .wired
      } else {
        bucket = .other
      }
      results.append(Result(name: probe.name, canPerform: canPerform, outcome: outcome, bucket: bucket))
    }

    let counts = Dictionary(grouping: results, by: \.bucket).mapValues(\.count)
    print("COMMAND SURFACE AUDIT COUNTS")
    for bucket in [Bucket.wired, .refused, .inert, .other, .untestable] {
      print("\(bucket.rawValue): \(counts[bucket, default: 0])")
    }
    print("COMMAND SURFACE AUDIT TABLE")
    print("case | canPerform | perform outcome | classification")
    for result in results {
      print("\(result.name) | \(result.canPerform) | \(result.outcome) | \(result.bucket.rawValue)")
    }

    let exportImage = try #require(results.first { $0.name == "exportImage" })
    let undo = try #require(results.first { $0.name == "undo" })
    #expect(exportImage.bucket == .wired, "exportImage did not reach its non-modal export runner")
    #expect(undo.bucket == .wired, "known-wired calibration case was misclassified")
    print("CALIBRATION: exportImage=WIRED, undo=WIRED — PASS")

    // ── THE PIN, without which this file is documentation rather than a gate ──────────────────
    //
    // As landed, this audit asserted only that the inventory is 63 and that two calibration cases
    // classify correctly. Both are necessary and neither is sufficient: a WIRED command silently
    // regressing to INERT left it green, which is the exact failure the audit exists to detect.
    // It measured the surface and gated nothing.
    //
    // So the inert set is pinned by name. Fixing a command FAILS this test, on purpose; the
    // green path is to delete its name from this list in the same commit as the fix, which is
    // what makes the list a running count of the remaining work rather than a stale comment.
    // Same discipline as `tools/seamcheck-baseline.txt` and `deadseam --selftest`.
    //
    // Some of these are reachable from a real control and some have no producer. Both stay pinned:
    // if an unused enum case ever acquires a producer it becomes a live defect that day, and this
    // list is what will say so.
    //
    // **The five help commands are a third category, and they must not be "fixed" the way the
    // three view commands below were.** `openUserGuide`, `openLibraryReference`, `openTutorial`,
    // `openProjectWebsite` and `showLicence` have no producer *by design*: `HelpMenuItems` in
    // `AppCommands.swift` opens the URLs itself and deliberately touches no `ProjectHost`, because
    // GPLv3 §5(d) and D10 require the licence and the notices to be reachable with **no document
    // open**, and `@FocusedValue(\.editorModel)` is nil then. Routing Help through
    // `EditorModel.perform` would move all five behind an open window and lose a licence
    // obligation to tidiness. They stay pinned and stay unproduced; the honest fix is to delete
    // the five enum cases, which needs `DomainTypes.swift`.
    //
    // **Greying an item out is NOT an available disposition for the rest.** D11 was rewritten on
    // 2026-09-08 by owner decision and names this exact temptation: *"neither is greying a menu
    // item out and calling it honest; a greyed item is a missing feature with better manners"*,
    // and it names `exportProject`, `extractRunProject`, `mergeProject` and `openFpgaWindow`
    // specifically as commands earlier boards proposed refusing from `canPerform`. They get
    // ported. So a name leaving this list must leave it by becoming WIRED, and the
    // `notImplemented` banner a click produces today is the correct interim state; it is a
    // to-do a user can read, not a lie.
    let expectedInert: Set<String> = [
      "newProject", "openProject", "mergeProject", "closeProject", "save", "saveAs", "revert",
      "exportProject", "extractRunProject", "copy", "paste", "duplicate",
      // `raise`, `lower`, `raiseToTop` and `lowerToBottom` left this list on 2026-09-09 and moved
      // to HONESTLY REFUSED, which is where 4.1.0 puts them: `LayoutEditHandler.computeEnabled()`
      // sets all six ordering/control-point items to `iconst_0` and their handler bodies are
      // `0: return` (javap on logisim-evolution-4.1.0-all.jar). They were INERT here because
      // `LogisimFileProjectHost.canPerform` answered `!selection.isEmpty` for four of the six
      // while correctly refusing the other two. `EditorModel.canPerform` now reads the one rule in
      // `SelectionEditHandler.isDisabledInLayoutMode`. They are NOT wired and must not be: see
      // `EditorModel.layoutModeEditCommand`; they belong to the appearance editor.
      //
      // `rotateSelection` and the two mirrors stay pinned, and stay pinned for a reason worth
      // writing down: **4.1.0 has no such commands.** `LogisimMenuBar.EDIT_ITEMS` is exactly
      // CUT/COPY/PASTE/DELETE/DUPLICATE/SELECT_ALL/RAISE/LOWER/RAISE_TOP/LOWER_BOTTOM/
      // ADD_CONTROL/REMOVE_CONTROL, and the jar contains no mirror or rotate class at all. The
      // enum cases and the Arrange menu items above them are port inventions.
      "rotateSelection(1)",
      "mirrorSelectionHorizontally", "mirrorSelectionVertically", "addVhdlEntity", "importVhdl",
      //
      // `editLayout`, `editAppearance`, `toggleLayoutAppearance` and `analyzeCircuit` left this
      // list on 2026-09-12, and the first three are the clearest illustration of what the list is
      // for. All four had a WORKING menu item in `AppCommands.swift` that bypassed the command:
      // the three view items assigned `model.centreView` inline and Analyze Circuit… reached
      // `AnalyzerWindowController` directly. So the feature worked, the command lied, and the lie
      // was cashed in by the *second* producer, `ExplorerSidebar.swift:255` sends
      // `.analyzeCircuit` from a circuit's right-click menu, which therefore answered "Command
      // unavailable, analyzeCircuit is not implemented yet." `EditorModel.perform` intercepts all
      // four now (shell state and a process-wide window, neither of which the host may own) and
      // both menus route through the command, so there is one path instead of two.
      //
      // Read the table above rather than assuming all four land in WIRED: `editLayout` reports
      // HONESTLY REFUSED here, and that is the correct answer for the state this fixture is in.
      // `computeEnabled()` ties EDIT_LAYOUT to `getEditorView().equals("appearance")`, and a model
      // opens on `.layout`, so 4.1.0 greys Edit Circuit Layout at exactly this moment too.
      // `ViewModeCommandTests` drives the command from `.appearance`, where it is enabled.
      //
      // `reloadLibrary(real)` left it the same day and did NOT become WIRED; it became HONESTLY
      // REFUSED, because every library in this fixture is a built-in. That is 4.1.0's answer, not
      // a dodge: `Popups$LibraryPopup`'s constructor disassembles to
      // `reload.setEnabled(canUnload && lib instanceof LoadedLibrary)`, and a built-in has no
      // descriptor to re-read. `LibraryReloadCommandTests` drives the WIRED half against a real
      // `.circ` library on disk, which is the only way to reach it.
      //
      // Which means **this audit cannot gate the reload wiring, and that was measured rather than
      // assumed.** Deleting the whole `.reloadLibrary` arm from `LogisimFileProjectHost.perform`
      // leaves this test GREEN: `canPerform` still answers false for a built-in, and the bucket is
      // decided by `canPerform` before the outcome is ever read. Making `canPerform` answer true
      // unconditionally leaves it green too; the outcome then ends in "is not available here",
      // which buckets as OTHER, and this pin looks only at INERT. So `LibraryReloadCommandTests`
      // is the gate for this command, not a supplement to this file. Any command whose enablement
      // is state-dependent will have the same hole, and the fixture is the reason: two circuits
      // and three built-in libraries cannot reach a `LoadedLibrary` at all.
      //
      // `circuitStatistics` left this list on 2026-09-12 and became WIRED. The presenter is
      // stubbed above because the real one orders an AppKit window front; the payload is checked
      // in `CircuitStatisticsCommandTests`. Upstream enables it in `MainMenuListener` and calls
      // `StatisticsDialog.show(file, circuit)`, so a banner saying "not implemented yet" was a
      // live student-facing miss rather than a future feature.
      //
      // `loadBuiltinLibrary` and `loadLogisimLibrary` left the INERT set the same day and moved to
      // HONESTLY REFUSED. That is a divergence from upstream's enabled menu, but not a D11 dodge:
      // 4.1.0 immediately opens a chooser and constructs `LogisimFileActions.LoadLibraries`, the
      // undoable action that resolves duplicates, base-library promotion, conformity and tool-name
      // conflicts. This port has only the low-level loader today. Until that action lands, a
      // disabled item plus a bypass error naming `LoadLibraries` is truer than a click that says
      // nothing or a non-undoable direct load.
      "projectOptions",
      "openLogWindow", "openTestWindow", "openChronogram",
      "openAssemblyWindow", "openFpgaWindow", "openUserGuide", "openLibraryReference",
      "openTutorial", "openProjectWebsite", "showLicence",
    ]
    let actualInert = Set(results.filter { $0.bucket == .inert }.map(\.name))
    #expect(
      actualInert == expectedInert,
      """
      the inert set moved. Newly inert (a REGRESSION — a working command stopped working):
        \(actualInert.subtracting(expectedInert).sorted().joined(separator: ", "))
      No longer inert (a FIX — delete these from `expectedInert` in the same commit):
        \(expectedInert.subtracting(actualInert).sorted().joined(separator: ", "))
      """)
  }
}
