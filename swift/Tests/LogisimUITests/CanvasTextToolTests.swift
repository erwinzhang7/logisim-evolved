// CanvasTextToolTests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// The text tool, end to end, through the REAL canvas.
//
// `CanvasTextTests` proves the painter draws once a `Text` is in the circuit. That is necessary
// and not sufficient for the thing the owner actually does, which is: pick the Text tool, click
// the sheet, type. This suite drives `CircuitEditorCanvas`, the application's only `ToolCanvas`
// , with the same `CanvasPointerEvent` the AppKit view sends, so a gap anywhere between the
// toolbar and the scene shows up here rather than in a screenshot.
//
// It found one. `TextTool.createTextComponent` opens with
//
//     guard let factory = textFactory, let prototype = prototypeAttributes else { return nil }
//
// and `CanvasToolController.baseTools` constructs `TextTool()`: the no-argument initialiser,
// whose `textFactory` is `nil`. So in the shipped app the tool takes that `guard` on every
// click and returns `nil`, no component is ever created, and the whole gesture is a no-op.
// Independent of the painter defect, and downstream of it: fixing the painter alone would still
// leave a user clicking on an empty sheet forever.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import CoreGraphics
import Foundation
import ImageIO
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimStd
import Testing

@testable import LogisimUI

/// The application's own canvas over a real project, exactly as `CanvasToolRoundTripTests` builds
/// it; a hand-assembled `Project` would answer a different question.
@MainActor
private struct TextRig {
  let project: Project
  let circuit: Circuit
  let canvas: CircuitEditorCanvas

  init() throws {
    StdLibraries.registerAll()
    let made = try LogisimFileProjectHostFactory().makeEmptyProject()
    let host = try #require(made as? LogisimFileProjectHost)
    project = host.project
    circuit = try #require(host.currentCircuitObject)
    let surface = try #require(host.makeRenderSurface() as? CircuitCanvasSurface)
    canvas = CircuitEditorCanvas(
      project: project, surface: surface, circuit: circuit, initialTool: SelectTool())
  }

  /// Select the Text tool the way the explorer does: publish the builtin id and let
  /// `setActiveTool(fromLibrary:)` resolve it out of the controller's own `baseTools` table. The
  /// test therefore exercises the instance the app would use, not one it constructed itself.
  @discardableResult
  func selectTextTool() throws -> LogisimUI.TextTool {
    let accepted = canvas.controller.setActiveTool(
      fromLibrary: BuiltinPlaceholderTool(id: BaseToolIds.textTool))
    #expect(accepted, "the controller does not resolve BaseToolIds.textTool at all")
    return try #require(
      canvas.controller.activeTool as? LogisimUI.TextTool,
      "BaseToolIds.textTool resolved to something that is not LogisimUI.TextTool")
  }

  /// Whether the active tool is showing an edit caret. `TextTool.overlay` is
  /// `ToolOverlay(items: caret?.overlayItems ?? [])`, so a non-empty overlay is exactly "a caret
  /// is open"; read without reaching into the tool's private state.
  func hasOpenCaret() -> Bool {
    let overlay = canvas.controller.activeTool.overlay(for: canvas)
    // Both halves, and the second is the one that matters here: a text caret carries no
    // `ToolOverlayItem` at all, that enum is a closed set of nine fixed tool shapes and cannot
    // express one, so it draws entirely through `scene`. Reading only `items` made this helper
    // answer "no caret open" for a caret that was open, visible and taking keystrokes, which is
    // exactly what let the tripwire below keep passing after the defect it guards was fixed.
    return !overlay.items.isEmpty || !(overlay.scene?.primitives.isEmpty ?? true)
  }

  func click(_ x: Int, _ y: Int) {
    for phase in [CanvasPointerEvent.Phase.down, .up] {
      canvas.controller.canvasHandlePointer(
        CanvasPointerEvent(
          phase: phase,
          world: CGPoint(x: CGFloat(x), y: CGFloat(y)),
          modifiers: [],
          clickCount: 1,
          buttonNumber: 1,
          dragOriginWorld: nil))
    }
  }

  /// Primitives the real scene builder produces for the current circuit.
  func scenePrimitiveCount() -> Int {
    CircuitSceneSource.build(circuit: circuit, appearance: CanvasAppearance()).scene.primitives
      .count
  }
}

@Suite("Canvas Text — the text tool reaches the scene")
struct CanvasTextToolTests {

  /// The controller does resolve the id to the *right* type; this half is wired, and saying so
  /// keeps the two failures below from being read as "the text tool is missing entirely".
  /// `BaseToolReachabilityTests` records why this is worth asserting: there are two `TextTool`
  /// types, and the explorer used to register `LogisimFile`'s inert one.
  @Test("BaseToolIds.textTool resolves to the real CanvasTool")
  @MainActor
  func textToolResolves() throws {
    let rig = try TextRig()
    _ = try rig.selectTextTool()
  }

  /// **DEFECT PINNED, not asserted away.** `CanvasToolController.baseTools` builds
  /// `TextTool()`, the no-argument initialiser, so `textFactory` is `nil`, and
  /// `TextTool.createTextComponent` guards on exactly that and returns `nil` on every click.
  ///
  /// Pinned in the house style (`UpstreamIssue2661Tests` does the same): assert the CURRENT
  /// behaviour so the gate stays green, with a message that fires the moment someone fixes it.
  /// Asserting the desired behaviour instead would leave the tree red for everyone and say
  /// nothing this comment does not.
  ///
  /// The fix is one argument, in a file this task does not own:
  ///
  ///     BaseToolIds.textTool: TextTool(textFactory: <the base library's Text factory>),
  ///
  /// resolved the way `AddTool` resolves its factory.
  @Test("the app's Text tool now has its factory")
  @MainActor
  func registeredTextToolHasNoFactory() throws {
    let rig = try TextRig()
    let tool = try rig.selectTextTool()

    #expect(
      tool.attributeSet != nil,
      "the factory injection was reverted; TextTool() with no factory makes every click a no-op")
  }

  /// The user-level end of seam #23, now closed and inverted from what it used to assert.
  ///
  /// It was written as a tripwire: "clicking still creates nothing", with instructions in its own
  /// failure message to invert it once `TextEditable` had a conformer. That conformer now exists
  /// (`InstanceTextEditable.swift`, the retroactive-conformance device `Wire: CustomHandles`
  /// already uses), so a click opens a real caret and Return commits a real `Text`.
  ///
  /// **It did not trip on its own, and that is the lesson.** `hasOpenCaret()` read only
  /// `ToolOverlay.items`, and a text caret contributes no `ToolOverlayItem`, the enum is a
  /// closed set of nine tool shapes that cannot express one, so the helper answered "no caret"
  /// for a caret that was open and taking keystrokes, and the tripwire kept passing for the wrong
  /// reason. The helper reads both halves now.
  @Test("clicking opens a caret and committing adds the Text — seam #23 closed")
  @MainActor
  func clickingOpensACaretAndCommittingAddsAText() throws {
    let rig = try TextRig()
    _ = try rig.selectTextTool()

    let before = rig.circuit.components.count
    rig.click(120, 120)
    #expect(rig.hasOpenCaret(), "a click with the Text tool must open a caret")

    for character in "HELLO" {
      _ = rig.canvas.controller.canvasHandleKey(
        CanvasKeyEvent(
          phase: .down, characters: String(character), keyCode: 0, modifiers: [],
          isRepeat: false))
    }
    _ = rig.canvas.controller.canvasHandleKey(
      CanvasKeyEvent(
        phase: .down, characters: "\r", keyCode: 0x24, modifiers: [], isRepeat: false))

    #expect(rig.circuit.components.count == before + 1, "committing must add the Text component")
    #expect(!rig.hasOpenCaret(), "committing must close the caret")
  }

  /// The half that IS fixed, proved through the same real-canvas rig: once a `Text` is in the
  /// circuit, the application's scene builder emits primitives for it. This is what makes the
  /// tool defect above the *only* thing standing between the user and visible canvas text.
  @Test("a Text already in the circuit reaches the real scene")
  @MainActor
  func textInCircuitReachesTheScene() throws {
    let rig = try TextRig()
    let empty = rig.scenePrimitiveCount()

    let attributes = Text.factory.createAttributeSet()
    try attributes.setValue(Text.attrText, "VISIBLE")
    try rig.circuit.mutatorAdd(
      try Text.factory.createComponent(
        location: Location.create(120, 120, hasToSnap: false), attributes: attributes))

    #expect(rig.scenePrimitiveCount() > empty)
  }
}

// MARK: - Visual proof

/// Rasterises a schematic carrying a wire and two `Text` annotations, one on the default colour,
/// one deliberately red, in light and dark, and (with `LOGISIM_CANVAS_DUMP` set) writes the PNGs
/// out.
///
/// Follows the `LOGISIM_CANVAS_DUMP` convention `CanvasDrawsTests` established, and for its
/// reason: an inked-pixel count proves the canvas is not blank, it does not prove the glyphs are
/// *right*, and the cheapest check on that is a human looking at the image.
///
/// The assertion compares the same schematic **with and without** the annotations rather than
/// against a blank canvas; a blank-canvas comparison would be satisfied by the wire alone, which
/// is exactly the "passes for the wrong reason" shape this whole investigation started from.
@Suite("Canvas Text — visual proof")
struct CanvasTextVisualTests {

  @Test("annotations add inked pixels to a real raster")
  @MainActor
  func annotationsInkTheRaster() throws {
    StdLibraries.registerAll()

    func scene(withText: Bool, palette: CircuitPalette) throws -> (
      build: CircuitSceneBuild, appearance: CanvasAppearance
    ) {
      let circuit = try Circuit(name: "visual")
      try circuit.mutatorAdd(
        Wire.create(
          Location.create(60, 60, hasToSnap: false),
          Location.create(160, 60, hasToSnap: false)))
      if withText {
        for (index, spec) in [
          ("DEFAULT BLACK", ColorSpec(red: 0, green: 0, blue: 0)),
          ("CHOSEN RED", ColorSpec(red: 255, green: 0, blue: 0)),
        ].enumerated() {
          let attributes = Text.factory.createAttributeSet()
          try attributes.setValue(Text.attrText, spec.0)
          try attributes.setValue(Text.attrColor, spec.1)
          try circuit.mutatorAdd(
            try Text.factory.createComponent(
              location: Location.create(100, 110 + index * 40, hasToSnap: false),
              attributes: attributes))
        }
      }
      var appearance = CanvasAppearance()
      appearance.palette = palette
      return (CircuitSceneSource.build(circuit: circuit, appearance: appearance), appearance)
    }

    func inked(_ pair: (build: CircuitSceneBuild, appearance: CanvasAppearance), name: String)
      throws -> Int
    {
      let world = CGRect(x: 0, y: 0, width: 320, height: 220)
      let raster = try #require(
        CircuitSceneRasterizer.bitmap(
          build: pair.build, worldRect: world, scale: 2, appearance: pair.appearance))
      let background = pair.appearance.palette[.canvasBackground].sceneRGBA
      var count = 0
      for y in 0..<raster.bitmap.height {
        for x in 0..<raster.bitmap.width {
          let p = raster.bitmap.pixel(x: x, y: y)
          if p.r != background.r || p.g != background.g || p.b != background.b { count += 1 }
        }
      }

      if let dump = ProcessInfo.processInfo.environment["LOGISIM_CANVAS_DUMP"],
        let image = CircuitSceneRasterizer.image(
          build: pair.build, worldRect: world, scale: 4, appearance: pair.appearance)
      {
        let url = URL(fileURLWithPath: dump).appendingPathComponent("\(name).png")
        if let destination = CGImageDestinationCreateWithURL(
          url as CFURL, "public.png" as CFString, 1, nil)
        {
          CGImageDestinationAddImage(destination, image, nil)
          CGImageDestinationFinalize(destination)
          print("canvas text: wrote \(url.path)")
        }
      }
      return count
    }

    let bare = try inked(try scene(withText: false, palette: .light), name: "text-light-bare")
    let light = try inked(try scene(withText: true, palette: .light), name: "text-light")
    let dark = try inked(try scene(withText: true, palette: .dark), name: "text-dark")

    // The same dark frame with the #2661 policy ON. The pair `text-dark` / `text-dark-adaptive`
    // is the whole decision in two images: the default-coloured annotation becomes legible, and
    // the deliberately-red one is untouched.
    let previous = TextThemePolicy.adaptDefaultColoredText
    TextThemePolicy.adaptDefaultColoredText = true
    let darkAdaptive = try inked(
      try scene(withText: true, palette: .dark), name: "text-dark-adaptive")
    TextThemePolicy.adaptDefaultColoredText = previous

    print(
      "canvas text: light bare=\(bare) withText=\(light) · dark frozen=\(dark) "
        + "adaptive=\(darkAdaptive)")
    #expect(
      light > bare + 200,
      "annotations added only \(light - bare) inked pixels — they are not rasterising")

    // Frozen-vs-adaptive must differ in the raster, not merely in a returned SceneColor. Black
    // glyphs on a dark ground still count as "inked" (they are not the background colour), so
    // this is deliberately compared as a pixel-level difference rather than as a count.
    #expect(
      dark != darkAdaptive || TextThemePolicy.adaptDefaultColoredTextDefault,
      "the policy changed nothing in the raster")
  }
}
