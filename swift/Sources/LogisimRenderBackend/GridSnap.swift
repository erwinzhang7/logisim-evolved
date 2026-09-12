// LogisimRender: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// Stroke normalisation: pushing a stroked path onto the DEVICE PIXEL grid, as Java2D does.
//
// ── THIS IS NOT THE COMPONENT GRID SNAP. READ THIS BEFORE EDITING. ──────────────────────────
//
// The name has misled readers into treating this as the port of `Canvas.snapXToGrid` /
// `Location.snapToGrid`, which decide where a *component* lands when a user drops it. It is not.
// Nothing here ever sees a model coordinate, and changing anything in this file cannot move a
// component by so much as one unit. What it does is Java2D's `KEY_STROKE_CONTROL` /
// `VALUE_STROKE_NORMALIZE`: a sub-pixel nudge applied at rasterisation time so a thin line
// covers one row of pixels instead of smearing grey across two.
//
// The component grid snap lives elsewhere, and there are two of them on two different grids:
//
//   * `CanvasGrid.snapXToGrid` / `snapYToGrid`: LogisimUI/Tools/ToolGeometry.swift.
//     `com.cburch.logisim.gui.main.Canvas.snapXToGrid(int)`: a 10-unit grid,
//     round-half-away-from-zero. Duplicated at `SelectionBase.snapXToGrid`.
//   * `Location.create(x, y, hasToSnap:)`: LogisimKernel/Location.swift.
//     `com.cburch.logisim.data.Location.create`: a 5-unit grid, truncating toward zero, because
//     upstream's `Math.round(x / 5) * 5` divides in `int` and the round is a no-op.
//
// `GridSnapParityTests` (Tests/LogisimUITests) pins both against the shipped 4.1.0 jar.
// `GridSnapTests` (Tests/LogisimRenderBackendTests) pins this file, at the pixel.
//
// WHY THIS FILE EXISTS AT ALL
//
// Every coordinate in a `.circ` file is an integer on a 10-unit grid, and upstream draws with
// `Graphics`'s `int` overloads throughout. Java2D's default `KEY_STROKE_CONTROL` is
// `VALUE_STROKE_NORMALIZE`, which pushes a stroked path onto the pixel grid before rasterising
// so that thin lines come out uniform. Concretely, for an odd pen width it moves the geometry
// to the nearest *pixel centre*; for an even width the pen already straddles a pixel boundary
// symmetrically, so it does not.
//
// CoreGraphics does none of that. A `CGContext` stroke of width 1 along y = 10 covers
// y in [9.5, 11.5) at half coverage in two rows: a grey, two-pixel-wide line. Every wire, every
// gate outline, every component box in every file would render soft and a half pixel north of
// where the reference puts it. That is what "renders subtly off-grid" means, and it is not
// something an image-diff harness would ever localise for you.
//
// THE RULE
//
//   odd *device* pen width  -> offset the geometry by half a device pixel in x and y
//   even device pen width   -> no offset
//   fills                   -> no offset (Java fills whole pixels from the integer coordinate)
//   text                    -> no offset (baseline is integral; glyph hinting handles the rest)
//
// THE THREE COORDINATE SPACES, AND WHY TWO SCALES ARE NEEDED
//
//   scene units --( viewport.scale )--> destination units (points) --( backingScale )--> device px
//
// `RenderViewport.scale` is the zoom: *destination units per scene unit*. On macOS the
// destination unit is a **point**, not a pixel. `backingScale` is `NSWindow.backingScaleFactor`
// , device pixels per point, and it is 2 on every Retina display, i.e. on every machine this
// port targets.
//
// The odd/even test is a claim about *device pixels*, so it must run on
// `penWidth * scale * backingScale`. Deciding it on `penWidth * scale` alone is wrong on
// exactly the hardware we ship to: a 1-unit pen at zoom 1 on a 2x display is **two** device
// pixels wide, straddles nothing, and must not be nudged, but the parity test on `1 * 1 = 1`
// calls it odd and returns 0.5 points, which translates the whole batch by a full device pixel.
// Every wire in the file then sits one physical pixel south-east of where the reference puts
// it: crisp, and wrong, which is the hardest kind of wrong to notice.
//
// Likewise the offset itself is half a *device* pixel, so in scene units it is
// `0.5 / (scale * backingScale)`, and `BasicStroke(0)` is one device pixel, `1 / (scale *
// backingScale)` scene units, at any zoom on any display.
//
// The nudge has to be applied outside any per-primitive rotation, because a rotated gate is
// still rasterised onto the same screen pixel grid, which is why the renderer concatenates it
// before the primitive transform, never after.
//
// The other half of the contract is on the viewport: the mapping from scene to device must
// itself be device-pixel-aligned, or the offset lands mid-pixel anyway. `RenderViewport
// .alignedToPixelGrid()` is that half, and it too snaps to device pixels rather than to points.

import CoreGraphics
import LogisimRender

public enum GridSnap {

  /// Sanitises a scale factor the way `RenderViewport.init` does, so a caller passing a raw
  /// value gets the same answer the renderer would compute from a viewport.
  @inlinable
  public static func sanitized(_ factor: Double) -> Double {
    factor.isFinite && factor > 0 ? factor : 1
  }

  /// Scene units -> device pixels: the zoom times the backing-store scale.
  ///
  /// This, not `viewport.scale`, is the number every pixel-grid decision is made on.
  @inlinable
  public static func deviceScale(scale: Double, backingScale: Double) -> Double {
    sanitized(scale) * sanitized(backingScale)
  }

  /// How many device pixels wide the pen actually rasterises.
  ///
  /// - Parameters:
  ///   - penWidth: the pen width in scene units. `0` is Java's `BasicStroke(0)`.
  ///   - scale: destination units (points) per scene unit: the zoom.
  ///   - backingScale: device pixels per destination unit. `NSWindow.backingScaleFactor`.
  @inlinable
  public static func deviceWidth(penWidth: Int, scale: Double, backingScale: Double = 1) -> Double
  {
    // `BasicStroke(0)` is "the thinnest line the device can render": exactly one device pixel,
    // at any zoom, on any backing store. It does not scale, so neither does its parity, which
    // is always odd.
    if penWidth <= 0 { return 1 }
    return Double(penWidth) * deviceScale(scale: scale, backingScale: backingScale)
  }

  /// Half a device pixel expressed in scene units, or `0` when no nudge applies.
  ///
  /// - Parameters:
  ///   - penWidth: the pen width in scene units. `0` is Java's `BasicStroke(0)`, a one-device-
  ///     pixel hairline, which is odd and therefore always snapped.
  ///   - scale: destination units (points) per scene unit: the zoom.
  ///   - backingScale: device pixels per destination unit. Defaults to `1` so a caller that has
  ///     no backing store in play (an offscreen `CGBitmapContext`, a PDF page) is unaffected.
  @inlinable
  public static func strokeOffset(penWidth: Int, scale: Double, backingScale: Double = 1) -> Double
  {
    guard scale.isFinite, scale > 0, backingScale.isFinite, backingScale > 0 else { return 0 }
    let devScale = deviceScale(scale: scale, backingScale: backingScale)
    let width = deviceWidth(penWidth: penWidth, scale: scale, backingScale: backingScale)
    let rounded = width.rounded()
    // `truncatingRemainder`, not `Int(rounded) % 2`: at an extreme zoom the device width can
    // exceed `Int.max` and the conversion would trap.
    guard rounded.truncatingRemainder(dividingBy: 2) != 0 else { return 0 }
    return 0.5 / devScale
  }

  /// The same decision, taken straight from the viewport. This is what the backend calls, so
  /// that adding a scale factor to the viewport can never again leave a call site behind.
  @inlinable
  public static func strokeOffset(penWidth: Int, viewport: RenderViewport) -> Double {
    strokeOffset(penWidth: penWidth, scale: viewport.scale, backingScale: viewport.backingScale)
  }

  /// The line width to hand `CGContext.setLineWidth`, in scene units.
  ///
  /// Java's `BasicStroke(0)` is documented as "the thinnest line the device can render", which
  /// is one *device pixel* however far you have zoomed: so it scales with neither the CTM nor
  /// the backing store. On a 2x display `1 / scale` scene units would be two device pixels, i.e.
  /// twice the thinnest line, and would also disagree with the parity `strokeOffset` assumes.
  @inlinable
  public static func lineWidth(penWidth: Int, scale: Double, backingScale: Double = 1) -> Double {
    if penWidth <= 0 { return 1.0 / deviceScale(scale: scale, backingScale: backingScale) }
    return Double(penWidth)
  }

  @inlinable
  public static func lineWidth(penWidth: Int, viewport: RenderViewport) -> Double {
    lineWidth(penWidth: penWidth, scale: viewport.scale, backingScale: viewport.backingScale)
  }

  /// `true` when scene integers map onto **device pixel** boundaries, i.e. when snapping can
  /// actually produce crisp output. A fractional scroll offset breaks it; `RenderViewport
  /// .alignedToPixelGrid()` restores it.
  ///
  /// Note this is deliberately a device-pixel test and not a point test: at `backingScale == 2`
  /// a scene origin of 3.5 points is a whole 7 device pixels and is perfectly aligned, so
  /// demanding integral points would reject viewports that are in fact fine: and, worse, would
  /// pass viewports that are integral in points but not in pixels once a fractional zoom is in
  /// play.
  public static func isPixelAligned(_ viewport: RenderViewport, tolerance: Double = 1e-6) -> Bool {
    func integral(_ v: Double) -> Bool { abs(v - v.rounded()) <= tolerance }
    let devScale = deviceScale(scale: viewport.scale, backingScale: viewport.backingScale)
    let backing = sanitized(viewport.backingScale)
    return integral(viewport.sceneOriginX * devScale)
      && integral(viewport.sceneOriginY * devScale)
      && integral(Double(viewport.rect.minX) * backing)
      && integral(Double(viewport.rect.minY) * backing)
  }
}
