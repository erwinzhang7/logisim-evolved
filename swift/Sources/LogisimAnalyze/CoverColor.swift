//
//  CoverColor.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution, specifically
//  `src/main/java/com/cburch/logisim/analyze/data/CoverColor.java`. GPL-3.0-only.
//  See LICENSE.md.
//

/// Java: `com.cburch.logisim.analyze.data.CoverColor`: hands out the next colour in a
/// 16-entry rotation, so that adjacent K-map covers are drawn in different colours.
///
/// **This vends a palette index, not a colour.** D9 keeps colours out of the modules below
/// the UI (the same rule that makes `Value.getColor()` return an index in the kernel), and
/// Java's version reaches straight into `AppPreferences.KMAP1_COLOR`…`KMAP16_COLOR` and
/// wraps each in a `java.awt.Color`. What is actually *model* behaviour here is the
/// rotation, which cover gets which slot, and that `reset()` restarts it, and that comes
/// across exactly. The UI resolves an index to an `NSColor` from its own preferences.
///
/// `defaultRGB` is carried because `AnalyzerTexWriter` has to emit literal
/// `\definecolor{…}{RGB}{r,g,b}` lines into the LaTeX preamble; a `.tex` file has nowhere to
/// put "ask the preferences later". A UI that has live preferences should pass its own
/// values to `AnalyzerTexWriter.save(…, palette:)` rather than let these defaults be used.
public final class CoverColor {
  /// Java: `CoverColor.COVER_COLOR`, the process-wide singleton both callers use.
  ///
  /// It is mutable shared state with a rotation cursor in it, exactly as upstream, and it is
  /// therefore no more thread-safe than upstream's. Both callers (`KarnaughMapGroups.update`
  /// and `AnalyzerTexWriter.doSave`) run on the UI thread in Java.
  public static let shared = CoverColor()

  /// Java: the `KMAP1_COLOR`…`KMAP16_COLOR` preference *defaults*, `0xRRGGBB`, in order.
  public static let defaultRGB: [Int] = [
    0x80_00_00, 0xE6_19_4B, 0xFA_BE_BE, 0xAA_6E_28,
    0xF5_82_30, 0xFF_D7_B4, 0x80_80_00, 0xFF_FF_19,
    0xD2_F5_3C, 0x00_00_80, 0x91_1E_B4, 0x3C_B4_AF,
    0x00_82_CB, 0xE6_BE_FF, 0xAA_FF_C3, 0xF0_32_E6,
  ]

  private var index = 0

  public init() {}

  /// Java: `nrOfColors()`.
  public var colorCount: Int { CoverColor.defaultRGB.count }

  /// Java: `getNext()`: the next index in the rotation, wrapping at 16.
  public func next() -> Int {
    if index >= colorCount { index = 0 }
    defer { index += 1 }
    return index
  }

  /// Java: `reset()`. `KarnaughMapGroups.update()` calls this before rebuilding its covers,
  /// which is what makes the colour assignment a function of the cover list alone rather
  /// than of how many maps have been drawn since launch.
  public func reset() { index = 0 }

  /// Java: `getColorName(Color)`; the `\definecolor` name `AnalyzerTexWriter` emits.
  ///
  /// Upstream looks the colour up in its list and returns `null` for an unknown one, which
  /// then lands in the `.tex` as the literal text `null`. Here the index *is* the identity,
  /// so the lookup cannot fail for an in-range index; out of range returns `nil` and the
  /// writer treats that the same way Java does.
  public static func colorName(index: Int) -> String? {
    guard index >= 0 && index < defaultRGB.count else { return nil }
    return "LogisimKMapColor\(index)"
  }

  /// Java: `getColor(int)`, decomposed. `nil` out of range, matching upstream.
  public static func rgb(index: Int) -> (red: Int, green: Int, blue: Int)? {
    guard index >= 0 && index < defaultRGB.count else { return nil }
    let v = defaultRGB[index]
    return ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
  }
}
