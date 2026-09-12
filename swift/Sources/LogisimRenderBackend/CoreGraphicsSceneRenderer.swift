// LogisimRender: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// The CoreGraphics backend (D6).
//
// It consumes a `RenderScene` and nothing else. No component code reaches this file, and this
// file knows nothing about components; that separation is the decision, and the reason a Metal
// renderer can replace this one at M9 without touching any of the 75 `paintInstance` ports.
//
// FOUR THINGS UPSTREAM DOES PER FRAME THAT THIS DOES NOT
//
//  1. A `Graphics2D` clone per component (`Circuit.java:474`, `:484`, mutually exclusive
//     branches of `if (isNullOrEmpty(hidden))`). At 5,000 components that is ~5,001 context
//     clones per frame, counting the frame's own. Here the context is configured once.
//     (D6 quoted `:540`/`:550` and 10,000; both were wrong, see
//     `docs/experiments/upstream-issues.md`.)
//  2. No culling of any kind, and no spatial index anywhere in the codebase; a repaint costs
//     O(all components) whatever is on screen. Here, group bounds reject the bulk of a large
//     schematic with one box test each, and `RenderStats.primitivesCulled` reports it.
//  3. Full text re-shaping for every label, with line 0 measured twice
//     (`GraphicsUtil.java`'s `drawText` -> `getTextBounds` -> a second `TextMetrics`). Here the
//     layout was resolved at build time and `CTLine`s are cached on `(font, string)`.
//  4. A fresh `BasicStroke` per width change, across 253 `switchToWidth` call sites. Here
//     consecutive primitives sharing a paint state fold into one `CGPath` and one draw call.
//
// The 20 fps cap in `CanvasPaintCoordinator` is upstream's defence against (2). We do not need
// one.

import CoreGraphics
import CoreText
import Foundation
import LogisimKernel
import LogisimRender

public final class CoreGraphicsSceneRenderer: SceneRenderer {

  public typealias Destination = CGContext

  public let textCache: CoreTextCache
  public weak var imageProvider: (any SceneImageProvider)?

  public init(textCache: CoreTextCache = .shared, imageProvider: (any SceneImageProvider)? = nil) {
    self.textCache = textCache
    self.imageProvider = imageProvider
  }

  // MARK: - Batch state

  /// The paint state a run of primitives has to share to be foldable into one draw call.
  private struct PaintState: Equatable {
    var rgba: RGBA
    var style: ScenePrimitive.Style
    var pen: StrokePen
    var fillRule: ScenePrimitive.FillRule
    var transform: UInt16
  }

  private var batchPath: CGMutablePath?
  private var batchState: PaintState?
  private var batchTransform: CGAffineTransform = .identity

  // MARK: - Entry point

  @discardableResult
  public func render(
    _ scene: RenderScene,
    into context: CGContext,
    viewport: RenderViewport,
    options: RenderOptions = .default
  ) -> RenderStats {
    var stats = RenderStats()

    context.saveGState()
    defer { context.restoreGState() }

    context.clip(to: viewport.rect)

    if let bg = options.background {
      context.setFillColor(bg.cgColor)
      context.fill(viewport.rect)
    }

    guard !scene.isEmpty else { return stats }

    // --- establish scene space: origin at the visual top-left of `rect`, y increasing down ---
    if viewport.yAxisPointsDown {
      context.translateBy(x: viewport.rect.minX, y: viewport.rect.minY)
    } else {
      context.translateBy(x: viewport.rect.minX, y: viewport.rect.maxY)
      context.scaleBy(x: 1, y: -1)
    }
    context.scaleBy(x: CGFloat(viewport.scale), y: CGFloat(viewport.scale))
    context.translateBy(x: CGFloat(-viewport.sceneOriginX), y: CGFloat(-viewport.sceneOriginY))

    // Scene space is y-down in every branch above, so glyphs need the compensating flip or
    // every label renders upside down.
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

    context.setShouldAntialias(options.antialias)
    context.setShouldSmoothFonts(options.textAntialias)
    context.setShouldSubpixelPositionFonts(options.textAntialias)
    context.setShouldSubpixelQuantizeFonts(options.textAntialias)
    context.setAllowsAntialiasing(options.antialias || options.textAntialias)
    context.setMiterLimit(CGFloat(StrokePen.miterLimit))
    context.interpolationQuality = .high

    let visible = viewport.visibleSceneBounds
    let cacheBefore = textCache.stats

    // One index query per frame; the result is also the denominator for the culling numbers.
    let visibleGroups = scene.visibleGroups(in: visible)
    var consideredPrimitives = 0

    // --- draw ---
    for groupIndex in visibleGroups {
      let group = scene.groups[Int(groupIndex)]
      stats.groupsConsidered += 1
      consideredPrimitives += Int(group.count)

      let transparent = group.opacity < 255
      if transparent {
        flush(into: context, viewport: viewport, options: options, stats: &stats)
        context.saveGState()
        context.setAlpha(CGFloat(group.opacity) / 255)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
      }

      var drewAnything = false
      for i in group.range {
        let prim = scene.primitives[i]
        guard prim.bounds.intersects(visible) else {
          stats.primitivesCulled += 1
          continue
        }
        draw(prim, scene: scene, context: context, viewport: viewport, options: options,
             stats: &stats)
        stats.primitivesDrawn += 1
        drewAnything = true
      }
      if drewAnything { stats.groupsDrawn += 1 }

      if transparent {
        flush(into: context, viewport: viewport, options: options, stats: &stats)
        context.endTransparencyLayer()
        context.restoreGState()
      }
    }
    flush(into: context, viewport: viewport, options: options, stats: &stats)

    // Count the primitives the spatial index rejected wholesale, not only the ones the exact
    // per-primitive test rejected: otherwise the culling number flatters itself.
    stats.primitivesCulled += scene.primitives.count - consideredPrimitives

    let cacheAfter = textCache.stats
    stats.textCacheHits = cacheAfter.hits - cacheBefore.hits
    stats.textCacheMisses = cacheAfter.misses - cacheBefore.misses
    return stats
  }

  // MARK: - Per-primitive dispatch

  private func draw(
    _ prim: ScenePrimitive, scene: RenderScene, context: CGContext, viewport: RenderViewport,
    options: RenderOptions, stats: inout RenderStats
  ) {
    let rgba = scene.color(of: prim.color, theme: options.theme)

    switch prim.kind {
    case .text:
      flush(into: context, viewport: viewport, options: options, stats: &stats)
      drawText(prim, scene: scene, context: context, rgba: rgba, options: options, stats: &stats)
      return
    case .image:
      flush(into: context, viewport: viewport, options: options, stats: &stats)
      drawImage(prim, scene: scene, context: context, stats: &stats)
      return
    default:
      break
    }

    let state = PaintState(
      rgba: rgba, style: prim.style, pen: prim.pen, fillRule: prim.fillRule,
      transform: prim.transform)

    // Even-odd fills must not be merged: two overlapping subpaths under the even-odd rule
    // cancel where they cross, which non-zero and separate fills do not. `java.awt.Polygon` is
    // even-odd, so this is the rule that keeps `fillPolygon` honest.
    let batchable = options.batchPrimitives
      && !(prim.style == .fill && prim.fillRule == .evenOdd)

    if !batchable || batchState != state {
      flush(into: context, viewport: viewport, options: options, stats: &stats)
      batchState = state
      batchPath = CGMutablePath()
      batchTransform =
        prim.transform != 0 ? scene.transform(prim).cgAffineTransform : .identity
    }

    let path = batchPath ?? CGMutablePath()
    batchPath = path
    append(prim, scene: scene, to: path)

    if !batchable {
      flush(into: context, viewport: viewport, options: options, stats: &stats)
    }
  }

  // MARK: - Flush

  private func flush(
    into context: CGContext, viewport: RenderViewport, options: RenderOptions,
    stats: inout RenderStats
  ) {
    guard let path = batchPath, let state = batchState, !path.isEmpty else {
      batchPath = nil
      batchState = nil
      return
    }
    batchPath = nil
    batchState = nil

    context.saveGState()

    // Order matters and is the whole of the grid-snapping contract:
    //   [viewport CTM] -> [half device pixel] -> [primitive transform] -> geometry.
    // The nudge sits outside the primitive's own rotation because a rotated gate is still
    // rasterised onto the same screen pixel grid.
    if state.style == .stroke, options.snapStrokesToPixelGrid {
      let off = GridSnap.strokeOffset(penWidth: Int(state.pen.width), viewport: viewport)
      if off != 0 { context.translateBy(x: CGFloat(off), y: CGFloat(off)) }
    }
    if state.transform != 0 {
      context.concatenate(batchTransform)
    }

    switch state.style {
    case .stroke:
      context.setStrokeColor(state.rgba.cgColor)
      context.setLineWidth(
        CGFloat(GridSnap.lineWidth(penWidth: Int(state.pen.width), viewport: viewport)))
      context.setLineCap(state.pen.cap.cgCap)
      context.setLineJoin(state.pen.join.cgJoin)
      if state.pen.isDashed {
        context.setLineDash(
          phase: CGFloat(state.pen.dashPhase),
          lengths: [CGFloat(state.pen.dashOn),
                    CGFloat(state.pen.dashOff == 0 ? state.pen.dashOn : state.pen.dashOff)])
      } else {
        context.setLineDash(phase: 0, lengths: [])
      }
      context.addPath(path)
      context.strokePath()

    case .fill:
      context.setFillColor(state.rgba.cgColor)
      context.addPath(path)
      if state.fillRule == .evenOdd {
        context.fillPath(using: .evenOdd)
      } else {
        context.fillPath(using: .winding)
      }
    }

    context.restoreGState()
    stats.drawCalls += 1
  }

  // MARK: - Geometry

  /// Appends one primitive to the batch path, in **scene** coordinates. The batch's own
  /// transform is applied once, as a CTM, at flush time, never here.
  private func append(_ prim: ScenePrimitive, scene: RenderScene, to path: CGMutablePath) {
    let x = Double(prim.a), y = Double(prim.b), c = Double(prim.c), d = Double(prim.d)

    switch prim.kind {
    case .line:
      path.move(to: CGPoint(x: x, y: y))
      path.addLine(to: CGPoint(x: c, y: d))

    case .polyline, .polygon:
      let range = prim.pointRange
      guard range.lowerBound >= 0, range.upperBound <= scene.points.count, !range.isEmpty else {
        return
      }
      var pts: [CGPoint] = []
      pts.reserveCapacity(range.count)
      for i in range {
        let p = scene.points[i]
        pts.append(CGPoint(x: Double(p.x), y: Double(p.y)))
      }
      if pts.count == 1 {
        // Java draws a degenerate polyline as a dot under CAP_SQUARE; a zero-length subpath
        // with a square cap does the same in CG.
        path.move(to: pts[0])
        path.addLine(to: pts[0])
      } else {
        path.addLines(between: pts)
      }
      if prim.kind == .polygon { path.closeSubpath() }

    case .rect:
      path.addRect(CGRect(x: x, y: y, width: c, height: d))

    case .roundRect:
      // Java's arcWidth/arcHeight are the full width/height of the corner arc; CG wants radii.
      let rw = min(Double(prim.e) / 2, abs(c) / 2)
      let rh = min(Double(prim.f) / 2, abs(d) / 2)
      let rect = CGRect(x: x, y: y, width: c, height: d)
      if rw <= 0 || rh <= 0 {
        path.addRect(rect)
      } else {
        path.addRoundedRect(in: rect, cornerWidth: CGFloat(rw), cornerHeight: CGFloat(rh))
      }

    case .oval:
      path.addEllipse(in: CGRect(x: x, y: y, width: c, height: d))

    case .arc:
      appendArc(prim, to: path, pie: prim.style == .fill)

    case .path:
      appendFreeform(prim, scene: scene, to: path)

    case .text, .image:
      break
    }
  }

  /// `Graphics.drawArc` / `fillArc`.
  ///
  /// Java's angles are degrees, zero at 3 o'clock, **counter-clockwise**, and are measured on
  /// the circle before the bounding box stretches it into an ellipse (`Arc2D`'s "skewed"
  /// convention). Reproducing that means building the arc on a unit circle and letting an
  /// affine transform do the stretching; computing `atan2` on the ellipse instead puts every
  /// non-square arc at the wrong angle. Scene space is y-down, so Java's +theta becomes -theta.
  private func appendArc(_ prim: ScenePrimitive, to path: CGMutablePath, pie: Bool) {
    let w = Double(prim.c), h = Double(prim.d)
    guard w != 0, h != 0 else { return }
    let cx = Double(prim.a) + w / 2
    let cy = Double(prim.b) + h / 2
    let rx = w / 2, ry = h / 2

    let start = -Double(prim.e) * .pi / 180
    let delta = -Double(prim.f) * .pi / 180

    let unitToEllipse = CGAffineTransform(
      a: CGFloat(rx), b: 0, c: 0, d: CGFloat(ry), tx: CGFloat(cx), ty: CGFloat(cy))

    let startPoint = CGPoint(x: cx + rx * cos(start), y: cy + ry * sin(start))

    if pie {
      path.move(to: CGPoint(x: cx, y: cy))
      path.addLine(to: startPoint)
    } else {
      // Without this, CG connects the previous batched subpath to the arc with a stray line.
      path.move(to: startPoint)
    }
    path.addRelativeArc(
      center: .zero, radius: 1, startAngle: CGFloat(start), delta: CGFloat(delta),
      transform: unitToEllipse)
    if pie { path.closeSubpath() }
  }

  private func appendFreeform(_ prim: ScenePrimitive, scene: RenderScene, to path: CGMutablePath) {
    let range = prim.pointRange
    guard range.lowerBound >= 0, range.upperBound <= scene.pathOps.count else { return }
    for i in range {
      switch scene.pathOps[i] {
      case .move(let px, let py):
        path.move(to: CGPoint(x: Double(px), y: Double(py)))
      case .line(let px, let py):
        if path.isEmpty { path.move(to: CGPoint(x: Double(px), y: Double(py))) }
        else { path.addLine(to: CGPoint(x: Double(px), y: Double(py))) }
      case .quad(let qx, let qy, let px, let py):
        if path.isEmpty { path.move(to: CGPoint(x: Double(qx), y: Double(qy))) }
        path.addQuadCurve(
          to: CGPoint(x: Double(px), y: Double(py)),
          control: CGPoint(x: Double(qx), y: Double(qy)))
      case .cubic(let c1x, let c1y, let c2x, let c2y, let px, let py):
        if path.isEmpty { path.move(to: CGPoint(x: Double(c1x), y: Double(c1y))) }
        path.addCurve(
          to: CGPoint(x: Double(px), y: Double(py)),
          control1: CGPoint(x: Double(c1x), y: Double(c1y)),
          control2: CGPoint(x: Double(c2x), y: Double(c2y)))
      case .close:
        path.closeSubpath()
      }
    }
  }

  // MARK: - Text

  private func drawText(
    _ prim: ScenePrimitive, scene: RenderScene, context: CGContext, rgba: RGBA,
    options: RenderOptions, stats: inout RenderStats
  ) {
    guard let run = scene.textRun(prim), !run.string.isEmpty else { return }

    context.saveGState()
    if prim.transform != 0 {
      context.concatenate(scene.transform(prim).cgAffineTransform)
    }

    // `drawText(..., fg, bg)` fills the resolved box first; the box came from the builder, so
    // no measurement happens here.
    if let bgSlot = run.background {
      context.setFillColor(scene.color(of: bgSlot, theme: options.theme).cgColor)
      context.fill(
        CGRect(
          x: Double(run.boxX), y: Double(run.boxY),
          width: Double(run.boxWidth), height: Double(run.boxHeight)))
      stats.drawCalls += 1
    }

    let (line, _) = textCache.line(for: run.string, font: run.font)
    context.setFillColor(rgba.cgColor)
    context.textPosition = CGPoint(x: Double(run.baselineX), y: Double(run.baselineY))
    CTLineDraw(line, context)

    context.restoreGState()
    stats.drawCalls += 1
    stats.textRunsDrawn += 1
  }

  // MARK: - Images

  private func drawImage(
    _ prim: ScenePrimitive, scene: RenderScene, context: CGContext, stats: inout RenderStats
  ) {
    guard let ref = scene.imageRef(prim), let image = imageProvider?.image(for: ref) else {
      return
    }
    let rect = CGRect(
      x: Double(prim.a), y: Double(prim.b), width: Double(prim.c), height: Double(prim.d))

    context.saveGState()
    if prim.transform != 0 {
      context.concatenate(scene.transform(prim).cgAffineTransform)
    }
    // Scene space is y-down; CG draws images bottom-up, so flip about the destination rect.
    context.translateBy(x: rect.minX, y: rect.maxY)
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
    context.restoreGState()
    stats.drawCalls += 1
  }
}

// MARK: - Bridging

extension RGBA {
  /// sRGB, non-premultiplied; matching how `java.awt.Color` components are defined.
  public var cgColor: CGColor {
    CGColor(
      srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255,
      alpha: CGFloat(a) / 255)
  }
}

extension SceneTransform {
  public var cgAffineTransform: CGAffineTransform {
    CGAffineTransform(
      a: CGFloat(a), b: CGFloat(b), c: CGFloat(c), d: CGFloat(d),
      tx: CGFloat(tx), ty: CGFloat(ty))
  }
}

extension ScenePath {
  /// The path as a `CGPath`, in scene coordinates.
  ///
  /// A *geometry* conversion, not a drawing one: nothing here touches a context, so component
  /// code may use it without breaching D6.
  public var cgPath: CGPath {
    let path = CGMutablePath()
    for op in ops {
      switch op {
      case .move(let x, let y):
        path.move(to: CGPoint(x: Double(x), y: Double(y)))
      case .line(let x, let y):
        if path.isEmpty { path.move(to: CGPoint(x: Double(x), y: Double(y))) }
        else { path.addLine(to: CGPoint(x: Double(x), y: Double(y))) }
      case .quad(let cx, let cy, let x, let y):
        if path.isEmpty { path.move(to: CGPoint(x: Double(cx), y: Double(cy))) }
        path.addQuadCurve(
          to: CGPoint(x: Double(x), y: Double(y)),
          control: CGPoint(x: Double(cx), y: Double(cy)))
      case .cubic(let c1x, let c1y, let c2x, let c2y, let x, let y):
        if path.isEmpty { path.move(to: CGPoint(x: Double(c1x), y: Double(c1y))) }
        path.addCurve(
          to: CGPoint(x: Double(x), y: Double(y)),
          control1: CGPoint(x: Double(c1x), y: Double(c1y)),
          control2: CGPoint(x: Double(c2x), y: Double(c2y)))
      case .close:
        path.closeSubpath()
      }
    }
    return path
  }

  /// `java.awt.geom.GeneralPath.contains(Point2D)`, non-zero winding.
  ///
  /// Not decoration: `PainterShaped.getInputLineLengths` walks a point rightwards one unit at a
  /// time while `path.contains(p)` holds, and that loop is what decides how long every shaped
  /// OR/XOR gate's input stubs are. Without a point-in-path query on this side, all the draw
  /// ports would need one from somewhere else.
  public func contains(x: Double, y: Double) -> Bool {
    cgPath.contains(CGPoint(x: x, y: y), using: .winding)
  }
}

extension StrokePen.Cap {
  /// `BasicStroke.CAP_SQUARE` is Java's default and is *not* CoreGraphics' default (`.butt`).
  /// Getting this wrong shortens every stroked line by half a pen width at each end.
  public var cgCap: CGLineCap {
    switch self {
    case .square: return .square
    case .butt: return .butt
    case .round: return .round
    }
  }
}

extension StrokePen.Join {
  public var cgJoin: CGLineJoin {
    switch self {
    case .miter: return .miter
    case .bevel: return .bevel
    case .round: return .round
    }
  }
}
