// BackingScaleTests: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// The third coordinate space: device pixels.
//
//   scene units --( viewport.scale )--> points --( viewport.backingScale )--> device pixels
//
// `GridSnap`'s odd/even pen parity is a claim about *device pixels*. Deciding it on
// `viewport.scale` alone is right only when one point is one pixel, which is true for an
// offscreen bitmap and false for every Retina display, i.e. false on every machine this port
// targets. On a 2x backing store a 1-unit pen at zoom 1 is two device pixels wide, straddles
// nothing, and must not be nudged; the parity test on `1 * 1 = 1` called it odd and shifted the
// whole batch by a full device pixel.
//
// That failure mode is invisible to a crispness test; the line is still exactly two pixels
// and still hard-edged, just one pixel south-east of the reference. So these tests assert
// *which* device rows are covered, not merely how many.
//
// `GridSnapTests` already covers the rule at `backingScale == 1`; everything here is about the
// join between the two scales, and every pixel assertion is made on a real 2x backing store.

import CoreGraphics
import Testing

@testable import LogisimRender
@testable import LogisimRenderBackend

// MARK: - Harness

/// Rasterises into a context set up exactly the way AppKit hands one to `-drawRect:` on a
/// Retina display: the backing store is `points * backingScale` pixels and the CTM is
/// pre-scaled so user space is in points.
private func renderRetina(
  _ build: (SceneBuilder) -> Void,
  points: Int = 64,
  backingScale: Int = 2,
  scale: Double = 1,
  options: RenderOptions = RenderOptions(background: .white)
) -> SceneBitmap {
  let b = SceneBuilder(measurer: NominalTextMeasurer())
  build(b)
  let scene = b.finish()

  let devicePixels = points * backingScale
  let context = SceneRasterizer.makeContext(width: devicePixels, height: devicePixels)!
  context.scaleBy(x: CGFloat(backingScale), y: CGFloat(backingScale))

  let viewport = RenderViewport(
    rect: CGRect(x: 0, y: 0, width: points, height: points),
    scale: scale, sceneOriginX: 0, sceneOriginY: 0, yAxisPointsDown: false,
    backingScale: Double(backingScale))

  CoreGraphicsSceneRenderer().render(scene, into: context, viewport: viewport, options: options)

  let raw = UnsafeRawBufferPointer(
    start: context.data!, count: context.bytesPerRow * devicePixels)
  return SceneBitmap(
    width: devicePixels, height: devicePixels, bytesPerRow: context.bytesPerRow,
    pixels: Array(raw))
}

/// The same picture drawn with no backing store at all, at a zoom chosen so that one scene unit
/// covers the same number of *device* pixels. Geometrically these two must be indistinguishable.
private func renderFlat(
  _ build: (SceneBuilder) -> Void,
  pixels: Int,
  scale: Double,
  options: RenderOptions = RenderOptions(background: .white)
) -> SceneBitmap {
  let b = SceneBuilder(measurer: NominalTextMeasurer())
  build(b)
  let scene = b.finish()
  let viewport = RenderViewport(
    rect: CGRect(x: 0, y: 0, width: pixels, height: pixels),
    scale: scale, sceneOriginX: 0, sceneOriginY: 0, yAxisPointsDown: false,
    backingScale: 1)
  return SceneRasterizer.render(
    scene, width: pixels, height: pixels, viewport: viewport, options: options)!.bitmap
}

// MARK: - The parity decision

@Test func theOddEvenTestRunsOnDevicePixelsNotOnPoints() {
  // The executed repro. A 1-unit pen at zoom 1 on a 2x display is TWO device pixels; it
  // straddles nothing and must not move. Deciding on `penWidth * scale` calls it odd and
  // returns 0.5 points: a full device pixel of unwanted translation.
  #expect(GridSnap.strokeOffset(penWidth: 1, scale: 1, backingScale: 2) == 0)
  #expect(GridSnap.strokeOffset(penWidth: 1, scale: 1, backingScale: 1) == 0.5)

  // Every combination is decided on the product, never on either factor alone.
  #expect(GridSnap.deviceWidth(penWidth: 1, scale: 1, backingScale: 2) == 2)
  #expect(GridSnap.deviceWidth(penWidth: 3, scale: 1, backingScale: 2) == 6)
  #expect(GridSnap.strokeOffset(penWidth: 3, scale: 1, backingScale: 2) == 0)  // 6 px: even
  #expect(GridSnap.strokeOffset(penWidth: 1, scale: 2, backingScale: 2) == 0)  // 4 px: even
  #expect(GridSnap.strokeOffset(penWidth: 2, scale: 1, backingScale: 2) == 0)  // 4 px: even

  // ... and it does still fire at 2x when the device width really is odd.
  #expect(GridSnap.strokeOffset(penWidth: 1, scale: 1.5, backingScale: 2) == 0.5 / 3)  // 3 px
  #expect(GridSnap.strokeOffset(penWidth: 1, scale: 0.5, backingScale: 2) == 0.5)  // 1 px
  #expect(GridSnap.strokeOffset(penWidth: 3, scale: 0.5, backingScale: 2) == 0.5 / 1)  // 3 px
}

@Test func onlyTheProductOfTheTwoScalesMatters() {
  // A 2x backing store at zoom 1 and a 1x backing store at zoom 2 put a scene unit on the same
  // number of device pixels, so no grid decision may distinguish them.
  for pen in 0...5 {
    for (s, b) in [(1.0, 2.0), (2.0, 1.0), (0.5, 4.0), (4.0, 0.5)] {
      #expect(
        GridSnap.strokeOffset(penWidth: pen, scale: s, backingScale: b)
          * GridSnap.deviceScale(scale: s, backingScale: b)
          == GridSnap.strokeOffset(penWidth: pen, scale: 2, backingScale: 1) * 2.0)
    }
  }
}

@Test func theNudgeIsHalfADevicePixelNotHalfAPoint() {
  // Whenever an offset is returned it must measure exactly half a device pixel once carried
  // through both scales. `0.5 / scale` is half a *point*, which is a whole pixel at 2x.
  for (s, b) in [(1.0, 1.0), (1.0, 2.0), (3.0, 2.0), (0.5, 2.0), (1.5, 2.0), (2.0, 3.0)] {
    for pen in 0...4 {
      let off = GridSnap.strokeOffset(penWidth: pen, scale: s, backingScale: b)
      guard off != 0 else { continue }
      let inDevicePixels = off * GridSnap.deviceScale(scale: s, backingScale: b)
      #expect(abs(inDevicePixels - 0.5) < 1e-12)
    }
  }
}

@Test func aHairlineIsOneDevicePixelAtEveryZoomAndEveryBackingScale() {
  // Java's BasicStroke(0) is "the thinnest line the device can render". That is one *device*
  // pixel, so it scales with neither the CTM nor the backing store, and its parity is
  // therefore always odd, at every zoom.
  #expect(GridSnap.deviceWidth(penWidth: 0, scale: 1, backingScale: 1) == 1)
  #expect(GridSnap.deviceWidth(penWidth: 0, scale: 7, backingScale: 2) == 1)

  #expect(GridSnap.lineWidth(penWidth: 0, scale: 4, backingScale: 1) == 0.25)
  #expect(GridSnap.lineWidth(penWidth: 0, scale: 1, backingScale: 2) == 0.5)
  #expect(GridSnap.lineWidth(penWidth: 0, scale: 4, backingScale: 2) == 0.125)

  // The hairline's own parity, which `penWidth * scale` also got wrong at 1x for any zoom != 1:
  // it computed a device width of `scale` and called a hairline at zoom 2 "even".
  #expect(GridSnap.strokeOffset(penWidth: 0, scale: 2, backingScale: 1) == 0.25)
  #expect(GridSnap.strokeOffset(penWidth: 0, scale: 1, backingScale: 2) == 0.25)
  #expect(GridSnap.strokeOffset(penWidth: 0, scale: 3, backingScale: 2) == 0.5 / 6)
}

// MARK: - The value actually reaches the backend

@Test func theViewportCarriesBackingScaleAndDefaultsToOne() {
  // Default 1 keeps every existing caller, offscreen bitmaps, PDF pages, the export path,
  // behaving exactly as before.
  #expect(RenderViewport(rect: CGRect(x: 0, y: 0, width: 10, height: 10)).backingScale == 1)
  #expect(RenderViewport.fitting(SceneBounds(minX: 0, minY: 0, maxX: 10, maxY: 10),
                                 in: CGRect(x: 0, y: 0, width: 10, height: 10)).backingScale == 1)

  let vp = RenderViewport(
    rect: CGRect(x: 0, y: 0, width: 10, height: 10), scale: 3, backingScale: 2)
  #expect(vp.deviceScale == 6)
  // Nonsense is clamped rather than propagated into a divide.
  #expect(RenderViewport(rect: .zero, backingScale: 0).backingScale == 1)
  #expect(RenderViewport(rect: .zero, backingScale: -2).backingScale == 1)
  #expect(RenderViewport(rect: .zero, backingScale: .nan).backingScale == 1)

  // `fitting` must carry it through, or "zoom to fit" silently reverts to 1x snapping.
  let fitted = RenderViewport.fitting(
    SceneBounds(minX: 0, minY: 0, maxX: 100, maxY: 100),
    in: CGRect(x: 0, y: 0, width: 200, height: 200), backingScale: 2)
  #expect(fitted.backingScale == 2)
  #expect(fitted.alignedToPixelGrid().backingScale == 2)
}

@Test func aOneUnitLineOnATwoXBackingStoreLandsOnTheReferenceDeviceRows() {
  // Scene y = 10 maps to the boundary between device rows 19 and 20. A 1-unit pen is two
  // device pixels, so it covers exactly rows 19 and 20: with NO nudge.
  //
  // Before the fix the batch was translated by 0.5 scene units = a whole device pixel, and the
  // line covered rows 20 and 21 instead: still two rows, still crisp, and one pixel wrong.
  let bmp = renderRetina { b in
    b.color = .black
    b.strokeWidth = 1
    b.drawLine(4, 10, 60, 10)
  }
  #expect(bmp.width == 128 && bmp.height == 128)
  #expect(bmp.luminance(x: 60, y: 19) == 0)
  #expect(bmp.luminance(x: 60, y: 20) == 0)
  #expect(bmp.luminance(x: 60, y: 18) == 255)
  #expect(bmp.luminance(x: 60, y: 21) == 255)
  #expect(bmp.darkPixelsInColumn(60, y0: 0, y1: 127) == 2)
}

@Test func aTwoXBackingStoreAndATwoXZoomProduceIdenticalPixels() {
  // The invariant that pins the whole plumbing job: device output depends only on
  // `scale * backingScale`, never on how that product is split between the two. Any call site
  // that still reasons in points instead of pixels breaks this.
  func picture(_ b: SceneBuilder) {
    b.color = .black
    b.strokeWidth = 1
    b.drawLine(4, 10, 60, 10)
    b.drawLine(20, 4, 20, 60)
    b.drawRect(30, 30, 20, 12)
    b.strokeWidth = 2
    b.drawLine(4, 50, 60, 50)
    b.strokeWidth = 3
    b.drawLine(4, 56, 60, 56)
    b.strokeWidth = 0
    b.drawLine(4, 24, 60, 24)
    b.strokeWidth = 1
    b.fillRect(2, 40, 10, 6)
  }
  let retina = renderRetina(picture, points: 64, backingScale: 2, scale: 1)
  let flat = renderFlat(picture, pixels: 128, scale: 2)
  #expect(retina.pixels == flat.pixels)
}

@Test func integerGridGeometryIsReproducedExactlyOnATwoXBackingStore() {
  // Every claim GridSnapTests makes at 1x, restated in device pixels at 2x. The point is that
  // plumbing a second scale through must not move a single edge.
  let outline = renderRetina { b in
    b.color = .black
    b.strokeWidth = 1
    b.drawRect(10, 10, 20, 12)
  }
  // drawRect's border runs through x and x+width (Java's inclusive box). At 2x each edge is a
  // 2-device-pixel pen centred on the boundary at device x = 20 and x = 60.
  #expect(outline.luminance(x: 19, y: 32) == 0)
  #expect(outline.luminance(x: 20, y: 32) == 0)
  #expect(outline.luminance(x: 59, y: 32) == 0)
  #expect(outline.luminance(x: 60, y: 32) == 0)
  #expect(outline.luminance(x: 40, y: 32) == 255)  // hollow
  #expect(outline.darkPixelsInRow(32, x0: 0, x1: 127) == 4)

  let filled = renderRetina { b in
    b.color = .black
    b.fillRect(10, 10, 8, 4)
  }
  // A fill is never snapped: 8 x 4 scene units = 16 x 8 device pixels from device (20, 20).
  #expect(filled.luminance(x: 20, y: 20) == 0)
  #expect(filled.luminance(x: 35, y: 27) == 0)
  #expect(filled.luminance(x: 36, y: 27) == 255)  // x + width is exclusive
  #expect(filled.luminance(x: 35, y: 28) == 255)  // y + height is exclusive
  #expect(filled.luminance(x: 19, y: 20) == 255)
  #expect(filled.darkPixelsInRow(24, x0: 0, x1: 127) == 16)
}

@Test func anOddDeviceWidthStillSnapsOnATwoXBackingStore() {
  // Backing scale must not disable snapping, only re-base it. At zoom 0.5 on a 2x display a
  // 1-unit pen is one device pixel, which straddles a boundary and does need the nudge.
  let bmp = renderRetina(
    { b in
      b.color = .black
      b.strokeWidth = 1
      b.drawLine(8, 20, 100, 20)
    }, points: 64, backingScale: 2, scale: 0.5)
  // scene y = 20 -> device row boundary 20; the half-pixel nudge centres the 1px pen on row 20.
  #expect(bmp.luminance(x: 40, y: 20) == 0)
  #expect(bmp.luminance(x: 40, y: 19) == 255)
  #expect(bmp.luminance(x: 40, y: 21) == 255)
  #expect(bmp.darkPixelsInColumn(40, y0: 0, y1: 127) == 1)
}

@Test func aHairlineRastersToExactlyOneDevicePixelRow() {
  // BasicStroke(0) at zoom 2. Its device width is 1 whatever the zoom, so it is odd and must be
  // snapped; computing the device width as `1 * scale` made it "even" and left the hairline
  // straddling two rows at half coverage.
  let bmp = renderFlat(
    { b in
      b.color = .black
      b.strokeWidth = 0
      b.drawLine(2, 10, 60, 10)
    }, pixels: 128, scale: 2)
  #expect(bmp.luminance(x: 60, y: 20) == 0)
  #expect(bmp.luminance(x: 60, y: 19) == 255)
  #expect(bmp.luminance(x: 60, y: 21) == 255)
  #expect(bmp.darkPixelsInColumn(60, y0: 0, y1: 127) == 1)
}

// MARK: - Viewport alignment

@Test func pixelAlignmentIsJudgedInDevicePixelsNotPoints() {
  // Half a point is a whole device pixel at 2x, so this viewport IS aligned. Judging in points
  // rejects it and `alignedToPixelGrid()` would then round a perfectly good origin away.
  let halfPoint = RenderViewport(
    rect: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 1,
    sceneOriginX: 0.5, sceneOriginY: -1.5, backingScale: 2)
  #expect(GridSnap.isPixelAligned(halfPoint))
  #expect(halfPoint.alignedToPixelGrid().sceneOriginX == 0.5)
  #expect(halfPoint.alignedToPixelGrid().sceneOriginY == -1.5)

  // ... while a genuinely ragged origin is still rejected, and the repair now rounds onto the
  // device grid (round(1.5)/1.5), not onto the point grid (round(0.75)/0.75 = 1.333…).
  let quarter = RenderViewport(
    rect: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 0.75,
    sceneOriginX: 1, sceneOriginY: 1, backingScale: 2)
  #expect(!GridSnap.isPixelAligned(quarter))  // 1 * 0.75 * 2 = 1.5 device px

  let repaired = quarter.alignedToPixelGrid()
  #expect(GridSnap.isPixelAligned(repaired))
  #expect(repaired.backingScale == 2)
  #expect(repaired.sceneOriginX == 2.0 / 1.5)  // round(1.5) / 1.5

  // A fractional destination rect origin is also a pixel question, not a point question.
  let halfPointRect = RenderViewport(
    rect: CGRect(x: 0.5, y: 0.5, width: 100, height: 100), scale: 1, backingScale: 2)
  #expect(GridSnap.isPixelAligned(halfPointRect))
  let thirdPointRect = RenderViewport(
    rect: CGRect(x: 0.25, y: 0, width: 100, height: 100), scale: 1, backingScale: 2)
  #expect(!GridSnap.isPixelAligned(thirdPointRect))
}

@Test func alignmentAtOneXIsUnchanged() {
  // Regression guard on the default path: nothing about the 1x behaviour may drift.
  let ragged = RenderViewport(
    rect: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2, sceneOriginX: 3.3,
    sceneOriginY: -1.7)
  #expect(!GridSnap.isPixelAligned(ragged))
  #expect(GridSnap.isPixelAligned(ragged.alignedToPixelGrid()))
  #expect(ragged.alignedToPixelGrid().sceneOriginX == 3.5)
}
