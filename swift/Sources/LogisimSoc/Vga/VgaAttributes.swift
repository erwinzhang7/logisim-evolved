// VgaAttributes.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.vga.VgaAttributes),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

private func makeVgaStateAttribute() -> Attribute<VgaState> {
  Attribute(
    name: "VgaState",
    isHidden: true,
    isToSave: false,
    codec: AttributeCodec(
      parse: { _ in VgaState() },
      toStandardString: { _ in "" },
      encode: { .object(AttributeObjectBox($0 as AnyObject)) },
      decode: { if case .object(let box) = $0 { return box.object as? VgaState } else { return nil } }))
}

/// `com.cburch.logisim.soc.vga.VgaAttributes`.
public final class VgaAttributes: AbstractAttributeSet {

  public static let vgaState: Attribute<VgaState> = makeVgaStateAttribute()
  public static let startAddress: Attribute<Int32> = Attributes.forHexInteger("StartAddress")
  public static let bufferAddress: Attribute<Int32> = Attributes.forHexInteger("BufferAddress")
  public static let mode: Attribute<VgaMode> = Attributes.forOption("DisplayMode")
  public static let soft160x120: Attribute<Bool> = Attributes.forBoolean("soft160x120")
  public static let soft320x240: Attribute<Bool> = Attributes.forBoolean("soft320x240")
  public static let soft640x480: Attribute<Bool> = Attributes.forBoolean("soft640x480")
  public static let soft800x600: Attribute<Bool> = Attributes.forBoolean("soft800x600")
  public static let soft1024x768: Attribute<Bool> = Attributes.forBoolean("soft1024x768")

  private static let attributeList: [AnyAttribute] = [
    startAddress, mode, bufferAddress, soft160x120, soft320x240, soft640x480, soft800x600,
    soft1024x768, StdAttr.label, StdAttr.labelFont, StdAttr.labelVisibility,
    SocSimulationManager.socBusSelect, vgaState,
  ]

  private var labelFontValue: FontSpec = StdAttr.defaultLabelFont
  private var labelVisibleValue = true
  private var state = VgaState()

  public override var attributes: [AnyAttribute] { Self.attributeList }
  public override func makeCopyInstance() -> AbstractAttributeSet { VgaAttributes() }

  public override func copyInto(_ destination: AbstractAttributeSet) {
    guard let d = destination as? VgaAttributes else { return }
    d.labelFontValue = labelFontValue
    d.labelVisibleValue = labelVisibleValue
    d.state = VgaState()
    state.copyInto(d.state)
  }

  public override func isReadOnly(_ attribute: AnyAttribute) -> Bool { attribute === Self.vgaState }
  public override func isToSave(_ attribute: AnyAttribute) -> Bool {
    attribute.isToSave && attribute !== Self.vgaState
  }

  public override func rawValue(_ attribute: AnyAttribute) -> AttributeValue? {
    if attribute === Self.startAddress { return Self.startAddress.encode(state.startAddress) }
    if attribute === Self.mode { return Self.mode.encode(state.initialMode) }
    if attribute === Self.bufferAddress {
      return Self.bufferAddress.encode(state.vgaBufferAddress)
    }
    if attribute === StdAttr.label { return StdAttr.label.encode(state.label) }
    if attribute === StdAttr.labelFont { return StdAttr.labelFont.encode(labelFontValue) }
    if attribute === StdAttr.labelVisibility {
      return StdAttr.labelVisibility.encode(labelVisibleValue)
    }
    if attribute === SocSimulationManager.socBusSelect {
      return SocSimulationManager.socBusSelect.encode(state.busInfo)
    }
    if attribute === Self.vgaState { return Self.vgaState.encode(state) }
    if attribute === Self.soft160x120 { return Self.soft160x120.encode(state.soft160x120) }
    if attribute === Self.soft320x240 { return Self.soft320x240.encode(state.soft320x240) }
    if attribute === Self.soft640x480 { return Self.soft640x480.encode(state.soft640x480) }
    if attribute === Self.soft800x600 { return Self.soft800x600.encode(state.soft800x600) }
    if attribute === Self.soft1024x768 { return Self.soft1024x768.encode(state.soft1024x768) }
    return nil
  }

  public override func setRawValue(_ attribute: AnyAttribute, _ value: AttributeValue?) throws {
    func fail() -> Error {
      ComponentError.unsupportedAttributeValue(factory: "SocVga", attribute: attribute.name)
    }
    if attribute === Self.startAddress {
      guard let value, let v = Self.startAddress.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if state.setStartAddress(v) { fireAttributeValueChanged(attribute, value: value, oldValue: old) }
      return
    }
    if attribute === Self.mode {
      guard let value, let v = Self.mode.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if state.setInitialMode(v) { fireAttributeValueChanged(attribute, value: value, oldValue: old) }
      return
    }
    if attribute === Self.bufferAddress {
      guard let value, let v = Self.bufferAddress.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if state.setVgaBufferStartAddress(v) {
        fireAttributeValueChanged(attribute, value: value, oldValue: old)
      }
      return
    }
    if attribute === StdAttr.label {
      guard let value, let v = StdAttr.label.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if state.setLabel(v) { fireAttributeValueChanged(attribute, value: value, oldValue: old) }
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
      if state.setBusInfo(info) { fireAttributeValueChanged(attribute, value: value, oldValue: old) }
      return
    }
    if attribute === Self.soft160x120 {
      guard let value, let v = Self.soft160x120.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if state.setSoft160x120(v) { fireAttributeValueChanged(attribute, value: value, oldValue: old) }
      return
    }
    if attribute === Self.soft320x240 {
      guard let value, let v = Self.soft320x240.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if state.setSoft320x240(v) { fireAttributeValueChanged(attribute, value: value, oldValue: old) }
      return
    }
    if attribute === Self.soft640x480 {
      guard let value, let v = Self.soft640x480.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if state.setSoft640x480(v) { fireAttributeValueChanged(attribute, value: value, oldValue: old) }
      return
    }
    if attribute === Self.soft800x600 {
      guard let value, let v = Self.soft800x600.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if state.setSoft800x600(v) { fireAttributeValueChanged(attribute, value: value, oldValue: old) }
      return
    }
    if attribute === Self.soft1024x768 {
      guard let value, let v = Self.soft1024x768.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if state.setSoft1024x768(v) { fireAttributeValueChanged(attribute, value: value, oldValue: old) }
      return
    }
  }
}
