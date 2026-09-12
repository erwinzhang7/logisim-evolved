// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution (com.cburch.logisim.gui.main.Print), GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE PRINT SCENE; the same walk the canvas does, with `printerView` ON.
//
// `MyPrintable.print` ends with
//
//     final var context = new ComponentDrawContext(
//         proj.getFrame().getCanvas(), circ, circState, base, g, printerView);
//     circ.draw(context, Collections.emptySet());
//
// i.e. it reuses the *same* painters the canvas uses and changes exactly one flag. This port
// renders through `RenderScene` (D6), so the equivalent is to run `CircuitRenderer`, the same
// walker `CircuitSceneSource` runs for the canvas, over a `StaticPaintContext` whose
// `isPrintView` is true.
//
// ── Why this does not simply call `CircuitSceneSource.build` ────────────────────────────────
//
// `CircuitSceneSource.paintContext(for:)` hard-codes `isPrintView: false` (line 273), which is
// correct for the canvas and is the whole thing Print needs to change. It also builds the
// hit-target table, the wire-segment list and the id index; all of which are for the pointer
// and none of which a sheet of paper has. So this is a deliberately smaller walk, not a
// duplicated one: `CircuitRenderer.render` is the shared part and it is called, not copied.
//
// ── What `isPrintView` actually changes, measured ───────────────────────────────────────────
//
// The flag is not decoration. In this port it is read by six paint paths already ported:
//
//   * `AbstractGate.paintInstance` (`:612`) ; port markers are suppressed unless the gate is
//     drawn in the rectangular/IEC shape, which has no lead lines of its own.
//   * `PainterShaped.paintInputLines` (`:274,300`) and `PainterDin` (`:162,164`); an input
//     lead is drawn only if that port is actually connected.
//   * `ControlledBuffer` (`:274`), `SubcircuitPainter` (`:421`); likewise.
//   * `InstancePainter.drawLabel` (`:664`); the label's colour attribute is IGNORED and the
//     pen colour is inherited, so a coloured label prints in the component colour. (Upstream
//     does the same: `printView` short-circuits `g.setColor(labelColor)`.)
//
// and indirectly by `shouldDrawColor`/`showState`, both of which are `!printView && …`.
// `PrintSceneDiffersTests` measures the resulting difference in primitive count and in pixels
// rather than asserting the flag was passed, because "the flag was passed" is exactly the
// assertion that passes against a version that prints a blank page.
//
// ── showState ───────────────────────────────────────────────────────────────────────────────
//
// `false`, matching `CircuitSceneSource`. Upstream hands `MyPrintable` a real `CircuitState`,
// but `ComponentDrawContext.getShowState()` is `!printView && showState`, so with the (default,
// checked) printer view the live state is unreachable anyway; the two agree wherever
// `printerView` is on, and this port has no live state behind a headless render regardless.

import CoreGraphics
import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimRenderBackend
import LogisimStd

/// One circuit, walked into a `RenderScene` for paper.
public struct CircuitPrintScene {

  /// The retained geometry.
  var scene: RenderScene

  /// `circ.getBounds(g).expand(4)`: `MyPrintable.print`'s `bds`, in circuit units, y downward.
  ///
  /// The `expand(4)` is upstream's and is the printed margin around the schematic; without it
  /// a component's stroke sits exactly on the paper's content edge.
  var bounds: CGRect

  /// Number of components the walker actually painted. Zero here and a non-empty circuit means
  /// the join is broken, which is the failure this project has hit twice.
  var paintedComponentCount: Int

  var isEmpty: Bool { scene.isEmpty }

  /// How many primitives the walk emitted. The measure that distinguishes a print-view scene from
  /// a screen scene (`PrintTests.printSceneDiffersFromScreenScene`), exposed by name so callers
  /// are not writing `page.scene.scene.primitives.count`.
  var primitiveCount: Int { scene.primitives.count }

  /// `ComponentDrawContext(..., printerView)` + `circ.draw(context, noComps)`.
  ///
  /// - Parameter printView: upstream's `ParmsPanel.getPrinterView()`, seeded **checked**
  ///   (`printerView.setSelected(true)`, `Print.java:212`). Passing `false` here yields the
  ///   canvas's own scene, which is what makes the difference measurable.
  @MainActor
  static func build(
    circuit: Circuit,
    appearance: CanvasAppearance,
    printView: Bool = true
  ) -> CircuitPrintScene {
    let builder = SceneBuilder(measurer: CoreTextMeasurer())
    let context = StaticPaintContext(
      showState: false,
      showColor: appearance.showsValueColours,
      isPrintView: printView,
      gateShape: GateShape(rawValue: appearance.gateShape.rawValue) ?? .shaped,
      pinAppearance: .dotSmall,
      componentColor: .rgba(appearance.palette[.componentStroke].sceneRGBA))
    let painted = CircuitRenderer.render(circuit, into: builder, context: context)

    let box = circuit.bounds.expand(4)
    return CircuitPrintScene(
      scene: builder.finish(),
      bounds: CGRect(
        x: CGFloat(box.x), y: CGFloat(box.y),
        width: CGFloat(box.width), height: CGFloat(box.height)),
      paintedComponentCount: painted)
  }
}
