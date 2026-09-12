// LogisimRender: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// Offscreen rasterisation.
//
// Two jobs. The obvious one is product surface, thumbnails, export-to-image, print, which
// upstream reaches by constructing a `BufferedImage` and reusing the same painters.
//
// The less obvious one is that it makes the backend *testable without a window*. Grid snapping
// is a claim about which physical pixels a line covers, and the only honest way to check it is
// to rasterise and read the pixels back. A test that inspects the scene can tell you the
// geometry is right and still miss the half-pixel error that makes every file render soft.

import CoreGraphics
import Foundation
import LogisimRender

// MARK: - SceneBitmap

/// A rasterised frame plus direct pixel access, with `(0, 0)` at the **top-left**.
///
/// The top-left convention is deliberate. `CGBitmapContext`'s coordinate origin is bottom-left
/// while its backing buffer's first row is the top of the image, and mixing those up produces a
/// vertically mirrored comparison that looks like a rendering bug for an hour.
public struct SceneBitmap: @unchecked Sendable {
  public let width: Int
  public let height: Int
  public let bytesPerRow: Int
  /// RGBA, one byte per channel, alpha premultiplied last.
  public let pixels: [UInt8]

  public init(width: Int, height: Int, bytesPerRow: Int, pixels: [UInt8]) {
    self.width = width
    self.height = height
    self.bytesPerRow = bytesPerRow
    self.pixels = pixels
  }

  /// The pixel at `(x, y)` with the origin at the top-left. Out of range reads return clear.
  public func pixel(x: Int, y: Int) -> RGBA {
    guard x >= 0, y >= 0, x < width, y < height else { return .clear }
    let o = y * bytesPerRow + x * 4
    guard o + 3 < pixels.count else { return .clear }
    return RGBA(r: pixels[o], g: pixels[o + 1], b: pixels[o + 2], a: pixels[o + 3])
  }

  /// Perceptual luminance, 0 (black) to 255 (white), ignoring alpha. Handy for asserting that
  /// a stroke landed on exactly one row rather than smeared across two.
  public func luminance(x: Int, y: Int) -> Int {
    let p = pixel(x: x, y: y)
    let r: Double = 0.299 * Double(p.r)
    let g: Double = 0.587 * Double(p.g)
    let b: Double = 0.114 * Double(p.b)
    return Int((r + g + b).rounded())
  }

  /// Number of pixels in column `x` between `y0` and `y1` darker than `threshold`.
  public func darkPixelsInColumn(_ x: Int, y0: Int, y1: Int, threshold: Int = 128) -> Int {
    var n = 0
    for y in y0...y1 where luminance(x: x, y: y) < threshold { n += 1 }
    return n
  }

  public func darkPixelsInRow(_ y: Int, x0: Int, x1: Int, threshold: Int = 128) -> Int {
    var n = 0
    for x in x0...x1 where luminance(x: x, y: y) < threshold { n += 1 }
    return n
  }
}

// MARK: - SceneRasterizer

public enum SceneRasterizer {

  /// A bitmap context in sRGB with the buffer laid out R, G, B, A in memory order.
  public static func makeContext(width: Int, height: Int) -> CGContext? {
    guard width > 0, height > 0 else { return nil }
    let bytesPerRow = width * 4
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    return CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue)
  }

  /// Renders `scene` into a fresh bitmap and hands back both the pixels and the frame stats.
  ///
  /// The viewport defaults to 1:1 with the scene origin at the top-left of the bitmap, which is
  /// the mapping the snapping tests reason in.
  public static func render(
    _ scene: RenderScene,
    width: Int,
    height: Int,
    viewport: RenderViewport? = nil,
    options: RenderOptions = RenderOptions(background: .white),
    renderer: CoreGraphicsSceneRenderer = CoreGraphicsSceneRenderer()
  ) -> (bitmap: SceneBitmap, stats: RenderStats)? {
    guard let context = makeContext(width: width, height: height) else { return nil }
    let vp =
      viewport
      ?? RenderViewport(
        rect: CGRect(x: 0, y: 0, width: width, height: height),
        scale: 1, sceneOriginX: 0, sceneOriginY: 0, yAxisPointsDown: false)

    let stats = renderer.render(scene, into: context, viewport: vp, options: options)

    guard let base = context.data else { return nil }
    let bytesPerRow = context.bytesPerRow
    let count = bytesPerRow * height
    let buffer = UnsafeRawBufferPointer(start: base, count: count)
    let bitmap = SceneBitmap(
      width: width, height: height, bytesPerRow: bytesPerRow, pixels: Array(buffer))
    return (bitmap, stats)
  }

  /// Renders to a `CGImage`, export, thumbnails, drag previews.
  public static func image(
    _ scene: RenderScene,
    width: Int,
    height: Int,
    viewport: RenderViewport? = nil,
    options: RenderOptions = RenderOptions(background: .white),
    renderer: CoreGraphicsSceneRenderer = CoreGraphicsSceneRenderer()
  ) -> CGImage? {
    guard let context = makeContext(width: width, height: height) else { return nil }
    let vp =
      viewport
      ?? RenderViewport.fitting(
        scene.bounds,
        in: CGRect(x: 0, y: 0, width: width, height: height),
        margin: 4)
    renderer.render(scene, into: context, viewport: vp, options: options)
    return context.makeImage()
  }
}
