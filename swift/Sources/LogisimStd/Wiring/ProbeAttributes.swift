// ProbeAttributes.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.wiring.ProbeAttributes),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ══ WHY THE DEFAULTS IN THIS FILE ARE BYTE-VISIBLE ══════════════════════════════════════════
//
// `XmlWriter.addAttributeSetContent` emits an `<a name= val=>` element only when the value
// differs from `source.getDefaultAttributeValue(attr, version)`, and it emits the enclosing
// `<tool>` element only if at least one `<a>` survives that test. `PROBEAPPEARANCE` is the
// attribute that makes `<tool name="Pin">` and `<tool name="Probe">` appear in essentially every
// file Logisim 4.1.0 writes, because upstream deliberately disagrees with itself about its
// default:
//
//     ProbeAttributes.appearance        (the field initialiser)  =  StdAttr.APPEAR_CLASSIC
//     ProbeAttributes.getDefaultProbeAppearance()                =  APPEAR_EVOLUTION_NEW
//                                                                   (pref `oldIO` defaults true)
//
// `Pin.createAttributeSet()` returns a bare `new PinAttributes()`, so a Pin tool's stored
// appearance is `classic`, while `Pin.getDefaultAttributeValue(PROBEAPPEARANCE)` answers
// `NewPins`. They differ, so the attribute is written, so the `<tool>` block exists. Verified
// against 4.1.0 output:
//
//     <tool name="Pin">
//       <a name="appearance" val="classic"/>
//     </tool>
//
// `Probe.createAttributeSet()` *does* set the appearance to `getDefaultProbeAppearance()`, so a
// freshly built Probe tool would agree with its default and emit nothing, but the loader
// overrides it: `XmlReader.initAttributeSet` sets `PROBEAPPEARANCE` to `APPEAR_CLASSIC` for any
// attribute set where the file does not mention it (`XmlReader.java:165-166`). So a loaded Probe
// tool is `classic` too, and its `<tool>` block appears for exactly the same reason.
//
// Getting `appearance`'s field initialiser "right" as `NewPins`, which is what the constant's
// own name suggests; silently deletes four `<tool>` blocks per file. It is `classic`.
//
// ── The preference seam ─────────────────────────────────────────────────────────────────────
//
// `getDefaultProbeAppearance()` reads `AppPreferences.NEW_INPUT_OUTPUT_SHAPES`, which D9 forbids
// the model from touching. The injection point already exists:
// `SharedProbeAttributes.defaultProbeAppearance`, a settable `static var` whose initial
// value reproduces the shipped preference (`new PrefMonitorBooleanConvert("oldIO", true)` →
// `true` → `APPEAR_EVOLUTION_NEW`). This file forwards to it rather than adding a second knob.
// `LogisimUI` overwrites it when it owns a preferences store; a headless run gets the shipped
// default, which is what every gate is measured against.
//
// ── Not ported ──────────────────────────────────────────────────────────────────────────────
//
//   * `public static ProbeAttributes instance`; a mutable shared singleton that nothing in the
//     4.1.0 tree reads (grepped: the only `ProbeAttributes` references outside this file and
//     `Probe`/`Pin` are to the *static* `PROBEAPPEARANCE`/`APPEAR_EVOLUTION_NEW`/
//     `getDefaultProbeAppearance`). Porting it would be a shared-mutable-state hazard for no
//     behaviour.
//   * `implements ConvertEventListener`; the AWT `PropertyChangeEvent` plumbing that pushes a
//     preference change into every live attribute set. `attributeValueChanged(ConvertEvent)` is
//     kept as `applyAppearancePreference(_:)`; the *listener registration*
//     (`PrefMonitorBooleanConvert.addConvertListener`, called from `configureNewInstance`) is a
//     UI-layer subscription and is reported as a seam rather than faked.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.wiring.ProbeAttributes`.
///
/// Non-`final` on purpose: `PinAttributes` extends it, and the port preserves inheritance chains.
open class ProbeAttributes: AbstractAttributeSet {

  // MARK: Appearance

  // ── The attribute identity is SHARED with `LogisimFile`, deliberately ─────────────────────
  //
  // `LogisimFile/XmlReaderSupport.swift` already declares `public enum ProbeAttributes` holding
  // exactly these three members, because `XmlReader.initAttributeSet` and
  // `XmlWriter.addAttributeSetContent` both special-case `PROBEAPPEARANCE` **by identity**
  // (`attr.equals(…)` on a class that overrides neither `equals` nor `hashCode`; the port's
  // `AnyAttribute ==` is `===`). Its header states the contract: "When `std/wiring` lands at M5
  // it must import this declaration rather than minting a second
  // `Attributes.forOption("appearance", …)`, or the probe branch below silently stops firing."
  //
  // So these are *forwarders*, not new objects. Minting a second `Attribute` here would give the
  // reader's `attr === ProbeAttributes.probeAppearance` test an object it never sees, the
  // "classic on absence" repair would stop running, and every `<comp name="Probe">` and
  // `<comp name="Pin">` without an explicit `appearance` would load with the wrong shape; the
  // exact failure the migration gate is measuring.
  //
  // ⚠ REQUIRED CHANGE IN A FILE THIS SLICE DOES NOT OWN. The forwarders name
  // `SharedProbeAttributes`, which does not exist yet. It cannot be written as
  // `LogisimFile.ProbeAttributes` (which is what `Wiring/Clock.swift` currently tries) because
  // the public **class** `LogisimFile` shadows the **module** `LogisimFile` for qualified
  // lookup; `LogisimFile.ProbeAttributes` resolves to the class and fails with "type
  // 'LogisimFile' has no member 'ProbeAttributes'". And it cannot be written unqualified,
  // because the class declared in *this* file shadows the imported enum of the same name.
  // The fix is one line in `Sources/LogisimFile/XmlReaderSupport.swift`, beside the enum:
  //
  //     public typealias SharedProbeAttributes = ProbeAttributes
  //
  // `Wiring/Clock.swift` needs the same substitution at its seven `LogisimFile.ProbeAttributes`
  // sites. Reported in this task's final output.

  /// `ProbeAttributes.APPEAR_EVOLUTION_NEW`; `.circ` token **`"NewPins"`**.
  ///
  /// Note it is *not* `StdAttr.APPEAR_EVOLUTION` (`"logisim_evolution"`) and not
  /// `StdAttr.APPEAR_FPGA` (`"evolution"`). Three different tokens, three different attributes.
  public static let appearEvolutionNew = SharedProbeAttributes.appearEvolutionNew

  /// `ProbeAttributes.PROBEAPPEARANCE`; `.circ` token `"appearance"`.
  ///
  /// Shares that token with `StdAttr.APPEARANCE` (whose choices are `classic` / `evolution` /
  /// `logisim_evolution`): two distinct attribute identities with one serialized name, exactly
  /// as upstream.
  public static let probeAppearance: Attribute<AttributeOption> =
    SharedProbeAttributes.probeAppearance

  /// `ProbeAttributes.getDefaultProbeAppearance()`.
  ///
  /// The preference seam (`AppPreferences.NEW_INPUT_OUTPUT_SHAPES`, whose shipped default is
  /// `true` → `APPEAR_EVOLUTION_NEW`) is the settable
  /// `SharedProbeAttributes.defaultProbeAppearance`; this forwards so that both spellings
  /// always agree.
  public static var defaultProbeAppearance: AttributeOption {
    SharedProbeAttributes.defaultProbeAppearance
  }

  /// `ProbeAttributes.ATTRIBUTES`.
  static let attributeList: [AnyAttribute] = [
    StdAttr.facing,
    RadixOption.attribute,
    StdAttr.label,
    stdAttrLabelLocation,
    StdAttr.labelFont,
    ProbeAttributes.probeAppearance,
  ]

  // MARK: Fields — Java's field initialisers, verbatim

  /// `Direction facing = Direction.EAST`.
  public var facing: Direction = .east

  /// `String label = ""`.
  public var label: String = ""

  /// `Object labelloc = Direction.WEST`.
  ///
  /// Java types this `Object` because `StdAttr.LABEL_LOC` is `Attribute<Object>` over a
  /// heterogeneous array mixing `LABEL_CENTER` with four `Direction`s. `LabelLocation`
  /// (`Io/IoLibrary.swift`) is the five-token enum that stands in for it; `.west` is the same
  /// token `Direction.WEST` serializes as.
  public var labelLocation: LabelLocation = .west

  /// `Font labelfont = StdAttr.DEFAULT_LABEL_FONT`: `new Font("SansSerif", Font.BOLD, 16)`.
  public var labelFont: FontSpec = StdAttr.defaultLabelFont

  /// `RadixOption radix = RadixOption.RADIX_2`.
  public var radix: RadixOption = .radix2

  /// `BitWidth width = BitWidth.ONE`.
  ///
  /// **Not an attribute.** It is absent from `ATTRIBUTES` and from `getValue`, so
  /// `attrs.getValue(StdAttr.WIDTH)` on a plain `ProbeAttributes` returns `null`. It is a cache
  /// of the width `Probe.propagate` last saw on its input, used only to size the bounds.
  ///
  /// **Deviation (mechanism):** `PinAttributes` declares its own `BitWidth width`, which in Java
  /// *hides* this field rather than overriding it; a Pin therefore has two independent `width`
  /// slots. Swift cannot express stored-property hiding, so there is one field. This is
  /// unobservable: the base slot is written only by `Probe.propagate` (never reached by a Pin,
  /// which is a different factory) and read only through a `ProbeAttributes`-typed reference
  /// (`Probe.getOffsetBounds`, `ProbeLogger.getBitWidth`), which upstream only ever holds for a
  /// real Probe. Confirmed by grep: no site outside `Probe.java` reads `ProbeAttributes.width`.
  public var width: BitWidth = .one

  /// `AttributeOption appearance = StdAttr.APPEAR_CLASSIC`.
  ///
  /// **This is the gated default.** See the file header before changing it.
  public var appearance: AttributeOption = StdAttr.appearClassic

  public override init() {
    super.init()
  }

  // MARK: AbstractAttributeSet

  open override var attributes: [AnyAttribute] { ProbeAttributes.attributeList }

  /// `getValue(Attribute<E>)`.
  ///
  /// Returns `null` for anything not listed: including `StdAttr.WIDTH`, whose backing field
  /// exists but is deliberately not exposed. Preserved.
  open override func rawValue(_ attribute: AnyAttribute) -> AttributeValue? {
    if attribute === StdAttr.facing { return StdAttr.facing.encode(facing) }
    if attribute === StdAttr.label { return StdAttr.label.encode(label) }
    if attribute === stdAttrLabelLocation {
      return stdAttrLabelLocation.encode(labelLocation)
    }
    if attribute === StdAttr.labelFont { return StdAttr.labelFont.encode(labelFont) }
    if attribute === RadixOption.attribute { return RadixOption.attribute.encode(radix) }
    if attribute === ProbeAttributes.probeAppearance {
      return ProbeAttributes.probeAppearance.encode(appearance)
    }
    return nil
  }

  /// `setValue(Attribute<V>, V)`.
  ///
  /// Every branch short-circuits on an unchanged value, so a redundant write fires nothing.
  /// `StdAttr.LABEL` is the one attribute that reports an old value; every other branch leaves
  /// `Oldvalue` null, which is what the undo stack and the attribute table then see.
  open override func setRawValue(
    _ attribute: AnyAttribute, _ newValue: AttributeValue?
  ) throws {
    var oldValue: AttributeValue? = nil
    if attribute === StdAttr.facing {
      guard let decoded = newValue.flatMap(StdAttr.facing.decode) else {
        throw ComponentError.unsupportedAttributeValue(
          factory: Probe.id, attribute: attribute.name)
      }
      if facing == decoded { return }
      facing = decoded
    } else if attribute === StdAttr.label {
      guard let decoded = newValue.flatMap(StdAttr.label.decode) else {
        throw ComponentError.unsupportedAttributeValue(
          factory: Probe.id, attribute: attribute.name)
      }
      if label == decoded { return }
      oldValue = StdAttr.label.encode(label)
      label = decoded
    } else if attribute === stdAttrLabelLocation {
      guard let decoded = newValue.flatMap(stdAttrLabelLocation.decode) else {
        throw ComponentError.unsupportedAttributeValue(
          factory: Probe.id, attribute: attribute.name)
      }
      if labelLocation == decoded { return }
      labelLocation = decoded
    } else if attribute === StdAttr.labelFont {
      guard let decoded = newValue.flatMap(StdAttr.labelFont.decode) else {
        throw ComponentError.unsupportedAttributeValue(
          factory: Probe.id, attribute: attribute.name)
      }
      if labelFont == decoded { return }
      labelFont = decoded
    } else if attribute === RadixOption.attribute {
      guard let decoded = newValue.flatMap(RadixOption.attribute.decode) else {
        throw ComponentError.unsupportedAttributeValue(
          factory: Probe.id, attribute: attribute.name)
      }
      if radix == decoded { return }
      radix = decoded
    } else if attribute === ProbeAttributes.probeAppearance {
      guard let decoded = newValue.flatMap(ProbeAttributes.probeAppearance.decode) else {
        throw ComponentError.unsupportedAttributeValue(
          factory: Probe.id, attribute: attribute.name)
      }
      if appearance == decoded { return }
      appearance = decoded
    } else {
      // `throw new IllegalArgumentException("unknown attribute")`. Reachable from a `.circ`
      // `<comp>` element naming an attribute this set does not define, so it throws (D13).
      throw AttributeSetError.attributeAbsent(name: attribute.name)
    }
    fireAttributeValueChanged(attribute, value: newValue, oldValue: oldValue)
  }

  open override func makeCopyInstance() -> AbstractAttributeSet {
    ProbeAttributes()
  }

  /// Java's `copyInto` is empty with the comment "nothing to do", because
  /// `AbstractAttributeSet.clone()` calls `Object.clone()` first and the fields are already
  /// copied. Swift has no such thing, so every field is copied explicitly; leaving this empty
  /// makes every clone read as "all defaults" and changes what the `.circ` writer emits
  /// (`PATTERNS.md` §5, the rule that has already bitten once).
  open override func copyInto(_ destination: AbstractAttributeSet) {
    guard let destination = destination as? ProbeAttributes else { return }
    destination.facing = facing
    destination.label = label
    destination.labelLocation = labelLocation
    destination.labelFont = labelFont
    destination.radix = radix
    destination.width = width
    destination.appearance = appearance
  }

  // MARK: Preference conversion

  /// `attributeValueChanged(ConvertEvent e)`: the callback
  /// `PrefMonitorBooleanConvert.addConvertListener` invokes when the user flips the
  /// "new input/output shapes" preference, pushing the new appearance into every live probe and
  /// pin attribute set.
  ///
  /// The *registration* half lives in `Probe.configureNewInstance` /
  /// `Pin.configureNewInstance` and is a UI subscription; see the final report's seam list.
  public func applyAppearancePreference(_ value: AttributeOption) throws {
    try setValue(ProbeAttributes.probeAppearance, value)
  }
}
