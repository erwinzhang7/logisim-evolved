// LogisimRender: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// Shaped-text cache and the CoreText measurer.
//
// WHAT UPSTREAM DOES PER LABEL, PER FRAME
//
// `GraphicsUtil.drawText` builds a `TextMetrics` (one `Font.getStringBounds` plus one
// `Font.getLineMetrics`), and calls `getTextBounds`, which builds *another* `TextMetrics` for
// the same string, so line 0 of every label is measured twice. Then `g.drawString` shapes the
// run a third time inside Java2D. None of it is cached anywhere in the codebase, and it happens
// on every repaint of every visible label.
//
// WHAT WE DO
//
// Measurement happens once, at scene-build time, and the resolved integer baseline is stored in
// the `TextRun`. Shaping happens once per distinct `(font, string)` pair for the lifetime of the
// cache, and a `CTLine` is reused for every subsequent frame. A schematic's label set is small
// and almost entirely static, component names, pin labels, bus widths, so the steady-state
// hit rate is essentially 100%, and a frame's text cost collapses to one `CTLineDraw` per
// visible label.
//
// The `CTLine` is built with `kCTForegroundColorFromContextAttribute`, so colour is *not* part
// of the cache key: the same shaped line draws in whatever the context's fill colour is. That
// matters because per-instance colour is the one thing that changes per frame (D6), and a
// colour-keyed cache would miss on exactly the strings that change.

import CoreGraphics
import CoreText
import Foundation
import LogisimRender

// MARK: - CoreTextCache

/// Caches `CTFont`s, font metrics, shaped `CTLine`s and their advance widths.
///
/// `@unchecked Sendable`: the state is a handful of dictionaries behind an `NSLock`. It has to
/// be `Sendable` because `TextMeasurer` is; a scene must be buildable off the main thread.
public final class CoreTextCache: @unchecked Sendable {

  /// Shared instance. One cache for the process is right: fonts and labels repeat across every
  /// canvas, thumbnail and print job in the app.
  public static let shared = CoreTextCache()

  private struct LineKey: Hashable {
    var font: SceneFont
    var string: String
  }

  private let lock = NSLock()
  private var fonts: [SceneFont: CTFont] = [:]
  private var metrics: [SceneFont: FontMetrics] = [:]
  private var lines: [LineKey: CTLine] = [:]
  private var widths: [LineKey: Int] = [:]

  private var hits = 0
  private var misses = 0

  /// Distinct shaped lines to retain before the line cache is dropped wholesale.
  ///
  /// A flush rather than an LRU: a schematic's working set is small and static, so the limit is
  /// only ever reached by something pathological (a hex viewer scrolling through thousands of
  /// distinct strings), where an LRU's bookkeeping would cost more than the occasional reshape.
  public let lineLimit: Int

  public init(lineLimit: Int = 4096) {
    self.lineLimit = lineLimit
  }

  // MARK: Fonts

  public func ctFont(for font: SceneFont) -> CTFont {
    lock.lock()
    if let hit = fonts[font] {
      lock.unlock()
      return hit
    }
    lock.unlock()

    let made = CoreTextCache.makeFont(font)

    lock.lock()
    fonts[font] = made
    lock.unlock()
    return made
  }

  /// Java's logical font families as the macOS JDK resolves them
  /// (`fontconfig.properties`: sansserif -> Helvetica, serif -> Times, monospaced -> Courier).
  /// Picking the system font instead would change the advance width of every label and move
  /// every centred string.
  private static func postScriptName(for family: SceneFont.Family) -> String {
    switch family {
    case .sansSerif: return "Helvetica"
    case .serif: return "Times-Roman"
    case .monospaced: return "Courier"
    case .named(let n): return n
    }
  }

  private static func makeFont(_ font: SceneFont) -> CTFont {
    let size = CGFloat(font.size)
    var ct = CTFontCreateWithName(postScriptName(for: font.family) as CFString, size, nil)

    if font.isBold || font.isItalic {
      var traits: CTFontSymbolicTraits = []
      if font.isBold { traits.insert(.traitBold) }
      if font.isItalic { traits.insert(.traitItalic) }
      if let styled = CTFontCreateCopyWithSymbolicTraits(ct, size, nil, traits, traits) {
        ct = styled
      }
    }
    return ct
  }

  // MARK: Metrics

  /// `com.cburch.draw.util.TextMetrics`: each field is `Math.ceil`'d to an int, and
  /// `height = ascent + descent + leading`. Rounding anywhere else moves every label.
  public func metrics(for font: SceneFont) -> FontMetrics {
    lock.lock()
    if let hit = metrics[font] {
      lock.unlock()
      return hit
    }
    lock.unlock()

    let ct = ctFont(for: font)
    let m = FontMetrics(
      ascent: Int(CTFontGetAscent(ct).rounded(.up)),
      descent: Int(CTFontGetDescent(ct).rounded(.up)),
      leading: Int(CTFontGetLeading(ct).rounded(.up)))

    lock.lock()
    metrics[font] = m
    lock.unlock()
    return m
  }

  // MARK: Lines

  /// The shaped line for `(font, string)`, plus whether it came from the cache.
  public func line(for string: String, font: SceneFont) -> (line: CTLine, wasCached: Bool) {
    let key = LineKey(font: font, string: string)

    lock.lock()
    if let hit = lines[key] {
      hits += 1
      lock.unlock()
      return (hit, true)
    }
    lock.unlock()

    let ct = ctFont(for: font)
    let attributes: [NSAttributedString.Key: Any] = [
      kCTFontAttributeName as NSAttributedString.Key: ct,
      // Colour comes from the context, so the cache key is (font, string) only.
      kCTForegroundColorFromContextAttributeName as NSAttributedString.Key: true,
    ]
    let attributed = NSAttributedString(string: string, attributes: attributes)
    let made = CTLineCreateWithAttributedString(attributed)
    let advance = CTLineGetTypographicBounds(made, nil, nil, nil)

    lock.lock()
    if lines.count >= lineLimit {
      lines.removeAll(keepingCapacity: true)
      widths.removeAll(keepingCapacity: true)
    }
    lines[key] = made
    // Java: `(int) font.getStringBounds(text, frc).getWidth()`, truncation, not rounding.
    widths[key] = Int(advance)
    misses += 1
    lock.unlock()
    return (made, false)
  }

  /// Advance width, truncated toward zero exactly as `TextMetrics.width` is.
  public func width(of string: String, font: SceneFont) -> Int {
    if string.isEmpty { return 0 }
    let key = LineKey(font: font, string: string)
    lock.lock()
    if let hit = widths[key] {
      hits += 1
      lock.unlock()
      return hit
    }
    lock.unlock()

    _ = line(for: string, font: font)

    lock.lock()
    let w = widths[key] ?? 0
    lock.unlock()
    return w
  }

  // MARK: Stats

  public struct Stats: Hashable, Sendable {
    public var hits: Int
    public var misses: Int
    public var shapedLines: Int
    public var fonts: Int
  }

  public var stats: Stats {
    lock.lock()
    defer { lock.unlock() }
    return Stats(hits: hits, misses: misses, shapedLines: lines.count, fonts: fonts.count)
  }

  public func resetStats() {
    lock.lock()
    hits = 0
    misses = 0
    lock.unlock()
  }

  public func removeAll() {
    lock.lock()
    fonts.removeAll()
    metrics.removeAll()
    lines.removeAll()
    widths.removeAll()
    lock.unlock()
  }
}

// MARK: - CoreTextMeasurer

/// The production `TextMeasurer`. Shares its cache with the CoreGraphics backend, so a string
/// measured while the scene is built is already shaped by the time the frame draws it.
public final class CoreTextMeasurer: TextMeasurer {
  public let cache: CoreTextCache

  public init(cache: CoreTextCache = .shared) {
    self.cache = cache
  }

  public func metrics(for font: SceneFont) -> FontMetrics {
    cache.metrics(for: font)
  }

  public func width(of string: String, font: SceneFont) -> Int {
    cache.width(of: string, font: font)
  }
}
