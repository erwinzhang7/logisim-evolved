// SceneBuilderTests: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// The emitter half of D6. Every expectation about text layout here is the arithmetic in
// `GraphicsUtil.getTextBounds` / `drawText` and `com.cburch.draw.util.TextMetrics`, including
// their truncating integer divisions. A "fix" that rounds properly instead is a fidelity
// regression: it moves every centred label in every file by up to a pixel.

import Testing

@testable import LogisimRender
@testable import LogisimKernel

// A measurer with round numbers, so an expectation reads as arithmetic rather than as a
// platform-font accident. ascent 10, descent 3, leading 0 -> height 13; advance 7/char.
private func fixedMeasurer() -> NominalTextMeasurer {
  // size 12.5 -> ascent ceil(10.0) = 10, descent ceil(2.5) = 3, advance 7 per char at 12.5*0.56
  NominalTextMeasurer(
    ascentRatio: 0.8, descentRatio: 0.2, leadingRatio: 0.0, advanceRatio: 0.56)
}

private func builder() -> SceneBuilder {
  SceneBuilder(measurer: fixedMeasurer())
}

// MARK: - Primitive emission

@Test func lineCarriesEndpointsAndInflatedBounds() {
  let b = builder()
  b.strokeWidth = 2
  b.drawLine(10, 20, 40, 20)
  let scene = b.finish()

  #expect(scene.primitives.count == 1)
  let p = scene.primitives[0]
  #expect(p.kind == .line)
  #expect(p.style == .stroke)
  #expect(p.pen.width == 2)
  #expect((p.a, p.b, p.c, p.d) == (10, 20, 40, 20))
  // Half the pen plus a pixel of slack; culling has to be conservative, never tight.
  #expect(p.bounds == SceneBounds(minX: 8, minY: 18, maxX: 42, maxY: 22))
}

@Test func penDefaultsMatchBasicStroke() {
  // BasicStroke(float) is CAP_SQUARE / JOIN_MITER. CoreGraphics defaults to CAP_BUTT, which
  // would shorten every stroked line by half a pen width at both ends.
  #expect(StrokePen.default.cap == .square)
  #expect(StrokePen.default.join == .miter)
  #expect(StrokePen.miterLimit == 10)
  #expect(StrokePen.default.isDashed == false)
}

@Test func highlightedWirePenMatchesJava() {
  // Wire.java:61, BasicStroke(3, CAP_BUTT, JOIN_BEVEL, 0, new float[]{7}, 0)
  let p = StrokePen.highlightedWire
  #expect(p.width == 3)
  #expect(p.cap == .butt)
  #expect(p.join == .bevel)
  #expect(p.dashOn == 7)
  #expect(p.isDashed)
}

@Test func translationIsBakedIntoCoordinatesAndAllocatesNoTransform() {
  let b = builder()
  b.withTranslate(100, 50) {
    b.drawLine(0, 0, 10, 0)
  }
  let scene = b.finish()
  let p = scene.primitives[0]
  #expect(p.transform == 0)
  #expect((p.a, p.b, p.c, p.d) == (100, 50, 110, 50))
  // The transform pool never grew past its identity entry.
  #expect(scene.transforms.count == 1)
}

@Test func rotationAllocatesAndDeduplicatesOneTransform() {
  let b = builder()
  for _ in 0..<5 {
    b.withTransform(.rotation(.pi / 2)) { b.drawRect(0, 0, 10, 10) }
  }
  let scene = b.finish()
  #expect(scene.transforms.count == 2)  // identity + the one rotation
  #expect(scene.primitives.allSatisfy { $0.transform == 1 })
}

@Test func polygonFillsEvenOddLikeJavaPolygon() {
  let b = builder()
  b.fillPolygon([ScenePoint(0, 0), ScenePoint(10, 0), ScenePoint(10, 10)])
  let scene = b.finish()
  #expect(scene.primitives[0].fillRule == .evenOdd)
  #expect(scene.primitives[0].style == .fill)
}

@Test func drawCenteredArcMatchesGraphicsUtil() {
  // GraphicsUtil.drawCenteredArc: g.drawArc(x - r, y - r, 2r, 2r, start, dist)
  let b = builder()
  b.drawCenteredArc(50, 50, 20, -90, 180)
  let p = b.finish().primitives[0]
  #expect(p.kind == .arc)
  #expect((p.a, p.b, p.c, p.d, p.e, p.f) == (30, 30, 40, 40, -90, 180))
}

@Test func drawArrowReproducesJavaIntegerTruncation() {
  // GraphicsUtil.drawArrow truncates each head coordinate with a (int) cast. Rounding instead
  // moves the head by a pixel on about half of all angles.
  let b = builder()
  b.drawArrow(0, 0, 40, 0, headLength: 10, headAngle: 30)
  let scene = b.finish()
  #expect(scene.primitives.count == 2)  // the shaft, then the 3-point head polyline

  let head = scene.primitives[1]
  #expect(head.kind == .polyline)
  let pts = head.pointRange.map { scene.points[$0] }
  #expect(pts.count == 3)
  // angle = atan2(0, -40) = pi, offs = 30*pi/180.
  //   x: cos(pi + pi/6) * 10 = -8.66  -> (int) -8  -> 40 - 8 = 32
  //   y: sin(pi + pi/6) * 10 = -4.999999999999999 (NOT -5.0 in IEEE double)
  //                                   -> (int) -4  -> 0 - 4 = -4
  // That second one is the whole point of reproducing Java's truncation rather than rounding:
  // the head is asymmetric by a pixel because the cast throws away a value that is one ulp shy
  // of an integer. Java computes the identical double and truncates identically.
  #expect(pts[0] == ScenePoint(32, -4))
  #expect(pts[1] == ScenePoint(40, 0))
  #expect(pts[2] == ScenePoint(32, 4))
}

// MARK: - Text layout (GraphicsUtil.getTextBounds)

@Test func textBoxReproducesJavaAlignmentArithmetic() {
  let m = FontMetrics(ascent: 10, descent: 3, leading: 0)  // height 13

  // H_LEFT / V_TOP: no adjustment at all.
  #expect(
    TextLayout.textBox(width: 21, metrics: m, x: 100, y: 200, halign: .left, valign: .top).x
      == 100)

  // H_CENTER truncates: an odd width sits one pixel LEFT of true centre. Java does the same.
  let centered = TextLayout.textBox(
    width: 21, metrics: m, x: 100, y: 200, halign: .center, valign: .center)
  #expect(centered.x == 100 - 21 / 2)  // 90, not 89.5
  #expect(centered.y == 200 - 10 / 2)  // V_CENTER uses ascent/2, not height/2

  #expect(
    TextLayout.textBox(width: 21, metrics: m, x: 100, y: 200, halign: .right, valign: .top).x
      == 79)

  // V_CENTER_OVERALL is the one that uses the full line height.
  #expect(
    TextLayout.textBox(width: 21, metrics: m, x: 100, y: 200, halign: .left, valign: .centerOverall)
      .y == 200 - 13 / 2)
  #expect(
    TextLayout.textBox(width: 21, metrics: m, x: 100, y: 200, halign: .left, valign: .baseline).y
      == 190)
  #expect(
    TextLayout.textBox(width: 21, metrics: m, x: 100, y: 200, halign: .left, valign: .bottom).y
      == 187)
}

@Test func oddWidthCentringTruncatesTowardZeroNotAway() {
  // The specific quirk: 21/2 == 10 in Java and in Swift. Rounding to 11 would shift every
  // odd-width centred label by one pixel, which across a corpus is every label.
  let m = FontMetrics(ascent: 9, descent: 3, leading: 0)
  let box = TextLayout.textBox(width: 21, metrics: m, x: 0, y: 0, halign: .center, valign: .center)
  #expect(box.x == -10)
  #expect(box.y == -4)  // 9 / 2 == 4
}

@Test func baselineIsBoxTopPlusAscent() {
  // GraphicsUtil.drawText's final call: g.drawString(text, bd.x, bd.y + tm.ascent)
  let m = FontMetrics(ascent: 10, descent: 3, leading: 0)
  let box = TextLayout.textBox(width: 20, metrics: m, x: 5, y: 7, halign: .left, valign: .top)
  let baseline = TextLayout.baselineOrigin(box: box, metrics: m)
  #expect(baseline == (5, 17))
}

@Test func drawTextResolvesLayoutOnceIntoTheRun() {
  let b = builder()
  b.font = SceneFont(family: .sansSerif, size: 12.5)
  b.drawCenteredText("ABC", x: 100, y: 50)
  let scene = b.finish()

  let prim = scene.primitives[0]
  #expect(prim.kind == .text)
  let run = try! #require(scene.textRun(prim))
  #expect(run.string == "ABC")
  // width = Int(3 * 12.5 * 0.56) = 21; ascent = ceil(10.0) = 10; height = 10 + 3 = 13
  #expect(run.boxWidth == 21)
  #expect(run.boxHeight == 13)
  #expect(run.boxX == 100 - 21 / 2)
  #expect(run.boxY == 50 - 10 / 2)
  #expect(run.baselineX == run.boxX)
  #expect(run.baselineY == run.boxY + 10)
}

@Test func emptyTextEmitsNothing() {
  // GraphicsUtil.drawText returns immediately on an empty string.
  let b = builder()
  b.drawText("", x: 0, y: 0)
  #expect(b.finish().isEmpty)
}

// MARK: - Colour slots (the per-frame delta)

@Test func staticColoursAreInternedAndShared() {
  let b = builder()
  b.color = .rgb(0xFF_0000)
  b.drawLine(0, 0, 10, 0)
  b.color = .rgb(0xFF_0000)
  b.drawLine(0, 10, 10, 10)
  b.color = .rgb(0x00_FF00)
  b.drawLine(0, 20, 10, 20)
  let scene = b.finish()

  #expect(scene.primitives[0].color == scene.primitives[1].color)
  #expect(scene.primitives[0].color != scene.primitives[2].color)
}

@Test func dynamicSlotIsTheEntirePerFrameDelta() {
  // This is the load-bearing claim of D6: a simulation frame writes UInt16s, never geometry.
  let b = builder()
  let slot = b.reserveColorSlot(initial: .palette(.nilValue))
  b.useColorSlot(slot)
  b.drawLine(0, 0, 100, 0)
  var scene = b.finish()

  let geometryBefore = scene.primitives
  #expect(scene.color(of: slot) == ValueColorTheme.logisim[.nilValue])

  let accepted = scene.setColor(slot, to: PaletteIndex(.trueValue))
  #expect(accepted)
  #expect(scene.color(of: slot) == ValueColorTheme.logisim[.trueValue])
  #expect(scene.primitives == geometryBefore)  // not one primitive touched
}

@Test func staticSlotsRefuseAPerFrameWrite() {
  // A static slot is shared by everything that asked for the same colour, so honouring the
  // write would silently recolour unrelated geometry. Failing visibly beats corrupting a frame.
  let b = builder()
  b.color = .rgb(0xFF_0000)
  b.drawLine(0, 0, 10, 0)
  var scene = b.finish()
  let staticSlot = scene.primitives[0].color

  let refused = scene.setColor(staticSlot, to: PaletteIndex(.trueValue))
  #expect(refused == false)
  #expect(scene.color(of: staticSlot) == RGBA(javaRGB: 0xFF_0000))
}

@Test func paletteValuesAreResolvedByTheThemeNotBakedIn() {
  let b = builder()
  b.color = .palette(.trueValue)
  b.drawLine(0, 0, 10, 0)
  let scene = b.finish()
  let slot = scene.primitives[0].color

  var custom = ValueColorTheme.logisim
  custom[.trueValue] = RGBA(javaRGB: 0x12_3456)
  #expect(scene.color(of: slot, theme: .logisim) == RGBA(javaRGB: 0x00_D200))
  #expect(scene.color(of: slot, theme: custom) == RGBA(javaRGB: 0x12_3456))
}

@Test func javaColorIntConstructorIgnoresTheAlphaByte() {
  // new Color(int) is opaque regardless of the high byte; AppPreferences stores 0x99999999 and
  // means opaque grey. Reading it as 60%-alpha grey washes out every default colour.
  #expect(RGBA(javaRGB: 0x99_99_99_99) == RGBA(r: 0x99, g: 0x99, b: 0x99, a: 255))
  #expect(RGBA(javaARGB: 0x80_99_99_99).a == 0x80)
}

@Test func paletteIndicesMirrorValuePaletteOneForOne() {
  // D9: the kernel returns an index, never a colour. That only works if the index space lines
  // up with ValuePalette exactly.
  for c in ValuePalette.allCases {
    #expect(PaletteIndex(c).rawValue == UInt16(c.rawValue))
    #expect(PaletteIndex(c).valuePalette == c)
  }
}

// MARK: - Groups

@Test func groupsBoundTheirPrimitivesAndCarryATag() {
  let b = builder()
  b.group(tag: 0xABCD) {
    b.fillRect(0, 0, 20, 20)
    b.fillRect(100, 100, 10, 10)
  }
  let scene = b.finish()
  #expect(scene.groups.count == 1)
  #expect(scene.groups[0].tag == 0xABCD)
  #expect(scene.groups[0].count == 2)
  #expect(scene.groups[0].bounds == SceneBounds(minX: 0, minY: 0, maxX: 110, maxY: 110))
  #expect(scene.groups[0].opacity == 255)
}

@Test func groupOpacityCarriesTheSubcircuitGhostAlpha() {
  // SubcircuitFactory.java:372, AlphaComposite.getInstance(SRC_OVER, 0.5f)
  let b = builder()
  b.group(tag: 1, opacity: 0.5) { b.fillRect(0, 0, 10, 10) }
  let scene = b.finish()
  #expect(scene.groups[0].opacity == 128)
}

@Test func primitivesEmittedOutsideAGroupStillLandInOne() {
  // Anything not in a group would fall out of the spatial index and vanish from the frame.
  let b = builder()
  b.drawLine(0, 0, 10, 10)
  let scene = b.finish()
  #expect(scene.groups.count == 1)
  #expect(scene.groups[0].count == 1)
}

// MARK: - Primitive role

// ═════════════════════════════════════════════════════════════════════════════════════════════
// `ScenePrimitive.Role`; the emitter's own answer to "is this a connection marker".
//
// It exists because `SelectionSilhouette` (LogisimUI) used to answer that question by shape;
// "markers are fills, boundaries are strokes", which was a proxy, not the rule, and collapsed
// the day `drawPinMarker` became a ring. These tests pin the three properties that make the
// replacement worth trusting: the role rides on EVERY primitive a marker is made of whatever
// kind it is drawn as, it does not leak past the marker, and nothing else in the builder emits
// it.
// ═════════════════════════════════════════════════════════════════════════════════════════════

@Test func aPortMarkerTagsEveryPrimitiveItIsMadeOf() {
  let b = builder()
  b.drawPinMarker(50, 50)
  let scene = b.finish()

  // The point is not that a marker is two primitives; that is the ring's own arithmetic and is
  // pinned in `PortMarkerRingTests`. It is that the tagged count equals the emitted count: a
  // marker later redrawn as three primitives, or as a polygon, must still be entirely tagged, or
  // the untagged part becomes a body outline again and the whole collision comes back.
  #expect(!scene.primitives.isEmpty)
  #expect(
    scene.primitives.allSatisfy { $0.role == .connectionMarker },
    "an untagged primitive: \(scene.primitives.map { "\($0.kind)/\($0.style)/\($0.role)" })")
}

@Test func theRoleIsScopedToTheMarkerAndDoesNotLeak() {
  // The stamp is a save/restore around `drawPinMarker`'s body. If it leaked, every primitive
  // drawn after the first port would be classed a marker, and a selected component would
  // silently stop being traced at all; a failure that shows up as "everything is boxed again",
  // i.e. the reported defect restored, with a green suite.
  let b = builder()
  b.drawRect(0, 0, 10, 10)
  b.drawPinMarker(50, 50)
  b.drawRect(100, 100, 10, 10)
  let scene = b.finish()

  let roles = scene.primitives.map(\.role)
  #expect(roles.first == .body, "a rect drawn before any marker was tagged a marker")
  #expect(roles.last == .body, "the marker's role leaked into the next primitive drawn")
  #expect(roles.filter { $0 == .connectionMarker }.count == scene.primitives.count - 2)
}

@Test func everyOtherBuilderCallEmitsBodyGeometry() {
  // The single-producer claim, swept over the primitive set rather than trusted. If a second
  // emitter ever starts stamping `.connectionMarker`, `SelectionSilhouette` clause 2a begins
  // dropping real geometry and the selection outline quietly shrinks.
  //
  // `drawDongle` is in the sweep on purpose: it is a 9-unit `drawOval` centred on a point, which
  // is the closest thing in the builder to a port marker by shape and size, and is exactly what
  // a size-threshold rule would have misclassified. It must come out `.body`.
  let b = builder()
  b.drawLine(0, 0, 10, 0)
  b.drawPolyline([ScenePoint(x: 0, y: 0), ScenePoint(x: 5, y: 5), ScenePoint(x: 10, y: 0)])
  b.drawPolygon([ScenePoint(x: 0, y: 0), ScenePoint(x: 5, y: 5), ScenePoint(x: 10, y: 0)])
  b.drawRect(0, 0, 10, 10)
  b.fillRect(0, 0, 10, 10)
  b.drawRoundRect(0, 0, 10, 10, 4, 4)
  b.fillRoundRect(0, 0, 10, 10, 4, 4)
  b.drawOval(0, 0, 10, 10)
  b.fillOval(0, 0, 10, 10)
  b.drawArc(0, 0, 10, 10, 0, 90)
  b.fillArc(0, 0, 10, 10, 0, 90)
  b.drawString("x", x: 0, y: 0)
  b.drawHandle(5, 5)
  b.drawDongle(5, 5)
  let scene = b.finish()

  #expect(scene.primitives.count > 12, "the sweep stopped emitting; it is no longer a sweep")
  #expect(
    scene.primitives.allSatisfy { $0.role == .body },
    "a builder call other than `drawPinMarker` emitted a connection marker")
}

@Test func theRoleFieldIsFreeInTheRecordLayout() {
  // `ScenePrimitive` is a POD record walked linearly tens of thousands of times a frame and
  // destined for a GPU instance buffer; its whole shape exists to keep that walk a contiguous
  // stride. `role` was declared between `pen` (6 bytes, 1-aligned) and `transform` (2-aligned)
  // specifically so it lands in padding that was already there. If a later edit moves it, or
  // adds a field beside it, this catches the growth rather than letting the walk quietly cost an
  // extra cache line per two primitives.
  #expect(MemoryLayout<ScenePrimitive>.size == 64)
  #expect(MemoryLayout<ScenePrimitive>.stride == 64)
}
