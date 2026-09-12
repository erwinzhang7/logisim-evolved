// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ============================================================================
// THE TOOLBAR.
//
// Upstream has a `com.cburch.draw.toolbar.Toolbar`, a hand-rolled Swing component with
// its own `ToolbarModel`, its own painting, its own hover tracking and its own orientation
// preference, floating inside the window's content pane above the canvas
// (`Frame.java:146`). It is not a window toolbar: it does not participate in the title
// bar, it cannot be customised, it does not collapse, and on macOS it looks like exactly
// what it is, a Java widget drawn on a panel.
//
// This is a real `NSToolbar` via SwiftUI's `.toolbar`, so it gets Liquid Glass, unified
// title-bar layout, keyboard traversal and the system's own overflow behaviour for free.
// The grouping is deliberate: what you are drawing with, then what the simulator is
// doing, then the inspector. Zoom is NOT here; it belongs on the canvas, next to the
// thing it zooms.
// ============================================================================

import SwiftUI

struct EditorToolbar: ToolbarContent {
  @Bindable var model: EditorModel

  var body: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      centreViewPicker
    }

    ToolbarItem(placement: .principal) {
      toolPalette
    }

    ToolbarItemGroup(placement: .primaryAction) {
      Button {
        model.perform(.toggleAutoPropagate)
      } label: {
        Label(
          model.simulation.isAutoPropagating ? "Pause Simulation" : "Resume Simulation",
          systemImage: model.simulation.isAutoPropagating ? "pause.fill" : "play.fill")
      }
      .help(model.simulation.isAutoPropagating ? "Pause propagation" : "Resume propagation")

      Button {
        model.perform(.step)
      } label: {
        Label("Step", systemImage: "forward.frame")
      }
      .disabled(!model.simulation.canStep)
      .help("Advance the simulation one propagation step (⌘I)")

      Button {
        model.perform(.toggleTicking)
      } label: {
        Label(
          model.simulation.isTicking ? "Stop Clock" : "Start Clock",
          systemImage: model.simulation.isTicking ? "stop.circle" : "metronome")
      }
      .help("Start or stop the clock (⌘K)")

      clockMenu
    }

    ToolbarItem(placement: .primaryAction) {
      Button {
        model.isInspectorPresented.toggle()
      } label: {
        Label("Inspector", systemImage: "sidebar.trailing")
      }
      .help("Show or hide the inspector (⌥⌘I)")
    }
  }

  // MARK: Layout / Appearance / HDL

  /// `Frame` switches these with a `CardPanel` keyed by string constants and no visible
  /// control at all: you change view from the Project menu and hope.
  private var centreViewPicker: some View {
    Picker("View", selection: $model.centreView) {
      ForEach(CentreView.allCases) { view in
        Label(view.displayName, systemImage: view.symbolName).tag(view)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .help("Switch between the layout, the custom appearance, and the HDL source")
  }

  // MARK: Tools

  /// `#Base`'s five tools, Poke, Select, Wire, Text, Menu, one `Button` each.
  ///
  /// ── WHY THIS IS NOT A `Picker` ANY MORE ───────────────────────────────────────────────────
  ///
  /// It was:
  ///
  /// ```swift
  /// Picker("Tool", selection: activeToolBinding) {
  ///   ForEach(model.outline.editingTools) { tool in
  ///     Label(tool.name, systemImage: tool.symbolName)
  ///       .tag(Optional(tool.id))
  ///       .help(tool.summary ?? tool.name)     // ← never reached the screen
  ///   }
  /// }
  /// .pickerStyle(.segmented)
  /// .labelsHidden()
  /// ```
  ///
  /// and that `.help` is dead. A segmented `Picker` on macOS is an `NSSegmentedControl`: SwiftUI
  /// reads each row's `Text`/`Image` and its `tag`, builds segments from those, and discards the
  /// rest of the row's modifiers. `NSSegmentedControl` does have per-segment tool tips
  /// (`setToolTip(_:forSegment:)`), but SwiftUI exposes no way to reach them, so the modifier had
  /// nowhere to land. `.labelsHidden()` then removed the only other thing naming the buttons.
  ///
  /// The result was five unlabelled glyphs in the title bar, a hand, an arrow, a diagonal line,
  /// `Aa` and `⋯`, with nothing to say what any of them did. That is the report this change
  /// answers, in the owner's words: *"hover i meant the top tool bar."* Note which row that is:
  /// the palette strip below the title bar is reordered by `PaletteLayout.presentationOrder` so it
  /// opens with the pointer, and the reported row opened with the hand, which is this one, the
  /// only unreordered copy of `#Base`.
  ///
  /// ── REVERTED TO THE SEGMENTED PICKER, deliberately ───────────────────────────────────────
  ///
  /// This was briefly rewritten as an `HStack` of `Button`s so each could carry `.help`, since a
  /// SwiftUI segmented `Picker` will not show a per-segment tooltip. The rewrite worked and **broke
  /// the layout**: hardcoded `.frame(width: 26, height: 22)` cells no longer fitted the toolbar's
  /// own capsule, which is what the owner saw and reported the same day it shipped.
  ///
  /// The trade was not the agent's to make. It was asked to add tooltips and it changed a control's
  /// appearance to get them; the tooltip was explicitly "a nice to have", the toolbar looking
  /// right was not. So the control is back and the richer strings stay: `.help` is applied to the
  /// segment labels, where AppKit may or may not surface it, and `ToolButtonToolTips` remains the
  /// single source of the text (still asserted by `ToolbarToolTipTests`, still used by the palette
  /// strip and the canvas, where tooltips DO render).
  ///
  /// If top-bar tooltips are wanted for real, the answer is a custom control sized to the toolbar
  /// rather than fixed cells: a deliberate piece of design work, not a side effect of a tooltip
  /// task.
  private var toolPalette: some View {
    Picker("Tool", selection: activeToolBinding) {
      ForEach(model.outline.editingTools) { tool in
        Label(tool.name, systemImage: tool.symbolName)
          .tag(Optional(tool.id))
          .help(ToolButtonToolTips.text(for: tool))
          .accessibilityLabel(tool.name)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
  }

  private var activeToolBinding: Binding<ToolID?> {
    Binding(
      get: { model.activeTool },
      set: { if let id = $0 { model.select(tool: id) } })
  }


  // MARK: Simulation

  private var clockMenu: some View {
    Menu {
      // D7: the menu sets the *requested* rate. What is actually achieved is reported
      // separately, on the canvas, and never conflated with this number.
      Picker("Tick Frequency", selection: tickFrequencyBinding) {
        ForEach(SimulationStatus.supportedTickFrequencies, id: \.self) { hz in
          Text(SimulationStatus.tickFrequencyLabel(hz)).tag(hz)
        }
      }
      .pickerStyle(.inline)
      Divider()
      Button("Tick Once") { model.perform(.tickFull) }
      Button("Tick Half") { model.perform(.tickHalf) }
      Divider()
      Button("Reset Simulation") { model.perform(.reset) }
    } label: {
      Label(
        SimulationStatus.tickFrequencyLabel(model.simulation.requestedTickHz),
        systemImage: "timer")
    }
    .help("Clock rate and manual ticks")
  }

  private var tickFrequencyBinding: Binding<Double> {
    Binding(
      get: { model.simulation.requestedTickHz },
      set: { model.perform(.setTickFrequency($0)) })
  }
}
