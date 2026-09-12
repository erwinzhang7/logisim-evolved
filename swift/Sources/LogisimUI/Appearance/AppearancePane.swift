// AppearancePane.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.gui.appear.{AppearanceView,
// AppearanceToolbarModel}), https://github.com/logisim-evolution/logisim-evolution. Copyright by
// the Logisim-evolution developers. This translation is a derivative work and is therefore
// GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// WHAT UPSTREAM'S PANE IS, MEASURED FROM THE 4.1.0 SOURCE
//
// `AppearanceToolbarModel`'s constructor is the complete tool list, in order:
//
//     SelectTool, TextTool, LineTool, CurveTool, PolyTool(closed:false),
//     RectangleTool, RoundRectangleTool, OvalTool, PolyTool(closed:true),
//     ResetAppearanceTool(toDefault), ResetAppearanceTool(toDefaultShape), ShowStateTool
//
// plus a `DrawingAttributeSet` shared by all of them (stroke width, fill/stroke paint type,
// colours, font, alignment), a `BasicZoomModel` over {100,150,200,300,400,600,800}%, and an
// `AttrTableDrawManager` that puts the selected shape's attributes in the same attribute table
// the layout view uses.
//
// **This pane ships the SelectTool arm only, and says so on screen.** The eight drawing tools
// are `com.cburch.draw.tools.*`, which is a further ~1,100 lines this port has not translated
// (`LogisimDraw` has the shape *model* and the SVG codec; it has no `tools/` directory). Naming
// the gap in the UI is the difference between an unfinished feature and a lie.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// WHY THIS PANE IS ALLOWED TO EXIST BEFORE THE DRAWING TOOLS
//
// Because the destructive risk is on the *read* side, not the write side. Before today a
// subcircuit's custom appearance could be parsed and re-emitted and never seen; a user editing a
// file with a hand-drawn symbol had no way to look at it. Rendering it, and moving one shape
// with full undo, is strictly more than nothing and, crucially, is provably byte-safe:
// `AppearanceRoundTripTests` opens every corpus file with an `<appear>`, builds this model, and
// asserts the saved bytes are identical to a save that never built one.

import AppKit
import LogisimDraw
import SwiftUI

// MARK: - The NSViewRepresentable bridge

@MainActor
private struct AppearanceCanvasHost: NSViewRepresentable {
  let controller: AppearanceEditorController

  func makeNSView(context: Context) -> AppearanceCanvasNSView {
    let view = AppearanceCanvasNSView(frame: .zero)
    view.delegate = controller
    controller.attach(view)
    return view
  }

  func updateNSView(_ view: AppearanceCanvasNSView, context: Context) {
    controller.attach(view)
  }
}

// MARK: - The controller

/// Owns the model, the build and the selection, and is the only thing that submits an `Action`.
///
/// A separate object from the SwiftUI view because the view is a struct recreated on every
/// update pass, and the `Drawing` behind it must not be: rebuilding the model per update would
/// drop the selection on every keystroke elsewhere in the window and, worse, would re-seed from
/// `CircuitAppearanceStore` mid-drag.
@MainActor
@Observable
final class AppearanceEditorController: AppearanceCanvasDelegate {

  private(set) var model: AppearanceEditorModel
  private(set) var build = AppearanceSceneBuild()
  private(set) var unmodelledShapeCount = 0
  private(set) var selectedIndices: Set<Int> = []
  private(set) var lastError: String?

  private weak var view: AppearanceCanvasNSView?
  private weak var host: (any AppearanceHosting)?
  private var appearance = CanvasAppearance()

  init(host: (any AppearanceHosting)?) {
    self.host = host
    self.model = AppearanceEditorModel(circuit: host?.appearanceCircuit)
    rebuild()
  }

  /// The circuit the pane is showing changed, or the pane came back on screen.
  func refresh(host: (any AppearanceHosting)?) {
    self.host = host
    let circuit = host?.appearanceCircuit
    if circuit !== model.circuit {
      model = AppearanceEditorModel(circuit: circuit)
      selectedIndices = []
    } else {
      model.reload()
    }
    rebuild()
  }

  var hasCustomAppearance: Bool { model.hasCustomAppearance }

  var summary: String {
    let drawn = build.paintedShapeCount
    let ports = build.portLocations.count
    var parts = ["\(drawn) shape\(drawn == 1 ? "" : "s")", "\(ports) port\(ports == 1 ? "" : "s")"]
    if build.anchorLocation != nil { parts.append("anchor") }
    if unmodelledShapeCount > 0 {
      // D8, surfaced. These are `visible-*` and unrecognised tags: preserved byte-for-byte on
      // save and not drawable from this module. Saying so is the point; a symbol that is
      // missing parts must not look like a symbol that is complete.
      parts.append("\(unmodelledShapeCount) preserved, not drawn")
    }
    return parts.joined(separator: " · ")
  }

  func attach(_ view: AppearanceCanvasNSView) {
    self.view = view
    view.delegate = self
    view.build = build
    view.selectedIndices = selectedIndices
    view.appearance_ = appearance
    view.viewport = fittedViewport(in: view.bounds)
  }

  func setAppearance(_ appearance: CanvasAppearance) {
    self.appearance = appearance
    view?.appearance_ = appearance
  }

  private func rebuild() {
    let result = AppearanceSceneSource.build(
      shapes: model.drawing.objectsFromBottom, appearance: appearance)
    // `objectsFromBottom` holds only the modelled objects; the D8 entries never enter the
    // scene, and the count of them comes from the model, which is the only place that knows.
    build = result.build
    unmodelledShapeCount = model.sourceShapeCount - model.drawing.objectsFromBottom.count
    view?.build = build
    view?.selectedIndices = selectedIndices
  }

  /// Fits the whole symbol, once, when the view first gets a size. Upstream's
  /// `AppearanceCanvas.computeSize` does the same thing with a scroll view's preferred size.
  private func fittedViewport(in rect: CGRect) -> CanvasViewport {
    var vp = CanvasViewport()
    vp.viewSize = rect.size
    guard !build.contentBounds.isNull, rect.width > 1, rect.height > 1 else { return vp }
    vp.reveal(build.contentBounds.insetBy(dx: -30, dy: -30))
    return vp
  }

  // MARK: AppearanceCanvasDelegate

  func appearanceCanvasDidClick(_ shape: CanvasObject?, extending: Bool) {
    guard let shape, let index = build.shapes.firstIndex(where: { $0 === shape }) else {
      if !extending { selectedIndices = [] }
      model.setSelection(selectedIndices.compactMap { build.shapes[safe: $0] })
      view?.selectedIndices = selectedIndices
      return
    }
    if extending {
      if selectedIndices.contains(index) {
        selectedIndices.remove(index)
      } else {
        selectedIndices.insert(index)
      }
    } else if !selectedIndices.contains(index) {
      selectedIndices = [index]
    }
    model.setSelection(selectedIndices.compactMap { build.shapes[safe: $0] })
    view?.selectedIndices = selectedIndices
  }

  func appearanceCanvasIsDragging(dx: Int, dy: Int) {
    // Preview only. The model does not move until the mouse comes up, because an in-progress
    // gesture must not become an undo entry; see `AppearanceTranslateAction`'s coalescing note
    // for what happens when it does.
  }

  func appearanceCanvasDidDrag(dx: Int, dy: Int) {
    let shapes = selectedIndices.compactMap { build.shapes[safe: $0] }
    guard !shapes.isEmpty, let project = host?.appearanceProject else { return }
    do {
      // THE POINT OF THE WHOLE FILE: every edit goes through `Project.doAction`, so it lands on
      // the undo stack and is serialised against the propagation thread by `Project.modelGuard`.
      try project.doAction(
        AppearanceTranslateAction(model: model, shapes: shapes, dx: dx, dy: dy))
      lastError = nil
    } catch {
      // D13 carried into the UI: a rejected edit is a message, never a trap.
      lastError = error.localizedDescription
    }
    rebuild()
  }
}

// MARK: - The pane

struct CircuitAppearancePane: View {
  @Bindable var model: EditorModel
  @State private var controller: AppearanceEditorController?

  var body: some View {
    Group {
      if let controller, controller.hasCustomAppearance {
        VStack(spacing: 0) {
          AppearanceToolStrip()
          AppearanceCanvasHost(controller: controller)
          AppearanceStatusBar(controller: controller)
        }
      } else {
        ContentUnavailableView {
          Label("No Custom Appearance", systemImage: "paintbrush")
        } description: {
          Text(
            "This circuit uses one of the built-in symbol styles. The appearance editor shows "
              + "and edits a custom \u{201C}appear\u{201D} drawing; there is none to show.")
        } actions: {
          Button("Back to Layout") { model.centreView = .layout }
        }
      }
    }
    .onAppear { ensureController() }
    .onChange(of: model.currentCircuit) { _, _ in controller?.refresh(host: hosting) }
    .onChange(of: model.preferences.appearance.colorScheme) { _, _ in ensureController() }
  }

  private var hosting: (any AppearanceHosting)? { model.host as? any AppearanceHosting }

  private func ensureController() {
    if controller == nil {
      controller = AppearanceEditorController(host: hosting)
    } else {
      controller?.refresh(host: hosting)
    }
  }
}

/// Upstream's twelve toolbar items, with the eleven that are not implemented shown disabled
/// rather than omitted.
///
/// Omitting them would misrepresent the feature as complete; a disabled row with a tooltip is
/// how a user finds out that "Rectangle" exists upstream and does not exist here yet.
private struct AppearanceToolStrip: View {
  private struct Item: Identifiable {
    let id: String
    let symbol: String
    let enabled: Bool
  }

  private static let items: [Item] = [
    Item(id: "Select", symbol: "cursorarrow", enabled: true),
    Item(id: "Text", symbol: "textformat", enabled: false),
    Item(id: "Line", symbol: "line.diagonal", enabled: false),
    Item(id: "Curve", symbol: "point.topleft.down.to.point.bottomright.curvepath", enabled: false),
    Item(id: "Polyline", symbol: "scribble", enabled: false),
    Item(id: "Rectangle", symbol: "rectangle", enabled: false),
    Item(id: "Rounded Rectangle", symbol: "rectangle.roundedtop", enabled: false),
    Item(id: "Oval", symbol: "oval", enabled: false),
    Item(id: "Polygon", symbol: "pentagon", enabled: false),
  ]

  var body: some View {
    HStack(spacing: 4) {
      ForEach(Self.items) { item in
        Image(systemName: item.symbol)
          .frame(width: 26, height: 22)
          .background(
            item.enabled ? Color.accentColor.opacity(0.18) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5))
          .foregroundStyle(item.enabled ? Color.primary : Color.secondary.opacity(0.5))
          .help(item.enabled ? "\(item.id) (active)" : "\(item.id) — not yet ported")
      }
      Spacer()
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(.bar)
  }
}

private struct AppearanceStatusBar: View {
  let controller: AppearanceEditorController

  var body: some View {
    HStack(spacing: 8) {
      Text(controller.summary)
        .font(.caption)
        .foregroundStyle(.secondary)
      if let error = controller.lastError {
        Text(error).font(.caption).foregroundStyle(.red)
      }
      Spacer()
      Text("Drag to move · \u{2325} disables grid snap")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(.bar)
  }
}

// MARK: - Small helpers

extension Array {
  subscript(safe index: Int) -> Element? {
    (index >= 0 && index < count) ? self[index] : nil
  }
}
