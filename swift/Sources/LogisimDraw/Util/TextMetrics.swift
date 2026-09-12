// TextMetrics.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/draw/util/TextMetrics.java. Copyright by the Logisim-evolution developers. This
// translation is a derivative work and is therefore licensed GPL-3.0-only. See LICENSE.md.
//
// ── Seam: font measurement is a rendering concern ────────────────────────────────────────────
//
// Java's `TextMetrics` measures a string against a live AWT `Graphics`/`FontRenderContext` or a
// `Component`'s `FontMetrics`. There is no Foundation-only equivalent, and this module must not
// import CoreGraphics/CoreText (D9-style, and explicit for this task: no drawing API, no
// CoreGraphics). So text measurement is a seam: `TextMetricsProviding` is the contract a
// renderer (CoreText, in `LogisimRender`) implements and hands to `EditableLabel`.
//
// This is not merely a nice-to-have abstraction: it mirrors a real latent behaviour in the
// Java. `EditableLabel.getBounds()`/`.contains()` read `width`/`ascent`/`descent` fields that
// start at zero and are populated ONLY as a side effect of `EditableLabel.paint(Graphics)`
// calling `computeDimensions`. The `dimsKnown` flag that looks like it should gate this is
// never actually read anywhere in `EditableLabel.java`: so in upstream, a freshly constructed
// `Text` shape reports zero-sized bounds and "contains nothing" until it has been painted at
// least once. This port preserves that shape exactly: `EditableLabel`'s metrics start at zero
// and only change when something calls `EditableLabel.measure(using:)`; there is no implicit
// "measure on first bounds query."

import LogisimKernel

/// The contract `EditableLabel` needs from a renderer to lay out text: `java.awt.FontMetrics`,
/// reduced to the three numbers `EditableLabel` actually reads.
public protocol TextMetricsProviding {
  /// - Returns: `(width, ascent, descent)` for `text` set in `font`. Mirrors
  ///   `TextMetrics(Graphics, Font, String)`: `width` is the string's advance width; `ascent`/
  ///   `descent` come from the font's line metrics (rounded up, as Java's `Math.ceil` does).
  func measure(text: String, font: FontSpec) -> (width: Int, ascent: Int, descent: Int)
}
