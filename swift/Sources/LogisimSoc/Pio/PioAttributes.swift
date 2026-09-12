// PioAttributes.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.pio.PioAttributes),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// The one attribute set in this module whose *attribute list itself* changes shape at runtime:
// which of the output-specific / input-specific / IRQ-specific attributes are visible depends on
// the current port direction and capture-mode settings. `attributeList` below recomputes on
// every read exactly as Java's `updateAttributeList()` rebuilds `myAttributes`, and
// `fireAttributeListChanged()` fires whenever a direction/mode change actually altered which
// attributes are present; reproducing the `changes` boolean Java threads through the rebuild.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

private func makePioStateAttribute() -> Attribute<PioState> {
  Attribute(
    name: "PioState",
    isHidden: true,
    isToSave: false,
    codec: AttributeCodec(
      parse: { _ in PioState() },
      toStandardString: { _ in "" },
      encode: { .object(AttributeObjectBox($0 as AnyObject)) },
      decode: { if case .object(let box) = $0 { return box.object as? PioState } else { return nil } }))
}

/// `com.cburch.logisim.soc.pio.PioAttributes`.
public final class PioAttributes: AbstractAttributeSet {

  public static let pioState: Attribute<PioState> = makePioStateAttribute()
  public static let direction: Attribute<PioDirection> = Attributes.forOption("direction")
  public static let outputResetValue: Attribute<Int32> = Attributes.forHexInteger(
    "outputresetvalue")
  public static let outputBitSetClear: Attribute<Bool> = Attributes.forBoolean("outputbitsetclear")
  public static let inputsSyncCapture: Attribute<Bool> = Attributes.forBoolean("inputssynccapt")
  public static let captureType: Attribute<PioCaptureEdge> = Attributes.forOption("capturetype")
  public static let inputsCaptureBit: Attribute<Bool> = Attributes.forBoolean("inputscaptbit")
  public static let genIrq: Attribute<Bool> = Attributes.forBoolean("genirq")
  public static let irqType: Attribute<PioIrqType> = Attributes.forOption("irqtype")

  /// `SocMemoryAttributes.START_ADDRESS`: Java reuses the memory peripheral's attribute
  /// constant by identity so both components' `.circ` XML uses the same `<a name="...">` token
  /// and so a single `AttributeSet.getValue` dispatch works for either. Preserved by referencing
  /// the same `Memory/` module constant rather than declaring a second, differently-identified
  /// `StartAddress` attribute.
  public static var startAddress: Attribute<Int32> { SocMemoryAttributes.startAddress }

  private var labelFontValue: FontSpec = StdAttr.defaultLabelFont
  private var labelVisibleValue = true
  private var state = PioState()

  public override var attributes: [AnyAttribute] { buildAttributeList() }

  /// `updateAttributeList()`, minus the `changes` bookkeeping (folded into the setters below,
  /// which compare the list before/after exactly as Java's callers do).
  private func buildAttributeList() -> [AnyAttribute] {
    var list: [AnyAttribute] = [Self.startAddress, StdAttr.width, Self.direction]
    if state.portDirection != .input {
      list.append(Self.outputResetValue)
      list.append(Self.outputBitSetClear)
    }
    if state.portDirection != .output {
      list.append(Self.inputsSyncCapture)
      if state.inputIsCapturedSynchronously {
        list.append(Self.captureType)
        list.append(Self.inputsCaptureBit)
      }
      list.append(Self.genIrq)
      if state.inputIsCapturedSynchronously {
        list.append(Self.irqType)
      }
    }
    list.append(contentsOf: [
      StdAttr.label, StdAttr.labelFont, StdAttr.labelVisibility,
      SocSimulationManager.socBusSelect, Self.pioState,
    ])
    return list
  }

  public override func makeCopyInstance() -> AbstractAttributeSet { PioAttributes() }

  public override func copyInto(_ destination: AbstractAttributeSet) {
    guard let d = destination as? PioAttributes else { return }
    d.labelFontValue = labelFontValue
    d.labelVisibleValue = labelVisibleValue
    d.state = PioState()
    state.copyInto(d.state)
  }

  public override func isReadOnly(_ attribute: AnyAttribute) -> Bool { attribute === Self.pioState }
  public override func isToSave(_ attribute: AnyAttribute) -> Bool {
    attribute.isToSave && attribute !== Self.pioState
  }

  public override func rawValue(_ attribute: AnyAttribute) -> AttributeValue? {
    if attribute === Self.startAddress { return Self.startAddress.encode(state.startAddress) }
    if attribute === StdAttr.width { return StdAttr.width.encode(state.nrOfIOs) }
    if attribute === Self.direction { return Self.direction.encode(state.portDirection) }
    if attribute === StdAttr.label { return StdAttr.label.encode(state.label) }
    if attribute === StdAttr.labelFont { return StdAttr.labelFont.encode(labelFontValue) }
    if attribute === StdAttr.labelVisibility {
      return StdAttr.labelVisibility.encode(labelVisibleValue)
    }
    if attribute === SocSimulationManager.socBusSelect {
      return SocSimulationManager.socBusSelect.encode(state.attachedBusInfo)
    }
    if attribute === Self.outputResetValue {
      return Self.outputResetValue.encode(state.outputResetValue)
    }
    if attribute === Self.outputBitSetClear {
      return Self.outputBitSetClear.encode(state.outputBitManipulations)
    }
    if attribute === Self.inputsSyncCapture {
      return Self.inputsSyncCapture.encode(state.inputIsCapturedSynchronously)
    }
    if attribute === Self.captureType { return Self.captureType.encode(state.inputCaptureEdge) }
    if attribute === Self.inputsCaptureBit {
      return Self.inputsCaptureBit.encode(state.inputCaptureBitClearing)
    }
    if attribute === Self.genIrq { return Self.genIrq.encode(state.inputGeneratesIrq) }
    if attribute === Self.irqType { return Self.irqType.encode(state.irqType) }
    if attribute === Self.pioState { return Self.pioState.encode(state) }
    return nil
  }

  public override func setRawValue(_ attribute: AnyAttribute, _ value: AttributeValue?) throws {
    func fail() -> Error {
      ComponentError.unsupportedAttributeValue(factory: "SocPio", attribute: attribute.name)
    }
    let before = buildAttributeList().map { ObjectIdentifier($0) }
    func maybeNotifyListShape() {
      let after = buildAttributeList().map { ObjectIdentifier($0) }
      if before != after { fireAttributeListChanged() }
    }

    if attribute === Self.startAddress {
      guard let value, let v = Self.startAddress.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if state.setStartAddress(v) { fireAttributeValueChanged(attribute, value: value, oldValue: old) }
      return
    }
    if attribute === StdAttr.width {
      guard let value, let v = StdAttr.width.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if state.setNrOfIOs(v) { fireAttributeValueChanged(attribute, value: value, oldValue: old) }
      return
    }
    if attribute === Self.direction {
      guard let value, let v = Self.direction.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if state.setPortDirection(v) {
        maybeNotifyListShape()
        fireAttributeValueChanged(attribute, value: value, oldValue: old)
      }
      return
    }
    if attribute === Self.outputResetValue {
      guard let value, let v = Self.outputResetValue.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if state.setOutputResetValue(v) { fireAttributeValueChanged(attribute, value: value, oldValue: old) }
      return
    }
    if attribute === Self.outputBitSetClear {
      guard let value, let v = Self.outputBitSetClear.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if state.setOutputBitManipulations(v) {
        fireAttributeValueChanged(attribute, value: value, oldValue: old)
      }
      return
    }
    if attribute === Self.inputsSyncCapture {
      guard let value, let v = Self.inputsSyncCapture.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if state.setInputSynchronousCapture(v) {
        maybeNotifyListShape()
        fireAttributeValueChanged(attribute, value: value, oldValue: old)
      }
      return
    }
    if attribute === Self.captureType {
      guard let value, let v = Self.captureType.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if state.setInputCaptureEdge(v) { fireAttributeValueChanged(attribute, value: value, oldValue: old) }
      return
    }
    if attribute === Self.inputsCaptureBit {
      guard let value, let v = Self.inputsCaptureBit.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if state.setInputCaptureBitClearing(v) {
        fireAttributeValueChanged(attribute, value: value, oldValue: old)
      }
      return
    }
    if attribute === Self.genIrq {
      guard let value, let v = Self.genIrq.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if state.setIrqGeneration(v) {
        maybeNotifyListShape()
        fireAttributeValueChanged(attribute, value: value, oldValue: old)
      }
      return
    }
    if attribute === Self.irqType {
      guard let value, let v = Self.irqType.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if state.setIrqType(v) { fireAttributeValueChanged(attribute, value: value, oldValue: old) }
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
