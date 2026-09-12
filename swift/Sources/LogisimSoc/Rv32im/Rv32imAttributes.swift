// Rv32imAttributes.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.rv32im.RV32imAttributes),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Why this file exists at all ─────────────────────────────────────────────────────────────
//
// `Rv32imConfig` (the port of Java's outer `RV32imState`) already carries every value this set
// exposes, and its own header says the `AttributeSet` wiring "is not ported (out of this
// slice)". That gap is what kept `#Soc` unregisterable: `Soc.java`'s tool list is eight
// `AddTool`s, `AddTool` needs a `ComponentFactory`, and a factory without a real
// `createAttributeSet()` cannot answer the writer's "is this attribute at its default?"
// question. So this is the missing half, and it is a codec-level requirement, not a GUI one.
//
// ── A divergence this file used to state, now closed ────────────────────────────────────────
//
// This header used to read: "Java's `RV32imState.attachedBus` IS the `SocBusInfo` object the
// attribute returns […] `Rv32imConfig` stores only the id string, so this set owns the
// `SocBusInfo` and mirrors its id into the config on every write. The observable difference is
// confined to a live simulation that re-assigns a bus id behind the attribute's back."
//
// That last sentence was true only while nothing simulated. `SocSimulationManager
// .registerComponent` attaches the manager and the placed component **to the object the
// attribute hands back**, and `Rv32imConfig.insertTransaction`/`entryPoint` read them off its
// own `attachedBus`; two objects means the CPU never learns which bus it is on. `Rv32imConfig`
// now owns the `SocBusInfo`, exactly as `RV32imState` does, and this set returns it
// (`RV32imAttributes.java:115` is literally `return upState.getAttachedBus();`).
//
// `plicState.setAttachedBus(upState.getAttachedBus())` (`RV32imAttributes.java:86`, and again in
// the `SOC_BUS_SELECT` setter at `:150`) is ported too, so the PLIC, a bus slave in its own
// right, resolves its own component and name.
//
// Not ported: `getValue`'s GUI-only branches have no counterpart (there are none) and the
// `SocUpMenuProvider` hooks (`Nios2Seams.swift` records the same seam).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

/// `RV32imAttributes.Rv32imStateAttribute`. Java builds it with `Attribute()`'s no-argument
/// constructor, which is `this("dummy", null, true)`; hence the name and the hidden flag.
/// `parse` returns `null` upstream: the value is never serialised, only rebuilt by `copyInto`.
private func makeRv32imStateAttribute() -> Attribute<Rv32imConfig> {
  Attribute(
    name: "dummy",
    isHidden: true,
    isToSave: false,
    codec: AttributeCodec(
      parse: { _ in Rv32imConfig() },
      toStandardString: { _ in "" },
      encode: { .object(AttributeObjectBox($0 as AnyObject)) },
      decode: {
        if case .object(let box) = $0 { return box.object as? Rv32imConfig } else { return nil }
      }))
}

/// `RV32imAttributes.Rv32imPlicStateAttribute`. Same shape, same `"dummy"` name; Java really
/// does give both state attributes the same name, and it is harmless because both are hidden
/// and neither is saved, so no `<a name="…">` can ever resolve to one.
private func makeRv32imPlicStateAttribute() -> Attribute<Rv32imPlicState> {
  Attribute(
    name: "dummy",
    isHidden: true,
    isToSave: false,
    codec: AttributeCodec(
      parse: { _ in Rv32imPlicState() },
      toStandardString: { _ in "" },
      encode: { .object(AttributeObjectBox($0 as AnyObject)) },
      decode: {
        if case .object(let box) = $0 { return box.object as? Rv32imPlicState } else { return nil }
      }))
}

/// `com.cburch.logisim.soc.rv32im.RV32imAttributes`.
public final class Rv32imAttributes: AbstractAttributeSet {

  /// `RESET_VECTOR`, `Attributes.forHexInteger("resetVector", …)`.
  public static let resetVector: Attribute<Int32> = Attributes.forHexInteger("resetVector")
  /// `NR_OF_IRQS`, `Attributes.forBitWidth("irqWidth", …, 0, 32)`.
  public static let nrOfIrqs: Attribute<BitWidth> = Attributes.forBitWidth(
    "irqWidth", min: 0, max: 32)
  /// `RV32IM_PLIC_BASE_ADDRESS`.
  public static let plicBaseAddress: Attribute<Int32> = Attributes.forHexInteger(
    "plicBaseAddress")
  /// `RV32IM_STATE_VISIBLE`.
  public static let stateVisible: Attribute<Bool> = Attributes.forBoolean("stateVisible")
  /// `RV32IM_STATE`.
  public static let rv32imState: Attribute<Rv32imConfig> = makeRv32imStateAttribute()
  /// `RV32IM_PLIC_STATE`.
  public static let rv32imPlicState: Attribute<Rv32imPlicState> = makeRv32imPlicStateAttribute()

  /// `ATTRIBUTES`, in upstream's order, which is the order `XmlWriter` walks, so it decides
  /// the order of any `<a>` children a non-default tool or component writes.
  private static let attributeList: [AnyAttribute] = [
    resetVector, nrOfIrqs, plicBaseAddress, stateVisible, StdAttr.label, StdAttr.labelFont,
    StdAttr.labelVisibility, SocSimulationManager.socBusSelect, rv32imState, rv32imPlicState,
  ]

  private var labelFontValue: FontSpec = StdAttr.defaultLabelFont
  private var labelVisibleValue = true
  private var stateVisibleValue = true
  private var upState = Rv32imConfig()
  private var plicState = Rv32imPlicState()

  /// `RV32imAttributes()`: `plicState.setAttachedBus(upState.getAttachedBus())`. The PLIC and
  /// the CPU share ONE `SocBusInfo`, which is how the PLIC (a bus slave) resolves the component
  /// it lives inside.
  public override init() {
    super.init()
    plicState.attachedBus = upState.attachedBus
  }

  public override var attributes: [AnyAttribute] { Self.attributeList }

  public override func makeCopyInstance() -> AbstractAttributeSet { Rv32imAttributes() }

  /// `copyInto(AbstractAttributeSet)`. Java rebuilds `upState` from scratch and copies into it,
  /// then re-points the PLIC's base address and bus, reproduced field for field.
  public override func copyInto(_ destination: AbstractAttributeSet) {
    guard let d = destination as? Rv32imAttributes else { return }
    d.labelFontValue = labelFontValue
    d.labelVisibleValue = labelVisibleValue
    d.stateVisibleValue = stateVisibleValue
    d.upState = Rv32imConfig()
    upState.copyInto(d.upState)
    d.plicState = Rv32imPlicState()
    d.plicState.setPlicBaseAddress(plicState.baseAddress)
    d.plicState.attachedBus = d.upState.attachedBus
  }

  /// `isReadOnly`: the two state attributes and nothing else.
  public override func isReadOnly(_ attribute: AnyAttribute) -> Bool {
    attribute === Self.rv32imState || attribute === Self.rv32imPlicState
  }

  /// `isToSave`: `attr.isToSave() && attr != RV32IM_STATE && attr != RV32IM_PLIC_STATE`.
  public override func isToSave(_ attribute: AnyAttribute) -> Bool {
    attribute.isToSave && attribute !== Self.rv32imState && attribute !== Self.rv32imPlicState
  }

  public override func rawValue(_ attribute: AnyAttribute) -> AttributeValue? {
    if attribute === Self.resetVector {
      return Self.resetVector.encode(Int32(truncatingIfNeeded: upState.resetVector))
    }
    if attribute === Self.nrOfIrqs {
      return Self.nrOfIrqs.encode(BitWidth.known(upState.numberOfIrqs))
    }
    if attribute === Self.plicBaseAddress {
      return Self.plicBaseAddress.encode(Int32(truncatingIfNeeded: plicState.baseAddress))
    }
    if attribute === Self.stateVisible { return Self.stateVisible.encode(stateVisibleValue) }
    if attribute === StdAttr.label { return StdAttr.label.encode(upState.label) }
    if attribute === StdAttr.labelFont { return StdAttr.labelFont.encode(labelFontValue) }
    if attribute === StdAttr.labelVisibility {
      return StdAttr.labelVisibility.encode(labelVisibleValue)
    }
    if attribute === SocSimulationManager.socBusSelect {
      return SocSimulationManager.socBusSelect.encode(upState.attachedBus)
    }
    if attribute === Self.rv32imState { return Self.rv32imState.encode(upState) }
    if attribute === Self.rv32imPlicState { return Self.rv32imPlicState.encode(plicState) }
    return nil
  }

  public override func setRawValue(_ attribute: AnyAttribute, _ value: AttributeValue?) throws {
    func fail() -> Error {
      ComponentError.unsupportedAttributeValue(factory: Rv32imRiscV.id, attribute: attribute.name)
    }
    if attribute === Self.resetVector {
      guard let value, let v = Self.resetVector.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if upState.setResetVector(Int(v)) {
        fireAttributeValueChanged(attribute, value: value, oldValue: old)
      }
      return
    }
    if attribute === Self.nrOfIrqs {
      guard let value, let width = Self.nrOfIrqs.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if upState.setNumberOfIrqs(Int(width.width)) {
        fireAttributeValueChanged(attribute, value: value, oldValue: old)
      }
      return
    }
    if attribute === Self.plicBaseAddress {
      guard let value, let v = Self.plicBaseAddress.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if plicState.setPlicBaseAddress(Int(v)) {
        fireAttributeValueChanged(attribute, value: value, oldValue: old)
      }
      return
    }
    if attribute === Self.stateVisible {
      guard let value, let v = Self.stateVisible.decode(value) else { throw fail() }
      if v != stateVisibleValue {
        let old = rawValue(attribute)
        stateVisibleValue = v
        fireAttributeValueChanged(attribute, value: value, oldValue: old)
      }
      return
    }
    if attribute === StdAttr.label {
      guard let value, let v = StdAttr.label.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if upState.setLabel(v) {
        plicState.setLabel(v)
        fireAttributeValueChanged(attribute, value: value, oldValue: old)
      }
      return
    }
    if attribute === StdAttr.labelFont {
      guard let value, let font = StdAttr.labelFont.decode(value) else { throw fail() }
      if font != labelFontValue {
        let old = rawValue(attribute)
        labelFontValue = font
        fireAttributeValueChanged(attribute, value: value, oldValue: old)
      }
      return
    }
    if attribute === StdAttr.labelVisibility {
      guard let value, let v = StdAttr.labelVisibility.decode(value) else { throw fail() }
      if v != labelVisibleValue {
        let old = rawValue(attribute)
        labelVisibleValue = v
        fireAttributeValueChanged(attribute, value: value, oldValue: old)
      }
      return
    }
    if attribute === SocSimulationManager.socBusSelect {
      guard let value, let info = SocSimulationManager.socBusSelect.decode(value) else {
        throw fail()
      }
      let old = rawValue(attribute)
      // `if (upState.setAttachedBus(value)) { plicState.setAttachedBus(upState.getAttachedBus());
      //   fireAttributeValueChanged(...); }`; note the config keeps ITS object and copies the
      // id out of `value`, so the identity the manager attached to survives a `setValue`.
      if upState.setAttachedBus(info) {
        plicState.attachedBus = upState.attachedBus
        fireAttributeValueChanged(attribute, value: value, oldValue: old)
      }
      return
    }
    // `RV32IM_STATE`/`RV32IM_PLIC_STATE` are read-only: Java's `setValue` has no branch for
    // them, so an assignment is silently ignored rather than rejected. Same here.
  }
}
