// RomAttributes.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.memory.RomAttributes),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── What survives the UI strip, and why what is left is still the whole model ────────────────
//
// Half of `RomAttributes.java` by line count is not attribute code at all: two static
// `WeakHashMap`s and the three static methods over them (`getHexFrame`, `closeHexFrame`,
// `register`/`setProject`) exist to give one `MemContents` at most one open hex-editor window and
// at most one undo-recording `RomContentsListener` per `Project`. `HexFrame` and `Project` are
// UI/M7 and do not exist below `LogisimUI`, and both call sites of `setProject` in this tree have
// already made the same cut for the same reason with the same note; see `MemPoker.swift`'s
// header ("dropped; the M6/M7 owner of `RomAttributes` should do that wiring at the tool level
// instead of inside the poker") and `MemMenu.swift`'s. Registration is therefore *deliberately*
// absent here rather than stubbed: reintroducing it means introducing `Project`, and whoever does
// that owns the choice of where the registry lives.
//
// What is left, a fixed nine-attribute list, the `MemContents` the ROM actually serialises, and
// the widths that resize it, is the entire model-level behaviour, and it is complete.
//
// ── Fixed list, unlike `RamAttributes` ───────────────────────────────────────────────────────
//
// `RomAttributes.ATTRIBUTES` is `static final` and never varies with the ROM's configuration, so
// this file needs neither `RamAttributes.swift`'s computed `attributes` property nor its
// `mutatingList(_:)` diff; a ROM's attribute list genuinely cannot change shape, and
// `fireAttributeListChanged()` is correspondingly never called. Note this file's list omits
// `Mem.ENABLES_ATTR` entirely (a ROM has no write port to enable), which is why
// `RamAppearance.swift`'s port-count helpers all lead with `attrs.containsAttribute(Mem.enables)`
// ; that guard exists for exactly this attribute set.
//
// ── `contents` is the one attribute in the port that is a live object ────────────────────────
//
// `Rom.contentsAttr`'s storage form is `.object(AttributeObjectBox(_:))` (see `Rom.swift`, which
// owns the codec). This set is what guarantees the invariant `Rom.memState(for:)` relies on:
// `contents` is non-`nil` from construction and every assignment path replaces it with another
// real `MemContents`, so `getValue(Rom.contentsAttr)` never answers `nil` for a `Rom` component.
//
// ── D13: `setDimensions` propagates rather than trapping ────────────────────────────────────
//
// Upstream's width setters call `contents.setDimensions(...)` with no error path (Java would
// surface a bad size as an unchecked `NegativeArraySizeException`/`OutOfMemoryError`). This
// port's `MemContents.setDimensions` `throws`, and `setRawValue` already `throws`, so the two
// calls below simply propagate. In practice `Mem.addr` (2...24) and `Mem.data` (1...64) bound
// both arguments before they arrive, so the throw is unreachable through the ordinary attribute
// path, but propagating costs nothing and keeps a hand-edited `.circ` from ever reaching a trap
// here, which is the whole of D13.
//
// ── Not ported ───────────────────────────────────────────────────────────────────────────────
//
//   * `getHexFrame`, `closeHexFrame`, `windowRegistry`: the interactive hex-editor window
//     (`HexFrame`, UI/M6), same cut `Ram.swift`/`Rom.swift` already make.
//   * `register(MemContents, Project)`, `listenerRegistry`, `setProject(Project)`; undo-log
//     wiring; see the header discussion above. `RomContentsListener` itself *is* ported
//     (`RomContentsListener.swift`) and waits for an M7 owner to hand it a project.
//   * `Font labelFont` uses `FontSpec` (D6/D9's precedent) in place of `java.awt.Font`.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.memory.RomAttributes`.
public final class RomAttributes: AbstractAttributeSet {

  /// `RomAttributes.ATTRIBUTES`.
  private static let attributeList: [AnyAttribute] = [
    Mem.addr,
    Mem.data,
    Mem.line,
    Mem.allowMisaligned,
    Rom.contentsAttr,
    StdAttr.label,
    StdAttr.labelFont,
    StdAttr.labelVisibility,
    StdAttr.appearance,
  ]

  // MARK: - Fields — Java's field initialisers, verbatim

  private var addrBits: BitWidth = BitWidth.known(8)
  private var dataBits: BitWidth = BitWidth.known(8)
  private var contents: MemContents
  private var lineSize: AttributeOption = Mem.single
  private var allowMisaligned: Bool = false
  private var label: String = ""
  private var labelFont: FontSpec = StdAttr.defaultLabelFont
  private var labelVisible: Bool = false
  /// Upstream reads `AppPreferences.getDefaultAppearance()`; D9 forbids this module reaching into
  /// a preferences store, so the field carries that preference's own compiled default. Same
  /// substitution `RamAttributes.swift`/`AbstractFlipFlop.swift` document for the same preference.
  private var appearance: AttributeOption = StdAttr.appearEvolution

  /// `RomAttributes()`: `contents = MemContents.create(addrBits.getWidth(), dataBits.getWidth(),
  /// false)`.
  public override init() {
    // `try!`: both arguments are the literal `8` above, so `MemContents.create`'s only throwing
    // path (`MemContentsError.invalidAddressWidth`, for a pathological address width) cannot be
    // reached from here at all. D13's "genuine programmer error, no input can produce it"
    // carve-out: an *initialiser* default, not a value any `.circ` file supplies.
    self.contents = try! MemContents.create(
      addrBits: RomAttributes.defaultWidth, width: RomAttributes.defaultWidth, randomize: false)
    super.init()
  }

  /// The `8` in both of `BitWidth.create(8)` above, named so the constructor's `try!` reads as
  /// obviously constant.
  private static let defaultWidth = 8

  // MARK: - AbstractAttributeSet

  /// `getAttributes()`.
  public override var attributes: [AnyAttribute] { RomAttributes.attributeList }

  /// `getValue(Attribute<V>)`.
  public override func rawValue(_ attribute: AnyAttribute) -> AttributeValue? {
    if attribute === Mem.addr { return Mem.addr.encode(addrBits) }
    if attribute === Mem.data { return Mem.data.encode(dataBits) }
    if attribute === Mem.line { return Mem.line.encode(lineSize) }
    if attribute === Mem.allowMisaligned { return Mem.allowMisaligned.encode(allowMisaligned) }
    if attribute === Rom.contentsAttr { return Rom.contentsAttr.encode(contents) }
    if attribute === StdAttr.label { return StdAttr.label.encode(label) }
    if attribute === StdAttr.labelFont { return StdAttr.labelFont.encode(labelFont) }
    if attribute === StdAttr.labelVisibility { return StdAttr.labelVisibility.encode(labelVisible) }
    if attribute === StdAttr.appearance { return StdAttr.appearance.encode(appearance) }
    // Upstream returns `null` for anything else.
    return nil
  }

  /// `setValue(Attribute<V>, V)`.
  public override func setRawValue(
    _ attribute: AnyAttribute, _ newValue: AttributeValue?
  ) throws {
    if attribute === Mem.addr {
      guard let value = newValue.flatMap(Mem.addr.decode) else { throw badValue(attribute) }
      if addrBits == value { return }
      addrBits = value
      try contents.setDimensions(addrBits: addrBits.width, width: dataBits.width)
      fireAttributeValueChanged(attribute, value: newValue, oldValue: nil)
    } else if attribute === Mem.data {
      guard let value = newValue.flatMap(Mem.data.decode) else { throw badValue(attribute) }
      if dataBits == value { return }
      dataBits = value
      try contents.setDimensions(addrBits: addrBits.width, width: dataBits.width)
      fireAttributeValueChanged(attribute, value: newValue, oldValue: nil)
    } else if attribute === Mem.line {
      guard let value = newValue.flatMap(Mem.line.decode) else { throw badValue(attribute) }
      if lineSize == value { return }
      lineSize = value
      fireAttributeValueChanged(attribute, value: newValue, oldValue: nil)
    } else if attribute === Mem.allowMisaligned {
      guard let value = newValue.flatMap(Mem.allowMisaligned.decode) else { throw badValue(attribute) }
      if allowMisaligned == value { return }
      allowMisaligned = value
      fireAttributeValueChanged(attribute, value: newValue, oldValue: nil)
    } else if attribute === Rom.contentsAttr {
      guard let value = newValue.flatMap(Rom.contentsAttr.decode) else { throw badValue(attribute) }
      // `if (contents.equals(newContents)) return;`: `MemContents` overrides neither `equals`
      // nor `hashCode` in 4.1.0, so upstream's guard is reference identity, not a contents
      // comparison. Two byte-identical-but-distinct arrays *do* fire a change event here, and
      // re-setting the same object does not. `===`, not `==`.
      if contents === value { return }
      contents = value
      fireAttributeValueChanged(attribute, value: newValue, oldValue: nil)
    } else if attribute === StdAttr.label {
      guard let value = newValue.flatMap(StdAttr.label.decode) else { throw badValue(attribute) }
      if label == value { return }
      let oldValue = StdAttr.label.encode(label)
      label = value
      fireAttributeValueChanged(attribute, value: newValue, oldValue: oldValue)
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
    } else if attribute === StdAttr.appearance {
      guard let value = newValue.flatMap(StdAttr.appearance.decode) else { throw badValue(attribute) }
      if appearance == value { return }
      appearance = value
      fireAttributeValueChanged(attribute, value: newValue, oldValue: nil)
    } else {
      // Upstream's `setValue` falls off the end for an unknown attribute; this port throws, for
      // the reason `RamAttributes.swift`/`DualRamAttributes.swift` give; a `.circ` `<comp>`
      // naming an attribute this set does not define must be a load error, not a silent no-op
      // (D13).
      throw AttributeSetError.attributeAbsent(name: attribute.name)
    }
  }

  private func badValue(_ attribute: AnyAttribute) -> ComponentError {
    .unsupportedAttributeValue(factory: Rom.id, attribute: attribute.name)
  }

  public override func makeCopyInstance() -> AbstractAttributeSet {
    RomAttributes()
  }

  /// `copyInto(AbstractAttributeSet)`, plus the one field `Object.clone()` carries across before
  /// upstream's `copyInto` runs. Java's version does not name `label`; that is not "a copied ROM
  /// loses its label": `AbstractAttributeSet.clone()` bitwise-copies every field via
  /// `super.clone()` first and `copyInto` only re-states what it wants to be explicit about.
  /// Swift has no `Object.clone()`, so the copy here has to be complete to match at runtime.
  /// (`RamAttributes.swift`'s header carries the long form of this argument.)
  ///
  /// `contents` is the one field that is deep-copied rather than shared: `d.contents =
  /// contents.clone()`. A duplicated ROM gets its own memory array, which is the difference
  /// between "copy this ROM" and "place a second reference to the same data", and the reason
  /// `Rom` can hold its contents in the attribute set at all.
  public override func copyInto(_ destination: AbstractAttributeSet) {
    guard let destination = destination as? RomAttributes else { return }
    destination.addrBits = addrBits
    destination.dataBits = dataBits
    destination.lineSize = lineSize
    destination.allowMisaligned = allowMisaligned
    destination.contents = contents.cloneContents()
    destination.label = label
    destination.labelFont = labelFont
    destination.labelVisible = labelVisible
    destination.appearance = appearance
  }
}
