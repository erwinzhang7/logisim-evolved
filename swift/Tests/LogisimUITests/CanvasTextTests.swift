// CanvasTextTests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// The free-floating `Text` annotation: does it draw, and does its colour follow the appearance?
//
// Two separate questions, and today's audit (`docs/experiments/upstream-issues.md`, #2661)
// established that the FIRST one had never been asked. `Text` is an `InstanceFactory` that
// conformed to neither `ComponentPaintable` nor `InstancePaintable`, and `CircuitRenderer.render`
// dispatches on exactly those two casts:
//
//     if let selfDrawing = component as? any ComponentPaintable { … }
//     else if let paintable = component.factory as? any InstancePaintable { … }
//     // Neither: draw nothing.
//
// so every text annotation a user placed fell off the end of that `if` and emitted zero
// primitives. Dropped hop #22: the painter arithmetic existed (`Text.estimateBounds`), the
// factory existed, the registration existed, and the one `extension Text: InstancePaintable`
// between them did not.
//
// EVERY assertion here is on PRIMITIVE COUNTS out of `SceneBuilder`, never on "a view exists"
// or "a component was constructed". `CircuitRenderer.render` returns a *painted* count that
// increments once per dispatched component; that number was 1 for a `Text` the moment it
// conformed, while the scene it produced still held zero primitives, so `painted` is precisely
// the metric that cannot distinguish a working painter from a stub. `scene.primitives.count`
// can.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimStd
import Testing

@testable import LogisimUI

// MARK: - Fixtures

/// A `Text` component carrying `text`, placed at (100, 100).
@MainActor
private func textComponent(
  _ text: String,
  color: ColorSpec = ColorSpec(red: 0, green: 0, blue: 0)
) throws -> any Component {
  StdLibraries.registerAll()
  let attributes = Text.factory.createAttributeSet()
  try attributes.setValue(Text.attrText, text)
  try attributes.setValue(Text.attrColor, color)
  return try Text.factory.createComponent(
    location: Location.create(100, 100, hasToSnap: false), attributes: attributes)
}

@MainActor
private func circuitWithText(
  _ text: String,
  color: ColorSpec = ColorSpec(red: 0, green: 0, blue: 0)
) throws -> Circuit {
  let circuit = try Circuit(name: "text")
  try circuit.mutatorAdd(try textComponent(text, color: color))
  return circuit
}

/// Renders `circuit` and hands back both the scene and the `painted` count, so a test can show
/// the two disagreeing.
@MainActor
private func renderScene(
  _ circuit: Circuit,
  componentColor: SceneColor = .black
) -> (scene: RenderScene, painted: Int) {
  let builder = SceneBuilder(measurer: NominalTextMeasurer())
  let context = StaticPaintContext(componentColor: componentColor)
  let painted = CircuitRenderer.render(circuit, into: builder, context: context)
  return (builder.finish(), painted)
}

/// The text runs a scene actually carries, as plain strings.
private func drawnStrings(_ scene: RenderScene) -> [String] {
  scene.texts.map(\.string)
}

// MARK: - Does it draw at all?

@Suite("Canvas Text — the annotation draws")
struct CanvasTextDrawsTests {

  /// The regression this file exists for. Before the fix this produced `painted == 0` and
  /// `primitives.count == 0`; a `Text` on a schematic was invisible.
  @Test("a Text annotation emits primitives")
  @MainActor
  func textEmitsPrimitives() throws {
    let (scene, painted) = renderScene(try circuitWithText("hello"))

    #expect(painted == 1, "CircuitRenderer dispatched no painter for Text")
    #expect(scene.primitives.count > 0, "Text was dispatched but emitted no primitives")
    #expect(drawnStrings(scene) == ["hello"])
  }

  /// The dispatch arm, named. `Text` must reach `paintInstance`, not be skipped by both casts.
  @Test("Text takes the InstancePaintable arm of CircuitRenderer's dispatch")
  @MainActor
  func textIsInstancePaintable() {
    #expect(Text.factory as? any InstancePaintable != nil)
  }

  /// Upstream's `paintGhost` opens with `if (text == null || text.equals("")) return;`
  /// (`Text.java:141-143`), so an empty annotation draws nothing, and that is the one case
  /// where zero primitives is CORRECT. Pinned so the fix cannot be "always emit something".
  @Test("empty text draws nothing, exactly as upstream returns early")
  @MainActor
  func emptyTextDrawsNothing() throws {
    let (scene, painted) = renderScene(try circuitWithText(""))

    #expect(painted == 1, "the painter must still be dispatched")
    #expect(scene.primitives.count == 0, "an empty annotation must emit no glyphs")
  }

  /// Multi-line: upstream's `GraphicsUtil.drawText` draws the string as one run, it does not
  /// split on newlines, so the port must not helpfully emit one primitive per line.
  @Test("a multi-line annotation is one text run, as upstream draws it")
  @MainActor
  func multiLineIsOneRun() throws {
    let (scene, _) = renderScene(try circuitWithText("a\nb\nc"))

    #expect(scene.texts.count == 1)
  }

  /// The annotation must land at the component's location, not at the origin. `paintInstance`
  /// translates by `painter.location` before delegating to `paintGhost`, which draws at (0, 0);
  /// drop the translate and every annotation in a circuit stacks at (0, 0).
  @Test("the annotation is translated to the component location")
  @MainActor
  func annotationIsTranslatedToItsLocation() throws {
    let (scene, _) = renderScene(try circuitWithText("x"))
    let run = try #require(scene.texts.first)

    // Placed at (100, 100) with the default centre/baseline alignment; the run's box must sit
    // near it rather than at the origin.
    #expect(abs(Int(run.baselineY) - 100) < 40, "baselineY \(run.baselineY) is not near y=100")
    #expect(abs(Int(run.boxX) - 100) < 60, "boxX \(run.boxX) is not near x=100")
  }

  /// Two annotations, two runs; the scene must not collapse or reuse them.
  @Test("two annotations draw independently")
  @MainActor
  func twoAnnotationsDrawIndependently() throws {
    StdLibraries.registerAll()
    let circuit = try Circuit(name: "two")
    for (index, word) in ["alpha", "beta"].enumerated() {
      let attributes = Text.factory.createAttributeSet()
      try attributes.setValue(Text.attrText, word)
      try circuit.mutatorAdd(
        try Text.factory.createComponent(
          location: Location.create(100 + index * 200, 100, hasToSnap: false),
          attributes: attributes))
    }

    let (scene, painted) = renderScene(circuit)
    #expect(painted == 2)
    #expect(Set(drawnStrings(scene)) == ["alpha", "beta"])
  }

  /// **The bounds writeback must converge.**
  ///
  /// `paintGhost` re-measures the string and corrects `TextAttributes.offsetBounds` *during* the
  /// render; upstream does the same, and it is the only place in this painter that writes to the
  /// model. The hazard that buys is oscillation: if the measured bounds never settled, every
  /// frame would change the component's bounds, every bounds change would invalidate, and the
  /// canvas would repaint forever at 100% CPU. That is a live-app failure a unit test on a single
  /// render cannot see.
  ///
  /// So: render three times and require the bounds to be identical from the second on. Frame 1
  /// legitimately differs; that is the estimate being corrected to real metrics, which is the
  /// whole point of the writeback.
  @Test("the offset-bounds writeback converges after one frame")
  @MainActor
  func boundsWritebackConverges() throws {
    let circuit = try circuitWithText("converge me")
    let component = try #require(circuit.components.first)

    _ = renderScene(circuit)
    let afterFirst = component.bounds
    _ = renderScene(circuit)
    let afterSecond = component.bounds
    _ = renderScene(circuit)
    let afterThird = component.bounds

    #expect(
      afterSecond == afterThird,
      "bounds still moving on frame 3 — the writeback oscillates and the canvas would never settle"
    )
    #expect(afterFirst == afterSecond)
  }

  /// And the correction must actually happen: the real measurement should differ from
  /// `estimateBounds`' deliberately crude `size * widest * 2 / 3` guess, or the writeback is
  /// dead code that converged trivially.
  @Test("the writeback replaces the crude estimate with a real measurement")
  @MainActor
  func writebackRefinesTheEstimate() throws {
    let circuit = try circuitWithText("proportional glyphs vary")
    let component = try #require(circuit.components.first)

    let estimated = component.bounds
    _ = renderScene(circuit)
    let measured = component.bounds

    #expect(
      estimated != measured,
      "bounds unchanged by painting — paintGhost's re-measure is not reaching the attributes")
  }
}

// MARK: - #2661 — the colour

@Suite("Canvas Text — #2661 label colour and the appearance")
struct CanvasTextColorTests {

  /// The default. `TextAttributes.color` is opaque black, which is upstream's `Color.BLACK`
  /// and is what the text tool stores into every annotation it creates.
  @Test("a fresh annotation stores opaque black, as upstream does")
  @MainActor
  func freshAnnotationIsBlack() throws {
    let attributes = Text.factory.createAttributeSet()
    let color = try #require(attributes.getValue(Text.attrColor))
    #expect(color == ColorSpec(red: 0, green: 0, blue: 0))
  }

  /// The constraint that makes the naive fix wrong, stated as a test. A user who deliberately
  /// picked red must keep red in BOTH appearances; an auto-invert that repaints it is the
  /// failure mode upstream's issue warns about.
  @Test("a deliberately-chosen colour is identical in both appearances")
  @MainActor
  func deliberateColourSurvivesBothAppearances() throws {
    let red = ColorSpec(red: 255, green: 0, blue: 0)
    let circuit = try circuitWithText("danger", color: red)

    let onLight = renderScene(circuit, componentColor: .rgb(0x000000)).scene
    let onDark = renderScene(circuit, componentColor: .rgb(0xE0E0E0)).scene

    let lightRun = try #require(onLight.texts.first)
    let darkRun = try #require(onDark.texts.first)
    #expect(lightRun.string == "danger" && darkRun.string == "danger")
    #expect(
      colorOf(onLight, run: 0) == colorOf(onDark, run: 0),
      "a user-chosen red was repainted by the appearance — that destroys a deliberate choice")
    #expect(colorOf(onLight, run: 0) == LogisimRender.RGBA(javaRGB: 0xFF0000))
  }

  /// The adaptive half, behind `TextThemePolicy.adaptDefaultColoredText`. An annotation still
  /// on the default black follows the ink; the same annotation with the policy off does not.
  @Test("an annotation still on the default colour follows the ink when the policy is on")
  @MainActor
  func defaultColouredTextFollowsInkUnderPolicy() throws {
    let circuit = try circuitWithText("note")

    let previous = TextThemePolicy.adaptDefaultColoredText
    defer { TextThemePolicy.adaptDefaultColoredText = previous }

    TextThemePolicy.adaptDefaultColoredText = true
    let adaptiveLight = renderScene(circuit, componentColor: .rgb(0x000000)).scene
    let adaptiveDark = renderScene(circuit, componentColor: .rgb(0xE0E0E0)).scene
    #expect(
      colorOf(adaptiveLight, run: 0) != colorOf(adaptiveDark, run: 0),
      "default-coloured text ignored the ink even with the policy on")
    #expect(colorOf(adaptiveDark, run: 0) == LogisimRender.RGBA(javaRGB: 0xE0E0E0))

    TextThemePolicy.adaptDefaultColoredText = false
    let frozenLight = renderScene(circuit, componentColor: .rgb(0x000000)).scene
    let frozenDark = renderScene(circuit, componentColor: .rgb(0xE0E0E0)).scene
    #expect(
      colorOf(frozenLight, run: 0) == colorOf(frozenDark, run: 0),
      "with the policy off the port must reproduce 4.1.0's frozen black exactly")
    #expect(colorOf(frozenDark, run: 0) == LogisimRender.RGBA(javaRGB: 0x000000))
  }

  /// D16: the shipped default must be upstream 4.1.0's behaviour. Turning adaptation on is the
  /// owner's call, not this agent's: see `docs/experiments/canvas-text.md`.
  @Test("the shipped default reproduces 4.1.0 — adaptation is opt-in")
  @MainActor
  func adaptationIsOffByDefault() {
    #expect(TextThemePolicy.adaptDefaultColoredTextDefault == false)
  }

  /// The policy must not touch a colour that merely *equals* the ink by coincidence in one
  /// appearance; it keys off "is the stored value the default", not "does it look like the
  /// current ink". Black text under a black ink stays adaptive; red never does.
  @Test("the policy keys off the stored default, not a colour match")
  @MainActor
  func policyKeysOffTheStoredDefault() throws {
    let previous = TextThemePolicy.adaptDefaultColoredText
    defer { TextThemePolicy.adaptDefaultColoredText = previous }
    TextThemePolicy.adaptDefaultColoredText = true

    // Black, the default, adapts.
    let plain = try circuitWithText("plain")
    #expect(
      colorOf(renderScene(plain, componentColor: .rgb(0xE0E0E0)).scene, run: 0)
        == LogisimRender.RGBA(javaRGB: 0xE0E0E0))

    // Near-black, deliberately chosen, does not.
    let nearBlack = try circuitWithText("chosen", color: ColorSpec(red: 1, green: 1, blue: 1))
    #expect(
      colorOf(renderScene(nearBlack, componentColor: .rgb(0xE0E0E0)).scene, run: 0)
        == LogisimRender.RGBA(javaRGB: 0x010101))
  }
}

// MARK: - Colour readback

/// The resolved colour of the primitive that carries text run `run`.
///
/// Goes through the scene's own slot table rather than trusting the builder's current colour,
/// because a static colour is interned and shared; reading the wrong one would silently
/// report a neighbouring primitive's ink.
@MainActor
private func colorOf(_ scene: RenderScene, run: Int) -> LogisimRender.RGBA? {
  for primitive in scene.primitives where primitive.kind == .text {
    if Int(primitive.poolOffset) == run {
      return scene.color(of: primitive.color)
    }
  }
  return nil
}
