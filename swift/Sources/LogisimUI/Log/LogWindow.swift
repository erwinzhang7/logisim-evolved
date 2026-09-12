// LogWindow.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.gui.log.{LogFrame, LogPanel, FilePanel,
// OptionsPanel, SelectionPanel, SelectionList}), https://github.com/logisim-evolution/
// logisim-evolution. Copyright by the Logisim-evolution developers. This translation is a
// derivative work and is therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Why this is not a ported Swing dialog ───────────────────────────────────────────────────
//
// Upstream's `LogFrame` is a `JTabbedPane` with four tabs, Selection, Table, Chronogram, File,
// each a `LogPanel` subclass, plus an `OptionsPanel` of 24 radio buttons and spinners laid out
// with `GridBagConstraints` by hand across 700 lines. The window's *state* is spread across
// those five classes and a `LogMenuListener` that re-enables menu items on focus change.
//
// This is one window with a sidebar and three panes:
//
//   * the **sidebar** is the signal list and the capture settings together, because in practice
//     you change a radix and a granularity in the same breath, and upstream makes that two tab
//     switches;
//   * **Timing** is the chronogram, which is the reason a student opens this window at all, so
//     it is the default pane rather than the third tab;
//   * **Table** is the same samples in text;
//   * **Export** is the file destination.
//
// The window follows the system appearance because every colour it uses is either a semantic
// SwiftUI colour or comes from `CircuitPalette`, which resolves per appearance (see the note on
// upstream issue #2661 in Palette.swift).
//
// ── Wiring, and what the integrator still has to do ─────────────────────────────────────────
//
// `LogWindowScene` below is a ready `Scene`. Adding the log to the app is two lines in
// `App/LogisimEvolvedApp.swift`, which this file set does not own:
//
//     LogWindowScene(controller: logController)     // inside `var body: some Scene`
//
// plus somewhere that constructs the controller and calls
// `controller.attach(to:state:simulated:)` when a document opens, and
// `controller.propagationCompleted(...)` from the simulator's completion callback. Until those
// exist the Log window is reachable code with no caller; stated here rather than left for the
// seam check to find.

import AppKit
import SwiftUI

/// The Log window as a `Scene`, ready to be added to the app's `body`.
public struct LogWindowScene: Scene {
  /// The scene identifier, so `openWindow(id:)` can raise it from a menu item.
  public static let sceneID = "log"

  private var controller: LogController

  public init(controller: LogController) {
    self.controller = controller
  }

  public var body: some Scene {
    Window("Signal Log", id: LogWindowScene.sceneID) {
      LogWindow(controller: controller)
    }
    .defaultSize(width: 1000, height: 620)
  }
}

/// The Log window's content.
public struct LogWindow: View {
  @Bindable var controller: LogController

  public init(controller: LogController) {
    self.controller = controller
  }

  private var model: LogModel { controller.model }

  public var body: some View {
    NavigationSplitView {
      LogSidebar(controller: controller)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
    } detail: {
      VStack(spacing: 0) {
        detailPane
        if let error = controller.lastSampleError {
          errorBanner(error)
        }
      }
      .toolbar { toolbarContent }
    }
    .navigationTitle("Signal Log")
    .navigationSubtitle(subtitle)
  }

  private var subtitle: String {
    let count = model.signalCount
    let span = LogDurationFormat.string(for: max(model.endTime - model.startTime, 0))
    return "\(count) signal\(count == 1 ? "" : "s") · \(span)"
  }

  @ViewBuilder
  private var detailPane: some View {
    switch controller.tab {
    case .chronogram: LogChronogramView(controller: controller)
    case .table: LogTableView(controller: controller)
    case .export: LogExportPane(controller: controller)
    }
  }

  private func errorBanner(_ message: String) -> some View {
    // D13 made visible: a sample that could not be recorded is a circuit error the user sees,
    // not a crash. Upstream prints it to stdout.
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
      Text(message).font(.callout).lineLimit(2)
      Spacer()
    }
    .padding(10)
    .glassPanel(cornerRadius: 10, tint: .orange)
    .padding(10)
  }

  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    ToolbarItem(placement: .principal) {
      Picker("Pane", selection: $controller.tab) {
        ForEach(LogWindowTab.allCases) { tab in
          Label(tab.rawValue, systemImage: tab.symbolName).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .labelStyle(.titleAndIcon)
    }

    ToolbarItemGroup(placement: .primaryAction) {
      if controller.tab == .chronogram {
        Slider(
          value: $controller.pointsPerTick,
          in: 4...120
        ) {
          Text("Zoom")
        } minimumValueLabel: {
          Image(systemName: "minus.magnifyingglass")
        } maximumValueLabel: {
          Image(systemName: "plus.magnifyingglass")
        }
        .frame(width: 160)

        Button {
          controller.cursorTime = nil
        } label: {
          Label("Jump to now", systemImage: "arrow.right.to.line")
        }
        .help("Pin the cursor to the newest sample")
      }

      Button {
        controller.reset()
      } label: {
        Label("Clear", systemImage: "trash")
      }
      .help("Discard the recorded history and start again")
    }
  }
}

// MARK: - Sidebar

/// The signal list and the capture settings. Upstream's `SelectionPanel` + `OptionsPanel`.
struct LogSidebar: View {
  @Bindable var controller: LogController

  private var model: LogModel { controller.model }

  var body: some View {
    List(selection: $controller.selection) {
      Section("Signals") {
        ForEach(model.rows) { row in
          LogSignalRowView(row: row, controller: controller)
            .tag(row.id)
        }
        .onMove { source, destination in
          model.move(from: Array(source), to: destination)
        }
        .onDelete { offsets in
          for offset in offsets.sorted(by: >) { model.remove(at: offset) }
        }
        if model.rows.isEmpty {
          Text("No signals selected")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }

      Section("Capture") {
        Picker("When", selection: modeBinding) {
          ForEach(LogCaptureMode.allCases, id: \.self) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
        Picker("Detail", selection: granularityBinding) {
          ForEach(LogGranularity.allCases, id: \.self) { g in
            Text(g.displayName).tag(g)
          }
        }
        LabeledContent("Tick") {
          Text("\(model.timeScale) ns").font(.callout.monospacedDigit())
        }
        LabeledContent("Gate delay") {
          Text("\(model.gateDelay) ns").font(.callout.monospacedDigit())
        }
        Stepper(
          value: historyLimitBinding, in: 0...100_000, step: 100
        ) {
          LabeledContent("History") {
            Text(model.historyLimit == 0 ? "Unlimited" : "\(model.historyLimit)")
              .font(.callout.monospacedDigit())
          }
        }
        .help("How many value changes to keep per signal. 0 keeps everything.")
      }
    }
    .listStyle(.sidebar)
    .onDeleteCommand { controller.removeSelected() }
  }

  private var modeBinding: Binding<LogCaptureMode> {
    Binding(
      get: { model.mode },
      set: { newMode in
        switch newMode {
        case .step:
          model.setStepMode(
            fine: model.isFine, timeScale: model.timeScale, gateDelay: model.gateDelay)
        case .realTime:
          model.setRealTimeMode(timeScale: model.timeScale, fine: model.isFine)
        default:
          model.setClockMode(
            fine: model.isFine, discipline: newMode, timeScale: model.timeScale,
            gateDelay: model.gateDelay)
        }
      })
  }

  private var granularityBinding: Binding<LogGranularity> {
    Binding(
      get: { model.granularity },
      set: { g in
        let fine = g == .fine
        switch model.mode {
        case .step:
          model.setStepMode(fine: fine, timeScale: model.timeScale, gateDelay: model.gateDelay)
        case .realTime:
          model.setRealTimeMode(timeScale: model.timeScale, fine: fine)
        default:
          model.setClockMode(
            fine: fine, discipline: model.mode, timeScale: model.timeScale,
            gateDelay: model.gateDelay)
        }
      })
  }

  private var historyLimitBinding: Binding<Int> {
    Binding(get: { model.historyLimit }, set: { model.setHistoryLimit($0) })
  }
}

/// One row of the sidebar's signal list.
struct LogSignalRowView: View {
  let row: LogRow
  @Bindable var controller: LogController

  var body: some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 1) {
        Text(row.info.displayName)
          .font(.system(size: 12))
          .lineLimit(1)
          .truncationMode(.middle)
        Text(controller.formattedValueAtCursor(row))
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      Picker("", selection: radixBinding) {
        ForEach(LogRadix.allCases, id: \.self) { radix in
          Text(radix.indexCharacter.uppercased()).tag(radix)
        }
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .frame(width: 56)
      .help("Radix")
    }
  }

  private var radixBinding: Binding<LogRadix> {
    Binding(
      get: { row.info.radix },
      set: { controller.model.setRadix($0, for: row.info) })
  }
}

// MARK: - Export

/// Upstream's `FilePanel`, minus its three-button "overwrite / append / cancel" dialog.
///
/// The exporter always appends, which is what upstream's `FileWriter(file, true)` does; the
/// "overwrite" option is offered here as an explicit button rather than as a modal that
/// interrupts the file choice.
struct LogExportPane: View {
  @Bindable var controller: LogController
  @State private var isChoosingFile = false

  private var model: LogModel { controller.model }

  var body: some View {
    Form {
      Section("Destination") {
        LabeledContent("File") {
          HStack {
            Text(model.fileURL?.path ?? "None chosen")
              .font(.callout)
              .foregroundStyle(model.fileURL == nil ? .secondary : .primary)
              .lineLimit(1)
              .truncationMode(.head)
            Spacer()
            Button("Choose…") { chooseFile() }
          }
        }
        Toggle("Write a header row of signal names", isOn: headerBinding)
        Toggle("Recording", isOn: enabledBinding)
          .disabled(model.fileURL == nil)
      }

      Section("Format") {
        Text(
          """
          Tab-separated. One row per interval in which nothing changed, ending in a \
          `# duration` comment. A `# mode:` line is written whenever the capture mode changes, \
          and the header row is repeated whenever the signal selection changes.
          """
        )
        .font(.callout)
        .foregroundStyle(.secondary)

        if let stalled = controller.exporter.lastNonProgressingWrite {
          Label(
            "A signal ran out of history at \(LogDurationFormat.string(for: stalled)); writing paused there.",
            systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.orange)
        }
        if let error = controller.exporter.lastError {
          Label(String(describing: error), systemImage: "xmark.octagon")
            .font(.callout)
            .foregroundStyle(.red)
        }
      }

      Section("Preview") {
        ScrollView {
          Text(previewText)
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220)
      }
    }
    .formStyle(.grouped)
  }

  private var headerBinding: Binding<Bool> {
    Binding(get: { model.writesFileHeader }, set: { model.setFileHeader($0) })
  }

  private var enabledBinding: Binding<Bool> {
    Binding(get: { model.isFileEnabled }, set: { model.setFileEnabled($0) })
  }

  /// A rendering of the current history in the export format, without touching the file. Built
  /// with a throwaway exporter so the live one's cursors are not disturbed.
  private var previewText: String {
    let preview = LogFileExporter()
    let text = preview.nextChunk(for: model)
    return text.isEmpty ? "(nothing recorded yet)" : text
  }

  private func chooseFile() {
    let panel = NSSavePanel()
    panel.title = "Choose a log file"
    panel.nameFieldStringValue = "signal-log.txt"
    panel.allowedContentTypes = [.plainText]
    panel.isExtensionHidden = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    controller.exporter.rewind()
    model.setFileURL(url)
  }
}
