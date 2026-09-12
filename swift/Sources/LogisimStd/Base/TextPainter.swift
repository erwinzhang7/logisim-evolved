// TextPainter.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.base.Text, the `graphics methods`
// section), https://github.com/logisim-evolution/logisim-evolution. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16). `Text.java:136-185`.
//
// ── Why this file exists ─────────────────────────────────────────────────────────────────────
//
// `Text.swift` closed with a `PAINT (M6):` comment describing exactly what belonged here, and
// that comment sat next to a factory that conformed to neither paint protocol. The consequence
// was measured, not inferred:
//
//     [PROBE] painted=0 prims=0 texts=0
//     [PROBE] instancePaintable=false
//     [PROBE] componentPaintable=false
//
// `CircuitRenderer.render` dispatches on two casts and nothing else:
// `component as? any ComponentPaintable`, then `component.factory as? any InstancePaintable`,
// so a `Text` matched neither arm and fell out of the loop silently. Every free-floating
// annotation a user placed on a schematic was invisible. That is the whole defect: the painter
// arithmetic existed (`Text.estimateBounds`), the factory existed, the registration existed,
// and the conformance between them did not.
//
// ── D9 ───────────────────────────────────────────────────────────────────────────────────────
//
// Nothing here touches AppKit. Text is measured through the `SceneBuilder`'s injected
// `TextMeasurer`, which is how every other painter in this module measures, and the output is
// `RenderScene` primitives. Same rule as `MemPainter` and `IoPainter`.

import Foundation
import LogisimKernel
import LogisimRender

// MARK: - The #2661 policy

/// How a canvas annotation's colour responds to the light/dark appearance.
///
/// ── The problem, precisely ───────────────────────────────────────────────────────────────────
///
/// Upstream issue #2661, *"Text labels on canvas don't adapt to dark/light theme switch"*:
///
/// > Each text label stores its own `ATTR_COLOR` at creation time. The `TEXT_TOOL_COLOR`
/// > preference only affects newly created labels; existing labels are unaffected by
/// > `applyThemeColors()`.
///
/// The port inherited that data model verbatim: `TextAttributes.color` defaults to opaque black
/// and is serialised per instance as `color="#000000"`. Drop into dark mode and every annotation
/// is black-on-black.
///
/// The issue itself says this is **not** a simple fix and floats three designs. Taking them in
/// turn against this tree:
///
/// 1. **Auto-adapt only annotations still on the default colour.** Chosen; see below.
/// 2. **A per-label "auto" option.** Rejected on D16. It needs a new inhabitant in the `color`
///    attribute's value domain, and that inhabitant gets *written into `.circ` files*. A file
///    this port saved would then carry a colour token 4.1.0 cannot parse, which is precisely the
///    class of divergence D16 exists to prevent.
/// 3. **A global preference that rewrites stored colours.** Rejected as destructive. That is
///    upstream's own `applyThemeColors()` shape: it mutates the document, dirties it, and turns
///    a deliberately-chosen red into black with no way back. It is the naive fix the issue warns
///    about.
///
/// ── Why design 1 is cheaper here than upstream ───────────────────────────────────────────────
///
/// Upstream would have to re-walk every component on a theme change. This port does not: the
/// live ink already arrives per frame as `PaintContext.componentColor`, because
/// `CircuitCanvasSurface` re-resolves its palette from the current `NSAppearance` on every push
/// and `CircuitSceneSource.paintContext` threads that through. So "follow the appearance" costs
/// one comparison at paint time, stores nothing, writes nothing back, and changes no file byte.
/// A red annotation is read from the attribute and drawn red in both appearances; a black one,
/// the default, is drawn in whatever ink the canvas is currently using.
///
/// ── The honest limitation ────────────────────────────────────────────────────────────────────
///
/// A user who *deliberately* picks black is indistinguishable from a user who never picked
/// anything, and adapts along with the defaults. This is not an oversight that better code would
/// fix: the `.circ` format stores the RGB triple and nothing else, so the provenance that would
/// separate the two cases does not survive a save/reload. It is undecidable across a round trip,
/// and pretending otherwise would mean inventing a file-format extension: design 2, already
/// rejected. Stated rather than hidden.
///
/// ── Why it ships OFF ─────────────────────────────────────────────────────────────────────────
///
/// D16: the port targets 4.1.0, and 4.1.0 freezes the stored colour. Turning adaptation on is a
/// behaviour change a user will see, so it is the owner's call, not this file's. The mechanism
/// is here, tested in both positions, and one assignment away.
/// `docs/experiments/canvas-text.md` is the write-up.
public enum TextThemePolicy {

  /// The shipped default: `false`, i.e. exactly 4.1.0's behaviour.
  public static let adaptDefaultColoredTextDefault = false

  /// When `true`, an annotation whose stored `ATTR_COLOR` is still the factory default is drawn
  /// in the canvas's live ink (`PaintContext.componentColor`) rather than in the stored black.
  /// An annotation carrying any other colour is always drawn in that colour, in every
  /// appearance; that is the constraint that makes the naive fix wrong.
  public nonisolated(unsafe) static var adaptDefaultColoredText = adaptDefaultColoredTextDefault

  /// `TextAttributes`' factory default: Java's `Color.BLACK`, opaque #000000.
  ///
  /// Compared by value, never by "does it look like the current ink". Keying off a match against
  /// the live ink would make a deliberately-chosen colour adaptive the moment the palette
  /// happened to agree with it, which is the same destruction by a slower route.
  static let defaultColor = ColorSpec(red: 0, green: 0, blue: 0)
}

// MARK: - Painting

extension Text: InstancePaintable {

  /// `Text.paintInstance(InstancePainter)` (`Text.java:167-176`).
  ///
  /// Java:
  /// ```java
  /// gfx.translate(x, y);
  /// gfx.setColor(painter.getAttributeValue(ATTR_COLOR));
  /// paintGhost(painter);
  /// gfx.translate(-x, -y);
  /// ```
  ///
  /// The translate is load-bearing and is the second thing that can silently go missing here:
  /// `paintGhost` draws at (0, 0) unconditionally, so without it every annotation in a circuit
  /// stacks on the origin. `CanvasTextDrawsTests.annotationIsTranslatedToItsLocation` pins it.
  public func paintInstance(_ painter: InstancePainter) {
    let location = painter.location
    let g = painter.g

    g.pushTranslate(location.x, location.y)
    let savedColor = g.color
    g.color = Text.inkColor(for: painter)
    paintGhost(painter)
    g.color = savedColor
    g.popTransform()
  }

  /// `Text.paintGhost(InstancePainter)` (`Text.java:139-164`).
  ///
  /// Two things happen, and upstream's ordering matters: the string is drawn first, then
  /// **re-measured with real metrics and the offset-bounds cache is corrected**. That second
  /// half is why `TextAttributes.setOffsetBoundsCache` exists; its own doc comment names
  /// `Text.paintGhost` as the one upstream caller that reads its return value, and until now
  /// there was no such caller.
  ///
  /// Without the writeback the component's bounds stay at `Text.estimateBounds`' deliberately
  /// crude `size * widest * 2 / 3` guess, which upstream's own comment calls "assume approx
  /// monospace 12x8 aspect ratio". Selection rectangles and hit-testing would run on that guess
  /// forever instead of converging to the real glyph box on first paint.
  ///
  /// One deviation, and it is a subtraction: Java follows the writeback with
  /// `instance.recomputeBounds()`. This port has no such call because it does not need one;
  /// `InstanceComponent.bounds` is computed on demand from `offsetBounds(attributes)` (the same
  /// reasoning `CircuitSubcircuitFactory.swift:245` records), so correcting the cache is
  /// sufficient and the next read picks it up.
  public func paintGhost(_ painter: InstancePainter) {
    guard let attrs = painter.attributeSet as? TextAttributes else { return }

    // Java: `if (text == null || text.equals("")) return;`. An empty annotation draws nothing,
    // and that zero is correct rather than a bug, pinned by `emptyTextDrawsNothing`.
    let text = attrs.text
    guard !text.isEmpty else { return }

    let halign = HAlign(rawValue: attrs.horizontalAlign) ?? .center
    let valign = VAlign(rawValue: attrs.verticalAlign) ?? .baseline

    let g = painter.g
    let savedFont = g.font
    g.font = InstancePainter.sceneFont(attrs.font)

    // `GraphicsUtil.drawText(g, text, 0, 0, halign, valign)`: at the origin, because
    // `paintInstance` has already translated to the component's location.
    g.drawText(text, x: 0, y: 0, halign: halign, valign: valign)

    // ── The re-measure, `Text.java:150-162` ───────────────────────────────────────────────
    //
    // Java trims ONE trailing space before measuring (`text.endsWith(" ") ? substring(0, len-1)`)
    // : one, not all, and only a space. Transcribed as written; a two-space suffix keeps the
    // first.
    let textTrim = text.hasSuffix(" ") ? String(text.dropLast()) : text
    let newBounds: Bounds
    if textTrim.isEmpty {
      newBounds = Bounds.empty
    } else {
      // `GraphicsUtil.getTextBounds(g, textTrim, 0, 0, halign, valign)` then `.expand(4)`.
      //
      // `textBoundsInUserSpace` and not `textBounds`: the box is being stored as an *offset*
      // bounds, i.e. relative to the component's location, and `paintInstance` has a translation
      // in effect. `SceneBuilder`'s own doc names `Text.java:156` as this method's caller.
      // Using the scene-space variant instead would bake the location in twice.
      //
      // Measured rather than reusing the box `drawText` just returned: the drawn string and the
      // measured string differ whenever that trailing space was trimmed.
      newBounds = g.textBoundsInUserSpace(textTrim, x: 0, y: 0, halign: halign, valign: valign)
        .expand(4)
    }
    attrs.setOffsetBoundsCache(newBounds)

    g.font = savedFont
  }

  /// The colour this annotation is drawn in: the whole of the #2661 decision, in one place.
  ///
  /// `TextThemePolicy` documents why it is shaped this way and why it is off by default.
  static func inkColor(for painter: InstancePainter) -> SceneColor {
    let stored = painter.attributeValue(
      Text.attrColor, default: TextThemePolicy.defaultColor)

    if TextThemePolicy.adaptDefaultColoredText, stored == TextThemePolicy.defaultColor {
      // Still on the default: follow the canvas's live ink, which already tracks the system
      // appearance frame by frame. Nothing is written back: the stored attribute, and
      // therefore the saved file, is untouched.
      return painter.context.componentColor
    }
    // A colour the user chose. Drawn verbatim in every appearance.
    return .rgba(RGBA(r: stored.red, g: stored.green, b: stored.blue))
  }
}
