// SocBusAttributes.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.bus.SocBusAttributes),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── `SOC_BUS_ID`'s lazily-generated default ─────────────────────────────────────────────────────
//
// Java generates a fresh id on first read (`getValue`) by formatting
// `"0x%016X" + Date.getTime() + <hash suffix of this.toString()>`: i.e. a timestamp plus the
// tail of `Object.toString()`'s `ClassName@hexHashCode`. Swift has no equivalent default
// `toString`, so the port substitutes `ObjectIdentifier(self)`'s hash for the hash-code suffix.
// This is deliberately *not* byte-for-byte with what the Java JVM would have produced: the id is
// an internal routing key that only needs to be unique within one running program (it is never
// compared across a Java run and a Swift run), and it round-trips exactly like any other string
// once written to a `.circ` file: a bus id a *Java* session generated and saved loads back into
// Swift unchanged, because parsing just takes the string as-is.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

/// `SocBusAttributes.SocBusIdAttribute`.
///
/// Identity-preserving for the same reason `SOC_BUS_SELECT` is; see the long note on
/// `makeSocBusSelectAttribute` in `Data/SocSimulationManager.swift`. Here the consequence was
/// that `registerComponent`'s `getValue(SOC_BUS_ID).setSocSimulationManager(this, c)` attached
/// the manager to a throwaway, so the *bus's own* `SocBusInfo` never learned which component it
/// belonged to.
private func makeSocBusIdAttribute() -> Attribute<SocBusInfo> {
  Attribute(
    name: "SocBusIdentifier",
    isHidden: true,
    codec: AttributeCodec(
      parse: { SocBusInfo($0) },
      toStandardString: { $0.busId },
      encode: { .object(AttributeObjectBox($0)) },
      decode: { value in
        switch value {
        case .object(let box): return box.object as? SocBusInfo
        case .string(let id): return SocBusInfo(id)
        default: return nil
        }
      }))
}

/// `com.cburch.logisim.soc.bus.SocBusAttributes`.
public final class SocBusAttributes: AbstractAttributeSet {

  /// `NrOfTracesAttr`.
  public static let nrOfTraces: Attribute<BitWidth> = Attributes.forBitWidth("TraceSize")
  /// `SOC_BUS_ID`. See file header for the lazy-default note.
  public static let socBusId: Attribute<SocBusInfo> = makeSocBusIdAttribute()
  /// `SOC_TRACE_VISIBLE`.
  public static let traceVisible: Attribute<Bool> = Attributes.forBoolean("TraceVisible")

  private static let attributeList: [AnyAttribute] = [
    nrOfTraces, traceVisible, StdAttr.label, StdAttr.labelFont, StdAttr.labelVisibility, socBusId,
  ]

  private var labelFontValue: FontSpec = StdAttr.defaultLabelFont
  private var labelVisibleValue = true
  private var traceSizeValue = BitWidth.known(5)
  private var labelValue = ""
  private var idValue = SocBusInfo(nil)
  private var traceVisibleValue = true

  public override var attributes: [AnyAttribute] { Self.attributeList }

  public override func makeCopyInstance() -> AbstractAttributeSet { SocBusAttributes() }

  public override func copyInto(_ destination: AbstractAttributeSet) {
    guard let d = destination as? SocBusAttributes else { return }
    d.labelFontValue = labelFontValue
    d.labelVisibleValue = labelVisibleValue
    d.traceSizeValue = traceSizeValue
    d.labelValue = labelValue
    d.traceVisibleValue = traceVisibleValue
    d.idValue = SocBusInfo(nil)
  }

  public override func isReadOnly(_ attribute: AnyAttribute) -> Bool {
    attribute === Self.socBusId
  }

  public override func rawValue(_ attribute: AnyAttribute) -> AttributeValue? {
    if attribute === Self.nrOfTraces { return Self.nrOfTraces.encode(traceSizeValue) }
    if attribute === StdAttr.label { return StdAttr.label.encode(labelValue) }
    if attribute === StdAttr.labelFont { return StdAttr.labelFont.encode(labelFontValue) }
    if attribute === StdAttr.labelVisibility {
      return StdAttr.labelVisibility.encode(labelVisibleValue)
    }
    if attribute === Self.socBusId {
      if idValue.busId.isEmpty {
        let stamp = Int64(Date().timeIntervalSince1970 * 1000)
        let suffix = UInt32(bitPattern: Int32(truncatingIfNeeded: ObjectIdentifier(self).hashValue))
        idValue.busId = String(format: "0x%016X%08X", stamp, suffix)
      }
      return Self.socBusId.encode(idValue)
    }
    if attribute === Self.traceVisible { return Self.traceVisible.encode(traceVisibleValue) }
    return nil
  }

  public override func setRawValue(_ attribute: AnyAttribute, _ value: AttributeValue?) throws {
    if attribute === Self.nrOfTraces {
      guard let value, let width = Self.nrOfTraces.decode(value) else {
        throw ComponentError.unsupportedAttributeValue(
          factory: "SocBus", attribute: attribute.name)
      }
      if traceSizeValue != width {
        let old = rawValue(attribute)
        traceSizeValue = width
        fireAttributeValueChanged(attribute, value: value, oldValue: old)
      }
      return
    }
    if attribute === StdAttr.label {
      guard let value, let label = StdAttr.label.decode(value) else {
        throw ComponentError.unsupportedAttributeValue(
          factory: "SocBus", attribute: attribute.name)
      }
      if labelValue != label {
        let old = rawValue(attribute)
        labelValue = label
        fireAttributeValueChanged(attribute, value: value, oldValue: old)
      }
      return
    }
    if attribute === StdAttr.labelFont {
      guard let value, let font = StdAttr.labelFont.decode(value) else {
        throw ComponentError.unsupportedAttributeValue(
          factory: "SocBus", attribute: attribute.name)
      }
      if labelFontValue != font {
        let old = rawValue(attribute)
        labelFontValue = font
        fireAttributeValueChanged(attribute, value: value, oldValue: old)
      }
      return
    }
    if attribute === StdAttr.labelVisibility {
      guard let value, let visible = StdAttr.labelVisibility.decode(value) else {
        throw ComponentError.unsupportedAttributeValue(
          factory: "SocBus", attribute: attribute.name)
      }
      // Bug-for-bug (`SocBusAttributes.java:117`): Java's condition is inverted,
      // `if (labelVisible.equals(v))`, so the stored flag only ever changes (and fires) when
      // the *new* value equals the *old* one, which means `LABEL_VISIBILITY` on a `SocBus`
      // never actually flips via `setValue`. Preserved.
      if labelVisibleValue == visible {
        let old = rawValue(attribute)
        labelVisibleValue = visible
        fireAttributeValueChanged(attribute, value: value, oldValue: old)
      }
      return
    }
    if attribute === Self.socBusId {
      guard let value, let info = Self.socBusId.decode(value) else {
        throw ComponentError.unsupportedAttributeValue(
          factory: "SocBus", attribute: attribute.name)
      }
      idValue.busId = info.busId
      return
    }
    if attribute === Self.traceVisible {
      guard let value, let visible = Self.traceVisible.decode(value) else {
        throw ComponentError.unsupportedAttributeValue(
          factory: "SocBus", attribute: attribute.name)
      }
      // Bug-for-bug, same inversion as `LABEL_VISIBILITY` above (`SocBusAttributes.java:129`).
      if traceVisibleValue == visible {
        let old = rawValue(attribute)
        traceVisibleValue = visible
        fireAttributeValueChanged(attribute, value: value, oldValue: old)
      }
      return
    }
  }
}
