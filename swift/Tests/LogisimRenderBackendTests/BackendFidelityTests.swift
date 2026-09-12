// BackendFidelityTests: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// The primitives whose Java semantics are easy to get subtly wrong: arcs (Java's angles are
// counter-clockwise, degrees, and skewed by the bounding box), even-odd polygon fills, the
// shaped-gate `GeneralPath`s, dashes, group alpha, and text.
//
// These rasterise and inspect pixels for the same reason `GridSnapTests` does: the scene would
// look correct in every one of these cases even if the backend drew the arc on the wrong side
// of the circle.

import CoreGraphics
import CoreText
import Testing

@testable import LogisimRender
@testable import LogisimRenderBackend

private func rasterise(
  _ build: (SceneBuilder) -> Void,
  size: Int = 64,
  options: RenderOptions = RenderOptions(background: .white)
) -> SceneBitmap {
  let b = SceneBuilder(measurer: CoreTextMeasurer())
  build(b)
  let scene = b.finish()
  let vp = RenderViewport(rect: CGRect(x: 0, y: 0, width: size, height: size))
  return SceneRasterizer.render(
    scene, width: size, height: size, viewport: vp, options: options)!.bitmap
}

// MARK: - Arcs

@Test func javaArcAnglesAreCounterClockwiseFromThreeOClock() {
  // GraphicsUtil.drawCenteredArc(g, 32, 32, 20, 0, 90) sweeps from 3 o'clock counter-clockwise
  // to 12 o'clock; i.e. the arc lives in the UPPER right quadrant. Screen y is down, so a
  // backend that forgets to negate the angle draws it in the LOWER right instead, and every
  // AND-gate nose in the app points the wrong way.
  let bmp = rasterise { b in
    b.color = .black
    b.strokeWidth = 2
    b.drawCenteredArc(32, 32, 20, 0, 90)
  }
  #expect(bmp.luminance(x: 52, y: 32) == 0)  // 3 o'clock: the start
  #expect(bmp.luminance(x: 32, y: 12) == 0)  // 12 o'clock: the end, ABOVE centre
  #expect(bmp.luminance(x: 32, y: 52) == 255)  // 6 o'clock untouched
  #expect(bmp.luminance(x: 12, y: 32) == 255)  // 9 o'clock untouched
}

@Test func andGateNoseSweepsMinus90Through180LikePainterShaped() {
  // PainterShaped.paintAnd: drawCenteredArc(g, -width/2, 0, width/2, -90, 180). Starting at
  // -90 (6 o'clock) and sweeping +180 counter-clockwise reaches 12 o'clock the RIGHT way round,
  // through 3 o'clock; the bulge points +x. Sweeping the other way gives a concave gate.
  let bmp = rasterise { b in
    b.color = .black
    b.strokeWidth = 2
    b.drawCenteredArc(32, 32, 20, -90, 180)
  }
  #expect(bmp.luminance(x: 52, y: 32) < 64)  // bulge on the +x side
  #expect(bmp.luminance(x: 12, y: 32) == 255)  // nothing on the -x side
}

@Test func arcAnglesAreSkewedByTheBoundingBoxNotMeasuredOnIt() {
  // Arc2D's "skewed" convention: 45 degrees on a 2:1 ellipse is NOT at 45 degrees geometrically.
  // Building the arc on a unit circle and stretching it reproduces that; calling atan2 on the
  // ellipse does not.
  let bmp = rasterise { b in
    b.color = .black
    b.strokeWidth = 2
    b.drawArc(2, 22, 60, 20, 0, 90)  // wide, flat ellipse, upper right quadrant
  }
  // Centre (32, 32), rx 30, ry 10. The 0-degree end is at (62, 32); the 90-degree end is at
  // (32, 22): the top of the *flat* ellipse, not 45 degrees away from anything.
  #expect(bmp.luminance(x: 61, y: 32) < 128)  // right extreme
  #expect(bmp.luminance(x: 32, y: 22) < 128)  // top
  #expect(bmp.luminance(x: 32, y: 41) == 255)  // bottom untouched
  #expect(bmp.luminance(x: 3, y: 32) == 255)  // left untouched
}

@Test func fillArcIsAPieAndDrawArcIsOpen() {
  let pie = rasterise { b in
    b.color = .black
    b.fillArc(12, 12, 40, 40, 0, 90)
  }
  // Centre (32, 32), radius 20, wedge from 3 o'clock counter-clockwise to 12 o'clock, i.e. the
  // upper-right quadrant. A pie fills its interior right up to the apex.
  #expect(pie.luminance(x: 38, y: 26) == 0)
  #expect(pie.luminance(x: 34, y: 30) == 0)  // just inside the apex
  #expect(pie.luminance(x: 38, y: 38) == 255)  // the opposite quadrant stays empty

  let open = rasterise { b in
    b.color = .black
    b.strokeWidth = 1
    b.drawArc(12, 12, 40, 40, 0, 90)
  }
  // Arc2D.OPEN: the rim only. No chord, no radii, hollow interior.
  // The rim crosses row 32 at x + width. A curve's antialiased extremum splits its coverage
  // between two columns, so assert on the neighbourhood rather than on one pixel.
  #expect(open.darkPixelsInRow(32, x0: 45, x1: 55, threshold: 200) >= 1)
  #expect(open.luminance(x: 38, y: 26) == 255)  // interior untouched
  #expect(open.luminance(x: 34, y: 30) == 255)  // no radius drawn back to the apex
}

@Test func batchedArcsDoNotConnectToEachOther() {
  // CG's arc appenders add a line from the current point. With batching, the previous
  // primitive's end IS the current point, so an open arc would grow a stray chord across the
  // component unless the backend moves first.
  let bmp = rasterise { b in
    b.color = .black
    b.strokeWidth = 1
    b.drawArc(2, 2, 20, 20, 0, 90)
    b.drawArc(42, 42, 20, 20, 0, 90)
  }
  // The midpoint of a line joining the two arcs would be around (32, 32).
  #expect(bmp.luminance(x: 32, y: 32) == 255)
  #expect(bmp.luminance(x: 28, y: 28) == 255)
}

// MARK: - Polygons

@Test func fillPolygonUsesEvenOddLikeJavaPolygon() {
  // A star self-intersects; even-odd leaves the middle hollow, non-zero fills it. java.awt
  // .Polygon is even-odd, so the hollow one is correct.
  let pts = (0..<5).map { i -> ScenePoint in
    let a = -Double.pi / 2 + Double(i) * 4 * Double.pi / 5
    return ScenePoint(Int(32 + 26 * cos(a)), Int(32 + 26 * sin(a)))
  }
  let bmp = rasterise { b in
    b.color = .black
    b.fillPolygon(pts)
  }
  #expect(bmp.luminance(x: 32, y: 32) == 255)  // hollow core: even-odd
  #expect(bmp.luminance(x: 32, y: 16) == 0)  // a point of the star is filled
}

@Test func overlappingEvenOddFillsAreNeverBatchedTogether() {
  // Two separate fillPolygon calls must each be resolved on their own. Folding them into one
  // even-odd path would cancel the overlap and punch a hole through both.
  let bmp = rasterise { b in
    b.color = .black
    b.fillPolygon([ScenePoint(10, 10), ScenePoint(40, 10), ScenePoint(40, 40), ScenePoint(10, 40)])
    b.fillPolygon([ScenePoint(20, 20), ScenePoint(50, 20), ScenePoint(50, 50), ScenePoint(20, 50)])
  }
  #expect(bmp.luminance(x: 30, y: 30) == 0)  // the overlap stays filled
}

// MARK: - Shaped-gate paths

/// `PainterShaped.PATH_NARROW`, verbatim.
private func narrowOrPath() -> ScenePath {
  var p = ScenePath()
  p.move(to: 0, 0)
  p.quad(control: -10, -15, to: -30, -15)
  p.quad(control: -22, 0, to: -30, 15)
  p.quad(control: -10, 15, to: 0, 0)
  p.close()
  return p
}

@Test func shapedOrGatePathStrokesAndFills() {
  let bmp = rasterise { b in
    b.color = .black
    b.strokeWidth = 2
    b.withTranslate(48, 32) { b.strokePath(narrowOrPath()) }
  }
  // The nose sits at the translated origin and the body's upper-left control point at
  // (-30, -15) + (48, 32). Regression guard: the builder used to store path ops untranslated,
  // which put every shielded gate back at the component origin.
  #expect(bmp.luminance(x: 48, y: 32) < 128)  // the nose
  #expect(bmp.luminance(x: 18, y: 17) < 128)  // upper-left of the body
  #expect(bmp.luminance(x: 30, y: 32) == 255)  // hollow: this is a stroke, not a fill
}

@Test func aTranslatedPathMovesWithTheTranslation() {
  let b = SceneBuilder(measurer: NominalTextMeasurer())
  b.withTranslate(100, 50) { b.strokePath(narrowOrPath()) }
  let scene = b.finish()
  guard case .move(let x, let y) = scene.pathOps[0] else {
    Issue.record("first op should be a move")
    return
  }
  #expect(x == 100)
  #expect(y == 50)
}

@Test func scenePathAnswersTheContainsQueryPainterShapedNeeds() {
  // PainterShaped.getInputLineLengths advances a point rightwards while path.contains(p) holds;
  // that loop sets the length of every shaped OR/XOR gate's input stubs.
  let p = narrowOrPath()
  #expect(p.contains(x: -20, y: 0))  // inside the shield
  #expect(!p.contains(x: -40, y: 0))  // left of it
  #expect(!p.contains(x: 10, y: 0))  // right of the nose
}

@Test func pathControlBoundsAreConservativeButNotEmpty() {
  let p = narrowOrPath()
  #expect(!p.controlBounds.isEmpty)
  // The hull must enclose every control point, or culling clips the gate at high zoom.
  #expect(p.controlBounds.minX <= -30)
  #expect(p.controlBounds.maxX >= 0)
  #expect(p.controlBounds.minY <= -15)
  #expect(p.controlBounds.maxY >= 15)
}

// MARK: - Pens

@Test func dashedPenLeavesGaps() {
  // Wire.HIGHLIGHTED_STROKE. A backend that drops the dash draws a solid selection outline,
  // which reads as "not selected".
  let bmp = rasterise { b in
    b.color = .black
    b.withPen(.highlightedWire) { b.drawLine(0, 32, 63, 32) }
  }
  let dark = bmp.darkPixelsInRow(32, x0: 0, x1: 63)
  #expect(dark > 10)
  #expect(dark < 54)  // gaps exist
}

@Test func squareCapsExtendPastTheEndpointTheWayBasicStrokeDoes() {
  // BasicStroke's default CAP_SQUARE extends half a pen width past each end; CoreGraphics
  // defaults to CAP_BUTT, which would stop short and leave visible seams at every wire joint.
  let bmp = rasterise { b in
    b.color = .black
    b.strokeWidth = 4
    b.drawLine(20, 32, 40, 32)
  }
  #expect(bmp.luminance(x: 19, y: 32) == 0)  // 2 units past x = 20
  #expect(bmp.luminance(x: 41, y: 32) == 0)
  #expect(bmp.luminance(x: 17, y: 32) == 255)
}

@Test func buttCapStopsAtTheEndpoint() {
  let bmp = rasterise { b in
    b.color = .black
    b.withPen(StrokePen(width: 4, cap: .butt)) { b.drawLine(20, 32, 40, 32) }
  }
  #expect(bmp.luminance(x: 21, y: 32) == 0)
  #expect(bmp.luminance(x: 19, y: 32) == 255)
}

// MARK: - Group alpha

@Test func groupOpacityAppliesToTheCompositeNotToEachPrimitive() {
  // SubcircuitFactory's ghost. Two overlapping half-transparent shapes must NOT darken where
  // they cross; that is the difference between an AlphaComposite over the group and per-shape
  // alpha, and it is what makes a dragged subcircuit look like one object.
  let bmp = rasterise { b in
    b.group(tag: 1, opacity: 0.5) {
      b.color = .black
      b.fillRect(10, 10, 30, 30)
      b.fillRect(25, 25, 30, 30)
    }
  }
  let solo = bmp.luminance(x: 15, y: 15)
  let overlap = bmp.luminance(x: 30, y: 30)
  #expect(solo > 100 && solo < 160)  // roughly half way to white
  #expect(abs(solo - overlap) <= 2)  // and the overlap matches it
}

// MARK: - Text

@Test func textRendersDarkPixelsAtTheResolvedBaseline() {
  let bmp = rasterise(
    { b in
      b.color = .black
      b.font = SceneFont(family: .sansSerif, size: 24)
      b.drawText("HI", x: 4, y: 4, halign: .left, valign: .top)
    }, size: 64)
  var dark = 0
  for y in 0..<40 {
    for x in 0..<50 where bmp.luminance(x: x, y: y) < 128 { dark += 1 }
  }
  #expect(dark > 20, "no glyphs rasterised")
}

@Test func textIsNotUpsideDown() {
  // Scene space is y-down; CoreText draws with an implicit y-up text matrix. Forgetting the
  // compensating flip mirrors every label, which a "does it have dark pixels" test would pass.
  // 'T' has its heavy bar at the top: the upper third must carry more ink than the lower third.
  let bmp = rasterise(
    { b in
      b.color = .black
      b.font = SceneFont(family: .sansSerif, size: 40)
      b.drawText("T", x: 10, y: 4, halign: .left, valign: .top)
    }, size: 64)

  func ink(rows: Range<Int>) -> Int {
    var n = 0
    for y in rows {
      for x in 0..<64 where bmp.luminance(x: x, y: y) < 128 { n += 1 }
    }
    return n
  }
  let top = ink(rows: 5..<15)
  let bottom = ink(rows: 25..<35)
  #expect(top > bottom * 2, "top=\(top) bottom=\(bottom) — glyphs look flipped")
}

@Test func textBackgroundFillsTheResolvedBoxFirst() {
  let bmp = rasterise(
    { b in
      b.color = .black
      b.font = SceneFont(family: .sansSerif, size: 16)
      b.drawText("x", x: 20, y: 20, halign: .left, valign: .top, background: .rgb(0xFF_0000))
    }, size: 64)
  #expect(bmp.pixel(x: 21, y: 21).r > 200)
  #expect(bmp.pixel(x: 21, y: 21).g < 60)
}

// MARK: - Hit testing

@Test func hitTestReturnsTagsTopmostFirst() {
  let b = SceneBuilder(measurer: NominalTextMeasurer())
  b.group(tag: 11) { b.fillRect(0, 0, 50, 50) }
  b.group(tag: 22) { b.fillRect(20, 20, 50, 50) }
  let scene = b.finish()

  #expect(scene.hitTest(x: 30, y: 30) == [22, 11])
  #expect(scene.topmostTag(atX: 30, y: 30) == 22)
  #expect(scene.topmostTag(atX: 5, y: 5) == 11)
  #expect(scene.topmostTag(atX: 200, y: 200) == nil)
}

// MARK: - Viewport

@Test func viewportRoundTripsBetweenSceneAndDestination() {
  let vp = RenderViewport(
    rect: CGRect(x: 10, y: 20, width: 200, height: 100), scale: 2,
    sceneOriginX: 5, sceneOriginY: -3)
  let p = vp.destinationPoint(sceneX: 17, sceneY: 11)
  let back = vp.scenePoint(destination: p)
  #expect(abs(back.x - 17) < 1e-9)
  #expect(abs(back.y - 11) < 1e-9)
}

@Test func fittingCentresContentAndNeverMagnifiesPastTheCap() {
  let bounds = SceneBounds(minX: 0, minY: 0, maxX: 100, maxY: 50)
  let vp = RenderViewport.fitting(
    bounds, in: CGRect(x: 0, y: 0, width: 400, height: 400), margin: 10, maxScale: 2)
  #expect(vp.scale == 2)
  // Content centre maps to the destination centre.
  let centre = vp.destinationPoint(sceneX: 50, sceneY: 25)
  #expect(abs(Double(centre.x) - 200) < 1e-6)
  #expect(abs(Double(centre.y) - 200) < 1e-6)
}
