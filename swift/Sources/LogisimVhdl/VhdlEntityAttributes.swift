// VhdlEntityAttributes: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/logisim/vhdl/base/VhdlEntityAttributes.java. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore licensed
// GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Why the attribute identities here are local, not shared `StdAttr` instances ──────────
//
// Java's static attribute list is `{VhdlEntity.nameAttr, StdAttr.LABEL, StdAttr.LABEL_FONT,
// StdAttr.LABEL_VISIBILITY, StdAttr.FACING, StdAttr.APPEARANCE, VhdlSimConstants.SIM_NAME_ATTR}`
// : five of those seven come from `LogisimFile`'s `StdAttr`, a module this task does not own.
// `Attribute<V>` identity in `LogisimKernel` is *object* identity (D4-adjacent, see
// `Attributes.swift`'s `AnyAttribute: Hashable`), but the `.circ` codec matches attributes by
// *name string*, not identity (`AbstractAttributeSet.attribute(named:)`), so declaring our own
// `Attribute<V>` instances with the exact same name strings Java's `StdAttr` uses
// (`"label"`, `"labelfont"`, `"labelvisible"`, `"facing"`, `"appearance"`) round-trips
// identically once this is wired into the real file codec, no shared instance is required for
// correctness, only for the two modules' UI code to compare `attrs.getValue(FOO) ===
// StdAttr.FOO` directly, which is exactly the kind of cross-module wiring this task's
// boundary defers.
//
// `VhdlSimConstants.SIM_NAME_ATTR` (`"vhdlSimName"`) is reproduced directly below rather than
// imported from `vhdl/sim`, which this task skips per its instructions (the QuestaSim/ModelSim
// bridge, D11); the attribute itself is inert data (a string the co-simulator would have
// looked at), not simulation code.
//
// ── Why generics are a struct wrapper, not a subclass ─────────────────────────────────────
//
// Java's `VhdlGenericAttribute extends Attribute<Integer>`, carrying `start`/`end`/the
// `Generic` alongside the usual name/codec. `LogisimKernel`'s `Attribute<V>` is `final` (D5
// deliberately made it a sealed carrier for an `AttributeCodec<V>`, not a base class), so this
// port captures `start`/`end`/`generic` in the codec's closures instead and exposes them
// separately on `VhdlGenericAttribute`, a plain struct pairing the `Attribute<Int32?>` with
// the metadata Java stored as subclass fields. Callers that only need to read or write the
// value go through `.attribute`; callers that need the bounds or the originating `Generic`
// (Java's `getGeneric()`, used by the cell editor, dropped per D9, and nothing else
// upstream) read the struct directly.
//
// The value type is `Int32?`, matching Java's `Integer` exactly: `null` means "no override
// recorded, use the generic's own default" (see `VhdlContent.setContent`'s note on how a
// generic's default can go stale) and is spelled `.opaque("default")` at the `AttributeValue`
// storage layer, since the closed `AttributeValue` enum (D5) has no "absent" case of its own
// and this attribute's `.circ` round-trip belongs to the file-codec integration this task does
// not do. `Attribute<V>.toStandardString` would NPE on `null` in Java (the override here is
// only for `toDisplayString`, not `toStandardString`: a real gap in the Java, unreachable in
// practice because nothing serialises a null-valued attribute); the port returns `""` instead
// of crashing.

import Foundation
import LogisimKernel

// MARK: - Generic attribute wrapper

/// See the file header. Pairs an `Attribute<Int32?>` with the range/generic metadata Java
/// stored on the (here, impossible) `Attribute` subclass.
public struct VhdlGenericAttribute {
  public let attribute: Attribute<Int32?>
  public let generic: VhdlContent.Generic
  public let minimum: Int32
  public let maximum: Int32
}

// MARK: - VhdlEntityAttributes

/// `com.cburch.logisim.vhdl.base.VhdlEntityAttributes`.
public final class VhdlEntityAttributes: AbstractAttributeSet {

  // MARK: Shared attribute identities (see file header)

  /// `VhdlEntity.nameAttr`.
  public static let nameAttribute: Attribute<String> = Attributes.forString("vhdlEntity")
  /// `StdAttr.LABEL`.
  public static let labelAttribute: Attribute<String> = Attributes.forString("label")
  /// `StdAttr.LABEL_FONT`.
  public static let labelFontAttribute: Attribute<FontSpec> = Attributes.forFont("labelfont")
  /// `StdAttr.DEFAULT_LABEL_FONT` (`new Font("SansSerif", Font.BOLD, 16)`).
  public static let defaultLabelFont = FontSpec(family: "SansSerif", style: .bold, size: 16)
  /// `StdAttr.LABEL_VISIBILITY`.
  public static let labelVisibilityAttribute: Attribute<Bool> = Attributes.forBoolean("labelvisible")
  /// `StdAttr.FACING`.
  public static let facingAttribute: Attribute<Direction> = Attributes.forDirection("facing")
  /// `StdAttr.APPEARANCE`.
  public static let appearanceAttribute: Attribute<AttributeOption> =
    Attributes.forOption("appearance", choices: VhdlAppearanceStyle.all)
  /// `VhdlSimConstants.SIM_NAME_ATTR`. Hidden, like Java's `VhdlSimNameAttribute.isHidden()`;
  /// excluded from saving by `isToSave(_:)` below, exactly as Java's override does.
  ///
  /// This is the *same instance* as `VhdlSimConstants.simNameAttribute`, not a second one with
  /// the same name; `AbstractAttributeSet`'s dispatch below is by object identity (`===`), so
  /// a duplicate declaration would make `attrs.getValue(VhdlSimConstants.simNameAttribute)`
  /// silently return nil. Kept as an alias rather than moved outright because
  /// `VhdlEntityAttributes.simNameAttribute` is the spelling the rest of this module and its
  /// tests already use.
  public static let simNameAttribute: Attribute<String> = VhdlSimConstants.simNameAttribute

  private static let fixedAttributes: [AnyAttribute] = [
    nameAttribute, labelAttribute, labelFontAttribute, labelVisibilityAttribute,
    facingAttribute, appearanceAttribute, simNameAttribute,
  ]

  /// `VhdlEntityAttributes.forGeneric(Generic)`.
  public static func makeGenericAttribute(for generic: VhdlContent.Generic) -> VhdlGenericAttribute {
    let (lo, hi): (Int32, Int32)
    switch generic.type {
    case "positive": (lo, hi) = (1, Int32.max)
    case "natural": (lo, hi) = (0, Int32.max)
    default: (lo, hi) = (Int32.min, Int32.max)
    }
    let attribute = Attribute<Int32?>(
      name: "vhdl_" + generic.name,
      codec: AttributeCodec<Int32?>(
        parse: { text in try Self.parseGenericValue(text, minimum: lo, maximum: hi, generic: generic) },
        toStandardString: { $0.map(String.init) ?? "" },
        encode: { $0.map(AttributeValue.integer) ?? .opaque("default") },
        decode: { value in
          switch value {
          case .integer(let v): return .some(.some(v))
          case .opaque("default"): return .some(.none)
          default: return nil
          }
        }))
    return VhdlGenericAttribute(attribute: attribute, generic: generic, minimum: lo, maximum: hi)
  }

  /// `VhdlGenericAttribute.parse(String)`.
  private static func parseGenericValue(
    _ text: String, minimum: Int32, maximum: Int32, generic: VhdlContent.Generic
  ) throws -> Int32? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let defaultDisplay = "(default) \(generic.defaultValue)"
    if trimmed.isEmpty || trimmed == "default" || trimmed == "(default)" || trimmed == defaultDisplay {
      return nil
    }
    guard let wide = Int64(trimmed) else {
      throw AttributeParseError.numberFormat("For input string: \"\(trimmed)\"")
    }
    if wide < Int64(minimum) {
      throw AttributeParseError.numberFormat("integer must be at least \(minimum)")
    }
    if wide > Int64(maximum) {
      throw AttributeParseError.numberFormat("integer must be at most \(maximum)")
    }
    return Int32(truncatingIfNeeded: wide)
  }

  /// `VhdlEntityAttributes.createBaseAttrs(VhdlContent)`: the shared prototype attribute set
  /// (`VhdlContent.staticAttributes`), distinct from a placed instance's own
  /// `VhdlEntityAttributes` below.
  public static func makeBaseAttributes(for content: VhdlContent) -> any AttributeSet {
    var bindings: [AttributeBinding] = [
      nameAttribute.binding(content.name),
      labelAttribute.binding(""),
      labelFontAttribute.binding(defaultLabelFont),
      labelVisibilityAttribute.binding(false),
      facingAttribute.binding(.east),
      appearanceAttribute.binding(VhdlAppearanceStyle.evolution),
      simNameAttribute.binding(""),
    ]
    for (generic, genericAttribute) in zip(content.generics, content.genericAttributes) {
      // `genericAttribute.attribute` is `Attribute<Int32?>`, so `.binding(_:)` wants an
      // `Int32??`; wrap explicitly to `Int32?` first rather than lean on double implicit
      // optional promotion.
      let initialValue: Int32? = generic.defaultValue
      bindings.append(genericAttribute.attribute.binding(initialValue))
    }
    return AttributeSets.fixedSet(bindings)
  }

  // MARK: Instance state

  private var content: VhdlContent
  private var label = ""
  private var simName = ""
  private var labelFont = VhdlEntityAttributes.defaultLabelFont
  private var facing = Direction.east
  private var labelVisible = false
  private var genericValues: [ObjectIdentifier: Int32?] = [:]
  private var instanceAttributes: [AnyAttribute] = []

  public init(content: VhdlContent) {
    self.content = content
    super.init()
    updateGenerics()
  }

  /// `VhdlEntityAttributes.getContent()`.
  public var vhdlContent: VhdlContent { content }

  /// `VhdlEntityAttributes.getFacing()`.
  public var currentFacing: Direction { facing }

  /// `VhdlEntityAttributes.updateGenerics()`. Called after the backing `VhdlContent`
  /// re-parses (a new/renamed/retyped generic list) to refresh the instance attribute list
  /// and drop any stored override for a generic that no longer exists.
  public func updateGenerics() {
    var attrs = Self.fixedAttributes
    attrs.append(contentsOf: content.genericAttributes.map { $0.attribute as AnyAttribute })
    instanceAttributes = attrs

    let stillValid = Set(content.genericAttributes.map { ObjectIdentifier($0.attribute) })
    genericValues = genericValues.filter { stillValid.contains($0.key) }
    fireAttributeListChanged()
  }

  // MARK: AbstractAttributeSet

  public override var attributes: [AnyAttribute] { instanceAttributes }

  public override func makeCopyInstance() -> AbstractAttributeSet {
    VhdlEntityAttributes(content: content)
  }

  public override func copyInto(_ destination: AbstractAttributeSet) {
    guard let destination = destination as? VhdlEntityAttributes else {
      preconditionFailure("VhdlEntityAttributes can only copy into a VhdlEntityAttributes")
    }
    // Java: `attr.content = content; // .clone();`; the comment is upstream's, marking that
    // sharing rather than cloning the content is deliberate (or at least deliberately left
    // alone). `label` is likewise left at the destination's own default, matching Java's
    // `// attr.label = unchanged;`.
    destination.content = content
    destination.labelFont = labelFont
    destination.labelVisible = labelVisible
    destination.facing = facing
    destination.instanceAttributes = instanceAttributes
    destination.genericValues = genericValues
  }

  public override func rawValue(_ attribute: AnyAttribute) -> AttributeValue? {
    if attribute === Self.nameAttribute { return .string(content.name) }
    if attribute === Self.labelAttribute { return .string(label) }
    if attribute === Self.labelFontAttribute { return .font(labelFont) }
    if attribute === Self.labelVisibilityAttribute { return .boolean(labelVisible) }
    if attribute === Self.appearanceAttribute { return .option(content.appearance) }
    if attribute === Self.facingAttribute { return .direction(facing.attributeDirection) }
    if attribute === Self.simNameAttribute { return .string(simName) }
    guard let stored = genericValues[ObjectIdentifier(attribute)] else { return nil }
    if let value = stored { return .integer(value) }
    return .opaque("default")
  }

  public override func setRawValue(_ attribute: AnyAttribute, _ value: AttributeValue?) throws {
    if attribute === Self.nameAttribute {
      guard case .string(let newName)? = value, content.name != newName else { return }
      guard content.setName(newName) else { return }
      fireAttributeValueChanged(attribute, value: value, oldValue: nil)
      return
    }
    if attribute === Self.labelAttribute {
      guard case .string(let newLabel)? = value, label != newLabel else { return }
      let old = label
      label = newLabel
      fireAttributeValueChanged(attribute, value: value, oldValue: .string(old))
      return
    }
    if attribute === Self.labelFontAttribute {
      guard case .font(let newFont)? = value, labelFont != newFont else { return }
      labelFont = newFont
      fireAttributeValueChanged(attribute, value: value, oldValue: nil)
      return
    }
    if attribute === Self.labelVisibilityAttribute {
      guard case .boolean(let newVisibility)? = value, labelVisible != newVisibility else { return }
      labelVisible = newVisibility
      fireAttributeValueChanged(attribute, value: value, oldValue: nil)
      return
    }
    if attribute === Self.facingAttribute {
      guard case .direction(let raw)? = value, let newFacing = Direction(attributeDirection: raw),
        facing != newFacing
      else { return }
      facing = newFacing
      fireAttributeValueChanged(attribute, value: value, oldValue: nil)
      return
    }
    if attribute === Self.simNameAttribute {
      guard case .string(let newName)? = value, simName != newName else { return }
      simName = newName
      fireAttributeValueChanged(attribute, value: value, oldValue: nil)
      return
    }
    if attribute === Self.appearanceAttribute {
      guard case .option(let option)? = value, VhdlAppearanceStyle.all.contains(option),
        content.appearance != option
      else { return }
      content.setAppearance(option)
      fireAttributeValueChanged(attribute, value: value, oldValue: nil)
      return
    }

    // Any other attribute is treated as a generic override, Java's unconditional final
    // fallthrough (`if (genericValues != null) { genericValues.put(...); fire...; }`, with no
    // identity check of its own, every attribute not matched above is assumed to be one of
    // this instance's own generic attributes).
    let key = ObjectIdentifier(attribute)
    let newValue: Int32? = { if case .integer(let v)? = value { return v }; return nil }()
    // `genericValues`'s Value type is itself `Int32?`, so the subscript setter's "assigning
    // nil removes the key" special case would silently collapse "explicitly reset to the
    // generic's default" (a present key mapped to `nil`) into "never touched" (an absent
    // key); exactly the distinction `rawValue(_:)` below depends on to tell `.opaque
    // ("default")` apart from "no stored value at all". `updateValue(_:forKey:)` always
    // stores, never removes.
    genericValues.updateValue(newValue, forKey: key)
    fireAttributeValueChanged(attribute, value: value, oldValue: nil)
  }

  /// `VhdlEntityAttributes.isToSave(Attribute<?>)`: everything the attribute itself marks
  /// saveable, except the (hidden, co-simulation-only) sim-name attribute.
  public override func isToSave(_ attribute: AnyAttribute) -> Bool {
    attribute.isToSave && attribute !== Self.simNameAttribute
  }
}
