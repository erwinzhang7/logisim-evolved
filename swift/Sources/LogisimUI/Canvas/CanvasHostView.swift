// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import AppKit
import CoreGraphics
import SwiftUI

/// The `NSViewRepresentable` seam. This is the entire SwiftUI surface area of the canvas:
/// everything else about it is AppKit in `CanvasHostNSView` and drawing in whatever
/// `LogisimRender` supplies.
///
/// Note what is *not* here. There is no `NSScrollView`. The renderer's view is never
/// resized, there are no scrollbars to keep in sync with a zoom factor, and there is no
/// "preferred size" anywhere in the stack. That is the structural half of the #1262 fix;
/// the gesture half is in the host view.
struct CanvasHostView: NSViewRepresentable {
  var model: EditorModel

  func makeNSView(context: Context) -> CanvasHostNSView {
    let view = CanvasHostNSView()
    view.delegate = context.coordinator
    view.attach(renderView: model.surface.renderView)
    return view
  }

  func updateNSView(_ view: CanvasHostNSView, context: Context) {
    context.coordinator.model = model
    view.delegate = context.coordinator
    view.attach(renderView: model.surface.renderView)
    // Push the camera only when SwiftUI moved it (menu zoom, reveal-from-explorer).
    // Comparing first is what keeps the AppKit gesture loop and the SwiftUI update loop
    // from feeding each other.
    if context.coordinator.lastPushedViewport != model.viewport {
      context.coordinator.lastPushedViewport = model.viewport
      model.surface.setViewport(model.viewport)
    }
    view.pushAppearance()
  }

  func makeCoordinator() -> Coordinator { Coordinator(model: model) }

  @MainActor
  final class Coordinator: NSObject, CanvasHostDelegate {
    var model: EditorModel
    var lastPushedViewport: CanvasViewport?

    init(model: EditorModel) {
      self.model = model
      super.init()
    }

    var surface: any CircuitRenderSurface { model.surface }
    var interactionHandler: (any CanvasInteractionHandler)? { model.host.interactionHandler }
    var appearanceTemplate: CanvasAppearance { model.preferences.canvasAppearanceTemplate }
    var zoomAnchorsAtPointer: Bool { model.preferences.zoomBehaviour == .anchorAtPointer }
    var scrollPans: Bool { model.preferences.scrollPans }
    var invertsScrollDirection: Bool { model.preferences.invertScrollDirection }
    var panSensitivity: Double { model.preferences.panSensitivity }
    var zoomSensitivity: Double { model.preferences.zoomSensitivity }

    var viewport: CanvasViewport {
      get { model.viewport }
      set {
        model.viewport = newValue
        lastPushedViewport = newValue
      }
    }

    func canvasHostDidChangeViewport() {}

    func canvasHostDidHover(_ target: CanvasHitTarget?, atWorld point: CGPoint) {
      model.hoveredTarget = target
      model.pointerWorldLocation = point
    }

    func canvasHostDidBecomeKey() {}

    func canvasHostZoomToFit() {
      model.zoomToFit()
      lastPushedViewport = model.viewport
    }

    /// Native contextual menus, built from the same `ProjectCommand` vocabulary the main
    /// menu bar uses and gated by the same `canPerform`. Upstream builds three different
    /// popup menus in three places (`Popups.java`, `ToolboxManip`, `SimulationExplorer`)
    /// with independently-hardcoded enablement, which is why they disagree.
    func canvasHostContextMenu(for target: CanvasHitTarget?) -> NSMenu {
      let menu = NSMenu()
      menu.autoenablesItems = false

      if let target {
        let header = NSMenuItem(title: target.displayName, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if target.kind == .unresolvedPlaceholder {
          let note = NSMenuItem(
            title: "Library unresolved — preserved on save", action: nil, keyEquivalent: "")
          note.isEnabled = false
          menu.addItem(note)
        }
        menu.addItem(.separator())
      }

      func add(_ title: String, _ command: ProjectCommand, key: String = "") {
        let item = NSMenuItem(
          title: title, action: #selector(runCommand(_:)), keyEquivalent: key)
        item.target = self
        item.representedObject = CommandBox(command)
        item.isEnabled = model.canPerform(command)
        menu.addItem(item)
      }

      if target != nil {
        add("Cut", .cut)
        add("Copy", .copy)
        add("Duplicate", .duplicate)
        add("Delete", .delete)
        menu.addItem(.separator())
        add("Rotate 90° Right", .rotateSelection(quarterTurns: 1))
        add("Rotate 90° Left", .rotateSelection(quarterTurns: -1))
        add("Flip Horizontally", .mirrorSelectionHorizontally)
        add("Flip Vertically", .mirrorSelectionVertically)
        menu.addItem(.separator())
        add("Bring to Front", .raiseToTop)
        add("Send to Back", .lowerToBottom)
        menu.addItem(.separator())
      }
      add("Paste", .paste)
      add("Select All", .selectAll)
      menu.addItem(.separator())

      let fit = NSMenuItem(title: "Zoom to Fit", action: #selector(zoomToFit), keyEquivalent: "")
      fit.target = self
      menu.addItem(fit)
      let actual = NSMenuItem(
        title: "Actual Size", action: #selector(zoomActual), keyEquivalent: "")
      actual.target = self
      menu.addItem(actual)
      return menu
    }

    @objc private func runCommand(_ sender: NSMenuItem) {
      guard let box = sender.representedObject as? CommandBox else { return }
      model.perform(box.command)
    }

    @objc private func zoomToFit() { canvasHostZoomToFit() }
    @objc private func zoomActual() { model.zoomToActualSize() }
  }
}

/// `representedObject` is `Any?` and AppKit needs a reference; a box keeps the enum
/// itself value-typed everywhere else.
private final class CommandBox {
  let command: ProjectCommand
  init(_ command: ProjectCommand) { self.command = command }
}
