// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md at the repository root.
//
// ============================================================================
// THE MENU BAR.
//
// Inventory taken from `LogisimMenuBar`, `MenuFile`, `MenuEdit`, `MenuProject`,
// `MenuSimulate`, `MenuHelp` and `Popups` in 4.1.0: the enum in `ProjectSeam.swift`
// lists every item, so nothing can be dropped without a compile error somewhere.
//
// What is deliberately NOT reproduced:
//
//  - File ▸ Quit, File ▸ Preferences, Help ▸ About. Upstream adds these itself and then
//    conditionally removes them on macOS (`MenuFile.java:85,89`). They belong in the
//    application menu and the system puts them there. About is *replaced* rather than
//    removed: SwiftUI's default "About logisim-evolved" opens the AppKit panel, which
//    cannot carry the GPLv3 §5 notice set, so `.appInfo` is pointed at our own window.
//  - File ▸ Open Recent. `OpenRecent.java` hand-maintains a preference-backed list with
//    its own pruning. `DocumentGroup` gives the real one.
//  - Window ▸ every-open-frame. Upstream has `WindowManagers` plus a
//    `WindowMenuItemManager` per auxiliary window. The system Window menu does this.
//  - Edit ▸ Undo History / Redo History submenus (`MenuEdit.java:204-240`). On a Mac,
//    a history list is not a menu; it is on the toolbar's undo control. The named
//    Undo/Redo items below carry the action name, which is the part that mattered.
//  - Any light/dark (theme) control, and this one is written down because it was *asked for*.
//    Real use on 2026-09-08 produced "the light/dark mode toggle should be in a settings or
//    smth". Measured against the shipping build rather than inferred: the only thing anywhere
//    that writes `EditorPreferences.appearance` is the radio group in `SettingsWindow.swift`'s
//    Appearance tab, and no menu, toolbar or canvas overlay has ever carried one. So the
//    request was already satisfied and there is nothing here to move; the report is about
//    discoverability, not placement. 4.1.0 puts it in the same place: `AppPreferences
//    .LookAndFeel` is built into `WindowOptions` (the Preferences window's Window tab, where
//    changing it also calls `checkRestartWarning()`), and it is referenced by **zero** of
//    `MenuFile`, `MenuEdit`, `MenuProject`, `MenuSimulate` and `LogisimMenuBar`. That count
//    comes from `javap -c -p` over the 4.1.0 jar in `Logisim-evolution.app`, NOT from this
//    repository's `src/main/java`, which is upstream main. Adding a theme item here would be
//    the regression, not the fix; `AppearancePlacementTests` fails if one appears.
//
// Enablement comes from `ProjectHost.canPerform`, so a greyed item is greyed for a reason
// the model can state. Upstream computes enablement in `MenuListener` from a set of
// booleans pushed by `EditHandler.computeEnabled()`, separately from the code that
// actually performs the action, which is how the two drift apart.
// ============================================================================

import AppKit
import SwiftUI

struct LogisimCommands: Commands {
  @FocusedValue(\.editorModel) private var model: EditorModel?

  /// The app's one hex-editor controller, handed down from `LogisimEvolvedApp` because a
  /// `Commands` tree is not in the view hierarchy and cannot read `@Environment` state the app
  /// put there. Optional so that a preview or a test can build the menu without one.
  var hexController: HexWindowController?

  init(hexController: HexWindowController? = nil) {
    self.hexController = hexController
  }

  var body: some Commands {
    appInfoCommands
    fileCommands
    editCommands
    arrangeCommands
    viewCommands
    circuitCommands
    simulateCommands
    windowCommands
    helpCommands
  }

  // MARK: Application menu

  /// The first item of the application menu, where a Mac user looks for this.
  ///
  /// The default implementation opens `NSApplication.orderFrontStandardAboutPanel`, which
  /// reads `Info.plist` and can show a name, a version and a short credits string: not a
  /// §5(a) modified-version notice, not the two-lineage credits, and not the licence. That
  /// is a legal obligation (D10), so the item is replaced rather than left alone.
  private var appInfoCommands: some Commands {
    CommandGroup(replacing: .appInfo) {
      AboutMenuItem(title: "About \(AboutFacts.productName)")
    }
  }

  // MARK: File

  private var fileCommands: some Commands {
    CommandGroup(after: .newItem) {
      Button("Merge Project…") { model?.perform(.mergeProject) }
        .disabled(model == nil)
      Divider()
      Button("Export Image…") { model?.perform(.exportImage) }
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(model == nil)
      Button("Export Project…") { model?.perform(.exportProject) }
        .disabled(model == nil)
      Button("Extract and Run…") { model?.perform(.extractRunProject) }
        .disabled(model == nil)
      Divider()
      // `MenuFile.java:81-82` adds `exportImage` then `print`, in that order and in this group.
      Button("Print…") { model?.perform(.print) }
        .keyboardShortcut("p", modifiers: .command)
        .disabled(model == nil)
    }
  }

  // MARK: Edit

  @CommandsBuilder
  private var editCommands: some Commands {
    CommandGroup(replacing: .undoRedo) {
      Button(model?.undoStatus.undoName.map { "Undo \($0)" } ?? "Undo") {
        model?.perform(.undo)
      }
      .keyboardShortcut("z", modifiers: .command)
      .disabled(!(model?.canPerform(.undo) ?? false))

      Button(model?.undoStatus.redoName.map { "Redo \($0)" } ?? "Redo") {
        model?.perform(.redo)
      }
      .keyboardShortcut("z", modifiers: [.command, .shift])
      .disabled(!(model?.canPerform(.redo) ?? false))
    }

    // Board #93. `S.get("ramEditMenuItem")` = "Edit Contents…": the exact string from
    // `resources/logisim/strings/std/std.properties:495` in the shipping 4.1.0 jar, not from
    // this repo's `src/main/java` (which is upstream main). It sits after Paste/Select All
    // because the Edit menu is where a selection-scoped command belongs on a Mac; 4.1.0 has it
    // ONLY on the component's right-click menu (`MemMenu.configureMenu`) and on no menu bar at
    // all: `javap -c -p` over `MenuFile`, `MenuEdit`, `MenuProject`, `MenuSimulate` and
    // `LogisimMenuBar` in the 4.1.0 jar finds zero references to `HexFrame`, `getHexFrame` or
    // `MemMenu`. The popup route is the faithful one and wants adding too; `Tools/MenuTool.swift`
    // is owned by another agent, so it is reported rather than edited.
    CommandGroup(after: .pasteboard) {
      Divider()
      EditMemoryContentsItem(model: model, controller: hexController)
    }
  }

  private var arrangeCommands: some Commands {
    CommandMenu("Arrange") {
      Button("Rotate 90° Right") { model?.perform(.rotateSelection(quarterTurns: 1)) }
        .keyboardShortcut("]", modifiers: [.command, .option])
        .disabled(!(model?.canPerform(.rotateSelection(quarterTurns: 1)) ?? false))
      Button("Rotate 90° Left") { model?.perform(.rotateSelection(quarterTurns: -1)) }
        .keyboardShortcut("[", modifiers: [.command, .option])
        .disabled(!(model?.canPerform(.rotateSelection(quarterTurns: -1)) ?? false))
      Button("Flip Horizontally") { model?.perform(.mirrorSelectionHorizontally) }
      Button("Flip Vertically") { model?.perform(.mirrorSelectionVertically) }
      Divider()
      // `.disabled` on all four, and this is the half that makes `canPerform` mean anything.
      // 4.1.0's `LayoutEditHandler.computeEnabled()` sets exactly these four to a literal `false`
      // and its `raise()`/`lower()`/`raiseTop()`/`lowerBottom()` bodies disassemble to `0: return`
      // : they belong to the APPEARANCE editor (`AppearanceEditHandler` implements them for real).
      // So greyed here is faithful, not a gap. Without these modifiers the items stayed clickable
      // and reported an error, which is the "enabled and inert" shape this release is trying to
      // remove; `canPerform` returning false is inert on its own if nothing reads it.
      Button("Bring to Front") { model?.perform(.raiseToTop) }
        .keyboardShortcut("]", modifiers: [.command, .shift])
        .disabled(!(model?.canPerform(.raiseToTop) ?? false))
      Button("Bring Forward") { model?.perform(.raise) }
        .keyboardShortcut("]", modifiers: .command)
        .disabled(!(model?.canPerform(.raise) ?? false))
      Button("Send Backward") { model?.perform(.lower) }
        .keyboardShortcut("[", modifiers: .command)
        .disabled(!(model?.canPerform(.lower) ?? false))
      Button("Send to Back") { model?.perform(.lowerToBottom) }
        .keyboardShortcut("[", modifiers: [.command, .shift])
        .disabled(!(model?.canPerform(.lowerToBottom) ?? false))
      Divider()
      Button("Add Control Point") { model?.perform(.addControlPoint) }
        .disabled(!(model?.canPerform(.addControlPoint) ?? false))
      Button("Remove Control Point") { model?.perform(.removeControlPoint) }
        .disabled(!(model?.canPerform(.removeControlPoint) ?? false))
    }
  }

  // MARK: View

  private var viewCommands: some Commands {
    CommandGroup(after: .toolbar) {
      Button("Zoom In") { model?.zoomIn() }
        .keyboardShortcut("+", modifiers: .command)
      Button("Zoom Out") { model?.zoomOut() }
        .keyboardShortcut("-", modifiers: .command)
      Button("Actual Size") { model?.zoomToActualSize() }
        .keyboardShortcut("0", modifiers: [.command, .option])
      Button("Zoom to Fit") { model?.zoomToFit() }
        .keyboardShortcut("0", modifiers: .command)
      Button("Zoom to Selection") { model?.zoomToSelection() }
        .keyboardShortcut("0", modifiers: [.command, .shift])
        .disabled(model?.selection.componentIDs.isEmpty ?? true)
      Divider()
      Toggle(
        "Show Grid",
        isOn: Binding(
          get: { EditorPreferences.shared.showGrid },
          set: { EditorPreferences.shared.showGrid = $0 })
      )
      .keyboardShortcut("'", modifiers: .command)
      Toggle(
        "Colour Wires by Value",
        isOn: Binding(
          get: { EditorPreferences.shared.showsValueColours },
          set: { EditorPreferences.shared.showsValueColours = $0 }))
      // The one *appearance preference* this menu carries, and therefore the only thing in
      // this file the "theme controls belong in Settings" report could have been pointing at.
      // It duplicates `SettingsWindow.swift`'s Appearance ▸ Gates picker, it has no keyboard
      // shortcut and no `ProjectCommand` behind it, and 4.1.0 keeps `AppPreferences.GATE_SHAPE`
      // out of every menu class as well (0 hits, same `javap -c -p` measurement over the 4.1.0
      // jar as the header's). Left in place on purpose rather than removed on inference: the
      // report was about light/dark, and deleting a working menu item nobody complained about
      // is exactly how a correct observation turns into a wrong consequence. Deleting this
      // `Picker` is the whole change if the owner does want the menu to hold no preferences.
      Picker(
        "Gate Shape",
        selection: Binding(
          get: { EditorPreferences.shared.gateShape },
          set: { EditorPreferences.shared.gateShape = $0 })
      ) {
        Text("Shaped").tag(CanvasAppearance.GateShape.shaped)
        Text("Rectangular").tag(CanvasAppearance.GateShape.rectangular)
        Text("DIN 40700").tag(CanvasAppearance.GateShape.din40700)
      }
      Divider()
      Button("Show Inspector") { model?.isInspectorPresented.toggle() }
        .keyboardShortcut("i", modifiers: [.command, .option])
      Divider()
      // These three used to set `model?.centreView` inline, which worked and was still wrong:
      // `ProjectCommand.editLayout` / `.editAppearance` / `.toggleLayoutAppearance` existed for
      // the same three items and reached `LogisimFileProjectHost.perform`'s `default:` arm, so
      // any *other* producer of them, a toolbar control, the explorer, a future popup, got
      // "not implemented yet" for a feature that demonstrably worked from here. `EditorModel`
      // now owns the switch (it is shell state, not document state) and this is the only path.
      // `.disabled` on the first two and deliberately NOT on the third, which is upstream's
      // arrangement: `computeEnabled()` ties EDIT_LAYOUT to `view.equals("appearance")` and
      // EDIT_APPEARANCE to `view.equals("layout")`, and hands TOGGLE_APPEARANCE a literal `true`.
      // So "Edit Layout" is greyed while the layout editor is showing, which is the same clause
      // the Arrange menu's four ordering items rest on, and the only refusal D11 still permits.
      // Without these two modifiers `canPerform`'s new answer would be computed and read by
      // nobody, which is inert in the other direction.
      Button("Edit Layout") { model?.perform(.editLayout) }
        .keyboardShortcut("1", modifiers: [.command, .control])
        .disabled(!(model?.canPerform(.editLayout) ?? false))
      Button("Edit Appearance") { model?.perform(.editAppearance) }
        .keyboardShortcut("2", modifiers: [.command, .control])
        .disabled(!(model?.canPerform(.editAppearance) ?? false))
      Button("Toggle Layout / Appearance") { model?.perform(.toggleLayoutAppearance) }
        .keyboardShortcut("\\", modifiers: .command)
        .disabled(model == nil)
    }
  }

  // MARK: Circuit

  private var circuitCommands: some Commands {
    CommandMenu("Circuit") {
      Button("Add Circuit…") { model?.perform(.addCircuit) }
        .keyboardShortcut("n", modifiers: [.command, .shift])
      Button("Add VHDL Entity…") { model?.perform(.addVhdlEntity) }
      Button("Import VHDL…") { model?.perform(.importVhdl) }
      Divider()
      // Upstream's Project ▸ Analyze Circuit. It does not reach the *host*, for the reason this
      // comment has always given: the host owns the document, and the analyzer is a process-wide
      // window over one circuit (`AnalyzerManager` holds one static `Analyzer` for the whole app,
      // not one per project), so routing it through the host would mean the host owning a window.
      //
      // It does now go through `ProjectCommand`, which is the correction. This item reaching
      // `AnalyzerWindowController` directly left `.analyzeCircuit` itself unimplemented, and
      // `ExplorerSidebar.swift:255` sends it from the circuit's right-click menu, so the same
      // command worked from this menu and reported "not implemented yet" from the context menu.
      // `EditorModel.perform` intercepts it now, exactly as it intercepts `.print`.
      Button("Analyze Circuit…") { model?.perform(.analyzeCircuit) }
        .disabled(!(model?.canPerform(.analyzeCircuit) ?? false))
      Button("Circuit Statistics…") { model?.perform(.circuitStatistics) }
        .disabled(!(model?.canPerform(.circuitStatistics) ?? false))
      Button("Revert Custom Appearance") { model?.perform(.revertAppearance) }
        .disabled(!(model?.canPerform(.revertAppearance) ?? false))
      Divider()
      Menu("Library") {
        Button("Load Built-in Library…") { model?.perform(.loadBuiltinLibrary) }
          .disabled(!(model?.canPerform(.loadBuiltinLibrary) ?? false))
          .help("Built-in library loading needs the chooser and undoable LoadLibraries action.")
        Button("Load Logisim Library…") { model?.perform(.loadLogisimLibrary) }
          .disabled(!(model?.canPerform(.loadLogisimLibrary) ?? false))
          .help("Logisim library loading needs the file importer and undoable LoadLibraries action.")
        // D11: permanently unavailable, and *listed* so the reason is discoverable.
        // Removing the item would leave a user with a JAR-using file no explanation.
        Button("Load JAR Library…") { model?.perform(.loadJarLibrary) }
          .disabled(true)
          .help("JAR libraries load Java classes at runtime and cannot be supported natively.")
      }
      Divider()
      Button("Project Options…") { model?.perform(.projectOptions) }
    }
  }

  // MARK: Simulate

  private var simulateCommands: some Commands {
    CommandMenu("Simulate") {
      Toggle(
        "Simulation Enabled",
        isOn: Binding(
          get: { model?.simulation.isAutoPropagating ?? false },
          set: { _ in model?.perform(.toggleAutoPropagate) })
      )
      .keyboardShortcut("e", modifiers: [.command, .shift, .option])

      Button("Reset Simulation") { model?.perform(.reset) }
        .keyboardShortcut("r", modifiers: [.command, .shift])
      Button("Step Simulation") { model?.perform(.step) }
        .keyboardShortcut("i", modifiers: .command)
        .disabled(!(model?.simulation.canStep ?? false))
      Divider()
      Toggle(
        "Clock Running",
        isOn: Binding(
          get: { model?.simulation.isTicking ?? false },
          set: { _ in model?.perform(.toggleTicking) })
      )
      .keyboardShortcut("k", modifiers: .command)
      Button("Tick Once") { model?.perform(.tickFull) }
        .keyboardShortcut("t", modifiers: .command)
      Button("Tick Half") { model?.perform(.tickHalf) }
        .keyboardShortcut("t", modifiers: [.command, .shift])

      Menu("Clock Rate") {
        // D7: this list is upstream's `MenuSimulate.SUPPORTED_TICK_FREQUENCIES`. What it
        // sets is the *request*; the achieved rate is reported on the canvas and the two
        // are never conflated the way `TickCounter` conflates them.
        Picker(
          "Clock Rate",
          selection: Binding(
            get: { model?.simulation.requestedTickHz ?? 1 },
            set: { model?.perform(.setTickFrequency($0)) })
        ) {
          ForEach(SimulationStatus.supportedTickFrequencies, id: \.self) { hz in
            Text(SimulationStatus.tickFrequencyLabel(hz)).tag(hz)
          }
        }
        .pickerStyle(.inline)
      }
      Divider()
      Button("Go Out to Parent State") { model?.perform(.ascendState) }
        .keyboardShortcut(.upArrow, modifiers: [.command, .option])
        .disabled(!(model?.simulation.canAscendState ?? false))
      Divider()
      Button("VHDL Simulation Enabled") { model?.perform(.enableVhdlSimulation(true)) }
      Button("Generate VHDL Simulation Files") {
        model?.perform(.generateVhdlSimulationFiles)
      }
    }
  }

  // MARK: Window

  /// Upstream opens each of these as its own `LFrame` registered in `WindowManagers` with
  /// a bespoke `WindowMenuItemManager`. Here they are ordinary auxiliary windows; the
  /// system Window menu tracks them.
  private var windowCommands: some Commands {
    CommandGroup(before: .windowList) {
      Button("Logging…") { model?.perform(.openLogWindow) }
      Button("Chronogram…") { model?.perform(.openChronogram) }
      Button("Test Vectors…") { model?.perform(.openTestWindow) }
      Button("Assembly…") { model?.perform(.openAssemblyWindow) }
      Button("FPGA Toolchain…") { model?.perform(.openFpgaWindow) }
      Divider()
    }
  }

  // MARK: Help

  private var helpCommands: some Commands {
    CommandGroup(replacing: .help) {
      HelpMenuItems()
    }
  }
}

/// `MemMenu`'s Edit item, as a menu-bar command. Board #93.
///
/// Its own `View` rather than an inline `Button` for the reason `AboutMenuItem` is one: it needs
/// `@Environment(\.openWindow)` to raise `HexWindowScene`, and a `Commands` body is not a view so
/// it cannot read the environment itself.
///
/// **Enablement is computed from the model, not from a flag.** `canOpen` asks the host to resolve
/// the selected component all the way to a `MemContents` and greys the item when that fails, so
/// the item is enabled exactly when clicking it would do something. That is the whole reason
/// `AppCommands`' header says enablement comes from the host: upstream computes it separately in
/// `MenuListener` from booleans pushed by `EditHandler.computeEnabled()`, which is how the two
/// drift apart.
struct EditMemoryContentsItem: View {
  var model: EditorModel?
  var controller: HexWindowController?

  @Environment(\.openWindow) private var openWindow

  /// The host, if it is one that can resolve memories at all. A headless or stand-in host is
  /// simply not one, and the item greys out rather than the shell pretending.
  private var provider: (any ProjectHost & MemoryContentsProviding)? {
    model?.host as? any ProjectHost & MemoryContentsProviding
  }

  /// The whole decision, computed in `MemoryContentsSeam.swift` where a test can reach it.
  private var availability: EditMemoryContentsAvailability {
    .resolve(host: provider)
  }

  var body: some View {
    let availability = self.availability
    // `S.get("ramEditMenuItem")`, `std.properties:495` in the 4.1.0 jar.
    Button("Edit Contents…") {
      guard let provider, let target = availability.target, let controller else { return }
      // `MemMenu.doEdit()`: resolve, then `setVisible(true)`. If the resolve fails the window is
      // not raised; an empty Hex Editor appearing over a non-memory would be a lie.
      guard controller.open(component: target, in: provider) != nil else { return }
      openWindow(id: HexWindowScene.sceneID)
    }
    .disabled(!availability.isEnabled || controller == nil)
    .help(availability.help)
  }
}

/// Help items never touch a `ProjectHost`; they are documentation and licence links,
/// which are the shell's own business and must work with no document open.
private struct HelpMenuItems: View {
  @Environment(\.openWindow) private var openWindow

  private static let documentation = URL(
    string: "https://github.com/logisim-evolution/logisim-evolution/wiki")!
  private static let website = URL(
    string: "https://github.com/logisim-evolution/logisim-evolution")!

  var body: some View {
    Button("Logisim User Guide") { NSWorkspace.shared.open(Self.documentation) }
    Button("Library Reference") { NSWorkspace.shared.open(Self.documentation) }
    Button("Tutorial") { NSWorkspace.shared.open(Self.documentation) }
    Divider()
    Button("Upstream Project Website") { NSWorkspace.shared.open(Self.website) }
    Divider()
    // GPLv3 §5(d) and the "Appropriate Legal Notices" duty in D10. Reachable from the app
    // menu *and* from Help: this item is not optional decoration, it is a licence
    // obligation, and a user who goes looking for a licence looks in Help. It opens
    // *on* the Licence tab, so "how to view a copy of this License" is one click.
    AboutMenuItem(title: "Licence and Attribution", tab: .licence)
  }
}

/// Opens the About window. Shared by the application menu and the Help menu so the two
/// cannot drift apart, and deliberately independent of any `ProjectHost`; the notices
/// must be reachable with no document open.
struct AboutMenuItem: View {
  var title: String
  var tab: AboutWindow.Tab = .notices

  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button(title) {
      AboutSelection.shared.tab = tab
      openWindow(id: AboutWindow.sceneID)
    }
  }
}
