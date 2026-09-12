// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution (com.cburch.logisim.gui.main.Print), GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// ONE PRINTED PAGE, AS ARITHMETIC.
//
// `Print.MyPrintable.print` (`Print.java:128-201`) computes the page transform by *mutating a
// `Graphics2D`*; six `translate`/`rotate`/`scale` calls interleaved with the drawing. That is
// impossible to test without a `Graphics`, and it is where every fidelity detail lives, so this
// file separates the decision from the drawing: `PrintPageLayout.plan` is a pure function of
// four numbers and a flag, and `CircuitPrintPage` (next door) applies it.
//
// Every line below transliterates a specific line of `MyPrintable.print`; the ones that look
// wrong are wrong upstream too and are preserved:
//
//   * **The circuit is never ENLARGED.** `if (scale < 1.0) { g2.scale(scale, scale); … }`:
//     a small circuit prints at 1:1 in the middle of a big sheet, it does not fill the page.
//     `fittedScale` is kept alongside `scale` so a test can see the gate rather than infer it.
//   * **Vertically top-aligned, horizontally centred.** `dx = max(0.0, (imWidth - bds.width)/2)`
//     then `translate(-bds.getX() + dx, -bds.getY())`. There is no `dy`.
//   * **`imWidth` is divided by the scale AFTER `g2.scale`**, so `dx` is in circuit units, not
//     points, which is why `circuitRect.x` below is `scale * dx` and not `dx`.
//   * **The rotate test's own asymmetry.** `scale2 = min(imHeight/bds.width,
//     (imWidth - headHeight)/bds.height)` subtracts the header from the *pre-swap width*,
//     because that dimension becomes the post-swap height. Reading it as a typo and "fixing" it
//     changes which circuits rotate.
//   * **Rotation is gated twice**: only if the upright fit is worse than `1/1.1`, and only if
//     rotating buys at least another 10% (`scale2 >= scale * 1.1`). A circuit that barely fits
//     upright stays upright.
//
// ── Coordinates ─────────────────────────────────────────────────────────────────────────────
//
// The plan is expressed in the **rotated frame**: the space `MyPrintable` is in immediately
// after `g2.translate(imageableX, imageableY)` and the optional `g2.rotate`, i.e. origin at the
// imageable area's leading corner, x to the right, **y downward**, and `imageableSize` already
// swapped if a quarter turn was taken. That is exactly Java's frame, so the arithmetic is a
// transliteration; mapping that frame onto a Core Graphics page (y upward) is `PrintRotation
// .transform(imageable:)`'s job and nothing else's.
//
// ── Deliberately NOT here ───────────────────────────────────────────────────────────────────
//
// Multi-page tiling of one circuit: upstream has none. `MyPrintable` prints one circuit per page
// and returns `NO_SUCH_PAGE` past the end of the list, so a circuit too large for the sheet is
// shrunk, never split. Page setup (paper size, margins, orientation) is `PageFormat`, which is
// the platform's, `NSPrintInfo` here.

import CoreGraphics
import Foundation

/// The quarter turn `MyPrintable` may take, named by what it does to the *sheet*.
///
/// Upstream picks the direction from the page's own aspect (`if (imHeight > imWidth)`), so a
/// portrait sheet and a landscape sheet turn opposite ways and the reader tilts their head the
/// same way in both cases.
enum PrintRotation: Equatable {
  /// No turn: the circuit is drawn upright on the sheet.
  case upright

  /// `g2.translate(0, imHeight); g2.rotate(-Math.PI / 2)`; the portrait branch. Content runs
  /// bottom-to-top up the sheet; the reader turns the paper clockwise to read it.
  case portraitToLandscape

  /// `g2.translate(imWidth, 0); g2.rotate(Math.PI / 2)`; the landscape branch. Content runs
  /// top-to-bottom down the sheet; the reader turns the paper anticlockwise.
  case landscapeToPortrait

  var isRotated: Bool { self != .upright }

  /// Maps the rotated frame, expressed **y-upward**, origin at its own visual bottom-left,
  /// size `PrintPageLayout.imageableSize`, onto a Core Graphics page whose imageable area is
  /// `imageable` (y upward, origin bottom-left of the sheet).
  ///
  /// Both rotated cases have determinant `+1`: they are rotations, never mirrors. A mirror here
  /// would still place the geometry correctly and would silently print every label backwards,
  /// which is precisely the class of error a "does it draw?" test cannot see.
  func transform(imageable: CGRect) -> CGAffineTransform {
    switch self {
    case .upright:
      return CGAffineTransform(translationX: imageable.minX, y: imageable.minY)
    case .portraitToLandscape:
      // The frame is the transpose of the imageable area, so its width W' = imageable.height
      // and its height H' = imageable.width. Local (u, w) -> page (minX + H' - w, minY + u).
      return CGAffineTransform(
        a: 0, b: 1, c: -1, d: 0,
        tx: imageable.minX + imageable.width,
        ty: imageable.minY)
    case .landscapeToPortrait:
      // Local (u, w) -> page (minX + w, maxY - u).
      return CGAffineTransform(
        a: 0, b: -1, c: 1, d: 0,
        tx: imageable.minX,
        ty: imageable.maxY)
    }
  }
}

/// Everything `MyPrintable.print` decides before it draws anything.
struct PrintPageLayout: Equatable {

  /// The imageable area *in the rotated frame*, i.e. `imageable.size` transposed when
  /// `rotation.isRotated`. Java's `imWidth`/`imHeight` locals after the swap.
  var imageableSize: CGSize

  var rotation: PrintRotation

  /// `Math.min(imWidth / bds.getWidth(), (imHeight - headHeight) / bds.getHeight())`, after the
  /// rotate branch has possibly replaced it with `scale2`. May exceed 1.
  var fittedScale: Double

  /// What is actually applied: `min(fittedScale, 1)`, because upstream only calls `g2.scale`
  /// when `scale < 1.0`.
  var scale: Double

  /// `fm.getHeight()` when a header is printed, else 0.
  var headerHeight: Double

  /// Where the circuit's (already `expand(4)`-ed) bounding box lands in the rotated frame,
  /// y downward, in points.
  var circuitRect: CGRect

  /// True when the circuit's box does not fit inside the content area even after scaling;
  /// only reachable when `fittedScale > 1` is clamped to 1 (it never is: clamping only shrinks
  /// the drawing relative to the page) or when the header eats the whole sheet. Kept because a
  /// negative content height is the one input that makes `scale` non-finite upstream, and
  /// silently printing a blank page is the failure this whole board is about.
  var isDegenerate: Bool

  /// `g.drawString(head, (int) Math.round((imWidth - fm.stringWidth(head)) / 2), fm.getAscent())`
  /// , but returned in the rotated frame's **y-upward** local space, which is what the Core
  /// Text draw actually needs. `y` is the baseline.
  func headerBaseline(stringWidth: Double, ascent: Double) -> CGPoint {
    CGPoint(
      x: ((imageableSize.width - stringWidth) / 2).rounded(),
      y: imageableSize.height - ascent)
  }

  /// `circuitRect` converted to the rotated frame's y-upward local space, which is the rect the
  /// scene renderer is handed.
  var circuitRectFlipped: CGRect {
    CGRect(
      x: circuitRect.minX,
      y: imageableSize.height - circuitRect.maxY,
      width: circuitRect.width,
      height: circuitRect.height)
  }

  // MARK: - The port of `MyPrintable.print`'s geometry

  /// - Parameters:
  ///   - imageable: the sheet's imageable size in points (`PageFormat.getImageableWidth/Height`).
  ///   - circuitBounds: `circ.getBounds(g).expand(4)`, in circuit units.
  ///   - headerHeight: `fm.getHeight()`, or 0 when no header is printed.
  ///   - rotateToFit: `ParmsPanel.getRotateToFit()`, seeded checked upstream.
  static func plan(
    imageable: CGSize,
    circuitBounds: CGRect,
    headerHeight: Double,
    rotateToFit: Bool
  ) -> PrintPageLayout {
    var imWidth = Double(imageable.width)
    var imHeight = Double(imageable.height)
    let bw = Double(circuitBounds.width)
    let bh = Double(circuitBounds.height)

    // A circuit with no extent at all: `expand(4)` guarantees 8x8 for a non-empty circuit, so
    // this is only reachable for an empty one. Java would divide by zero and get an infinite
    // scale, which `if (scale < 1.0)` then declines to apply: so it prints a blank page. Same
    // outcome here, stated rather than stumbled into.
    guard bw > 0, bh > 0, imWidth > 0, imHeight > 0 else {
      return PrintPageLayout(
        imageableSize: imageable,
        rotation: .upright,
        fittedScale: 1,
        scale: 1,
        headerHeight: headerHeight,
        circuitRect: CGRect(x: 0, y: headerHeight, width: 0, height: 0),
        isDegenerate: true)
    }

    var scale = min(imWidth / bw, (imHeight - headerHeight) / bh)
    var rotation = PrintRotation.upright

    if rotateToFit && scale < 1.0 / 1.1 {
      let scale2 = min(imHeight / bw, (imWidth - headerHeight) / bh)
      if scale2 >= scale * 1.1 {
        scale = scale2
        rotation = imHeight > imWidth ? .portraitToLandscape : .landscapeToPortrait
        swap(&imWidth, &imHeight)
      }
    }

    let fitted = scale
    // `if (scale < 1.0)`; nothing is enlarged.
    let applied = scale < 1.0 ? scale : 1.0

    if headerHeight > 0 { imHeight -= headerHeight }

    // `imWidth /= scale; imHeight /= scale` happens only inside the `scale < 1.0` branch; with
    // `applied == 1` the division is the identity, so one expression covers both arms.
    let contentWidthInCircuitUnits = imWidth / applied
    let dx = max(0.0, (contentWidthInCircuitUnits - bw) / 2)

    return PrintPageLayout(
      imageableSize: CGSize(width: imWidth, height: imHeight + headerHeight),
      rotation: rotation,
      fittedScale: fitted,
      scale: applied,
      headerHeight: headerHeight,
      circuitRect: CGRect(
        x: applied * dx,
        y: headerHeight,
        width: bw * applied,
        height: bh * applied),
      isDegenerate: !(fitted.isFinite && fitted > 0) || imHeight <= 0)
  }
}
