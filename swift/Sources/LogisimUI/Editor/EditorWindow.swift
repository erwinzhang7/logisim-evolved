// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ============================================================================
// THE WINDOW.
//
// Three panes: explorer, canvas, inspector.
//
// One structural decision worth stating, because it is a deliberate departure from the
// literal brief: the third pane is `.inspector`, not a third `NavigationSplitView`
// column. `NavigationSplitView`'s three-column form is a *drill-down* structure,
// sidebar chooses a list, list chooses a detail, and a circuit editor is not that. The
// inspector is a property panel over whatever is selected, which is exactly what
// `.inspector` models: it gets the system's trailing-edge presentation, its own resize
// behaviour and its own Liquid Glass treatment, and it collapses without disturbing the
// canvas. Xcode, Keynote, Numbers and Freeform all do it this way; so does every Mac app
// that has a property panel rather than a third level of navigation.
// ============================================================================

import SwiftUI

public struct EditorWindow: View {
  @Bindable var model: EditorModel

  public init(model: EditorModel) {
    self.model = model
  }

  public var body: some View {
    NavigationSplitView(columnVisibility: $model.columnVisibility) {
      ExplorerSidebar(model: model)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
    } detail: {
      centre
        .navigationTitle(model.displayName)
        .navigationSubtitle(model.windowSubtitle)
        .toolbar { EditorToolbar(model: model) }
        .inspector(isPresented: $model.isInspectorPresented) {
          InspectorPane(model: model)
            .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
    }
    .navigationSplitViewStyle(.balanced)
    // Dark/light is automatic (semantic colours everywhere, and the canvas re-resolves
    // its palette in `viewDidChangeEffectiveAppearance`). The preference exists only to
    // *override* the system, which is a different feature.
    .preferredColorScheme(model.preferences.appearance.colorScheme)
    .focusedSceneValue(\.editorModel, model)
    .onChange(of: model.preferences.gateShape) { _, _ in
      model.surface.invalidate(worldRect: nil)
    }
  }

  @ViewBuilder private var centre: some View {
    switch model.centreView {
    case .layout:
      VStack(spacing: 0) {
        // The document's `<toolbar>`. Only on the layout view: the appearance and HDL views place
        // nothing, so a palette there would be a row of buttons that do nothing.
        ComponentPalette(model: model)
        CanvasPane(model: model)
      }
    case .appearance:
      // The custom-appearance editor. `AppearancePane` renders the circuit's `<appear>` through
      // `LogisimStd.AppearanceShapePainter` into a `RenderScene` (D6) and routes every edit
      // through `Project.doAction`. See `Appearance/AppearancePane.swift` for what upstream's
      // twelve-item toolbar contains and which one arm of it is implemented.
      CircuitAppearancePane(model: model)
    case .hdl:
      placeholder(
        title: "HDL Source",
        detail: "VHDL entity editing is not part of the shell milestone.",
        symbol: "doc.plaintext")
    }
  }

  private func placeholder(title: String, detail: String, symbol: String) -> some View {
    ContentUnavailableView {
      Label(title, systemImage: symbol)
    } description: {
      Text(detail)
    } actions: {
      Button("Back to Layout") { model.centreView = .layout }
    }
  }
}

// MARK: - Focus plumbing

/// How the menu bar reaches the front window's editor.
///
/// The alternative, upstream's, is `Projects.getCurrentProject()`, a static registry
/// scanned by window-activation listeners, read by every menu action. That is why menu
/// enablement upstream drifts out of sync with what is actually focused: the registry and
/// the real focus are two sources of truth. `focusedSceneValue` has one.
struct EditorModelFocusKey: FocusedValueKey {
  typealias Value = EditorModel
}

extension FocusedValues {
  var editorModel: EditorModel? {
    get { self[EditorModelFocusKey.self] }
    set { self[EditorModelFocusKey.self] = newValue }
  }
}
