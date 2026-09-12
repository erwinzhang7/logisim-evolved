// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ============================================================================
// THE REAL RENDER SURFACE.
//
// Replaces `PlaceholderRenderSurface`. It takes a `Circuit`, builds a `RenderScene` through
// `LogisimStd.CircuitRenderer`, which drives the 61 real `paintInstance` implementations,
// and paints it with `LogisimRender.CoreGraphicsSceneRenderer` into the view that
// `CanvasHostNSView` embeds.
//
// ── What is per-frame and what is not ───────────────────────────────────────────────────────
//
// Rebuild (walk the circuit, run every painter): circuit changed, gate shape changed, or the
//                                                  light/dark ink colour flipped.
// Per frame: cull to the viewport, swap the 12-entry
//                                                  colour theme, draw.
//
// That split is the reason `SpatialIndex` and `RenderScene.colorSlots` exist, and it is what
// the throughput test in `LogisimRenderTests/CullingTests` (5,000 components culled to a
// viewport) already assumes. A surface that rebuilt on `setAppearance` would defeat both, and
// `setAppearance` is called on every SwiftUI update pass, every backing-property change and
// every appearance change, so "rebuild on appearance" means "rebuild continuously".
//
// ── Upstream contrast ───────────────────────────────────────────────────────────────────────
//
// Upstream repaints every component in the circuit on every frame with two `Graphics2D` clones
// each and no culling anywhere, then hides the cost behind `CanvasPaintCoordinator`'s ~20 fps
// cap and its rotating 47–53 ms delays (`CanvasPaintCoordinator.java:37-39`). Nothing here caps
// anything: invalidation is a rectangle and the window server drives repaint at display
// refresh.
// ============================================================================

import AppKit
import CoreGraphics
import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimRenderBackend
import LogisimStd

// MARK: - CircuitBackedRenderSurface

/// The extra verb the real surface needs and the seam deliberately does not carry.
///
/// `RenderSeam.swift` is written so the shell never has to name a renderer type; it equally
/// must not have to name `LogisimFile.Circuit`, so `setCircuit` lives here rather than being
/// bolted onto `CircuitRenderSurface`. Whoever wires the codec to the shell calls this; nobody
/// else needs to know it exists.
@MainActor
protocol CircuitBackedRenderSurface: CircuitRenderSurface {
  func setCircuit(_ circuit: Circuit?)
}

// MARK: - CircuitCanvasSurface

@MainActor
final class CircuitCanvasSurface: CircuitBackedRenderSurface {

  private let view = CircuitSceneView()
  private var circuit: Circuit?
  private var geometryKey: CircuitSceneGeometryKey?

  /// Bumped whenever the circuit reports a structural change, so the geometry key differs even
  /// though the `Circuit` object is the same one.
  private var revision: UInt64 = 0
  private var circuitSubscription: CircuitChangeRelay?

  /// The running simulation, or nil. Set once by `LogisimFileProjectHost` right after the surface
  /// is made; nil for every test rig and for a surface with no document behind it.
  var simulationAccess: (any CanvasSimulationAccess)?

  /// The propagation counter the scene was last built at. See
  /// `CircuitSceneGeometryKey.simulationRevision` for why values belong in the geometry key.
  private var simulationRevision: UInt64 = 0

  init() {
    view.appearance_ = appearance
  }

  // MARK: Content

  /// `private(set)` rather than `private` so `CircuitEditorCanvas` can *derive* its appearance
  /// from this one instead of keeping a second copy. Two copies is what caused the dark-mode
  /// preview bug: the canvas's copy was never written, so it stayed `.light` forever and every
  /// tool overlay drew with a black `componentStroke` on a dark canvas.
  private(set) var appearance = CanvasAppearance()

  /// Fires after the appearance actually changes, so an already-rendered tool overlay can be
  /// rebuilt in the new theme. Without it, flipping the system theme mid-drag leaves the pending
  /// wire in the old colour until the next mouse move: `#2661`'s shape, at a smaller scale.
  var appearanceDidChange: (() -> Void)?

  var build: CircuitSceneBuild { view.build }

  /// Every hit target in paint order. The project layer uses this to answer "what is in this
  /// circuit" without a second traversal: the same table the hit tests index into.
  var hitTargets: [CanvasHitTarget] { view.build.targets }

  func setCircuit(_ circuit: Circuit?) {
    guard self.circuit !== circuit else { return }
    circuitSubscription = nil
    self.circuit = circuit
    revision = 0
    if let circuit {
      circuitSubscription = CircuitChangeRelay(circuit: circuit) { [weak self] in
        self?.circuitDidChange()
      }
    }
    rebuild(force: true)
  }

  /// A structural edit. The scene is geometry, so it has to be rebuilt: but only the scene:
  /// the camera, the palette and the selection all survive.
  func circuitDidChange() {
    revision &+= 1
    rebuild(force: true)
  }

  /// The propagation thread has settled the circuit again; the schematic is now stale.
  ///
  /// Cheap when nothing changed; the revision is part of the geometry key, so an unchanged count
  /// is a dictionary comparison and no rebuild.
  func setSimulationRevision(_ value: UInt64) {
    guard simulationRevision != value else { return }
    simulationRevision = value
    rebuild(force: false)
    view.needsDisplay = true
  }

  private func rebuild(force: Bool) {
    let key = CircuitSceneGeometryKey(
      circuit: circuit, revision: revision, appearance: appearance,
      hidden: view.hiddenComponentIDs, simulationRevision: simulationRevision)
    if !force, key == geometryKey { return }
    geometryKey = key
    view.build = buildScene()
    view.needsDisplay = true
  }

  /// One scene, painted from the live simulation when there is one.
  ///
  /// **The whole build is inside `withModelLock`, deliberately, and not each state read.** Every
  /// painter the walk reaches asks the context for values and `InstanceData`; locking per call
  /// would be slower *and* less correct, because the frame could then straddle a propagation and
  /// show half of one circuit state beside half of the next.
  private func buildScene() -> CircuitSceneBuild {
    guard let simulationAccess else {
      return CircuitSceneSource.build(
        circuit: circuit, appearance: appearance, hidden: view.hiddenComponentIDs)
    }
    return simulationAccess.withModelLock {
      let live = simulationAccess.liveState.map { state -> any PaintContext in
        let context = LiveCircuitPaintContext(
          state: state,
          showColor: appearance.showsValueColours,
          gateShape: GateShape(rawValue: appearance.gateShape.rawValue) ?? .shaped,
          pinAppearance: .dotSmall,
          componentColor: .rgba(appearance.palette[.componentStroke].sceneRGBA))
        // The real canvas ground, so the port ring's hole reads as a hole in dark mode too.
        context.markerHoleColorOverride = .rgba(appearance.palette[.canvasBackground].sceneRGBA)
        return context
      }
      return CircuitSceneSource.build(
        circuit: circuit, appearance: appearance, hidden: view.hiddenComponentIDs,
        liveContext: live)
    }
  }

  // MARK: - CircuitRenderSurface

  var renderView: NSView { view }

  var contentBounds: CGRect { view.build.contentBounds }

  func setViewport(_ viewport: CanvasViewport) {
    guard view.viewport != viewport else { return }
    view.viewport = viewport
    view.needsDisplay = true
  }

  /// Palette / grid / gate-shape changed.
  ///
  /// The expensive path, rebuilding geometry, is taken only when
  /// `CircuitSceneGeometryKey` actually moves. Everything else is a repaint with a different
  /// 12-entry theme, which is #2661 fixed properly: the colours are re-resolved from the live
  /// `NSAppearance` on every push and nothing is cached in a static.
  func setAppearance(_ appearance: CanvasAppearance) {
    guard self.appearance != appearance else { return }
    self.appearance = appearance
    view.appearance_ = appearance
    rebuild(force: false)
    view.needsDisplay = true
    appearanceDidChange?()
  }

  func setSelection(_ ids: Set<ComponentID>, haloed: ComponentID?) {
    guard view.selection != ids || view.haloed != haloed else { return }
    view.selection = ids
    view.haloed = haloed
    view.needsDisplay = true
  }

  func setMarquee(_ worldRect: CGRect?) {
    guard view.marquee != worldRect else { return }
    view.marquee = worldRect
    view.needsDisplay = true
  }

  // MARK: Tool overlay
  //
  // The tool layer's half of the surface, added when `ToolCanvas` got its first conformer
  // (`CircuitEditorCanvas`). Two scenes rather than one because `RenderScene` interns points and
  // colour slots by index, so a poke highlight cannot be concatenated into the item scene; it is
  // one more draw call. See `ToolOverlaySceneBuilder`.

  /// The active tool's overlay, already rendered.
  ///
  /// `hidden` is honoured: a move preview draws the selection shifted by the drag delta, so the
  /// unshifted originals have to stop being drawn or the drag shows both copies. That means not
  /// emitting their geometry, which is a rebuild, but only when the set actually moves, which is
  /// twice per drag (gesture start, gesture end) rather than once per frame, because
  /// `CircuitSceneGeometryKey` now carries it.
  func setToolOverlay(
    items: RenderScene, poke: RenderScene?, hidden: Set<ComponentRef>, previewOffset: CGSize
  ) {
    view.toolOverlayScene = items.isEmpty ? nil : items
    view.pokeOverlayScene = poke

    let ids = Set(hidden.map { CircuitSceneSource.identity(of: $0.component) })
    // BEFORE the rebuild, and that ordering is the whole of this fix. The rebuild below is what
    // removes a hidden component's geometry from the scene, and a selection outline is traced
    // from that geometry, so this is the last frame in which there is anything to capture.
    // See `CircuitSceneView.dragPreview`.
    view.setDragPreview(hiding: ids, offset: previewOffset)
    if view.hiddenComponentIDs != ids {
      view.hiddenComponentIDs = ids
      rebuild(force: false)
    }
    view.needsDisplay = true
  }

  /// `setHighlightedWires(WireSet)`, mapped onto the adornment pass.
  func setHighlight(_ ids: Set<ComponentID>) {
    guard view.highlighted != ids else { return }
    view.highlighted = ids
    view.needsDisplay = true
  }

  func invalidate(worldRect: CGRect?) {
    guard let worldRect, !worldRect.isNull, !worldRect.isInfinite else {
      view.needsDisplay = true
      return
    }
    // Inflated by a couple of points: the scene inflates primitive bounds by the stroke width
    // already, and being generous here can only cost an extra blit, never drop one.
    let viewRect = worldRect.applying(view.worldToView).insetBy(dx: -3, dy: -3)
    view.setNeedsDisplay(viewRect)
  }

  // MARK: Hit testing

  /// Topmost drawable at a world point.
  ///
  /// Answered out of the same `SpatialIndex` that culls, mapping a group tag back through
  /// `Circuit.components` ordering; never by re-walking the circuit. Components are tried
  /// first and in reverse paint order (topmost wins); wires only if nothing else claimed the
  /// point, which matches the draw order (wires go under component bodies) and stops a wire
  /// running beneath a gate from stealing the click.
  func hitTest(worldPoint: CGPoint, tolerance: Double) -> CanvasHitTarget? {
    let build = view.build
    guard !build.isEmpty else { return nil }
    let t = max(tolerance, 0)

    var exactFallback: CanvasHitTarget?
    for index in candidateIndices(around: worldPoint, tolerance: t) {
      let target = build.targets[index]
      if target.kind == .wire { continue }
      // Bounds-level hits come out of the index; this second test is the exact geometry, and
      // is what stops the bounding box of an L-shaped body from swallowing its concave corner.
      if build.components[index].contains(location(worldPoint)) { return target }
      if exactFallback == nil, target.bounds.insetBy(dx: -t, dy: -t).contains(worldPoint) {
        exactFallback = target
      }
    }
    if let exactFallback { return exactFallback }

    // Wires: a zero-area shape can only be hit with a tolerance, so it is distance to the
    // segment, nearest first.
    let limit = CGFloat(max(t, 1))
    var best: (distance: CGFloat, index: Int)?
    for segment in build.wireSegments {
      let d = segment.squaredDistance(to: worldPoint)
      guard d <= limit * limit else { continue }
      if best == nil || d < best!.distance {
        best = (d, segment.targetIndex)
      }
    }
    if let best { return build.targets[best.index] }
    return nil
  }

  func hitTest(worldRect: CGRect) -> [CanvasHitTarget] {
    let build = view.build
    guard !build.isEmpty, !worldRect.isNull else { return [] }
    var results: [CanvasHitTarget] = []
    var seen = Set<Int>()

    for groupIndex in build.scene.visibleGroups(in: sceneBounds(worldRect)) {
      let tag = build.scene.groups[Int(groupIndex)].tag
      guard let index = build.target(forTag: tag), seen.insert(index).inserted else { continue }
      if build.targets[index].kind == .wire { continue }
      results.append(build.targets[index])
    }
    // A component that paints nothing has no group, so it never appears above. D8 placeholders
    // are exactly that case and must still be marquee-selectable.
    for index in build.unresolvedTargetIndices where seen.insert(index).inserted {
      if build.targets[index].bounds.intersects(worldRect) {
        results.append(build.targets[index])
      }
    }
    for segment in build.wireSegments where seen.insert(segment.targetIndex).inserted {
      if worldRect.intersects(
        CGRect(
          x: min(segment.a.x, segment.b.x), y: min(segment.a.y, segment.b.y),
          width: abs(segment.b.x - segment.a.x), height: abs(segment.b.y - segment.a.y))
          .insetBy(dx: -0.5, dy: -0.5))
      {
        results.append(build.targets[segment.targetIndex])
      }
    }
    return results
  }

  /// Group indices whose bounds are within `tolerance` of the point, topmost first.
  private func candidateIndices(around point: CGPoint, tolerance: Double) -> [Int] {
    let build = view.build
    let probe = CGRect(x: point.x, y: point.y, width: 0, height: 0)
      .insetBy(dx: -CGFloat(tolerance), dy: -CGFloat(tolerance))
    var indices: [Int] = []
    var seen = Set<Int>()
    for groupIndex in build.scene.visibleGroups(in: sceneBounds(probe)).reversed() {
      let tag = build.scene.groups[Int(groupIndex)].tag
      guard let index = build.target(forTag: tag), seen.insert(index).inserted else { continue }
      indices.append(index)
    }
    // Same reason as in the rect form: placeholders paint nothing and so are not in the index.
    for index in build.unresolvedTargetIndices.reversed() where seen.insert(index).inserted {
      indices.append(index)
    }
    return indices
  }

  private func location(_ point: CGPoint) -> Location {
    Location.create(
      Int(point.x.rounded()), Int(point.y.rounded()), hasToSnap: false)
  }

  private func sceneBounds(_ rect: CGRect) -> SceneBounds {
    SceneBounds(
      minX: clamped(rect.minX.rounded(.down)),
      minY: clamped(rect.minY.rounded(.down)),
      maxX: clamped(rect.maxX.rounded(.up)),
      maxY: clamped(rect.maxY.rounded(.up)))
  }

  private func clamped(_ value: CGFloat) -> Int32 {
    guard value.isFinite else { return value < 0 ? Int32.min : Int32.max }
    return Int32(max(Double(Int32.min), min(Double(Int32.max), Double(value))))
  }

  // MARK: Offscreen

  /// File ▸ Export Image and Print. No window, no view, no camera: the same scene rendered
  /// through the same backend into a bitmap context, which is precisely why the walker was put
  /// in `LogisimStd` instead of here.
  func snapshotImage(worldRect: CGRect, scale: Double, appearance: CanvasAppearance)
    -> CGImage?
  {
    let source: CircuitSceneBuild
    if CircuitSceneGeometryKey(circuit: circuit, revision: revision, appearance: appearance)
      == geometryKey
    {
      source = view.build
    } else {
      source = CircuitSceneSource.build(circuit: circuit, appearance: appearance)
    }
    return CircuitSceneRasterizer.image(
      build: source, worldRect: worldRect, scale: scale, appearance: appearance)
  }
}

// MARK: - Offscreen rasterisation

/// Shared by Export Image, Print, and the verification test. Kept out of the view so that
/// "does this circuit draw?" can be answered with no `NSView` in existence; the failure this
/// whole task exists to prevent is a renderer that compiles, runs, and emits nothing, and that
/// is only catchable by rasterising and looking at pixels.
enum CircuitSceneRasterizer {

  static func viewport(
    worldRect: CGRect, scale: Double, backingScale: Double, pixelSize: CGSize
  ) -> RenderViewport {
    RenderViewport(
      rect: CGRect(origin: .zero, size: pixelSize),
      scale: scale,
      sceneOriginX: Double(worldRect.minX),
      sceneOriginY: Double(worldRect.minY),
      yAxisPointsDown: false,
      backingScale: backingScale)
  }

  static func options(for appearance: CanvasAppearance, opaque: Bool) -> RenderOptions {
    RenderOptions(
      theme: CircuitSceneSource.theme(for: appearance.palette),
      antialias: appearance.antialiasing,
      textAntialias: appearance.antialiasing,
      snapStrokesToPixelGrid: true,
      batchPrimitives: true,
      background: opaque ? appearance.palette[.canvasBackground].sceneRGBA : nil)
  }

  static func image(
    build: CircuitSceneBuild, worldRect: CGRect, scale: Double, appearance: CanvasAppearance
  ) -> CGImage? {
    let width = Int((Double(worldRect.width) * scale).rounded(.up))
    let height = Int((Double(worldRect.height) * scale).rounded(.up))
    guard width > 0, height > 0, width < 20_000, height < 20_000 else { return nil }
    guard let context = SceneRasterizer.makeContext(width: width, height: height) else {
      return nil
    }
    let vp = viewport(
      worldRect: worldRect, scale: scale, backingScale: 1,
      pixelSize: CGSize(width: width, height: height))
    CoreGraphicsSceneRenderer().render(
      build.scene, into: context, viewport: vp,
      options: options(for: appearance, opaque: true))
    return context.makeImage()
  }

  /// Pixels rather than a `CGImage`, so a test can assert the output is not blank.
  static func bitmap(
    build: CircuitSceneBuild, worldRect: CGRect, scale: Double, appearance: CanvasAppearance
  ) -> (bitmap: SceneBitmap, stats: RenderStats)? {
    let width = Int((Double(worldRect.width) * scale).rounded(.up))
    let height = Int((Double(worldRect.height) * scale).rounded(.up))
    guard width > 0, height > 0, width < 20_000, height < 20_000 else { return nil }
    return SceneRasterizer.render(
      build.scene,
      width: width,
      height: height,
      viewport: viewport(
        worldRect: worldRect, scale: scale, backingScale: 1,
        pixelSize: CGSize(width: width, height: height)),
      options: options(for: appearance, opaque: true))
  }
}

// MARK: - Circuit change relay

/// Keeps a `CircuitListenerClosure` alive for as long as the surface wants the subscription.
///
/// D3: `Circuit` holds its listeners in a `WeakListenerList`, so a closure registered and
/// dropped is a subscription that silently stops firing. The token makes the lifetime explicit
/// ; the surface holds it, and releasing it is what unsubscribes.
private final class CircuitChangeRelay {
  private let listener: CircuitListenerClosure
  private weak var circuit: Circuit?

  init(circuit: Circuit, onChange: @escaping @MainActor () -> Void) {
    self.circuit = circuit
    self.listener = CircuitListenerClosure { event in
      switch event.action {
      case .add, .remove, .clear, .invalidate, .transactionDone, .changeDefaultBoxAppearance:
        // `onMainActor`, not `MainActor.assumeIsolated`. `.invalidate` is what
        // `InstanceComponent.fireInvalidated()` posts, and subcircuit propagation reaches that
        // from the SIMULATION thread while creating a substate; D1 keeps the kernel outside
        // Swift Concurrency, so there is no actor there to assume. Asserting isolation trapped
        // the whole process with EXC_BREAKPOINT; the identical bug in
        // `LogisimFileProjectHost.observeCircuit` is where it was found, and this relay had it
        // too and had simply not been attached in a suite that propagates yet.
        onMainActor { onChange() }
      case .setName, .checkName, .displayChange:
        break
      }
    }
    circuit.addCircuitListener(listener)
  }

  deinit {
    circuit?.removeCircuitListener(listener)
  }
}
