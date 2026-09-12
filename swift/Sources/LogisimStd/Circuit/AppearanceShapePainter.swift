// AppearanceShapePainter.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.draw.shapes.{Rectangle,Oval,RoundRectangle,Line,
// Poly,Curve,Text}.paint, com.cburch.draw.model.AbstractCanvasObject.{setForFill,setForStroke},
// com.cburch.draw.util.EditableLabel.paint),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// WHY THIS FILE EXISTS
//
// `LogisimDraw` is 28 files and the whole `<appear>` shape model: `Rectangle`, `Oval`,
// `RoundRectangle`, `Line`, `Poly`, `Curve`, `DrawText`, plus the SVG codec. Before this file it
// was imported by exactly two things, `CircuitAppearanceReader` and `CircuitAppearanceWriter`,
// both in `LogisimFile`, and **no view had ever drawn one of its shapes**. The model round-tripped
// through the codec and was otherwise inert: `CanvasObject` deliberately carries no `paint`
// method, because `LogisimDraw` depends on `LogisimKernel` alone and must not acquire a renderer
// (see `Package.swift`'s note on that edge; it is what keeps the headless CLI free of
// CoreGraphics).
//
// So the painting cannot live on the shape, the way Java's `CanvasObject.paint(Graphics, …)`
// does. It lives here instead, one module up, where `SceneBuilder` is nameable. That is the same
// inversion `MemPainter`, `IoPainter` and `TextPainter` already make, and it is why this is a
// free function over a shape rather than a method on it.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE MODULE EDGE
//
// `import LogisimDraw` from `LogisimStd` resolves **without a `Package.swift` change**:
// `LogisimStd -> LogisimFile -> LogisimDraw`, and SwiftPM puts every transitively-built module
// on the import search path. Verified by compiling, not assumed.
//
// It is nonetheless a *latent* edge; nothing in the manifest records that `LogisimStd` needs
// `LogisimDraw`, so a future change that drops `LogisimFile -> LogisimDraw` would break this file
// with an error pointing at the wrong place. The recommended explicit edge is written out in
// `docs/experiments/subcircuit-paint.md`; `Package.swift` is not this work's file to edit.
//
// D9 holds either way: `LogisimDraw` imports `LogisimKernel` and nothing platform-shaped, so
// naming it here drags no AppKit or CoreGraphics into `LogisimStd`.

import Foundation
import LogisimDraw
import LogisimFile
import LogisimKernel
import LogisimRender

/// `CanvasObject.paint(Graphics, HandleGesture)` for every shape an `<appear>` can hold, emitted
/// into a `RenderScene` (D6) instead of onto a `Graphics`.
///
/// `gesture` is always `null` at this call site, upstream's `CircuitAppearance.paintSubcircuit`
/// passes `shape.paint(dup, null)`, so every handle-dragging branch inside the Java `paint`
/// bodies is dead here and is not reproduced. That is the *only* systematic subtraction; each
/// individual `paint` is otherwise transcribed.
public enum AppearanceShapePainter {

  /// Paints a whole object list, bottom to top, and returns how many shapes actually drew.
  ///
  /// The return value is the metric this file is measured on. "A painter exists" is not evidence;
  /// a count of shapes that reached a draw call, cross-checked against primitives out of the
  /// `SceneBuilder`, is.
  ///
  /// `AppearanceElement`, the `AppearancePort`/`AppearanceAnchor` pair, is skipped, exactly as
  /// `paintSubcircuit`'s `if (!(shape instanceof AppearanceElement))` skips it. Ports are drawn by
  /// `InstancePainter.drawPorts()` afterwards, from the component's *ends*, so painting them here
  /// as well would double-draw every pin.
  @discardableResult
  public static func paint(_ shapes: [AppearanceShape], into g: SceneBuilder) -> Int {
    var drawn = 0
    for shape in shapes {
      // `AppearanceAnchor`/`AppearancePort` both descend from `AppearanceElement`.
      if shape is AppearanceElement { continue }
      guard let object = shape as? CanvasObject else { continue }
      if paint(object, into: g) { drawn += 1 }
    }
    return drawn
  }

  /// One shape. Returns `false` for a kind this painter does not know, which is not a failure
  /// mode to paper over: `visible-*` (`DynamicElement`) shapes are kept verbatim by the reader
  /// (D8) and never become a `CanvasObject`, so they cannot appear here, and every other tag the
  /// reader models is handled below.
  @discardableResult
  public static func paint(_ shape: CanvasObject, into g: SceneBuilder) -> Bool {
    // Saved and restored per shape because upstream hands each one `g.create()`: a private
    // Graphics whose colour, pen and font cannot leak into the next shape.
    let savedColor = g.color
    let savedWidth = g.strokeWidth
    let savedFont = g.font
    defer {
      g.color = savedColor
      g.strokeWidth = savedWidth
      g.font = savedFont
    }

    switch shape {
    case let text as DrawText:
      paintText(text, into: g)
      return true

    case let poly as Poly:
      let points = poly.handles(nil).map { ScenePoint($0.x, $0.y) }
      guard !points.isEmpty else { return false }
      if setForFill(shape, into: g) { g.fillPolygon(points) }
      if setForStroke(shape, into: g) {
        if poly.isClosed { g.drawPolygon(points) } else { g.drawPolyline(points) }
      }
      return true

    case let curve as Curve:
      // `Curve.paint`: `QuadCurve2D` filled and/or stroked. A quadratic Bézier, not a cubic;
      // `ScenePath.quad` is the matching op and the renderer elevates it.
      var path = ScenePath()
      path.move(to: Double(curve.end0.x), Double(curve.end0.y))
      path.quad(
        control: Double(curve.control.x), Double(curve.control.y),
        to: Double(curve.end1.x), Double(curve.end1.y))
      if setForFill(shape, into: g) { g.fillPath(path) }
      if setForStroke(shape, into: g) { g.strokePath(path) }
      return true

    case let line as Line:
      // Note `Line.paint` calls ONLY `setForStroke`; a line is never filled, even though
      // `setForFill` would return true for it (its attribute list has no PAINT_TYPE and no
      // FILL_COLOR, so upstream's `color == null` arm falls through to `return true`). Calling
      // both would fill a degenerate polygon on every line in every custom appearance.
      if setForStroke(shape, into: g) {
        g.drawLine(line.end0.x, line.end0.y, line.end1.x, line.end1.y)
      }
      return true

    // ── The three `Rectangular` subclasses ───────────────────────────────────────────────────
    //
    // **`x`/`y`/`width`/`height`, NOT `bounds`.** `Rectangular.paint` reads the private field;
    // Java's own comment on it is "excluding the stroke's width", while `getBounds()` inflates
    // a stroke-2 shape by `wid / 2` on every side. Painting the inflated box draws a stroke-2
    // rectangle one pixel out and two pixels too big in each dimension.
    //
    // This was not caught by reading: the jar oracle reported the default box's outline as
    // `(-211,-11,202,102)`, the port drew exactly that, and the *drawn* rectangle upstream is
    // `(-210,-10,200,100)`. `SubcircuitPaintOracleTests` is what separated the two, and the
    // accessors below are the raw field by construction (`Rectangular.x` is `boundsValue.x`).
    case let round as RoundRectangle:
      // `RoundRectangle.draw`: `diam = 2 * radius`, and Java's `fillRoundRect`/`drawRoundRect`
      // take the DIAMETER of the corner arc, not the radius.
      let diameter = 2 * Int(round.cornerRadius)
      if setForFill(shape, into: g) {
        g.fillRoundRect(round.x, round.y, round.width, round.height, diameter, diameter)
      }
      if setForStroke(shape, into: g) {
        g.drawRoundRect(round.x, round.y, round.width, round.height, diameter, diameter)
      }
      return true

    case let oval as Oval:
      if setForFill(shape, into: g) { g.fillOval(oval.x, oval.y, oval.width, oval.height) }
      if setForStroke(shape, into: g) { g.drawOval(oval.x, oval.y, oval.width, oval.height) }
      return true

    // `DrawRectangle`, not `Rectangle`: the port renames it to keep it distinct from
    // `LogisimKernel`'s geometry vocabulary, exactly as `Text` became `DrawText`.
    case let rect as DrawRectangle:
      if setForFill(shape, into: g) { g.fillRect(rect.x, rect.y, rect.width, rect.height) }
      if setForStroke(shape, into: g) { g.drawRect(rect.x, rect.y, rect.width, rect.height) }
      return true

    default:
      return false
    }
  }

  // MARK: - `Text.paint` → `EditableLabel.paint`

  /// `EditableLabel.paint(Graphics)`:
  ///
  /// ```java
  /// g.setFont(font);
  /// g.setColor(color);
  /// GraphicsUtil.drawText(g, text, x, y, horzAlign, vertAlign)   // via getLeftX()/getBaseY()
  /// ```
  ///
  /// Upstream computes the origin itself (`getLeftX`/`getBaseY`) and calls `drawString`; the two
  /// arms agree term for term with `SceneBuilder.drawText`'s `TextLayout.textBox`,
  /// `CENTER -> x - width/2`, `MIDDLE -> y + (ascent - descent)/2`, `BASELINE -> y`, so the
  /// alignment is handed to `drawText` rather than pre-resolved. `EditableLabel`'s own header
  /// records the `float` truncation that only affects `getBounds`, which painting does not read.
  private static func paintText(_ text: DrawText, into g: SceneBuilder) {
    let string = text.text
    guard !string.isEmpty else { return }

    if let font = text.getValue(DrawAttr.font) {
      g.font = InstancePainter.sceneFont(font)
    }
    if let color = text.getValue(DrawAttr.fillColor) {
      g.color = sceneColor(color)
    }

    let location = text.location
    g.drawText(
      string, x: location.x, y: location.y,
      halign: horizontalAlign(text.getValue(DrawAttr.halignment)),
      valign: verticalAlign(text.getValue(DrawAttr.valignment)))
  }

  /// `DrawAttr.HALIGN_*` → `HAlign`. `EditableLabel`'s constructor default is `LEFT`, and that is
  /// also what an absent attribute means.
  static func horizontalAlign(_ option: AttributeOption?) -> HAlign {
    switch option {
    case DrawAttr.halignCenter: return .center
    case DrawAttr.halignRight: return .right
    default: return .left
    }
  }

  /// `DrawAttr.VALIGN_*` → `VAlign`. Default `BASELINE`, matching `EditableLabel`.
  ///
  /// `MIDDLE` maps to `.center` and not to `.centerOverall`: `getBaseY`'s middle arm is
  /// `y + (ascent - descent) / 2`, which is `GraphicsUtil.V_CENTER`'s arithmetic exactly.
  static func verticalAlign(_ option: AttributeOption?) -> VAlign {
    switch option {
    case DrawAttr.valignTop: return .top
    case DrawAttr.valignMiddle: return .center
    case DrawAttr.valignBottom: return .bottom
    default: return .baseline
    }
  }

  // MARK: - `setForFill` / `setForStroke`

  /// `AbstractCanvasObject.setForFill(Graphics)`.
  ///
  /// ```java
  /// if (attrs.contains(PAINT_TYPE) && getValue(PAINT_TYPE) == PAINT_STROKE) return false;
  /// final var color = getValue(FILL_COLOR);
  /// if (color != null && color.getAlpha() == 0) return false;
  /// if (color != null) g.setColor(color);
  /// return true;
  /// ```
  ///
  /// Two details are upstream's and are easy to "improve" into a bug: a shape whose attribute
  /// list has no `PAINT_TYPE` at all skips the first test rather than defaulting to stroke-only,
  /// and a `null` fill colour returns **true** while leaving the current colour alone. Both are
  /// transcribed; the `Line` call site is the one that would have been visibly wrong.
  static func setForFill(_ shape: CanvasObject, into g: SceneBuilder) -> Bool {
    let attributes = shape.attributeSet.attributes
    if attributes.contains(where: { $0 === DrawAttr.paintType }),
      shape.getValue(DrawAttr.paintType) == DrawAttr.paintStroke
    {
      return false
    }
    guard let color = shape.getValue(DrawAttr.fillColor) else { return true }
    if color.alpha == 0 { return false }
    g.color = sceneColor(color)
    return true
  }

  /// `AbstractCanvasObject.setForStroke(Graphics)`.
  ///
  /// ```java
  /// if (attrs.contains(PAINT_TYPE) && getValue(PAINT_TYPE) == PAINT_FILL) return false;
  /// final var width = getValue(STROKE_WIDTH);
  /// if (width == null || width <= 0) return false;
  /// final var color = getValue(STROKE_COLOR);
  /// if (color != null && color.getAlpha() == 0) return false;
  /// GraphicsUtil.switchToWidth(g, width);
  /// if (color != null) g.setColor(color);
  /// return true;
  /// ```
  ///
  /// A missing or non-positive `STROKE_WIDTH` means "do not stroke", which is the branch that
  /// makes a fill-only rectangle draw as a solid block with no outline.
  static func setForStroke(_ shape: CanvasObject, into g: SceneBuilder) -> Bool {
    let attributes = shape.attributeSet.attributes
    if attributes.contains(where: { $0 === DrawAttr.paintType }),
      shape.getValue(DrawAttr.paintType) == DrawAttr.paintFill
    {
      return false
    }
    guard let width = shape.getValue(DrawAttr.strokeWidth), width > 0 else { return false }
    if let color = shape.getValue(DrawAttr.strokeColor) {
      if color.alpha == 0 { return false }
      g.color = sceneColor(color)
    }
    g.strokeWidth = Int(width)
    return true
  }

  /// `ColorSpec` (the kernel's `java.awt.Color`) → the scene's literal colour.
  ///
  /// Deliberately a literal and never `.palette`: an `<appear>` colour is authored by the user
  /// and is not a simulation value, so it must not re-theme with the wire palette.
  static func sceneColor(_ spec: ColorSpec) -> SceneColor {
    .rgba(RGBA(r: spec.red, g: spec.green, b: spec.blue, a: spec.alpha))
  }
}
