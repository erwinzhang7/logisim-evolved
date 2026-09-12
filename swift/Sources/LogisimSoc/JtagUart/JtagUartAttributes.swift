// JtagUartAttributes.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.jtaguart.JtagUartAttributes),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

private func makeJtagUartStateAttribute() -> Attribute<JtagUartState> {
  Attribute(
    name: "JtagUartState",
    isHidden: true,
    isToSave: false,
    codec: AttributeCodec(
      parse: { _ in JtagUartState() },
      toStandardString: { _ in "" },
      encode: { .object(AttributeObjectBox($0 as AnyObject)) },
      decode: {
        if case .object(let box) = $0 { return box.object as? JtagUartState } else { return nil }
      }))
}

/// `com.cburch.logisim.soc.jtaguart.JtagUartAttributes`.
public final class JtagUartAttributes: AbstractAttributeSet {

  public static let startAddress: Attribute<Int32> = Attributes.forHexInteger("StartAddress")
  public static let jtagState: Attribute<JtagUartState> = makeJtagUartStateAttribute()
  public static let writeFifoSize: Attribute<JtagUartFifoSize> = Attributes.forOption(
    "WriteFifoSize")
  public static let writeIrqThreshold: Attribute<Int32> = Attributes.forInteger("WriteThreshold")
  public static let readFifoSize: Attribute<JtagUartFifoSize> = Attributes.forOption(
    "ReadFifoSize")
  public static let readIrqThreshold: Attribute<Int32> = Attributes.forInteger("ReadThreshold")

  private static let attributeList: [AnyAttribute] = [
    startAddress, writeFifoSize, writeIrqThreshold, readFifoSize, readIrqThreshold,
    StdAttr.label, StdAttr.labelFont, StdAttr.labelVisibility,
    SocSimulationManager.socBusSelect, jtagState,
  ]

  private var labelFontValue: FontSpec = StdAttr.defaultLabelFont
  private var labelVisibleValue = true
  private var state = JtagUartState()

  public override var attributes: [AnyAttribute] { Self.attributeList }
  public override func makeCopyInstance() -> AbstractAttributeSet { JtagUartAttributes() }

  public override func copyInto(_ destination: AbstractAttributeSet) {
    guard let d = destination as? JtagUartAttributes else { return }
    d.labelFontValue = labelFontValue
    d.labelVisibleValue = labelVisibleValue
    d.state = JtagUartState()
    state.copyInto(d.state)
  }

  public override func isReadOnly(_ attribute: AnyAttribute) -> Bool { attribute === Self.jtagState }
  public override func isToSave(_ attribute: AnyAttribute) -> Bool {
    attribute.isToSave && attribute !== Self.jtagState
  }

  public override func rawValue(_ attribute: AnyAttribute) -> AttributeValue? {
    if attribute === Self.startAddress { return Self.startAddress.encode(state.startAddress) }
    if attribute === Self.writeFifoSize { return Self.writeFifoSize.encode(state.writeFifoSize) }
    if attribute === Self.writeIrqThreshold {
      return Self.writeIrqThreshold.encode(state.writeIrqThreshold)
    }
    if attribute === Self.readFifoSize { return Self.readFifoSize.encode(state.readFifoSize) }
    if attribute === Self.readIrqThreshold {
      return Self.readIrqThreshold.encode(state.readIrqThreshold)
    }
    if attribute === StdAttr.label { return StdAttr.label.encode(state.label) }
    if attribute === StdAttr.labelFont { return StdAttr.labelFont.encode(labelFontValue) }
    if attribute === StdAttr.labelVisibility {
      return StdAttr.labelVisibility.encode(labelVisibleValue)
    }
    if attribute === SocSimulationManager.socBusSelect {
      return SocSimulationManager.socBusSelect.encode(state.attachedBusInfo)
    }
    if attribute === Self.jtagState { return Self.jtagState.encode(state) }
    return nil
  }

  public override func setRawValue(_ attribute: AnyAttribute, _ value: AttributeValue?) throws {
    func fail() -> Error {
      ComponentError.unsupportedAttributeValue(factory: "SocJtagUart", attribute: attribute.name)
    }
    if attribute === Self.startAddress {
      guard let value, let v = Self.startAddress.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if state.setStartAddress(v) { fireAttributeValueChanged(attribute, value: value, oldValue: old) }
      return
    }
    if attribute === Self.writeFifoSize {
      guard let value, let v = Self.writeFifoSize.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if state.setWriteFifoSize(v) { fireAttributeValueChanged(attribute, value: value, oldValue: old) }
      return
    }
    if attribute === Self.writeIrqThreshold {
      guard let value, let v = Self.writeIrqThreshold.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if state.setWriteIrqThreshold(v) { fireAttributeValueChanged(attribute, value: value, oldValue: old) }
      return
    }
    if attribute === Self.readFifoSize {
      guard let value, let v = Self.readFifoSize.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if state.setReadFifoSize(v) { fireAttributeValueChanged(attribute, value: value, oldValue: old) }
      return
    }
    if attribute === Self.readIrqThreshold {
      guard let value, let v = Self.readIrqThreshold.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if state.setReadIrqThreshold(v) { fireAttributeValueChanged(attribute, value: value, oldValue: old) }
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
      if state.setAttachedBus(info) { fireAttributeValueChanged(attribute, value: value, oldValue: old) }
      return
    }
  }
}
