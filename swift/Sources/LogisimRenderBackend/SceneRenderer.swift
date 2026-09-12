// LogisimRender: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// The backend seam.
//
// `RenderScene` is produced by component code that has no idea a backend exists. This file is
// the other half of that contract: everything a *renderer* needs and nothing a component may
// see. `CoreGraphicsSceneRenderer` implements it today; at M9 a Metal renderer implements the
// same three-line protocol and no `paintInstance` changes.
//
// The viewport is part of the seam rather than of the backend because culling is: the scene
// answers "what is visible in this rect" (D6), and it has to be given the rect in scene units,
// not in pixels.

import CoreGraphics
import LogisimKernel
import LogisimRender

// MARK: - RenderViewport

/// The mapping from scene coordinates to the destination context, plus the rect being painted.
///
/// Scene space is y-down (schematic convention, and Java2D's). The renderer establishes that
/// orientation itself, so a caller only has to say whether the context it is handing over is
/// already flipped; an `NSView` with `isFlipped == true` is, a fresh `CGBitmapContext` is not.
public struct RenderViewport: Hashable, Sendable {

  /// Destination rect, in the context's *current* user space. Everything is clipped to it.
  public var rect: CGRect

  /// Destination units per scene unit. Logisim calls this the zoom.
  ///
  /// On macOS a destination unit is a **point**, not a device pixel, see `backingScale`.
  public var scale: Double

  /// Device pixels per destination unit: `NSWindow.backingScaleFactor`, `2` on every Retina
  /// display. Part of the viewport rather than of `RenderOptions` because it belongs to the
  /// scene -> device *mapping*, exactly like `scale` and `rect` do, and because it varies per
  /// destination while a `RenderOptions` value is shared across destinations.
  ///
  /// Defaults to `1`, which is right for an offscreen `CGBitmapContext` or a PDF page, where
  /// one destination unit really is one pixel, and keeps every existing caller unchanged. The
  /// shell must push the real value; without it the odd/even pen-parity test in `GridSnap` runs
  /// on points instead of pixels and nudges geometry that should not move.
  public var backingScale: Double

  /// The scene point drawn at the visual top-left corner of `rect`.
  public var sceneOriginX: Double
  public var sceneOriginY: Double

  /// `true` when the destination context's y axis already increases downward.
  public var yAxisPointsDown: Bool

  public init(
    rect: CGRect,
    scale: Double = 1,
    sceneOriginX: Double = 0,
    sceneOriginY: Double = 0,
    yAxisPointsDown: Bool = false,
    backingScale: Double = 1
  ) {
    self.rect = rect
    self.scale = scale.isFinite && scale > 0 ? scale : 1
    self.backingScale = backingScale.isFinite && backingScale > 0 ? backingScale : 1
    self.sceneOriginX = sceneOriginX
    self.sceneOriginY = sceneOriginY
    self.yAxisPointsDown = yAxisPointsDown
  }

  /// Scene units -> device pixels. Every pixel-grid decision is made on this, never on `scale`.
  public var deviceScale: Double { scale * backingScale }

  /// The scene-space rect covered by `rect`. This is the culling query.
  ///
  /// Rounded outward by one unit: primitive bounds are already stroke-inflated by the builder,
  /// so a unit of slack is enough, and being generous here can only cost an extra draw, never
  /// drop one.
  public var visibleSceneBounds: SceneBounds {
    let w = Double(rect.width) / scale
    let h = Double(rect.height) / scale
    return SceneBounds(
      minX: clampToInt32((sceneOriginX - 1).rounded(.down)),
      minY: clampToInt32((sceneOriginY - 1).rounded(.down)),
      maxX: clampToInt32((sceneOriginX + w + 1).rounded(.up)),
      maxY: clampToInt32((sceneOriginY + h + 1).rounded(.up)))
  }

  /// Scene point -> destination point, for hit testing and scrollbar arithmetic.
  public func destinationPoint(sceneX: Double, sceneY: Double) -> CGPoint {
    let dx = Double(rect.minX) + (sceneX - sceneOriginX) * scale
    let dyFromTop = (sceneY - sceneOriginY) * scale
    let dy = yAxisPointsDown ? Double(rect.minY) + dyFromTop : Double(rect.maxY) - dyFromTop
    return CGPoint(x: dx, y: dy)
  }

  /// Destination point -> scene point.
  public func scenePoint(destination p: CGPoint) -> (x: Double, y: Double) {
    let sx = sceneOriginX + (Double(p.x) - Double(rect.minX)) / scale
    let fromTop = yAxisPointsDown
      ? Double(p.y) - Double(rect.minY)
      : Double(rect.maxY) - Double(p.y)
    return (sx, sceneOriginY + fromTop / scale)
  }

  /// Nudges the origin so that scene integer coordinates land on **device pixel** boundaries.
  /// Without this, a fractional scroll offset defeats the half-pixel stroke snapping and the
  /// whole schematic goes soft.
  ///
  /// Rounds on `deviceScale`, not on `scale`: at 2x a half-point scroll offset is a whole
  /// device pixel and must be left alone, and conversely an origin that is integral in points
  /// can still be half a pixel out once a fractional zoom is applied.
  public func alignedToPixelGrid() -> RenderViewport {
    var v = self
    let d = deviceScale
    guard d > 0, d.isFinite else { return v }
    v.sceneOriginX = (sceneOriginX * d).rounded() / d
    v.sceneOriginY = (sceneOriginY * d).rounded() / d
    return v
  }

  /// A viewport that fits `bounds` inside `rect` with a margin, never magnifying past
  /// `maxScale`. Used by thumbnails, print, and "zoom to fit".
  public static func fitting(
    _ bounds: SceneBounds,
    in rect: CGRect,
    margin: Double = 0,
    maxScale: Double = .greatestFiniteMagnitude,
    yAxisPointsDown: Bool = false,
    backingScale: Double = 1
  ) -> RenderViewport {
    guard !bounds.isEmpty, rect.width > 0, rect.height > 0 else {
      return RenderViewport(
        rect: rect, yAxisPointsDown: yAxisPointsDown, backingScale: backingScale)
    }
    let availW = max(1.0, Double(rect.width) - 2 * margin)
    let availH = max(1.0, Double(rect.height) - 2 * margin)
    let w = max(1.0, Double(bounds.width))
    let h = max(1.0, Double(bounds.height))
    let s = min(maxScale, min(availW / w, availH / h))
    // Centre the content.
    let ox = Double(bounds.minX) - (Double(rect.width) / s - w) / 2
    let oy = Double(bounds.minY) - (Double(rect.height) / s - h) / 2
    return RenderViewport(
      rect: rect, scale: s, sceneOriginX: ox, sceneOriginY: oy,
      yAxisPointsDown: yAxisPointsDown, backingScale: backingScale)
  }
}

// MARK: - RenderOptions

public struct RenderOptions: Sendable {
  /// Maps `ValuePalette` indices to pixels at draw time, so re-theming never rebuilds a scene.
  public var theme: ValueColorTheme
  /// Geometry antialiasing. Upstream's schematic canvas leaves it *off* (`logisim/gui/main/
  /// Canvas.java` sets no rendering hint); on a Retina display leaving it on looks better and
  /// costs nothing, and the stroke snapping below keeps axis-aligned geometry crisp either way.
  public var antialias: Bool
  public var textAntialias: Bool
  /// Reproduce Java2D's `VALUE_STROKE_NORMALIZE`: nudge odd-width strokes by half a device
  /// pixel so a 1-unit pen lands *on* a pixel row instead of straddling two. Turning this off
  /// makes every wire in every file render one blurry pixel wide.
  ///
  /// Whether a pen is "odd" is decided in device pixels, on `RenderViewport.deviceScale`,
  /// which is why the backing-store factor lives on the viewport and not here. This flag is
  /// only the on/off switch; the geometry it controls is entirely the viewport's business.
  public var snapStrokesToPixelGrid: Bool
  /// Fold runs of same-state primitives into one `CGPath`. Correctness-neutral; see
  /// `CoreGraphicsSceneRenderer` for why fills are only batched under the non-zero rule.
  public var batchPrimitives: Bool
  /// Background fill for the destination rect. `nil` draws over whatever is there.
  public var background: RGBA?

  public init(
    theme: ValueColorTheme = .logisim,
    antialias: Bool = true,
    textAntialias: Bool = true,
    snapStrokesToPixelGrid: Bool = true,
    batchPrimitives: Bool = true,
    background: RGBA? = nil
  ) {
    self.theme = theme
    self.antialias = antialias
    self.textAntialias = textAntialias
    self.snapStrokesToPixelGrid = snapStrokesToPixelGrid
    self.batchPrimitives = batchPrimitives
    self.background = background
  }

  public static let `default` = RenderOptions()
}

// MARK: - RenderStats

/// What a frame cost. Not decoration: the culling claim in D6 is only worth anything if it is
/// measured, and `primitivesCulled` is the number that says whether it happened.
public struct RenderStats: Hashable, Sendable {
  public var groupsConsidered: Int = 0
  public var groupsDrawn: Int = 0
  public var primitivesDrawn: Int = 0
  public var primitivesCulled: Int = 0
  /// Distinct `CGContext` draw calls issued. Batching is visible here.
  public var drawCalls: Int = 0
  public var textRunsDrawn: Int = 0
  public var textCacheHits: Int = 0
  public var textCacheMisses: Int = 0

  public init() {}
}

// MARK: - SceneImageProvider

/// Resolves an opaque `SceneImageRef` to a bitmap.
///
/// The scene never holds a `CGImage`, which is what keeps `RenderScene` `Sendable` and lets
/// the Metal backend swap in a texture atlas behind the same handle.
public protocol SceneImageProvider: AnyObject {
  func image(for ref: SceneImageRef) -> CGImage?
}

// MARK: - SceneRenderer

/// The entire backend contract. `CoreGraphicsSceneRenderer` implements it now; a Metal renderer
/// implements it at M9 with the scene, the viewport, and the palette unchanged.
public protocol SceneRenderer: AnyObject {
  associatedtype Destination
  @discardableResult
  func render(
    _ scene: RenderScene, into destination: Destination, viewport: RenderViewport,
    options: RenderOptions
  ) -> RenderStats
}
