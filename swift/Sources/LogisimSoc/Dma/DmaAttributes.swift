// DmaAttributes.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.dma.DmaAttributes),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Not ported: `MasterBusSelector`/`MasterBusSelectAttribute.getCellEditor`,
// `BurstSizeAttribute.getCellEditor` (a `ComboBox` over `BURST_OPTIONS`); both are attribute-
// table cell-editor widgets (D9). The two master-only bus-select attributes
// (`DMA_SRC_BUS`/`DMA_DST_BUS`) keep their distinct identity from `SocSimulationManager
// .SOC_BUS_SELECT` (they do not drive slave/sniffer registration: see `SocSimulationManager
// .registerComponent`'s note on additional `SocBusInfo` attributes), which is why they get their
// own attribute constants here rather than reusing the shared one.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

/// `DmaAttributes.BurstSizeAttribute.BURST_OPTIONS`.
private let dmaBurstOptions: [Int32] = [1, 2, 4, 8, 16, 32, 64, 128, 256]

/// `DmaAttributes.BurstSizeAttribute`.
///
/// `parse` clamps to the nearest valid power-of-two burst size *at or above* the parsed value,
/// falling back to the largest option if none is big enough: ported exactly, including that an
/// input larger than 256 silently becomes 256 rather than erroring.
private func makeBurstSizeAttribute() -> Attribute<Int32> {
  Attribute(
    name: "BurstSize",
    codec: AttributeCodec(
      parse: { text in
        guard let v = Int32(text) else {
          throw AttributeParseError.numberFormat("For input string: \"\(text)\"")
        }
        for option in dmaBurstOptions where option >= v { return option }
        return dmaBurstOptions[dmaBurstOptions.count - 1]
      },
      toStandardString: { String($0) },
      encode: { .integer($0) },
      decode: { if case .integer(let value) = $0 { return value } else { return nil } }))
}

private func makeMasterBusSelectAttribute(_ name: String) -> Attribute<SocBusInfo> {
  Attribute(
    name: name,
    codec: AttributeCodec(
      parse: { SocBusInfo($0) },
      toStandardString: { $0.busId },
      encode: { .string($0.busId) },
      decode: { if case .string(let id) = $0 { return SocBusInfo(id) } else { return nil } }))
}

private func makeDmaStateAttribute() -> Attribute<DmaState> {
  Attribute(
    name: "DmaState",
    isHidden: true,
    isToSave: false,
    codec: AttributeCodec(
      parse: { _ in DmaState() },
      toStandardString: { _ in "" },
      encode: { .object(AttributeObjectBox($0 as AnyObject)) },
      decode: { if case .object(let box) = $0 { return box.object as? DmaState } else { return nil } }))
}

/// `com.cburch.logisim.soc.dma.DmaAttributes`.
public final class DmaAttributes: AbstractAttributeSet {

  public static let startAddress: Attribute<Int32> = Attributes.forHexInteger("StartAddress")
  public static let burstSize: Attribute<Int32> = makeBurstSizeAttribute()
  public static let dmaState: Attribute<DmaState> = makeDmaStateAttribute()
  public static let srcBus: Attribute<SocBusInfo> = makeMasterBusSelectAttribute("DmaSrcBus")
  public static let dstBus: Attribute<SocBusInfo> = makeMasterBusSelectAttribute("DmaDstBus")

  private static let attributeList: [AnyAttribute] = [
    startAddress, burstSize, StdAttr.label, StdAttr.labelFont, StdAttr.labelVisibility,
    SocSimulationManager.socBusSelect, srcBus, dstBus, dmaState,
  ]

  private var labelFontValue: FontSpec = StdAttr.defaultLabelFont
  private var labelVisibleValue = true
  private var state = DmaState()

  public override var attributes: [AnyAttribute] { Self.attributeList }

  public override func makeCopyInstance() -> AbstractAttributeSet { DmaAttributes() }

  public override func copyInto(_ destination: AbstractAttributeSet) {
    guard let d = destination as? DmaAttributes else { return }
    d.labelFontValue = labelFontValue
    d.labelVisibleValue = labelVisibleValue
    d.state = DmaState()
    _ = d.state.setStartAddress(state.startAddress)
    _ = d.state.setBurstSize(state.burstSize)
    _ = d.state.setLabel(state.label)
    _ = d.state.setControlBus(state.controlBusInfo)
    _ = d.state.setSourceBus(state.sourceBusInfo)
    _ = d.state.setDestBus(state.destBusInfo)
  }

  public override func isReadOnly(_ attribute: AnyAttribute) -> Bool { attribute === Self.dmaState }

  public override func isToSave(_ attribute: AnyAttribute) -> Bool {
    attribute.isToSave && attribute !== Self.dmaState
  }

  public override func rawValue(_ attribute: AnyAttribute) -> AttributeValue? {
    if attribute === Self.startAddress { return Self.startAddress.encode(state.startAddress) }
    if attribute === Self.burstSize { return Self.burstSize.encode(state.burstSize) }
    if attribute === StdAttr.label { return StdAttr.label.encode(state.label) }
    if attribute === StdAttr.labelFont { return StdAttr.labelFont.encode(labelFontValue) }
    if attribute === StdAttr.labelVisibility {
      return StdAttr.labelVisibility.encode(labelVisibleValue)
    }
    if attribute === SocSimulationManager.socBusSelect {
      return SocSimulationManager.socBusSelect.encode(state.controlBusInfo)
    }
    if attribute === Self.srcBus { return Self.srcBus.encode(state.sourceBusInfo) }
    if attribute === Self.dstBus { return Self.dstBus.encode(state.destBusInfo) }
    if attribute === Self.dmaState { return Self.dmaState.encode(state) }
    return nil
  }

  public override func setRawValue(_ attribute: AnyAttribute, _ value: AttributeValue?) throws {
    func fail() -> Error {
      ComponentError.unsupportedAttributeValue(factory: "SocDma", attribute: attribute.name)
    }
    if attribute === Self.startAddress {
      guard let value, let addr = Self.startAddress.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if state.setStartAddress(addr) { fireAttributeValueChanged(attribute, value: value, oldValue: old) }
      return
    }
    if attribute === Self.burstSize {
      guard let value, let size = Self.burstSize.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if state.setBurstSize(size) { fireAttributeValueChanged(attribute, value: value, oldValue: old) }
      return
    }
    if attribute === StdAttr.label {
      guard let value, let label = StdAttr.label.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if state.setLabel(label) { fireAttributeValueChanged(attribute, value: value, oldValue: old) }
      return
    }
    if attribute === StdAttr.labelFont {
      guard let value, let font = StdAttr.labelFont.decode(value) else { throw fail() }
      if labelFontValue != font {
        let old = rawValue(attribute)
        labelFontValue = font
        fireAttributeValueChanged(attribute, value: value, oldValue: old)
      }
      return
    }
    if attribute === StdAttr.labelVisibility {
      guard let value, let visible = StdAttr.labelVisibility.decode(value) else { throw fail() }
      if labelVisibleValue != visible {
        let old = rawValue(attribute)
        labelVisibleValue = visible
        fireAttributeValueChanged(attribute, value: value, oldValue: old)
      }
      return
    }
    if attribute === SocSimulationManager.socBusSelect {
      guard let value, let info = SocSimulationManager.socBusSelect.decode(value) else {
        throw fail()
      }
      let old = rawValue(attribute)
      if state.setControlBus(info) { fireAttributeValueChanged(attribute, value: value, oldValue: old) }
      return
    }
    if attribute === Self.srcBus {
      guard let value, let info = Self.srcBus.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if state.setSourceBus(info) { fireAttributeValueChanged(attribute, value: value, oldValue: old) }
      return
    }
    if attribute === Self.dstBus {
      guard let value, let info = Self.dstBus.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if state.setDestBus(info) { fireAttributeValueChanged(attribute, value: value, oldValue: old) }
      return
    }
  }
}
