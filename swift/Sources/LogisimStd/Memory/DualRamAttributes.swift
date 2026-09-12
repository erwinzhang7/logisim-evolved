// DualRamAttributes.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.memory.DualRamAttributes),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Ownership note ───────────────────────────────────────────────────────────────────────────
//
// `DualRam`/`DualRamAppearance`/`DualRamAttributes`/`DualRamState` are a self-contained second
// RAM implementation (upstream's own header credits a named contributor and a Feb-2026 date;
// this is not core Logisim, it is a community-contributed variant living in the same package).
// Named in neither this task's explicit remit ("RamAppearance, MemMenu, MemPoker, and remaining
// memory/*.java") nor the sibling Mem/Ram/Rom slice's ("Mem/MemContents/MemContentsSub/MemState
// /Ram/Rom": six specific files). Ported here under the "remaining memory/*.java, files not
// named by either slice" clause of this task's ownership rule; see the final report for the
// `MemoryLibrary` wiring this unblocks.
//
// ── Structure ────────────────────────────────────────────────────────────────────────────────
//
// A dynamic attribute list, same shape as `GateAttributes`/`ProbeAttributes`: `attributes` is a
// computed property built fresh from the current field values (no upstream-style cached
// `myAttributes` list to keep in sync by hand). Upstream's `updateAttributes()` both rebuilds
// `myAttributes` *and* returns whether the shape changed, purely so its four call sites can
// decide whether to fire `fireAttributeListChanged()`; with a computed property there is nothing
// to rebuild, so `mutatingList(_:)` below reproduces the *decision* by diffing the list's
// identity sequence before and after the mutation, which is exactly the observable upstream
// answers regardless of which of the four fields changed shape.
//
// ── Naming: the static-attribute / stored-field collision ──────────────────────────────────────
//
// Upstream's own field names collide with their attribute constants by construction
// (`byteEnables`/`ATTR_ByteEnables`, `clearPin`/`CLEAR_PIN`); legal in Java because one is
// `UPPER_SNAKE` and the other `camelCase`. This port's convention drops the `ATTR_`/`_ATTR`
// decoration from every static identity (`RamAppearance.swift`'s precedent), which would make
// the two spellings identical. Rather than rely on Swift's static/instance name coexistence
// (legal, but a footgun the moment a method body drops a qualifier), the stored fields below are
// given distinct names (`byteEnableSetting`, `clearPinEnabled`) and the statics keep the clean,
// load-bearing names `DualRamAppearance.swift` (this same slice) already calls by.
//
// ── Preferences not wired (same precedent as `AbstractFlipFlop.swift`) ─────────────────────────
//
// Upstream's `appearance` field initialiser reads `AppPreferences.getDefaultAppearance()`
// (default `StdAttr.APPEAR_EVOLUTION`, per `PrefMonitorStringOpts`'s own default). D9 forbids
// this module from reaching into a preferences store; the field below hardcodes the compiled
// default instead, exactly as `AbstractFlipFlop.swift`'s header documents for the same
// preference.
//
// ── Not ported ───────────────────────────────────────────────────────────────────────────────
//
//   * `Font labelFont` uses `FontSpec` (D6/D9's precedent throughout this port) in place of
//     `java.awt.Font`.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.memory.DualRamAttributes`.
public final class DualRamAttributes: AbstractAttributeSet {

  // MARK: - Static attribute identities

  /// `DualRamAttributes.VOLATILE` / `.NONVOLATILE`.
  public static let volatileOption = AttributeOption(name: "volatile")
  public static let nonVolatileOption = AttributeOption(name: "nonvolatile")

  /// `DualRamAttributes.ATTR_TYPE`.
  public static let type: Attribute<AttributeOption> = Attributes.forOption(
    "type", choices: [volatileOption, nonVolatileOption])

  /// `DualRamAttributes.BUS_BIDIR` / `.BUS_SEP`.
  public static let busBidir = AttributeOption(name: "bidir")
  public static let busSeparate = AttributeOption(name: "bibus")

  /// `DualRamAttributes.ATTR_DBUS`.
  public static let dataBus: Attribute<AttributeOption> = Attributes.forOption(
    "databus", choices: [busBidir, busSeparate])

  /// `DualRamAttributes.BUS_WITH_BYTEENABLES` / `.BUS_WITHOUT_BYTE_ENABLES`.
  public static let busWithByteEnables = AttributeOption(name: "byteEnables")
  public static let busWithoutByteEnables = AttributeOption(name: "NobyteEnables")

  /// `DualRamAttributes.ATTR_ByteEnables`.
  public static let byteEnables: Attribute<AttributeOption> = Attributes.forOption(
    "byteenables", choices: [busWithByteEnables, busWithoutByteEnables])

  /// `DualRamAttributes.CLEAR_PIN`.
  public static let clearPin: Attribute<Bool> = Attributes.forBoolean("clearpin")

  // MARK: - Fields — Java's field initialisers, verbatim (see header for `appearance`)

  private var addrBits: BitWidth = BitWidth.known(8)
  private var dataBits: BitWidth = BitWidth.known(8)
  private var label: String = ""
  private var trigger: AttributeOption = StdAttr.triggerRising
  private var busStyle: AttributeOption = DualRamAttributes.busSeparate
  private var labelFont: FontSpec = StdAttr.defaultLabelFont
  private var labelVisible: Bool = false
  private var byteEnableSetting: AttributeOption = DualRamAttributes.busWithoutByteEnables
  private var asynchronousRead: Bool = false
  private var appearance: AttributeOption = StdAttr.appearEvolution
  private var readWriteBehavior: AttributeOption = Mem.readAfterWrite
  private var clearPinEnabled: Bool = false
  private var lineSize: AttributeOption = Mem.single
  private var allowMisaligned: Bool = false
  private var enablesStyle: AttributeOption = Mem.useByteEnables
  private var ramType: AttributeOption = DualRamAttributes.volatileOption

  public override init() {
    super.init()
  }

  // MARK: - AbstractAttributeSet

  /// `updateAttributes()`'s list-construction half. See the file header for why this port has no
  /// `myAttributes` cache or `changes` boolean to maintain.
  public override var attributes: [AnyAttribute] {
    var list: [AnyAttribute] = [Mem.addr, Mem.data, Mem.enables, DualRamAttributes.type, DualRamAttributes.clearPin]
    if enablesStyle == Mem.useByteEnables {
      list.append(StdAttr.trigger)
      if trigger == StdAttr.triggerRising || trigger == StdAttr.triggerFalling {
        list.append(Mem.asyncRead)
        if !asynchronousRead { list.append(Mem.readBehavior) }
        if dataBits.width > 8 { list.append(DualRamAttributes.byteEnables) }
      }
      list.append(DualRamAttributes.dataBus)
    } else {
      list.append(Mem.line)
      list.append(Mem.allowMisaligned)
      list.append(StdAttr.trigger)
      list.append(DualRamAttributes.dataBus)
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

  /// `getValue(Attribute<E>)`.
  public override func rawValue(_ attribute: AnyAttribute) -> AttributeValue? {
    if attribute === Mem.addr { return Mem.addr.encode(addrBits) }
    if attribute === Mem.data { return Mem.data.encode(dataBits) }
    if attribute === DualRamAttributes.type { return DualRamAttributes.type.encode(ramType) }
    if attribute === StdAttr.label { return StdAttr.label.encode(label) }
    if attribute === StdAttr.trigger { return StdAttr.trigger.encode(trigger) }
    if attribute === Mem.asyncRead { return Mem.asyncRead.encode(asynchronousRead) }
    if attribute === Mem.readBehavior { return Mem.readBehavior.encode(readWriteBehavior) }
    if attribute === DualRamAttributes.dataBus { return DualRamAttributes.dataBus.encode(busStyle) }
    if attribute === StdAttr.labelFont { return StdAttr.labelFont.encode(labelFont) }
    if attribute === StdAttr.labelVisibility { return StdAttr.labelVisibility.encode(labelVisible) }
    if attribute === DualRamAttributes.byteEnables {
      return DualRamAttributes.byteEnables.encode(byteEnableSetting)
    }
    if attribute === StdAttr.appearance { return StdAttr.appearance.encode(appearance) }
    if attribute === Mem.line { return Mem.line.encode(lineSize) }
    if attribute === Mem.allowMisaligned { return Mem.allowMisaligned.encode(allowMisaligned) }
    if attribute === DualRamAttributes.clearPin {
      return DualRamAttributes.clearPin.encode(clearPinEnabled)
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
    } else if attribute === DualRamAttributes.type {
      guard let value = newValue.flatMap(DualRamAttributes.type.decode) else { throw badValue(attribute) }
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
    } else if attribute === DualRamAttributes.dataBus {
      guard let value = newValue.flatMap(DualRamAttributes.dataBus.decode) else { throw badValue(attribute) }
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
    } else if attribute === DualRamAttributes.byteEnables {
      guard var value = newValue.flatMap(DualRamAttributes.byteEnables.decode) else {
        throw badValue(attribute)
      }
      if byteEnableSetting == value { return }
      // ── UPSTREAM QUIRK, PRESERVED ────────────────────────────────────────────────────────
      // A data width under 9 bits silently clamps the *stored* value to "no byte enables"
      // regardless of what was requested, but the fired event still carries the caller's
      // original (unclamped) `newValue`; the attribute table briefly shows the value the
      // user picked, not the one that took effect, until the next repaint re-reads `getValue`.
      if dataBits.width < 9 { value = DualRamAttributes.busWithoutByteEnables }
      byteEnableSetting = value
      fireAttributeValueChanged(attribute, value: newValue, oldValue: nil)
    } else if attribute === DualRamAttributes.clearPin {
      guard let value = newValue.flatMap(DualRamAttributes.clearPin.decode) else { throw badValue(attribute) }
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
      // `throw new IllegalArgumentException`; reachable from a `.circ` `<comp>` element naming
      // an attribute this set does not define (D13).
      throw AttributeSetError.attributeAbsent(name: attribute.name)
    }
  }

  private func badValue(_ attribute: AnyAttribute) -> ComponentError {
    .unsupportedAttributeValue(factory: DualRam.id, attribute: attribute.name)
  }

  public override func makeCopyInstance() -> AbstractAttributeSet {
    DualRamAttributes()
  }

  /// Every field copied explicitly; see `ProbeAttributes.swift`'s identical note on why
  /// `copyInto` cannot be the empty method upstream's text shows (no `Object.clone()` in Swift).
  public override func copyInto(_ destination: AbstractAttributeSet) {
    guard let destination = destination as? DualRamAttributes else { return }
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
