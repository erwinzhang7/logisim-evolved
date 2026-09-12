// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ============================================================================
// THE CANVAS HOST; the AppKit seam the renderer plugs into.
//
// This view draws nothing. It owns input and the camera; the renderer's view is its only
// subview and is always exactly its bounds. That split is the fix for two of the four
// named upstream issues:
//
//   #1262 (mouse zoom and panning). Upstream's canvas is a `JScrollPane` viewport over a
//   `Canvas` whose *preferred size* is the circuit bounds times the zoom
//   (`Canvas.computeSize`). Zooming therefore resizes a Swing component and then tries to
//   re-derive the scrollbar positions from ratios (`Canvas.java:700-710`), after a layout
//   pass that has already clamped them, so the anchor drifts. You also cannot scroll past
//   the content edge, and plain two-finger scroll is bound to wheel-notch scrollbar
//   increments (`Canvas.java:917-921`), so trackpad panning is steppy with no inertia and
//   no pinch zoom of any kind.
//
//   Here: the renderer's view never changes size, the camera is `(center, zoom)` and is
//   unbounded, `magnify(with:)` gives continuous pinch anchored exactly on the pinch
//   centroid, precise scroll deltas pan 1:1 in view points at any zoom, and momentum is
//   whatever the system gives us because we never re-quantise it.
//
//   #2661 (canvas text ignores the dark/light switch). `viewDidChangeEffectiveAppearance`
//   re-resolves the palette from the *live* `NSAppearance` and pushes it down the seam.
//   Nothing is cached in a static, so there is nothing to go stale. Same for
//   `viewDidChangeBackingProperties` and the backing scale.
// ============================================================================

import AppKit
import CoreGraphics
import Foundation

/// What the host needs from its owner. A protocol rather than a closure bag so the
/// direction of the dependency is obvious: the view pulls, the model never reaches in.
@MainActor
protocol CanvasHostDelegate: AnyObject {
  var surface: any CircuitRenderSurface { get }
  var interactionHandler: (any CanvasInteractionHandler)? { get }
  var viewport: CanvasViewport { get set }
  var appearanceTemplate: CanvasAppearance { get }
  var zoomAnchorsAtPointer: Bool { get }
  var scrollPans: Bool { get }
  var invertsScrollDirection: Bool { get }
  var panSensitivity: Double { get }
  var zoomSensitivity: Double { get }

  func canvasHostDidChangeViewport()
  func canvasHostDidHover(_ target: CanvasHitTarget?, atWorld point: CGPoint)
  func canvasHostContextMenu(for target: CanvasHitTarget?) -> NSMenu
  func canvasHostDidBecomeKey()
  func canvasHostZoomToFit()
}

final class CanvasHostNSView: NSView {

  weak var delegate: (any CanvasHostDelegate)?

  private var trackingArea: NSTrackingArea?
  private var dragOriginWorld: CGPoint?
  private var isSpacePanning = false
  private var panLastPoint: CGPoint?
  private var installedRenderView: NSView?
  private var keyWindowObserver: (any NSObjectProtocol)?

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layerContentsRedrawPolicy = .duringViewResize
    focusRingType = .none
    registerForDraggedTypes([.logisimTool])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not supported") }

  // MARK: - Renderer attachment

  /// Install (or swap) the renderer's view. Called once per surface; swapping is what
  /// happens when the user switches circuits and the project vends a new surface.
  func attach(renderView: NSView) {
    guard installedRenderView !== renderView else { return }
    installedRenderView?.removeFromSuperview()
    renderView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(renderView, positioned: .below, relativeTo: nil)
    NSLayoutConstraint.activate([
      renderView.leadingAnchor.constraint(equalTo: leadingAnchor),
      renderView.trailingAnchor.constraint(equalTo: trailingAnchor),
      renderView.topAnchor.constraint(equalTo: topAnchor),
      renderView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    installedRenderView = renderView
    pushAppearance()
  }

  // MARK: - Lifecycle

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let keyWindowObserver {
      NotificationCenter.default.removeObserver(keyWindowObserver)
      self.keyWindowObserver = nil
    }
    guard let window else { return }
    pushAppearance()
    syncViewSize()
    keyWindowObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.delegate?.canvasHostDidBecomeKey() }
    }
    if window.isKeyWindow { delegate?.canvasHostDidBecomeKey() }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect,
                .cursorUpdate],
      owner: self)
    addTrackingArea(area)
    trackingArea = area
    // The rect is sized to `bounds`, so a resize invalidates it. Re-apply the standing decision
    // rather than re-deciding: the pointer has not moved, so the answer has not changed.
    refreshToolTipRect(hasText: toolTipHasText)
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    syncViewSize()
  }

  /// The camera has to know how big the window is, and that is the *only* thing a resize
  /// changes. Upstream conflates this with zoom, which is the root of #1262.
  private func syncViewSize() {
    guard var viewport = delegate?.viewport else { return }
    guard viewport.viewSize != bounds.size else { return }
    let wasEmpty = viewport.viewSize == .zero
    viewport.viewSize = bounds.size
    delegate?.viewport = viewport
    delegate?.surface.setViewport(viewport)
    delegate?.canvasHostDidChangeViewport()
    if wasEmpty { delegate?.canvasHostZoomToFit() }
  }

  // MARK: - Appearance (#2661)

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    pushAppearance()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    pushAppearance()
  }

  /// Rebuild the appearance from live sources every time. There is deliberately no cache:
  /// a cached palette is exactly what makes upstream's canvas ignore a theme switch.
  func pushAppearance() {
    guard let delegate else { return }
    var appearance = delegate.appearanceTemplate
    appearance.palette = CircuitPalette.resolved(for: effectiveAppearance)
    appearance.backingScale = Double(window?.backingScaleFactor ?? 2)
    delegate.surface.setAppearance(appearance)
  }

  // MARK: - Coordinate conversion

  private func world(for event: NSEvent) -> CGPoint {
    let local = convert(event.locationInWindow, from: nil)
    return delegate?.viewport.viewToWorld(local) ?? local
  }

  // There is no `snapped(_:)` here any more, and that is deliberate rather than an oversight.
  //
  // The shell used to compute `(v / gridSpacing).rounded() * gridSpacing` and hand it onward on
  // every event and on every explorer drop. Snapping is not the shell's decision: it produces the
  // integer that gets written into `<comp loc="(x,y)"/>`, so it belongs with the tools, which do
  // it in `ToolGeometry.CanvasGrid` using upstream's exact integer arithmetic. The shell forwards
  // raw world points and nothing else.
  //
  // The rule that lived here was also wrong. Rounding the continuous world value puts the 0 -> 10
  // threshold at 5.0; 4.1.0 integerises the pointer first (`Canvas.zoomEvent` is
  // `(int) Math.round(px / zoom)`) and so thresholds at 4.5. On the pointer path that was
  // harmless because nothing read the result. On `performDragOperation` below it was NOT: the
  // snapped point WAS the drop point, so a component dropped from the explorer anywhere in the
  // half-unit band [4.5, 5.0) of a grid cell landed a whole grid step from where the same point
  // clicked would have put it. Passing the raw point through fixes that by construction.

  private func pointerEvent(_ phase: CanvasPointerEvent.Phase, _ event: NSEvent)
    -> CanvasPointerEvent
  {
    return CanvasPointerEvent(
      phase: phase,
      world: world(for: event),
      modifiers: CanvasModifiers(event.modifierFlags),
      clickCount: max(event.clickCount, 1),
      buttonNumber: event.buttonNumber,
      dragOriginWorld: dragOriginWorld)
  }

  private func forward(_ event: CanvasPointerEvent) {
    delegate?.interactionHandler?.canvasHandlePointer(event)
  }

  // MARK: - Mouse

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    if isSpacePanning || event.modifierFlags.contains(.option) {
      panLastPoint = convert(event.locationInWindow, from: nil)
      return
    }
    dragOriginWorld = world(for: event)
    forward(pointerEvent(.down, event))
  }

  override func mouseDragged(with event: NSEvent) {
    if let last = panLastPoint {
      let now = convert(event.locationInWindow, from: nil)
      pan(byViewDelta: CGSize(width: now.x - last.x, height: now.y - last.y))
      panLastPoint = now
      return
    }
    forward(pointerEvent(.dragged, event))
  }

  override func mouseUp(with event: NSEvent) {
    if panLastPoint != nil {
      panLastPoint = nil
      return
    }
    forward(pointerEvent(.up, event))
    dragOriginWorld = nil
  }

  override func mouseMoved(with event: NSEvent) {
    let w = world(for: event)
    let hit = delegate?.surface.hitTest(worldPoint: w, tolerance: hitTolerance)
    noteHover(hit, atWorld: w)
    delegate?.canvasHostDidHover(hit, atWorld: w)
    forward(pointerEvent(.moved, event))
  }

  override func mouseEntered(with event: NSEvent) { forward(pointerEvent(.entered, event)) }

  override func mouseExited(with event: NSEvent) {
    let w = world(for: event)
    noteHover(nil, atWorld: w)
    delegate?.canvasHostDidHover(nil, atWorld: w)
    forward(pointerEvent(.exited, event))
  }

  /// Middle button pans, the way every other pro Mac canvas app behaves. Upstream binds
  /// button 2 to `PokeTool` cycling and offers no pan gesture at all.
  override func otherMouseDown(with event: NSEvent) {
    panLastPoint = convert(event.locationInWindow, from: nil)
  }

  override func otherMouseDragged(with event: NSEvent) {
    guard let last = panLastPoint else { return }
    let now = convert(event.locationInWindow, from: nil)
    pan(byViewDelta: CGSize(width: now.x - last.x, height: now.y - last.y))
    panLastPoint = now
  }

  override func otherMouseUp(with event: NSEvent) { panLastPoint = nil }

  /// Hit tolerance in world units, widened as you zoom out so a 1-unit wire stays
  /// clickable at 25%. Upstream uses a fixed pixel tolerance and wires become unhittable
  /// at low zoom.
  private var hitTolerance: Double {
    let zoom = delegate?.viewport.zoom ?? 1
    return max(3, 6 / max(zoom, 0.05))
  }

  // MARK: - Tool tips (upstream `Canvas.getToolTipText`)

  /// The component the tip is currently keyed to, so a move from one chip to the next can reset
  /// AppKit's tip session. Not the same thing as `EditorModel.hoveredTarget`: that is written for
  /// every hover including wires, this only tracks what the tip machinery has been told.
  private var toolTipComponentID: ComponentID?

  /// Whether the last hover produced text; i.e. whether the rect should exist at all. Stored so
  /// a geometry change can rebuild the rect at the new size without re-deciding, and without
  /// re-running the resolver on a path where the pointer has not moved.
  private var toolTipHasText = false

  /// **`NSView.toolTip` is the wrong API here and this is why.** That property is one string for
  /// the whole view; the canvas is one view over a whole circuit, and the tip has to follow the
  /// *component* under the pointer. The AppKit call that matches Swing's
  /// `JComponent.getToolTipText(MouseEvent)`, a callback per hover, given the point, is
  /// `NSViewToolTipOwner`, installed with `addToolTip(_:owner:userData:)`. It also buys the
  /// system hover delay, the system panel and the system dismissal, none of which a hand-rolled
  /// `NSPanel` would get right and all of which a user notices when they are wrong.
  ///
  /// **The rect's presence is the "is there anything to say" decision**, rather than returning an
  /// empty string from the callback. Suppressing a tip with `""` is the usual advice, but whether
  /// AppKit renders an empty panel for it is not something this port can verify without a window,
  /// and an empty box trailing the pointer across blank canvas would be worse than no feature.
  /// With no rect there is nothing for AppKit to show, which needs no such assumption. (The
  /// callback still returns `""` for the case it cannot control: see the extension at the foot
  /// of this file.)
  private func refreshToolTipRect(hasText: Bool) {
    toolTipHasText = hasText
    removeAllToolTips()
    guard hasText, !bounds.isEmpty else { return }
    _ = addToolTip(bounds, owner: self, userData: nil)
  }

  /// A single tool-tip rect means AppKit sees no boundary when the pointer slides from one
  /// component to the next, and keeps showing the first component's text. Tearing the rect down
  /// and re-adding it ends the tip session, so the next settle re-queries, which is what makes
  /// the tip follow the component rather than the view.
  ///
  /// Keyed on the hovered component id, so it costs one resolver call per component crossed, not
  /// one per mouse-moved event.
  private func noteHover(_ target: CanvasHitTarget?, atWorld point: CGPoint) {
    guard target?.id != toolTipComponentID else { return }
    toolTipComponentID = target?.id
    guard let delegate, target != nil else {
      refreshToolTipRect(hasText: false)
      return
    }
    let text = ComponentToolTips.hoverText(
      over: delegate.surface, atWorld: point, tolerance: hitTolerance)
    refreshToolTipRect(hasText: text != nil)
  }

  override func cursorUpdate(with event: NSEvent) {
    if isSpacePanning || panLastPoint != nil {
      NSCursor.closedHand.set()
      return
    }
    let cursor = delegate?.interactionHandler?.canvasCursor(atWorldPoint: world(for: event))
    (cursor ?? .arrow).set()
  }

  // MARK: - Context menu

  override func menu(for event: NSEvent) -> NSMenu? {
    let w = world(for: event)

    // ── MenuTool first ────────────────────────────────────────────────────────────────────
    //
    // Upstream binds `Menu Tool` to Button3 and Ctrl-Button1 in the default project template and
    // resolves it in `Canvas.MyListener.mousePressed`. That menu is a *ported behaviour*, its
    // item set, its enablement predicate and its undo entries all come from `MenuTool.java`, so
    // it takes precedence over the shell's own `ProjectCommand` menu below.
    //
    // **The synthetic left-click that used to happen here is gone, and its removal is the fix
    // for a real defect.** It selected whatever was under the pointer before showing the menu,
    // reasoning that this was "the macOS convention". Measured against 4.1.0 it is not what
    // Logisim does, and the cost was concrete: with three components selected, right-clicking one
    // of them replaced the three-component selection with one, so the next Delete removed one
    // component instead of three. Upstream never touches the selection on a right-click; it
    // asks whether the point is *inside* the existing selection and switches menus accordingly,
    // which is exactly what `MenuTool.menu(for:at:)` reproduces.
    if let toolMenu = delegate?.interactionHandler?.canvasContextMenu(atWorldPoint: w) {
      return toolMenu
    }

    // Nothing under the pointer. Upstream shows no menu at all here; this port keeps its own
    // canvas-level menu (Paste, Select All, zoom) because those commands have nowhere else to
    // live on a Mac and offering them costs no fidelity: no item below mutates a component.
    let hit = delegate?.surface.hitTest(worldPoint: w, tolerance: hitTolerance)
    return delegate?.canvasHostContextMenu(for: hit)
  }

  // MARK: - Trackpad and wheel (#1262)

  override func scrollWheel(with event: NSEvent) {
    guard let delegate else { return }
    let zoomModifier =
      event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control)

    var dx = event.scrollingDeltaX
    var dy = event.scrollingDeltaY
    if !event.hasPreciseScrollingDeltas {
      // A wheel notch. Scale to something that feels like a line, not a magic constant
      // rotated to avoid resonating with the tick rate the way upstream's redraw delays
      // are (`CanvasPaintCoordinator.java:37-39`).
      dx *= 16
      dy *= 16
    }
    if delegate.invertsScrollDirection {
      dx = -dx
      dy = -dy
    }

    if zoomModifier {
      let factor = exp(dy * 0.005 * delegate.zoomSensitivity)
      zoom(byFactor: factor, at: convert(event.locationInWindow, from: nil))
      return
    }
    guard delegate.scrollPans else { return }
    pan(
      byViewDelta: CGSize(
        width: dx * delegate.panSensitivity, height: dy * delegate.panSensitivity))
  }

  /// Continuous pinch, anchored on the pinch centroid. Upstream has none.
  override func magnify(with event: NSEvent) {
    let factor = 1 + event.magnification * (delegate?.zoomSensitivity ?? 1)
    zoom(byFactor: factor, at: convert(event.locationInWindow, from: nil))
  }

  /// Two-finger double tap: toggle between fit and 100%, the standard Mac gesture.
  override func smartMagnify(with event: NSEvent) {
    guard let delegate else { return }
    if abs(delegate.viewport.zoom - 1) < 0.01 {
      delegate.canvasHostZoomToFit()
    } else {
      zoomToActualSize(at: convert(event.locationInWindow, from: nil))
    }
  }

  private func zoom(byFactor factor: Double, at viewPoint: CGPoint) {
    guard var viewport = delegate?.viewport, factor.isFinite, factor > 0 else { return }
    let anchor =
      (delegate?.zoomAnchorsAtPointer ?? true)
      ? viewport.viewToWorld(viewPoint) : viewport.center
    viewport.zoom(to: viewport.zoom * factor, anchoringWorldPoint: anchor)
    commit(viewport)
  }

  private func zoomToActualSize(at viewPoint: CGPoint) {
    guard var viewport = delegate?.viewport else { return }
    viewport.zoom(to: 1, anchoringWorldPoint: viewport.viewToWorld(viewPoint))
    commit(viewport)
  }

  private func pan(byViewDelta delta: CGSize) {
    guard var viewport = delegate?.viewport else { return }
    viewport.pan(byViewDelta: delta)
    commit(viewport)
  }

  private func commit(_ viewport: CanvasViewport) {
    delegate?.viewport = viewport
    delegate?.surface.setViewport(viewport)
    delegate?.canvasHostDidChangeViewport()
  }

  // MARK: - Keyboard
  //
  // ── IF THE KEYBOARD APPEARS DEAD, IT IS THE BUILD PRODUCT, NOT THIS CODE ─────────────────
  //
  // Measured, because it cost an hour and looks exactly like a bug in here. `keyDown(with:)` was
  // instrumented with a probe alongside `becomeFirstResponder`, and running
  // `.build/debug/logisim-evolved-app` directly gave:
  //
  //     click on the canvas   ->  PROBE becomeFirstResponder
  //     ⌫, ⌘Z, plain "a"      ->  (nothing; no keyDown of any kind)
  //
  // The view *was* the first responder and still saw no keys. The cause is one line up from
  // AppKit: `osascript -e 'name of first process whose frontmost is true'` answered **Terminal**
  // even immediately after clicking this app's own title bar. `logisim-evolved-app` is a bare
  // Mach-O executable, not an `.app` bundle (`docs/experiments/upstream-issues.md` records the
  // same fact for a different reason), and an unbundled binary gets a window, a menu bar and
  // mouse events but never becomes the frontmost *application*, so the window server routes no
  // key events to it.
  //
  // Copying the same binary into a minimal `.app` (an `Info.plist` with `CFBundleExecutable`,
  // `CFBundleIdentifier` and `NSPrincipalClass`, ad-hoc signed) and launching it with `open -a`
  // made it frontmost on the first try, and Delete then deleted the selection and ⌘Z restored it.
  // **Nothing in this file needed changing.**
  //
  // So: test keyboard behaviour through a bundled build, or through `CanvasToolController`
  // directly (`MenuToolTests`). A `swift run`-style launch will tell you every key is broken.

  override func keyDown(with event: NSEvent) {
    // Space held = temporary pan mode, released below. `keyCode 49` is space.
    if event.keyCode == 49, !event.isARepeat {
      isSpacePanning = true
      NSCursor.openHand.set()
      return
    }
    let consumed =
      delegate?.interactionHandler?.canvasHandleKey(
        CanvasKeyEvent(
          phase: .down, characters: event.charactersIgnoringModifiers ?? "",
          keyCode: event.keyCode, modifiers: CanvasModifiers(event.modifierFlags),
          isRepeat: event.isARepeat)) ?? false
    if !consumed { super.keyDown(with: event) }
  }

  override func keyUp(with event: NSEvent) {
    if event.keyCode == 49 {
      isSpacePanning = false
      NSCursor.arrow.set()
      return
    }
    _ = delegate?.interactionHandler?.canvasHandleKey(
      CanvasKeyEvent(
        phase: .up, characters: event.charactersIgnoringModifiers ?? "",
        keyCode: event.keyCode, modifiers: CanvasModifiers(event.modifierFlags),
        isRepeat: false))
  }

  // MARK: - Drag and drop from the explorer

  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    guard
      let raw = sender.draggingPasteboard.string(forType: .logisimTool),
      let value = UInt64(raw)
    else { return false }
    let point = convert(sender.draggingLocation, from: nil)
    guard let viewport = delegate?.viewport else { return false }
    // The RAW world point. `CanvasToolController.canvasDropTool` runs it through
    // `CanvasGrid.circuitPoint` and then replays a press/release, so the active tool snaps it
    // exactly as it would a click. Pre-snapping here used to double-round it through a different
    // and coarser rule; see the note above `pointerEvent`.
    delegate?.interactionHandler?.canvasDropTool(
      ToolID(rawValue: value), atWorldPoint: viewport.viewToWorld(point))
    return true
  }

  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    sender.draggingPasteboard.string(forType: .logisimTool) != nil ? .copy : []
  }
}

// MARK: - Tool tip owner

/// AppKit's answer to Swing's `JComponent.getToolTipText(MouseEvent)`, which is what
/// `com.cburch.logisim.gui.main.Canvas` overrides (gui/main/Canvas.class in the 4.1.0 jar).
///
/// The content decision, what upstream says, what this port can say, and where the two part
/// company, is entirely in `ComponentToolTips.swift`. This is only the crossing.
extension CanvasHostNSView: NSViewToolTipOwner {

  /// `point` arrives in this view's (flipped) coordinates, the same space `world(for:)` converts
  /// from, so the world point is one `viewToWorld` away.
  ///
  /// `""` is the last resort, not the mechanism. The rect only exists when the last hover
  /// produced text (`refreshToolTipRect`), so the normal "nothing to say" path never reaches
  /// here. What does reach here is the case the view cannot see: `mouseMoved` is delivered
  /// `.activeInKeyWindow` only, so in a background window the standing rect can outlive the
  /// answer that justified it. Recomputing from the point keeps the *text* right regardless, and
  /// `""` covers the remainder.
  func view(
    _ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
    userData data: UnsafeMutableRawPointer?
  ) -> String {
    guard let delegate else { return "" }
    let world = delegate.viewport.viewToWorld(point)
    return ComponentToolTips.hoverText(
      over: delegate.surface, atWorld: world, tolerance: hitTolerance) ?? ""
  }
}

extension NSPasteboard.PasteboardType {
  /// Explorer → canvas tool drags. A private type, not a public UTI: this is intra-app.
  static let logisimTool = NSPasteboard.PasteboardType("app.closiq.logisim-evolved.tool")
}
