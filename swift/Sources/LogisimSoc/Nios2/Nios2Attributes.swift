// Nios2Attributes.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.nios2.Nios2Attributes),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// `Nios2Seams.swift` lists `Nios2Attributes.java` as "not ported at all", with the reason: it
// "binds `Nios2Config`'s fields to LogisimKernel's `Attribute<V>`/`AttributeSet` (D5) machinery
// … wiring it into a real `AttributeSet` is the integrator's job once this module has a
// confirmed dependency edge onto `LogisimKernel`'s D5 API." That edge exists; every other SoC
// peripheral in this module already has its `*Attributes` class, so this closes the seam.
//
// It is not cosmetic. `Soc.java`'s tool list is eight `AddTool`s, and an `AddTool` without a
// factory that returns a real attribute set cannot answer `XmlWriter`'s "is this attribute at
// its factory default?" question, which is what decides whether `<lib desc="#Soc">` comes back
// self-closing (as the oracle writes it) or carrying seven `<tool>` blocks.
//
// Divergence, same one `Rv32imAttributes.swift` documents: Java's `Nios2State.attachedBus` IS
// the `SocBusInfo` the attribute hands out; `Nios2Config` stores only the id string, so this
// set owns the object and mirrors its id into the config on write.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

/// `Nios2Attributes.Nios2StateAttribute`. Java's `Attribute()` no-argument constructor is
/// `this("dummy", null, true)`, hence the name and the hidden flag; `parse` returns `null`
/// upstream because the value is rebuilt by `copyInto`, never deserialised.
private func makeNios2StateAttribute() -> Attribute<Nios2Config> {
  Attribute(
    name: "dummy",
    isHidden: true,
    isToSave: false,
    codec: AttributeCodec(
      parse: { _ in Nios2Config() },
      toStandardString: { _ in "" },
      encode: { .object(AttributeObjectBox($0 as AnyObject)) },
      decode: {
        if case .object(let box) = $0 { return box.object as? Nios2Config } else { return nil }
      }))
}

/// `com.cburch.logisim.soc.nios2.Nios2Attributes`.
public final class Nios2Attributes: AbstractAttributeSet {

  /// `RESET_VECTOR`.
  public static let resetVector: Attribute<Int32> = Attributes.forHexInteger("resetVector")
  /// `EXCEPTION_VECTOR`.
  public static let exceptionVector: Attribute<Int32> = Attributes.forHexInteger(
    "exceptionVector")
  /// `BREAK_VECTOR`.
  public static let breakVector: Attribute<Int32> = Attributes.forHexInteger("breakVector")
  /// `NR_OF_IRQS`, `Attributes.forBitWidth("irqWidth", …, 0, 32)`.
  public static let nrOfIrqs: Attribute<BitWidth> = Attributes.forBitWidth(
    "irqWidth", min: 0, max: 32)
  /// `NIOS_STATE_VISIBLE`.
  public static let stateVisible: Attribute<Bool> = Attributes.forBoolean("stateVisible")
  /// `NIOS2_STATE`.
  public static let nios2State: Attribute<Nios2Config> = makeNios2StateAttribute()

  /// `ATTRIBUTES`, in upstream's order.
  private static let attributeList: [AnyAttribute] = [
    resetVector, exceptionVector, breakVector, nrOfIrqs, stateVisible, StdAttr.label,
    StdAttr.labelFont, StdAttr.labelVisibility, SocSimulationManager.socBusSelect, nios2State,
  ]

  private var labelFontValue: FontSpec = StdAttr.defaultLabelFont
  private var labelVisibleValue = true
  private var stateVisibleValue = true
  private var upState = Nios2Config()

  public override var attributes: [AnyAttribute] { Self.attributeList }

  public override func makeCopyInstance() -> AbstractAttributeSet { Nios2Attributes() }

  public override func copyInto(_ destination: AbstractAttributeSet) {
    guard let d = destination as? Nios2Attributes else { return }
    d.labelFontValue = labelFontValue
    d.labelVisibleValue = labelVisibleValue
    d.stateVisibleValue = stateVisibleValue
    d.upState = Nios2Config()
    upState.copyInto(d.upState)
  }

  public override func isReadOnly(_ attribute: AnyAttribute) -> Bool {
    attribute === Self.nios2State
  }

  public override func isToSave(_ attribute: AnyAttribute) -> Bool {
    attribute.isToSave && attribute !== Self.nios2State
  }

  public override func rawValue(_ attribute: AnyAttribute) -> AttributeValue? {
    if attribute === Self.resetVector {
      return Self.resetVector.encode(Int32(truncatingIfNeeded: upState.resetVector))
    }
    if attribute === Self.exceptionVector {
      return Self.exceptionVector.encode(Int32(truncatingIfNeeded: upState.exceptionVector))
    }
    if attribute === Self.breakVector {
      return Self.breakVector.encode(Int32(truncatingIfNeeded: upState.breakVector))
    }
    if attribute === Self.nrOfIrqs {
      return Self.nrOfIrqs.encode(BitWidth.known(upState.nrOfIrqs))
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
    if attribute === Self.nios2State { return Self.nios2State.encode(upState) }
    return nil
  }

  public override func setRawValue(_ attribute: AnyAttribute, _ value: AttributeValue?) throws {
    func fail() -> Error {
      ComponentError.unsupportedAttributeValue(factory: Nios2.id, attribute: attribute.name)
    }
    if attribute === Self.resetVector {
      guard let value, let v = Self.resetVector.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if upState.setResetVector(Int(v)) {
        fireAttributeValueChanged(attribute, value: value, oldValue: old)
      }
      return
    }
    if attribute === Self.exceptionVector {
      guard let value, let v = Self.exceptionVector.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if upState.setExceptionVector(Int(v)) {
        fireAttributeValueChanged(attribute, value: value, oldValue: old)
      }
      return
    }
    if attribute === Self.breakVector {
      guard let value, let v = Self.breakVector.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if upState.setBreakVector(Int(v)) {
        fireAttributeValueChanged(attribute, value: value, oldValue: old)
      }
      return
    }
    if attribute === Self.nrOfIrqs {
      guard let value, let width = Self.nrOfIrqs.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if upState.setNrOfIrqs(Int(width.width)) {
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
      // `if (upState.setAttachedBus((SocBusInfo) value)) fireAttributeValueChanged(...)`
      // (`Nios2Attributes.java:131-134`). The config keeps ITS `SocBusInfo` and copies the id
      // out of `value`, so the identity `SocSimulationManager` attached to survives.
      if upState.setAttachedBus(info) {
        fireAttributeValueChanged(attribute, value: value, oldValue: old)
      }
      return
    }
    // `NIOS2_STATE` is read-only; Java's `setValue` has no branch for it, so assignment is
    // silently ignored rather than rejected.
  }
}
