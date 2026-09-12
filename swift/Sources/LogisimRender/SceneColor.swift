// LogisimRender: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// Colour model for the retained scene (D6/D9).
//
// The load-bearing property, from the performance survey: schematic geometry is static
// integer-grid, and the *only* thing that changes between simulation frames is which
// palette entry a wire or port draws in. Wire endpoints do not move.
//
// So no primitive stores a colour. Every primitive stores a `ColorSlot`, which indexes
// `RenderScene.colorSlots`; a flat `[PaletteIndex]` buffer that is the entire per-frame
// delta. Resolving a slot is two array reads:
//
//     colorSlots[slot] -> PaletteIndex -> ScenePalette/theme -> RGBA
//
// `colorSlots` is a `[UInt16]` in memory, which is exactly what a Metal backend uploads
// per frame at M9 while the vertex buffers stay resident. Nothing about that plan leaks
// into the component-facing API.

import LogisimKernel

// MARK: - RGBA

/// A non-premultiplied sRGB colour, one byte per channel.
///
/// Byte layout is fixed and matches what a GPU vertex attribute wants, so the M9 backend
/// can upload `ScenePalette.entries` verbatim.
public struct RGBA: Hashable, Sendable, CustomStringConvertible {
  public var r: UInt8
  public var g: UInt8
  public var b: UInt8
  public var a: UInt8

  public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
    self.r = r
    self.g = g
    self.b = b
    self.a = a
  }

  /// Java `new Color(int)`; the alpha byte of the argument is **ignored** and the result is
  /// opaque. `AppPreferences` stores its colours this way (e.g. `0x99999999` is opaque grey,
  /// not 60%-alpha grey), so this is the constructor that reproduces upstream's palette.
  public init(javaRGB: UInt32) {
    self.init(
      r: UInt8((javaRGB >> 16) & 0xFF),
      g: UInt8((javaRGB >> 8) & 0xFF),
      b: UInt8(javaRGB & 0xFF),
      a: 255)
  }

  /// Java `new Color(int, true)`, honours the alpha byte.
  public init(javaARGB: UInt32) {
    self.init(
      r: UInt8((javaARGB >> 16) & 0xFF),
      g: UInt8((javaARGB >> 8) & 0xFF),
      b: UInt8(javaARGB & 0xFF),
      a: UInt8((javaARGB >> 24) & 0xFF))
  }

  /// `0xAARRGGBB`, the form `AppPreferences` persists.
  public var argb: UInt32 {
    (UInt32(a) << 24) | (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
  }

  public func withAlpha(_ alpha: UInt8) -> RGBA {
    RGBA(r: r, g: g, b: b, a: alpha)
  }

  public var description: String {
    String(format: "#%08X", argb)
  }

  public static let black = RGBA(javaRGB: 0x00_0000)
  public static let white = RGBA(javaRGB: 0xFF_FFFF)
  public static let gray = RGBA(javaRGB: 0x80_8080)
  public static let lightGray = RGBA(javaRGB: 0xC0_C0C0)
  public static let red = RGBA(javaRGB: 0xFF_0000)
  public static let blue = RGBA(javaRGB: 0x00_00FF)
  public static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)
}

// MARK: - PaletteIndex

/// An index into `ScenePalette`.
///
/// Indices `0 ..< ValuePalette.reservedCount` are reserved and mirror `ValuePalette` one for
/// one, so `PaletteIndex(.trueValue).rawValue == ValuePalette.trueValue.rawValue`. Everything
/// above that is a literal colour interned while the scene was built.
public struct PaletteIndex: Hashable, Sendable, Comparable, CustomStringConvertible {
  public var rawValue: UInt16

  public init(rawValue: UInt16) { self.rawValue = rawValue }

  public init(_ value: ValuePalette) {
    self.rawValue = UInt16(value.rawValue)
  }

  /// The `ValuePalette` case this index names, or `nil` if it is an interned literal colour.
  public var valuePalette: ValuePalette? {
    ValuePalette(rawValue: Int(rawValue))
  }

  public static func < (lhs: PaletteIndex, rhs: PaletteIndex) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  public var description: String {
    if let v = valuePalette { return "palette(\(v))" }
    return "palette#\(rawValue)"
  }
}

extension ValuePalette {
  /// Number of palette indices reserved for simulation values. Everything below this is
  /// re-themable at render time without touching the scene.
  public static let reservedCount: Int = ValuePalette.allCases.count
}

// MARK: - SceneColor

/// What component code writes when it wants a colour. Interned into a `PaletteIndex` by the
/// builder; never stored in a primitive.
public enum SceneColor: Hashable, Sendable {
  /// A literal colour. Interned and deduplicated.
  case rgba(RGBA)
  /// A simulation-value colour. Resolved through the render-time theme, so changing the
  /// user's "true" colour re-themes every wire without rebuilding a single primitive.
  case palette(ValuePalette)

  public static func rgb(_ javaRGB: UInt32) -> SceneColor { .rgba(RGBA(javaRGB: javaRGB)) }

  public static let black = SceneColor.rgba(.black)
  public static let white = SceneColor.rgba(.white)
}

// MARK: - ColorSlot

/// Index into `RenderScene.colorSlots`. Primitives store this; it is the only colour-shaped
/// field in the whole geometry stream.
///
/// A *static* slot is interned and shared by every primitive that asked for the same
/// `SceneColor`. A *dynamic* slot is unique to one emitter and is what the caller rewrites
/// per frame (`RenderScene.setColor(_:to:)`).
public struct ColorSlot: Hashable, Sendable, CustomStringConvertible {
  public var rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }
  public var description: String { "slot#\(rawValue)" }
}

// MARK: - ScenePalette

/// Slot table: `PaletteIndex` -> `RGBA`. Built while the scene is built and immutable
/// afterwards. The first `ValuePalette.reservedCount` entries are placeholders that the
/// render-time `ValueColorTheme` overrides.
public struct ScenePalette: Sendable {
  public private(set) var entries: [RGBA]
  private var lookup: [UInt32: PaletteIndex]

  public init() {
    // Reserve the ValuePalette range up front so `PaletteIndex(.trueValue)` is always valid.
    var e = [RGBA](repeating: .black, count: ValuePalette.reservedCount)
    let defaults = ValueColorTheme.logisim
    for c in ValuePalette.allCases {
      e[c.rawValue] = defaults[c]
    }
    self.entries = e
    self.lookup = [:]
  }

  public var count: Int { entries.count }

  /// Interns a literal colour, deduplicating. `UInt16.max` distinct literal colours is far
  /// beyond anything a schematic produces; the cap is enforced rather than trapped so a
  /// pathological file degrades to a shared colour instead of crashing (D13 in spirit).
  public mutating func intern(_ color: RGBA) -> PaletteIndex {
    if let hit = lookup[color.argb] { return hit }
    guard entries.count < Int(UInt16.max) else {
      return PaletteIndex(rawValue: UInt16(entries.count - 1))
    }
    let idx = PaletteIndex(rawValue: UInt16(entries.count))
    entries.append(color)
    lookup[color.argb] = idx
    return idx
  }

  public mutating func intern(_ color: SceneColor) -> PaletteIndex {
    switch color {
    case .rgba(let c): return intern(c)
    case .palette(let p): return PaletteIndex(p)
    }
  }

  /// Resolves an index, applying `theme` to the reserved `ValuePalette` range.
  public func resolve(_ index: PaletteIndex, theme: ValueColorTheme) -> RGBA {
    let i = Int(index.rawValue)
    if i < ValuePalette.reservedCount, let v = ValuePalette(rawValue: i) {
      return theme[v]
    }
    guard i >= 0 && i < entries.count else { return .black }
    return entries[i]
  }
}

// MARK: - ValueColorTheme

/// The 12 simulation colours, supplied at render time rather than baked into the scene.
///
/// Upstream keeps these as mutable `java.awt.Color` statics on `Value` (`Value.java:296-307`)
/// wired straight to `AppPreferences`. D9 forbids the kernel from knowing about colours, so
/// the kernel returns a `ValuePalette` index and this is where the index becomes a pixel.
public struct ValueColorTheme: Hashable, Sendable {
  private var colors: [RGBA]

  public init(_ colors: [ValuePalette: RGBA]) {
    var e = [RGBA](repeating: .black, count: ValuePalette.reservedCount)
    for (k, v) in colors { e[k.rawValue] = v }
    self.colors = e
  }

  private init(raw: [RGBA]) { self.colors = raw }

  public subscript(_ slot: ValuePalette) -> RGBA {
    get { colors[slot.rawValue] }
    set { colors[slot.rawValue] = newValue }
  }

  /// The raw table, in `ValuePalette.rawValue` order. This is the buffer a Metal backend
  /// binds once per frame.
  public var table: [RGBA] { colors }

  /// Upstream's out-of-the-box preference values (`AppPreferences.java:715-747`).
  public static let logisim: ValueColorTheme = {
    var raw = [RGBA](repeating: .black, count: ValuePalette.reservedCount)
    raw[ValuePalette.falseValue.rawValue] = RGBA(javaRGB: 0x00_6400)
    raw[ValuePalette.trueValue.rawValue] = RGBA(javaRGB: 0x00_D200)
    raw[ValuePalette.unknown.rawValue] = RGBA(javaRGB: 0x28_28FF)
    raw[ValuePalette.error.rawValue] = RGBA(javaRGB: 0xC0_0000)
    raw[ValuePalette.nilValue.rawValue] = RGBA(javaRGB: 0x80_8080)
    raw[ValuePalette.stroke.rawValue] = RGBA(javaRGB: 0xFF_00FF)
    raw[ValuePalette.multi.rawValue] = RGBA(javaRGB: 0x00_0000)
    raw[ValuePalette.widthError.rawValue] = RGBA(javaRGB: 0xFF_7B00)
    raw[ValuePalette.widthErrorCaption.rawValue] = RGBA(javaRGB: 0x55_0000)
    raw[ValuePalette.widthErrorHighlight.rawValue] = RGBA(javaRGB: 0xFF_FF00)
    raw[ValuePalette.widthErrorCaptionBackground.rawValue] = RGBA(javaRGB: 0xFF_E6D2)
    raw[ValuePalette.clockFrequency.rawValue] = RGBA(javaRGB: 0xFF_00B4)
    return ValueColorTheme(raw: raw)
  }()
}
