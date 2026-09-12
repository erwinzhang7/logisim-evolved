// TextCacheAndThroughputTests: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// The two performance claims in D6, made checkable.
//
//   1. Text is shaped once per (font, string) for the life of the cache, where upstream
//      re-shapes every label every frame and measures line 0 twice while doing it.
//   2. Culling makes a frame cost O(visible), where upstream's costs O(all components), which
//      is what the 20 fps cap in CanvasPaintCoordinator is defending against.
//
// The thresholds are deliberately loose. These are regression tripwires, not benchmarks: they
// exist so that "the cache quietly stopped working" fails a test instead of showing up as a
// vague report that the canvas feels sticky.

import CoreGraphics
import Foundation
import Testing

@testable import LogisimRender
@testable import LogisimRenderBackend

// MARK: - CoreText metrics

@Test func coreTextMetricsAreIntegerAndCeiledLikeTextMetrics() {
  // com.cburch.draw.util.TextMetrics: ascent/descent/leading are each Math.ceil'd to an int and
  // height is their sum. Rounding anywhere else moves every label vertically.
  let cache = CoreTextCache()
  let m = cache.metrics(for: SceneFont(family: .sansSerif, size: 12))
  #expect(m.ascent > 0)
  #expect(m.descent > 0)
  #expect(m.height == m.ascent + m.descent + m.leading)
}

@Test func metricsScaleWithFontSize() {
  let cache = CoreTextCache()
  let small = cache.metrics(for: SceneFont(family: .sansSerif, size: 10))
  let large = cache.metrics(for: SceneFont(family: .sansSerif, size: 30))
  #expect(large.ascent > small.ascent)
  #expect(large.height > small.height)
}

@Test func widthIsTruncatedNotRounded() {
  // Java: (int) font.getStringBounds(text, frc).getWidth(). Truncation, and it matters: the
  // centring arithmetic divides this by two, so a rounding difference is up to a pixel of
  // horizontal drift on every centred label.
  let cache = CoreTextCache()
  let font = SceneFont(family: .sansSerif, size: 12)
  let w = cache.width(of: "MMMM", font: font)
  #expect(w > 0)
  #expect(cache.width(of: "", font: font) == 0)
  #expect(cache.width(of: "MMMMMMMM", font: font) > w)
}

@Test func boldAndItalicAreDistinctFontsWithDistinctMetrics() {
  let cache = CoreTextCache()
  let plain = SceneFont(family: .sansSerif, size: 18)
  let bold = SceneFont(family: .sansSerif, size: 18, bold: true)
  #expect(cache.width(of: "Hamburgefonstiv", font: bold)
    >= cache.width(of: "Hamburgefonstiv", font: plain))
}

// MARK: - The cache

@Test func aStringIsShapedOnceAndThenReused() {
  let cache = CoreTextCache()
  let font = SceneFont(family: .sansSerif, size: 12)

  _ = cache.line(for: "Q0", font: font)
  let afterFirst = cache.stats
  #expect(afterFirst.misses == 1)

  for _ in 0..<500 { _ = cache.line(for: "Q0", font: font) }
  let afterMany = cache.stats
  #expect(afterMany.misses == 1)  // still one shaping, 500 draws later
  #expect(afterMany.hits >= 500)
  #expect(afterMany.shapedLines == 1)
}

@Test func theCacheKeyIsFontAndStringOnlyNotColour() {
  // Colour comes from the context via kCTForegroundColorFromContextAttribute. If it were part
  // of the key, the cache would miss on exactly the strings that change per frame, which are
  // the only ones that matter (D6).
  let cache = CoreTextCache()
  let font = SceneFont(family: .sansSerif, size: 12)
  _ = cache.line(for: "1010", font: font)
  cache.resetStats()

  let b = SceneBuilder(measurer: CoreTextMeasurer(cache: cache))
  for colour in [SceneColor.rgb(0xFF_0000), .rgb(0x00_FF00), .rgb(0x00_00FF)] {
    b.color = colour
    b.font = font
    b.drawText("1010", x: 10, y: 10)
  }
  let scene = b.finish()

  let context = SceneRasterizer.makeContext(width: 64, height: 64)!
  let stats = CoreGraphicsSceneRenderer(textCache: cache).render(
    scene, into: context,
    viewport: RenderViewport(rect: CGRect(x: 0, y: 0, width: 64, height: 64)),
    options: .default)

  #expect(stats.textRunsDrawn == 3)
  #expect(stats.textCacheMisses == 0)
}

@Test func repaintingASceneReshapesNothing() {
  // The steady state a running simulation lives in: labels are static, only colours move.
  let cache = CoreTextCache()
  let b = SceneBuilder(measurer: CoreTextMeasurer(cache: cache))
  for i in 0..<40 {
    b.group(tag: UInt64(i)) {
      b.font = SceneFont(family: .sansSerif, size: 12)
      b.drawCenteredText("D\(i % 8)", x: (i % 8) * 60 + 30, y: (i / 8) * 40 + 20)
    }
  }
  let scene = b.finish()

  let renderer = CoreGraphicsSceneRenderer(textCache: cache)
  let context = SceneRasterizer.makeContext(width: 512, height: 256)!
  let viewport = RenderViewport(rect: CGRect(x: 0, y: 0, width: 512, height: 256))

  _ = renderer.render(scene, into: context, viewport: viewport, options: .default)
  let second = renderer.render(scene, into: context, viewport: viewport, options: .default)

  #expect(second.textRunsDrawn == 40)
  #expect(second.textCacheMisses == 0)  // zero re-shaping on frame two
  #expect(second.textCacheHits >= 40)
}

@Test func theCacheIsBoundedAndSurvivesOverflow() {
  let cache = CoreTextCache(lineLimit: 64)
  let font = SceneFont(family: .monospaced, size: 11)
  for i in 0..<300 { _ = cache.line(for: "value-\(i)", font: font) }
  #expect(cache.stats.shapedLines <= 64)
  // Still functional afterwards.
  #expect(cache.width(of: "value-0", font: font) > 0)
}

@Test func theCacheIsUsableFromMultipleThreads() {
  // TextMeasurer is Sendable because a scene must be buildable off the main thread.
  let cache = CoreTextCache()
  let font = SceneFont(family: .sansSerif, size: 12)
  DispatchQueue.concurrentPerform(iterations: 64) { i in
    _ = cache.width(of: "label\(i % 8)", font: font)
    _ = cache.metrics(for: font)
  }
  #expect(cache.stats.shapedLines == 8)
}

// MARK: - Throughput

/// A schematic-shaped scene: `count` components on a 100-unit lattice, each a body, four port
/// stubs with a dynamic colour slot, and a label.
private func schematic(count: Int, cache: CoreTextCache) -> (RenderScene, [ColorSlot]) {
  let b = SceneBuilder(measurer: CoreTextMeasurer(cache: cache))
  let side = Int(Double(count).squareRoot().rounded(.up))
  var slots: [ColorSlot] = []
  slots.reserveCapacity(count * 4)
  for i in 0..<count {
    let x = (i % side) * 100
    let y = (i / side) * 100
    b.group(tag: UInt64(i)) {
      b.color = .black
      b.strokeWidth = 2
      b.drawRect(x, y, 50, 40)
      b.font = SceneFont(family: .sansSerif, size: 12)
      b.drawCenteredText("U\(i % 64)", x: x + 25, y: y + 20)
      b.strokeWidth = 3
      for p in 0..<4 {
        let slot = b.reserveColorSlot()
        slots.append(slot)
        b.useColorSlot(slot)
        b.drawLine(x - 10, y + 8 + p * 8, x, y + 8 + p * 8)
      }
    }
  }
  return (b.finish(), slots)
}

@Test func aPerFrameColourUpdateTouchesNoGeometry() {
  // The claim that makes the M9 Metal backend straightforward: a frame is a handful of UInt16
  // writes against buffers that stay resident.
  let cache = CoreTextCache()
  var (scene, slots) = schematic(count: 400, cache: cache)
  let geometry = scene.primitives
  let points = scene.points

  let start = DispatchTime.now().uptimeNanoseconds
  for (i, slot) in slots.enumerated() {
    scene.setColor(slot, to: PaletteIndex(i % 2 == 0 ? .trueValue : .falseValue))
  }
  let elapsedNs = DispatchTime.now().uptimeNanoseconds - start

  #expect(scene.primitives == geometry)
  #expect(scene.points == points)
  #expect(scene.colorSlots.count >= slots.count)
  // 1,600 slot writes should be microseconds, not milliseconds.
  #expect(elapsedNs < 20_000_000, "colour update took \(elapsedNs) ns")
}

@Test func aFiveThousandComponentSchematicCullsToTheViewport() {
  // The size D6 quotes for upstream's ~5,001 Graphics2D clones per frame.
  let cache = CoreTextCache()
  let (scene, _) = schematic(count: 5000, cache: cache)
  #expect(scene.groups.count == 5000)

  let renderer = CoreGraphicsSceneRenderer(textCache: cache)
  let context = SceneRasterizer.makeContext(width: 1280, height: 800)!
  let viewport = RenderViewport(
    rect: CGRect(x: 0, y: 0, width: 1280, height: 800), scale: 1,
    sceneOriginX: 0, sceneOriginY: 0)

  // Warm the text cache, then measure a steady-state frame.
  _ = renderer.render(scene, into: context, viewport: viewport, options: .default)

  let start = DispatchTime.now().uptimeNanoseconds
  let stats = renderer.render(scene, into: context, viewport: viewport, options: .default)
  let ns = DispatchTime.now().uptimeNanoseconds - start

  // A 1280x800 window at 1:1 sees a small fraction of a 71x71 lattice.
  #expect(stats.groupsDrawn < 200)
  #expect(stats.primitivesCulled > scene.primitives.count * 9 / 10)
  #expect(stats.textCacheMisses == 0)
  // Upstream would clone 10,000 Graphics2D objects and repaint all 5,000 components here.
  // 16.6 ms is one display frame; this should be far inside it.
  print("[throughput] 5,000-component schematic, 1280x800 viewport: \(Double(ns) / 1e6) ms/frame, \(stats.groupsDrawn) groups drawn, \(stats.drawCalls) draw calls")
  #expect(ns < 16_000_000, "steady-state frame took \(Double(ns) / 1e6) ms")
}

@Test func anUncullableFullViewRemainsBounded() {
  // Zoomed all the way out, nothing culls: the honest worst case, and the one upstream pays
  // on every frame at every zoom.
  let cache = CoreTextCache()
  let (scene, _) = schematic(count: 2000, cache: cache)
  let renderer = CoreGraphicsSceneRenderer(textCache: cache)
  let context = SceneRasterizer.makeContext(width: 1280, height: 800)!
  let viewport = RenderViewport.fitting(
    scene.bounds, in: CGRect(x: 0, y: 0, width: 1280, height: 800), margin: 8)

  _ = renderer.render(scene, into: context, viewport: viewport, options: .default)
  let start = DispatchTime.now().uptimeNanoseconds
  let stats = renderer.render(scene, into: context, viewport: viewport, options: .default)
  let ns = DispatchTime.now().uptimeNanoseconds - start

  #expect(stats.groupsDrawn == 2000)
  #expect(stats.textCacheMisses == 0)
  print("[throughput] 2,000-component schematic, zoomed to fit (nothing culls): \(Double(ns) / 1e6) ms/frame, \(stats.drawCalls) draw calls")
  #expect(ns < 500_000_000, "full-view frame took \(Double(ns) / 1e6) ms")
}
