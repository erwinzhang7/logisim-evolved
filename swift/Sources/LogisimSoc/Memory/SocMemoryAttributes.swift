// SocMemoryAttributes.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.memory.SocMemoryAttributes),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Unlike most `*Attributes` classes in this module, the *state* object (`SocMemoryState`) is
// the single source of truth for `START_ADDRESS`/`MEM_SIZE`/the bus selection/the label; this
// attribute set is a thin forwarding layer over it, exactly as Java's is. `SOCMEM_STATE` is the
// hidden, read-only, not-saved attribute that hands the live `SocMemoryState` to the factory
// (`SocMemory.getSlaveInterface`).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

/// `SocMemoryAttributes.SocMemoryStateAttribute`. `parse` always returns `nil` upstream too
/// (the value is never serialised; it is reconstructed via `copyInto`, not the `.circ` codec).
private func makeSocMemoryStateAttribute() -> Attribute<SocMemoryState> {
  Attribute(
    name: "SocMemoryState",
    isHidden: true,
    isToSave: false,
    codec: AttributeCodec(
      parse: { _ in SocMemoryState() },
      toStandardString: { _ in "" },
      encode: { state in .object(AttributeObjectBox(state as AnyObject)) },
      decode: { value in
        if case .object(let box) = value { return box.object as? SocMemoryState }
        return nil
      }))
}

/// `com.cburch.logisim.soc.memory.SocMemoryAttributes`.
public final class SocMemoryAttributes: AbstractAttributeSet {

  /// `START_ADDRESS`.
  public static let startAddress: Attribute<Int32> = Attributes.forHexInteger("StartAddress")
  /// `MEM_SIZE`, `Attributes.forBitWidth(name, disp, 10, 26)`.
  public static let memSize: Attribute<BitWidth> = Attributes.forBitWidth(
    "MemSize", min: 10, max: 26)
  /// `SOCMEM_STATE`.
  public static let socMemState: Attribute<SocMemoryState> = makeSocMemoryStateAttribute()

  private static let attributeList: [AnyAttribute] = [
    startAddress, memSize, StdAttr.label, StdAttr.labelFont, StdAttr.labelVisibility,
    SocSimulationManager.socBusSelect, socMemState,
  ]

  private var labelFontValue: FontSpec = StdAttr.defaultLabelFont
  private var labelVisibleValue = true
  // `SocMemoryState()`'s own default (1024 bytes) already matches `BitWidth.known(10)`, so no
  // custom initializer is needed to keep `memState`/`memSizeValue` in sync at construction.
  private var memState = SocMemoryState()
  private var memSizeValue = BitWidth.known(10)

  public override var attributes: [AnyAttribute] { Self.attributeList }

  public override func makeCopyInstance() -> AbstractAttributeSet { SocMemoryAttributes() }

  public override func copyInto(_ destination: AbstractAttributeSet) {
    guard let d = destination as? SocMemoryAttributes else { return }
    d.labelFontValue = labelFontValue
    d.labelVisibleValue = labelVisibleValue
    d.memSizeValue = memSizeValue
    d.memState = SocMemoryState()
    _ = d.memState.setSize(memSizeValue)
    _ = d.memState.setStartAddress(memState.startAddress)
    d.memState.socBusInfo.busId = memState.socBusInfo.busId
    _ = d.memState.setLabel(memState.label)
  }

  public override func isReadOnly(_ attribute: AnyAttribute) -> Bool {
    attribute === Self.socMemState
  }

  public override func isToSave(_ attribute: AnyAttribute) -> Bool {
    attribute.isToSave && attribute !== Self.socMemState
  }

  public override func rawValue(_ attribute: AnyAttribute) -> AttributeValue? {
    if attribute === Self.startAddress { return Self.startAddress.encode(memState.startAddress) }
    if attribute === Self.memSize { return Self.memSize.encode(memSizeValue) }
    if attribute === StdAttr.label { return StdAttr.label.encode(memState.label) }
    if attribute === StdAttr.labelFont { return StdAttr.labelFont.encode(labelFontValue) }
    if attribute === StdAttr.labelVisibility {
      return StdAttr.labelVisibility.encode(labelVisibleValue)
    }
    if attribute === SocSimulationManager.socBusSelect {
      return SocSimulationManager.socBusSelect.encode(memState.socBusInfo)
    }
    if attribute === Self.socMemState { return Self.socMemState.encode(memState) }
    return nil
  }

  public override func setRawValue(_ attribute: AnyAttribute, _ value: AttributeValue?) throws {
    func fail() -> Error {
      ComponentError.unsupportedAttributeValue(factory: "SocMemory", attribute: attribute.name)
    }
    if attribute === Self.startAddress {
      guard let value, let addr = Self.startAddress.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if memState.setStartAddress(addr) {
        fireAttributeValueChanged(attribute, value: value, oldValue: old)
      }
      return
    }
    if attribute === Self.memSize {
      guard let value, let width = Self.memSize.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if memState.setSize(width) {
        memSizeValue = width
        fireAttributeValueChanged(attribute, value: value, oldValue: old)
      }
      return
    }
    if attribute === StdAttr.label {
      guard let value, let label = StdAttr.label.decode(value) else { throw fail() }
      let old = rawValue(attribute)
      if memState.setLabel(label) {
        fireAttributeValueChanged(attribute, value: value, oldValue: old)
      }
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
      if memState.setSocBusInfo(info) {
        fireAttributeValueChanged(attribute, value: value, oldValue: old)
      }
      return
    }
  }
}
