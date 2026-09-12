// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import AppKit
import LogisimKernel
import SwiftUI

/// A fully-resolved colour. Deliberately *not* `NSColor`/`CGColor`: the render seam
/// (`CircuitRenderSurface`) has to be `Sendable`-clean and has to be usable from a Metal
/// backend at M9 that wants raw components, not an AppKit object.
public struct RGBA: Sendable, Hashable {
  public var red: Double
  public var green: Double
  public var blue: Double
  public var alpha: Double

  public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }

  /// 0xRRGGBB, the form the Java `AppPreferences.*_COLOR` prefs store.
  public init(hex: UInt32, alpha: Double = 1) {
    self.init(
      Double((hex >> 16) & 0xFF) / 255,
      Double((hex >> 8) & 0xFF) / 255,
      Double(hex & 0xFF) / 255,
      alpha)
  }

  public var cgColor: CGColor {
    CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
  }

  public var nsColor: NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
  }

  public var color: Color {
    Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
  }

  public func opacity(_ value: Double) -> RGBA {
    RGBA(red, green, blue, alpha * value)
  }

  /// Linear blend, used to derive halo/selection tints from the base palette.
  public func mixed(with other: RGBA, amount: Double) -> RGBA {
    let t = min(max(amount, 0), 1)
    return RGBA(
      red + (other.red - red) * t,
      green + (other.green - green) * t,
      blue + (other.blue - blue) * t,
      alpha + (other.alpha - alpha) * t)
  }
}

/// The per-frame colour palette. D6 states component `draw` implementations emit a palette
/// *index*, never a colour, and D9 forbids the kernel from knowing about colours at all,
/// so resolving an index to an actual colour is this module's job, and only this module's.
///
/// `ValueRole` mirrors `Value.java:296-307` one-for-one so nothing is dropped.
public enum ValueRole: Int, CaseIterable, Sendable, Hashable {
  case nilValue = 0
  case falseValue
  case trueValue
  case unknown
  case error
  case bus
  case widthError
  case widthErrorCaption
  case widthErrorHighlight
  case widthErrorCaptionBackground
  case clockFrequency
  case stroke
}

extension ValueRole {
  /// Translates the kernel's palette index into this module's role.
  ///
  /// **This bridge is load-bearing and its absence was a real defect.** `LogisimKernel`'s
  /// `ValuePalette` and this `ValueRole` are both flat, `rawValue`-indexed tables, both
  /// documented as mirroring `Value.java:296-307` one-for-one: *in different orders*, and for
  /// a while with nothing converting between them. Because `CircuitPalette` subscripts
  /// `values[role.rawValue]`, handing it a raw kernel index silently returned the wrong colour:
  /// kernel `falseValue` is 0 where this enum's 0 is `nilValue`, so a FALSE wire rendered as
  /// unconnected grey instead of green, and kernel `nilValue` (4) came back as error red.
  ///
  /// Two indices that agree on nothing but their type is exactly the failure D9 invites: the
  /// kernel is forbidden from knowing about colours, so it can only hand over an index, and an
  /// index is meaningless without an agreed table. The mapping is therefore written out by name
  /// rather than by number, and is exhaustive; adding a case on either side becomes a compile
  /// error here instead of a wrong colour on the canvas.
  ///
  /// Note `ValuePalette.multi` and `ValueRole.bus` are the same thing under two names
  /// (Java's `Value.multiColor`, used for a multi-bit bus).
  public init(_ slot: ValuePalette) {
    switch slot {
    case .falseValue: self = .falseValue
    case .trueValue: self = .trueValue
    case .unknown: self = .unknown
    case .error: self = .error
    case .nilValue: self = .nilValue
    case .stroke: self = .stroke
    case .multi: self = .bus
    case .widthError: self = .widthError
    case .widthErrorCaption: self = .widthErrorCaption
    case .widthErrorHighlight: self = .widthErrorHighlight
    case .widthErrorCaptionBackground: self = .widthErrorCaptionBackground
    case .clockFrequency: self = .clockFrequency
    }
  }
}

/// Non-value chrome the canvas needs. Separated from `ValueRole` because these are pure UI
/// and never come out of the kernel.
public enum ChromeRole: Int, CaseIterable, Sendable, Hashable {
  case canvasBackground
  case gridDot
  case gridLine
  case componentStroke
  case componentFill
  case label
  case pinLabel
  case halo
  case selectionStroke
  case selectionFill
  case marqueeStroke
  case marqueeFill
  case tickMarker
}

/// A palette resolved for one concrete appearance.
///
/// **Upstream issue #2661**, "canvas text ignores the dark/light switch", happens because
/// `Value.java` resolves every colour into a `static Color` field at class-init time from
/// `AppPreferences`, so the values are frozen for the life of the JVM and no appearance
/// change can move them. Here nothing is static: `CircuitPalette.resolved(for:)` is called
/// afresh whenever `NSView.viewDidChangeEffectiveAppearance()` fires, and the result is
/// pushed through `CircuitRenderSurface.setAppearance(_:)`, which invalidates the canvas.
public struct CircuitPalette: Sendable, Equatable {
  public var isDark: Bool
  public var values: [RGBA]
  public var chrome: [RGBA]

  public subscript(role: ValueRole) -> RGBA { values[role.rawValue] }

  /// Resolves a kernel palette index straight to a colour.
  ///
  /// This is what component code should call: a component only ever holds a `ValuePalette`,
  /// since D9 forbids it from knowing about colours at all. Going through `ValueRole.init(_:)`
  /// rather than `values[slot.rawValue]` is the whole point; the raw index is not portable
  /// between the two enums.
  ///
  /// **Deliberately a named method rather than a third `subscript` overload.** `CircuitPalette`
  /// already subscripts on `ValueRole` and `ChromeRole`, and `ValuePalette` shares case names
  /// with `ValueRole` (`trueValue`, `falseValue`, `unknown`, `error`…), so an overload made
  /// every bare `palette[.trueValue]` ambiguous, which is exactly how this was found, as two
  /// build errors in `PlaceholderRenderSurface`. A method keeps the two lookups distinguishable
  /// at every call site instead of relying on the compiler inferring the enum.
  public func color(for slot: ValuePalette) -> RGBA { self[ValueRole(slot)] }
  public subscript(role: ChromeRole) -> RGBA { chrome[role.rawValue] }

  init(isDark: Bool, values: [ValueRole: RGBA], chrome: [ChromeRole: RGBA]) {
    self.isDark = isDark
    self.values = ValueRole.allCases.map { values[$0] ?? RGBA(1, 0, 1) }
    self.chrome = ChromeRole.allCases.map { chrome[$0] ?? RGBA(1, 0, 1) }
  }

  /// Light appearance. Signal colours keep upstream's hues (a user reading a Logisim
  /// textbook must still see "green means high"), but the *chrome* is redrawn to macOS
  /// semantics rather than upstream's hard-coded `Color.white` background.
  public static let light = CircuitPalette(
    isDark: false,
    values: [
      .nilValue: RGBA(hex: 0x808080),
      .falseValue: RGBA(hex: 0x006B00),
      .trueValue: RGBA(hex: 0x00D000),
      .unknown: RGBA(hex: 0x2828FF),
      .error: RGBA(hex: 0xC00000),
      .bus: RGBA(hex: 0x000000),
      .widthError: RGBA(hex: 0xFF7B00),
      .widthErrorCaption: RGBA(hex: 0x850000),
      .widthErrorHighlight: RGBA(hex: 0xFFFF00),
      .widthErrorCaptionBackground: RGBA(hex: 0xFFE6D2),
      .clockFrequency: RGBA(hex: 0x1EDC1E),
      .stroke: RGBA(hex: 0x000000),
    ],
    chrome: [
      .canvasBackground: RGBA(hex: 0xFFFFFF),
      .gridDot: RGBA(hex: 0x000000, alpha: 0.22),
      .gridLine: RGBA(hex: 0x000000, alpha: 0.07),
      .componentStroke: RGBA(hex: 0x000000),
      .componentFill: RGBA(hex: 0xFFFFFF),
      .label: RGBA(hex: 0x000000),
      .pinLabel: RGBA(hex: 0x404040),
      .halo: RGBA(hex: 0x0A84FF, alpha: 0.85),
      .selectionStroke: RGBA(hex: 0x0A84FF),
      .selectionFill: RGBA(hex: 0x0A84FF, alpha: 0.14),
      .marqueeStroke: RGBA(hex: 0x0A84FF, alpha: 0.9),
      .marqueeFill: RGBA(hex: 0x0A84FF, alpha: 0.10),
      .tickMarker: RGBA(hex: 0x000000, alpha: 0.5),
    ])

  /// Dark appearance. Not an inversion: the two "high/low" greens are re-tuned for a dark
  /// ground (upstream's `0x006B00` false-green is illegible on a dark canvas), and the bus
  /// colour flips from black to a light neutral so multi-bit wires stay visible.
  public static let dark = CircuitPalette(
    isDark: true,
    values: [
      .nilValue: RGBA(hex: 0x8E8E93),
      .falseValue: RGBA(hex: 0x2E7D32),
      .trueValue: RGBA(hex: 0x30E060),
      .unknown: RGBA(hex: 0x6E8BFF),
      .error: RGBA(hex: 0xFF453A),
      .bus: RGBA(hex: 0xE4E4E7),
      .widthError: RGBA(hex: 0xFF9F0A),
      .widthErrorCaption: RGBA(hex: 0xFFB4AB),
      .widthErrorHighlight: RGBA(hex: 0xFFD60A),
      .widthErrorCaptionBackground: RGBA(hex: 0x4A2400),
      .clockFrequency: RGBA(hex: 0x30E060),
      .stroke: RGBA(hex: 0xE4E4E7),
    ],
    chrome: [
      .canvasBackground: RGBA(hex: 0x1C1C1E),
      .gridDot: RGBA(hex: 0xFFFFFF, alpha: 0.26),
      .gridLine: RGBA(hex: 0xFFFFFF, alpha: 0.08),
      .componentStroke: RGBA(hex: 0xE4E4E7),
      .componentFill: RGBA(hex: 0x2C2C2E),
      .label: RGBA(hex: 0xF2F2F7),
      .pinLabel: RGBA(hex: 0xAEAEB2),
      .halo: RGBA(hex: 0x64D2FF, alpha: 0.85),
      .selectionStroke: RGBA(hex: 0x0A84FF),
      .selectionFill: RGBA(hex: 0x0A84FF, alpha: 0.22),
      .marqueeStroke: RGBA(hex: 0x64D2FF, alpha: 0.9),
      .marqueeFill: RGBA(hex: 0x64D2FF, alpha: 0.12),
      .tickMarker: RGBA(hex: 0xFFFFFF, alpha: 0.5),
    ])

  /// Resolve against a live AppKit appearance. Handles the increased-contrast and
  /// accessibility variants that `NSAppearance.bestMatch` reports, so "Increase contrast"
  /// in System Settings is honoured rather than ignored.
  public static func resolved(for appearance: NSAppearance) -> CircuitPalette {
    let match = appearance.bestMatch(from: [
      .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
    ])
    switch match {
    case .darkAqua:
      return .dark
    case .accessibilityHighContrastDarkAqua:
      return .dark.contrastBoosted()
    case .accessibilityHighContrastAqua:
      return .light.contrastBoosted()
    default:
      return .light
    }
  }

  /// Pushes chrome away from the background and drops the translucency on overlays.
  func contrastBoosted() -> CircuitPalette {
    var copy = self
    let ground = self[.canvasBackground]
    for role in ChromeRole.allCases {
      let c = copy.chrome[role.rawValue]
      copy.chrome[role.rawValue] = c
        .mixed(with: isDark ? RGBA(1, 1, 1) : RGBA(0, 0, 0), amount: 0.2)
        .opacity(c.alpha < 1 ? min(1, c.alpha * 1.6) / max(c.alpha, 0.001) : 1)
    }
    copy.chrome[ChromeRole.canvasBackground.rawValue] = ground
    return copy
  }
}
