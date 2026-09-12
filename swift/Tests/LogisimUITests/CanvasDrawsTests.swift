// LogisimUITests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// DOES THE CANVAS ACTUALLY DRAW?
//
// This suite exists because "it compiles and runs" has twice been true of a canvas that drew
// nothing:
//
//   1. `CircuitRenderer` was written with a `builder.reset()` per component. `reset()` clears
//      the whole scene, not the pen state, so six components "painted" and zero primitives came
//      out. It compiled, it ran, and every assertion about the walker passed.
//   2. `CircuitRenderer` then emitted a complete scene that nothing in `LogisimUI` ever called;
//      `grep -rn CircuitRenderer Sources/LogisimUI` returned nothing at all.
//
// Neither is visible to a build, to a scene-level unit test, or to a test that only counts
// primitives. So this suite goes all the way to pixels: it builds a scene from a real circuit,
// rasterises it offscreen, and asserts that ink landed on the bitmap.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import CoreGraphics
import ImageIO
import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimRenderBackend
import LogisimStd
import Testing

@testable import LogisimUI

// MARK: - Fixtures

/// A small circuit assembled from the real builtin factories; the same objects a loaded
/// `.circ` produces, minus the codec. Deliberately not a mock: the thing under test is whether
/// the *actual* `paintInstance` implementations reach the *actual* backend.
@MainActor
private func demoCircuit() throws -> Circuit {
  StdLibraries.registerAll()
  let circuit = try Circuit(name: "canvas-gate")

  func place(_ factory: any ComponentFactory, _ x: Int, _ y: Int) throws {
    let attributes = factory.createAttributeSet()
    let component = try factory.createComponent(
      location: Location.create(x, y, hasToSnap: false), attributes: attributes)
    try circuit.mutatorAdd(component)
  }

  try place(AndGate.factory, 120, 100)
  try place(OrGate.factory, 120, 180)
  try place(NotGate.factory, 220, 100)

  try circuit.mutatorAdd(
    Wire.create(Location.create(60, 90, hasToSnap: false), Location.create(120, 90, hasToSnap: false)))
  try circuit.mutatorAdd(
    Wire.create(Location.create(60, 110, hasToSnap: false), Location.create(120, 110, hasToSnap: false)))
  try circuit.mutatorAdd(
    Wire.create(Location.create(120, 100, hasToSnap: false), Location.create(220, 100, hasToSnap: false)))
  // Deliberately clear of every gate body. A gate's location is its *output* pin and the body
  // extends behind it, so a wire drawn into an input runs underneath the gate it feeds, which
  // is realistic, and useless for asserting that wires are hittable at all.
  try circuit.mutatorAdd(
    Wire.create(Location.create(400, 300, hasToSnap: false), Location.create(500, 300, hasToSnap: false)))

  return circuit
}

/// Fraction of pixels that differ from the background. `SceneBitmap` gives raw sRGB bytes, so
/// "did anything draw" is answerable without any tolerance games.
private func inkedPixelCount(_ bitmap: SceneBitmap, background: LogisimRender.RGBA) -> Int {
  var count = 0
  for y in 0..<bitmap.height {
    for x in 0..<bitmap.width {
      let p = bitmap.pixel(x: x, y: y)
      if p.r != background.r || p.g != background.g || p.b != background.b { count += 1 }
    }
  }
  return count
}

private func writePNG(_ image: CGImage, to url: URL) {
  guard
    let destination = CGImageDestinationCreateWithURL(
      url as CFURL, "public.png" as CFString, 1, nil)
  else { return }
  CGImageDestinationAddImage(destination, image, nil)
  CGImageDestinationFinalize(destination)
  print("canvas corpus gate: wrote \(url.path)")
}

private func corpusDirectory() -> URL? {
  guard let path = ProcessInfo.processInfo.environment["LOGISIM_CORPUS"] else { return nil }
  var isDirectory: ObjCBool = false
  guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
    isDirectory.boolValue
  else { return nil }
  return URL(fileURLWithPath: path)
}

// MARK: - The gate

@Suite("Canvas draws")
struct CanvasDrawsTests {

  @Test("a built scene is not empty")
  @MainActor
  func sceneIsNotEmpty() throws {
    let circuit = try demoCircuit()
    let build = CircuitSceneSource.build(circuit: circuit, appearance: CanvasAppearance())

    #expect(build.components.count == 7)
    #expect(build.targets.count == 7)
    #expect(build.wireSegments.count == 4)
    // The failure mode this catches: a walker that reports having painted components while
    // emitting no geometry.
    #expect(build.paintedComponentCount > 0)
    #expect(!build.scene.isEmpty)
    #expect(build.scene.primitives.count > 0)
    #expect(!build.contentBounds.isNull)
  }

  @Test("the rasterised canvas is not blank")
  @MainActor
  func rasterIsNotBlank() throws {
    let circuit = try demoCircuit()
    var appearance = CanvasAppearance()
    appearance.antialiasing = false
    let build = CircuitSceneSource.build(circuit: circuit, appearance: appearance)

    let world = build.contentBounds.insetBy(dx: -20, dy: -20)
    let raster = try #require(
      CircuitSceneRasterizer.bitmap(
        build: build, worldRect: world, scale: 2, appearance: appearance))

    #expect(raster.stats.primitivesDrawn > 0)
    let background = appearance.palette[.canvasBackground].sceneRGBA
    let inked = inkedPixelCount(raster.bitmap, background: background)
    // A blank frame is the whole point of this suite. The threshold is deliberately low;
    // the assertion is "ink exists", not "ink looks a particular way".
    #expect(inked > 200, "rasterised canvas was blank: \(inked) inked pixels")
  }

  @Test("a CGImage snapshot comes back at the requested size")
  @MainActor
  func snapshotImage() throws {
    let circuit = try demoCircuit()
    let surface = CircuitCanvasSurface()
    surface.setAppearance(CanvasAppearance())
    surface.setCircuit(circuit)

    let world = surface.contentBounds.insetBy(dx: -10, dy: -10)
    let image = try #require(
      surface.snapshotImage(worldRect: world, scale: 2, appearance: CanvasAppearance()))
    #expect(image.width == Int((Double(world.width) * 2).rounded(.up)))
    #expect(image.height == Int((Double(world.height) * 2).rounded(.up)))
  }

  // MARK: Culling

  @Test("the scene culls to the viewport instead of drawing everything")
  @MainActor
  func cullsToViewport() throws {
    let circuit = try demoCircuit()
    let build = CircuitSceneSource.build(circuit: circuit, appearance: CanvasAppearance())

    let everything = build.scene.visiblePrimitiveCount(in: SceneBounds.infinite)
    // A window over the left-hand wires only.
    let corner = build.scene.visiblePrimitiveCount(
      in: SceneBounds(minX: 55, minY: 85, maxX: 95, maxY: 115))
    #expect(everything > 0)
    #expect(corner < everything, "culling did nothing: \(corner) of \(everything)")
  }

  // MARK: Hit testing

  @Test("a hit maps back to the component through the walker's tag, not a second walk")
  @MainActor
  func hitTestingRoundTrips() throws {
    let circuit = try demoCircuit()
    let surface = CircuitCanvasSurface()
    surface.setAppearance(CanvasAppearance())
    surface.setCircuit(circuit)

    let components = circuit.components
    // Every non-wire component must be findable at the centre of its own bounds.
    for (index, component) in components.enumerated() where !(component is Wire) {
      let box = component.bounds
      let centre = CGPoint(
        x: Double(box.x) + Double(box.width) / 2,
        y: Double(box.y) + Double(box.height) / 2)
      let hit = surface.hitTest(worldPoint: centre, tolerance: 2)
      #expect(hit != nil, "no hit at the centre of \(component.factory.name)")
      if let hit {
        #expect(
          hit.id == CircuitSceneSource.identity(of: component),
          "tag \(index + 1) mapped to the wrong component")
      }
    }

    // A point in open space hits nothing.
    #expect(surface.hitTest(worldPoint: CGPoint(x: -500, y: -500), tolerance: 2) == nil)
  }

  @Test("a wire is hittable within tolerance and unhittable outside it")
  @MainActor
  func wireHitTesting() throws {
    let circuit = try demoCircuit()
    let surface = CircuitCanvasSurface()
    surface.setAppearance(CanvasAppearance())
    surface.setCircuit(circuit)

    // Midpoint of the isolated wire, which runs (400,300) → (500,300).
    let onWire = surface.hitTest(worldPoint: CGPoint(x: 450, y: 300), tolerance: 3)
    #expect(onWire?.kind == .wire)

    // Ten units off it, with a three-unit tolerance: nothing at all.
    #expect(surface.hitTest(worldPoint: CGPoint(x: 450, y: 310), tolerance: 3) == nil)

    // A wire that runs under a gate body loses to the gate; draw order is wires first, so the
    // component is on top and must win the click.
    #expect(surface.hitTest(worldPoint: CGPoint(x: 90, y: 90), tolerance: 3)?.kind == .component)
  }

  @Test("a marquee returns everything it crosses")
  @MainActor
  func marqueeHitTesting() throws {
    let circuit = try demoCircuit()
    let surface = CircuitCanvasSurface()
    surface.setAppearance(CanvasAppearance())
    surface.setCircuit(circuit)

    let all = surface.hitTest(worldRect: surface.contentBounds.insetBy(dx: -50, dy: -50))
    #expect(all.count >= 3)
    #expect(surface.hitTest(worldRect: CGRect(x: -900, y: -900, width: 10, height: 10)).isEmpty)
  }

  // MARK: Appearance

  @Test("a palette-only appearance change does not rebuild geometry")
  @MainActor
  func paletteSwapDoesNotRebuild() throws {
    let circuit = try demoCircuit()
    let surface = CircuitCanvasSurface()
    var appearance = CanvasAppearance()
    surface.setAppearance(appearance)
    surface.setCircuit(circuit)

    let before = surface.build.scene.primitives.count
    #expect(before > 0)

    // Everything here is render-time or overlay-time. None of it may cost a walk of the
    // circuit; `setAppearance` runs on every SwiftUI update pass.
    appearance.backingScale = 2
    appearance.showGrid = false
    appearance.antialiasing = false
    appearance.showsTickMarkers = true
    appearance.showsAttentionHalo = false
    surface.setAppearance(appearance)

    #expect(surface.build.scene.primitives.count == before)
    #expect(surface.build.targets.count == 7)
  }

  @Test("the value theme is re-resolved from the live palette — #2661")
  @MainActor
  func themeFollowsPalette() {
    let light = CircuitSceneSource.theme(for: .light)
    let dark = CircuitSceneSource.theme(for: .dark)
    // If either side were frozen into a static, which is exactly what `Value.java` does and
    // exactly why upstream's canvas text ignores the dark/light switch, these would agree.
    #expect(light[.trueValue] != dark[.trueValue] || light[.nilValue] != dark[.nilValue])
  }

  @Test("a light/dark flip changes the pixels — #2661")
  @MainActor
  func darkModeChangesThePixels() throws {
    let circuit = try demoCircuit()
    let surface = CircuitCanvasSurface()

    var light = CanvasAppearance()
    light.antialiasing = false
    light.palette = .light
    surface.setAppearance(light)
    surface.setCircuit(circuit)
    let world = surface.contentBounds.insetBy(dx: -10, dy: -10)
    let lightRaster = try #require(
      CircuitSceneRasterizer.bitmap(
        build: surface.build, worldRect: world, scale: 1, appearance: light))

    var dark = light
    dark.palette = .dark
    surface.setAppearance(dark)
    let darkRaster = try #require(
      CircuitSceneRasterizer.bitmap(
        build: surface.build, worldRect: world, scale: 1, appearance: dark))

    // Upstream freezes these colours into `static Color` fields at class-init, so its canvas
    // renders identically in both appearances; that is the whole of issue #2661.
    #expect(lightRaster.bitmap.pixels != darkRaster.bitmap.pixels)
    // And the schematic is still there afterwards: a theme switch must not empty the canvas.
    #expect(surface.build.scene.primitives.count > 0)
  }

  @Test("the backing scale reaches the render viewport")
  @MainActor
  func backingScaleReachesTheViewport() {
    let view = CircuitSceneView()
    view.frame = CGRect(x: 0, y: 0, width: 400, height: 300)

    var appearance = CanvasAppearance()
    appearance.backingScale = 2
    view.appearance_ = appearance
    // The half-wired seam this task was asked to finish: `CanvasAppearance.backingScale` was
    // set from `window.backingScaleFactor` and `RenderViewport.backingScale` existed, and
    // nothing joined them, so every render ran at the default 1 and `GridSnap`'s odd-pen test
    // ran on points instead of device pixels.
    #expect(view.renderViewport.backingScale == 2)
    #expect(view.renderViewport.deviceScale == view.renderViewport.scale * 2)
    #expect(view.renderViewport.yAxisPointsDown)

    appearance.backingScale = 1
    view.appearance_ = appearance
    #expect(view.renderViewport.backingScale == 1)
  }

  // MARK: Corpus

  @Test("a real corpus circuit rasterises to something non-blank")
  @MainActor
  func corpusFileDraws() throws {
    guard let corpus = corpusDirectory() else {
      print("LOGISIM_CORPUS unset — canvas corpus gate skipped")
      return
    }
    StdLibraries.registerAll()

    // The largest circuit in the first handful of files that loads and has components: the
    // point is to exercise a real file, not a particular one.
    let files = (FileManager.default.enumerator(at: corpus, includingPropertiesForKeys: nil)?
      .compactMap { $0 as? URL }
      .filter { $0.pathExtension == "circ" }
      .sorted { $0.path < $1.path } ?? [])
    guard !files.isEmpty else {
      print("LOGISIM_CORPUS has no .circ files — canvas corpus gate skipped")
      return
    }

    // The `file` is kept deliberately: holding only the winning `Circuit` releases every OTHER
    // circuit in that file, including the subcircuits the winner places, and the `unowned` D3
    // back-edges on `CircuitSubcircuitFactory.source` / `CircuitAppearance.circuit` then trap
    // during paint. See the full account in `IoPaintSeamTests.corpusIoPaints`, where this shape
    // took down the whole test binary.
    var best: (name: String, file: LogisimFile, circuit: Circuit, build: CircuitSceneBuild)?
    for url in files.prefix(40) {
      guard let file = try? Loader().openLogisimFile(url) else { continue }
      for circuit in file.circuits where !circuit.components.isEmpty {
        let build = CircuitSceneSource.build(circuit: circuit, appearance: CanvasAppearance())
        if build.scene.primitives.count > (best?.build.scene.primitives.count ?? 0) {
          best = ("\(url.lastPathComponent)/\(circuit.name)", file, circuit, build)
        }
      }
      if (best?.build.scene.primitives.count ?? 0) > 200 { break }
    }

    let chosen = try #require(best, "no corpus circuit produced any geometry at all")
    var appearance = CanvasAppearance()
    appearance.antialiasing = false

    #expect(chosen.build.paintedComponentCount > 0)
    #expect(chosen.build.scene.primitives.count > 0)

    let world = chosen.build.contentBounds.insetBy(dx: -20, dy: -20)
    let raster = try #require(
      CircuitSceneRasterizer.bitmap(
        build: chosen.build, worldRect: world, scale: 1, appearance: appearance))
    let inked = inkedPixelCount(
      raster.bitmap, background: appearance.palette[.canvasBackground].sceneRGBA)
    #expect(
      inked > 200,
      "\(chosen.name): \(chosen.build.scene.primitives.count) primitives rasterised to \(inked) inked pixels")
    print(
      "canvas corpus gate: \(chosen.name) — \(chosen.build.components.count) components, "
        + "\(chosen.build.scene.primitives.count) primitives, \(inked) inked pixels")

    // An inked-pixel count proves the canvas is not blank; it does not prove the schematic is
    // *right*. Set LOGISIM_CANVAS_DUMP to a directory to get the PNG out and look at it; the
    // cheapest possible check that the geometry is a circuit and not confetti.
    if let dump = ProcessInfo.processInfo.environment["LOGISIM_CANVAS_DUMP"] {
      let root = URL(fileURLWithPath: dump)
      if let image = CircuitSceneRasterizer.image(
        build: chosen.build, worldRect: world, scale: 2, appearance: appearance)
      {
        writePNG(image, to: root.appendingPathComponent("canvas-gate.png"))
      }
      var dark = appearance
      dark.palette = .dark
      if let image = CircuitSceneRasterizer.image(
        build: CircuitSceneSource.build(circuit: chosen.circuit, appearance: dark),
        worldRect: world, scale: 2, appearance: dark)
      {
        writePNG(image, to: root.appendingPathComponent("canvas-gate-dark.png"))
      }
    }
  }
}
