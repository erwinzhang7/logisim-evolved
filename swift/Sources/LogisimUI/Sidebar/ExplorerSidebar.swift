// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ============================================================================
// THE EXPLORER.
//
// Upstream puts four things in the left region, nested two split panes deep:
// a `JTabbedPane` of {Toolbox, SimulationExplorer}, over another `JTabbedPane` of
// {AttrTable, RegTabContent}, over a zoom strip (`Frame.java:143-190`). Consequences:
// the attribute table is permanently as wide as the explorer and as short as whatever
// the split leaves it; the tabs are unlabelled `JTabbedPane` indices; there is no search;
// and the toolbox `JTree` shows every builtin library expanded, so a fresh project opens
// with ~200 rows and the user's own circuits scrolled off the top.
//
// Here the sidebar does one job: navigate the project. Attributes moved to a real
// inspector on the trailing edge (where a Mac user looks for them), the zoom control
// moved onto the canvas (where the thing it zooms is), and the two explorer roles became
// an explicit mode switch instead of anonymous tabs.
//
// The one thing that departure had dropped was upstream's *toolbar* over the explorer: see
// `ExplorerAffordance` below, which is where the bottom action bar and its single button are
// justified against what 4.1.0 actually builds.
// ============================================================================

import AppKit
import SwiftUI

struct ExplorerSidebar: View {
  @Bindable var model: EditorModel

  var body: some View {
    VStack(spacing: 0) {
      modePicker
      Divider()
      content
      Divider()
      actionBar
    }
    .frame(minWidth: 220, idealWidth: 260)
    .searchable(
      text: $model.searchText, placement: .sidebar,
      prompt: model.sidebarMode == .design ? "Circuits and Components" : "States")
  }

  private var modePicker: some View {
    Picker("", selection: $model.sidebarMode) {
      ForEach(SidebarMode.allCases) { mode in
        Label(mode.displayName, systemImage: mode.symbolName).tag(mode)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
  }

  @ViewBuilder private var content: some View {
    switch model.sidebarMode {
    case .design: designList
    case .simulation: simulationList
    }
  }

  // MARK: - The action bar
  //
  // Shown in both modes rather than only in Design, and that is upstream's enablement rule
  // rather than laziness: each `ToolboxToolbarModel` item is a
  // `LogisimToolbarItem(MenuListener, Icon, LogisimMenuItem, StringGetter)`, so its enabled
  // state is the *menu item's*, `ADD_CIRCUIT`, and not the explorer tab's. Adding a circuit
  // while reading the state tree edits the same document either way.

  private var actionBar: some View {
    HStack(spacing: 2) {
      ForEach(ExplorerAffordance.actionBarItems, id: \.self) { item in
        switch item {
        case .command(let command, let symbol, let title, let shortcut):
          Button { model.perform(command) } label: { Self.icon(symbol) }
            .disabled(!model.canPerform(command))
            .help(shortcut.map { "\(title) (\($0))" } ?? title)
            .accessibilityLabel(title)

        case .spacer:
          Spacer(minLength: 0)

        // Points AT Settings; it does not duplicate anything in it. The same report that asked
        // where circuits are added also said "im not seeing lightmode toggle either", and the
        // light/dark control has been in Settings ▸ Appearance ▸ Theme the whole time; it was
        // moved there at this owner's own earlier request, so the answer is a signpost, not a
        // second control. `SettingsLink` opens the `Settings` scene `LogisimEvolvedApp.swift:79`
        // registers, which is the same window ⌘, opens; nothing here reads or writes a
        // preference, and `ExplorerAffordanceTests` asserts that this file never reaches the
        // theme preference by any of its spellings.
        case .settings(let symbol, let title, let shortcut):
          SettingsLink { Self.icon(symbol) }
            .help(shortcut.map { "\(title) (\($0))" } ?? title)
            .accessibilityLabel(title)
        }
      }
    }
    .buttonStyle(.borderless)
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
  }

  private static func icon(_ symbol: String) -> some View {
    Image(systemName: symbol)
      .frame(width: 22, height: 18)
      .contentShape(.rect)
  }

  // MARK: - Design

  private var designList: some View {
    List(selection: circuitSelection) {
      Section("Circuits") {
        ForEach(model.filteredCircuits) { circuit in
          CircuitRow(circuit: circuit, model: model)
            .tag(circuit.id)
        }
      }

      Section("Components") {
        ForEach(model.filteredLibraries) { library in
          LibraryDisclosure(library: library, model: model)
        }
      }
    }
    .listStyle(.sidebar)
    .contextMenu {
      // Same constant as the "+" button above, so the visible affordance and the hidden one
      // cannot drift apart; that is the whole reason `ExplorerAffordance.addCircuit` exists
      // rather than two `.addCircuit` literals.
      Button("Add Circuit…") { model.perform(ExplorerAffordance.addCircuit) }
      Button("Add VHDL Entity…") { model.perform(.addVhdlEntity) }
      Divider()
      Button("Load Built-in Library…") { model.perform(.loadBuiltinLibrary) }
        .disabled(!model.canPerform(.loadBuiltinLibrary))
        .help("Built-in library loading needs the chooser and undoable LoadLibraries action.")
      Button("Load Logisim Library…") { model.perform(.loadLogisimLibrary) }
        .disabled(!model.canPerform(.loadLogisimLibrary))
        .help("Logisim library loading needs the file importer and undoable LoadLibraries action.")
      Button("Load JAR Library…") { model.perform(.loadJarLibrary) }
        .disabled(!model.canPerform(.loadJarLibrary))
    }
  }

  /// Bridges `EditorSelection` (which is richer than a `List` selection can be) to a
  /// single-selection `List`. Only circuits participate; tools are selected by click, so
  /// clicking a tool does not blow away a canvas selection.
  private var circuitSelection: Binding<CircuitID?> {
    Binding(
      get: {
        if case .circuit(let id) = model.selection { return id }
        return model.currentCircuit
      },
      set: { id in if let id { model.select(circuit: id) } })
  }

  // MARK: - Simulation

  private var simulationList: some View {
    Group {
      if let root = model.outline.simulationRoot {
        List {
          Section("Simulation States") {
            OutlineGroup(root, children: \.optionalChildren) { node in
              SimulationRow(node: node, model: model)
            }
          }
        }
        .listStyle(.sidebar)
      } else {
        ContentUnavailableView(
          "No Simulation", systemImage: "waveform.path.ecg",
          description: Text("Open a circuit to see its state tree."))
      }
    }
  }
}

// MARK: - What the visible controls send

/// The commands the explorer's **visible** controls send, as named constants rather than literals
/// at each call site, plus the two decisions those controls need. Both exist so the part worth
/// testing is a value rather than a `Button`, the same split `CircuitRenameRequest` below uses and
/// for the same reason: there is no honest way to assert from a test that a menu item was drawn.
///
/// ## Why the explorer grew a visible bar at all
///
/// Reported from real use: *"how do u add more circuits and all those functions? this is missing a
/// ton."* Nothing was missing. `ProjectCommand.addCircuit` is WIRED, it is absent from
/// `CommandSurfaceAuditTests.expectedInert`, and `ExplorerAffordanceTests` performs it against a
/// real `LogisimFileProjectHost` and watches a circuit appear, and it already had two producers:
/// Circuit ▸ Add Circuit… (⇧⌘N, `AppCommands.swift:245`) and this list's own right-click menu.
/// Neither is visible, and a context menu with no visible affordance is not a feature a user can
/// find. So this is a discoverability defect, and the fix is an affordance rather than a command.
///
/// ## What 4.1.0 does — and it does have this bar
///
/// Measured from the shipping 4.1.0 jar's class constant pools
/// (`/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar`). Read
/// directly rather than with `javap` because no JDK is installed on this machine, which is why
/// the notes below name types and fields but never bytecode offsets:
///
/// - `gui/main/Toolbox` is a `JPanel(BorderLayout)` holding `Toolbar(ToolboxToolbarModel)` at
///   **`North`** and `ProjectExplorer`, inside a `JScrollPane`, at `Center`. So the explorer
///   upstream carries a button strip, above the tree.
/// - `gui/main/ToolboxToolbarModel` builds exactly six `LogisimToolbarItem`s, in this order:
///
///   | field            | icon                | menu item           | tooltip key                |
///   | ---------------- | ------------------- | ------------------- | -------------------------- |
///   | `itemAdd`        | `ProjectAddIcon`    | `ADD_CIRCUIT`       | `projectAddCircuitTip`     |
///   | `itemAddVhdl`    | none                | `ADD_VHDL`          | `projectAddVhdlItem`       |
///   | `itemUp`         | `FatArrowIcon`(N)   | `MOVE_CIRCUIT_UP`   | `projectMoveCircuitUpTip`  |
///   | `itemDown`       | `FatArrowIcon`(S)   | `MOVE_CIRCUIT_DOWN` | `projectMoveCircuitDownTip`|
///   | `itemAppearance` | `AppearEditIcon`    | `TOGGLE_APPEARANCE` | `projectEditAppearanceTip` |
///   | `itemDelete`     | none                | `REMOVE_CIRCUIT`    | `projectRemoveCircuitTip`  |
///
/// ## Why the bar is at the bottom, and why it holds one of those six
///
/// Placement is the only thing borrowed from the platform instead of from upstream: a Mac source
/// list puts its add/remove strip along the **bottom** edge (Finder's sidebar, Xcode's navigators,
/// System Settings' lists), and this pane is a source list. Nothing else about the explorer moved.
///
/// Of upstream's six items only `itemAdd` is promoted, and the omissions are deliberate:
///
/// - `itemAddVhdl` sends `.addVhdlEntity`, which is still pinned inert in
///   `CommandSurfaceAuditTests.expectedInert`; a visible button that says "not implemented yet"
///   is worse than no button. `itemAppearance` sends `.toggleLayoutAppearance`, which is now
///   wired but already has a menu home and answers no part of the "how do I add circuits?"
///   report. Both stay in the context menu / the View menu, which is where they already were.
/// - `itemDelete` sends `.removeCircuit`, which *is* wired, and is still not promoted. It is not
///   undoable in this port yet, and this port shows no confirmation where upstream confirms
///   removal unconditionally, so a one-click destroy sitting next to the "+" would be a trap. It
///   stays in a circuit row's context menu, where it costs deliberate intent, until both of those
///   are fixed.
/// - `itemUp`/`itemDown` are wired and harmless, and answer no part of the report. The constraint
///   on this change was the minimum that makes the missing affordance visible.
/// One control in the explorer's action bar.
///
/// **The bar is a described list rather than a hand-written `HStack`, and the reason is a measured
/// one.** Two reviewers deleted the `+` Button from the old hand-written bar and the suite stayed
/// green; so did the author's first attempt at a gate, which scanned this file for the words
/// `actionBar` and `plus`: both of which a *declaration* satisfies just as well as a use, so
/// removing the bar from `body` and changing the symbol to `circle` both stayed green too.
///
/// A control that exists only as SwiftUI view code cannot be seen without a running window. A
/// control that exists as a value can. `ExplorerAffordanceTests.theActionBarOffersAddCircuit`
/// reads this array, and deleting the `+` from it reddens.
enum ExplorerActionBarItem: Hashable {
  /// A button that performs a project command, disabled when the model refuses it.
  case command(ProjectCommand, symbol: String, title: String, shortcut: String?)
  /// Flexible space.
  case spacer
  /// A `SettingsLink`: the signpost, not a second copy of anything in Settings.
  case settings(symbol: String, title: String, shortcut: String?)
}

enum ExplorerAffordance {

  /// What the action bar shows, left to right.
  ///
  /// Shown in both explorer modes rather than only in Design, and that is upstream's enablement
  /// rule rather than laziness: each `ToolboxToolbarModel` item is a
  /// `LogisimToolbarItem(MenuListener, Icon, LogisimMenuItem, StringGetter)`, so its enabled state
  /// is the *menu item's*, `ADD_CIRCUIT`, and not the explorer tab's. Adding a circuit while
  /// reading the state tree edits the same document either way.
  static let actionBarItems: [ExplorerActionBarItem] = [
    .command(.addCircuit, symbol: "plus", title: "Add Circuit", shortcut: "⇧⌘N"),
    .spacer,
    .settings(
      symbol: "gearshape",
      title: "Settings — appearance (light or dark), grid, simulation",
      shortcut: "⌘,"),
  ]

  /// The command behind the "+" button, and behind the design list's "Add Circuit…" item.
  /// Upstream's `itemAdd` → `LogisimMenuBar.ADD_CIRCUIT`.
  static let addCircuit: ProjectCommand = .addCircuit

  /// What the explorer must send *before* the analyzer can be opened on `id`, or `nil` when `id`
  /// is already the circuit the canvas is showing.
  ///
  /// This exists because of an asymmetry that cost this file a broken menu item. The analyzer is
  /// reached through `EditorModel.analyzableCircuit`, which resolves the **current** circuit only;
  /// see its header for why it is a downcast to the one real host rather than a widening of
  /// `ProjectHost`. A row's context menu, though, names a circuit that need not be current, and
  /// there is no `Circuit`-by-`CircuitID` accessor above the seam. Making the row's circuit current
  /// first is the honest way to close that with the API that exists: it cannot analyse the wrong
  /// circuit, and the switch is visible on the canvas rather than silent.
  ///
  /// **Divergence, stated:** 4.1.0's `ProjectCircuitActions.doAnalyze(project, circuit)` takes the
  /// clicked circuit as an argument, so upstream analyses it without changing what the canvas
  /// shows. (`ProjectCircuitActions` does reference `setCurrentCircuit`, but attributing that call
  /// to a method needs `javap -c` and there is no JDK here, so no claim is made about which method
  /// it belongs to; `doAddCircuit` is the obvious candidate.) The fix that removes the divergence
  /// is a per-id accessor next to `analyzableCircuit`, in `Analyze/EditorModel+Analyze.swift`,
  /// which is outside this file.
  @MainActor
  static func prepareAnalysis(of id: CircuitID, in model: EditorModel) -> ProjectCommand? {
    model.currentCircuit == id ? nil : .setCurrentCircuit(id)
  }

  /// Whether "Analyze Circuit…" may be offered for `item` at all.
  ///
  /// `analyzableCircuit != nil` is the same test `AppCommands.swift:261` uses, and it is really
  /// asking "is this host a real `LogisimFile` document with a circuit on screen"; a preview or a
  /// test double answers `nil` and the item greys out rather than doing nothing. The extra `kind`
  /// clause is upstream's own split rather than a shortcut: `Popups$VhdlPopup` holds only `edit`
  /// and `remove`, and a VHDL entity has no netlist to derive a truth table from.
  @MainActor
  static func canAnalyse(_ item: CircuitItem, in model: EditorModel) -> Bool {
    item.kind == .circuit && model.analyzableCircuit != nil
  }

  /// Same reachability as analysis, but named for the row menu that asks for the statistics
  /// table. Upstream's `ProjectCircuitActions.doAnalyze(project, circuit)` and
  /// `StatisticsDialog.show(file, circuit)` both take an explicit circuit; this port's public
  /// seam exposes only the current one, so the row command first makes its circuit current.
  @MainActor
  static func canShowStatistics(_ item: CircuitItem, in model: EditorModel) -> Bool {
    item.kind == .circuit && model.circuitStatisticsReport() != nil
  }
}

// MARK: - Rows

// MARK: - Renaming a circuit

/// The Rename prompt's decision, factored out of the view so that the part worth testing, *which
/// command, with which payload, and when none at all*, is a value type rather than a `Button`.
///
/// ## Why the shell decides anything at all
///
/// 4.1.0 has no rename command. `Popups$CircuitPopup` (jar, `javap -c`) builds exactly six items,
/// `editLayout`, `editAppearance`, `analyze`, `stats`, separator, `main`, `remove`, and
/// `ProjectCircuitActions` (jar, `javap -p`) has `doAddCircuit`/`doMoveCircuit`/`doRemoveCircuit`/
/// `doSetAsMainCircuit` and **no** `doRenameCircuit`. The only 4.1.0 path to a new circuit name is
/// the attribute table's NAME row, and `AttrTableCircuitModel.setValueRequested` (jar, `javap -c`)
/// validates *nothing*: it writes a `CircuitMutation.setForCircuit` and lets the model object
/// afterwards. Validation lives entirely in the two listeners the write wakes up, and both of them
/// work by **applying the bad name and then reverting it**:
///
/// - `CircuitAttributes$StaticListener.attributeValueChanged` (jar, `javap -c`): returns early when
///   the name is unchanged; on `newName.isEmpty()` shows `EmptyNameError` and reverts; on
///   `!SyntaxChecker.isVariableNameAcceptable(newName, true)` reverts; on a non-empty `Pin` label
///   equal to the new name shows `CircuitSameInputOutputLabel` and reverts; only then fires
///   `ACTION_CHECK_NAME` and `ACTION_SET_NAME`.
/// - `LogisimFile.circuitChanged` (jar, `javap -c`) answers `ACTION_CHECK_NAME` by calling the
///   private `isNameInUse(name, circuitBeingRenamed)`, which matches any tool in any loaded
///   library, recursively, *and* any other circuit's name case-insensitively, then shows
///   `circuitNameExists` and reverts.
///
/// So upstream's contract on a bad name is **refuse and say so**, never "accept quietly". That is
/// the contract this type reproduces, with one deliberate improvement: it refuses *before*
/// producing a command, so a rejected rename costs no undo entry. Upstream's revert leaves the
/// original mutation on the undo log; undoing a *failed* rename is a real 4.1.0 wart.
///
/// ## What is checked here and what is delegated
///
/// - **Empty** is checked here. It has to be: `LogisimFileProjectHost` does not reject it (its
///   pre-check is `circuitNameConflicts`, and `LogisimFile.circuitNameConflicts` returns `false`
///   for the empty string, exactly as upstream's `isNameInUse` does), so an empty rename reaches
///   the model, gets reverted by `CircuitStaticAttributeListener`, and leaves a no-op "Rename
///   Circuit" entry behind. Worse, the `.emptyCircuitName` diagnostic that accompanies the revert
///   goes nowhere; nothing in the app installs `Circuit.diagnosticReporter`. Silent.
/// - **Unchanged** is checked here, matching the listener's own `newName != oldName` guard. A
///   rename to the current name is not an edit and must not push undo.
/// - **In use** is delegated to the host, which pre-checks `circuitNameConflicts` and throws
///   `ProjectHostError.invalidValue`; `EditorModel.perform` turns that into `transientError` plus a
///   visible issue. That is upstream's `circuitNameExists` refusal, minus the phantom undo entry.
///   Duplicating the check here would mean re-deriving `HdlNames.namesEqualForCurrentHdl` and the
///   recursive library walk from the outline, which is a second source of truth for no gain.
struct CircuitRenameRequest: Equatable {
  var id: CircuitID
  var originalName: String
  var proposedName: String

  /// Upstream's empty test is a literal `String.isEmpty()`, but `"   "` only survives it because
  /// `SyntaxChecker`'s `^([a-zA-Z]+\w*)`, applied with `matches()`, rejects it a line later. That
  /// syntax check is a recorded gap in this port (see `CircuitStaticAttributeListener`'s note: it
  /// reads `AppPreferences.HdlType`, which D9 keeps out of the model layer), so trimming is what
  /// keeps 4.1.0's *accepted set* rather than 4.1.0's *line of code*. Both `""` and `"   "` are
  /// refused either way; the only behaviour change is that `" Foo "` renames to `Foo` instead of
  /// being accepted verbatim as a name upstream would have thrown out.
  var normalizedName: String {
    proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Why the rename cannot proceed, or `nil` when it can. Non-`nil` and `command == nil` are the
  /// same condition, deliberately: the button's disabled state and the explanation under it must
  /// never disagree.
  var rejectionReason: String? {
    // `EmptyNameError`, circuit.properties: "Each circuit needs a name, cannot allow an empty
    // one. Please specify a non-empty circuit name."
    normalizedName.isEmpty ? "A circuit needs a name." : nil
  }

  /// The command to send, or `nil` when there is nothing to do. Separate from `rejectionReason`
  /// because "same name" is a no-op rather than an error: it disables the button without
  /// accusing the user of anything.
  var command: ProjectCommand? {
    guard rejectionReason == nil, normalizedName != originalName else { return nil }
    return .renameCircuit(id, normalizedName)
  }
}

private struct CircuitRow: View {
  var circuit: CircuitItem
  var model: EditorModel

  @State private var isRenaming = false
  @State private var draftName = ""

  private var renameRequest: CircuitRenameRequest {
    CircuitRenameRequest(id: circuit.id, originalName: circuit.name, proposedName: draftName)
  }

  var body: some View {
    Label {
      HStack(spacing: 6) {
        Text(circuit.name)
        if circuit.isMain {
          Text("MAIN")
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.tint.opacity(0.18), in: .rect(cornerRadius: 3))
        }
        Spacer(minLength: 0)
        // A circuit that failed to propagate is flagged where you browse circuits.
        // Upstream reports it only in a modal, so a broken subcircuit is invisible until
        // you happen to open it.
        if circuit.errorSummary != nil {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .help(circuit.errorSummary ?? "")
        }
        Text("\(circuit.componentCount)")
          .font(.caption).monospacedDigit()
          .foregroundStyle(.tertiary)
      }
    } icon: {
      Image(systemName: circuit.kind == .vhdl ? "doc.plaintext" : "square.grid.3x3")
    }
    .contextMenu {
      // Not offered for a VHDL entity, and that is upstream's split rather than a shortcut:
      // `Popups$VhdlPopup` (jar, `javap -p`) holds only `edit` and `remove`. It is also the
      // honest thing here: `ProjectCommand.renameCircuit` resolves through
      // `LogisimFileProjectHost`'s `handles.circuits`, and a VHDL entity lives in `handles.vhdl`,
      // so the arm's `guard … else { return }` would make the menu item do nothing at all.
      if circuit.kind == .circuit {
        Button("Rename…") {
          draftName = circuit.name
          isRenaming = true
        }
      }
      Button("Set as Main Circuit") { model.perform(.setMainCircuit(circuit.id)) }
        .disabled(!model.canPerform(.setMainCircuit(circuit.id)))
      // This used to hand `.analyzeCircuit` straight to `model.perform`, and was therefore a dead
      // control: that command is INERT by design; the host drops it into `notImplemented` because
      // the host owns the *document* and the analyzer is a process-wide window
      // (`AppCommands.swift:250-256` carries the full argument). So the Circuit menu's
      // "Analyze Circuit…" opened the analyzer while this one, with the same name, answered
      // "Analyze Circuit is not implemented yet."; the exact shape of the report this change
      // came from. Both now take the one working path.
      Button("Analyze Circuit…") {
        if let prepare = ExplorerAffordance.prepareAnalysis(of: circuit.id, in: model) {
          model.perform(prepare)
        }
        guard let target = model.analyzableCircuit else { return }
        AnalyzerWindowController.shared.show(circuit: target.circuit, file: target.file)
      }
      .disabled(!ExplorerAffordance.canAnalyse(circuit, in: model))
      Button("Circuit Statistics…") {
        if let prepare = ExplorerAffordance.prepareAnalysis(of: circuit.id, in: model) {
          model.perform(prepare)
        }
        model.perform(.circuitStatistics)
      }
      .disabled(!ExplorerAffordance.canShowStatistics(circuit, in: model))
      Divider()
      Button("Move Up") { model.perform(.moveCircuitUp(circuit.id)) }
      Button("Move Down") { model.perform(.moveCircuitDown(circuit.id)) }
      Divider()
      Button("Remove", role: .destructive) { model.perform(.removeCircuit(circuit.id)) }
        .disabled(!model.canPerform(.removeCircuit(circuit.id)))
    }
    // The `OptionPane.showInputDialog` upstream uses for `promptForNewName` has no rename caller;
    // this is the same shape, wired to the one it never grew.
    .alert("Rename Circuit", isPresented: $isRenaming) {
      TextField("Name", text: $draftName)
      Button("Cancel", role: .cancel) {}
      Button("Rename") {
        if let command = renameRequest.command { model.perform(command) }
      }
      .disabled(renameRequest.command == nil)
    } message: {
      Text(renameRequest.rejectionReason ?? "Enter a new name for “\(circuit.name)”.")
    }
  }
}

private struct LibraryDisclosure: View {
  var library: LibraryItem
  var model: EditorModel
  @State private var isExpanded = false

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      ForEach(library.tools) { tool in
        ToolRow(tool: tool, model: model)
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: symbol)
          .foregroundStyle(library.isResolved ? Color.secondary : Color.orange)
        Text(library.name)
          .foregroundStyle(library.isResolved ? Color.primary : Color.secondary)
        Spacer(minLength: 0)
        if !library.isResolved {
          Image(systemName: "questionmark.circle")
            .foregroundStyle(.orange)
            .help(unresolvedHelp)
        }
      }
    }
    .onAppear {
      // Only auto-expand when the user asked for it, or when a search is narrowing the
      // list. Upstream expands everything, always.
      isExpanded =
        model.preferences.expandsLibrariesByDefault || !model.searchText.isEmpty
    }
    .onChange(of: model.searchText) { _, newValue in
      if !newValue.isEmpty { isExpanded = true }
    }
    .contextMenu {
      Button("Reload Library") { model.perform(.reloadLibrary(library.id)) }
      Button("Unload Library", role: .destructive) {
        model.perform(.unloadLibrary(library.id))
      }
      .disabled(!library.isRemovable)
    }
  }

  private var symbol: String {
    switch library.origin {
    case .builtin: return "shippingbox"
    case .loadedLogisimFile: return "doc.badge.plus"
    case .jar: return "shippingbox.badge.questionmark"  // D11
    case .unresolved: return "questionmark.square.dashed"  // D8
    }
  }

  private var unresolvedHelp: String {
    switch library.origin {
    case .jar(let desc):
      return "\(desc) — JAR libraries load Java classes at runtime and cannot be supported "
        + "natively. Its components are preserved verbatim and written back unchanged."
    case .unresolved(let name):
      return "\(name) is not available in this build. Its components are preserved verbatim "
        + "and written back unchanged."
    default:
      return ""
    }
  }
}

private struct ToolRow: View {
  var tool: ToolItem
  var model: EditorModel

  var body: some View {
    Label {
      HStack(spacing: 6) {
        Text(tool.name)
        Spacer(minLength: 0)
        if let shortcut = tool.shortcutCharacter {
          Text(String(shortcut))
            .font(.caption).monospaced()
            .foregroundStyle(.tertiary)
        }
      }
    } icon: {
      // Was `Image(systemName: tool.symbolName)`. The sidebar is "the left panel" the icon
      // complaint was about, and it and the palette now resolve through one catalog so a glyph
      // added for a gate shows up in both. See `Icons/ToolIcons.swift`.
      ToolIconView(item: tool)
    }
    .foregroundStyle(tool.isAvailable ? .primary : .tertiary)
    .help(tool.unavailableReason ?? tool.summary ?? tool.name)
    .contentShape(.rect)
    .onTapGesture { if tool.isAvailable { model.select(tool: tool.id) } }
    .background {
      if model.activeTool == tool.id {
        RoundedRectangle(cornerRadius: 5).fill(.tint.opacity(0.18))
      }
    }
    // Drag a tool straight onto the canvas. Upstream requires select-then-click, and the
    // selected tool is only indicated in the floating toolbar, not in the tree.
    .onDrag {
      let item = NSItemProvider()
      let payload = String(tool.id.rawValue)
      item.registerDataRepresentation(
        forTypeIdentifier: NSPasteboard.PasteboardType.logisimTool.rawValue,
        visibility: .ownProcess
      ) { completion in
        completion(Data(payload.utf8), nil)
        return nil
      }
      return item
    }
    .disabled(!tool.isAvailable)
  }
}

private struct SimulationRow: View {
  var node: SimulationNode
  var model: EditorModel

  var body: some View {
    Label {
      HStack(spacing: 6) {
        Text(node.name)
        Text(node.circuitName)
          .font(.caption)
          .foregroundStyle(.tertiary)
        Spacer(minLength: 0)
        if node.isCurrent {
          Image(systemName: "smallcircle.filled.circle")
            .foregroundStyle(.tint)
            .help("Current simulation state")
        }
      }
    } icon: {
      Image(systemName: node.children.isEmpty ? "circle.dashed" : "rectangle.stack")
    }
    .contentShape(.rect)
    .onTapGesture(count: 2) { model.perform(.enterState(node.id)) }
    .contextMenu {
      Button("Go In to State") { model.perform(.enterState(node.id)) }
      Button("Go Out to Parent") { model.perform(.ascendState) }
        .disabled(!model.simulation.canAscendState)
    }
  }
}

extension SimulationNode {
  /// `OutlineGroup` wants `nil` for a leaf, not an empty array; an empty array draws a
  /// disclosure triangle that expands into nothing.
  fileprivate var optionalChildren: [SimulationNode]? {
    children.isEmpty ? nil : children
  }
}
