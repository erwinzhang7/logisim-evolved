// UpstreamIssue2661Tests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// UPSTREAM ISSUE #2661: "canvas text ignores the dark/light switch"
//
// `CanvasDrawsTests.darkModeChangesThePixels` already flips `.light` → `.dark` and asserts the
// raster changed. That test is real, but it CANNOT FAIL FOR THE RIGHT REASON, and this file
// exists because of that:
//
//   1. its fixture (`demoCircuit`) places AND/OR/NOT gates and four wires: **no text at all**,
//      so nothing in the frame is the thing #2661 is about; and
//   2. `.light` and `.dark` differ in `canvasBackground` (0xFFFFFF vs a dark ground), so the
//      whole-bitmap inequality it asserts is satisfied by the BACKGROUND alone. Port every
//      glyph and every stroke to a frozen `Color.BLACK`; i.e. reintroduce the exact upstream
//      bug, and that assertion still passes.
//
// So the flip is isolated here instead: both rasters are drawn with palettes that differ in
// EXACTLY ONE entry, `ChromeRole.componentStroke` (the ink), with an identical background. Any
// surviving pixel difference is therefore attributable to component ink, which is the channel
// canvas text actually travels on in this port; `CircuitSceneSource.paintContext` passes
// `componentColor: palette[.componentStroke]` and painters draw text with `painter.componentColor`.
//
// The upstream mechanism being contrasted, for the record (4.1.0 tree, D16):
//   * `Value.java:296-304`: nine `public static Color` fields initialised at class-load from
//     `AppPreferences`, so they are frozen for the life of the JVM;
//   * they are reassigned from exactly one place, `gui/prefs/SimOptions.java:453-486`, i.e. the
//     preferences dialogue: never from a system-appearance change;
//   * `grep -rln "ColorRegistry|isDarkTheme|DarkTheme" src/main/java` returns **nothing**: 4.1.0
//     has no dark-mode colour infrastructure at all;
//   * `gui/main/Canvas.java:1287` is a literal `g.setColor(Color.BLACK)`.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import CoreGraphics
import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimRenderBackend
import LogisimStd
import Testing

@testable import LogisimUI

// MARK: - Fixtures

@MainActor
private func circuit(named name: String, _ factories: [any ComponentFactory]) throws -> Circuit {
  StdLibraries.registerAll()
  let circuit = try Circuit(name: name)
  var x = 120
  for factory in factories {
    let attributes = factory.createAttributeSet()
    let component = try factory.createComponent(
      location: Location.create(x, 120, hasToSnap: false), attributes: attributes)
    try circuit.mutatorAdd(component)
    x += 160
  }
  return circuit
}

/// `.light`, with **only** the ink entry replaced. The background is untouched, which is the
/// whole point, see the file header.
private func lightPalette(ink: LogisimUI.RGBA) -> CircuitPalette {
  var palette = CircuitPalette.light
  palette.chrome[ChromeRole.componentStroke.rawValue] = ink
  return palette
}

@MainActor
private func raster(_ circuit: Circuit, ink: LogisimUI.RGBA) throws -> SceneBitmap {
  var appearance = CanvasAppearance()
  appearance.antialiasing = false
  appearance.palette = lightPalette(ink: ink)
  let build = CircuitSceneSource.build(circuit: circuit, appearance: appearance)
  let world = build.contentBounds.insetBy(dx: -12, dy: -12)
  let result = try #require(
    CircuitSceneRasterizer.bitmap(
      build: build, worldRect: world, scale: 2, appearance: appearance))
  return result.bitmap
}

/// How many pixels moved when only the ink changed.
@MainActor
private func pixelsMovedByInkFlip(_ circuit: Circuit) throws -> Int {
  let black = try raster(circuit, ink: RGBA(hex: 0x000000))
  let white = try raster(circuit, ink: RGBA(hex: 0xF2F2F7))
  guard black.width == white.width, black.height == white.height else {
    Issue.record("rasters differ in size; the comparison is meaningless")
    return -1
  }
  var moved = 0
  for y in 0..<black.height {
    for x in 0..<black.width {
      let a = black.pixel(x: x, y: y)
      let b = white.pixel(x: x, y: y)
      if a.r != b.r || a.g != b.g || a.b != b.b { moved += 1 }
    }
  }
  return moved
}

// MARK: - The gate

@Suite("Upstream #2661 — canvas ink follows the appearance")
struct UpstreamIssue2661Tests {

  /// Guards the guard. If `.light` and `.dark` had the same background, the existing
  /// whole-bitmap test would be discriminating and this file would be unnecessary; if they
  /// differ, that test is satisfied by the background alone and proves nothing about text.
  @Test("the existing whole-bitmap flip is satisfied by the background alone")
  @MainActor
  func backgroundAloneExplainsTheExistingTest() {
    #expect(CircuitPalette.light[.canvasBackground] != CircuitPalette.dark[.canvasBackground])
  }

  /// Positive control. Gate painters go through `painter.componentColor`, so the ink is live
  /// and a flip must move pixels with the background held constant.
  @Test("gates re-ink when only the ink changes — background held identical")
  @MainActor
  func gatesFollowTheInk() throws {
    let gates = try circuit(named: "i2661-gates", [AndGate.factory, OrGate.factory, NotGate.factory])
    let moved = try pixelsMovedByInkFlip(gates)
    #expect(moved > 100, "gate ink did not follow the palette: \(moved) pixels moved")
  }

  /// **RETIRED AS A DEFECT PIN, KEPT AS A REGRESSION GUARD; the defect is fixed.**
  ///
  /// This test used to assert `primitives.count == 0`, pinning the fact that a free-floating
  /// `Text` annotation drew NOTHING: `LogisimStd/Base/Text.swift` was a codec-only port with no
  /// `paintInstance`, so `CircuitRenderer.render` matched neither of its two dispatch casts and
  /// dropped the component. Its failure message said "Text now paints: good; retire this test
  /// and measure #2661 through it instead", and that is what happened.
  ///
  /// `LogisimStd/Base/TextPainter.swift` supplies the missing `extension Text: InstancePaintable`
  /// (measured before: `painted=0 prims=0 texts=0`; after: `painted=1 prims=1 texts=1`). The
  /// assertion is inverted rather than deleted, because the vacuity it guarded against is still
  /// the failure mode that matters: an empty frame is identical under every palette, so a
  /// "text follows the appearance" test built on a `Text` that draws nothing would pass for the
  /// wrong reason. This keeps that from silently coming back.
  ///
  /// It runs through `CircuitSceneSource.build`, the real canvas path, not through
  /// `CircuitRenderer` directly, so it is independent confirmation that the fix reaches the app
  /// and not only the unit seam. Full coverage lives in `CanvasTextTests.swift`.
  @Test("a Text annotation draws — the vacuity that would fake #2661 is gone")
  @MainActor
  func textAnnotationDraws() throws {
    StdLibraries.registerAll()
    let circuit = try Circuit(name: "i2661-text")
    let attributes = Text.factory.createAttributeSet()
    try attributes.setValue(Text.attrText, "DARK MODE")
    try circuit.mutatorAdd(
      try Text.factory.createComponent(
        location: Location.create(120, 120, hasToSnap: false), attributes: attributes))

    let build = CircuitSceneSource.build(circuit: circuit, appearance: CanvasAppearance())
    #expect(
      build.scene.primitives.count > 0,
      "Text draws nothing again — the InstancePaintable conformance has been lost")
    #expect(build.scene.texts.map(\.string) == ["DARK MODE"])
  }

  /// **The actual state of #2661 in this port, measured.**
  ///
  /// A component *label* is the canvas text a user really sees, and it does NOT follow the
  /// appearance. `InstancePainter.drawLabel()` (`InstancePainter.swift:665-666`) resolves its
  /// colour as `attributeValue(StdAttr.labelColor, default: StdAttr.defaultLabelColor)`,
  /// `Color.BLUE`, per `StdAttr.java:47` in the 4.1.0 tree, with no palette and no appearance
  /// input anywhere on the path. So the label renders the same blue on a white ground and on a
  /// dark one.
  ///
  /// That is faithful to the port target: **4.1.0 has no fix for this.** Upstream added one
  /// only on `main` (4.2.0-dev): `StdAttr.getDefaultLabelColor()` selecting
  /// `DARK_DEFAULT_LABEL_COLOR = 0x6CB6FF` off `AppPreferences.isDarkTheme(...)`, consumed at
  /// `InstanceTextField.java:84`. Neither the constant nor the accessor exists at the v4.1.0
  /// tag; `grep -rn DARK_DEFAULT_LABEL_COLOR upstream-java-4.1.0` returns nothing.
  ///
  /// `LogisimFile/StdAttr.swift:89` already declares `darkDefaultLabelColor`, and **nothing
  /// reads it**; the fix is stubbed, not wired. Likewise `ChromeRole.label` and
  /// `ChromeRole.pinLabel` are defined in both palettes and read by no drawing code.
  ///
  /// When someone wires it, this test goes red, and that is the point: it is the tripwire that
  /// says "#2661 is now closeable", not an endorsement of the current behaviour.
  @Test("component labels are frozen blue and ignore the ink — #2661 NOT closed")
  @MainActor
  func componentLabelsIgnoreTheAppearance() throws {
    StdLibraries.registerAll()
    let circuit = try Circuit(name: "i2661-label")
    let attributes = AndGate.factory.createAttributeSet()
    try attributes.setValue(StdAttr.label, "Q")
    try circuit.mutatorAdd(
      try AndGate.factory.createComponent(
        location: Location.create(120, 120, hasToSnap: false), attributes: attributes))

    let dark = StdAttr.defaultLabelColor
    let onBlack = try raster(circuit, ink: RGBA(hex: 0x000000))
    let onWhite = try raster(circuit, ink: RGBA(hex: 0xF2F2F7))

    func labelPixels(_ bitmap: SceneBitmap) -> Int {
      var count = 0
      for y in 0..<bitmap.height {
        for x in 0..<bitmap.width {
          let p = bitmap.pixel(x: x, y: y)
          if p.r == dark.red, p.g == dark.green, p.b == dark.blue { count += 1 }
        }
      }
      return count
    }

    let a = labelPixels(onBlack)
    let b = labelPixels(onWhite)
    // Vacuity guard first: if the label never drew, the equality below would be 0 == 0.
    #expect(a > 0, "the gate label drew no pixels at all; this test proves nothing")
    #expect(
      a == b,
      "label pixel count moved with the ink (\(a) vs \(b)) — #2661 may now be closeable")
    // And the stub that a real fix would consume is still unreferenced.
    #expect(StdAttr.darkDefaultLabelColor != StdAttr.defaultLabelColor)
  }
}
