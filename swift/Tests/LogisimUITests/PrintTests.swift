// LogisimUITests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// PRINT, WITHOUT A PRINTER, and the Export Image finding that came with it.
//
// Board #90 found four Settings controls bound to preferences that nothing read. This board
// asked whether File ▸ Export Image is the same shape of hole before building Print. **It is**,
// and §0 below is the standing proof: the menu item exists (`AppCommands.swift:71`), its
// enablement predicate says yes, and performing it throws `notImplemented`, which the shell
// turns into a "Command unavailable" banner. No file is ever written. §0 asserts both halves so
// that whoever wires it cannot leave the enablement lying.
//
// The rest of the file is Print. Everything asserted here is asserted on the SCENE or on the
// RASTERISED PIXELS, never on `NSPrintOperation`:
//
//   §1  the header template, against `Print.format`'s three preserved quirks
//   §2  the page arithmetic, against `MyPrintable.print` line by line
//   §3  the print scene really differs from the screen scene: in primitive count AND in pixels
//   §4  a rasterised page actually has ink on it, inside the imageable box and nowhere else
//   §5  the rotate-to-fit transform is a rotation and not a mirror
//
// §3 is the one that matters. "An `NSPrintOperation` was created" passes against a version that
// prints a blank page, and "`isPrintView` was passed" passes against a version where the flag is
// read by nothing. Counting the primitives that disappear is the only assertion that can tell
// the difference.

import CoreGraphics
import CoreText
import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimRenderBackend
import LogisimStd
import Testing
import UniformTypeIdentifiers

@testable import LogisimUI

// MARK: - Fixture

/// Shaped gates with UNCONNECTED inputs, which is what makes the print/screen difference
/// visible: `AbstractGate.paintInstance` drops `drawPorts()` in print view unless the gate is
/// rectangular, and `PainterShaped.paintInputLines` drops an input lead whose port is not
/// connected. A circuit of fully-wired rectangular gates would legitimately look identical in
/// both views, and a test built on one would be green for the wrong reason.
@MainActor
private func printDemoCircuit() throws -> Circuit {
  StdLibraries.registerAll()
  let circuit = try Circuit(name: "print-demo")

  func place(_ factory: any ComponentFactory, _ x: Int, _ y: Int) throws {
    let attributes = factory.createAttributeSet()
    let component = try factory.createComponent(
      location: Location.create(x, y, hasToSnap: false), attributes: attributes)
    try circuit.mutatorAdd(component)
  }

  try place(AndGate.factory, 120, 100)
  try place(OrGate.factory, 120, 180)
  try place(NotGate.factory, 220, 100)
  try place(AndGate.factory, 220, 260)

  try circuit.mutatorAdd(
    Wire.create(
      Location.create(120, 100, hasToSnap: false),
      Location.create(220, 100, hasToSnap: false)))
  return circuit
}

/// Pixels that are not the background colour.
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

/// US Letter's imageable area at the AppKit default half-inch margin: 612x792 less 2x36.
private let letterImageable = CGRect(x: 36, y: 36, width: 540, height: 720)

@Suite("Print — the page, the scene, and Export Image's missing arm")
struct PrintTests {

  // ═══════════════════════════════════════════════════════════════════════════════════════════
  // §0. THE FINDING: File ▸ Export Image is inert.
  // ═══════════════════════════════════════════════════════════════════════════════════════════

  /// `AppCommands.swift:71` puts an enabled "Export Image…" item in the File menu bound to
  /// `.exportImage`. `LogisimFileProjectHost.perform` has no arm for it, so it falls to the
  /// `default:` at `:1291` and throws `notImplemented`; `EditorModel.perform` catches that and
  /// appends a "Command unavailable" issue. The user clicks, gets a banner, and no image is
  /// written anywhere.
  ///
  /// Both halves are asserted. Enablement saying "yes" while `perform` says "no" is the actual
  /// defect; a permanently-unsupported command is supposed to report `false` from
  /// `canPerform`, which is what `.loadJarLibrary` and `.revertAppearance` already do.
  @Test("File ▸ Export Image is enabled and does nothing — it throws notImplemented")
  @MainActor
  func exportImageIsInert() throws {
    let host = try LogisimFileProjectHostFactory().makeEmptyProject()

    #expect(
      host.canPerform(.exportImage) == true,
      "the menu item is enabled, which is why this is a defect and not a gap")

    var thrown: Error?
    do { try host.perform(.exportImage) } catch { thrown = error }
    let error = try #require(thrown, "Export Image silently succeeded — did someone wire it?")
    guard case ProjectHostError.notImplemented(let what) = error else {
      Issue.record("expected .notImplemented, got \(error)")
      return
    }
    #expect(what.contains("exportImage"))
  }

  /// The seam Export Image needs already exists and already works, which is why the arm is the
  /// whole fix: `CircuitRenderSurface.snapshotImage` (`RenderSeam.swift:243`, "for File ▸ Export
  /// Image and for Print") is implemented by `CircuitCanvasSurface` and returns real pixels.
  /// Asserted here so the report's claim "one arm away" is measured, not assumed.
  @Test("…even though the render seam it needs already returns a real image")
  @MainActor
  func snapshotSeamAlreadyWorks() throws {
    let circuit = try printDemoCircuit()
    let surface = CircuitCanvasSurface()
    surface.setAppearance(CanvasAppearance())
    surface.setCircuit(circuit)
    let world = surface.contentBounds.insetBy(dx: -10, dy: -10)
    let image = try #require(
      surface.snapshotImage(worldRect: world, scale: 2, appearance: CanvasAppearance()))
    #expect(image.width > 0 && image.height > 0)
  }

  // ═══════════════════════════════════════════════════════════════════════════════════════════
  // §1. `Print.format`, the header template.
  // ═══════════════════════════════════════════════════════════════════════════════════════════

  @Test("the seeded template substitutes name, page and count")
  func defaultTemplateSubstitutes() {
    #expect(
      PrintHeaderFormat.format(
        PrintHeaderFormat.defaultTemplate, index: 2, max: 5, circuitName: "main")
        == "main (2 of 5)")
  }

  /// The three behaviours a rewrite loses. Each is reachable by typing into upstream's own
  /// header field.
  @Test("a trailing %, an unknown escape and a %-free template are all preserved verbatim")
  func formatQuirks() {
    // 1. `mark + 1 < header.length()` fails, so the loop never runs and the tail appends the %.
    #expect(PrintHeaderFormat.format("page %", index: 1, max: 1, circuitName: "c") == "page %")
    // 2. `default -> ret.append("%").append(c)` keeps the % as well as the letter.
    #expect(PrintHeaderFormat.format("%q%n", index: 1, max: 1, circuitName: "c") == "%qc")
    // 3. `indexOf('%') < 0` returns the argument by identity.
    #expect(PrintHeaderFormat.format("plain", index: 1, max: 1, circuitName: "c") == "plain")
    // 4. `%%` is a literal percent.
    #expect(PrintHeaderFormat.format("100%%", index: 1, max: 1, circuitName: "c") == "100%")
    // 5. A lone `%` is the whole string.
    #expect(PrintHeaderFormat.format("%", index: 1, max: 1, circuitName: "c") == "%")
  }

  // ═══════════════════════════════════════════════════════════════════════════════════════════
  // §2. `MyPrintable.print`'s arithmetic.
  // ═══════════════════════════════════════════════════════════════════════════════════════════

  /// **A small circuit is NOT enlarged.** `if (scale < 1.0)` gates the only `g2.scale` call, so
  /// a 100x100 schematic on a 540x720 sheet prints at 1:1 and floats in the middle of the page.
  /// A "fit to page" implementation would blow it up to 5.4x: visibly different output, and the
  /// single most likely thing for a reimplementation to get wrong.
  @Test("a circuit smaller than the page prints at 1:1, not enlarged")
  func smallCircuitIsNotEnlarged() {
    let plan = PrintPageLayout.plan(
      imageable: letterImageable.size,
      circuitBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
      headerHeight: 0,
      rotateToFit: true)

    #expect(plan.fittedScale == 5.4)  // min(540/100, 720/100)
    #expect(plan.scale == 1.0)
    #expect(plan.rotation == .upright)
    #expect(plan.circuitRect.width == 100)
    #expect(plan.circuitRect.height == 100)
  }

  /// Horizontally centred, vertically TOP-aligned: `dx = max(0, (imWidth - bds.width)/2)` and
  /// there is no `dy` at all. On the 540-wide sheet above, `(540 - 100)/2 == 220`.
  @Test("placement is horizontally centred and vertically top-aligned — there is no dy")
  func placementIsCentredHorizontallyOnly() {
    let plan = PrintPageLayout.plan(
      imageable: letterImageable.size,
      circuitBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
      headerHeight: 0,
      rotateToFit: false)
    #expect(plan.circuitRect.minX == 220)
    #expect(plan.circuitRect.minY == 0)
  }

  /// The header eats height off the top and nothing else. `circuitRect.y == headerHeight`, and
  /// the fit divides by `(imHeight - headHeight)`.
  @Test("the header consumes height from the top of the content area")
  func headerConsumesTopOfPage() {
    let plan = PrintPageLayout.plan(
      imageable: letterImageable.size,
      circuitBounds: CGRect(x: 0, y: 0, width: 1080, height: 1080),
      headerHeight: 20,
      rotateToFit: false)
    #expect(plan.circuitRect.minY == 20)
    // min(540/1080, (720-20)/1080) = min(0.5, 0.648…) = 0.5
    #expect(plan.scale == 0.5)
    #expect(plan.circuitRect.height == 540)
  }

  /// The rotate branch is gated TWICE. A circuit that fits at 0.95 is above `1/1.1 == 0.909…`
  /// and must stay upright even though rotating would fit it better.
  @Test("rotate-to-fit does not trigger when the upright fit is already good")
  func rotateGateOne() {
    // 540/560 = 0.964, 720/100 = 7.2 -> upright scale 0.964 > 1/1.1
    let plan = PrintPageLayout.plan(
      imageable: letterImageable.size,
      circuitBounds: CGRect(x: 0, y: 0, width: 560, height: 100),
      headerHeight: 0,
      rotateToFit: true)
    #expect(plan.rotation == .upright)
  }

  /// …and it does not trigger when rotating buys less than another 10% (`scale2 >= scale * 1.1`).
  /// A square circuit gains nothing at all from a quarter turn.
  @Test("rotate-to-fit does not trigger when the turn buys less than 10%")
  func rotateGateTwo() {
    let plan = PrintPageLayout.plan(
      imageable: letterImageable.size,
      circuitBounds: CGRect(x: 0, y: 0, width: 2000, height: 2000),
      headerHeight: 0,
      rotateToFit: true)
    // upright: min(540/2000, 720/2000) = 0.27 ; rotated: min(720/2000, 540/2000) = 0.27
    #expect(plan.rotation == .upright)
    #expect(plan.scale == 0.27)
  }

  /// A wide, short circuit on a portrait sheet: the turn is worth taking, the sheet is taller
  /// than it is wide, so `imHeight > imWidth` selects the portrait branch, and the imageable
  /// size is transposed.
  @Test("a wide circuit on a portrait sheet takes the quarter turn and transposes the frame")
  func rotateTriggersAndTransposes() {
    let plan = PrintPageLayout.plan(
      imageable: letterImageable.size,
      circuitBounds: CGRect(x: 0, y: 0, width: 1400, height: 100),
      headerHeight: 0,
      rotateToFit: true)
    // upright: min(540/1400, 720/100) = 0.3857 ; rotated: min(720/1400, 540/100) = 0.5143
    // 0.5143 >= 0.3857 * 1.1 = 0.4243, and 0.3857 < 1/1.1, so it rotates.
    #expect(plan.rotation == .portraitToLandscape)
    #expect(abs(plan.scale - 720.0 / 1400.0) < 1e-12)
    #expect(plan.imageableSize == CGSize(width: 720, height: 540))
  }

  /// Upstream subtracts the header from the PRE-swap width when testing the rotated fit
  /// (`(imWidth - headHeight) / bds.getHeight()`), because that dimension becomes the post-swap
  /// height. Reading it as a typo and using `imHeight` instead changes which circuits rotate;
  /// this pins the version that is actually in 4.1.0.
  @Test("the rotated fit subtracts the header from the pre-swap width, as 4.1.0 does")
  func rotatedFitUsesPreSwapWidth() {
    let plan = PrintPageLayout.plan(
      imageable: letterImageable.size,
      circuitBounds: CGRect(x: 0, y: 0, width: 1400, height: 100),
      headerHeight: 40,
      rotateToFit: true)
    // scale2 = min(720/1400, (540 - 40)/100) = min(0.5143, 5.0) = 0.5143; the header came off
    // the 540, not off the 720. Had it come off the 720 the first term would be 0.4857.
    #expect(abs(plan.fittedScale - 720.0 / 1400.0) < 1e-12)
  }

  /// An empty circuit has a zero-extent box and upstream divides by zero. Java gets `Infinity`,
  /// `if (scale < 1.0)` declines to apply it, and a blank page comes out. Same here, flagged.
  @Test("an empty circuit is degenerate rather than a crash or a NaN transform")
  func emptyCircuitIsDegenerate() {
    let plan = PrintPageLayout.plan(
      imageable: letterImageable.size,
      circuitBounds: .zero,
      headerHeight: 0,
      rotateToFit: true)
    #expect(plan.isDegenerate)
    #expect(plan.scale == 1)
  }

  // ═══════════════════════════════════════════════════════════════════════════════════════════
  // §3. THE ONE THAT MATTERS: the print scene is not the screen scene.
  // ═══════════════════════════════════════════════════════════════════════════════════════════

  /// `isPrintView` is read by six paint paths. With shaped gates whose inputs are unconnected,
  /// turning it on drops every port marker (`AbstractGate.paintInstance:612`) and every
  /// unconnected input lead (`PainterShaped.paintInputLines:300`). If this comes back EQUAL, one
  /// of two things is true and the test cannot tell you which: the flag never reached the
  /// painters, or the painters do not consult it. Either way, go and look.
  @Test("the print scene has strictly fewer primitives than the screen scene")
  @MainActor
  func printSceneDiffersFromScreenScene() throws {
    let circuit = try printDemoCircuit()
    let appearance = CanvasAppearance()

    let screen = CircuitPrintScene.build(
      circuit: circuit, appearance: appearance, printView: false)
    let printed = CircuitPrintScene.build(
      circuit: circuit, appearance: appearance, printView: true)

    #expect(screen.paintedComponentCount == printed.paintedComponentCount)
    #expect(screen.paintedComponentCount > 0, "the walker painted nothing — the join is broken")
    #expect(!screen.scene.isEmpty)
    #expect(!printed.scene.isEmpty, "print view emitted an EMPTY scene — a blank page")

    #expect(
      printed.scene.primitives.count < screen.scene.primitives.count,
      """
      print view emitted \(printed.scene.primitives.count) primitives and the screen scene \
      emitted \(screen.scene.primitives.count). Equal means isPrintView reached nothing.
      """)
  }

  /// …and the difference survives to the paper. A primitive count can move without a single
  /// pixel changing (a zero-length line, a fully-clipped shape), so the same two scenes are
  /// rasterised at the same viewport and their ink is compared.
  @Test("the difference is visible in pixels, not only in the primitive count")
  @MainActor
  func printSceneDiffersInPixels() throws {
    let circuit = try printDemoCircuit()
    var appearance = CanvasAppearance()
    appearance.antialiasing = false
    let background = LogisimRender.RGBA(r: 255, g: 255, b: 255)

    let screen = CircuitPrintScene.build(
      circuit: circuit, appearance: appearance, printView: false)
    let printed = CircuitPrintScene.build(
      circuit: circuit, appearance: appearance, printView: true)

    func ink(_ page: CircuitPrintScene) throws -> Int {
      let width = Int(page.bounds.width * 2)
      let height = Int(page.bounds.height * 2)
      let raster = try #require(
        SceneRasterizer.render(
          page.scene, width: width, height: height,
          viewport: RenderViewport(
            rect: CGRect(x: 0, y: 0, width: width, height: height),
            scale: 2,
            sceneOriginX: Double(page.bounds.minX),
            sceneOriginY: Double(page.bounds.minY),
            yAxisPointsDown: false),
          options: RenderOptions(background: background)))
      return inkedPixelCount(raster.bitmap, background: background)
    }

    let screenInk = try ink(screen)
    let printInk = try ink(printed)

    #expect(printInk > 0, "print view rasterised to a blank page")
    #expect(
      printInk < screenInk,
      "print view inked \(printInk) pixels and the screen scene \(screenInk) — expected fewer")
  }

  // ═══════════════════════════════════════════════════════════════════════════════════════════
  // §4. A whole page, rasterised.
  // ═══════════════════════════════════════════════════════════════════════════════════════════

  /// `CircuitPrintPage.draw` into an offscreen bitmap the size of a US Letter sheet. Asserts
  /// that ink lands, that it lands INSIDE the imageable box, and that the margins stay clean;
  /// the three ways a page transform goes wrong that a "did it draw?" check cannot separate.
  @Test("a rasterised page has ink, inside the imageable area, with clean margins")
  @MainActor
  func pageRasterisesWithinTheImageableArea() throws {
    let circuit = try printDemoCircuit()
    var appearance = CanvasAppearance()
    appearance.antialiasing = false
    let page = CircuitPrintScene.build(circuit: circuit, appearance: appearance, printView: true)

    let sheet = CGSize(width: 612, height: 792)
    let context = try #require(
      SceneRasterizer.makeContext(width: Int(sheet.width), height: Int(sheet.height)))
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(origin: .zero, size: sheet))

    let layout = CircuitPrintPage.draw(
      page, into: context, imageable: letterImageable,
      header: "print-demo (1 of 1)", rotateToFit: true, appearance: appearance)

    #expect(layout.rotation == .upright)
    #expect(!layout.isDegenerate)

    let image = try #require(context.makeImage())
    let bitmap = try #require(bitmapOf(image))
    let background = LogisimRender.RGBA(r: 255, g: 255, b: 255)

    let total = inkedPixelCount(bitmap, background: background)
    #expect(total > 400, "the page is blank: \(total) inked pixels")

    // …but `total` alone is NOT enough, and a probe proved it: with the scene render removed
    // entirely the header's own glyphs still put 394 pixels on the sheet, which nearly cleared
    // the threshold. So the SCHEMATIC's contribution is counted separately, in the band below
    // the header, where only the circuit can draw. That band is what goes to 0 on a blank page.
    let headerRows = Int(PrintPageMetrics.standard().height.rounded(.up))
    var belowHeader = 0
    for y in (36 + headerRows)..<756 {
      for x in 36..<576 {
        let p = bitmap.pixel(x: x, y: y)
        if p.r != 255 || p.g != 255 || p.b != 255 { belowHeader += 1 }
      }
    }
    #expect(belowHeader > 400, "the schematic did not draw: \(belowHeader) inked pixels")

    // The bitmap's origin is TOP-left (SceneBitmap's own convention); the imageable rect is in
    // Core Graphics' bottom-left space. On a 792-tall sheet with a 36pt margin the two agree by
    // symmetry, so the margin bands are the same four strips either way.
    var outside = 0
    for y in 0..<bitmap.height {
      for x in 0..<bitmap.width where x < 36 || x >= 576 || y < 36 || y >= 756 {
        let p = bitmap.pixel(x: x, y: y)
        if p.r != 255 || p.g != 255 || p.b != 255 { outside += 1 }
      }
    }
    #expect(outside == 0, "\(outside) inked pixels landed in the page margins")
  }

  /// The header is drawn, and it is drawn at the TOP of the content area rather than wherever
  /// a coordinate flip happened to put it. Measured by rasterising the same page twice, once
  /// with a header and once without, and comparing the ink in the top band only.
  @Test("the header line lands in the top band of the imageable area")
  @MainActor
  func headerLandsAtTheTop() throws {
    let circuit = try printDemoCircuit()
    var appearance = CanvasAppearance()
    appearance.antialiasing = false
    let page = CircuitPrintScene.build(circuit: circuit, appearance: appearance, printView: true)
    let metrics = PrintPageMetrics.standard()

    func topBandInk(header: String?) throws -> Int {
      let context = try #require(SceneRasterizer.makeContext(width: 612, height: 792))
      context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 612, height: 792))
      CircuitPrintPage.draw(
        page, into: context, imageable: letterImageable, header: header,
        rotateToFit: false, appearance: appearance, metrics: metrics)
      let rendered = try #require(context.makeImage())
      let bitmap = try #require(bitmapOf(rendered))
      // Top band of the imageable area, in SceneBitmap's top-left space: rows 36 ..< 36 + height.
      var n = 0
      for y in 36..<(36 + Int(metrics.height.rounded(.up))) {
        for x in 36..<576 {
          let p = bitmap.pixel(x: x, y: y)
          if p.r != 255 || p.g != 255 || p.b != 255 { n += 1 }
        }
      }
      return n
    }

    let withHeader = try topBandInk(header: "print-demo (1 of 1)")
    let without = try topBandInk(header: nil)
    #expect(
      withHeader > without,
      "the header band gained \(withHeader - without) pixels — expected the header's glyphs")
  }

  // ═══════════════════════════════════════════════════════════════════════════════════════════
  // §5. The quarter turn is a rotation, not a mirror.
  // ═══════════════════════════════════════════════════════════════════════════════════════════

  /// A mirrored transform places every primitive in a plausible-looking spot and prints every
  /// label backwards. `determinant == +1` is the only cheap way to rule it out, and the corner
  /// mapping pins which way up the result is.
  @Test("both rotated transforms preserve orientation and map the frame onto the sheet")
  func rotationsAreNotMirrors() {
    let imageable = letterImageable

    for rotation in [
      PrintRotation.upright, .portraitToLandscape, .landscapeToPortrait,
    ] {
      let t = rotation.transform(imageable: imageable)
      let determinant = t.a * t.d - t.b * t.c
      #expect(abs(determinant - 1) < 1e-12, "\(rotation) is not orientation-preserving")
    }

    // The local frame is the transpose of the imageable area when rotated: 720 x 540.
    let portrait = PrintRotation.portraitToLandscape.transform(imageable: imageable)
    // Local (0, 0) is the frame's bottom-left; it must land on a corner of the imageable box.
    let origin = CGPoint.zero.applying(portrait)
    #expect(origin == CGPoint(x: imageable.maxX, y: imageable.minY))
    // Local (720, 540), the frame's far corner, is the opposite corner of the same box.
    let far = CGPoint(x: 720, y: 540).applying(portrait)
    #expect(abs(far.x - imageable.minX) < 1e-9)
    #expect(abs(far.y - imageable.maxY) < 1e-9)

    let landscape = PrintRotation.landscapeToPortrait.transform(imageable: imageable)
    #expect(CGPoint.zero.applying(landscape) == CGPoint(x: imageable.minX, y: imageable.maxY))
    let farL = CGPoint(x: 720, y: 540).applying(landscape)
    #expect(abs(farL.x - imageable.maxX) < 1e-9)
    #expect(abs(farL.y - imageable.minY) < 1e-9)
  }

  /// End to end: a wide circuit on a portrait sheet rotates, and its ink still stays inside the
  /// imageable box. The transform arithmetic above is necessary but not sufficient: a correct
  /// matrix with the wrong viewport rect still prints off the edge of the paper.
  @Test("a rotated page keeps its ink inside the imageable area")
  @MainActor
  func rotatedPageStaysOnTheSheet() throws {
    StdLibraries.registerAll()
    let circuit = try Circuit(name: "wide")
    // A long horizontal run of wire: 1400 units wide, ~10 tall. Forces the quarter turn.
    try circuit.mutatorAdd(
      Wire.create(
        Location.create(0, 0, hasToSnap: false),
        Location.create(1400, 0, hasToSnap: false)))
    try circuit.mutatorAdd(
      Wire.create(
        Location.create(0, 0, hasToSnap: false),
        Location.create(0, 10, hasToSnap: false)))

    var appearance = CanvasAppearance()
    appearance.antialiasing = false
    let page = CircuitPrintScene.build(circuit: circuit, appearance: appearance, printView: true)

    let context = try #require(SceneRasterizer.makeContext(width: 612, height: 792))
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 612, height: 792))
    let layout = CircuitPrintPage.draw(
      page, into: context, imageable: letterImageable, header: nil,
      rotateToFit: true, appearance: appearance)

    #expect(layout.rotation == .portraitToLandscape, "the wide circuit did not rotate")

    let rendered = try #require(context.makeImage())
    let bitmap = try #require(bitmapOf(rendered))
    var inside = 0
    var outside = 0
    for y in 0..<bitmap.height {
      for x in 0..<bitmap.width {
        let p = bitmap.pixel(x: x, y: y)
        guard p.r != 255 || p.g != 255 || p.b != 255 else { continue }
        if x < 36 || x >= 576 || y < 36 || y >= 756 { outside += 1 } else { inside += 1 }
      }
    }
    #expect(inside > 200, "the rotated page is blank: \(inside) inked pixels")
    #expect(outside == 0, "\(outside) inked pixels landed in the page margins")

    // The turn is what makes it fit: the wire is 1408 units wide after `expand(4)` and the
    // sheet is 540 wide, so upright it would be scaled to 0.3835 and rotated to 0.5114.
    #expect(layout.scale > 0.5)
  }
}

// MARK: - CGImage -> SceneBitmap

/// `SceneRasterizer.render` builds its own context; these tests need to draw a page transform
/// into a context they own, so the pixels come back out of the `CGImage` instead.
private func bitmapOf(_ image: CGImage) -> SceneBitmap? {
  let width = image.width
  let height = image.height
  guard let space = CGColorSpace(name: CGColorSpace.sRGB),
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue)
  else { return nil }
  context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  guard let base = context.data else { return nil }
  let buffer = UnsafeRawBufferPointer(start: base, count: context.bytesPerRow * height)
  return SceneBitmap(
    width: width, height: height, bytesPerRow: context.bytesPerRow, pixels: Array(buffer))
}
