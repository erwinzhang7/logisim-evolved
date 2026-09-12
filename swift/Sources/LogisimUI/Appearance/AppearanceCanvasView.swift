// AppearanceCanvasView.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.gui.appear.AppearanceCanvas,
// com.cburch.draw.canvas.{Canvas, CanvasListener}, com.cburch.draw.tools.SelectTool),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE SECOND CANVAS, AND WHAT IT DOES NOT DUPLICATE
//
// The brief's instruction was: reuse `CircuitCanvasSurface` + `RenderScene` and
// `CanvasToolController` rather than writing a parallel vocabulary, and if a second instance of
// that machinery is needed, say so. Here is the measured answer.
//
// REUSED, unchanged, no copy:
//   `RenderScene`, `SceneBuilder`, `CoreTextMeasurer`    : D6's drawing API
//   `CoreGraphicsSceneRenderer`, `RenderViewport`,
//     `RenderOptions`, `RenderStats`                     : the backend and its camera
//   `CanvasViewport`, `CanvasAppearance`, `CircuitPalette`: the shell's camera and theme
//   `CircuitSceneSource.theme(for:)`                     : the 12-entry per-frame colour swap
//   `LogisimStd.AppearanceShapePainter`                  : every per-shape `paint`
//
// NOT REUSED, and the reason in each case:
//
//   `CircuitCanvasSurface`; its entire contract is `setCircuit(_ circuit: Circuit?)`, its
//     rebuild key is `CircuitSceneGeometryKey(circuit:…)`, and its hit tests return
//     `CanvasHitTarget`/`ComponentID`. An `<appear>` has no `Circuit`, no `Component` and no
//     `ComponentID`. Making the surface serve both means making all three polymorphic, in a file
//     another agent is live in.
//
//   `CanvasToolController`: it dispatches `Tool`/`AddTool`/`PokeTool`, whose vocabulary is
//     "place a component, poke a component, draw a wire". The appearance editor's tools are
//     `com.cburch.draw.tools.*`, a different and disjoint set (upstream keeps them in a different
//     *package* for the same reason). Routing shape editing through the component tool layer
//     would mean teaching `Tool` about `CanvasObject`.
//
// **The recommendation, stated rather than taken:** the thing genuinely worth sharing is the
// `NSView` shell: flipped coordinates, `renderViewport`, `worldToView`, grid painting, the
// backing-scale seam. That is ~60 lines duplicated below and it is the same 60 lines in
// `CircuitSceneView`. Factoring it into a `SceneHostingView` base class that both subclass is a
// change to `Canvas/CircuitSceneView.swift`, which this work does not own. Whoever owns it:
// that, not a polymorphic `CircuitSceneBuild`, is the right cut.

import AppKit
import CoreGraphics
import Foundation
import LogisimDraw
import LogisimKernel
import LogisimRender
import LogisimRenderBackend

@MainActor
protocol AppearanceCanvasDelegate: AnyObject {
  /// A press that hit `shape` (nil = empty space).
  func appearanceCanvasDidClick(_ shape: CanvasObject?, extending: Bool)
  /// A completed drag of the current selection, in world units.
  ///
  /// **Not necessarily grid-snapped.** Upstream leaves placement free in the appearance editor
  /// and snaps only while Control is held: see the input section below for the measurement.
  func appearanceCanvasDidDrag(dx: Int, dy: Int)
  /// A drag in progress. The view draws the preview; the model is untouched until release,
  /// because an in-progress gesture is not an undo entry.
  func appearanceCanvasIsDragging(dx: Int, dy: Int)
}

@MainActor
final class AppearanceCanvasNSView: NSView {

  weak var delegate: (any AppearanceCanvasDelegate)?

  var build = AppearanceSceneBuild() { didSet { needsDisplay = true } }
  var viewport = CanvasViewport() { didSet { needsDisplay = true } }
  var appearance_ = CanvasAppearance() { didSet { needsDisplay = true } }
  /// Selected shapes' world bounds, for the outline. Indices into `build.shapes`.
  var selectedIndices: Set<Int> = [] { didSet { needsDisplay = true } }

  private let renderer = CoreGraphicsSceneRenderer()
  private(set) var lastStats = RenderStats()

  /// Live drag offset, in world units. Applied to the *drawing* of the selection only; the
  /// model does not move until the mouse comes up.
  private var dragOffset: CGPoint = .zero

  override var isFlipped: Bool { true }
  override var isOpaque: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not supported") }

  // MARK: - Camera
  //
  // Identical to `CircuitSceneView.renderViewport`/`worldToView` and deliberately so; see the
  // file header for why it is duplicated rather than shared, and what the right cut is.

  var renderViewport: RenderViewport {
    let rect = bounds
    let zoom = max(viewport.zoom, CanvasViewport.minimumZoom)
    return RenderViewport(
      rect: rect,
      scale: zoom,
      sceneOriginX: Double(viewport.center.x) - Double(rect.width) / 2 / zoom,
      sceneOriginY: Double(viewport.center.y) - Double(rect.height) / 2 / zoom,
      yAxisPointsDown: true,
      backingScale: appearance_.backingScale
    ).alignedToPixelGrid()
  }

  var worldToView: CGAffineTransform {
    let vp = renderViewport
    return CGAffineTransform(translationX: vp.rect.minX, y: vp.rect.minY)
      .scaledBy(x: CGFloat(vp.scale), y: CGFloat(vp.scale))
      .translatedBy(x: CGFloat(-vp.sceneOriginX), y: CGFloat(-vp.sceneOriginY))
  }

  func worldPoint(_ viewPoint: CGPoint) -> CGPoint {
    viewPoint.applying(worldToView.inverted())
  }

  // MARK: - Drawing

  override func draw(_ dirtyRect: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    let palette = appearance_.palette

    ctx.setFillColor(palette[.canvasBackground].cgColor)
    ctx.fill(dirtyRect)

    let vp = renderViewport
    lastStats = renderer.render(
      build.scene, into: ctx, viewport: vp,
      options: RenderOptions(
        theme: CircuitSceneSource.theme(for: palette),
        antialias: appearance_.antialiasing,
        textAntialias: appearance_.antialiasing,
        snapStrokesToPixelGrid: true,
        batchPrimitives: true,
        background: nil))

    drawPortsAndAnchor(in: ctx)
    drawSelection(in: ctx)
  }

  /// The port anchors, which the shape painter deliberately does not draw.
  ///
  /// `AppearanceShapePainter.paint` skips `AppearanceElement` because `paintSubcircuit` does;
  /// a placement's ports are drawn from its *ends* by `InstancePainter.drawPorts()`, and drawing
  /// them twice would double every pin. Inside the editor they are the opposite: they are the
  /// most important thing on the canvas, because they are what a parent circuit wires to. So
  /// they are drawn here, as chrome, in the same relationship the selection outline has to the
  /// schematic: never emitted into the scene, so an export of the symbol does not contain them.
  ///
  /// Geometry is upstream's: `AppearancePort` draws an 8×8 square for an input and a 10-diameter
  /// circle for an output (`AppearancePort.INPUT_RADIUS = 4`, `OUTPUT_RADIUS = 5`), and
  /// `AppearanceAnchor` draws a cross plus a facing arrow. The distinction between input and
  /// output is not available from `AppearanceElement.location` alone, so both are drawn as the
  /// same marker for now: a real gap, named here rather than papered over.
  private func drawPortsAndAnchor(in ctx: CGContext) {
    let t = worldToView
    ctx.saveGState()
    defer { ctx.restoreGState() }
    ctx.setLineWidth(1)

    ctx.setStrokeColor(NSColor.systemBlue.cgColor)
    for point in build.portLocations {
      let p = point.applying(t)
      ctx.strokeEllipse(in: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
    }

    if let anchor = build.anchorLocation {
      let p = anchor.applying(t)
      ctx.setStrokeColor(NSColor.systemRed.cgColor)
      ctx.move(to: CGPoint(x: p.x - 7, y: p.y))
      ctx.addLine(to: CGPoint(x: p.x + 7, y: p.y))
      ctx.move(to: CGPoint(x: p.x, y: p.y - 7))
      ctx.addLine(to: CGPoint(x: p.x, y: p.y + 7))
      ctx.strokePath()
    }
  }

  private func drawSelection(in ctx: CGContext) {
    guard !selectedIndices.isEmpty else { return }
    let t = worldToView
    ctx.saveGState()
    defer { ctx.restoreGState() }
    ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
    ctx.setLineWidth(1)
    ctx.setLineDash(phase: 0, lengths: [4, 3])
    for index in selectedIndices where index < build.bounds.count {
      var rect = build.bounds[index].applying(t)
      rect = rect.offsetBy(
        dx: dragOffset.x * CGFloat(renderViewport.scale),
        dy: dragOffset.y * CGFloat(renderViewport.scale))
      ctx.stroke(rect.insetBy(dx: -2, dy: -2))
    }
  }

  // MARK: - Input
  //
  // `CanvasListener.mousePressed/Dragged/Released` delegating to
  // `com.cburch.draw.tools.SelectTool.setMouse`, MOVE_ALL branch.
  //
  // ═══════════════════════════════════════════════════════════════════════════════════════════
  // THE APPEARANCE EDITOR DOES NOT SNAP BY DEFAULT. THAT IS UPSTREAM, AND IT IS DELIBERATE.
  //
  // This is the surface where a user draws a subcircuit's symbol: a mux trapezoid, a curve, a
  // label bar. Upstream leaves placement FREE here precisely so a symbol that looks right can be
  // drawn, and offers snapping on demand through a modifier. The schematic canvas is the
  // opposite (always snapped, `CanvasGrid`), and conflating the two is the trap this block
  // exists to close: the port previously snapped by default and treated a modifier as an
  // *escape*, which is upstream's rule inverted on both halves.
  //
  // ── MEASURED, NOT READ ─────────────────────────────────────────────────────────────────────
  //
  // Every claim below was produced by *executing* 4.1.0's bytecode, in the manner
  // `GridSnapParityTests` established: a harness reflected `SelectTool.setMouse` onto a real
  // `AppearanceCanvas` holding a real `Selection` of a real `com.cburch.draw.shapes.Rectangle`,
  // and read back what upstream handed to `Selection.setMovingDelta`.
  //
  //   javac -cp /Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar
  //   java  -Djava.awt.headless=true -cp .:<that jar> Oracle
  //
  // Rectangle at (103,107), deliberately OFF grid, dragged by (13,7):
  //
  //     modifiers                 upstream's delta      where the shape lands
  //     none                      (13, 7)              (116, 114)   free, stays off grid
  //     CTRL_DOWN_MASK  (128)     (17, 3)              (120, 110)   ON the grid
  //     ALT_DOWN_MASK   (512)     (13, 7)              (116, 114)   Alt is not a modifier here
  //
  // ── THE DESTINATION IS SNAPPED, NOT THE DELTA ──────────────────────────────────────────────
  //
  // The 17 above is the whole point, and it is a defect independent of which modifier means
  // what. Upstream computes
  //
  //     dx = canvas.snapX(minHandleX + dx) - minHandleX
  //
  // ; the *absolute destination* is put on the grid, and the delta is whatever gets it there.
  // Snapping the delta instead (`snap(13)` = 10) preserves the shape's existing 3-unit offset
  // forever: 103 -> 113 -> 123, off grid at every step, and no drag can ever recover. Snapping
  // the destination lands it: 103 -> 120. With CTRL held and no pointer movement at all,
  // upstream answers (-3, +3); it pulls an off-grid shape straight onto the grid.
  //
  // `minHandleX`/`minHandleY` are the minimum over *every handle of every selected shape*, both
  // seeded at `Integer.MAX_VALUE`; not the bounding box. For a Curve the control handle can sit
  // outside the bounds, so the two genuinely differ.
  //
  // ── ROUNDING ───────────────────────────────────────────────────────────────────────────────
  //
  // `AppearanceCanvas.snapX(int)`/`snapY(int)` were executed against
  // `com.cburch.logisim.gui.main.Canvas.snapXToGrid(int)` over every input in [-400, 400]: the
  // two are the **same function**. So this reuses `CanvasGrid.snapXToGrid` rather than growing a
  // second rounding rule, and inherits everything `GridSnapParityTests` already proved about it
  // : round-half-away-from-zero, the negative-coordinate branch, and the 32-bit wrap. The base
  // `com.cburch.draw.canvas.Canvas.snapX` is the identity (`iload_1; ireturn`); only the
  // appearance subclass snaps at all.
  //
  // ** One correction to the audit that prompted this work. ** It listed a fourth divergence as
  // "`floor(v+0.5)` vs Swift `.rounded()`" and placed it at the grid snap. Measured, the grid
  // snap was NOT divergent: `((v + 5) / 10) * 10` in `int` is round-half-away-from-zero, and
  // Swift's default `.rounded()` is `.toNearestOrAwayFromZero`: the same rule on every
  // reachable value. A red probe substituting that one-liner here reddened nothing, which is how
  // it was caught. The two part only at the 32-bit boundary, where `snapX` adds 5 before
  // dividing and Java's `int` wraps while `Double` sails past.
  //
  // The rounding divergence is real but sits one step earlier, at the pointer integerisation.
  // The two endpoints are integerised *separately* with Java's `Math.round` before subtracting
  // (`AppearanceCanvas.repairEvent` -> `(int) Math.round(px / zoom)`, then
  // `Location.create(x, y, false)` in `mousePressed`/`setMouse`, which does not snap), and
  // `Math.round` is `floor(v + 0.5)`: NOT Swift's `.rounded()`; they disagree on every negative
  // half-integer, which a Retina pointer position genuinely produces. Rounding the continuous
  // *difference* once, as the old code did, is a third function again: press at world 0.6 and
  // release at 10.4 is a delta of 9 upstream and 10 that way.
  // ═══════════════════════════════════════════════════════════════════════════════════════════

  /// `SelectTool.DRAG_TOLERANCE`. Until the pointer has moved more than this from the press
  /// point, `setMouse` returns without touching the selection.
  ///
  /// Load-bearing *because* the default is now free placement. While the port snapped by
  /// default, a 1-unit tremor during a click rounded to a delta of 0 and was invisible; without
  /// snapping it would commit a 1-unit move and knock a shape off whatever alignment it had.
  /// This is upstream's guard against exactly that, and it is not optional here.
  static let dragTolerance = 2

  /// `SelectTool.dragStart`: the press point, integerised the way upstream integerises it.
  private var dragStart: ToolPoint?

  /// `SelectTool.dragEffective`. Latches true for the rest of the gesture once the tolerance is
  /// beaten, and `mouseReleased` commits nothing while it is false.
  private var dragEffective = false

  /// `SelectTool.setMouse`'s MOVE_ALL branch, as a pure function of its inputs.
  ///
  /// Split out from `mouseDragged` for two reasons: it is the geometry worth testing and it
  /// needs no window to test, and upstream's `mouseReleased` calls `setMouse` *again* with the
  /// release event rather than reusing a cached delta, so releasing with a different modifier
  /// state changes what gets committed, and both paths must share one implementation.
  ///
  /// `origin` is the selection's minimum handle corner; it is only read when `snapping`.
  static func movingDelta(
    start: ToolPoint, end: ToolPoint, snapping: Bool, selectionOrigin origin: ToolPoint
  ) -> (dx: Int, dy: Int) {
    let dx = wrap32(end.x &- start.x)
    let dy = wrap32(end.y &- start.y)
    guard snapping else { return (dx, dy) }
    // `canvas.snapX(handle.x + dx) - handle.x`, in Java `int`. `CanvasGrid.snapXToGrid` already
    // wraps internally; the add and the subtract around it have to wrap too or a delta near the
    // 32-bit boundary would diverge in the other direction.
    return (
      wrap32(CanvasGrid.snapXToGrid(wrap32(origin.x &+ dx)) &- origin.x),
      wrap32(CanvasGrid.snapYToGrid(wrap32(origin.y &+ dy)) &- origin.y)
    )
  }

  /// `Math.abs(dx) + Math.abs(dy) > DRAG_TOLERANCE`, the press-jitter guard from `setMouse`.
  static func dragBeatsTolerance(dx: Int, dy: Int) -> Bool {
    abs(dx) + abs(dy) > dragTolerance
  }

  /// The `(minX, minY)` over every handle of every selected shape: upstream seeds both with
  /// `Integer.MAX_VALUE` and scans `CanvasObject.getHandles(null)`. An empty selection therefore
  /// leaves the seed in place, and the snap arithmetic above wraps on it exactly as Java does.
  static func selectionOrigin(of shapes: [CanvasObject]) -> ToolPoint {
    var minX = Int(Int32.max)
    var minY = Int(Int32.max)
    for shape in shapes {
      for handle in shape.handles(nil) {
        if handle.x < minX { minX = handle.x }
        if handle.y < minY { minY = handle.y }
      }
    }
    return ToolPoint(x: minX, y: minY)
  }

  /// The instance side of `setMouse`: resolves the event, applies the tolerance latch, and
  /// returns the delta upstream would hand to `Selection.setMovingDelta`, or nil while the
  /// gesture is still inside the tolerance, which is upstream's early `return`.
  private func movingDelta(for event: NSEvent) -> (dx: Int, dy: Int)? {
    guard let start = dragStart else { return nil }
    let end = CanvasGrid.circuitPoint(worldPoint(convert(event.locationInWindow, from: nil)))
    if !dragEffective {
      guard Self.dragBeatsTolerance(dx: end.x - start.x, dy: end.y - start.y) else { return nil }
      dragEffective = true
    }
    // `(mods & InputEvent.CTRL_DOWN_MASK) != 0`, executed from the jar as 128. Control, not
    // Option: `ALT_DOWN_MASK` (512) is read nowhere in this branch, so Option does nothing.
    return Self.movingDelta(
      start: start,
      end: end,
      snapping: event.modifierFlags.contains(.control),
      selectionOrigin: Self.selectionOrigin(of: selectedShapes()))
  }

  private func selectedShapes() -> [CanvasObject] {
    selectedIndices.sorted().compactMap { $0 < build.shapes.count ? build.shapes[$0] : nil }
  }

  override func mouseDown(with event: NSEvent) {
    let view = convert(event.locationInWindow, from: nil)
    let world = worldPoint(view)
    // `SelectTool.mousePressed`: `dragStart = Location.create(x, y, false)`; the press point is
    // NOT snapped, whatever the modifiers.
    dragStart = CanvasGrid.circuitPoint(world)
    dragEffective = false
    dragOffset = .zero
    delegate?.appearanceCanvasDidClick(
      hitShape(at: world), extending: event.modifierFlags.contains(.shift))
  }

  override func mouseDragged(with event: NSEvent) {
    guard let delta = movingDelta(for: event) else { return }
    dragOffset = CGPoint(x: CGFloat(delta.dx), y: CGFloat(delta.dy))
    needsDisplay = true
    delegate?.appearanceCanvasIsDragging(dx: delta.dx, dy: delta.dy)
  }

  override func mouseUp(with event: NSEvent) {
    defer {
      dragStart = nil
      dragEffective = false
      dragOffset = .zero
      needsDisplay = true
    }
    guard dragStart != nil else { return }
    // `SelectTool.mouseReleased` re-runs `setMouse` on the release event before reading the
    // delta, then commits only `if (dragEffective && !delta.equals(Location.create(0, 0)))`.
    guard let delta = movingDelta(for: event), delta.dx != 0 || delta.dy != 0 else { return }
    delegate?.appearanceCanvasDidDrag(dx: delta.dx, dy: delta.dy)
  }

  /// Bounds-level hit, resolved by the model's exact `contains` test afterwards. Kept here so a
  /// press with no delegate still behaves.
  private func hitShape(at world: CGPoint) -> CanvasObject? {
    guard let index = AppearanceSceneSource.index(at: world, in: build) else { return nil }
    return build.shapes[index]
  }
}
