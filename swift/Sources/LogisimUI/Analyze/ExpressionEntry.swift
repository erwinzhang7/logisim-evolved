// ExpressionEntry.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.analyze.gui.ExpressionTab and its inner
// ExpressionTableModel / ExpressionEditor / ExpressionTransferHandler),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Board #92: the model half was already gated, and nothing could reach it ──────────────────
//
// `Tests/LogisimAnalyzeTests/ExpressionEntryTests.swift` replays `ExpressionTab.importData`
// (ExpressionTab.java:485-538) against a recorded 4.1.0 transcript and passes. What it cannot
// do is prove that a *user* can get there: `ExpressionTab` is the only caller in all of 4.1.0
// of `Parser.parse`, `Parser.parseMaybeAssignment` and the three assignment accessors, and the
// port had no Expression tab at all. This file is the missing half, the tab's state machine,
// with the Swing removed, and `AnalyzerWindow.swift` is the two dozen lines of SwiftUI over it.
//
// D9: no SwiftUI and no AppKit in here. Everything below is callable, and is called, from a
// test with nothing on screen; the caret *range* an error selects is a `Range<Int>` that the
// text field applies, not an `NSRange` computed by a view.
//
// ── Upstream's tab is a one-column JTable, and that shape is kept ────────────────────────────
//
// One row per **output bit** (`ExpressionTableModel.updateCopy`, iterating `outputs.bits`), each
// holding a `NamedExpression`: a name, an expression, the string it was typed as, and an error.
// Reading a row renders the expression through the notation combo; editing a row swaps in a
// `JTextField` with a `name =` buddy label on its left, so the field holds the RIGHT-HAND SIDE
// ONLY. Two consequences that are easy to get wrong and are reproduced here deliberately:
//
//   * The editor commits through `Parser.parse` (ExpressionTab.java:279), **not**
//     `parseMaybeAssignment`. Typing `q = a+b` into row `q`'s field is therefore a syntax error
//     in 4.1.0, because the `q =` is already printed to the left of the field. Measured, rather
//     than assumed from the `=`: the message is `badVariableName`, "“q” is not an input
//     variable.", at offset 0; `Parser`'s identifier check fires on token 0 before the
//     assignment branch, which `parse` never enables (`Parser.swift:111,135`). The full
//     assignment form goes in through `importText` below, which is what Paste and drop use.
//   * The editor field renders with `expr.toString()`, Expression.java:466, hard-wired to
//     MATHEMATICAL, while the row *display* renders with the notation combo. So switching the
//     combo to "Programming with bits" changes what a row shows but not what you edit. That is
//     upstream's, not an oversight here.
//
// ── The three rejections are three different things, and only two are visible ────────────────
//
// `importData` refuses in three ways, and `ExpressionEntryTests` pins all three against the jar:
//
//   1. A `ParserException` → `setError(ex.getMessageGetter())`. In the *editor* path upstream
//      goes further and selects the offending run in the field, ExpressionTab.java:285-286:
//
//          field.setCaretPosition(ex.getOffset());
//          field.moveCaretPosition(ex.getEndOffset());
//
//      `ParserError` already carries `offset` and `length`, so `errorSelection` is that range.
//      A field that only said "invalid" would throw the position away.
//   2. A well-formed expression that is not an assignment, with no row selected, has nowhere to
//      go and is dropped **silently**: `return false` with no `setError`, and note that the
//      preceding `setError(null)` has already cleared whatever was on screen.
//   3. An assignment is routed to the row its left-hand side names, scanning **downward from the
//      last row** (`for (idx = getRowCount() - 1; idx >= 0; idx--)`), which leaves `idx == -1`
//      when nothing matches.
//
// ── One divergence, stated ───────────────────────────────────────────────────────────────────
//
// Upstream's import path sets the error message but no caret range, because the text came from
// the clipboard and there is no field to select in. Here the import field is on screen, so the
// same `offset`/`endOffset` are published for it. Same numbers, one more place they are used.

import LogisimAnalyze
import Observation

// MARK: - NamedExpression

/// `ExpressionView.NamedExpression`; the one value the tab's table column holds.
public struct NamedExpression: Identifiable, Equatable {
  /// The output bit this row is for. Row identity: `setValueAt` refuses a value whose name does
  /// not match the row it is being written to (ExpressionTab.java:105).
  public let name: String
  public var expression: LogisimAnalyze.Expression?
  /// `exprString`: what the user actually typed, kept verbatim so `OutputExpressions` can hand
  /// it back rather than re-printing the parse tree.
  public var expressionString: String?
  /// `err`; set when `getExpression` fails. The port's `expression(for:)` returns an optional
  /// instead of throwing, so nothing sets this today; the field exists so the row shape matches
  /// upstream's and a later throwing accessor has somewhere to land.
  public var error: String?

  public var id: String { name }

  public init(
    name: String, expression: LogisimAnalyze.Expression? = nil,
    expressionString: String? = nil, error: String? = nil
  ) {
    self.name = name
    self.expression = expression
    self.expressionString = expressionString
    self.error = error
  }
}

// MARK: - The tab's state

/// `ExpressionTab`, minus every `javax.swing` type in it.
@MainActor
@Observable
public final class ExpressionEntryModel {

  /// D3: the presentation owns the `AnalyzerModel` (through its `Analysis`); this holds an
  /// unowned edge to it exactly as `ExpressionTab` holds `model`.
  @ObservationIgnored public unowned let model: AnalyzerModel

  /// `ExpressionTableModel.listCopy`, in `outputs.bits` order.
  public private(set) var rows: [NamedExpression] = []

  /// `table.getSelectedRow()`: `-1` for "nothing selected", which is the value `importData`
  /// branches on.
  public var selectedRow: Int = -1

  /// The notation combo (`ExpressionTab.notation`, `MyListener.itemStateChanged`). Upstream's
  /// `NotationModel` offers five of the six, LaTeX is a file-export notation and is not in the
  /// combo, so `notationChoices` is the list, not `Notation.allCases`.
  public var notation: LogisimAnalyze.Expression.Notation = .mathematical

  /// The `error` JLabel at the bottom of the tab, via `setError(StringGetter)`.
  public private(set) var errorMessage: String?

  /// ExpressionTab.java:285-286: the run of the input the parser objected to, as a half-open
  /// range of `Character` offsets. `nil` when there is no error or the error carries no span.
  public private(set) var errorSelection: Range<Int>?

  /// Which row the editor is open on, and the text in its field. `nil` means no cell editor,
  /// which is upstream's resting state (`isCellEditable` needs a double-click or F2/Enter).
  public private(set) var editingRow: Int?
  public var draft: String = ""

  /// `ExpressionEditor.oldExpr.name`, captured when the editor opened; **not** re-read at
  /// commit time. That is what makes `setValueAt`'s name guard reachable: if the output list
  /// changes while a field is open, the value carries the name it was typed for and is refused
  /// rather than landing on whichever output now sits at that index.
  private var editingName: String?

  public init(model: AnalyzerModel) {
    self.model = model
    updateCopy()
  }

  // MARK: - ExpressionTableModel

  /// `ExpressionTab.updateTab()` → `ExpressionTableModel.update()`.
  public func updateTab() { updateCopy() }

  /// `ExpressionTableModel.updateCopy()`.
  private func updateCopy() {
    rows = model.outputs.bits.map { name in
      NamedExpression(name: name, expression: model.outputExpressions.expression(for: name))
    }
    if selectedRow >= rows.count { selectedRow = -1 }
  }

  /// `ExpressionTableModel.setValueAt(Object, int, int)`.
  ///
  /// The name guard is upstream's `if (ne != e && !ne.name.equals(e.name)) return;`; a value may
  /// only be written to the row that owns the name.
  private func setValue(_ value: NamedExpression, at row: Int) {
    guard rows.indices.contains(row), rows[row].name == value.name else { return }
    rows[row] = value
    guard let expression = value.expression else { return }
    do {
      try model.outputExpressions.setExpression(
        value.name, expression, value.expressionString)
    } catch {
      // D13: `setOutputColumn` throws on a malformed column. Upstream's `setExpression` is
      // declared to throw nothing and the failure would be an unchecked exception on the EDT;
      // here it lands in the same label a parse error does.
      errorMessage = String(describing: error)
    }
    refreshRow(named: value.name)
  }

  /// `ExpressionTableModel.expressionChanged(OutputExpressionsEvent)` for `OUTPUT_EXPRESSION`,
  /// which is what `setExpression` fires on its way out.
  ///
  /// It matters that this refreshes **only the row the event names**, and not the whole list.
  /// Upstream's `listCopy[row] = e` write in `setValueAt` is otherwise permanent, so a full
  /// rebuild here would paper over the name guard above. That is not hypothetical: an
  /// `updateCopy()` on this line made the guard unobservable and its red probe came back GREEN.
  ///
  /// Re-reading from the model rather than trusting the value handed in is upstream's too, and
  /// is load-bearing: what the model holds after a commit is not always what was committed (see
  /// `AnalyzerPresentation.analyze`'s `enableUpdates`).
  private func refreshRow(named name: String) {
    guard let index = rows.firstIndex(where: { $0.name == name }) else { return }
    rows[index].expression = model.outputExpressions.expression(for: name)
    rows[index].error = nil
  }

  // MARK: - ExpressionEditor

  /// `ExpressionEditor.getTableCellEditorComponent`: open the editor on one row.
  ///
  /// `field.setText(oldExpr.expr.toString())`: the *default* notation, not `self.notation`.
  public func beginEditing(row: Int) {
    guard rows.indices.contains(row) else { return }
    editingRow = row
    editingName = rows[row].name
    selectedRow = row
    draft = rows[row].expression?.toString() ?? ""
  }

  /// Leaving the cell editor without committing (`cancelCellEditing`).
  public func cancelEditing() {
    editingRow = nil
    editingName = nil
    draft = ""
  }

  /// `ExpressionEditor.stopCellEditing()`: `ok()`, then `setValueAt` with the value it built.
  ///
  /// Returns false exactly when upstream refuses to close the editor, which is the parse-error
  /// case: the field stays open with the offending run selected.
  @discardableResult
  public func commitEditing() -> Bool {
    guard let row = editingRow, let name = editingName, rows.indices.contains(row) else {
      return false
    }
    let exprString = draft
    let expression: LogisimAnalyze.Expression?
    do {
      expression = try Parser.parse(exprString, model)
    } catch let error as ParserError {
      setError(error)
      return false
    } catch {
      setError(message: String(describing: error), selection: nil)
      return false
    }
    setError(nil)
    // `newExpr = new NamedExpression(oldExpr.name, expr, exprString)`, then `setValueAt`. An
    // empty field parses to `null` with no exception, so the editor closes and nothing is
    // committed: the `if (e.expr != null)` guard in `setValueAt`.
    editingRow = nil
    editingName = nil
    setValue(
      NamedExpression(name: name, expression: expression, expressionString: exprString), at: row)
    return true
  }

  // MARK: - ExpressionTransferHandler

  /// `ExpressionTransferHandler.importData(TransferSupport)`, ExpressionTab.java:485-538.
  ///
  /// `dropRow` is `((JTable.DropLocation) info.getDropLocation()).getRow()`: non-nil only for a
  /// drag-and-drop, `nil` for a paste, which is the case `ExpressionEntryTests` pins.
  @discardableResult
  public func importText(_ text: String, dropRow: Int? = nil) -> Bool {
    var expression: LogisimAnalyze.Expression?
    do {
      expression = try Parser.parseMaybeAssignment(text, model)
      setError(nil)
    } catch let error as ParserError {
      // Upstream sets only the message here; the range is this port's addition (see the header).
      setError(error)
      return false
    } catch {
      setError(message: String(describing: error), selection: nil)
      return false
    }
    // REJECT null: a blank or whitespace-only paste. Silent; the `setError(null)` above has
    // already cleared the label.
    guard var expr = expression else { return false }

    var idx = -1
    if rows.isEmpty { return false }
    if rows.count == 1 {
      // One output: everything lands on it, assignment or not.
      idx = 0
    } else if let dropRow {
      idx = dropRow
    } else {
      idx = selectedRow
      if idx < 0, expr.isAssignment, let target = expr.assignmentVariable {
        // Scan DOWNWARD from the last row; `idx` is left at -1 when nothing matches.
        idx = rows.count - 1
        while idx >= 0 && rows[idx].name != target { idx -= 1 }
      }
    }
    // REJECT norow.
    guard idx >= 0 && idx < rows.count else { return false }
    if expr.isAssignment, let stripped = expr.assignmentExpression { expr = stripped }

    var value = rows[idx]
    value.expressionString = text
    value.expression = expr
    value.error = nil
    setValue(value, at: idx)
    return true
  }

  /// `ExpressionTransferHandler.createTransferable`; what Copy puts on the clipboard: the row
  /// in the assignment form `importText` reads back. Note it uses the *combo's* notation, so a
  /// copy round-trip through a non-mathematical notation is upstream's own asymmetry.
  public func copyText(row: Int) -> String? {
    guard rows.indices.contains(row) else { return nil }
    let value = rows[row]
    guard let text = value.expression.map({ $0.toString(notation) }) ?? value.error else {
      return nil
    }
    return "\(value.name) = \(text)"
  }

  // MARK: - Rendering

  /// What the row shows when the editor is closed: the pretty view, in the combo's notation.
  public func displayText(row: Int) -> String {
    guard rows.indices.contains(row) else { return "" }
    guard let expression = rows[row].expression else { return rows[row].error ?? "" }
    let text = expression.toString(notation)
    // Java prints the empty string for the constant-false expression; say so instead, as the
    // Minimized pane already does.
    return text.isEmpty ? "0" : text
  }

  /// `S.get("outputExpressionEdit")`, the `infoLabel` above the table.
  public var infoLabel: String { AnalyzeStrings.message("outputExpressionEdit") }
  /// `S.get("ExpressionNotation")`, the combo's label.
  public var notationLabel: String { AnalyzeStrings.message("ExpressionNotation") }

  /// `MinimizedTab.NotationModel`: five choices, LaTeX excluded, in `Notation` ordinal order
  /// because `itemStateChanged` does `Notation.values()[getSelectedIndex()]`.
  public static let notationChoices: [LogisimAnalyze.Expression.Notation] = [
    .mathematical, .logic, .altLogic, .progBools, .progBits,
  ]

  /// The combo's visible text for one notation.
  public static func notationName(_ notation: LogisimAnalyze.Expression.Notation) -> String {
    switch notation {
    case .mathematical: return AnalyzeStrings.message("expressionMathrepresentation")
    case .logic: return AnalyzeStrings.message("expressionLogicrepresentation")
    case .altLogic: return AnalyzeStrings.message("expressionAltLogicrepresentation")
    case .progBools: return AnalyzeStrings.message("expressionProgboolsrepresentation")
    case .progBits: return AnalyzeStrings.message("expressionProgbitsrepresentation")
    case .latex: return "LaTeX"
    }
  }

  // MARK: - setError

  /// `ExpressionTab.setError(StringGetter)` plus the caret move that follows it in the editor.
  private func setError(_ error: ParserError?) {
    guard let error else {
      setError(message: nil, selection: nil)
      return
    }
    setError(message: error.message, selection: error.offset..<error.endOffset)
  }

  private func setError(message: String?, selection: Range<Int>?) {
    errorMessage = message
    errorSelection = selection
  }
}
