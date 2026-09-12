// AnalyzeExpressionTabTests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// BOARD #92; CAN A USER ACTUALLY TYPE A BOOLEAN EXPRESSION INTO ANALYZE?
//
// The model half was already gated and already passing.
// `Tests/LogisimAnalyzeTests/ExpressionEntryTests.swift` replays `ExpressionTab.importData`
// (ExpressionTab.java:485-538) against a recorded 4.1.0 transcript, parse, route, strip,
// commit, over eleven inputs, against a HAND-BUILT `AnalyzerModel`. It proves the composition
// is right. It cannot prove anybody can reach it, and nobody could: the port's analyzer window
// had three tabs and none of them had a text field.
//
// So this suite deliberately does NOT re-test the model. Every assertion below starts from a
// real `.circ` file, goes through `AnalyzerPresentation.analyze`, the closure the Analyze menu
// item runs, and then through `presentation.expressionEntry`, which is the object the tab's
// SwiftUI is bound to. Nothing here constructs an `AnalyzerModel` or calls `Parser` to decide
// what to expect. Delete the tab, the entry model, or the `enableUpdates()` line and these turn
// red; the LogisimAnalyze suite stays green, which is exactly the gap board #92 named.
//
// ── The oracle ──────────────────────────────────────────────────────────────────────────────
//
// `theJarTranscriptReplaysThroughTheTab` compares against the SAME 4.1.0 transcript
// `ExpressionEntryTests` records, verbatim, including the row numbers. Regenerating it is
// documented there (`ExprTabProbe.java`, run against
// /Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar). The
// starting state matches because a circuit whose output pins are unconnected tabulates to an
// all-don't-care column, which is what the probe's fresh `AnalyzerModel` starts from too, so
// the eleven imports land on identical ground and the twelve printed lines are comparable line
// for line.
//
// Everything else is measured against the jar indirectly, through that transcript, or is a
// property of the port measured on 2026-09-06 and quoted in place.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimAnalyze
import LogisimFile
import LogisimKernel
import LogisimStd
import SwiftUI
import Testing

@testable import LogisimUI

// MARK: - Fixtures

/// Three input pins and three output pins, nothing wired. Pin order is by vertical position
/// (`Analyze.getPinLabels` sorts every pin top-to-bottom before splitting inputs from outputs),
/// so the y coordinates give `a b c` then `q r s`.
///
/// The outputs are deliberately undriven: every column tabulates to don't-care, which is the
/// state the jar probe's fresh `AnalyzerModel` is in, and it makes the recorded transcript
/// directly comparable. It is also the honest starting point for this feature; the reason to
/// type an expression is that the circuit does not compute it yet.
private let threeByThreeCirc = """
  <?xml version="1.0" encoding="UTF-8" standalone="no"?>
  <project source="4.1.0" version="1.0">
    <lib desc="#Wiring" name="0"/>
    <lib desc="#Gates" name="1"/>
    <main name="entry"/>
    <options>
      <a name="gateUndefined" val="ignore"/>
      <a name="simlimit" val="1000"/>
      <a name="simrand" val="0"/>
    </options>
    <circuit name="entry">
      <a name="circuit" val="entry"/>
      <comp lib="0" loc="(80,100)" name="Pin">
        <a name="label" val="a"/>
      </comp>
      <comp lib="0" loc="(80,140)" name="Pin">
        <a name="label" val="b"/>
      </comp>
      <comp lib="0" loc="(80,180)" name="Pin">
        <a name="label" val="c"/>
      </comp>
      <comp lib="0" loc="(300,220)" name="Pin">
        <a name="facing" val="west"/>
        <a name="label" val="q"/>
        <a name="output" val="true"/>
      </comp>
      <comp lib="0" loc="(300,260)" name="Pin">
        <a name="facing" val="west"/>
        <a name="label" val="r"/>
        <a name="output" val="true"/>
      </comp>
      <comp lib="0" loc="(300,300)" name="Pin">
        <a name="facing" val="west"/>
        <a name="label" val="s"/>
        <a name="output" val="true"/>
      </comp>
    </circuit>
  </project>
  """

/// The same, with ONE output: `importData`'s `if (table.getRowCount() == 1) idx = 0;` branch,
/// which is the only way a bare non-assignment commits with nothing selected.
private let oneOutputCirc = """
  <?xml version="1.0" encoding="UTF-8" standalone="no"?>
  <project source="4.1.0" version="1.0">
    <lib desc="#Wiring" name="0"/>
    <lib desc="#Gates" name="1"/>
    <main name="one"/>
    <options>
      <a name="gateUndefined" val="ignore"/>
      <a name="simlimit" val="1000"/>
      <a name="simrand" val="0"/>
    </options>
    <circuit name="one">
      <a name="circuit" val="one"/>
      <comp lib="0" loc="(80,100)" name="Pin">
        <a name="label" val="a"/>
      </comp>
      <comp lib="0" loc="(80,140)" name="Pin">
        <a name="label" val="b"/>
      </comp>
      <comp lib="0" loc="(300,220)" name="Pin">
        <a name="facing" val="west"/>
        <a name="label" val="q"/>
        <a name="output" val="true"/>
      </comp>
    </circuit>
  </project>
  """

@MainActor
private func present(_ text: String, circuit name: String) throws -> AnalyzerPresentation {
  LogisimFileProjectHostFactory.registerBuiltinLibrariesIfNeeded()
  let file = try #require(try Loader().openLogisimFile(data: Data(text.utf8)))
  let circuit = try #require(file.circuit(named: name))
  // Not `.shared`: one per test, so the suite cannot depend on ordering.
  let presentation = AnalyzerPresentation()
  presentation.analyze(circuit: circuit, file: file)
  return presentation
}

/// The 4.1.0 transcript, verbatim from `ExpressionEntryTests`. Measured 2026-09-06.
private let javaTranscript = """
  initial | q=0/-------- | r=0/-------- | s=0/--------
  import "q = a+b" -> row 0 | q=a+b/00111111 | r=0/-------- | s=0/--------
  import "r = a*b" -> row 1 | q=a+b/00111111 | r=a⋅b/00000011 | s=0/--------
  import "s = ~c" -> row 2 | q=a+b/00111111 | r=a⋅b/00000011 | s=~c/10101010
  import "a+b" -> REJECT norow
  import "z = a" -> REJECT parser:“z” is not an input variable.
  import "q = a ^ b" -> row 0 | q=a⊕b/00111100 | r=a⋅b/00000011 | s=~c/10101010
  import "r = 1" -> row 1 | q=a⊕b/00111100 | r=1/11111111 | s=~c/10101010
  import "s = a b c" -> row 2 | q=a⊕b/00111100 | r=1/11111111 | s=a⋅b⋅c/00000001
  import "q = " -> REJECT parser:Operator “=” missing right operand.
  import "r = a &&& b" -> REJECT parser:Operator “&” missing left operand.
  import "q = (a+b)'" -> row 0 | q=~(a+b)/11000000 | r=1/11111111 | s=a⋅b⋅c/00000001
  """

private let importInputs = [
  "q = a+b", "r = a*b", "s = ~c", "a+b", "z = a", "q = a ^ b",
  "r = 1", "s = a b c", "q = ", "r = a &&& b", "q = (a+b)'",
]

// MARK: - Suite

@MainActor
@Suite("Analyze — the Expression tab (board #92)")
struct AnalyzeExpressionTabTests {

  // ── The tab exists at all ─────────────────────────────────────────────────────────────────

  @Test("the window has all four upstream tabs, and the Expression one has state behind it")
  func theExpressionTabIsPresentAndBacked() throws {
    // `Analyzer.java:134-137` order: IO, TABLE, EXPRESSION, MINIMIZED.
    #expect(
      AnalyzerPresentation.Tab.allCases.map(\.title)
        == ["Inputs & Outputs", "Table", "Expression", "Minimized"])

    let presentation = try present(threeByThreeCirc, circuit: "entry")
    let entry = try #require(
      presentation.expressionEntry, "analyze() built no Expression tab state")
    // `ExpressionTableModel.updateCopy` iterates `outputs.bits`, one row per OUTPUT BIT.
    #expect(entry.rows.map(\.name) == ["q", "r", "s"])
    #expect(presentation.analysis?.model.outputs.bits == ["q", "r", "s"])

    // A failed analysis must not leave a stale tab pointing at a released model: `ExpressionEntryModel`
    // holds the `AnalyzerModel` unowned, and `analysis` is what retains it.
    let empty = AnalyzerPresentation()
    #expect(empty.expressionEntry == nil)
  }

  @Test("the Expression pane renders rather than merely compiling")
  func theExpressionPaneRenders() throws {
    // Constructing a SwiftUI view runs none of its body. This is the same guard
    // `AnalyzeWiringTests.viewBodyRendersRatherThanMerelyCompiling` applies to the other three
    // panes, aimed at the new one and at a row that already has an expression in it.
    let presentation = try present(threeByThreeCirc, circuit: "entry")
    let entry = try #require(presentation.expressionEntry)
    #expect(entry.importText("q = a+b"))
    presentation.tab = .expression

    let renderer = ImageRenderer(content: AnalyzerWindowContent(presentation: presentation))
    renderer.proposedSize = ProposedViewSize(width: 720, height: 560)
    let image = try #require(renderer.nsImage, "the Expression pane rendered nothing")
    #expect(image.size.width > 0 && image.size.height > 0)
  }

  // ── The jar oracle, through the tab ───────────────────────────────────────────────────────

  @Test("the 4.1.0 import transcript replays through the tab's own view model")
  func theJarTranscriptReplaysThroughTheTab() throws {
    let presentation = try present(threeByThreeCirc, circuit: "entry")
    let analysis = try #require(presentation.analysis)
    let entry = try #require(presentation.expressionEntry)
    let model = analysis.model
    let names = ["q", "r", "s"]

    func column(_ index: Int) -> String {
      (0..<analysis.truthTable.rowCount)
        .map { analysis.truthTable.outputEntry(row: $0, column: index).description() }
        .joined()
    }
    func show(_ label: String) -> String {
      var out = label
      for (i, name) in names.enumerated() {
        let expr = model.outputExpressions.expression(for: name)?.description ?? "null"
        out += " | \(name)=\(expr)/\(column(i))"
      }
      return out
    }

    var lines = [show("initial")]
    for input in importInputs {
      if entry.importText(input) {
        // Which row it routed to, read back from the model rather than recomputed: the routing
        // decision is the thing under test, and `setExpression(name, expr, exprString)` stores
        // the string it was given against exactly one output.
        let row = names.firstIndex { model.outputExpressions.expressionString(for: $0) == input }
        lines.append(show("import \"\(input)\" -> row \(row ?? -1)"))
      } else if let message = entry.errorMessage {
        lines.append("import \"\(input)\" -> REJECT parser:\(message)")
      } else {
        // The silent rejection: no message, and the `setError(null)` before it cleared the label.
        lines.append("import \"\(input)\" -> REJECT norow")
      }
    }

    let expected = javaTranscript.split(separator: "\n").map(String.init)
    #expect(lines.count == expected.count)
    #expect(lines.count == 12)
    for (actual, want) in zip(lines, expected) {
      #expect(actual == want)
    }
  }

  // ── The commit path, and the `enableUpdates` it depends on ────────────────────────────────

  @Test("an expression typed into a row field takes effect and is not rewritten")
  func typedExpressionSurvivesTheCommit() throws {
    let presentation = try present(threeByThreeCirc, circuit: "entry")
    let analysis = try #require(presentation.analysis)
    let entry = try #require(presentation.expressionEntry)

    // The column starts undefined, nothing drives `q`.
    #expect(
      (0..<8).map { analysis.truthTable.outputEntry(row: $0, column: 0).description() }.joined()
        == "--------")

    // The editor: double-click, type, Enter. `beginEditing` is `getTableCellEditorComponent`,
    // `commitEditing` is `stopCellEditing`.
    entry.beginEditing(row: 0)
    #expect(entry.editingRow == 0)
    entry.draft = "a ^ b"
    #expect(entry.commitEditing())
    #expect(entry.editingRow == nil)
    #expect(entry.errorMessage == nil)

    // TAKES EFFECT: the truth-table column is rewritten underneath it. jar transcript line 7,
    // `q=a⊕b/00111100`.
    #expect(
      (0..<8).map { analysis.truthTable.outputEntry(row: $0, column: 0).description() }.joined()
        == "00111100")
    #expect(analysis.truthTable.outputHeader(0) == "q")

    // ── AND IS NOT REWRITTEN. This is the assertion that fails without
    //    `AnalyzerPresentation.analyze`'s `enableUpdates()` call ─────────────────────────────
    //
    // `setExpression` rewrites the column, the column change fires `cellsChanged`, and
    // `OutputExpressions.invalidate(String)` DROPS the output's `OutputData` when updates are
    // off (OutputExpressions.swift:336-340). The next read rebuilds it from the table and hands
    // back the MINIMAL form. The jar prints `a⊕b`, not `~a⋅b+a⋅~b`, and the two are chosen here
    // precisely because they differ as strings while covering the same eight rows.
    #expect(entry.rows[0].expression?.toString() == "a⊕b")
    #expect(analysis.model.outputExpressions.expression(for: "q")?.toString() == "a⊕b")
    #expect(entry.displayText(row: 0) == "a⊕b")
    // The Minimized tab still shows the minimal form: the two tabs disagree on purpose.
    #expect(
      analysis.model.outputExpressions.minimalExpression(for: "q")?.toString() == "~a⋅b+a⋅~b")
    #expect(presentation.minimalExpression(for: "q")?.toString() == "~a⋅b+a⋅~b")

    // The other two rows are untouched.
    #expect(entry.rows[1].expression?.toString() == "0")
    #expect(entry.rows[2].expression?.toString() == "0")
  }

  @Test("an empty field commits nothing to the model, and reports no error — a 4.1.0 quirk")
  func anEmptyFieldIsANoOpOnTheModelAndBlanksTheRow() throws {
    // `Parser.parse("")` returns null with no exception (measured: `PROBE parse "" -> nil`), so
    // `ok()` SUCCEEDS, the editor closes, and `setValueAt`'s `if (e.expr != null)` drops the
    // write. What upstream does *not* guard is the line above it, `listCopy[row] = e` runs
    // unconditionally, ExpressionTab.java:106, so the displayed row is blanked while the model
    // keeps the old expression. That is upstream's, it is reproduced rather than repaired, and
    // `updateTab()` (which `MyChangeListener.stateChanged` runs on every tab switch, and which
    // the pane runs `onAppear`) is what puts the row back.
    let presentation = try present(threeByThreeCirc, circuit: "entry")
    let entry = try #require(presentation.expressionEntry)
    let model = try #require(presentation.analysis?.model)
    #expect(entry.importText("q = a+b"))

    entry.beginEditing(row: 0)
    entry.draft = ""
    #expect(entry.commitEditing())
    #expect(entry.errorMessage == nil)
    #expect(entry.editingRow == nil)

    // The MODEL is untouched; this is the part that matters, and it is the assertion that
    // would fail if the empty string were committed as a null expression.
    #expect(model.outputExpressions.expression(for: "q")?.toString() == "a+b")
    #expect(
      (0..<8).map { presentation.analysis!.truthTable.outputEntry(row: $0, column: 0).description() }
        .joined() == "00111111")

    // The row copy is blank until it is refreshed, and then it is not.
    #expect(entry.rows[0].expression == nil)
    #expect(entry.displayText(row: 0) == "")
    entry.updateTab()
    #expect(entry.rows[0].expression?.toString() == "a+b")
    #expect(entry.displayText(row: 0) == "a+b")
  }

  // ── The error offsets survive the trip ────────────────────────────────────────────────────

  @Test("a parser error keeps the editor open and points at the offending characters")
  func aParserErrorSelectsTheOffendingRun() throws {
    let presentation = try present(threeByThreeCirc, circuit: "entry")
    let entry = try #require(presentation.expressionEntry)

    entry.beginEditing(row: 0)
    entry.draft = "a &&& b"
    #expect(entry.commitEditing() == false)

    // ExpressionTab.java:284-286: the message goes in the label, and the field selects
    // `[getOffset(), getEndOffset())`. Measured on the port 2026-09-06:
    //     PROBE parse "a &&& b" -> ERR offset=4 len=1 msg=Operator “&” missing left operand.
    #expect(entry.errorMessage == "Operator \u{201C}&\u{201D} missing left operand.")
    let selection = try #require(entry.errorSelection, "the caret range was thrown away")
    #expect(selection == 4..<5)
    // The range really does name the offending character, not an arbitrary index.
    let draft = Array(entry.draft)
    #expect(String(draft[selection.lowerBound..<selection.upperBound]) == "&")

    // `stopCellEditing` returned false, so the cell editor stays open on the same row with the
    // user's text intact; that is what makes the selection visible at all.
    #expect(entry.editingRow == 0)
    #expect(entry.draft == "a &&& b")
    // And nothing was committed.
    #expect(entry.rows[0].expression?.toString() == "0")
    #expect(presentation.analysis?.truthTable.outputEntry(row: 3, column: 0) == .dontCare)
  }

  @Test("the import field reports the same offsets the row field does")
  func theImportPathCarriesTheOffsetsToo() throws {
    let presentation = try present(threeByThreeCirc, circuit: "entry")
    let entry = try #require(presentation.expressionEntry)

    // Measured: `PROBE maybe "q = " -> ERR offset=2 len=1`: the `=` at index 2 of `"q = "`.
    #expect(entry.importText("q = ") == false)
    #expect(entry.errorMessage == "Operator \u{201C}=\u{201D} missing right operand.")
    #expect(entry.errorSelection == 2..<3)

    // `PROBE maybe "r = a &&& b" -> ERR offset=8 len=1`.
    #expect(entry.importText("r = a &&& b") == false)
    #expect(entry.errorSelection == 8..<9)
    #expect(Array("r = a &&& b")[8] == "&")
  }

  @Test("Character offsets survive the conversion the text field does to select them")
  func caretOffsetsConvertToUtf16() {
    // `ParserError.offset` counts Characters; `NSTextField` selects UTF-16. Identical for ASCII…
    #expect(SelectingTextField.utf16Range(of: 4..<5, in: "a &&& b") == NSRange(location: 4, length: 1))
    // …and not identical once a glyph outside the BMP is in front of it, which is what the
    // conversion is for.
    #expect(
      SelectingTextField.utf16Range(of: 1..<2, in: "\u{1F600}xy") == NSRange(location: 2, length: 1))
    // A zero-length error (the implicit-AND token carries length 0) and an out-of-range offset
    // both clamp rather than trap.
    #expect(SelectingTextField.utf16Range(of: 2..<2, in: "abc") == NSRange(location: 2, length: 0))
    #expect(SelectingTextField.utf16Range(of: 9..<12, in: "abc") == NSRange(location: 3, length: 0))
  }

  @Test("the offending run is written into a real field editor's selection")
  func theSelectionReachesTheFieldEditor() throws {
    // The last link before the screen. `updateNSView` hands `field.currentEditor()` to
    // `applySelection`, and a field that is not in a window has no field editor, so the editor
    // is supplied here directly, which is the most of this path a headless test can reach. What
    // it does prove is that the range is written to `selectedRange` and not merely computed.
    let presentation = try present(threeByThreeCirc, circuit: "entry")
    let entry = try #require(presentation.expressionEntry)
    entry.beginEditing(row: 0)
    entry.draft = "a &&& b"
    #expect(entry.commitEditing() == false)

    let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
    editor.string = entry.draft
    // Setting the string leaves an empty caret at the end: measured, `{7, 0}` for a 7-character
    // draft. Asserting it first is what makes the next line a movement rather than a no-op.
    #expect(editor.selectedRange() == NSRange(location: 7, length: 0))
    SelectingTextField.applySelection(entry.errorSelection, to: editor, in: entry.draft)
    #expect(editor.selectedRange() == NSRange(location: 4, length: 1))
    let selected = (entry.draft as NSString).substring(with: editor.selectedRange())
    #expect(selected == "&")

    // A nil range leaves the selection alone rather than collapsing it to the start.
    SelectingTextField.applySelection(nil, to: editor, in: entry.draft)
    #expect(editor.selectedRange() == NSRange(location: 4, length: 1))
  }

  // ── The two parsers are not the same parser ───────────────────────────────────────────────

  @Test("the row field rejects the assignment form the import field accepts")
  func theRowFieldAndTheImportFieldUseDifferentParsers() throws {
    let presentation = try present(threeByThreeCirc, circuit: "entry")
    let entry = try #require(presentation.expressionEntry)

    // ExpressionTab.java:279 is `Parser.parse`, not `parseMaybeAssignment`; the `q =` is
    // already printed to the LEFT of the field by the buddy label, so typing it again is an
    // error. Measured: `PROBE parse "q = a+b" -> ERR offset=0 len=1 msg=“q” is not an input
    // variable.` (the identifier check fires before the assignment branch, which `parse`
    // does not enable).
    entry.beginEditing(row: 0)
    entry.draft = "q = a+b"
    #expect(entry.commitEditing() == false)
    #expect(entry.errorMessage == "\u{201C}q\u{201D} is not an input variable.")
    #expect(entry.errorSelection == 0..<1)
    #expect(entry.rows[0].expression?.toString() == "0")

    // The same string through `importData` (ExpressionTab.java:496) is accepted and routed.
    #expect(entry.importText("q = a+b"))
    #expect(entry.errorMessage == nil)
    #expect(entry.rows[0].expression?.toString() == "a+b")

    // And the right-hand side alone is what the field wants.
    entry.beginEditing(row: 1)
    entry.draft = "a*b"
    #expect(entry.commitEditing())
    #expect(entry.rows[1].expression?.toString() == "a⋅b")
  }

  // ── Routing ───────────────────────────────────────────────────────────────────────────────

  @Test("the three rejections are three different things in the UI")
  func theThreeRejectionsAreDistinguishable() throws {
    let presentation = try present(threeByThreeCirc, circuit: "entry")
    let entry = try #require(presentation.expressionEntry)
    let before = entry.rows.map { $0.expression?.toString() }

    // 1. A parser error is reported.
    #expect(entry.importText("z = a") == false)
    #expect(entry.errorMessage == "\u{201C}z\u{201D} is not an input variable.")
    #expect(entry.errorSelection != nil)

    // 2. A well-formed non-assignment with nothing selected is dropped SILENTLY, and note it
    //    clears the message left by (1), because `setError(null)` runs before the routing.
    #expect(entry.selectedRow == -1)
    #expect(entry.importText("a+b") == false)
    #expect(entry.errorMessage == nil)
    #expect(entry.errorSelection == nil)

    // 3. An assignment is routed to the row its left-hand side names.
    #expect(entry.importText("s = ~c"))
    #expect(entry.rows.map { $0.expression?.toString() } == [before[0], before[1], "~c"])
  }

  @Test("a selected row takes a bare expression, as getSelectedRow() does upstream")
  func aSelectedRowTakesABareExpression() throws {
    let presentation = try present(threeByThreeCirc, circuit: "entry")
    let entry = try #require(presentation.expressionEntry)

    // `idx = table.getSelectedRow();`; the branch before the left-hand-side scan.
    entry.selectedRow = 1
    #expect(entry.importText("a+b"))
    #expect(entry.rows.map { $0.expression?.toString() } == ["0", "a+b", "0"])

    // A selected row does NOT override an assignment's target: upstream strips the assignment
    // and writes to `getSelectedRow()`, so `s = ~c` with row 1 selected lands on row 1.
    #expect(entry.importText("s = ~c"))
    #expect(entry.rows.map { $0.expression?.toString() } == ["0", "~c", "0"])
  }

  @Test("with a single output, everything lands on it")
  func oneOutputTakesEverything() throws {
    // `if (table.getRowCount() == 1) idx = 0;`: checked before the drop location and before
    // `getSelectedRow`, so it also wins over "nothing is selected".
    let presentation = try present(oneOutputCirc, circuit: "one")
    let entry = try #require(presentation.expressionEntry)
    #expect(entry.rows.map(\.name) == ["q"])
    #expect(entry.selectedRow == -1)

    #expect(entry.importText("a+b"))
    #expect(entry.rows[0].expression?.toString() == "a+b")
    let table = try #require(presentation.analysis?.truthTable)
    #expect(
      (0..<4).map { table.outputEntry(row: $0, column: 0).description() }.joined() == "0111")
  }

  @Test("a drop names its own row")
  func aDropRoutesToTheRowItLandedOn() throws {
    // `((JTable.DropLocation) info.getDropLocation()).getRow()`, ExpressionTab.java:513.
    let presentation = try present(threeByThreeCirc, circuit: "entry")
    let entry = try #require(presentation.expressionEntry)
    #expect(entry.importText("a+b", dropRow: 2))
    #expect(entry.rows.map { $0.expression?.toString() } == ["0", "0", "a+b"])
    // Out of range is refused, not clamped.
    #expect(entry.importText("a*b", dropRow: 7) == false)
    #expect(entry.rows.map { $0.expression?.toString() } == ["0", "0", "a+b"])
  }

  // ── The notation combo ────────────────────────────────────────────────────────────────────

  @Test("the notation combo changes what a row shows but not what you edit")
  func notationAffectsTheRendererAndNotTheEditor() throws {
    let presentation = try present(threeByThreeCirc, circuit: "entry")
    let entry = try #require(presentation.expressionEntry)
    #expect(entry.importText("q = a ^ b"))

    // `MinimizedTab.NotationModel` offers five of the six; LaTeX is a file-export notation.
    #expect(ExpressionEntryModel.notationChoices.count == 5)
    #expect(ExpressionEntryModel.notationChoices.first == .mathematical)
    #expect(!ExpressionEntryModel.notationChoices.contains(.latex))
    #expect(ExpressionEntryModel.notationName(.progBits) == "Programming with bits")

    #expect(entry.notation == .mathematical)
    #expect(entry.displayText(row: 0) == "a⊕b")
    entry.notation = .progBits
    #expect(entry.displayText(row: 0) == "a^b")

    // The EDITOR is hard-wired to `expr.toString()`, Expression.java:466, MATHEMATICAL, even
    // with the combo somewhere else. Upstream's asymmetry, reproduced.
    entry.beginEditing(row: 0)
    #expect(entry.draft == "a⊕b")
  }

  @Test("Copy produces the assignment form Paste reads back")
  func copyRoundTripsThroughImport() throws {
    // `createTransferable` builds `name + " = " + expr.toString(notation)`; `importData` parses
    // it. The pair is the tab's whole clipboard contract.
    let presentation = try present(threeByThreeCirc, circuit: "entry")
    let entry = try #require(presentation.expressionEntry)
    #expect(entry.importText("s = a b c"))
    let copied = try #require(entry.copyText(row: 2))
    #expect(copied == "s = a⋅b⋅c")

    let second = try present(threeByThreeCirc, circuit: "entry")
    let other = try #require(second.expressionEntry)
    #expect(other.importText(copied))
    #expect(other.rows.map { $0.expression?.toString() } == ["0", "0", "a⋅b⋅c"])
  }

  @Test("a value typed for one output cannot land on another that took its index")
  func aValueCannotBeWrittenToTheWrongRow() throws {
    // `if (ne != e && !ne.name.equals(e.name)) return;`, ExpressionTab.java:105. It is reachable
    // only because the editor carries the name it was OPENED with (`oldExpr.name`) rather than
    // re-reading the row at commit time, so if the output list changes underneath an open
    // field, the value is refused instead of landing on whoever now sits at that index.
    let presentation = try present(threeByThreeCirc, circuit: "entry")
    let entry = try #require(presentation.expressionEntry)
    let model = try #require(presentation.analysis?.model)

    entry.beginEditing(row: 0)
    entry.draft = "a+b"
    // `q` is deleted from the Inputs/Outputs tab while the field is open; `r` slides into row 0.
    try model.outputs.remove(Var("q", 1))
    entry.updateTab()
    #expect(entry.rows.map(\.name) == ["r", "s"])

    // `ok()` still succeeds, the text parses, so the editor closes, and then the guard drops
    // the write.
    #expect(entry.commitEditing())
    #expect(entry.errorMessage == nil)
    #expect(entry.rows[0].expression?.toString() == "0")
    #expect(model.outputExpressions.expression(for: "r")?.toString() == "0")
  }
}
