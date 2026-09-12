// RamAttributes.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.memory.RamAttributes),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── This file and `DualRamAttributes.swift` are the same file twice, and that is upstream ─────
//
// `diff RamAttributes.java DualRamAttributes.java` in the 4.1.0 tree reports exactly three
// hunks, all of them the class name (declaration, constructor, `copyInto`'s downcast). Every
// attribute identity, every field default, every `setValue` branch is byte-identical. The
// community-contributed dual-port variant was copy-pasted from this file and never diverged.
//
// This port therefore keeps the two as two files with parallel structure rather than hoisting a
// shared base: upstream has no such base, and the static attribute *identities* must stay
// distinct per class (`RamAttributes.ATTR_DBUS != DualRamAttributes.ATTR_DBUS` in Java, compared
// by `==` reference identity at every call site, and by `===` here). `DualRamAttributes.swift`
// landed first in a sibling slice; its header carries the long-form rationale for the three
// structural decisions below, which this file follows verbatim so the pair stays greppable:
//
//   * the dynamic list is a computed `attributes` property, not a hand-maintained `myAttributes`
//     cache, with `mutatingList(_:)` reproducing `if (updateAttributes()) fireAttributeListChanged()`
//     by diffing the list's identity sequence around the mutation;
//   * the stored fields that would collide with a static of the same name once the `ATTR_`/
//     `_ATTR` decoration is dropped (`byteEnables`/`ATTR_ByteEnables`, `clearPin`/`CLEAR_PIN`)
//     are renamed `byteEnableSetting`/`clearPinEnabled`, leaving the load-bearing static names
//     `RamAppearance.swift` and `Ram.swift` already call by;
//   * `appearance`'s initialiser hardcodes `StdAttr.appearEvolution` where upstream reads
//     `AppPreferences.getDefaultAppearance()`: D9 forbids a preferences reach-in from this
//     module, and `StdAttr.APPEAR_EVOLUTION` is that preference's own compiled default.
//
// ── `copyInto` copies more than Java's `copyInto` names, and that is the faithful reading ────
//
// Upstream's `copyInto` omits `label` and `labelVisible`. That is not "a copy loses its label":
// `AbstractAttributeSet.clone()` runs `super.clone()`, `Object.clone()`, a bitwise copy of
// *every* field, **before** calling `copyInto`, so both fields are already carried across and
// `copyInto` only needs to re-state the ones it wants to be explicit about. Swift has no
// `Object.clone()`, so the field-for-field copy below has to be complete; the two omitted fields
// are listed with the rest, which is what upstream actually does at runtime.
//
// The one thing `Object.clone()` does that this port deliberately does not reproduce is aliasing
// `myAttributes`: after the bitwise copy, clone and original share the *same* `ArrayList`, so a
// later `updateAttributes()` on either mutates both. With `attributes` computed fresh from the
// (fully copied) fields, each set answers its own correct list; the divergence is only visible
// through the shared-list bug itself, which nothing in this port relies on.
//
// ── Not ported ───────────────────────────────────────────────────────────────────────────────
//
//   * `Font labelFont` uses `FontSpec` (D6/D9's precedent throughout this port) in place of
//     `java.awt.Font`.
//   * Every `S.getter(...)` display string (D5's precedent: `Attributes.forOption`/`forBoolean`
//     in this port take no description parameter).

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.memory.RamAttributes`.
public final class RamAttributes: AbstractAttributeSet {

  // MARK: - Static attribute identities

  /// `RamAttributes.VOLATILE` / `.NONVOLATILE`. Named `volatileOption` rather than `volatile`
  /// to match `DualRamAttributes.swift`'s spelling of the same pair (and because a bare
  /// `volatile` reads as a storage qualifier at every call site).
  public static let volatileOption = AttributeOption(name: "volatile")
  public static let nonVolatileOption = AttributeOption(name: "nonvolatile")

  /// `RamAttributes.ATTR_TYPE`.
  public static let type: Attribute<AttributeOption> = Attributes.forOption(
    "type", choices: [volatileOption, nonVolatileOption])

  /// `RamAttributes.BUS_BIDIR` / `.BUS_SEP`.
  public static let busBidir = AttributeOption(name: "bidir")
  public static let busSeparate = AttributeOption(name: "bibus")

  /// `RamAttributes.ATTR_DBUS`.
  public static let dataBus: Attribute<AttributeOption> = Attributes.forOption(
    "databus", choices: [busBidir, busSeparate])

  /// `RamAttributes.BUS_WITH_BYTEENABLES` / `.BUS_WITHOUT_BYTE_ENABLES`. The option names are
  /// upstream's own inconsistent casing (`byteEnables` vs `NobyteEnables`); they are `.circ`
  /// tokens, so they are copied exactly rather than tidied.
  public static let busWithByteEnables = AttributeOption(name: "byteEnables")
  public static let busWithoutByteEnables = AttributeOption(name: "NobyteEnables")

  /// `RamAttributes.ATTR_ByteEnables`.
  public static let byteEnables: Attribute<AttributeOption> = Attributes.forOption(
    "byteenables", choices: [busWithByteEnables, busWithoutByteEnables])

  /// `RamAttributes.CLEAR_PIN`.
  public static let clearPin: Attribute<Bool> = Attributes.forBoolean("clearpin")

  // MARK: - Fields — Java's field initialisers, verbatim (see header for `appearance`)

  private var addrBits: BitWidth = BitWidth.known(8)
  private var dataBits: BitWidth = BitWidth.known(8)
  private var label: String = ""
  private var trigger: AttributeOption = StdAttr.triggerRising
  private var busStyle: AttributeOption = RamAttributes.busSeparate
  private var labelFont: FontSpec = StdAttr.defaultLabelFont
  private var labelVisible: Bool = false
  private var byteEnableSetting: AttributeOption = RamAttributes.busWithoutByteEnables
  private var asynchronousRead: Bool = false
  private var appearance: AttributeOption = StdAttr.appearEvolution
  private var readWriteBehavior: AttributeOption = Mem.readAfterWrite
  private var clearPinEnabled: Bool = false
  private var lineSize: AttributeOption = Mem.single
  private var allowMisaligned: Bool = false
  private var enablesStyle: AttributeOption = Mem.useByteEnables
  private var ramType: AttributeOption = RamAttributes.volatileOption

  public override init() {
    super.init()
  }

  // MARK: - AbstractAttributeSet

  /// `updateAttributes()`'s list-construction half. See the file header (and
  /// `DualRamAttributes.swift`'s) for why this port has no `myAttributes` cache or `changes`
  /// boolean to maintain.
  public override var attributes: [AnyAttribute] {
    var list: [AnyAttribute] = [Mem.addr, Mem.data, Mem.enables, RamAttributes.type, RamAttributes.clearPin]
    if enablesStyle == Mem.useByteEnables {
      list.append(StdAttr.trigger)
      if trigger == StdAttr.triggerRising || trigger == StdAttr.triggerFalling {
        list.append(Mem.asyncRead)
        if !asynchronousRead { list.append(Mem.readBehavior) }
        if dataBits.width > 8 { list.append(RamAttributes.byteEnables) }
      }
      list.append(RamAttributes.dataBus)
    } else {
      list.append(Mem.line)
      list.append(Mem.allowMisaligned)
      list.append(StdAttr.trigger)
      list.append(RamAttributes.dataBus)
    }
    list.append(StdAttr.label)
    list.append(StdAttr.labelFont)
    list.append(StdAttr.labelVisibility)
    list.append(StdAttr.appearance)
    return list
  }

  /// Runs `body` (a field mutation) and fires `fireAttributeListChanged()` iff the attribute
  /// list's identity sequence differs before and after: the computed-property equivalent of
  /// upstream's `if (updateAttributes()) fireAttributeListChanged()`.
  private func mutatingList(_ body: () -> Void) {
    let before = attributes.map(ObjectIdentifier.init)
    body()
    let after = attributes.map(ObjectIdentifier.init)
    if before != after { fireAttributeListChanged() }
  }

  /// `getValue(Attribute<V>)`.
  public override func rawValue(_ attribute: AnyAttribute) -> AttributeValue? {
    if attribute === Mem.addr { return Mem.addr.encode(addrBits) }
    if attribute === Mem.data { return Mem.data.encode(dataBits) }
    if attribute === RamAttributes.type { return RamAttributes.type.encode(ramType) }
    if attribute === StdAttr.label { return StdAttr.label.encode(label) }
    if attribute === StdAttr.trigger { return StdAttr.trigger.encode(trigger) }
    if attribute === Mem.asyncRead { return Mem.asyncRead.encode(asynchronousRead) }
    if attribute === Mem.readBehavior { return Mem.readBehavior.encode(readWriteBehavior) }
    if attribute === RamAttributes.dataBus { return RamAttributes.dataBus.encode(busStyle) }
    if attribute === StdAttr.labelFont { return StdAttr.labelFont.encode(labelFont) }
    if attribute === StdAttr.labelVisibility { return StdAttr.labelVisibility.encode(labelVisible) }
    if attribute === RamAttributes.byteEnables {
      return RamAttributes.byteEnables.encode(byteEnableSetting)
    }
    if attribute === StdAttr.appearance { return StdAttr.appearance.encode(appearance) }
    if attribute === Mem.line { return Mem.line.encode(lineSize) }
    if attribute === Mem.allowMisaligned { return Mem.allowMisaligned.encode(allowMisaligned) }
    if attribute === RamAttributes.clearPin {
      return RamAttributes.clearPin.encode(clearPinEnabled)
    }
    if attribute === Mem.enables { return Mem.enables.encode(enablesStyle) }
    // Upstream returns `null` for anything else.
    return nil
  }

  /// `setValue(Attribute<V>, V)`. Every branch mirrors upstream's short-circuit on an unchanged
  /// value; only `ATTR_ByteEnables` reports a value different from what it actually stores (see
  /// the inline note there, an upstream quirk, preserved).
  public override func setRawValue(
    _ attribute: AnyAttribute, _ newValue: AttributeValue?
  ) throws {
    if attribute === Mem.addr {
      guard let value = newValue.flatMap(Mem.addr.decode) else { throw badValue(attribute) }
      if addrBits == value { return }
      addrBits = value
      fireAttributeValueChanged(attribute, value: newValue, oldValue: nil)
    } else if attribute === Mem.data {
      guard let value = newValue.flatMap(Mem.data.decode) else { throw badValue(attribute) }
      if dataBits == value { return }
      mutatingList { dataBits = value }
      fireAttributeValueChanged(attribute, value: newValue, oldValue: nil)
    } else if attribute === Mem.enables {
      guard let value = newValue.flatMap(Mem.enables.decode) else { throw badValue(attribute) }
      guard enablesStyle != value else { return }
      mutatingList { enablesStyle = value }
      fireAttributeValueChanged(attribute, value: newValue, oldValue: nil)
    } else if attribute === RamAttributes.type {
      guard let value = newValue.flatMap(RamAttributes.type.decode) else { throw badValue(attribute) }
      guard ramType != value else { return }
      ramType = value
      fireAttributeValueChanged(attribute, value: newValue, oldValue: nil)
    } else if attribute === StdAttr.label {
      guard let value = newValue.flatMap(StdAttr.label.decode) else { throw badValue(attribute) }
      if label == value { return }
      let oldValue = StdAttr.label.encode(label)
      label = value
      fireAttributeValueChanged(attribute, value: newValue, oldValue: oldValue)
    } else if attribute === StdAttr.trigger {
      guard let value = newValue.flatMap(StdAttr.trigger.decode) else { throw badValue(attribute) }
      if trigger == value { return }
      mutatingList { trigger = value }
      fireAttributeValueChanged(attribute, value: newValue, oldValue: nil)
    } else if attribute === Mem.asyncRead {
      guard let value = newValue.flatMap(Mem.asyncRead.decode) else { throw badValue(attribute) }
      guard asynchronousRead != value else { return }
      mutatingList { asynchronousRead = value }
      fireAttributeValueChanged(attribute, value: newValue, oldValue: nil)
    } else if attribute === Mem.readBehavior {
      guard let value = newValue.flatMap(Mem.readBehavior.decode) else { throw badValue(attribute) }
      guard readWriteBehavior != value else { return }
      readWriteBehavior = value
      fireAttributeValueChanged(attribute, value: newValue, oldValue: nil)
    } else if attribute === RamAttributes.dataBus {
      guard let value = newValue.flatMap(RamAttributes.dataBus.decode) else { throw badValue(attribute) }
      if busStyle == value { return }
      busStyle = value
      fireAttributeValueChanged(attribute, value: newValue, oldValue: nil)
    } else if attribute === StdAttr.labelFont {
      guard let value = newValue.flatMap(StdAttr.labelFont.decode) else { throw badValue(attribute) }
      if labelFont == value { return }
      labelFont = value
      fireAttributeValueChanged(attribute, value: newValue, oldValue: nil)
    } else if attribute === StdAttr.labelVisibility {
      guard let value = newValue.flatMap(StdAttr.labelVisibility.decode) else { throw badValue(attribute) }
      if labelVisible == value { return }
      labelVisible = value
      fireAttributeValueChanged(attribute, value: newValue, oldValue: nil)
    } else if attribute === RamAttributes.byteEnables {
      guard var value = newValue.flatMap(RamAttributes.byteEnables.decode) else {
        throw badValue(attribute)
      }
      if byteEnableSetting == value { return }
      // ── UPSTREAM QUIRK, PRESERVED ────────────────────────────────────────────────────────
      // A data width under 9 bits silently clamps the *stored* value to "no byte enables"
      // regardless of what was requested, but the fired event still carries the caller's
      // original (unclamped) `newValue`; the attribute table briefly shows the value the
      // user picked, not the one that took effect, until the next repaint re-reads `getValue`.
      if dataBits.width < 9 { value = RamAttributes.busWithoutByteEnables }
      byteEnableSetting = value
      fireAttributeValueChanged(attribute, value: newValue, oldValue: nil)
    } else if attribute === RamAttributes.clearPin {
      guard let value = newValue.flatMap(RamAttributes.clearPin.decode) else { throw badValue(attribute) }
      guard clearPinEnabled != value else { return }
      clearPinEnabled = value
      fireAttributeValueChanged(attribute, value: newValue, oldValue: nil)
    } else if attribute === Mem.line {
      guard let value = newValue.flatMap(Mem.line.decode) else { throw badValue(attribute) }
      guard lineSize != value else { return }
      lineSize = value
      fireAttributeValueChanged(attribute, value: newValue, oldValue: nil)
    } else if attribute === Mem.allowMisaligned {
      guard let value = newValue.flatMap(Mem.allowMisaligned.decode) else { throw badValue(attribute) }
      guard allowMisaligned != value else { return }
      allowMisaligned = value
      fireAttributeValueChanged(attribute, value: newValue, oldValue: nil)
    } else if attribute === StdAttr.appearance {
      guard let value = newValue.flatMap(StdAttr.appearance.decode) else { throw badValue(attribute) }
      if appearance == value { return }
      appearance = value
      fireAttributeValueChanged(attribute, value: newValue, oldValue: nil)
    } else {
      // Upstream's `setValue` simply falls off the end for an unknown attribute; this port
      // throws instead, matching `DualRamAttributes.swift` and the rest of the module; the
      // reachable case is a `.circ` `<comp>` element naming an attribute this set does not
      // define, which must produce a load error rather than a silently ignored write (D13).
      throw AttributeSetError.attributeAbsent(name: attribute.name)
    }
  }

  private func badValue(_ attribute: AnyAttribute) -> ComponentError {
    .unsupportedAttributeValue(factory: Ram.id, attribute: attribute.name)
  }

  public override func makeCopyInstance() -> AbstractAttributeSet {
    RamAttributes()
  }

  /// `copyInto(AbstractAttributeSet)` plus the two fields `Object.clone()` carries across before
  /// upstream's `copyInto` ever runs: see the file header on why `label`/`labelVisible` belong
  /// here even though Java's `copyInto` does not name them.
  public override func copyInto(_ destination: AbstractAttributeSet) {
    guard let destination = destination as? RamAttributes else { return }
    destination.addrBits = addrBits
    destination.dataBits = dataBits
    destination.label = label
    destination.trigger = trigger
    destination.busStyle = busStyle
    destination.labelFont = labelFont
    destination.labelVisible = labelVisible
    destination.byteEnableSetting = byteEnableSetting
    destination.asynchronousRead = asynchronousRead
    destination.appearance = appearance
    destination.readWriteBehavior = readWriteBehavior
    destination.clearPinEnabled = clearPinEnabled
    destination.lineSize = lineSize
    destination.allowMisaligned = allowMisaligned
    destination.enablesStyle = enablesStyle
    destination.ramType = ramType
  }
}
