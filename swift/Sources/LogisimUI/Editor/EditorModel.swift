// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ============================================================================
// ONE WINDOW'S WORTH OF STATE.
//
// Upstream's `Frame` is a 769-line `JFrame` that owns the canvas, the toolbar model,
// two `JTabbedPane`s, four split panes, the zoom model, the attribute table, the VHDL
// console, the HDL editor, the appearance editor and a `java.util.Timer`: and also
// implements `LocaleListener`, `ProjectListener`, `LibraryListener` and `CircuitListener`
// through a private inner class that switches on event codes. View, controller and
// several models, in one object.
//
// Here the window is a pure function of this object. `EditorModel` holds no views, and
// views hold no state that is not view-local (scroll position, disclosure, focus). That
// is what makes the canvas host replaceable, the inspector previewable, and the whole
// shell testable without a screen.
// ============================================================================

import AppKit
import CoreGraphics
import Foundation
import LogisimFile
import Observation
import SwiftUI

/// Which of the two sidebar roles is showing.
///
/// Upstream stacks these as unlabelled tabs in a `JTabbedPane` whose tab titles are set
/// from the locale bundle (`Frame.java:181-185`), inside another split pane that also
/// contains the attribute table. So the sidebar is four things at once and the attribute
/// table is trapped inside it, permanently as wide as the explorer.
public enum SidebarMode: String, CaseIterable, Sendable, Identifiable {
  case design
  case simulation

  public var id: String { rawValue }
  public var displayName: String {
    switch self {
    case .design: return "Design"
    case .simulation: return "Simulate"
    }
  }
  public var symbolName: String {
    switch self {
    case .design: return "square.grid.2x2"
    case .simulation: return "waveform.path.ecg"
    }
  }
}

/// Which editor is showing in the centre pane.
///
/// `Frame` does this with a `CardPanel` keyed by the string constants `"layout"`,
/// `"appearance"` and `"hdl"` (`Frame.java:79-82`) plus a `lastFraction` double it has to
/// stash and restore by hand every time the HDL editor appears. An enum plus SwiftUI's
/// own transition machinery replaces all of it.
public enum CentreView: String, CaseIterable, Sendable, Identifiable {
  case layout
  case appearance
  case hdl

  public var id: String { rawValue }
  public var displayName: String {
    switch self {
    case .layout: return "Layout"
    case .appearance: return "Appearance"
    case .hdl: return "HDL"
    }
  }
  public var symbolName: String {
    switch self {
    case .layout: return "square.grid.3x3"
    case .appearance: return "paintbrush"
    case .hdl: return "doc.plaintext"
    }
  }
}

@MainActor
@Observable
public final class EditorModel {

  // MARK: Projected model state (pulled on ProjectChange)

  public private(set) var displayName = "Untitled"
  public private(set) var fileURL: URL?
  public private(set) var isDirty = false
  public private(set) var outline = ProjectOutline()
  public private(set) var currentCircuit: CircuitID?
  public private(set) var activeTool: ToolID?
  public private(set) var selection: EditorSelection = .nothing
  public private(set) var inspectorForm: InspectorForm = .empty
  public private(set) var simulation = SimulationStatus()
  public private(set) var undoStatus = UndoStatus()

  // MARK: Shell-owned view state

  /// The camera. Owned here, not by the renderer and not by a scroll view: see the long
  /// note on issue #1262 in `CanvasViewport`.
  public var viewport = CanvasViewport()
  public var sidebarMode: SidebarMode = .design
  public var centreView: CentreView = .layout
  public var searchText = ""
  public var isInspectorPresented = true
  public var columnVisibility: NavigationSplitViewVisibility = .all
  public var issues: [UserFacingIssue] = []
  public var transientError: String?
  public var hoveredTarget: CanvasHitTarget?
  /// Set by the canvas host so the toolbar can show a live coordinate readout; upstream
  /// has no coordinate feedback at all, which makes precise placement guesswork.
  public var pointerWorldLocation: CGPoint?

  // MARK: Collaborators

  public let host: any ProjectHost
  public let preferences: EditorPreferences
  public let surface: any CircuitRenderSurface

  private var observation: ProjectObservation?

  public init(host: any ProjectHost, preferences: EditorPreferences = .shared) {
    self.host = host
    self.preferences = preferences
    self.surface = host.makeRenderSurface()
    observation = host.addObserver { [weak self] change in
      self?.pull(change)
    }
    pull(.all)
    issues = host.drainPendingIssues()
    if selection == .nothing, let circuit = currentCircuit {
      host.setSelection(.circuit(circuit))
    }
  }

  // MARK: - Change intake

  /// Re-pull whatever the host says moved. Coarse by design: snapshots are value types,
  /// and applying deltas by hand is where model/UI divergence lives.
  private func pull(_ change: ProjectChange) {
    if change.contains(.outline) { outline = host.outline }
    if change.contains(.currentCircuit) { currentCircuit = host.currentCircuit }
    if change.contains(.activeTool) { activeTool = host.activeTool }
    if change.contains(.dirtyState) {
      isDirty = host.isDirty
      displayName = host.displayName
      fileURL = host.fileURL
    }
    if change.contains(.simulation) { simulation = host.simulation }
    if change.contains(.undoStack) { undoStatus = host.undoStatus }
    if change.contains(.selection) {
      selection = host.selection
      inspectorForm = host.inspectorForm(for: selection)
    } else if change.contains(.attributes) {
      inspectorForm = host.inspectorForm(for: selection)
    }
    if change.contains(.geometry) { surface.invalidate(worldRect: nil) }
    let drained = host.drainPendingIssues()
    if !drained.isEmpty { issues.append(contentsOf: drained) }
  }

  // MARK: - Selection

  public func select(circuit id: CircuitID) {
    try? host.perform(.setCurrentCircuit(id))
  }

  public func select(tool id: ToolID) {
    try? host.perform(.selectTool(id))
    host.setSelection(.tool(id))
  }

  public func selectComponents(_ ids: Set<ComponentID>) {
    host.setSelection(ids.isEmpty ? .nothing : .components(ids))
  }

  /// Explorer → canvas. Reveals without changing zoom, which is the behaviour a schematic
  /// wants: jumping the zoom as well loses the reader's place.
  public func reveal(_ id: ComponentID) {
    guard let rect = host.bounds(of: id) else { return }
    viewport.reveal(rect)
    surface.setViewport(viewport)
    selectComponents([id])
  }

  // MARK: - Attribute editing

  public func apply(_ edit: AttributeEdit) {
    do {
      try host.apply(edit)
      transientError = nil
    } catch {
      // D13's principle carried into the UI: a rejected value is a message, never a trap
      // and never a silent no-op.
      transientError = error.localizedDescription
    }
  }

  // MARK: - Commands

  public func canPerform(_ command: ProjectCommand) -> Bool {
    // `LayoutEditHandler.computeEnabled()` before anything else, because upstream's answer for
    // these six does not depend on the document at all. See `layoutModeEditCommand`.
    if let edit = Self.layoutModeEditCommand(for: command),
      SelectionEditHandler.isDisabledInLayoutMode(edit)
    {
      return false
    }
    // The shell-owned commands answer for themselves, for the same reason `perform` intercepts
    // them: the host cannot be asked a question about a window it does not own. Everything else
    // is the document's business.
    switch command {
    case .analyzeCircuit: return analyzableCircuit != nil
    case .circuitStatistics: return circuitStatisticsReport() != nil
    // `MainMenuListener$ProjectMenuListener.computeEnabled()`, from the 4.1.0 jar. It reads
    // `frame.getEditorView()` once into a local and then:
    //
    //     final var viewAppearance = view.equals("appearance");
    //     final var viewLayout     = view.equals("layout");
    //     …
    //     menubar.setEnabled(LogisimMenuBar.EDIT_LAYOUT, viewAppearance);
    //     menubar.setEnabled(LogisimMenuBar.EDIT_APPEARANCE, viewLayout);
    //     menubar.setEnabled(LogisimMenuBar.TOGGLE_APPEARANCE, true);
    //
    // So each of the two named items is enabled only from the *other* editor; "Edit Circuit
    // Layout" is greyed while the layout editor is already showing, and the toggle is always
    // enabled. This is the one disposition D11 still allows after its 2026-09-08 rewrite: not
    // "the feature is missing", but "4.1.0 itself disables it in this state", the same clause
    // `layoutModeEditCommand` below rests on.
    //
    // Note what the two `equals` calls do from the HDL card: both are false, so upstream greys
    // BOTH items and leaves only the toggle. Reproduced rather than smoothed over, and it is not
    // a trap, because the toggle is the way out. LATENT either way; nothing assigns `.hdl` yet.
    case .editLayout: return centreView == .appearance
    case .editAppearance: return centreView == .layout
    case .toggleLayoutAppearance: return true
    default: break
    }
    return host.canPerform(command)
  }

  public func perform(_ command: ProjectCommand) {
    // A few commands are the shell's own business: they never reach the model.
    switch command {
    case .selectTool(let id): select(tool: id); return
    case .revealComponent(let id): reveal(id); return
    case .print: presentPrintPanel(); return
    case .analyzeCircuit: presentAnalyzer(); return
    case .circuitStatistics: presentCircuitStatistics(); return
    // `MenuProject`'s three view items (`projectEditCircuitLayoutItem`,
    // `projectEditCircuitAppearanceItem`, `projectToggleCircuitAppearanceItem`; the string keys
    // are in the 4.1.0 jar's `MenuProject`). Upstream's handler calls
    // `frame.setEditorView(Frame.EDIT_LAYOUT)` / `EDIT_APPEARANCE`, which is the `CardPanel`
    // switch `CentreView` replaces; see that enum's own comment. So these are shell state by
    // construction and there is nothing for the host to do with them, which is why they used to
    // land in its `default:` arm and report themselves unimplemented while the View menu, setting
    // `centreView` directly, worked. Two paths to one piece of state, one of them a lie. This is
    // now the only path: `AppCommands.viewCommands` sends the command.
    case .editLayout: centreView = .layout; return
    case .editAppearance: centreView = .appearance; return
    case .toggleLayoutAppearance:
      // `MainMenuListener$ProjectMenuListener.actionPerformed`, TOGGLE_APPEARANCE branch, from the
      // 4.1.0 jar:
      //
      //     final var viewAppearance = frame.getEditorView().equals("appearance");
      //     frame.setEditorView(viewAppearance ? "layout" : "appearance");
      //
      // The test is `== appearance`, **not** `== layout`, and the difference is the third card.
      // `CentreView` has an `.hdl` case (upstream's `Frame.EDIT_HDL`), and the expression this
      // replaced: `centreView == .layout ? .appearance : .layout`: sent HDL to *layout* where
      // upstream sends it to appearance. LATENT rather than live: nothing in the shipping shell
      // assigns `.hdl` yet (the HDL editor is unported, so `Project.restoreEditingContext`'s
      // `hdlModel` arm has no view to switch to), so no click can reach it today. Written the
      // upstream way now because the day something does assign it, a toggle that jumps to the
      // wrong card is a bug nobody will think to look for here.
      centreView = centreView == .appearance ? .layout : .appearance
      return
    default: break
    }
    if let edit = Self.layoutModeEditCommand(for: command),
      SelectionEditHandler.isDisabledInLayoutMode(edit)
    {
      reportLayoutModeOnly(edit)
      return
    }
    do {
      try host.perform(command)
      transientError = nil
    } catch {
      transientError = error.localizedDescription
      issues.append(
        UserFacingIssue(
          severity: .warning, title: "Command unavailable",
          detail: error.localizedDescription))
    }
  }

  public func perform(_ command: SimulationCommand) {
    host.perform(command)
  }

  // MARK: - The appearance-editor commands, in layout mode

  /// The `ProjectCommand` → `SelectionEditCommand` half of the crossing, for the six commands
  /// `LayoutEditHandler` answers for and this port had split across two different answers.
  ///
  /// Only the six are mapped. Cut/Copy/Paste/Delete/Duplicate/Select All have real, document-
  /// dependent enablement that belongs to whoever holds the file, and routing them through here
  /// would move a live rule out of the host for no gain; this function exists precisely because
  /// upstream's answer for the *other* six is a constant.
  ///
  /// Placed in `EditorModel` rather than in the project host on purpose, and the placement is the
  /// design question this change had to answer. Upstream's `EditHandler` is installed by `Frame`
  /// and swapped per editor, `LayoutEditHandler` for the schematic,
  /// `AppearanceEditHandler` for the appearance canvas, so "may this command run?" is decided by
  /// **which editor is showing**, which is shell state (`centreView` here), not document state.
  /// The host cannot answer it without being told what is on screen, and telling it would put a
  /// view concern inside the document. That is why `LogisimFileProjectHost.canPerform`'s
  /// `!selection.isEmpty` was wrong rather than merely incomplete: a non-empty selection is a
  /// true fact about the document and still the wrong reason.
  ///
  /// The corollary, and the reason nothing here mutates: when the appearance editor lands, this
  /// interception grows a `centreView == .appearance` arm that routes to an
  /// `AppearanceEditHandler`, and these six light up. Wiring them to the layout `Circuit` today
  /// would be work that has to be deleted then, on top of being unfaithful now.
  static func layoutModeEditCommand(for command: ProjectCommand) -> SelectionEditCommand? {
    switch command {
    case .raise: return .raise
    case .lower: return .lower
    case .raiseToTop: return .raiseTop
    case .lowerToBottom: return .lowerBottom
    case .addControlPoint: return .addControlPoint
    case .removeControlPoint: return .removeControlPoint
    default: return nil
    }
  }

  /// What a click on one of the six does *today*.
  ///
  /// `LayoutEditHandler.raise()` and its five siblings disassemble to `0: return`; upstream does
  /// nothing, because upstream's item is greyed and the method is unreachable. A silent no-op is
  /// therefore the faithful body, and it is **not** what this does, for one reason: the port's
  /// `AppCommands.arrangeCommands` attaches no `.disabled(...)` to Bring to Front / Bring Forward
  /// / Send Backward / Send to Back, so the items are still clickable however this model answers
  /// `canPerform`. Until that modifier lands, a click has to say something, and an `.info` that
  /// names the appearance editor is the honest thing to say; the command is not broken, it is
  /// not applicable here.
  ///
  /// **Delete this method when `AppCommands` greys the items.** At that point the branch becomes
  /// unreachable from any control and should go back to matching upstream's empty body. The exact
  /// lines the integrator needs are in this change's report.
  private func reportLayoutModeOnly(_ edit: SelectionEditCommand) {
    // Two different reasons, and they are not interchangeable. Z-order is missing because a
    // `Circuit` stores components in a set; control points are missing because a schematic
    // component is a placed factory instance and has no editable geometry at all. One shared
    // sentence would have been wrong for one of the pairs, which is why they are split.
    let label: String
    let reason: String
    switch edit {
    case .raise, .lower, .raiseTop, .lowerBottom:
      switch edit {
      case .raise: label = "Bring Forward"
      case .lower: label = "Send Backward"
      case .raiseTop: label = "Bring to Front"
      default: label = "Send to Back"
      }
      reason =
        "A schematic has no front-to-back order — a circuit holds its components in a set, so "
        + "there is no front to bring anything to. The appearance editor draws a shape list, "
        + "which does."
    default:
      label = edit == .addControlPoint ? "Add Control Point" : "Remove Control Point"
      reason =
        "Control points belong to a drawn shape. A schematic component is a placed factory "
        + "instance with a fixed footprint, so there is no outline to add a point to."
    }
    transientError = nil
    issues.append(
      UserFacingIssue(
        severity: .info,
        title: "\(label) applies to the appearance editor",
        detail: reason
          + " Logisim-evolution 4.1.0 greys this item out while the layout editor is showing and "
          + "enables it only in the appearance editor."))
  }

  /// `Print.doPrint(Project)`: the shell's business, like `.selectTool` above, because it ends
  /// in an `NSPrintOperation` and never touches the model.
  ///
  /// The one thing worth watching here: `printerView` is passed to the host **from the same
  /// `settings` value** the pages are later drawn with. They decide different halves of the same
  /// question, the host's copy chooses what the renderer emits, the drawing copy chooses the
  /// header and rotation, and reading them from one value is what stops the two drifting into a
  /// printout whose ink does not match its settings.
  /// Everything the print panel needs, gathered but not presented.
  ///
  /// Split out so the wiring is testable: `CircuitPrintCommand.run` ends in
  /// `NSPrintOperation.run()`, which puts up a modal panel and would hang a test run, so no test
  /// may call it. What a test *can* check is that the model asks the host for the right pages
  /// with the right settings, and that is all of this method. The one line left unasserted is
  /// the hand-off itself: deliberately, since a test that only checks "an `NSPrintOperation`
  /// was constructed" passes against a version that prints a blank page.
  func printJob() -> PrintJob {
    let settings = PrintJobSettings()
    let appearance = preferences.canvasAppearanceTemplate
    return PrintJob(
      settings: settings,
      circuits: host.printablePages(appearance: appearance, printerView: settings.printerView),
      appearance: appearance)
  }

  /// The hand-off, held as a closure **so that a test can prove `.print` is intercepted at all**
  /// without a modal panel appearing. Without this the interception is the one line in the chain
  /// no probe can redden: every other assertion calls `printJob()` directly and would stay green
  /// with `case .print` deleted from `perform`, which is exactly the unowned join this file
  /// exists to gate. Nothing but a test ever replaces it.
  var printPresenter: @MainActor (PrintJob) -> Void = { job in
    CircuitPrintCommand.run(
      circuits: job.circuits, settings: job.settings, appearance: job.appearance)
  }

  private func presentPrintPanel() { printPresenter(printJob()) }

  // MARK: - Combinational analysis

  /// `ProjectMenuListener` ▸ `projectAnalyzeCircuitItem` → `Analyze.computeTable` inside
  /// `AnalyzerManager.getAnalyzer(parent)`, which upstream reaches through a **static** holder:
  /// one `Analyzer` frame for the whole application, not one per project.
  ///
  /// Intercepted here rather than in the host for exactly that reason, and the reasoning is
  /// already written down in `AppCommands.circuitCommands`; the host owns the *document*, and a
  /// process-wide window is not one. What is new is that the interception exists at all. Before
  /// this, `AppCommands` reached `AnalyzerWindowController` directly and `.analyzeCircuit` fell
  /// into `LogisimFileProjectHost.perform`'s `default:` arm, which throws `notImplemented`. That
  /// was not merely untidy: `ExplorerSidebar`'s circuit context menu **sends the command**
  /// (`ExplorerSidebar.swift:255`), so right-clicking a circuit and choosing Analyze Circuit…
  /// produced a "Command unavailable; analyzeCircuit is not implemented yet." banner while the
  /// identical item in the Circuit menu opened the window. A live defect on the affordance a
  /// first-year lab reaches for most, and reachable by an ordinary click.
  ///
  /// So the command is now the single path and both producers go through it.
  private func presentAnalyzer() {
    // No `guard else { report }`: `canPerform` answers `analyzableCircuit != nil` for this
    // command, both producers carry `.disabled` from it, and upstream's item is likewise
    // enabled only with a circuit showing. Silently returning is what 4.1.0's unreachable
    // handler body does.
    guard let target = analyzableCircuit else { return }
    analyzerPresenter(target.circuit, target.file)
  }

  /// The hand-off, replaceable for the same reason `printPresenter` is: the real one ends in
  /// `NSApp.activate()`, and `AnalyzerWindowController.show`'s own comment says a test must not
  /// call it or the suite steals focus from whoever is at the keyboard. Holding it here is what
  /// lets a test prove the interception happens *and* that it passes the circuit the editor is
  /// actually showing; a probe that only checked "no error was reported" would stay green
  /// against a presenter handed the wrong circuit. Nothing but a test ever replaces it.
  var analyzerPresenter: @MainActor (Circuit, LogisimFile) -> Void = { circuit, file in
    AnalyzerWindowController.shared.show(circuit: circuit, file: file)
  }

  // MARK: - Circuit statistics

  /// The hand-off for `.circuitStatistics`, replaceable for the same reason as
  /// `analyzerPresenter`: the real presenter orders an AppKit window front, while tests need to
  /// prove the command and its payload without activating the application. Upstream calls
  /// `StatisticsDialog.show(frame, file, circuit)` from the project menu listener; the table is
  /// read-only and computed from `FileStatistics`, so the host has no mutation to own.
  var circuitStatisticsPresenter: @MainActor (CircuitStatisticsReport) -> Void = { report in
    CircuitStatisticsWindowController.shared.show(report)
  }

  // MARK: - Camera

  public func zoomIn() { setZoom(CanvasZoom.next(after: viewport.zoom)) }
  public func zoomOut() { setZoom(CanvasZoom.previous(before: viewport.zoom)) }
  public func zoomToActualSize() { setZoom(1) }

  public func setZoom(_ value: Double) {
    // Keyboard and menu zoom anchor on the view centre; pointer zoom anchors on the
    // pointer. Both are exact, because there is a camera to be exact about.
    viewport.zoom(to: value, anchoringWorldPoint: viewport.center)
    surface.setViewport(viewport)
  }

  public func zoomToFit() {
    let bounds = surface.contentBounds
    viewport.fit(bounds.isNull ? CGRect(x: 0, y: 0, width: 400, height: 300) : bounds)
    surface.setViewport(viewport)
  }

  public func zoomToSelection() {
    let ids = selection.componentIDs
    guard !ids.isEmpty else { return zoomToFit() }
    let rect = ids.compactMap { host.bounds(of: $0) }.reduce(CGRect.null) { $0.union($1) }
    guard !rect.isNull else { return zoomToFit() }
    viewport.fit(rect.insetBy(dx: -20, dy: -20))
    surface.setViewport(viewport)
  }

  // MARK: - Derived presentation

  public var windowSubtitle: String {
    var parts: [String] = []
    if let name = currentCircuit.flatMap({ outline.circuit($0)?.name }) { parts.append(name) }
    if simulation.isTicking {
      parts.append(SimulationStatus.tickFrequencyLabel(simulation.requestedTickHz))
    }
    return parts.joined(separator: " — ")
  }

  public var activeToolItem: ToolItem? { activeTool.flatMap { outline.tool($0) } }

  /// Filtered explorer content. Matching on the tool *and* its library name means typing
  /// "gates" finds the library and typing "xnor" finds the tool, which is the behaviour a
  /// 200-item palette needs and upstream's plain `JTree` does not have at all.
  public var filteredLibraries: [LibraryItem] {
    let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
    guard !query.isEmpty else {
      return preferences.showsUnavailableTools
        ? outline.libraries
        : outline.libraries.map { library in
          var copy = library
          copy.tools = library.tools.filter(\.isAvailable)
          return copy
        }.filter { !$0.tools.isEmpty }
    }
    return outline.libraries.compactMap { library in
      if library.name.lowercased().contains(query) { return library }
      let matches = library.tools.filter { $0.name.lowercased().contains(query) }
      guard !matches.isEmpty else { return nil }
      var copy = library
      copy.tools = matches
      return copy
    }
  }

  public var filteredCircuits: [CircuitItem] {
    let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
    guard !query.isEmpty else { return outline.circuits }
    return outline.circuits.filter { $0.name.lowercased().contains(query) }
  }

  public func dismissIssue(_ issue: UserFacingIssue) {
    issues.removeAll { $0.id == issue.id }
  }
}
