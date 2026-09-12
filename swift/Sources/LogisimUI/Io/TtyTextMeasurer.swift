// TtyTextMeasurer.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (the `tempGraphics.getFontMetrics().charWidth('W')` inside
// com.cburch.logisim.std.io.Tty.getOffsetBounds),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// HOW WIDE A TTY IS ON THE CANVAS.
//
// Upstream sizes the component from a LIVE font measurement:
//
// ```java
// // Tty.getOffsetBounds(AttributeSet)
// final var image = new BufferedImage(1, 1, BufferedImage.TYPE_INT_RGB);
// final var tempGraphics = image.getGraphics();
// tempGraphics.setFont(DEFAULT_FONT);
// final var width = 2 * BORDER + cols * tempGraphics.getFontMetrics().charWidth('W');
// ```
//
// `Tty.columnWidth` is the port of that expression and reads `Tty.textMeasurer`, which was
// declared and assigned NOWHERE: so every placed TTY fell back to `Tty.COL_WIDTH`, the constant
// upstream declares and never paints with.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// ── THE MEASUREMENT THAT MATTERS: `charWidth`, NOT `getStringBounds` ─────────────────────────
//
// **Installing `CoreTextMeasurer` here is wrong, and the jar oracle says so in nine rows.**
// Measured, `swift test` on this tree with `CoreTextMeasurer` installed into the seam:
//
//     I/O/TTY [<default>]  java=0,-122,236,132  swift=0,-122,204,132
//     I/O/TTY [cols=60]    java=0,-122,432,132  swift=0,-122,372,132
//     I/O/TTY [cols=119]   java=0,-122,845,132  swift=0,-122,726,132
//     I/O/TTY [cols=120]   java=0,-122,852,132  swift=0,-122,732,132
//     … and five `rows=` rows, same width divergence
//
// `OffsetBoundsOracleTests` went from 0 mismatches to 9, all of them TTY. Back out the numbers:
// every Java row is `2 * BORDER + cols * 7`, so the JDK's `charWidth('W')` for
// `Font("monospaced", PLAIN, 11)` is exactly **7**. Courier at 11pt has a 6.6pt advance, and
// `TextMeasurer.width` is contractually TRUNCATING,
//
//     /// Advance width, truncated toward zero, Java does
//     /// `(int) font.getStringBounds(...).getWidth()`.       (LogisimRender/SceneText.swift:107)
//
// , so it answers 6, and every TTY comes out `cols` pixels narrow. That is a real divergence
// between two different Java measurement APIs, not a rounding preference:
// `TextMetrics`/`getStringBounds` truncates, `FontMetrics.charWidth` rounds. `Tty.getOffsetBounds`
// calls the second one. `SceneBuilder`'s layout calls the first, and must keep truncating.
//
// So this type exists to supply `charWidth` semantics, the rounded advance, for the one seam
// that needs them. It is installed into `Tty.textMeasurer` and nowhere else, and it must not be
// handed to a `SceneBuilder`: doing so would move every centred label by up to a pixel.
//
// ── THE COINCIDENCE, STATED PLAINLY SO NOBODY "SIMPLIFIES" IT AWAY ───────────────────────────
//
// `Tty.COL_WIDTH` is 7, and `charWidth('W')` for `DEFAULT_FONT` is also 7: so on this machine
// the nil-seam fallback and a correct measurement agree, and the box width does NOT change when
// this is installed. The fallback was never a fidelity gap for the shipped font; it was a
// hardcoded constant that happened to be right. What the install buys is that the box now
// follows the font actually resolved rather than asserting a number: `DEFAULT_FONT` is fixed at
// monospaced/11 upstream, but which physical face "monospaced" resolves to is a platform
// decision, and a machine without Courier gets a different advance and a wrong box today.
//
// It also means the tempting assertion, "the width changes once the measurer is installed", is
// green only against a measurer that is WRONG. `IoPlatformSeamInstallTests` says so, and pins the
// box to the jar's numbers plus a sentinel instead.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import CoreText
import LogisimRender
import LogisimRenderBackend

/// `java.awt.FontMetrics.charWidth(char)` as a `TextMeasurer`, for `Tty.textMeasurer` only.
///
/// Shares `CoreTextCache.shared` with the renderer, so the string is shaped once for the process
/// however many placements ask; only the float→int step differs from `CoreTextMeasurer`.
public final class TtyCharWidthMeasurer: TextMeasurer {

  /// Deliberately the shared cache. `CoreTextCache.line(for:font:)` is the expensive half and it
  /// is identical for both measurers; keeping them on one cache means installing this costs no
  /// extra shaping at all.
  public let cache: CoreTextCache

  public init(cache: CoreTextCache = .shared) {
    self.cache = cache
  }

  public func metrics(for font: SceneFont) -> FontMetrics {
    cache.metrics(for: font)
  }

  /// The rounded advance: `FontMetrics.charWidth` / `FontMetrics.stringWidth`, which round where
  /// `TextMetrics`/`getStringBounds` truncate. See the file header for the nine oracle rows that
  /// distinguish the two.
  public func width(of string: String, font: SceneFont) -> Int {
    guard !string.isEmpty else { return 0 }
    let (line, _) = cache.line(for: string, font: font)
    let advance = CTLineGetTypographicBounds(line, nil, nil, nil)
    return Int(advance.rounded())
  }
}

/// The one measurer this process installs into `Tty.textMeasurer`.
///
/// An enum rather than a class: there is nothing to instantiate, and nothing may hold a second
/// one. `TextMeasurer` refines `Sendable`, which is what lets a `static let` of it cross into
/// `LogisimStd`'s D1 world and be read from the layout path without further ceremony.
///
/// `LogisimFileProjectHostFactory.installProcessSeams()` runs on EVERY host construction by
/// design, so the value it assigns has to be stable: assigning a freshly-built measurer there
/// would swap the process-global for a new object each time, which is the object-identity churn
/// board #67 is about and the reason `VhdlContentReader.handler` is guarded at that site.
/// Assigning this `static let` is idempotent.
public enum TtyTextMeasurer {

  /// Deliberately not private: `IoPlatformSeamInstallTests` asserts the seam holds *this* object,
  /// which is the difference between "a measurer was installed" and "the measurer with
  /// `charWidth` semantics was installed".
  public static let shared: any TextMeasurer = TtyCharWidthMeasurer()
}
