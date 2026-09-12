// SceneBuilderNestingTests: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// Regressions for three `SceneBuilder` state bugs that a flat, single-group,
// single-frame test suite cannot see:
//
//   1. `beginGroup` used to close the open group first, so an outer transparency group was
//      destroyed by its first child; `SubcircuitFactory.paintGhost` (AlphaComposite SRC_OVER
//      0.5 around a subcircuit that paints its children as groups) came out fully opaque and
//      the ghost's tag was gone from the scene entirely.
//   2. `textBounds` skipped the baked translation that every emitter applies, so measuring a
//      label under `pushTranslate` and drawing it disagreed by the whole translation.
//   3. `reset()` reset `strokeWidth`, which only touches `pen.width`: cap, join and the dash
//      pattern of `Wire.HIGHLIGHTED_STROKE` survived into the next frame.
//
// Every test here is built around the case the old suite skipped: more than one group, more
// than one frame, or a non-zero translation.

import CoreGraphics
import Testing

@testable import LogisimRender
@testable import LogisimRenderBackend

private func nestingMeasurer() -> NominalTextMeasurer {
  NominalTextMeasurer(
    ascentRatio: 0.8, descentRatio: 0.2, leadingRatio: 0.0, advanceRatio: 0.56)
}

private func nestingBuilder() -> SceneBuilder {
  SceneBuilder(measurer: nestingMeasurer())
}

/// Every primitive belongs to exactly one drawn group. Overlapping group ranges would paint
/// the overlap twice, which is what a naive "parent group covers its children" fix does.
private func assertRangesPartitionPrimitives(_ scene: RenderScene, sourceLocation: SourceLocation = #_sourceLocation) {
  var owners = [Int](repeating: 0, count: scene.primitives.count)
  for g in scene.groups {
    for i in g.range {
      #expect(i >= 0 && i < owners.count, "group range out of bounds", sourceLocation: sourceLocation)
      if i >= 0 && i < owners.count { owners[i] += 1 }
    }
  }
  for (i, n) in owners.enumerated() {
    #expect(n == 1, "primitive \(i) is drawn \(n) times", sourceLocation: sourceLocation)
  }
}

/// Groups must stay in painter's order: the backend walks them ascending.
private func assertPainterOrder(_ scene: RenderScene, sourceLocation: SourceLocation = #_sourceLocation) {
  var lastEnd = 0
  for g in scene.groups where g.count > 0 {
    #expect(Int(g.start) >= lastEnd, "group starts before the previous one ended", sourceLocation: sourceLocation)
    lastEnd = Int(g.start) + Int(g.count)
  }
}

private func group(_ scene: RenderScene, tag: UInt64) -> SceneGroup? {
  scene.groups.first { $0.tag == tag }
}

// MARK: - Nesting

@Test func innerGroupDoesNotDestroyTheOuterOne() {
  // The executed repro: tag 100 at 0.5 with two children used to produce exactly two groups,
  // tags 1 and 2, both opaque. Tag 100 did not exist in the scene at all.
  let b = nestingBuilder()
  b.group(tag: 100, opacity: 0.5) {
    b.group(tag: 1) { b.fillRect(0, 0, 10, 10) }
    b.group(tag: 2) { b.fillRect(20, 0, 10, 10) }
  }
  let scene = b.finish()

  let ghost = group(scene, tag: 100)
  #expect(ghost != nil, "the outer group vanished")
  #expect(ghost?.bounds == SceneBounds(minX: 0, minY: 0, maxX: 30, maxY: 10))
  #expect(group(scene, tag: 1) != nil)
  #expect(group(scene, tag: 2) != nil)
  #expect(scene.groups.count == 3)

  // The children carry the composed alpha; the backend applies opacity where the primitives
  // are, and the parent's identity entry draws nothing (so it must not open a layer).
  #expect(group(scene, tag: 1)?.opacity == 128)
  #expect(group(scene, tag: 2)?.opacity == 128)
  #expect(ghost?.count == 0)
  #expect(ghost?.opacity == 255)

  assertRangesPartitionPrimitives(scene)
  assertPainterOrder(scene)
}

@Test func nestedOpacityComposesLikeStackedAlphaComposites() {
  // AlphaComposite nests multiplicatively: 0.5 inside 0.5 leaves 25% of the source, not 50%.
  let b = nestingBuilder()
  b.group(tag: 10, opacity: 0.5) {
    b.group(tag: 11, opacity: 0.5) { b.fillRect(0, 0, 10, 10) }
  }
  let scene = b.finish()
  #expect(group(scene, tag: 11)?.opacity == 64)  // 0.25 * 255, rounded

  // ...and three deep.
  let c = nestingBuilder()
  c.group(tag: 1, opacity: 0.5) {
    c.group(tag: 2, opacity: 0.5) {
      c.group(tag: 3, opacity: 0.5) { c.fillRect(0, 0, 10, 10) }
    }
  }
  #expect(group(c.finish(), tag: 3)?.opacity == 32)  // 0.125 * 255, rounded
}

@Test func aTransparentParentTintsItsOwnPrimitivesToo() {
  // Primitives drawn by the parent itself, not by a child, still get the parent's alpha.
  let b = nestingBuilder()
  b.group(tag: 7, opacity: 0.5) {
    b.fillRect(0, 0, 10, 10)
    b.group(tag: 8) { b.fillRect(20, 0, 10, 10) }
  }
  let scene = b.finish()
  for g in scene.groups where g.count > 0 {
    #expect(g.opacity == 128)
  }
  assertRangesPartitionPrimitives(scene)
}

@Test func parentPrimitivesKeepPaintOrderAroundAChild() {
  // A parent that draws a body, then a child, then a highlight on top must emit three runs in
  // that order; a fix that appends the parent's whole run at close time would paint the body
  // and the highlight after the child.
  let b = nestingBuilder()
  b.group(tag: 100) {
    b.fillRect(0, 0, 5, 5)  // primitive 0, parent, before the child
    b.group(tag: 200) { b.fillRect(10, 0, 5, 5) }  // primitive 1, child
    b.fillRect(20, 0, 5, 5)  // primitive 2, parent, after the child
  }
  let scene = b.finish()

  #expect(scene.primitives.count == 3)
  assertRangesPartitionPrimitives(scene)
  assertPainterOrder(scene)

  let drawn = scene.groups.filter { $0.count > 0 }
  #expect(drawn.map { Int($0.start) } == [0, 1, 2])
  // The child's run is the one that carries a tag; the parent's split runs must not repeat
  // tag 100, or one hit test would report the same component twice.
  #expect(drawn.map(\.tag) == [0, 200, 0])
  #expect(group(scene, tag: 100)?.bounds == SceneBounds(minX: 0, minY: 0, maxX: 25, maxY: 5))
}

@Test func nestedGroupTagsAreAllHittableTopmostFirst() {
  // Losing the outer tag makes a dragged subcircuit ghost unhittable, which is the other half
  // of the same bug.
  let b = nestingBuilder()
  b.group(tag: 100, opacity: 0.5) {
    b.group(tag: 1) { b.fillRect(0, 0, 10, 10) }
    b.group(tag: 2) { b.fillRect(20, 0, 10, 10) }
  }
  let scene = b.finish()

  #expect(scene.hitTest(x: 5, y: 5) == [1, 100])
  #expect(scene.hitTest(x: 25, y: 5) == [2, 100])
  // Between the children: inside the parent's extent, outside both children.
  #expect(scene.hitTest(x: 15, y: 5) == [100])
  #expect(scene.topmostTag(atX: 5, y: 5) == 1)
  #expect(scene.topmostTag(atX: 15, y: 5) == 100)
}

@Test func aGroupWithOnlyChildrenStillBoundsThemAll() {
  let b = nestingBuilder()
  b.group(tag: 42) {
    b.group(tag: 1) { b.fillRect(-30, -30, 10, 10) }
    b.group(tag: 2) { b.fillRect(100, 100, 10, 10) }
  }
  let scene = b.finish()
  #expect(group(scene, tag: 42)?.bounds == SceneBounds(minX: -30, minY: -30, maxX: 110, maxY: 110))
  // ...and culling still finds the parent through the spatial index.
  #expect(scene.hitTest(x: -25, y: -25).contains(42))
}

@Test func unbalancedEndGroupDoesNotEatTheEnclosingGroup() {
  // A ported painter that returns early inside a helper must not silently close its caller's
  // group; before the stack existed there was only one group to close, so it always did.
  let b = nestingBuilder()
  b.beginGroup(tag: 1)
  b.endGroup()
  b.endGroup()  // stray
  b.endGroup()  // stray
  b.group(tag: 2) { b.fillRect(0, 0, 10, 10) }
  let scene = b.finish()
  #expect(scene.groups.count == 1)
  #expect(scene.groups[0].tag == 2)
}

@Test func finishClosesEveryGroupLeftOpen() {
  let b = nestingBuilder()
  b.beginGroup(tag: 1, opacity: 0.5)
  b.beginGroup(tag: 2)
  b.fillRect(0, 0, 10, 10)
  let scene = b.finish()  // no endGroup at all
  #expect(group(scene, tag: 1) != nil)
  #expect(group(scene, tag: 2)?.opacity == 128)
  assertRangesPartitionPrimitives(scene)
}

@Test func chromeBeforeAGroupStaysInItsOwnImplicitGroup() {
  // The implicit group is not a parent: a stray line drawn before the first component must not
  // adopt that component.
  let b = nestingBuilder()
  b.drawLine(0, 0, 10, 0)
  b.group(tag: 5) { b.fillRect(50, 50, 10, 10) }
  let scene = b.finish()

  #expect(scene.groups.count == 2)
  #expect(scene.groups[0].tag == 0)
  #expect(scene.groups[0].count == 1)
  #expect(scene.groups[1].tag == 5)
  #expect(scene.groups[1].count == 1)
  assertRangesPartitionPrimitives(scene)
}

@Test func anEmptyGroupEmitsNothing() {
  let b = nestingBuilder()
  b.group(tag: 1) {}
  b.group(tag: 2, opacity: 0.5) { b.group(tag: 3) {} }
  #expect(b.finish().groups.isEmpty)
}

@Test func groupDepthTracksTheStack() {
  let b = nestingBuilder()
  #expect(b.openGroupDepth == 0)
  b.beginGroup(tag: 1)
  #expect(b.openGroupDepth == 1)
  b.beginGroup(tag: 2)
  #expect(b.openGroupDepth == 2)
  b.endGroup()
  #expect(b.openGroupDepth == 1)
  b.endGroup()
  #expect(b.openGroupDepth == 0)
}

// MARK: - Nesting, rasterised

private func rasteriseNested(
  _ build: (SceneBuilder) -> Void,
  size: Int = 64
) -> SceneBitmap {
  let b = SceneBuilder(measurer: CoreTextMeasurer())
  build(b)
  let scene = b.finish()
  let vp = RenderViewport(rect: CGRect(x: 0, y: 0, width: size, height: size))
  return SceneRasterizer.render(
    scene, width: size, height: size, viewport: vp,
    options: RenderOptions(background: .white))!.bitmap
}

@Test func aGhostGroupTintsTheChildrenItWraps() {
  // The pixel test the flat-group suite could not do: black children inside a 0.5 parent must
  // land half way to white. With the old `beginGroup`, the parent's alpha was discarded by the
  // first child and every pixel came out fully opaque black.
  let bmp = rasteriseNested { b in
    b.color = .black
    b.group(tag: 100, opacity: 0.5) {
      b.group(tag: 1) { b.fillRect(4, 4, 16, 16) }
      b.group(tag: 2) { b.fillRect(30, 4, 16, 16) }
    }
  }
  #expect(bmp.luminance(x: 10, y: 10) == 127)
  #expect(bmp.luminance(x: 36, y: 10) == 127)
  #expect(bmp.luminance(x: 25, y: 10) == 255)  // the gap between them is untouched
}

@Test func nestedGhostAlphaMultipliesOnScreen() {
  let bmp = rasteriseNested { b in
    b.color = .black
    b.group(tag: 1, opacity: 0.5) {
      b.group(tag: 2, opacity: 0.5) { b.fillRect(4, 4, 20, 20) }
    }
  }
  // 0.25 black over white = 191.
  #expect(bmp.luminance(x: 10, y: 10) == 191)
}

// MARK: - textBounds and the baked translation

@Test func textBoundsFollowsTheBakedTranslation() {
  // Every other emitter goes through tx()/ty(). A measurement in a different coordinate frame
  // from the run it predicts is wrong no matter which frame the caller wanted.
  let b = nestingBuilder()
  b.pushTranslate(100, 100)

  let measured = b.textBounds("AB", x: 0, y: 0, halign: .center, valign: .center)
  b.drawCenteredText("AB", x: 0, y: 0)
  let scene = b.finish()

  let run = scene.texts[0]
  #expect(measured.x == Int(run.boxX))
  #expect(measured.y == Int(run.boxY))
  #expect(measured.width == Int(run.boxWidth))
  #expect(measured.height == Int(run.boxHeight))
}

@Test func textBoundsMatchesTheDrawnRunUnderEveryTranslation() {
  for (dx, dy) in [(0, 0), (100, 100), (-40, 7)] {
    let b = nestingBuilder()
    b.withTranslate(dx, dy) {
      let measured = b.textBounds("Hello", x: 3, y: -9, halign: .right, valign: .bottom)
      b.drawText("Hello", x: 3, y: -9, halign: .right, valign: .bottom)
      let run = b.finish().texts[0]
      #expect(measured.x == Int(run.boxX), "dx=\(dx)")
      #expect(measured.y == Int(run.boxY), "dy=\(dy)")
    }
  }
}

@Test func nestedTranslationsAccumulateInTextBounds() {
  let b = nestingBuilder()
  let untranslated = b.textBounds("AB", x: 0, y: 0, halign: .center, valign: .center)
  b.pushTranslate(10, 20)
  b.pushTranslate(5, 5)
  let translated = b.textBounds("AB", x: 0, y: 0, halign: .center, valign: .center)
  #expect(translated.x == untranslated.x + 15)
  #expect(translated.y == untranslated.y + 25)
}

@Test func userSpaceTextBoundsCanBeFedBackIntoAnEmitter() {
  // The Java idiom is `bds = getTextBounds(...); g.fillRect(bds)`, both in user space. Since
  // the builder bakes the translation at emit time, that round trip needs the user-space
  // measurement or the translation is applied twice.
  let b = nestingBuilder()
  b.pushTranslate(100, 100)
  let box = b.textBoundsInUserSpace("AB", x: 0, y: 0, halign: .center, valign: .center)
  b.fillRect(box)
  let scene = b.finish()

  let sceneBox = b.textBounds("AB", x: 0, y: 0, halign: .center, valign: .center)
  let rect = scene.primitives[0]
  #expect(rect.a == Int32(sceneBox.x))
  #expect(rect.b == Int32(sceneBox.y))
  #expect(rect.c == Int32(sceneBox.width))
  #expect(rect.d == Int32(sceneBox.height))
}

@Test func emptyTextMeasuresAsAZeroWidthBoxInBothFrames() {
  let b = nestingBuilder()
  b.pushTranslate(10, 10)
  #expect(b.textBounds("", x: 0, y: 0).width == 0)
  #expect(b.textBoundsInUserSpace("", x: 0, y: 0).width == 0)
  #expect(b.textBounds("", x: 0, y: 0).x == 10)
  #expect(b.textBoundsInUserSpace("", x: 0, y: 0).x == 0)
}

// MARK: - reset

@Test func resetClearsTheWholePenNotJustItsWidth() {
  // `strokeWidth = 1` only assigns pen.width. Cap, join, dash and phase of
  // Wire.HIGHLIGHTED_STROKE survived, so every wire in the next frame came out dashed.
  let b = nestingBuilder()
  b.pen = .highlightedWire
  b.reset()
  b.drawLine(0, 0, 10, 0)
  let scene = b.finish()

  #expect(b.pen == StrokePen.default)
  #expect(scene.primitives[0].pen == StrokePen.default)
  #expect(scene.primitives[0].pen.isDashed == false)
  #expect(scene.primitives[0].pen.cap == .square)
  #expect(scene.primitives[0].pen.join == .miter)
  #expect(scene.primitives[0].pen.width == 1)
}

@Test func resetClearsGroupOpacityAndTheGroupStack() {
  // openGroupOpacity was stale after reset() and only masked because emit() happened to
  // rewrite it. Anything emitted into the reused builder inherited the ghost's alpha the
  // moment that masking stopped holding.
  let b = nestingBuilder()
  b.beginGroup(tag: 5, opacity: 0.5)
  b.beginGroup(tag: 6, opacity: 0.5)
  b.fillRect(0, 0, 10, 10)
  b.reset()

  #expect(b.openGroupDepth == 0)
  b.drawLine(0, 0, 10, 0)
  let scene = b.finish()
  #expect(scene.groups.count == 1)
  #expect(scene.groups[0].tag == 0)
  #expect(scene.groups[0].opacity == 255)
  #expect(scene.primitives.count == 1)
}

@Test func resetClearsTheTranslationThatTextBoundsReads() {
  let b = nestingBuilder()
  b.pushTranslate(100, 100)
  let before = b.textBounds("AB", x: 0, y: 0, halign: .center, valign: .center)
  b.reset()
  let after = b.textBounds("AB", x: 0, y: 0, halign: .center, valign: .center)
  #expect(before.x == after.x + 100)
  #expect(before.y == after.y + 100)
}

@Test func aBuilderRebuiltAfterResetMatchesAFreshOne() {
  // reset() exists to be reused across frames; the only thing that may differ from a fresh
  // builder is capacity.
  func build(_ b: SceneBuilder) {
    b.color = .rgb(0x00_00FF)
    b.group(tag: 3, opacity: 0.5) {
      b.group(tag: 4) { b.drawLine(0, 0, 10, 10) }
      b.fillRect(0, 0, 4, 4)
    }
  }

  let dirty = nestingBuilder()
  dirty.pen = .highlightedWire
  dirty.font = SceneFont(family: .serif, size: 40)
  dirty.color = .rgb(0xFF_0000)
  dirty.pushTranslate(50, 50)
  dirty.beginGroup(tag: 99, opacity: 0.25)
  dirty.fillRect(1, 1, 2, 2)
  dirty.reset()
  build(dirty)

  let fresh = nestingBuilder()
  build(fresh)

  let a = dirty.finish()
  let z = fresh.finish()
  #expect(a.primitives == z.primitives)
  #expect(a.groups == z.groups)
  #expect(a.colorSlots == z.colorSlots)
}
