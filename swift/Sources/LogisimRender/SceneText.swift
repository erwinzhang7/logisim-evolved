// LogisimRender: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// Text: fonts, the alignment model, and Java-identical layout arithmetic.
//
// Text is the one primitive whose geometry is not known until something measures it, so this
// is where the port's text-performance win is decided. Upstream re-shapes on every paint:
// `GraphicsUtil.drawText` builds a `TextMetrics` (one `getStringBounds` + one
// `getLineMetrics`), and `getTextBounds` inside it builds *another* `TextMetrics` for the
// same string; line 0 is measured twice, every frame, for every label
// (`GraphicsUtil.java:166-167`, `:201`).
//
// Here, measurement happens once at scene-build time. The resolved integer baseline origin
// and the box the string occupies are stored in the `TextRun`, so the backend does zero
// layout arithmetic and (via `CoreTextMeasurer`'s CTLine cache) zero re-shaping.

import Foundation

// MARK: - Alignment

/// Horizontal alignment. Raw values are `GraphicsUtil.H_LEFT/H_CENTER/H_RIGHT`, so a ported
/// call site can carry the constant across unchanged.
public enum HAlign: Int, Hashable, Sendable, CaseIterable {
  case left = -1
  case center = 0
  case right = 1
}

/// Vertical alignment. Raw values are `GraphicsUtil.V_TOP/V_CENTER/V_BASELINE/V_BOTTOM/
/// V_CENTER_OVERALL`.
public enum VAlign: Int, Hashable, Sendable, CaseIterable {
  case top = -1
  case center = 0
  case baseline = 1
  case bottom = 2
  /// `V_CENTER_OVERALL`: centres on the full line box rather than on the ascent.
  case centerOverall = 3
}

// MARK: - SceneFont

/// A font request. Value type, `Hashable`, and free of any platform handle, so it doubles as
/// the cache key for shaped lines.
public struct SceneFont: Hashable, Sendable {
  /// Java's logical font families, plus an escape hatch for a concrete face.
  public enum Family: Hashable, Sendable {
    case sansSerif
    case serif
    case monospaced
    case named(String)
  }

  public var family: Family
  public var size: Double
  public var isBold: Bool
  public var isItalic: Bool

  public init(family: Family = .sansSerif, size: Double = 12, bold: Bool = false, italic: Bool = false) {
    self.family = family
    self.size = size
    self.isBold = bold
    self.isItalic = italic
  }

  /// `StdAttr.FONT`'s default: `new Font("SansSerif", Font.PLAIN, 12)`.
  public static let `default` = SceneFont()

  public func withSize(_ size: Double) -> SceneFont {
    var f = self
    f.size = size
    return f
  }
}

// MARK: - FontMetrics

/// Java `com.cburch.draw.util.TextMetrics`, minus the `Graphics` it needed to exist.
///
/// Every field is an integer because upstream's are: `ascent = (int) Math.ceil(...)` and so
/// on, and every layout decision downstream is integer arithmetic on them. Rounding here in a
/// different place than Java does would move every label by up to a pixel.
public struct FontMetrics: Hashable, Sendable {
  public var ascent: Int
  public var descent: Int
  public var leading: Int

  public init(ascent: Int, descent: Int, leading: Int) {
    self.ascent = ascent
    self.descent = descent
    self.leading = leading
  }

  /// `TextMetrics.height = ascent + descent + leading`.
  public var height: Int { ascent + descent + leading }
}

// MARK: - TextMeasurer

/// Supplies text metrics to the scene builder.
///
/// The scene must be buildable without a drawing context, that is the whole point of D6, so
/// measurement is a protocol rather than a `CGContext` reach-in. `CoreTextMeasurer` is the
/// production implementation and shares its shaped-line cache with the CoreGraphics backend;
/// `NominalTextMeasurer` is deterministic and lets scene-layout tests run headless.
public protocol TextMeasurer: AnyObject, Sendable {
  func metrics(for font: SceneFont) -> FontMetrics
  /// Advance width, truncated toward zero; Java does `(int) font.getStringBounds(...).getWidth()`.
  func width(of string: String, font: SceneFont) -> Int
}

// MARK: - TextLayout

/// Java's `GraphicsUtil.getTextBounds` / `drawText` arithmetic, reproduced exactly.
///
/// Reproduced literally, including the integer divisions: `width / 2` and `ascent / 2`
/// truncate toward zero in both languages, and a label whose width is odd sits one pixel left
/// of true centre in upstream. Rounding it "properly" would put every centred label in the
/// corpus half a pixel off where the reference renders it.
public enum TextLayout {
  /// `GraphicsUtil.getTextBounds(g, text, x, y, halign, valign)`.
  ///
  /// Returns the box in Java's `(x, y, width, height)` form.
  public static func textBox(
    width: Int, metrics: FontMetrics, x: Int, y: Int, halign: HAlign, valign: VAlign
  ) -> (x: Int, y: Int, width: Int, height: Int) {
    var rx = x
    var ry = y
    let ascent = metrics.ascent
    let height = metrics.height

    switch halign {
    case .left: break
    case .center: rx -= width / 2
    case .right: rx -= width
    }

    switch valign {
    case .top: break
    case .center: ry -= ascent / 2
    case .centerOverall: ry -= height / 2
    case .baseline: ry -= ascent
    case .bottom: ry -= height
    }

    return (rx, ry, width, height)
  }

  /// The pen position `GraphicsUtil.drawText` finally hands to `g.drawString`:
  /// `(bd.x, bd.y + tm.ascent)`.
  public static func baselineOrigin(
    box: (x: Int, y: Int, width: Int, height: Int), metrics: FontMetrics
  ) -> (x: Int, y: Int) {
    (box.x, box.y + metrics.ascent)
  }
}

// MARK: - TextRun

/// A fully resolved piece of text. Nothing here needs re-deriving at draw time.
public struct TextRun: Hashable, Sendable {
  public var string: String
  public var font: SceneFont
  /// Pen position for the glyph run, in scene coordinates. Left edge, on the baseline.
  public var baselineX: Int32
  public var baselineY: Int32
  /// The box the string occupies, in Java's `(x, y, width, height)` form. Used for the
  /// background fill and for culling.
  public var boxX: Int32
  public var boxY: Int32
  public var boxWidth: Int32
  public var boxHeight: Int32
  public var halign: HAlign
  public var valign: VAlign
  /// `nil` unless the call site was one of the `drawText(..., fg, bg)` overloads, which fill
  /// the box before drawing.
  public var background: ColorSlot?

  public init(
    string: String,
    font: SceneFont,
    baselineX: Int32,
    baselineY: Int32,
    boxX: Int32,
    boxY: Int32,
    boxWidth: Int32,
    boxHeight: Int32,
    halign: HAlign,
    valign: VAlign,
    background: ColorSlot? = nil
  ) {
    self.string = string
    self.font = font
    self.baselineX = baselineX
    self.baselineY = baselineY
    self.boxX = boxX
    self.boxY = boxY
    self.boxWidth = boxWidth
    self.boxHeight = boxHeight
    self.halign = halign
    self.valign = valign
    self.background = background
  }

  public var bounds: SceneBounds {
    SceneBounds(x: Int(boxX), y: Int(boxY), width: Int(boxWidth), height: Int(boxHeight))
  }
}

// MARK: - NominalTextMeasurer

/// A platform-independent measurer with fixed ratios.
///
/// Exists so scene-layout behaviour can be tested without CoreText, and so a headless
/// differential run produces the same scene on any machine. Not for on-screen use.
public final class NominalTextMeasurer: TextMeasurer {
  public let ascentRatio: Double
  public let descentRatio: Double
  public let leadingRatio: Double
  public let advanceRatio: Double

  public init(
    ascentRatio: Double = 0.8,
    descentRatio: Double = 0.2,
    leadingRatio: Double = 0.0,
    advanceRatio: Double = 0.6
  ) {
    self.ascentRatio = ascentRatio
    self.descentRatio = descentRatio
    self.leadingRatio = leadingRatio
    self.advanceRatio = advanceRatio
  }

  public func metrics(for font: SceneFont) -> FontMetrics {
    FontMetrics(
      ascent: Int((font.size * ascentRatio).rounded(.up)),
      descent: Int((font.size * descentRatio).rounded(.up)),
      leading: Int((font.size * leadingRatio).rounded(.up)))
  }

  public func width(of string: String, font: SceneFont) -> Int {
    Int(Double(string.count) * font.size * advanceRatio)
  }
}
