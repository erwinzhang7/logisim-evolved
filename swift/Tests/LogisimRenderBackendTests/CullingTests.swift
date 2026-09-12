// CullingTests: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// D6 claims the CG backend beats upstream partly because it culls and upstream does not: there
// is no viewport culling and no spatial index anywhere in the 4.1.0 tree, so a repaint costs
// O(all components) whatever is on screen. That is the claim these tests hold to account; if
// culling silently stops working, everything still renders correctly and only the frame time
// regresses, which no rendering test would catch.

import CoreGraphics
import Testing

@testable import LogisimRender
@testable import LogisimRenderBackend

/// A grid of `side x side` little components, 100 units apart: the shape of a real schematic.
private func gridScene(side: Int) -> RenderScene {
  let b = SceneBuilder(measurer: NominalTextMeasurer())
  for row in 0..<side {
    for col in 0..<side {
      b.group(tag: UInt64(row * side + col)) {
        let x = col * 100
        let y = row * 100
        b.drawRect(x, y, 40, 40)
        b.drawLine(x - 10, y + 20, x, y + 20)
        b.drawLine(x + 40, y + 20, x + 50, y + 20)
      }
    }
  }
  return b.finish()
}

@Test func cullingRejectsOffscreenGroups() {
  let scene = gridScene(side: 30)  // 900 components, 2,700 primitives
  #expect(scene.groups.count == 900)
  #expect(scene.primitives.count == 2700)

  // A viewport over the first 2x2 block.
  let visible = SceneBounds(minX: -20, minY: -20, maxX: 160, maxY: 160)
  let groups = scene.visibleGroups(in: visible)
  #expect(groups.count == 4)
  #expect(scene.visiblePrimitiveCount(in: visible) == 12)
}

@Test func cullingIsExactAtTheBoundary() {
  let scene = gridScene(side: 3)
  // Component (1,1) spans x 90...140 including its stubs. A rect ending at x = 89 must miss it.
  let justShort = SceneBounds(minX: 60, minY: 60, maxX: 88, maxY: 200)
  #expect(!scene.visibleGroups(in: justShort).contains(4))

  let justReaching = SceneBounds(minX: 60, minY: 60, maxX: 92, maxY: 200)
  #expect(scene.visibleGroups(in: justReaching).contains(4))
}

@Test func visibleGroupsStayInPaintersOrder() {
  // Ascending order is not cosmetic: a filled body drawn before its label depends on it, and
  // the spatial index visits buckets in row-major order, which is not paint order.
  let scene = gridScene(side: 12)
  let all = scene.visibleGroups(in: .infinite)
  #expect(all == all.sorted())
  #expect(all.count == scene.groups.count)
}

@Test func aFullViewportCullsNothing() {
  let scene = gridScene(side: 8)
  #expect(scene.visiblePrimitiveCount(in: .infinite) == scene.primitives.count)
}

@Test func emptySceneRendersAsANoOp() {
  let scene = RenderScene.empty
  #expect(scene.isEmpty)
  #expect(scene.visibleGroups(in: .infinite).isEmpty)
}

@Test func oversizedGroupsAreAlwaysConsidered() {
  // A group too big to bucket sensibly (a full-canvas background, a selection rectangle) must
  // never be dropped by the index.
  let b = SceneBuilder(measurer: NominalTextMeasurer())
  b.group(tag: 1) { b.drawRect(-100_000, -100_000, 200_000, 200_000) }
  b.group(tag: 2) { b.fillRect(0, 0, 10, 10) }
  let scene = b.finish()
  let hits = scene.visibleGroups(in: SceneBounds(minX: 0, minY: 0, maxX: 5, maxY: 5))
  #expect(hits.contains(0))
  #expect(hits.contains(1))
}

@Test func negativeCoordinatesBucketCorrectly() {
  // Truncating division puts negative offsets one bucket high; if that is not corrected, the
  // whole third quadrant of a schematic disappears.
  let b = SceneBuilder(measurer: NominalTextMeasurer())
  for i in 0..<20 {
    b.group(tag: UInt64(i)) { b.fillRect(-1000 + i * 100, -1000 + i * 100, 20, 20) }
  }
  let scene = b.finish()
  for i in 0..<20 {
    let x = Int32(-1000 + i * 100)
    let probe = SceneBounds(minX: x, minY: x, maxX: x + 20, maxY: x + 20)
    #expect(scene.visibleGroups(in: probe).contains(Int32(i)), "group \(i) lost")
  }
}

// MARK: - The renderer reports it

@Test func rendererCullsAndReportsIt() {
  let scene = gridScene(side: 30)
  let renderer = CoreGraphicsSceneRenderer()
  let context = try! #require(SceneRasterizer.makeContext(width: 150, height: 150))

  let viewport = RenderViewport(
    rect: CGRect(x: 0, y: 0, width: 150, height: 150),
    scale: 1, sceneOriginX: 0, sceneOriginY: 0)
  let stats = renderer.render(scene, into: context, viewport: viewport, options: .default)

  // 150x150 at 1:1 covers components at x,y in {0, 100} plus a unit of slack.
  #expect(stats.groupsDrawn == 4)
  #expect(stats.primitivesDrawn == 12)
  #expect(stats.primitivesCulled == scene.primitives.count - 12)
  // Upstream would have painted all 900 components here, with two Graphics2D clones each.
  #expect(stats.primitivesDrawn < scene.primitives.count / 100)
}

@Test func batchingCollapsesSameStateRunsIntoOneDrawCall() {
  // 253 switchToWidth sites in the Java means a fresh BasicStroke per width change; a
  // component's outline here becomes one CGPath and one stroke.
  let b = SceneBuilder(measurer: NominalTextMeasurer())
  b.group(tag: 1) {
    for i in 0..<50 { b.drawLine(0, i * 2, 100, i * 2) }
  }
  let scene = b.finish()
  let context = try! #require(SceneRasterizer.makeContext(width: 200, height: 200))
  let viewport = RenderViewport(rect: CGRect(x: 0, y: 0, width: 200, height: 200))

  let batched = CoreGraphicsSceneRenderer()
    .render(scene, into: context, viewport: viewport, options: RenderOptions())
  #expect(batched.primitivesDrawn == 50)
  #expect(batched.drawCalls == 1)

  let unbatched = CoreGraphicsSceneRenderer()
    .render(
      scene, into: context, viewport: viewport,
      options: RenderOptions(batchPrimitives: false))
  #expect(unbatched.drawCalls == 50)
}

@Test func aColourChangeBreaksTheBatchSoPaintersOrderSurvives() {
  let b = SceneBuilder(measurer: NominalTextMeasurer())
  b.group(tag: 1) {
    b.color = .rgb(0xFF_0000)
    b.drawLine(0, 0, 10, 0)
    b.color = .rgb(0x00_FF00)
    b.drawLine(0, 10, 10, 10)
    b.color = .rgb(0xFF_0000)
    b.drawLine(0, 20, 10, 20)
  }
  let scene = b.finish()
  let context = try! #require(SceneRasterizer.makeContext(width: 64, height: 64))
  let stats = CoreGraphicsSceneRenderer().render(
    scene, into: context,
    viewport: RenderViewport(rect: CGRect(x: 0, y: 0, width: 64, height: 64)),
    options: .default)
  #expect(stats.drawCalls == 3)
}
