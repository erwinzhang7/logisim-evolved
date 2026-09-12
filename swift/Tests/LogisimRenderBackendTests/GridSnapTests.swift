// GridSnapTests: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// The integer-grid contract, checked at the pixel.
//
// Schematic geometry is integer-grid, and Java2D's default KEY_STROKE_CONTROL is
// VALUE_STROKE_NORMALIZE, so a 1-unit pen along y = 10 lands *on* row 10. CoreGraphics has no
// such normalisation: the same stroke covers rows 9 and 10 at half coverage. Every wire, gate
// outline and component box in every file would be soft and half a pixel north.
//
// Inspecting the scene cannot catch that; the scene is right either way. The only honest test
// rasterises and reads the pixels back, which is what these do.

import CoreGraphics
import Testing

@testable import LogisimRender
@testable import LogisimRenderBackend

private func render(
  _ build: (SceneBuilder) -> Void,
  size: Int = 64,
  scale: Double = 1,
  options: RenderOptions = RenderOptions(background: .white)
) -> SceneBitmap {
  let b = SceneBuilder(measurer: NominalTextMeasurer())
  build(b)
  let scene = b.finish()
  let viewport = RenderViewport(
    rect: CGRect(x: 0, y: 0, width: size, height: size),
    scale: scale, sceneOriginX: 0, sceneOriginY: 0, yAxisPointsDown: false)
  let out = SceneRasterizer.render(
    scene, width: size, height: size, viewport: viewport, options: options)
  return out!.bitmap
}

// MARK: - The rule itself

@Test func oddPenWidthsSnapAndEvenOnesDoNot() {
  #expect(GridSnap.strokeOffset(penWidth: 1, scale: 1) == 0.5)
  #expect(GridSnap.strokeOffset(penWidth: 3, scale: 1) == 0.5)
  #expect(GridSnap.strokeOffset(penWidth: 2, scale: 1) == 0)
  #expect(GridSnap.strokeOffset(penWidth: 4, scale: 1) == 0)
  // BasicStroke(0) is a one-device-pixel hairline: odd, therefore snapped.
  #expect(GridSnap.strokeOffset(penWidth: 0, scale: 1) == 0.5)
}

@Test func snappingIsDecidedInDeviceSpaceNotSceneSpace() {
  // A 1-unit pen at zoom 2 is two device pixels wide and already straddles a boundary cleanly;
  // nudging it would be wrong. Deciding on the scene width would nudge it anyway.
  #expect(GridSnap.strokeOffset(penWidth: 1, scale: 2) == 0)
  #expect(GridSnap.strokeOffset(penWidth: 1, scale: 3) == 0.5 / 3)
  #expect(GridSnap.strokeOffset(penWidth: 2, scale: 1.5) == 0.5 / 1.5)  // 3 device px: odd
}

@Test func hairlineWidthDoesNotScaleWithZoom() {
  // Java: BasicStroke(0) is "the thinnest line the device can render", at any zoom.
  #expect(GridSnap.lineWidth(penWidth: 0, scale: 4) == 0.25)
  #expect(GridSnap.lineWidth(penWidth: 2, scale: 4) == 2)
}

// MARK: - Pixels

@Test func aOneUnitHorizontalLineCoversExactlyOneRow() {
  let bmp = render { b in
    b.color = .black
    b.strokeWidth = 1
    b.drawLine(4, 10, 60, 10)
  }
  // Row 10 is solid black; the rows either side are untouched white.
  #expect(bmp.pixel(x: 30, y: 10) == RGBA(javaRGB: 0x00_0000))
  #expect(bmp.luminance(x: 30, y: 9) == 255)
  #expect(bmp.luminance(x: 30, y: 11) == 255)
  #expect(bmp.darkPixelsInColumn(30, y0: 0, y1: 63) == 1)
}

@Test func aOneUnitVerticalLineCoversExactlyOneColumn() {
  let bmp = render { b in
    b.color = .black
    b.strokeWidth = 1
    b.drawLine(20, 4, 20, 60)
  }
  #expect(bmp.pixel(x: 20, y: 30) == RGBA(javaRGB: 0x00_0000))
  #expect(bmp.darkPixelsInRow(30, x0: 0, x1: 63) == 1)
}

@Test func withoutSnappingTheSameLineSmearsAcrossTwoRows() {
  // The failure mode this whole mechanism exists to prevent, made visible.
  let bmp = render(
    { b in
      b.color = .black
      b.strokeWidth = 1
      b.drawLine(4, 10, 60, 10)
    }, options: RenderOptions(snapStrokesToPixelGrid: false, background: .white))

  #expect(bmp.darkPixelsInColumn(30, y0: 0, y1: 63, threshold: 250) == 2)
  #expect(bmp.pixel(x: 30, y: 10) != RGBA(javaRGB: 0x00_0000))
}

@Test func anEvenPenWidthIsCrispWithoutASnap() {
  // A 2-unit pen centred on y = 10 covers rows 9 and 10 exactly. Nudging it would smear it.
  let bmp = render { b in
    b.color = .black
    b.strokeWidth = 2
    b.drawLine(4, 10, 60, 10)
  }
  #expect(bmp.luminance(x: 30, y: 9) == 0)
  #expect(bmp.luminance(x: 30, y: 10) == 0)
  #expect(bmp.luminance(x: 30, y: 8) == 255)
  #expect(bmp.luminance(x: 30, y: 11) == 255)
  #expect(bmp.darkPixelsInColumn(30, y0: 0, y1: 63) == 2)
}

@Test func aThreeUnitPenIsCentredOnItsCoordinate() {
  // GraphicsUtil.switchToWidth(g, 3) is what the shaped-gate input stubs use.
  let bmp = render { b in
    b.color = .black
    b.strokeWidth = 3
    b.drawLine(4, 20, 60, 20)
  }
  #expect(bmp.luminance(x: 30, y: 19) == 0)
  #expect(bmp.luminance(x: 30, y: 20) == 0)
  #expect(bmp.luminance(x: 30, y: 21) == 0)
  #expect(bmp.darkPixelsInColumn(30, y0: 0, y1: 63) == 3)
}

@Test func fillRectCoversExactlyWidthByHeightPixels() {
  // java.awt fills w x h pixels starting at (x, y); a fill is NOT snapped, and must not be.
  let bmp = render { b in
    b.color = .black
    b.fillRect(10, 10, 8, 4)
  }
  #expect(bmp.luminance(x: 10, y: 10) == 0)
  #expect(bmp.luminance(x: 17, y: 13) == 0)
  #expect(bmp.luminance(x: 18, y: 13) == 255)  // x + width is exclusive
  #expect(bmp.luminance(x: 17, y: 14) == 255)  // y + height is exclusive
  #expect(bmp.luminance(x: 9, y: 10) == 255)
  #expect(bmp.darkPixelsInRow(12, x0: 0, x1: 63) == 8)
}

@Test func drawRectOutlinesTheInclusiveBoxJavaDoes() {
  // Java's drawRect(x, y, w, h) paints the border through x and x+w: one pixel wider than the
  // fill of the same arguments. Getting this wrong shrinks every component body by a pixel.
  let bmp = render { b in
    b.color = .black
    b.strokeWidth = 1
    b.drawRect(10, 10, 20, 12)
  }
  #expect(bmp.luminance(x: 10, y: 16) == 0)  // left edge
  #expect(bmp.luminance(x: 30, y: 16) == 0)  // right edge at x + width
  #expect(bmp.luminance(x: 20, y: 10) == 0)  // top edge
  #expect(bmp.luminance(x: 20, y: 22) == 0)  // bottom edge at y + height
  #expect(bmp.luminance(x: 20, y: 16) == 255)  // hollow
  #expect(bmp.darkPixelsInRow(16, x0: 0, x1: 63) == 2)
}

@Test func snappingSurvivesZoomWhenTheViewportIsPixelAligned() {
  let bmp = render(
    { b in
      b.color = .black
      b.strokeWidth = 1
      b.drawLine(2, 5, 30, 5)
    }, size: 64, scale: 3)
  // A 1-unit pen at zoom 3 is 3 device pixels: rows 14, 15, 16 around scene y = 5 (device 15).
  #expect(bmp.darkPixelsInColumn(30, y0: 0, y1: 63) == 3)
  #expect(bmp.luminance(x: 30, y: 15) == 0)
}

@Test func viewportAlignmentIsDetectedAndRepairable() {
  let ragged = RenderViewport(
    rect: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2, sceneOriginX: 3.3,
    sceneOriginY: -1.7)
  #expect(!GridSnap.isPixelAligned(ragged))
  #expect(GridSnap.isPixelAligned(ragged.alignedToPixelGrid()))
}

// MARK: - Orientation

@Test func sceneYIncreasesDownward() {
  // Schematic convention, and Java2D's. A backend that inherits CoreGraphics' bottom-left
  // origin renders every file upside down, which is obvious, until a symmetric test hides it.
  let bmp = render { b in
    b.color = .black
    b.fillRect(0, 0, 64, 4)
  }
  #expect(bmp.luminance(x: 32, y: 1) == 0)  // near the TOP of the image
  #expect(bmp.luminance(x: 32, y: 62) == 255)
}

@Test func aFlippedContextProducesTheSamePixels() {
  // The `yAxisPointsDown` branch exists for NSView(isFlipped:). It must agree with the other.
  let b = SceneBuilder(measurer: NominalTextMeasurer())
  b.color = .black
  b.strokeWidth = 1
  b.drawLine(4, 10, 60, 10)
  b.fillRect(2, 40, 10, 6)
  let scene = b.finish()

  func pixels(flipped: Bool) -> [UInt8] {
    let context = SceneRasterizer.makeContext(width: 64, height: 64)!
    if flipped {
      // Pre-apply the flip the way AppKit does for a flipped view, then tell the renderer.
      context.translateBy(x: 0, y: 64)
      context.scaleBy(x: 1, y: -1)
    }
    let vp = RenderViewport(
      rect: CGRect(x: 0, y: 0, width: 64, height: 64), scale: 1,
      sceneOriginX: 0, sceneOriginY: 0, yAxisPointsDown: flipped)
    CoreGraphicsSceneRenderer().render(
      scene, into: context, viewport: vp, options: RenderOptions(background: .white))
    let raw = UnsafeRawBufferPointer(start: context.data!, count: context.bytesPerRow * 64)
    return Array(raw)
  }

  #expect(pixels(flipped: false) == pixels(flipped: true))
}
