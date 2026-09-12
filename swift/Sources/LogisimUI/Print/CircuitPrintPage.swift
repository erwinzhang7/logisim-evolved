// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution (com.cburch.logisim.gui.main.Print), GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// DRAWING ONE PAGE.
//
// The counterpart to `PrintPageLayout`: that file decides, this one draws, and the split is what
// makes the decision testable with no printer, no window and no `NSPrintOperation` in existence.
// `PrintPageTests` calls exactly this function into an offscreen bitmap.
//
// The whole page transform is:
//
//     rotated frame  --PrintRotation.transform-->  page (Core Graphics, y up)
//
// and inside the rotated frame the scene is placed by a plain `RenderViewport`, exactly as the
// canvas places it in a window. `RenderViewport` already knows how to map a y-DOWN scene into a
// y-UP destination (`destinationPoint` uses `rect.maxY - dyFromTop`), so print needs no
// coordinate flip of its own and, critically, no mirrored CTM: a mirror would place every
// primitive correctly and print every label backwards, which no "did it draw?" assertion sees.
//
// ── The header ──────────────────────────────────────────────────────────────────────────────
//
// Drawn with Core Text rather than through the scene, because upstream draws it with the raw
// `Graphics` before the circuit transform is installed (`Print.java:169-175`); it belongs to
// the page, not to the schematic, and putting it in the scene would make it scale with the
// circuit. `PrintPageMetrics` stands in for `g.getFontMetrics()`.

import CoreGraphics
import CoreText
import Foundation
import LogisimRender
import LogisimRenderBackend

/// `java.awt.FontMetrics` for the one font the header uses.
///
/// `MyPrintable` takes the metrics of whatever font the printer `Graphics` arrives with; there
/// is no equivalent default on a `CGContext`, so the font is named here. It is the only
/// invented value in the print path and it is confined to the header line.
struct PrintPageMetrics {
  var font: CTFont

  /// `FontMetrics.getHeight()`, ascent + descent + leading.
  var height: Double

  /// `FontMetrics.getAscent()`.
  var ascent: Double

  static func standard(pointSize: Double = 10) -> PrintPageMetrics {
    let font = CTFontCreateWithName("Helvetica" as CFString, pointSize, nil)
    return PrintPageMetrics(
      font: font,
      height: CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font),
      ascent: CTFontGetAscent(font))
  }

  /// `FontMetrics.stringWidth(String)`.
  func width(of text: String) -> Double {
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(string: text, attributes: [.font: font]))
    return CTLineGetTypographicBounds(line, nil, nil, nil)
  }
}

enum CircuitPrintPage {

  /// Draws one circuit onto one page.
  ///
  /// - Parameters:
  ///   - imageable: the sheet's imageable rect **in the context's user space**, y upward.
  ///     `NSPrintInfo.imageablePageBounds` gives this directly.
  ///   - header: the already-substituted header line, or `nil` for none
  ///     (`header != null && !header.isEmpty()` upstream).
  /// - Returns: the layout that was used, so a caller, or a test, can assert on the decision
  ///   and on the pixels from the same call.
  @discardableResult
  static func draw(
    _ page: CircuitPrintScene,
    into context: CGContext,
    imageable: CGRect,
    header: String?,
    rotateToFit: Bool,
    appearance: CanvasAppearance,
    metrics: PrintPageMetrics = .standard()
  ) -> PrintPageLayout {
    let headerHeight = header == nil ? 0 : metrics.height
    let layout = PrintPageLayout.plan(
      imageable: imageable.size,
      circuitBounds: page.bounds,
      headerHeight: headerHeight,
      rotateToFit: rotateToFit)

    context.saveGState()
    defer { context.restoreGState() }

    // Upstream clips to the union of the printer's clip and the circuit's box, i.e. it *widens*
    // the clip so the schematic is never cut off by the imageable area (`Print.java:190-193`).
    // Nothing here narrows the clip, so that behaviour is the default; the page transform is
    // the only thing installed.
    context.concatenate(layout.rotation.transform(imageable: imageable))

    if let header, !header.isEmpty {
      drawHeader(header, layout: layout, metrics: metrics, into: context, appearance: appearance)
    }

    guard !layout.isDegenerate, layout.circuitRect.width > 0, layout.circuitRect.height > 0
    else { return layout }

    let viewport = RenderViewport(
      rect: layout.circuitRectFlipped,
      scale: layout.scale,
      sceneOriginX: Double(page.bounds.minX),
      sceneOriginY: Double(page.bounds.minY),
      yAxisPointsDown: false,
      backingScale: 1)

    CoreGraphicsSceneRenderer().render(
      page.scene,
      into: context,
      viewport: viewport,
      options: RenderOptions(
        theme: CircuitSceneSource.theme(for: appearance.palette),
        antialias: appearance.antialiasing,
        textAntialias: appearance.antialiasing,
        snapStrokesToPixelGrid: true,
        batchPrimitives: true,
        // `nil`, not the canvas background: paper is already white and upstream fills nothing.
        background: nil))

    return layout
  }

  private static func drawHeader(
    _ text: String,
    layout: PrintPageLayout,
    metrics: PrintPageMetrics,
    into context: CGContext,
    appearance: CanvasAppearance
  ) {
    let stroke = appearance.palette[.componentStroke].sceneRGBA
    let colour = CGColor(
      srgbRed: CGFloat(stroke.r) / 255, green: CGFloat(stroke.g) / 255,
      blue: CGFloat(stroke.b) / 255, alpha: CGFloat(stroke.a) / 255)
    let attributed = NSAttributedString(
      string: text,
      attributes: [.font: metrics.font, .foregroundColor: colour])
    let line = CTLineCreateWithAttributedString(attributed)
    let baseline = layout.headerBaseline(
      stringWidth: metrics.width(of: text), ascent: metrics.ascent)

    context.saveGState()
    context.textMatrix = .identity
    context.textPosition = baseline
    CTLineDraw(line, context)
    context.restoreGState()
  }
}
