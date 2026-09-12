// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ============================================================================
// THE DRAWING HALF of the real render surface.
//
// Flipped, like every coordinate convention in this port: world space is Logisim's own,
// origin top-left, +x right, **+y down**, so world → view is a pure scale-and-translate with
// no Y flip anywhere (`CanvasViewport`'s header is the binding statement of that).
//
// ── The backing-scale seam, finished here ───────────────────────────────────────────────────
//
// `CanvasAppearance.backingScale` was already being set from `window.backingScaleFactor` by
// `CanvasHostNSView.pushAppearance()`, and `GridSnap` already took a `backingScale`, and
// `RenderViewport` already carried one, and nothing joined the two ends, so every render ran
// with the default `backingScale: 1`. That is invisible on a 1x display and wrong on every Mac
// this targets: `GridSnap.strokeOffset` decides whether a pen is an *odd number of device
// pixels* wide and nudges it by half a pixel if so, and at 2x with `backingScale == 1` it makes
// that decision on points, offsetting strokes that should sit flush and leaving flush the ones
// that should be offset. `renderViewport` below is where the two ends meet.
// ============================================================================

import AppKit
import CoreGraphics
import Foundation
import LogisimRender
import LogisimRenderBackend
// For `CircuitRenderer.wireGroupTag`; the one tag `SelectionSilhouette` must refuse, because
// the whole wire layer shares it and it is not any single component's geometry.
import LogisimStd

final class CircuitSceneView: NSView {

  // MARK: State pushed by the surface

  var build = CircuitSceneBuild() {
    didSet {
      // Invalidated here rather than recomputed, because most rebuilds are followed by a frame
      // with nothing selected, which needs no map at all. See `silhouetteGroups`.
      cachedSilhouetteGroups = nil
      needsDisplay = true
    }
  }

  /// `SelectionSilhouette.groupsByTag(in: build.scene)`, memoised for the life of one `build`.
  ///
  /// Building it is one pass over every group in the scene. That is cheap once and not cheap
  /// 60 times a second: a drag reassigns `toolOverlayScene` on every mouse event and repaints,
  /// so a per-frame rebuild would walk 5,000 groups on every mouse move of a drag that has a
  /// selection: against a renderer measured at 2.03 ms/frame for that circuit. The scene's
  /// geometry cannot change without `build` being reassigned (it is a value type; any mutation
  /// runs the setter), so the cache has exactly one invalidation point and it is above.
  private var cachedSilhouetteGroups: [UInt64: SceneGroup]?

  private var silhouetteGroups: [UInt64: SceneGroup] {
    if let cachedSilhouetteGroups { return cachedSilhouetteGroups }
    let map = SelectionSilhouette.groupsByTag(in: build.scene)
    cachedSilhouetteGroups = map
    return map
  }

  var viewport = CanvasViewport()
  /// Trailing underscore: `NSView.appearance` is already taken, and shadowing it with a
  /// different type is exactly the kind of thing that compiles and then misbehaves.
  var appearance_ = CanvasAppearance()
  var selection: Set<ComponentID> = []
  var haloed: ComponentID?
  var marquee: CGRect?

  /// The active tool's overlay: a rubber band, a pending wire, ghosts, a value callout.
  ///
  /// Drawn as a *second scene* through the same backend, in world space, after the schematic and
  /// before the view-space adornments. Two scenes because `RenderScene` interns points,
  /// transforms and colour slots by index, so they cannot be concatenated; and world space
  /// because everything a tool draws is in circuit coordinates and must zoom with the circuit,
  /// unlike a selection outline.
  ///
  /// **`didSet` is load-bearing: without it, dragging smears the canvas.** This was a plain
  /// stored property, and `CircuitCanvasSurface.setToolOverlay` assigns it on every mouse event of
  /// a drag. Nothing marked the view dirty, so the old overlay's pixels were never invalidated;
  /// and because `draw(_:)` fills only `dirtyRect` (see there), whichever frames did get painted
  /// left the previous ones on screen. Dragging a pin across the canvas left a trail of copies of
  /// it: the first defect this project found by someone simply using the app.
  ///
  /// The whole view is invalidated rather than the overlay's own rectangle because `RenderScene`
  /// exposes no bounds, so a precise union of the old and new scenes would mean walking both
  /// primitive lists on every mouse move. That is an optimisation with a real cost and no measured
  /// need: upstream repaints the entire canvas on every change and caps itself at ~20 fps to
  /// survive it (`CanvasPaintCoordinator`, upstream #786), whereas this renderer culls to the
  /// viewport and was measured at 2.03 ms/frame with 5,000 components. Correctness first; if a
  /// profile ever says this matters, `SceneBounds` is the place to add it.
  var toolOverlayScene: RenderScene? {
    didSet { needsDisplay = true }
  }
  /// The live poke highlight, drawn by the poked component's own `InstancePoker.paint`. Its own
  /// scene because it changes on every keystroke while the overlay items change on every mouse
  /// event, and neither should force the other to rebuild.
  ///
  /// Same `didSet`, same reason: a poke highlight that moves without invalidating leaves the old
  /// highlight behind. Assigned from the same setter, so it had the identical defect.
  var pokeOverlayScene: RenderScene? {
    didSet { needsDisplay = true }
  }
  /// `Tool.getHiddenComponents(Canvas)`; components the scene must not draw, because the tool
  /// is drawing a moved copy of them itself.
  ///
  /// **Honoured, and that is what makes `dragPreview` necessary.** `CircuitSceneSource.build`
  /// passes this to `CircuitRenderer.render(_:into:context:skipping:)`, so a hidden component
  /// emits no primitives and therefore has **no `SceneGroup`**, which is where a selection
  /// silhouette is read from. See `dragPreview`.
  var hiddenComponentIDs: Set<ComponentID> = []

  /// The selection adornment for components the active tool has hidden, captured while they were
  /// still in the scene, plus the delta their ghosts are being drawn at.
  ///
  /// ── THE DEFECT THIS EXISTS FOR ─────────────────────────────────────────────────────────────
  ///
  /// Reported from real use, dragging a Pin: "the highlight is not following the dragging
  /// preview. nor is it fitted to the object." Both halves, one cause.
  ///
  /// A move preview hides the originals (above) so the ghost is not drawn on top of them. Hiding
  /// them removes their geometry from `build.scene`, so `SelectionSilhouette.groupsByTag` has no
  /// entry for them and `drawAdornments` fell through to `.bounds`: the rectangle fallback,
  /// drawn from `build.targets[…].bounds`, which is the component's **committed, unshifted**
  /// position. So the instant a drag started, the outline both lost the component's shape and
  /// stopped moving: a box, left behind.
  ///
  /// Note what did *not* cause it. The silhouette rule is fine; `SelectionSilhouetteTests`
  /// traces a Pin's pentagon and always did. It was never asked, because by the time the drag
  /// began there was nothing left in the scene to ask about.
  ///
  /// ── WHY CAPTURE RATHER THAN RE-DERIVE ──────────────────────────────────────────────────────
  ///
  /// The obvious alternative is to trace the *ghost* in `toolOverlayScene`, which is genuinely
  /// the shape on screen. It was rejected on what it draws: a ghost goes through
  /// `paintGhost`, and upstream's default `paintGhost` is a sentinel that falls back to the plain
  /// offset-bounds rectangle (`ToolOverlaySceneBuilder`'s header, and its `ghostsFellBackToBounds`
  /// counter). Most components have no `paintGhost` of their own, so their ghost *is* a box,
  /// and the outline would still collapse to a rectangle on mouse-down for everything but a Pin,
  /// which is three quarters of the reported defect surviving the fix.
  ///
  /// Capturing keeps the outline the user was already looking at and moves it. The shape cannot
  /// change mid-gesture, which is the property being asked for.
  ///
  /// Nil whenever nothing is hidden, so a committed drag reverts to reading the live build on the
  /// very next frame, see `setDragPreview(hiding:offset:)`.
  private(set) var dragPreview: DragPreview?
  /// `setHighlightedWires(WireSet)`: the poke tool's bus highlight.
  var highlighted: Set<ComponentID> = []

  private let renderer = CoreGraphicsSceneRenderer()

  /// Last frame's culling numbers. Kept because D6's claim is only worth something if it is
  /// measured, and this is where the measurement is available.
  private(set) var lastStats = RenderStats()

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { false }
  /// The scene fills the view opaquely; letting AppKit know saves it compositing what is
  /// behind a canvas that is never see-through.
  override var isOpaque: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layerContentsRedrawPolicy = .duringViewResize
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not supported") }

  // MARK: - Geometry

  /// The camera, expressed the way the backend wants it.
  ///
  /// Derived from `bounds` rather than from `viewport.viewSize` on purpose: the host pushes the
  /// size on `setFrameSize`, so during a live resize the two disagree for one frame, and a
  /// scene drawn against a stale size visibly slides. `bounds` is the truth at draw time.
  var renderViewport: RenderViewport {
    let rect = bounds
    let zoom = max(viewport.zoom, CanvasViewport.minimumZoom)
    let originX = Double(viewport.center.x) - Double(rect.width) / 2 / zoom
    let originY = Double(viewport.center.y) - Double(rect.height) / 2 / zoom
    return RenderViewport(
      rect: rect,
      scale: zoom,
      sceneOriginX: originX,
      sceneOriginY: originY,
      // The view is flipped, so user space already increases downward: no compensating
      // flip, and therefore no upside-down text to undo.
      yAxisPointsDown: true,
      // THE SEAM. Without this the pen-parity test in `GridSnap` runs on points.
      backingScale: appearance_.backingScale
    ).alignedToPixelGrid()
  }

  /// World → view, derived from the *aligned* render viewport so overlays land on exactly the
  /// same pixels the scene did. Deriving it independently from `CanvasViewport.transform`
  /// would put selection rectangles a fraction of a pixel off the geometry they outline.
  var worldToView: CGAffineTransform {
    let vp = renderViewport
    return CGAffineTransform(translationX: vp.rect.minX, y: vp.rect.minY)
      .scaledBy(x: CGFloat(vp.scale), y: CGFloat(vp.scale))
      .translatedBy(x: CGFloat(-vp.sceneOriginX), y: CGFloat(-vp.sceneOriginY))
  }

  private var visibleWorldRect: CGRect {
    let vp = renderViewport
    guard vp.scale > 0 else { return .null }
    return CGRect(
      x: vp.sceneOriginX,
      y: vp.sceneOriginY,
      width: Double(vp.rect.width) / vp.scale,
      height: Double(vp.rect.height) / vp.scale)
  }

  // MARK: - Drawing

  /// How many times this view has actually drawn.
  ///
  /// **Instrumentation, in the idiom `CircuitEditorCanvas` already uses** ("Counters, not
  /// booleans": `repaintAllCount`, `repaintedRects`, `focusRequestCount`). It exists because
  /// `NSView.needsDisplay` is not observable in a headless test: on a detached view the setter is
  /// dropped, and on an offscreen window it does not survive a `display()`. Asserting on it
  /// produced a suite that failed against the CORRECT fix, and then one that passed against the
  /// broken one; both readings were the instrument, not the code.
  ///
  /// A count of real `draw(_:)` calls is the honest observable: a test assigns an overlay, asks
  /// the window to `displayIfNeeded()`, and sees whether a frame happened. That exercises the
  /// whole chain, `didSet` → `needsDisplay` → AppKit → `draw`, rather than any one link, so it
  /// cannot pass against a `didSet` that has stopped invalidating.
  private(set) var drawCount = 0

  override func draw(_ dirtyRect: NSRect) {
    drawCount += 1
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    let palette = appearance_.palette

    ctx.setFillColor(palette[.canvasBackground].cgColor)
    ctx.fill(dirtyRect)

    if appearance_.showGrid { drawGrid(in: ctx) }

    // The scene. One call; the backend culls to the viewport itself.
    let vp = renderViewport
    lastStats = renderer.render(
      build.scene,
      into: ctx,
      viewport: vp,
      options: RenderOptions(
        // The per-frame colour swap. 12 entries, no geometry touched, see #2661.
        theme: CircuitSceneSource.theme(for: palette),
        antialias: appearance_.antialiasing,
        textAntialias: appearance_.antialiasing,
        snapStrokesToPixelGrid: true,
        batchPrimitives: true,
        // nil: the background is already painted above, in the *chrome* palette rather than
        // the scene's, so a dark canvas stays dark behind a schematic drawn in ink.
        background: nil))

    drawUnresolvedPlaceholders(in: ctx)
    drawToolOverlay(in: ctx, viewport: vp, palette: palette)
    drawAdornments(in: ctx)
  }

  /// The active tool's overlay and the live poke highlight.
  ///
  /// Same backend, same viewport, same pixel-grid snapping as the schematic, which is the whole
  /// point of routing a tool's drawing through `RenderScene` (D6) instead of handing it a
  /// `CGContext`: a pending wire lands on exactly the pixels the committed wire will.
  private func drawToolOverlay(
    in ctx: CGContext, viewport vp: RenderViewport, palette: CircuitPalette
  ) {
    guard toolOverlayScene != nil || pokeOverlayScene != nil else { return }
    let options = RenderOptions(
      theme: CircuitSceneSource.theme(for: palette),
      antialias: appearance_.antialiasing,
      textAntialias: appearance_.antialiasing,
      snapStrokesToPixelGrid: true,
      batchPrimitives: true,
      background: nil)
    if let scene = toolOverlayScene {
      renderer.render(scene, into: ctx, viewport: vp, options: options)
    }
    if let scene = pokeOverlayScene {
      renderer.render(scene, into: ctx, viewport: vp, options: options)
    }
  }

  /// Grid dots, culled to the visible span and dropped entirely once they would alias.
  ///
  /// Drawn in *view* space with a device-sized dot rather than in world space with a
  /// `1 / zoom` radius: a world-space dot grows and shrinks with the camera and turns into a
  /// blob at high zoom, which is what upstream's grid does.
  private func drawGrid(in ctx: CGContext) {
    let world = visibleWorldRect
    guard !world.isNull else { return }
    let spacing = appearance_.gridSpacing
    guard spacing > 0 else { return }
    let zoom = max(viewport.zoom, CanvasViewport.minimumZoom)
    // Below ~4 points between marks the grid is noise, not information.
    guard zoom * spacing >= 4 else { return }

    let transform = worldToView
    let dot = 1.0 / max(appearance_.backingScale, 1)
    ctx.setFillColor(appearance_.palette[.gridDot].cgColor)

    var rects: [CGRect] = []
    var y = (Double(world.minY) / spacing).rounded(.down) * spacing
    while y <= Double(world.maxY) {
      var x = (Double(world.minX) / spacing).rounded(.down) * spacing
      while x <= Double(world.maxX) {
        let p = CGPoint(x: x, y: y).applying(transform)
        rects.append(CGRect(x: p.x - dot / 2, y: p.y - dot / 2, width: dot, height: dot))
        x += spacing
      }
      y += spacing
      // A pathological zoom-out is already excluded by the alias guard above; this is the
      // belt-and-braces bound so a malformed viewport cannot spin here (D13 in spirit).
      if rects.count > 200_000 { break }
    }
    guard !rects.isEmpty else { return }
    ctx.fill(rects)
  }

  /// D8: components whose library did not resolve paint nothing; `CircuitRenderer` skips them
  /// deliberately rather than stamping a box over the schematic. The *canvas* still has to show
  /// them, or a file the port preserves perfectly looks to the user like a file it silently
  /// ate. Drawn here, as chrome, so an exported image does not contain it.
  private func drawUnresolvedPlaceholders(in ctx: CGContext) {
    guard !build.unresolvedTargetIndices.isEmpty else { return }
    let transform = worldToView
    let stroke = appearance_.palette[.componentStroke].opacity(0.55)
    ctx.saveGState()
    ctx.setStrokeColor(stroke.cgColor)
    ctx.setFillColor(appearance_.palette[.componentFill].opacity(0.25).cgColor)
    ctx.setLineWidth(1)
    ctx.setLineDash(phase: 0, lengths: [4, 3])
    for index in build.unresolvedTargetIndices {
      let rect = build.targets[index].bounds.applying(transform)
      guard rect.intersects(bounds) else { continue }
      ctx.fill(rect)
      ctx.stroke(rect)
    }
    ctx.restoreGState()
  }

  /// Selection, attention halo and marquee.
  ///
  /// All three are view-space chrome with fixed point widths, because that is what a native Mac
  /// canvas does: upstream scales its selection outline with the zoom, so at 25% the outline
  /// is thinner than a hairline and at 400% it is a slab.
  /// The selection pen, in view points.
  ///
  /// Reported from real use: "double border size on the blue". It was 1pt, which on a Retina
  /// panel is two device pixels and reads as a hairline next to a component whose own outline is
  /// two *world* units. Named rather than spelled `2` at the two call sites because the rect
  /// fallback's inset is half of it; writing the number twice is how those two silently drift
  /// apart.
  static let selectionStrokeWidth: CGFloat = 2

  /// Where the selection outline goes for a component's view-space bounds.
  ///
  /// **The fallback shape, not the usual one.** A component whose drawn geometry is available is
  /// traced by `selectionSilhouette` below; this rectangle is what is left for a wire, for a
  /// component that draws nothing closed, and for one too busy to trace legibly.
  ///
  /// Extracted from `drawAdornments` so it can be asserted: the geometry is three lines and was
  /// gated by nothing, so the previous version's mistake, expanding OUTWARD, could not have been
  /// caught by any test. Pure, so `SelectionOutlineTests` can pin both cases without a window.
  static func selectionOutline(for bounds: CGRect, isWire: Bool) -> CGRect {
    // A wire's bounds are a zero-thickness line, so an outline drawn exactly on them would be
    // invisible; it is the one case that must grow. 1.5pt is the minimum that still reads at 100%.
    if isWire { return bounds.insetBy(dx: -1.5, dy: -1.5) }
    // Everything else is pulled IN by half the stroke, so the drawn line lands ON the
    // component's boundary rather than straddling or clearing it. Derived from the pen rather
    // than written as a literal, so doubling the pen cannot leave the inset behind.
    let half = selectionStrokeWidth / 2
    return bounds.insetBy(dx: half, dy: half)
  }

  // MARK: - Selection adornments

  /// Tell the view which components are about to leave the scene, and where their ghosts are.
  ///
  /// **Call this BEFORE the rebuild that hides them.** It reads the geometry out of the current
  /// `build`, which is the last moment that geometry exists;
  /// `CircuitCanvasSurface.setToolOverlay` is the one caller and does exactly that. Calling it
  /// after the rebuild is not a crash and not a compile error: it silently captures nothing and
  /// restores the defect, which is why `SelectionFollowsDragTests` drives the surface rather than
  /// this method.
  ///
  /// Capture is per component and once: an id already captured is left alone, because on every
  /// frame after the first its geometry is gone and re-reading it would overwrite a good capture
  /// with a fallback. Ids no longer hidden are dropped, so a preview that gains and loses
  /// rerouted wires does not accumulate them.
  func setDragPreview(hiding ids: Set<ComponentID>, offset: CGSize) {
    guard !ids.isEmpty else {
      dragPreview = nil
      return
    }
    var captured = dragPreview?.captured.filter { ids.contains($0.key) } ?? [:]
    for id in ids where captured[id] == nil {
      guard let index = build.indexByID[id] else { continue }
      captured[id] = liveAdornment(at: index)
    }
    dragPreview = DragPreview(offset: offset, captured: captured)
  }

  /// What the selection pass will draw for one component: its shape, its fallback rectangle, and
  /// the world-space delta to apply before the camera.
  ///
  /// The single expression of "which geometry does this component's outline come from", so the
  /// answer can be asserted without a window and cannot differ between the halo and the
  /// selection; the two used to read `build.targets` independently and only one of them would
  /// have been fixed.
  func selectionAdornment(for id: ComponentID) -> SelectionAdornment? {
    if let dragPreview, var captured = dragPreview.captured[id] {
      captured.offset = dragPreview.offset
      return captured
    }
    guard let index = build.indexByID[id] else { return nil }
    return liveAdornment(at: index)
  }

  /// The view-space geometry the selection pass strokes for one component.
  ///
  /// **One expression of it, called by the drawing and by the tests.** Both arms used to be
  /// written out inline in `drawAdornments`, where nothing headless could reach them, so every
  /// assertion about the selection outline was really an assertion about a re-implementation of
  /// it, free to agree with the canvas or not. That is the same disease the corpus census had.
  ///
  /// The rectangle arm comes back as a path as well. Nothing about the drawing changed by doing
  /// that: filling a rectangle and then stroking the same rectangle is exactly what
  /// `CGPathDrawingMode.fillStroke` does to a rectangular path.
  func selectionPath(for id: ComponentID, camera: CGAffineTransform) -> CGPath? {
    guard let adornment = selectionAdornment(for: id) else { return nil }
    let toView = adornment.worldToView(camera)
    switch adornment.silhouette {
    case .body(let shapes):
      let path = SelectionSilhouette.path(for: shapes, worldToView: toView)
      return path.isEmpty ? nil : path
    case .bounds:
      let rect = CircuitSceneView.selectionOutline(
        for: adornment.bounds.applying(toView), isWire: adornment.isWire)
      return CGPath(rect: rect, transform: nil)
    }
  }

  /// The attention halo's view-space rectangle, or nil when nothing is haloed.
  ///
  /// Named and separate for the same reason `selectionPath` is. It follows a drag, the inspected
  /// component is usually the one being dragged, and a halo left at the old position is the
  /// reported defect wearing a different colour, and a claim that something follows a drag is
  /// worth exactly as much as the test that can watch it move.
  ///
  /// `showsAttentionHalo` is deliberately NOT consulted here: this answers where the halo goes,
  /// not whether the user asked for one.
  func haloRect(camera: CGAffineTransform) -> CGRect? {
    guard let haloed, let adornment = selectionAdornment(for: haloed) else { return nil }
    return adornment.bounds.applying(adornment.worldToView(camera)).insetBy(dx: 0.5, dy: 0.5)
  }

  /// The adornment as the *current* build sees it: no drag offset, and `.bounds` if the
  /// component drew nothing traceable (or is hidden, which is the case `dragPreview` covers).
  private func liveAdornment(at index: Int) -> SelectionAdornment {
    let target = build.targets[index]
    let silhouette =
      silhouetteGroups[UInt64(index + 1)]
      .map { SelectionSilhouette.of(group: $0, in: build.scene) } ?? .bounds
    return SelectionAdornment(
      silhouette: silhouette, bounds: target.bounds, isWire: target.kind == .wire)
  }

  private func drawAdornments(in ctx: CGContext) {
    let transform = worldToView
    let palette = appearance_.palette

    // ── THE ATTENTION HALO, RESTYLED RATHER THAN DELETED ─────────────────────────────────────
    //
    // Reported from real use: "the orange box can straight up go, its ugly". It can, and the
    // orange was never upstream's anyway; `Canvas.HALO_COLOR` in the 4.1.0 jar is
    // `new Color(255, 0, 255)`, MAGENTA, and upstream paints it with `fillOval`/`drawOval`, not a
    // rectangle. So both the colour (`0xFF8000`) and the shape were port inventions.
    //
    // What is NOT a port invention is the feature. `AppPreferences.ATTRIBUTE_HALO` is real, the
    // preference audit confirmed our `showsAttentionHalo` is live and consumed, and deleting the
    // drawing would leave that preference inert; the exact defect class three separate audits
    // have been removing from this app. So the capability stays and only the appearance changes:
    // a thin ring in the selection hue instead of a heavy orange box.
    //
    // It is also drawn INSIDE the selection outline rather than 4pt outside it, so a component
    // that is both selected and inspected reads as one object with emphasis, rather than two
    // concentric boxes of competing colours.
    //
    // Routed through `selectionAdornment` rather than `build.targets` so that it follows a drag
    // for the same reason the selection does. The inspected component is very often the one being
    // dragged, and a halo left behind at the old position is the same defect wearing a different
    // colour.
    if appearance_.showsAttentionHalo, let rect = haloRect(camera: transform) {
      ctx.setStrokeColor(palette[.halo].cgColor)
      ctx.setLineWidth(1.5)
      ctx.stroke(rect)
    }

    // The poke tool's bus highlight. Drawn before the selection so a wire that is both
    // highlighted and selected shows the selection colour on top, which is upstream's z-order.
    if !highlighted.isEmpty {
      ctx.setStrokeColor(palette[.halo].cgColor)
      ctx.setLineWidth(3)
      for id in highlighted {
        guard let index = build.indexByID[id] else { continue }
        let rect = build.targets[index].bounds.applying(transform).insetBy(dx: -2, dy: -2)
        guard rect.intersects(bounds) else { continue }
        ctx.stroke(rect)
      }
    }

    if !selection.isEmpty {
      ctx.setStrokeColor(palette[.selectionStroke].cgColor)
      ctx.setFillColor(palette[.selectionFill].cgColor)
      ctx.setLineWidth(CircuitSceneView.selectionStrokeWidth)
      // ── TRACE THE OBJECT, DO NOT BOX IT ───────────────────────────────────────────────────
      //
      // Reported from real use, selecting a Pin: "make it the same shape as the object, why rect
      // around the funny shape?? colours fine double border size on the blue". A Pin in the
      // shipped appearance is a PENTAGON (`Pin.drawInputShape` → `g.drawPolygon`, five points),
      // so a bounding rectangle around it is visibly the wrong outline no matter how tightly it
      // hugs, which is why yesterday's tightening did not settle it.
      //
      // The component's real geometry is already in the scene, so nothing has to re-run a
      // painter: `SelectionSilhouette.of` reads the component's own primitives back out of its
      // `SceneGroup` and returns the closed shapes to trace. Everything about *which* shapes is
      // in that one function, deliberately, so the rule is readable in one place and assertable
      // without a window.
      //
      // One map per *build*, not one per frame and not one scan per selected component; see
      // `silhouetteGroups`.
      //
      // ── AND IT FOLLOWS THE DRAG ───────────────────────────────────────────────────────────
      //
      // `selectionAdornment` answers both "which shape" and "where", because during a move
      // preview those are the same question: the component has been hidden, so its shape is no
      // longer in the scene and has to come from the capture, which is also the only thing that
      // knows how far the ghost has travelled. See `dragPreview`.
      for id in selection {
        guard let path = selectionPath(for: id, camera: transform),
          path.boundingBox.intersects(bounds)
        else { continue }
        ctx.addPath(path)
        // Stroke centred ON the component's own drawn edge; no outward offset. That is the
        // literal reading of "the same shape as the object", and it is the reason no inset is
        // computed for the traced arm the way the rectangle fallback computes one: a rectangle
        // can be pulled in by half a pen, a five-point polygon cannot without offsetting the
        // polygon itself.
        ctx.drawPath(using: .fillStroke)
      }
    }

    if let marquee, !marquee.isNull {
      let rect = marquee.applying(transform)
      ctx.setFillColor(palette[.marqueeFill].cgColor)
      ctx.setStrokeColor(palette[.marqueeStroke].cgColor)
      ctx.setLineWidth(1)
      ctx.fill(rect)
      ctx.stroke(rect)
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════════════════════
// MARK: - SelectionSilhouette
//
// THE SHAPE OF A SELECTION, and the one place the rule for it is written down.
//
// ── What upstream 4.1.0 does, so the divergence is a decision and not a drift ───────────────
//
// Cited from `/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar`
// via `javap -p -c`:
//
//   * `com.cburch.logisim.gui.main.CanvasPainter.drawWithUserState` calls
//     `Circuit.draw(context, hidden)` and *then* `Selection.draw(context, hidden)`. The first
//     call paints every component in its normal colours; being selected changes nothing about
//     it. There is no recolour of the selected component on the schematic canvas.
//   * `com.cburch.logisim.gui.main.Selection.draw` then, for every selected component that is
//     not suppressed and not hidden, asks for the `com.cburch.logisim.tools.CustomHandles`
//     feature. If it is absent it calls `ComponentDrawContext.drawHandles(component)`; if it is
//     present the component draws its own (`com.cburch.logisim.circuit.Wire` is the one that
//     does; it implements `CustomHandles`).
//   * `ComponentDrawContext.drawHandles` reads `component.getBounds(g)` and calls `drawHandle`
//     at the FOUR CORNERS of that box. `ComponentDrawContext.drawHandle(int,int)` is
//     `g.setColor(Color.white); g.fillRect(x-3, y-3, 7, 7); g.setColor(Color.black);
//     g.drawRect(x-3, y-3, 7, 7)`; a 7x7 white square with a black border.
//
// So 4.1.0's selection indicator is **four bounding-box corner handles**, in world coordinates,
// that grow and shrink with the zoom. It is neither an outline nor a recolour.
//
// **DELIBERATE DIVERGENCE**, and this file is refining one that already existed: this port marks
// a selection with a translucent fill and an outline in the system accent colour, at a fixed
// point width that does not scale with the zoom. The owner is entitled to a native-feeling Mac
// canvas and asked for this shape explicitly; what is recorded here is that upstream does
// something else and what that something is. Note that upstream's handles are just as much a
// *bounding-box* marker as the rectangle this replaces; tracing the component's real silhouette
// is a divergence in fidelity as well as in style, in the direction the owner asked for.
//
// ── THE RULE ────────────────────────────────────────────────────────────────────────────────
//
// A component's silhouette is traced from its own drawn primitives, filtered by four clauses.
// Each is a separate, named step in `of(group:in:)` below rather than one clever predicate,
// because a rule buried in a filter closure is a rule nobody can read or test.
//
//   1. SHAPE, NOT LETTERING, NOT LEADS. `text` and `image` are excluded because a label is not
//      part of an object's shape; a TTL chip draws its type name and its pin numbers, and
//      outlining "7408" would be worse than a box, which is exactly the failure this clause
//      exists to prevent. `line` is excluded because a single straight segment cannot bound
//      anything: every one of them in the corpus is a lead, a stub or a rule: a Pin's wire
//      stub, an OR gate's two input stubs, a Register's internal ruling.
//      Everything else stays, INCLUDING `polyline` and `arc`, and that is not an oversight.
//      `PainterShaped` draws an AND gate as an `arc` plus an open `polyline` and a NOT gate as a
//      closed `polyline`; excluding them was tried first and left a NOT gate outlined by its
//      inversion BUBBLE ALONE, which is worse than any box. Measured, not guessed; see
//      `SelectionSilhouetteTests.notGateTracesItsTriangleAndItsBubble`.
//
//   2. WHERE IT ENDS, NOT WHERE IT CONNECTS, AND NOT ITS INK. Two independent halves, and they
//      are separate predicates below because they reject different things for different reasons.
//
//      2a. NOT A CONNECTION MARKER. A port marker says where the component *connects*; it is not
//          part of where the component *ends*, so tracing one puts a little blue ring on every
//          pin. The primitive says so itself: `ScenePrimitive.Role.connectionMarker`, stamped by
//          `SceneBuilder.drawPinMarker`, which is the only producer of them in the app.
//
//          ── WHY THE ROLE AND NOT THE SHAPE ──────────────────────────────────────────────────
//          This clause used to read "stroked shapes only", justified by "port markers are
//          `fillOval`". That was never the rule. It was a proxy that happened to hold, and it
//          stopped holding the day `drawPinMarker` became a white ring (a fill AND a stroke):
//          at which point the silhouette started tracing every port as if it were a body
//          outline, and seven tests went red together.
//          A size rule was the obvious replacement and is also wrong: threshold it at the
//          largest marker footprint (`dot-bigger`, radius 10 grown to 12) and it swallows
//          `ComponentDrawContext.drawDongle`, which is `drawOval(x - 4, y - 4, 9, 9)`: a NOT
//          gate's inversion bubble, i.e. exactly the shape clause 1 exists to keep. The two
//          populations overlap at 9 vs 12, so no threshold separates them; measured, not
//          guessed. Asking the emitter is the only criterion that survives the marker being
//          restyled again, which is the whole lesson of that collision.
//
//      2b. OUTLINES, NOT INK. A stroked shape is something the painter drew as a boundary; a
//          filled one is ink, value swatches, LED glows, filled bodies, and is generally a
//          fill sitting inside the outline that already bounds it. A component drawn ONLY with
//          fills falls through and gets its bounding box, which is the honest answer for it.
//          Note this half no longer has anything to do with port markers: 2a rejects those
//          whichever style they are drawn in, and 2b would now reject only the ring's hole,
//          which 2a has already taken.
//
//   3. THE OUTER BOUNDARY, NOT THE FURNITURE. A surviving shape whose bounds sit inside another
//      surviving shape's bounds is interior detail, a flip-flop's clock wedge, a Clock's
//      waveform glyph, and is dropped. Only the shapes that form the object's edge remain.
//
//   4. LEGIBILITY CAP. Past `maxShapes` separate outer shapes there is no silhouette left to
//      read, only a tangle. This is the clause that catches the TTL family: a 7408 draws a
//      round-rect body, a notch arc and FOURTEEN pin-leg rectangles, all of which stick out of
//      the body and so survive clause 3. A single box is the more legible marker for it, and
//      falling back is a decision rather than a failure.
//
//   5. IT MUST ACTUALLY REPRESENT THE COMPONENT. The survivors have to span at least
//      `minimumCoverage` of the component's own extent on both axes, measuring that extent over
//      everything it draws except lettering AND except connection markers. Without this clause a
//      component whose body is drawn in `line`s but which happens to contain one stroked oval,
//      `Transistor`, `TransmissionGate`, would be marked by that oval alone, a small circle
//      floating in the middle of the part.
//
//      Both exclusions from the denominator are the same principle: a thing that is not part of
//      the component's shape must not be able to change the shape its selection draws. Lettering
//      is out so that *naming* a pin cannot; markers are out so that *restyling a marker*
//      cannot. That second one is not hypothetical; it was measured. When `drawPinMarker` became
//      a ring the marker's footprint grew from ±2 to ±4 around every port, and with markers still
//      in the denominator the worst traced component (`Pull Resistor`) fell from 0.76 to 0.722,
//      i.e. from six points clear of the floor to two. Nothing had changed about any component's
//      body; a restyle had quietly moved the whole traced population toward falling back to
//      boxes. With markers out, every figure below is exactly what it was before the ring.
//
// Nothing surviving, at any clause, means `.bounds`. That is also what every wire gets, and not
// by accident: the whole wire layer shares one `SceneGroup` tagged `CircuitRenderer.wireGroupTag`
// (see its header; a per-wire group would make the index useless), so an individual wire has no
// geometry of its own to find and `groupsByTag` never has an entry for it.
// ═══════════════════════════════════════════════════════════════════════════════════════════

/// One closed shape from a component's body.
///
/// The form is kept in the primitive's own coordinates with its `SceneTransform` alongside,
/// rather than pre-flattened to points: a rotated gate's body is still an oval, and flattening
/// it here would throw away the curve that `CGPath` can draw exactly. `Equatable` so a test can
/// state the expected shape rather than measure a rasterisation of it.
struct SelectionBodyShape: Equatable {

  enum Form: Equatable {
    /// `a,b,c,d` = x, y, width, height.
    case rect(CGRect)
    /// `e,f` are Java's arc *diameters*; the corner values here are radii, already halved.
    case roundedRect(CGRect, cornerWidth: CGFloat, cornerHeight: CGFloat)
    case ellipse(CGRect)
    /// Java's `Polygon`, closed. Point order is the painter's.
    case polygon([CGPoint])
    /// Java's `drawPolyline`, **open**. Kept distinct from `polygon` because an AND gate's three
    /// straight sides are a polyline and closing them would draw a line straight across the
    /// gate's middle; a NOT gate's triangle is also a polyline and needs no closing because the
    /// painter repeats its first point.
    case polyline([CGPoint])
    /// `Graphics.drawArc`: `e,f` in Java's degree convention. Held unresolved rather than
    /// flattened so it is built exactly the way `CoreGraphicsSceneRenderer.appendArc` builds it.
    case arc(CGRect, startDegrees: CGFloat, sweepDegrees: CGFloat)
    /// `GeneralPath`: the shaped and DIN gate painters.
    case path([PathOp])
  }

  var form: Form
  /// The primitive's scene transform: identity for the overwhelming majority, a rotation for a
  /// facing-aware component. Applied before the world→view camera.
  var transform: CGAffineTransform
  /// World-space extent, taken from the primitive's own precomputed `bounds`. Used only by
  /// clause 3; never re-derived from `form`, because the primitive's bounds are already
  /// stroke-inflated and the containment test should compare like with like.
  var worldBounds: CGRect
}

/// Everything the selection pass needs about one component: what to trace, what to fall back to,
/// and where to put it.
///
/// A value type rather than three parallel lookups because the three have to agree. They did not:
/// the shape came from `build.scene`, the rectangle from `build.targets`, and the position was
/// implicit in both, so hiding the component for a move preview moved one of them out from under
/// the other two and the outline turned into a box at the old location.
struct SelectionAdornment: Equatable {
  var silhouette: SelectionSilhouette
  /// World-space bounds, used only by the `.bounds` fallback.
  var bounds: CGRect
  /// A wire's outline has to grow, because a wire's bounds have no thickness.
  var isWire: Bool
  /// World-space translation applied **before** the camera. Non-zero only while the component is
  /// being previewed at a drag delta.
  var offset: CGSize = .zero

  /// The full world → view map for this adornment.
  ///
  /// Order matters and is why this is a method rather than two call sites doing it by hand: the
  /// drag delta is in *world* units, so it composes before the camera. Applying it afterwards
  /// would displace the outline by the delta in *points*, which is correct only at 100% zoom;
  /// the kind of bug that is invisible in the one configuration anyone tests by hand.
  func worldToView(_ camera: CGAffineTransform) -> CGAffineTransform {
    guard offset != .zero else { return camera }
    return CGAffineTransform(translationX: offset.width, y: offset.height)
      .concatenating(camera)
  }
}

/// The adornments for components the active tool has hidden, and the delta their ghosts are drawn
/// at. See `CircuitSceneView.dragPreview`.
struct DragPreview: Equatable {
  /// World-space delta, from `ToolOverlay.previewOffset`.
  var offset: CGSize
  /// Captured while the components were still in the scene. Never empty; an empty preview is
  /// spelled `nil`, so "is a drag being previewed" has one answer.
  var captured: [ComponentID: SelectionAdornment]
}

/// What the selection outline should trace for one component.
enum SelectionSilhouette: Equatable {
  /// Trace these shapes. Never empty.
  case body([SelectionBodyShape])
  /// No usable body geometry: fall back to `CircuitSceneView.selectionOutline`.
  case bounds
}

extension SelectionSilhouette {

  /// Clause 4's threshold. Eight is the point at which a traced outline stops reading as one
  /// object: a DIP switch body plus its switches, a TTL chip plus its legs.
  static let maxShapes = 8

  /// Clause 5's threshold. The traced shapes must span this fraction of the component's own
  /// shape extent, everything it draws except lettering and except connection markers, on
  /// both axes.
  ///
  /// 0.7 because the corpus decides it, not taste. Measured over every builtin component
  /// (`SelectionSilhouetteCorpusTests` re-measures it, so the number cannot rot):
  ///
  ///   * the lone-detail misfires this clause exists to catch sit far down: `Transistor` 0.23
  ///     and `Transmission Gate` 0.24, each a small stroked circle adrift in a part drawn
  ///     entirely in `line`s;
  ///   * everything whose survivor really is the body sits at 0.76 (`Pull Resistor`) and up,
  ///     with the great majority at 0.91–1.00;
  ///   * the band between is empty except for `Power` and `Register` at 0.67, which therefore
  ///     keep their box. Both are near-rectangular and their box and their trace differ by a
  ///     couple of world units, so that is a cost of nothing.
  ///
  /// 0.7 sits inside the empty band, not on either population's edge.
  static let minimumCoverage: CGFloat = 0.7

  /// Every component group in the scene, by tag. One pass, so a frame with a large selection
  /// walks `scene.groups` once instead of once per selected component.
  ///
  /// Runs carry tag `0` and the wire layer carries `CircuitRenderer.wireGroupTag`; neither is a
  /// component, and both are dropped here rather than at every call site.
  static func groupsByTag(in scene: RenderScene) -> [UInt64: SceneGroup] {
    var map: [UInt64: SceneGroup] = [:]
    map.reserveCapacity(scene.groups.count)
    for group in scene.groups {
      guard group.tag != 0, group.tag != CircuitRenderer.wireGroupTag else { continue }
      map[group.tag] = group
    }
    return map
  }

  /// THE RULE, in five named steps. See the block comment above for why each one is there.
  static func of(group: SceneGroup, in scene: RenderScene) -> SelectionSilhouette {
    guard group.count > 0 else { return .bounds }

    // ── TWO QUESTIONS, TWO PREDICATES, NEITHER DERIVED FROM THE OTHER ─────────────────────────
    //
    // A connection marker is excluded from BOTH the candidate list (clause 2a) and clause 5's
    // denominator, and the two exclusions are asked separately on purpose. They were briefly
    // folded into one `continue` in the walk below, and the effect was that a marker never
    // reached `isBodyOutline` at all: clause 2a became dead code, deleting it changed nothing,
    // and the red probe for it came back empty. A rule enforced twice is a rule that cannot be
    // probed, and an unprobeable rule is one nobody can tell is still working.
    //
    // Clause 5's denominator is a separate pass, `shapeExtent`, the same function tests call,
    // rather than accumulated inline, so there is exactly one expression of it. That is one more
    // linear pass over ONE component's primitives (tens of them), not over the scene; the
    // whole-scene walk this type's shape is tuned for is `SpatialIndex`, and it is untouched.
    let drawnExtent = shapeExtent(of: group, in: scene)

    // 1 + 2: candidacy is `isBodyOutline`'s question, and nothing else here consults it.
    // (`isBodyOutline` already rejects `text` and `image`, so lettering needs no separate skip.)
    var shapes: [SelectionBodyShape] = []
    for index in group.range {
      guard index >= 0, index < scene.primitives.count else { continue }
      let primitive = scene.primitives[index]
      guard isBodyOutline(primitive) else { continue }
      guard let shape = bodyShape(of: primitive, in: scene) else { continue }
      shapes.append(shape)
    }
    guard !shapes.isEmpty, !drawnExtent.isNull else { return .bounds }

    // 3: drop interior detail.
    let outer = shapes.enumerated().filter { candidate in
      !shapes.enumerated().contains { other in
        other.offset != candidate.offset
          && other.element.worldBounds.contains(candidate.element.worldBounds)
          // A pair of identical boxes contains each other; keeping the earlier one stops both
          // from being dropped, which would silently turn a two-primitive body into `.bounds`.
          && !(other.element.worldBounds == candidate.element.worldBounds
            && other.offset > candidate.offset)
      }
    }.map(\.element)
    guard !outer.isEmpty else { return .bounds }

    // 4: too busy to trace.
    guard outer.count <= maxShapes else { return .bounds }

    // 5: it must actually represent the component.
    guard coverage(of: outer, over: drawnExtent) >= minimumCoverage else { return .bounds }
    return .body(outer)
  }

  /// Clause 5's measurement, separate and pure so the threshold can be justified from data
  /// rather than asserted. The smaller of the two axis ratios; a shape that is full width and a
  /// tenth of the height represents the component no better than the transpose of it does.
  static func coverage(of shapes: [SelectionBodyShape], over extent: CGRect) -> CGFloat {
    guard !extent.isNull, extent.width > 0 || extent.height > 0 else { return 0 }
    var union = CGRect.null
    for shape in shapes { union = union.union(shape.worldBounds) }
    guard !union.isNull else { return 0 }
    // A zero-extent axis is fully covered by definition; only the other one carries information.
    let x = extent.width > 0 ? union.width / extent.width : 1
    let y = extent.height > 0 ? union.height / extent.height : 1
    return min(x, y)
  }

  /// Clause 1's lettering half. Separate from `isBodyOutline` because clause 5 needs it on its
  /// own: lettering is excluded from the denominator as well as from the tracing.
  static func isLettering(_ primitive: ScenePrimitive) -> Bool {
    primitive.kind == .text || primitive.kind == .image
  }

  /// Clause 5's denominator, as a membership predicate: is this primitive part of the
  /// component's SHAPE?
  ///
  /// Lettering is out so that *naming* a pin cannot change the outline its selection draws;
  /// connection markers are out so that *restyling a marker* cannot. Same principle, and it is
  /// worth having as one named predicate because those are the only two things that are drawn by
  /// a component and are not part of its shape.
  static func isShapeExtentMember(_ primitive: ScenePrimitive) -> Bool {
    !isLettering(primitive) && !isConnectionMarker(primitive)
  }

  /// The component's own shape extent; clause 5's denominator over a whole group.
  ///
  /// The ONE expression of it: `of` calls this, and so does every test that measures coverage,
  /// so a test measures **the quantity the rule acts on** rather than a re-implementation of it
  /// that can drift. It drifted: the corpus census used to build this extent inline with only
  /// lettering excluded, so it reported coverage figures the rule never saw, and no probe of
  /// the denominator could redden anything, because the two sides moved independently.
  static func shapeExtent(of group: SceneGroup, in scene: RenderScene) -> CGRect {
    var extent = CGRect.null
    for index in group.range {
      guard index >= 0, index < scene.primitives.count else { continue }
      let primitive = scene.primitives[index]
      guard isShapeExtentMember(primitive) else { continue }
      extent = extent.union(worldBounds(of: primitive))
    }
    return extent
  }

  /// Clause 2a, on its own so it can be asserted directly and so the reason it rejects a
  /// primitive is not confused with 2b's.
  ///
  /// A one-line predicate over a field, which is the point: the question "is this a connection
  /// marker" is answered by the emitter that drew it, not inferred from its shape, its size or
  /// its style. See `ScenePrimitive.Role`.
  static func isConnectionMarker(_ primitive: ScenePrimitive) -> Bool {
    primitive.role == .connectionMarker
  }

  /// Clauses 1 and 2, as a predicate on the primitive rather than on the shape, because all three
  /// questions are about how the primitive was *emitted*.
  static func isBodyOutline(_ primitive: ScenePrimitive) -> Bool {
    // 2a. Where the component connects is not where it ends; whatever shape the marker is.
    guard !isConnectionMarker(primitive) else { return false }
    // 2b. Ink is not boundary.
    guard primitive.style == .stroke else { return false }
    switch primitive.kind {
    case .polygon, .rect, .roundRect, .oval, .path, .polyline, .arc:
      return true
    // A single straight segment cannot bound anything: in the whole builtin corpus every one is
    // a lead, a stub or an internal rule.
    case .line:
      return false
    case .text, .image:
      return false
    }
  }

  private static func worldBounds(of primitive: ScenePrimitive) -> CGRect {
    let b = primitive.bounds
    guard !b.isEmpty else { return .null }
    return CGRect(
      x: CGFloat(b.minX), y: CGFloat(b.minY), width: CGFloat(b.width), height: CGFloat(b.height))
  }

  /// Reads one primitive's geometry back out of the scene's side pools.
  static func bodyShape(of primitive: ScenePrimitive, in scene: RenderScene) -> SelectionBodyShape?
  {
    let box = CGRect(
      x: CGFloat(primitive.a), y: CGFloat(primitive.b),
      width: CGFloat(primitive.c), height: CGFloat(primitive.d)
    ).standardized

    let form: SelectionBodyShape.Form
    switch primitive.kind {
    case .rect:
      form = .rect(box)
    case .roundRect:
      // Java's `drawRoundRect` takes arc *width* and *height*; diameters. `CGPath` wants radii.
      form = .roundedRect(
        box, cornerWidth: CGFloat(primitive.e) / 2, cornerHeight: CGFloat(primitive.f) / 2)
    case .oval:
      form = .ellipse(box)
    case .polygon, .polyline:
      let range = primitive.pointRange
      // Two points cannot bound anything, and a two-point polyline is a `drawLine` in disguise.
      guard range.lowerBound >= 0, range.upperBound <= scene.points.count, range.count >= 3
      else { return nil }
      let points = scene.points[range].map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
      form = primitive.kind == .polygon ? .polygon(points) : .polyline(points)
    case .arc:
      guard box.width > 0, box.height > 0, primitive.f != 0 else { return nil }
      form = .arc(box, startDegrees: CGFloat(primitive.e), sweepDegrees: CGFloat(primitive.f))
    case .path:
      let range = primitive.pointRange
      guard range.lowerBound >= 0, range.upperBound <= scene.pathOps.count, !range.isEmpty
      else { return nil }
      form = .path(Array(scene.pathOps[range]))
    case .line, .text, .image:
      return nil
    }

    let t = scene.transform(primitive)
    let world = primitive.bounds
    guard !world.isEmpty else { return nil }
    return SelectionBodyShape(
      form: form,
      transform: CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.tx, ty: t.ty),
      worldBounds: CGRect(
        x: CGFloat(world.minX), y: CGFloat(world.minY),
        width: CGFloat(world.width), height: CGFloat(world.height)))
  }

  /// Shapes → one view-space path, ready to stroke.
  ///
  /// Pure and separate from the drawing so a test can assert on the geometry that will be
  /// stroked. The primitive's own transform composes with the camera here, in that order: the
  /// scene transform is a world-space rotation and must apply before the world→view map, not
  /// after.
  static func path(
    for shapes: [SelectionBodyShape], worldToView: CGAffineTransform
  ) -> CGPath {
    let path = CGMutablePath()
    for shape in shapes {
      let t = shape.transform.concatenating(worldToView)
      switch shape.form {
      case .rect(let r):
        path.addRect(r, transform: t)
      case .roundedRect(let r, let cw, let ch):
        // `addRoundedRect` rejects a corner larger than half the side; clamping keeps a
        // degenerate attribute set from producing an empty path instead of an outline.
        let cornerW = min(cw, r.width / 2)
        let cornerH = min(ch, r.height / 2)
        if cornerW > 0, cornerH > 0 {
          path.addRoundedRect(in: r, cornerWidth: cornerW, cornerHeight: cornerH, transform: t)
        } else {
          path.addRect(r, transform: t)
        }
      case .ellipse(let r):
        path.addEllipse(in: r, transform: t)
      case .polygon(let points):
        guard let first = points.first else { continue }
        path.move(to: first, transform: t)
        for point in points.dropFirst() { path.addLine(to: point, transform: t) }
        path.closeSubpath()
      case .polyline(let points):
        guard let first = points.first else { continue }
        path.move(to: first, transform: t)
        for point in points.dropFirst() { path.addLine(to: point, transform: t) }
      // Deliberately NOT closed: see the `polyline` case on `Form`.
      case .arc(let box, let startDegrees, let sweepDegrees):
        appendArc(box, startDegrees, sweepDegrees, to: path, transform: t)
      case .path(let ops):
        appendPathOps(ops, to: path, transform: t)
      }
    }
    return path
  }

  /// `Graphics.drawArc`, built exactly as `CoreGraphicsSceneRenderer.appendArc` builds the
  /// stroked case: on a unit circle with an affine stretch, because Java measures the angle on
  /// the circle *before* the bounding box turns it into an ellipse (`Arc2D`'s skewed
  /// convention). Computing `atan2` on the ellipse puts every non-square arc at the wrong angle,
  /// and an AND gate's body is a non-square arc.
  private static func appendArc(
    _ box: CGRect, _ startDegrees: CGFloat, _ sweepDegrees: CGFloat,
    to path: CGMutablePath, transform: CGAffineTransform
  ) {
    let rx = box.width / 2
    let ry = box.height / 2
    guard rx > 0, ry > 0 else { return }
    let cx = box.midX
    let cy = box.midY
    // Scene space is y-down, so Java's +theta becomes -theta.
    let start = -startDegrees * .pi / 180
    let delta = -sweepDegrees * .pi / 180
    let unitToEllipse = CGAffineTransform(a: rx, b: 0, c: 0, d: ry, tx: cx, ty: cy)
      .concatenating(transform)
    // Without the explicit move, CG joins the previous subpath to the arc with a stray line.
    path.move(
      to: CGPoint(x: cx + rx * cos(start), y: cy + ry * sin(start)), transform: transform)
    path.addRelativeArc(
      center: .zero, radius: 1, startAngle: start, delta: delta, transform: unitToEllipse)
  }

  private static func appendPathOps(
    _ ops: [PathOp], to path: CGMutablePath, transform t: CGAffineTransform
  ) {
    func point(_ x: Float, _ y: Float) -> CGPoint { CGPoint(x: CGFloat(x), y: CGFloat(y)) }
    for op in ops {
      switch op {
      case .move(let x, let y):
        path.move(to: point(x, y), transform: t)
      case .line(let x, let y):
        // A `GeneralPath` that begins with a `lineTo` is malformed; `CGPath` traps on it, so a
        // leading line is promoted to a move rather than crashing the canvas.
        if path.isEmpty {
          path.move(to: point(x, y), transform: t)
        } else {
          path.addLine(to: point(x, y), transform: t)
        }
      case .quad(let cx, let cy, let x, let y):
        guard !path.isEmpty else { path.move(to: point(x, y), transform: t); continue }
        path.addQuadCurve(to: point(x, y), control: point(cx, cy), transform: t)
      case .cubic(let c1x, let c1y, let c2x, let c2y, let x, let y):
        guard !path.isEmpty else { path.move(to: point(x, y), transform: t); continue }
        path.addCurve(
          to: point(x, y), control1: point(c1x, c1y), control2: point(c2x, c2y), transform: t)
      case .close:
        if !path.isEmpty { path.closeSubpath() }
      }
    }
  }
}
