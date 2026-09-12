// AnalyzerWindow.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.analyze.gui.{AnalyzerManager, Analyzer,
// VariableTab, TableTab, MinimizedTab}), https://github.com/logisim-evolution/logisim-evolution.
// Copyright by the Logisim-evolution developers. This translation is a derivative work and is
// therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── What upstream's window is ───────────────────────────────────────────────────────────────
//
// One process-wide `JFrame` with four tabs (`Analyzer.java:134-137`), lazily created and reused
// by `AnalyzerManager.getAnalyzer(parent)`, a static holder, not one window per project:
//
//   IO_TAB (0)          `VariableTab`  , edit the input and output variable lists.
//   TABLE_TAB (1)       `TableTab`     : the truth table; editable, with CSV/text import
//                                         and export and a LaTeX export.
//   EXPRESSION_TAB (2)  `ExpressionTab`: the expression per output, typed or derived.
//   MINIMIZED_TAB (3)   `MinimizedTab` : the Karnaugh map, the minimised expression, the
//                                         sum-of-products / product-of-sums switch, and the
//                                         "Build Circuit" button.
//
// `configureAnalyzer` picks the landing tab: IO if there are no inputs or no outputs,
// EXPRESSION if `computeExpression` succeeded, TABLE otherwise.
//
// ── What this window is, and what it deliberately is not ────────────────────────────────────
//
// This *was* the read-only half: Inputs/Outputs, Table, and the minimised expressions. **Board
// #92 added the Expression tab**, so all four upstream tabs are now present and the window is no
// longer read-only: an expression typed here rewrites its output's truth-table column through
// `OutputExpressions.setExpression`, exactly as upstream's does. The tab's state machine is
// `ExpressionEntry.swift`; this file is the SwiftUI over it. Everything else in the window is
// still derived, by `CircuitAnalysis`, from the real circuit through the real propagator, and
// nothing here is a placeholder.
//
// Not included, each for a stated reason rather than by omission:
//
//   * **Editing** the table or the variable lists. The model supports it completely
//     (`TruthTable.setOutputEntry`, `setVisibleRows`, `VariableList.add/remove/move`, all
//     jar-pinned by `LogisimAnalyzeTests`), so this is a UI-only gap. It is left out because an
//     editable table needs the caret/selection machinery of `TableTabCaret` + `TableTabClip`,
//     which is a second piece of work and does not gate reading the answer.
//   * **The Karnaugh map.** `KarnaughMapGroups`, `KarnaughMapGeometry` and `CoverColor` are all
//     ported and ready. The panel itself is a *drawing* surface, coloured cover rectangles over
//     a grid, and D6 says drawing goes through `RenderScene`, not a bespoke AppKit path. Doing
//     it properly means a K-map scene source; doing it improperly means the one thing D6 exists
//     to prevent.
//   * **Build Circuit.** `analyze/gui/BuildCircuitButton` drives `std/gates/CircuitBuilder`,
//     which is not ported (it is in the gates package, not the analyze one). See the report.
//   * **Export** to CSV / text / LaTeX. `TruthtableCsvFile`, `TruthtableTextFile` and
//     `AnalyzerTexWriter` are all ported and jar-pinned; they need an `NSSavePanel` and the file
//     extensions they already vend. Cheap, and not on the critical path to reading a table.
//   * **The Minimized tab's format combo** (`minimizedSumOfProducts` / `minimizedProductOfSums`,
//     `MinimizedTab.java`). It lives on the K-map panel, which is the item above. The two
//     Minimize buttons below carry the same two formats for the >6-input case, which is the one
//     the combo cannot reach: upstream disables the whole tab there (`Analyzer.java:126`).
//
// **Included since board #68:** upstream's two `MinimizeButton`s (`Analyzer.java:170,172`) and
// the report surface behind them. That control is the only caller of
// `OutputExpressions.forcedOptimize`, which is the only thing that lifts `computeMinimal`'s
// 6-input guard, so without it every circuit past six input bits showed `0` as its minimal
// expression. All of the reasoning, the two format constants, the threading, the report
// surface, and a 4.1.0 defect this port does not reproduce, is in `Minimization.swift`.
//
// D9: this file is the only one under `Analyze/` that imports SwiftUI. `CircuitAnalysis`, the
// derivation, has no UI in it at all and is tested with nothing on screen.

import AppKit
import LogisimAnalyze
import LogisimFile
import LogisimStd
import Observation
import SwiftUI

// MARK: - The state behind the window

/// What the analyzer window is showing. One per process, exactly as `AnalyzerManager` holds one
/// static `Analyzer`: the window follows whichever circuit was last analysed.
@MainActor
@Observable
public final class AnalyzerPresentation {
  public static let shared = AnalyzerPresentation()

  public private(set) var analysis: CircuitAnalysis.Analysis?
  /// D13 made visible: `doAnalyze`'s two limit checks end in `analyzeError`, an `OptionPane`
  /// message the user reads and recovers from. Here they end in this string.
  public private(set) var failure: String?
  public var tab: Tab = .table

  // ── The Minimize buttons (Analyzer.java:170,172) ─────────────────────────────────────────
  //
  // The result is held HERE rather than written back into `analysis.model`, and that is the
  // point: `Minimization.run` computes on a private model on a worker, so the live model is
  // never mutated off the main actor. See `Minimization.swift` for the whole argument.

  /// The last completed minimisation, layered over `analysis` by `minimalExpression(for:)`.
  public private(set) var minimization: MinimizationOutcome?
  /// True while a worker is running. `optimizeThread` is alive, in upstream's terms.
  public private(set) var isMinimizing = false
  /// The command the user picked and has not yet answered `OptimizeLongTimeWarning` for.
  public var pendingCommand: MinimizeCommand?
  /// Whether the report surface is up, upstream's modal `JDialog`.
  public var reportPresented = false

  /// The Expression tab's state (board #92), rebuilt per derivation because it holds an
  /// `unowned` edge to the `AnalyzerModel` inside `analysis`. Nil exactly when `analysis` is.
  public private(set) var expressionEntry: ExpressionEntryModel?

  /// The four tabs, in `Analyzer.java:134-137` order. `expression` is board #92's; `minimized`
  /// was called `expressions` until then, which was one letter away from the new case and named
  /// after what it shows rather than after the tab it is, `MINIMIZED_TAB`.
  public enum Tab: String, CaseIterable, Identifiable, Sendable {
    case variables
    case table
    case expression
    case minimized

    public var id: String { rawValue }
    /// The four upstream tab titles.
    public var title: String {
      switch self {
      case .variables: return "Inputs & Outputs"
      case .table: return "Table"
      case .expression: return "Expression"
      case .minimized: return "Minimized"
      }
    }
  }

  public init() {}

  /// `ProjectCircuitActions.doAnalyze`: derive, then choose the landing tab the way
  /// `configureAnalyzer` does.
  public func analyze(circuit: Circuit, file: LogisimFile?) {
    // A new derivation invalidates any minimisation: the outcome is keyed by output-bit name
    // and would otherwise be shown against a different circuit's identically-named bit.
    minimization = nil
    isMinimizing = false
    pendingCommand = nil
    reportPresented = false
    do {
      let result = try CircuitAnalysis.analyze(circuit: circuit, file: file)
      analysis = result
      failure = nil
      // ── `enableUpdates()`, and it is load-bearing, not housekeeping ───────────────────────
      //
      // `Analyzer.MyChangeListener.stateChanged` (Analyzer.java:57) and `setSelectedTab`
      // (Analyzer.java:234) both call it whenever any of the four tabs is selected, and
      // `configureAnalyzer` ends in `setSelectedTab`, so upstream's model has updates on from
      // the moment the window appears. This port never called it, which did not matter while
      // the window was read-only and matters completely now.
      //
      // With updates OFF, `OutputExpressions.invalidate(String)` DROPS the output's `OutputData`
      // instead of recomputing it (OutputExpressions.swift:336-340). `setExpression` rewrites
      // the truth-table column, the column change fires `cellsChanged`, and that invalidate
      // throws away the expression that was just set, so a typed `a^b` reads back as the
      // MINIMAL form `~a⋅b+a⋅~b` on the next glance. The jar transcript in
      // `ExpressionEntryTests` prints `q=a⊕b` there, and `typedExpressionSurvivesTheCommit`
      // is the test that fails without this line.
      result.model.outputExpressions.enableUpdates()
      expressionEntry = ExpressionEntryModel(model: result.model)
      // "If there are no inputs or outputs, we stop with that tab selected."
      //
      // `configureAnalyzer`'s three-way landing rule (`ProjectCircuitActions.java:63-86`),
      // verified against 4.1.0 rather than carried over:
      //
      //   no inputs or outputs        -> IO_TAB
      //   computeExpression succeeds  -> EXPRESSION_TAB, and RETURN; the table is never computed
      //   otherwise                   -> computeTable, TABLE_TAB
      //
      // The port collapsed this to two arms because the expression tab did not exist. It does
      // now (#92), so the rule is restored. `derivation == .netlistExpressions` is this port's
      // spelling of "computeExpression succeeded"; the same distinction `analyze()` already
      // makes to decide whether to fall through to `computeTable`.
      if !result.tableComputed {
        tab = .variables
      } else if result.derivation == .netlistExpressions {
        tab = .expression
      } else {
        tab = .table
      }
    } catch {
      analysis = nil
      expressionEntry = nil
      failure = String(describing: error)
      tab = .variables
    }
  }

  // MARK: - MinimizeButton

  /// `Analyzer.java:116-119`, exactly:
  ///
  ///     minimizeMinterms.setEnabled(hasInputsAndOutputs
  ///             && (nrOfInputs > Implicant.MAXIMAL_NR_OF_INPUTS_FOR_AUTO_MINIMAL_FORM));
  ///
  /// At or below six inputs the Minimized tab computes the answer unasked and upstream leaves
  /// both buttons dead; past six the tab is the dead one and these are the only route.
  public var canMinimize: Bool {
    guard let analysis, analysis.tableComputed else { return false }
    let table = analysis.truthTable
    let inputs = table.inputColumnCount
    return inputs > 0 && table.outputColumnCount > 0
      && inputs > Implicant.maximalNrOfInputsForAutoMinimalForm
  }

  /// `MinimizeButton.doOptimize`, past the confirm: snapshot on this actor, compute off it,
  /// store the answer back here.
  ///
  /// Returns the outcome as well as storing it, so a caller that is not a view can assert on
  /// it without reaching into observable state.
  @discardableResult
  public func minimize(_ command: MinimizeCommand) async -> MinimizationOutcome? {
    guard let analysis, !isMinimizing else { return nil }
    let request: MinimizationRequest
    do {
      request = try Minimization.request(from: analysis.model, format: command.format)
    } catch {
      let outcome = MinimizationOutcome(
        format: command.format, expressions: [:], report: "",
        failure: String(describing: error))
      minimization = outcome
      return outcome
    }
    isMinimizing = true
    minimization = nil
    reportPresented = true
    // The only suspension point, and the only place work leaves the main actor.
    let outcome = await Minimization.perform(request)
    minimization = outcome
    isMinimizing = false
    return outcome
  }

  /// The minimal expression the Minimized pane should show for one output bit: the forced
  /// minimisation when there is one, otherwise whatever the model derived unasked, which past
  /// six inputs is `computeMinimal`'s guard result, the constant `0`.
  public func minimalExpression(for outputBit: String) -> LogisimAnalyze.Expression? {
    if let forced = minimization?.expressions[outputBit] { return forced }
    return analysis?.minimalExpression(for: outputBit)
  }
}

// MARK: - AnalyzerManager

/// The port of `AnalyzerManager`: one lazily-created, reused window.
///
/// It is an `NSWindow` rather than a SwiftUI `Window` scene because a scene has to be declared in
/// `LogisimEvolvedApp`'s `body`, and this file set does not own that file. Swapping it for
/// `AnalyzerWindowScene` later is two lines there plus deleting this class; the view below is
/// the same either way. Stated here rather than left for the seam check to find.
@MainActor
public final class AnalyzerWindowController: NSObject, NSWindowDelegate {
  public static let shared = AnalyzerWindowController()

  private var window: NSWindow?

  /// `AnalyzerManager.getAnalyzer(parent)` followed by `setVisible(true)` / `toFront()`.
  public func show(circuit: Circuit, file: LogisimFile?) {
    AnalyzerPresentation.shared.analyze(circuit: circuit, file: file)
    let window = existingWindow()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
  }

  /// The window without ordering it front. `show` calls `NSApp.activate()`, which a test must
  /// not do; the suite would steal focus from whoever is at the keyboard.
  func windowForTesting() -> NSWindow { existingWindow() }

  private func existingWindow() -> NSWindow {
    if let window { return window }
    let controller = NSHostingController(
      rootView: AnalyzerWindowContent(presentation: AnalyzerPresentation.shared))
    let created = NSWindow(contentViewController: controller)
    created.title = "Combinational Analysis"
    created.setContentSize(NSSize(width: 720, height: 560))
    created.styleMask.insert(.resizable)
    created.isReleasedWhenClosed = false
    created.center()
    created.delegate = self
    window = created
    return created
  }
}

// MARK: - The window's content

/// The read-only analyzer: three panes over one derived `AnalyzerModel`.
public struct AnalyzerWindowContent: View {
  @Bindable var presentation: AnalyzerPresentation

  public init(presentation: AnalyzerPresentation) {
    self.presentation = presentation
  }

  public var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      Group {
        if let failure = presentation.failure {
          ContentUnavailableView {
            Label("Cannot Analyze This Circuit", systemImage: "exclamationmark.triangle")
          } description: {
            Text(failure)
          }
        } else if let analysis = presentation.analysis {
          pane(for: analysis)
        } else {
          ContentUnavailableView {
            Label("Nothing Analysed", systemImage: "tablecells")
          } description: {
            Text("Choose Circuit ▸ Analyze Circuit with a circuit open.")
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      minimizeBar
    }
    // `MinimizeButton.doOptimize`'s first act: the YES/NO on `OptimizeLongTimeWarning`. Kept
    // because "can take a long time (hours)" is the honest description of what the button does
    // in the only case where it is enabled.
    .confirmationDialog(
      Minimization.title,
      isPresented: Binding(
        get: { presentation.pendingCommand != nil },
        set: { if !$0 { presentation.pendingCommand = nil } }),
      presenting: presentation.pendingCommand
    ) { command in
      Button("Continue") {
        presentation.pendingCommand = nil
        Task { await presentation.minimize(command) }
      }
      Button("Cancel", role: .cancel) { presentation.pendingCommand = nil }
    } message: { _ in
      Text(Minimization.longRunWarning)
    }
    .sheet(isPresented: $presentation.reportPresented) {
      MinimizationReportSheet(presentation: presentation)
    }
  }

  /// `Analyzer.java:186-195`'s `buttonPanel`, reduced to the two buttons this window has.
  /// The list is `MinimizeCommand.all`, so the format really is per-button.
  private var minimizeBar: some View {
    HStack(spacing: 8) {
      if presentation.isMinimizing {
        ProgressView().controlSize(.small)
        Text("Optimizing\u{2026}").font(.caption).foregroundStyle(.secondary)
      } else if let outcome = presentation.minimization {
        Button("Show Report\u{2026}") { presentation.reportPresented = true }
          .buttonStyle(.link)
        Text(formatName(outcome.format)).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      ForEach(MinimizeCommand.all) { command in
        Button(command.title) { presentation.pendingCommand = command }
          .disabled(!presentation.canMinimize || presentation.isMinimizing)
      }
    }
    .padding(12)
  }

  private func formatName(_ format: Int) -> String {
    format == AnalyzerModel.formatProductOfSums ? "product of sums" : "sum of products"
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(presentation.analysis?.circuitName ?? "—")
            .font(.headline)
          if let analysis = presentation.analysis {
            Text(subtitle(for: analysis))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
      }
      Picker("", selection: $presentation.tab) {
        ForEach(AnalyzerPresentation.Tab.allCases) { tab in
          Text(tab.title).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
    }
    .padding(12)
  }

  private func subtitle(for analysis: CircuitAnalysis.Analysis) -> String {
    let inputs = analysis.model.inputs.bits.count
    let outputs = analysis.model.outputs.bits.count
    guard analysis.tableComputed else {
      return "\(inputs) input bit\(inputs == 1 ? "" : "s"), \(outputs) output bit"
        + "\(outputs == 1 ? "" : "s") — nothing to tabulate"
    }
    return
      "\(inputs) input bit\(inputs == 1 ? "" : "s") · \(outputs) output bit"
      + "\(outputs == 1 ? "" : "s") · \(analysis.truthTable.rowCount) rows"
  }

  @ViewBuilder private func pane(for analysis: CircuitAnalysis.Analysis) -> some View {
    switch presentation.tab {
    case .variables: VariablesPane(analysis: analysis)
    case .table: TruthTablePane(analysis: analysis)
    case .expression:
      if let entry = presentation.expressionEntry {
        ExpressionEntryPane(entry: entry, analysis: analysis)
      }
    case .minimized: MinimizedPane(presentation: presentation, analysis: analysis)
    }
  }
}

// MARK: - The report surface

/// `MinimizeButton`'s `infoPanel`: a modal dialog holding a monospaced white-on-black text area
/// that the run narrates into, with a Done button revealed when it finishes.
///
/// A sheet rather than a free-floating modal window, because on macOS a modal that belongs to
/// one document window is a sheet; the modality is upstream's and is kept, since the answer the
/// window is showing is being replaced underneath it.
///
/// **The one thing deliberately not reproduced is the live streaming.** Upstream appends to the
/// `JTextArea` from the worker thread as `computeMinimal` narrates; an off-EDT mutation of a
/// Swing `Document`. Reproducing that here means the worker and the main actor sharing the
/// `MinimizationReport`, which is the exact race `Minimization.swift` is built to avoid, and
/// Swift 6 would need `@unchecked` to allow it. So the text arrives all at once when the run
/// returns: every line upstream shows, at a different time. `Minimization.swift` records what it
/// would take to get the streaming back safely (a callback on `MinimizationReport`, which lives
/// outside this slice).
private struct MinimizationReportSheet: View {
  @Bindable var presentation: AnalyzerPresentation

  private var text: String {
    if let failure = presentation.minimization?.failure { return "Failed: \(failure)" }
    if let report = presentation.minimization?.report, !report.isEmpty { return report }
    if presentation.isMinimizing {
      return "Working\u{2026}\n\nThe report appears when the run finishes."
    }
    return "(no output)"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Text(Minimization.title).font(.headline)
        if presentation.isMinimizing { ProgressView().controlSize(.small) }
        Spacer()
      }
      .padding(12)
      Divider()
      ScrollView {
        Text(text)
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(.white)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
      }
      .background(Color.black)
      Divider()
      HStack {
        Spacer()
        // `doneButton.setVisible(true)` happens only when the worker returns; disabled until
        // then says the same thing without the layout jump.
        Button(Minimization.doneLabel) { presentation.reportPresented = false }
          .disabled(presentation.isMinimizing)
          .keyboardShortcut(.defaultAction)
      }
      .padding(12)
    }
    .frame(minWidth: 560, idealWidth: 640, minHeight: 360, idealHeight: 420)
  }
}

// MARK: - Inputs & Outputs

/// The read-only half of `VariableTab`.
private struct VariablesPane: View {
  let analysis: CircuitAnalysis.Analysis

  var body: some View {
    List {
      Section("Inputs") {
        if analysis.inputVariables.isEmpty {
          Text("This circuit has no input pins.").foregroundStyle(.secondary)
        }
        ForEach(analysis.inputVariables, id: \.name) { variable in
          row(variable)
        }
      }
      Section("Outputs") {
        if analysis.outputVariables.isEmpty {
          Text("This circuit has no output pins.").foregroundStyle(.secondary)
        }
        ForEach(analysis.outputVariables, id: \.name) { variable in
          row(variable)
        }
      }
    }
  }

  private func row(_ variable: Var) -> some View {
    HStack {
      Text(variable.name).font(.system(.body, design: .monospaced))
      Spacer()
      Text(variable.width == 1 ? "1 bit" : "\(variable.width) bits")
        .foregroundStyle(.secondary)
    }
  }
}

// MARK: - Table

/// The read-only half of `TableTab`.
///
/// Rows come from the model's *visible* row list (`visibleRowCount` / `visibleInputEntry`),
/// which is what upstream's table paints, so if a later change compacts don't-care rows, this
/// follows without knowing about it. Lazy, because `MAX_INPUTS = 20` allows 1,048,576 rows and
/// upstream renders every one of them into a single `JPanel`.
private struct TruthTablePane: View {
  let analysis: CircuitAnalysis.Analysis

  private var table: TruthTable { analysis.truthTable }

  var body: some View {
    if !analysis.tableComputed {
      ContentUnavailableView {
        Label("No Truth Table", systemImage: "tablecells")
      } description: {
        Text(
          "A truth table needs at least one input pin and one output pin. "
            + "Upstream stops on the Inputs/Outputs tab here too.")
      }
    } else {
      ScrollView([.horizontal, .vertical]) {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
          Section {
            ForEach(0..<table.visibleRowCount, id: \.self) { row in
              rowView(row)
            }
          } header: {
            headerRow
          }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
      }
    }
  }

  private var headerRow: some View {
    HStack(spacing: 0) {
      ForEach(0..<table.inputColumnCount, id: \.self) { column in
        cell(table.inputHeader(column), bold: true)
      }
      separator
      ForEach(0..<table.outputColumnCount, id: \.self) { column in
        cell(table.outputHeader(column), bold: true)
      }
    }
    .padding(.vertical, 4)
    .background(.background)
    .overlay(alignment: .bottom) { Divider() }
  }

  private func rowView(_ row: Int) -> some View {
    HStack(spacing: 0) {
      ForEach(0..<table.inputColumnCount, id: \.self) { column in
        cell(text(table.visibleInputEntry(row: row, column: column)))
      }
      separator
      ForEach(0..<table.outputColumnCount, id: \.self) { column in
        cell(text(table.visibleOutputEntry(row: row, column: column)))
      }
    }
    .background(row.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.04))
  }

  /// `Entry.getDescription()` in the default `AppPreferences` characters; the model already
  /// carries them as `EntryCharacters.standard`, so the window does not invent its own.
  private func text(_ entry: Entry) -> String {
    entry.description(chars: .standard)
  }

  private var separator: some View {
    Rectangle()
      .frame(width: 1)
      .foregroundStyle(.separator)
      .padding(.horizontal, 6)
  }

  private func cell(_ text: String, bold: Bool = false) -> some View {
    Text(text)
      .font(.system(.body, design: .monospaced).weight(bold ? .semibold : .regular))
      .frame(minWidth: 34, alignment: .center)
      .padding(.vertical, 2)
  }
}

// MARK: - Expression (board #92)

/// `ExpressionTab`'s Swing, with `ExpressionEntryModel` standing in for its three inner classes.
///
/// Upstream's table is a `JTable` whose cell renderer is a pretty-printed `ExpressionView` and
/// whose cell *editor* is a `JTextField` with a `name =` buddy label, reached by double-click or
/// F2. Here every row is a field all the time and focus is what opens the editor; a `JTable`
/// with one editable column is a Swing idiom, not a Mac one, and the double-click gate exists
/// upstream only because the same widget has to be a grid. What is *not* softened is which
/// parser each path uses, or where an error lands: the row field commits through `Parser.parse`
/// and the import field through `Parser.parseMaybeAssignment`, exactly as upstream splits them.
private struct ExpressionEntryPane: View {
  @Bindable var entry: ExpressionEntryModel
  let analysis: CircuitAnalysis.Analysis

  @State private var pendingImport: String = ""
  @FocusState private var focusedRow: Int?

  var body: some View {
    if entry.rows.isEmpty {
      ContentUnavailableView {
        Label("No Outputs", systemImage: "function")
      } description: {
        Text("This circuit has no output pins, so there is no expression to write.")
      }
    } else {
      VStack(alignment: .leading, spacing: 0) {
        control
        Divider()
        rowList
        Divider()
        importRow
        errorLabel
      }
      // `MyChangeListener.stateChanged` (Analyzer.java:53-57): selecting a tab calls
      // `tab.updateTab()`, which re-reads every row from the model. It is what repairs a row
      // that `setValueAt` blanked, see `anEmptyFieldIsANoOpOnTheModelAndBlanksTheRow`.
      .onAppear { entry.updateTab() }
      .onChange(of: focusedRow) { _, row in
        // `getTableCellEditorComponent` on entry, `cancelCellEditing` on exit. A Swing cell
        // editor is likewise torn down, and by default discards, when focus leaves it.
        if let row { entry.beginEditing(row: row) } else { entry.cancelEditing() }
      }
    }
  }

  /// `ExpressionTab.control()`: the notation label and combo.
  private var control: some View {
    HStack(spacing: 8) {
      Text(entry.notationLabel)
      Picker("", selection: $entry.notation) {
        ForEach(ExpressionEntryModel.notationChoices, id: \.self) { choice in
          Text(ExpressionEntryModel.notationName(choice)).tag(choice)
        }
      }
      .labelsHidden()
      .frame(maxWidth: 260)
      Spacer()
    }
    .padding(12)
  }

  private var rowList: some View {
    VStack(alignment: .leading, spacing: 0) {
      // `infoLabel`, S.get("outputExpressionEdit").
      Text(entry.infoLabel)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.top, 8)
      ScrollView {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(Array(entry.rows.enumerated()), id: \.element.id) { index, row in
            HStack(spacing: 6) {
              // `BuddySupport.addLeft(label, field)` with " name = ".
              Text("\(row.name) =")
                .font(.system(.body, design: .monospaced).weight(.semibold))
              SelectingTextField(
                text: fieldBinding(index),
                selection: entry.editingRow == index ? entry.errorSelection : nil,
                onSubmit: { _ = entry.commitEditing() })
                .focused($focusedRow, equals: index)
            }
          }
        }
        .padding(12)
      }
      .frame(maxHeight: .infinity)
    }
  }

  /// The row field: the *editor's* text while this row is being edited (`expr.toString()`,
  /// mathematical, Expression.java:466), the *renderer's* text otherwise (the combo's notation).
  private func fieldBinding(_ index: Int) -> Binding<String> {
    Binding(
      get: { entry.editingRow == index ? entry.draft : entry.displayText(row: index) },
      set: { newValue in
        if entry.editingRow != index { entry.beginEditing(row: index) }
        entry.draft = newValue
      })
  }

  /// `ExpressionTransferHandler.importData`'s way in. Upstream reaches it from the Edit menu's
  /// Paste and from a drop on the table; the tab's own `LogisimMenuBar` wiring is not this file
  /// set's to add, so the same call gets an explicit field and a Paste button. This is the path
  /// that accepts the assignment form `q = a + b`, which the per-row fields deliberately reject.
  private var importRow: some View {
    HStack(spacing: 8) {
      SelectingTextField(
        text: $pendingImport,
        selection: entry.editingRow == nil ? entry.errorSelection : nil,
        onSubmit: submitImport)
      Button("Set") { submitImport() }
        .disabled(pendingImport.isEmpty)
      Button("Paste") {
        if let text = NSPasteboard.general.string(forType: .string) {
          pendingImport = text
          submitImport()
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.top, 10)
  }

  private func submitImport() {
    // `importData` returns false for all three rejections; only the parser one leaves a message
    // behind, and the field is kept on a rejection so the highlighted run is still on screen.
    if entry.importText(pendingImport) { pendingImport = "" }
  }

  /// The `error` JLabel. Upstream keeps it at a constant `" "` when there is nothing to say, so
  /// the layout does not jump; a fixed-height row does the same thing.
  private var errorLabel: some View {
    Text(entry.errorMessage ?? " ")
      .font(.caption)
      .foregroundStyle(entry.errorMessage == nil ? .secondary : Color.red)
      .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
      .padding(.horizontal, 12)
      .padding(.bottom, 10)
      .textSelection(.enabled)
  }
}

/// An `NSTextField` that can be told to select a range of its own text.
///
/// It exists for one line of upstream, ExpressionTab.java:285-286:
///
///     field.setCaretPosition(ex.getOffset());
///     field.moveCaretPosition(ex.getEndOffset());
///
/// SwiftUI's `TextField` has no selection API at all, so a field that merely showed the message
/// would drop the offsets `ParserError` carries, which is the whole difference between "invalid
/// expression" and pointing at the character that is wrong. The offsets are `Character` indices
/// (see `ParserError.offset`) and are converted to UTF-16 here, at the only place that needs it.
/// Internal rather than private so `utf16Range`, the one piece of arithmetic in it, is
/// reachable from a test without an NSView on screen.
struct SelectingTextField: NSViewRepresentable {
  @Binding var text: String
  var selection: Range<Int>?
  var onSubmit: () -> Void

  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField(string: text)
    field.delegate = context.coordinator
    field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    field.bezelStyle = .roundedBezel
    field.lineBreakMode = .byClipping
    field.cell?.usesSingleLineMode = true
    return field
  }

  func updateNSView(_ field: NSTextField, context: Context) {
    context.coordinator.parent = self
    if field.stringValue != text { field.stringValue = text }
    // Apply a selection once per distinct range, or every keystroke would re-select it and the
    // field would be impossible to type in.
    guard let selection, context.coordinator.appliedSelection != selection else {
      if selection == nil { context.coordinator.appliedSelection = nil }
      return
    }
    context.coordinator.appliedSelection = selection
    // `field.currentEditor()` is non-nil only while the field is first responder, which is the
    // same precondition upstream's `field.setCaretPosition` has, since the cell editor's field
    // holds focus when `ok()` fails. Untestable headlessly: a view that is never in a window
    // never has a field editor. `applySelection` below is the part that IS testable, and is
    // separated out for exactly that reason rather than left inline where a test could not
    // reach it.
    Self.applySelection(selection, to: field.currentEditor(), in: field.stringValue)
  }

  /// ExpressionTab.java:285-286, the two lines this whole type exists for:
  ///
  ///     field.setCaretPosition(ex.getOffset());
  ///     field.moveCaretPosition(ex.getEndOffset());
  ///
  /// Anchor plus extend is one `selectedRange` on AppKit's field editor.
  static func applySelection(_ range: Range<Int>?, to editor: NSText?, in string: String) {
    guard let range, let editor else { return }
    editor.selectedRange = utf16Range(of: range, in: string)
  }

  /// `Character` offsets → UTF-16, clamped to the string. A parser error can point one past the
  /// end (`"q = "` reports the `=` at the last token, and an implicit-AND error carries length
  /// 0), so the clamp is not decoration.
  static func utf16Range(of range: Range<Int>, in string: String) -> NSRange {
    let count = string.count
    let lower = max(0, min(range.lowerBound, count))
    let upper = max(lower, min(range.upperBound, count))
    let start = string.index(string.startIndex, offsetBy: lower)
    let end = string.index(string.startIndex, offsetBy: upper)
    let utf16Start = string.utf16.distance(from: string.utf16.startIndex, to: start.samePosition(in: string.utf16) ?? string.utf16.startIndex)
    let utf16End = string.utf16.distance(from: string.utf16.startIndex, to: end.samePosition(in: string.utf16) ?? string.utf16.endIndex)
    return NSRange(location: utf16Start, length: max(0, utf16End - utf16Start))
  }

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: SelectingTextField
    var appliedSelection: Range<Int>?

    init(parent: SelectingTextField) { self.parent = parent }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      appliedSelection = nil
      parent.text = field.stringValue
    }

    func control(
      _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
      if selector == #selector(NSResponder.insertNewline(_:)) {
        parent.onSubmit()
        return true
      }
      return false
    }
  }
}

// MARK: - Minimized expressions

/// The expression half of `MinimizedTab`, minus the K-map and the Build Circuit button.
private struct MinimizedPane: View {
  let presentation: AnalyzerPresentation
  let analysis: CircuitAnalysis.Analysis

  var body: some View {
    if !analysis.tableComputed {
      ContentUnavailableView {
        Label("No Expressions", systemImage: "function")
      } description: {
        Text("Expressions are minimised from the truth table, and there is no table.")
      }
    } else {
      List {
        Section {
          ForEach(analysis.model.outputs.bits, id: \.self) { bit in
            VStack(alignment: .leading, spacing: 4) {
              Text(bit).font(.system(.body, design: .monospaced).weight(.semibold))
              Text(expression(for: bit))
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            }
            .padding(.vertical, 2)
          }
        } footer: {
          // Honest about where these came from: this is the same derivation upstream shows on
          // its Minimized tab in BOTH of its paths (see CircuitAnalysis's header).
          Text(footerText)
        }
      }
    }
  }

  /// Which of the three states the numbers above are in. The third is the one board #68 is
  /// about, and saying it out loud is half the fix: before the Minimize button existed, a
  /// >6-input circuit showed `0` for every output with nothing on screen explaining why.
  private var footerText: String {
    if let outcome = presentation.minimization {
      let form =
        outcome.format == AnalyzerModel.formatProductOfSums
        ? "product-of-sums" : "sum-of-products"
      return
        "Minimised on request by Quine-McCluskey with Petrick cover selection, in \(form) form."
    }
    if analysis.truthTable.inputColumnCount > Implicant.maximalNrOfInputsForAutoMinimalForm {
      return
        "Not minimised: past \(Implicant.maximalNrOfInputsForAutoMinimalForm) input bits "
        + "Quine-McCluskey is not run unasked, so these are the guard\u{2019}s answer, not the "
        + "minimal expressions. Use Optimize Minterms or Optimize Maxterms below."
    }
    return
      "Minimised from the truth table by Quine-McCluskey with Petrick cover selection, "
      + "in sum-of-products form."
  }

  private func expression(for bit: String) -> String {
    guard let expression = presentation.minimalExpression(for: bit) else {
      return "—"
    }
    let text = expression.toString(.mathematical)
    // Java prints an empty string for the constant-false expression; say so instead.
    return text.isEmpty ? "0" : text
  }
}
