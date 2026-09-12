// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// The chrome that floats over the canvas. Everything here is Liquid Glass, because it is
// literally suspended above content; that is the material's job.

import SwiftUI

/// The centre pane: canvas plus its floating controls.
struct CanvasPane: View {
  @Bindable var model: EditorModel

  var body: some View {
    CanvasHostView(model: model)
      .overlay(alignment: .topLeading) { breadcrumb }
      .overlay(alignment: .topTrailing) { issueStack }
      .overlay(alignment: .bottomLeading) { zoomControl }
      .overlay(alignment: .bottomTrailing) { statusCluster }
      .overlay(alignment: .top) { errorBanner }
      .accessibilityLabel("Circuit canvas")
  }

  // MARK: Breadcrumb

  /// Where you are in the simulation state tree. Upstream shows the current state only as
  /// a selected row inside the Simulate tab, so descending into `alu0 ▸ shift0` and then
  /// switching tabs leaves you with no indication of which state you are poking.
  @ViewBuilder private var breadcrumb: some View {
    if let circuit = model.currentCircuit.flatMap({ model.outline.circuit($0) }) {
      HStack(spacing: 6) {
        Image(systemName: circuit.kind == .vhdl ? "doc.plaintext" : "square.grid.3x3")
          .foregroundStyle(.secondary)
        Text(circuit.name).fontWeight(.medium)
        if let state = model.simulation.currentStateName, state != circuit.name {
          Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
          Text(state)
        }
        if model.simulation.canAscendState {
          Button {
            model.perform(.ascendState)
          } label: {
            Image(systemName: "arrow.up.left")
          }
          .buttonStyle(.borderless)
          .help("Go out to the parent circuit state")
        }
      }
      .modifier(HUDChrome())
      .padding(12)
    }
  }

  // MARK: Zoom

  /// Upstream's `ZoomControl` lives in a fixed strip under the attribute table
  /// (`Frame.java:161-163`): permanently occupying sidebar height, nowhere near the thing
  /// it zooms, and it disappears entirely if you collapse the left region.
  private var zoomControl: some View {
    HStack(spacing: 2) {
      Button { model.zoomOut() } label: { Image(systemName: "minus") }
        .disabled(model.viewport.zoom <= CanvasViewport.minimumZoom + 0.001)
        .help("Zoom Out (⌘−)")

      Menu(CanvasZoom.percentLabel(model.viewport.zoom)) {
        ForEach(CanvasZoom.steps.filter { $0 >= 0.25 && $0 <= 4 }, id: \.self) { step in
          Button(CanvasZoom.percentLabel(step)) { model.setZoom(step) }
        }
        Divider()
        Button("Actual Size") { model.zoomToActualSize() }
        Button("Zoom to Fit") { model.zoomToFit() }
        Button("Zoom to Selection") { model.zoomToSelection() }
          .disabled(model.selection.componentIDs.isEmpty)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .frame(minWidth: 54)
      .monospacedDigit()

      Button { model.zoomIn() } label: { Image(systemName: "plus") }
        .disabled(model.viewport.zoom >= CanvasViewport.maximumZoom - 0.001)
        .help("Zoom In (⌘+)")

      Divider().frame(height: 14)

      Button { model.zoomToFit() } label: {
        Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
      }
      .help("Zoom to Fit (⌘0)")

      Toggle(
        isOn: Binding(
          get: { model.preferences.showGrid },
          set: { model.preferences.showGrid = $0 })
      ) {
        Image(systemName: "grid")
      }
      .toggleStyle(.button)
      .help("Show Grid")
    }
    .buttonStyle(.borderless)
    .labelStyle(.iconOnly)
    .modifier(HUDChrome())
    .padding(12)
  }

  // MARK: Status

  /// D7, made visible. Upstream's `TickCounter` falls back to reporting the *requested*
  /// frequency when it cannot compute a real one, so the UI cannot distinguish "on target"
  /// from "no idea". Here an unknown rate is shown as unknown, and a scheduler that cannot
  /// keep up says so in colour.
  @ViewBuilder private var statusCluster: some View {
    if model.preferences.showsSimulationDiagnostics {
      HStack(spacing: 10) {
        if let point = model.pointerWorldLocation {
          Label {
            Text("\(Int(point.x.rounded())), \(Int(point.y.rounded()))")
              .monospacedDigit()
          } icon: {
            Image(systemName: "dot.scope")
          }
          .foregroundStyle(.secondary)
          Divider().frame(height: 14)
        }

        HStack(spacing: 5) {
          Circle()
            .fill(simulationTint)
            .frame(width: 7, height: 7)
          Text(simulationSummary).monospacedDigit()
        }
        .help(simulationHelp)
      }
      .modifier(HUDChrome())
      .padding(12)
    }
  }

  private var simulationTint: Color {
    if model.simulation.errorMessage != nil { return .red }
    if model.simulation.isFallingBehind { return .orange }
    if model.simulation.isTicking { return .green }
    if model.simulation.isAutoPropagating { return .secondary }
    return .gray
  }

  private var simulationSummary: String {
    let sim = model.simulation
    guard sim.isTicking else {
      return sim.isAutoPropagating ? "Idle" : "Paused"
    }
    guard let achieved = sim.achievedTickHz else { return "Measuring…" }
    var text = SimulationStatus.tickFrequencyLabel(achieved)
    if let jitter = sim.tickJitterSeconds {
      text += jitter < 0.001
        ? String(format: " ±%.0f µs", jitter * 1_000_000)
        : String(format: " ±%.1f ms", jitter * 1000)
    }
    if sim.isFallingBehind { text += " — behind" }
    return text
  }

  private var simulationHelp: String {
    let sim = model.simulation
    guard sim.isTicking else { return "The clock is stopped." }
    let requested = SimulationStatus.tickFrequencyLabel(sim.requestedTickHz)
    guard let achieved = sim.achievedTickHz else {
      return "Requested \(requested). No completed interval has been measured yet."
    }
    return "Requested \(requested); measured \(SimulationStatus.tickFrequencyLabel(achieved))."
  }

  // MARK: Errors and issues

  @ViewBuilder private var errorBanner: some View {
    if let message = model.simulation.errorMessage ?? model.transientError {
      HStack(spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        Text(message).lineLimit(2)
        Spacer(minLength: 0)
        Button("Reset Simulation") { model.perform(.reset) }
          .buttonStyle(.borderless)
        Button {
          model.transientError = nil
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
      }
      .font(.callout)
      .padding(.horizontal, 14)
      .padding(.vertical, 9)
      .frame(maxWidth: 620)
      .glassPanel(cornerRadius: 12, tint: .orange)
      .padding(.top, 12)
      .transition(.move(edge: .top).combined(with: .opacity))
    }
  }

  /// D8's promise, kept in the UI: an unresolved library is a visible, dismissible note,
  /// not a silent deletion. Upstream loses the components and says nothing.
  @ViewBuilder private var issueStack: some View {
    if !model.issues.isEmpty {
      VStack(alignment: .trailing, spacing: 8) {
        ForEach(model.issues) { issue in
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol(for: issue.severity))
              .foregroundStyle(tint(for: issue.severity))
            VStack(alignment: .leading, spacing: 2) {
              Text(issue.title).font(.callout).fontWeight(.medium)
              if let detail = issue.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
              }
              if let command = issue.recoveryCommand, let title = issue.recoveryTitle {
                Button(title) { model.perform(command) }
                  .buttonStyle(.link)
                  .font(.caption)
              }
            }
            Button {
              model.dismissIssue(issue)
            } label: {
              Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
          }
          .padding(12)
          .frame(width: 320, alignment: .leading)
          .glassPanel(cornerRadius: 14)
        }
      }
      .padding(12)
      .transition(.opacity)
    }
  }

  private func symbol(for severity: UserFacingIssue.Severity) -> String {
    switch severity {
    case .info: return "info.circle.fill"
    case .warning: return "exclamationmark.triangle.fill"
    case .failure: return "xmark.octagon.fill"
    }
  }

  private func tint(for severity: UserFacingIssue.Severity) -> Color {
    switch severity {
    case .info: return .accentColor
    case .warning: return .orange
    case .failure: return .red
    }
  }
}

/// The shared HUD treatment, so every floating cluster is identical.
private struct HUDChrome: ViewModifier {
  func body(content: Content) -> some View {
    content
      .font(.system(size: 12, weight: .medium))
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .glassPanel(cornerRadius: 999)
  }
}
