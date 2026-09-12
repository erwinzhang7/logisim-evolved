// StdAttr.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.instance.StdAttr),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// ── Where this lives, and why ───────────────────────────────────────────────────────────────
//
// Upstream puts `StdAttr` in `com.cburch.logisim.instance`, alongside the `Instance` facade that
// D3 deletes. `LogisimKernel` deliberately owns only the *machinery* of attributes
// (`Attribute<V>`, `AttributeSet`, the codecs); the concrete stock attribute identities are
// model-level, and `Circuit`/`CircuitAttributes`/every component placement record needs them, so
// they live in `LogisimFile` for now. Nothing above `LogisimFile` needs them earlier.
//
// ── What did not come across ────────────────────────────────────────────────────────────────
//
//   * `getDefaultLabelColor()`; reads `AppPreferences.LookAndFeel` to pick a dark-theme colour.
//     D9 forbids reaching into preferences from the model, and theme selection is a UI concern.
//     Both colour constants are here; choosing between them belongs to `LogisimUI`.
//   * `LABEL_LOC`: Java declares it `Attribute<Object>` over a heterogeneous option array mixing
//     an `AttributeOption` with four `Direction`s. That is not expressible as a single
//     `Attribute<V>` and it is only read by components (M4/M5). `CircuitAttributes` uses its own
//     `labelloc` attribute, which is a plain `Attribute<Direction>` upstream too, so nothing in
//     this milestone needs `LABEL_LOC`.
//   * `FP_WIDTH`: `Attributes.forOption` over a `BitWidth[]`, i.e. an option attribute whose
//     choices are widths rather than named options. Only floating-point components (M4) read it.
//
// Both omissions are recorded rather than faked; the component tranche that needs them is the
// right place to decide how they are spelled.

import Foundation
import LogisimKernel

/// `com.cburch.logisim.instance.StdAttr`: the stock attributes shared across components.
///
/// Java declares this as an `interface` full of constants, which makes every field implicitly
/// `public static final`. A Swift caseless `enum` with static members is the direct equivalent.
public enum StdAttr {

  /// `StdAttr.FACING`.
  public static let facing: Attribute<Direction> = Attributes.forDirection("facing")

  /// `StdAttr.MAPINFO`: the FPGA `ComponentMapInformationContainer` holder. Hidden and never
  /// saved, so it round-trips as an opaque live object (`Attributes.forMap`).
  public static let mapInfo: Attribute<AttributeObjectBox> = Attributes.forMap()

  /// `StdAttr.WIDTH`.
  public static let width: Attribute<BitWidth> = Attributes.forBitWidth("width")

  // MARK: Trigger

  /// `StdAttr.TRIG_RISING`.
  public static let triggerRising = AttributeOption(name: "rising")
  /// `StdAttr.TRIG_FALLING`.
  public static let triggerFalling = AttributeOption(name: "falling")
  /// `StdAttr.TRIG_HIGH`.
  public static let triggerHigh = AttributeOption(name: "high")
  /// `StdAttr.TRIG_LOW`.
  public static let triggerLow = AttributeOption(name: "low")

  /// `StdAttr.TRIGGER`.
  public static let trigger: Attribute<AttributeOption> = Attributes.forOption(
    "trigger", choices: [triggerRising, triggerFalling, triggerHigh, triggerLow])

  /// `StdAttr.EDGE_TRIGGER`. Note it shares the serialized name `"trigger"` with `TRIGGER`: two
  /// distinct attribute identities with the same `.circ` token, exactly as upstream.
  public static let edgeTrigger: Attribute<AttributeOption> = Attributes.forOption(
    "trigger", choices: [triggerRising, triggerFalling])

  // MARK: Labels

  /// `StdAttr.LABEL`.
  public static let label: Attribute<String> = Attributes.forString("label")

  /// `StdAttr.LABEL_FONT`.
  public static let labelFont: Attribute<FontSpec> = Attributes.forFont("labelfont")

  /// `StdAttr.DEFAULT_LABEL_FONT`: `new Font("SansSerif", Font.BOLD, 16)`.
  public static let defaultLabelFont = FontSpec(family: "SansSerif", style: .bold, size: 16)

  /// `StdAttr.LABEL_COLOR`.
  public static let labelColor: Attribute<ColorSpec> = Attributes.forColor("labelcolor")

  /// `StdAttr.DEFAULT_LABEL_COLOR`, `Color.BLUE`.
  public static let defaultLabelColor = ColorSpec(red: 0x00, green: 0x00, blue: 0xFF)

  /// `StdAttr.DARK_DEFAULT_LABEL_COLOR`: `new Color(0x6C, 0xB6, 0xFF)`. See the file header:
  /// selecting between this and `defaultLabelColor` is a UI-layer decision, not a model one.
  public static let darkDefaultLabelColor = ColorSpec(red: 0x6C, green: 0xB6, blue: 0xFF)

  /// `StdAttr.LABEL_CENTER`: `new AttributeOption("center", "center", …)`, i.e. the two-argument
  /// form whose `value` is the string `"center"` rather than `null`.
  public static let labelCenter = AttributeOption(value: "center")

  /// Where a component's label sits relative to its body.
  ///
  /// Java is `Attribute<Object> LABEL_LOC = Attributes.forOption("labelloc", …, new Object[] {
  /// LABEL_CENTER, Direction.NORTH, Direction.SOUTH, Direction.EAST, Direction.WEST })`: a
  /// deliberately heterogeneous choice list mixing one `AttributeOption` with four `Direction`s,
  /// which is why its static type is `Object`. The port models it as a single closed enum
  /// instead: the union is fixed, the saved tokens are what actually matter, and `Object` would
  /// force every call site to downcast.
  ///
  /// **The five serialized tokens are exactly Java's**: `"center"` from `LABEL_CENTER`'s value,
  /// and `"north"`/`"south"`/`"east"`/`"west"` from `Direction.toString()`. The declaration order
  /// is Java's array order, which `AttributeOptionValue`'s `CaseIterable` default turns into the
  /// order a UI presents them in.
  ///
  /// This is deliberately declared here rather than in `LogisimStd`. Seven component files each
  /// hit this gap independently while the real symbol was missing, and they did not agree: five
  /// (`Button`, `SevenSegment`, `HexDigit`, `Led`, `RgbLed`, `DotMatrix`, plus `Counter`/
  /// `Register`) assumed this `StdAttr`-nested shape, while `IoLibrary.swift` invented a
  /// top-level `LabelLocation` with its own `stdAttrLabelLocation` constant. Both cannot be the
  /// real declaration. This is the majority shape; `IoLibrary`'s stand-in should be deleted or
  /// re-pointed at it.
  public enum LabelLocation: String, AttributeOptionValue, CaseIterable, Sendable {
    case center
    case north
    case south
    case east
    case west
  }

  /// `StdAttr.LABEL_LOC`.
  public static let labelLocation: Attribute<LabelLocation> = Attributes.forOption("labelloc")

  /// `StdAttr.LABEL_VISIBILITY`.
  public static let labelVisibility: Attribute<Bool> = Attributes.forBoolean("labelvisible")

  // MARK: Appearance

  /// `StdAttr.APPEAR_CLASSIC`.
  public static let appearClassic = AttributeOption(name: "classic")
  /// `StdAttr.APPEAR_FPGA`. Note the mismatch is upstream's: the *FPGA* option serializes as
  /// `"evolution"` and the *evolution* option as `"logisim_evolution"`. Preserved verbatim:
  /// getting this backwards silently rewrites every `appearance=` in every saved file.
  public static let appearFpga = AttributeOption(name: "evolution")
  /// `StdAttr.APPEAR_EVOLUTION`.
  public static let appearEvolution = AttributeOption(name: "logisim_evolution")

  /// `StdAttr.APPEARANCE`.
  public static let appearance: Attribute<AttributeOption> = Attributes.forOption(
    "appearance", choices: [appearClassic, appearFpga, appearEvolution])

  // MARK: Select location

  /// `StdAttr.SELECT_BOTTOM_LEFT`.
  public static let selectBottomLeft = AttributeOption(name: "bl")
  /// `StdAttr.SELECT_TOP_RIGHT`.
  public static let selectTopRight = AttributeOption(name: "tr")

  /// `StdAttr.SELECT_LOC`.
  public static let selectLocation: Attribute<AttributeOption> = Attributes.forOption(
    "selloc", choices: [selectBottomLeft, selectTopRight])

  /// `StdAttr.DUMMY`, `Attributes.forHidden()`.
  public static let dummy: Attribute<String> = Attributes.forHidden()
}
