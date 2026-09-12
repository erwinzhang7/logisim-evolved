// GatesHdlBindings: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution): the
// `StdAttr`, `GateAttributes`, `NegateAttribute`, `PlexersLibrary`, `BitSelector`,
// `BitExtender` and `Constant` attribute constants that the generators in
// `com/cburch/logisim/std/gates/`, `com/cburch/logisim/std/wiring/` and
// `com/cburch/logisim/std/plexers/` read. Copyright by the Logisim-evolution developers. This
// translation is a derivative work and is therefore licensed GPL-3.0-only. See LICENSE.md.
//
// ── Why the attributes are injected rather than named directly ───────────────────────────────
//
// Upstream's generators live in the same package as the components they describe, so
// `attrs.getValue(GateAttributes.ATTR_INPUTS)` is a plain static reference. Here they do not:
// `LogisimHdl` depends on `LogisimKernel` and `LogisimFile` only, and the attribute constants
// live in `LogisimStd`, which is meant to depend on *this* module for HDL generation. Naming
// them here would create a module cycle.
//
// So they arrive as data, exactly as `HdlParameters.swift` and `AbstractHdlGeneratorFactory.swift`
// already document for `widthAttribute` and the clock-trigger attributes. This struct is the
// single place that seam is spelled out, and whoever registers these generators fills it in once
// from the real `LogisimStd` constants.
//
// ── Identity matters, and only for some of them ──────────────────────────────────────────────
//
// `AnyAttribute`'s `==` is reference identity (D4), so an attribute handed to `HdlParameters` or
// `HdlPorts` at *construction* time must be the very object the component's `AttributeSet` uses.
// Those are the fields below. Everything a generator merely reads at *call* time is resolved by
// `.circ` name off the attribute set it was handed, which returns that set's own object and is
// therefore identity-correct by construction; see `attribute(named:)` in `AttributeSet`.
//
// The one place this differs from Java, harmlessly: upstream reads a negated input with
// `attrs.getValue(new NegateAttribute(index, null))`, and `GateAttributes.getValue` answers it
// through `attr instanceof NegateAttribute`, so it answers for *any* index, whether or not that
// input exists. Name lookup answers `nil` for an index past the input count, and this file maps
// that to `false`, which is the same answer Java computes (`(negated >> index) & 1` is 0 for any
// bit the gate does not have).

import LogisimKernel

/// The `LogisimStd` attribute constants the gates / wiring / plexers HDL generators need by
/// identity. Construct one and share it across every generator in these three families.
public struct GatesHdlBindings {

  /// `com.cburch.logisim.instance.StdAttr.WIDTH`.
  public let width: Attribute<BitWidth>

  /// `com.cburch.logisim.std.gates.GateAttributes.ATTR_INPUTS`.
  ///
  /// Needed by identity because `AbstractGateHdlGenerator`'s constructor hands it to
  /// `HdlParameters` as the input-count source for the bubble mask, before any attribute set
  /// exists to resolve it from.
  public let gateInputs: AnyAttribute

  /// `new NegateAttribute(index, null)`: upstream constructs one per query. Supply
  /// `NegateAttributes.attribute(index:side:)` with `side: nil`; the port interns those, so the
  /// object returned compares equal to the one the gate's own attribute set holds only when the
  /// sides match, which is why the generators read negation by name instead. This hook exists
  /// for callers that would rather bind it explicitly.
  public let negatedInput: ((Int) -> AnyAttribute)?

  /// `com.cburch.logisim.std.plexers.PlexersLibrary.ATTR_SELECT`.
  ///
  /// Needed by identity by `PriorityEncoderHdlGeneratorFactory`, whose constructor uses it as
  /// both a `MAP_POW2` and a `MAP_INT_ATTRIBUTE` parameter source.
  public let plexerSelect: Attribute<BitWidth>

  /// `com.cburch.logisim.std.plexers.BitSelector.GROUP_ATTR`.
  public let bitSelectorGroup: Attribute<BitWidth>

  /// `com.cburch.logisim.std.plexers.BitSelector.SELECT_ATTR`.
  ///
  /// `Attributes.forNoSave()` upstream, so its `getName()` is `null` and it cannot be found by
  /// name; injection is the only way to reach it.
  public let bitSelectorSelect: AnyAttribute

  /// `com.cburch.logisim.std.plexers.BitSelector.EXTENDED_ATTR`. Also `forNoSave()`.
  public let bitSelectorExtended: AnyAttribute

  public init(
    width: Attribute<BitWidth>,
    gateInputs: AnyAttribute,
    plexerSelect: Attribute<BitWidth>,
    bitSelectorGroup: Attribute<BitWidth>,
    bitSelectorSelect: AnyAttribute,
    bitSelectorExtended: AnyAttribute,
    negatedInput: ((Int) -> AnyAttribute)? = nil
  ) {
    self.width = width
    self.gateInputs = gateInputs
    self.plexerSelect = plexerSelect
    self.bitSelectorGroup = bitSelectorGroup
    self.bitSelectorSelect = bitSelectorSelect
    self.bitSelectorExtended = bitSelectorExtended
    self.negatedInput = negatedInput
  }
}

// MARK: - Name-resolved reads

/// The `.circ` attribute names these generators resolve at call time. Reading by name off the
/// attribute set the generator was handed returns that set's own attribute object, so identity
/// comparisons downstream still hold.
public enum GatesHdlAttributeNames {
  /// `StdAttr.WIDTH`.
  public static let width = "width"
  /// `GateAttributes.ATTR_INPUTS`.
  public static let gateInputs = "inputs"
  /// `GateAttributes.ATTR_XOR`; its `XOR_ONE` option's `.circ` token is `1`.
  public static let gateXor = "xor"
  public static let gateXorOneToken = "1"
  /// `GateAttributes.ATTR_OUTPUT`; its `OUTPUT_01` option's `.circ` token is `01`.
  public static let gateOutput = "out"
  public static let gateOutput01Token = "01"
  /// `new NegateAttribute(index, side)`, `"negate" + index`.
  public static func negate(_ index: Int) -> String { "negate\(index)" }
  /// `PlexersLibrary.ATTR_SELECT`.
  public static let plexerSelect = "select"
  /// `PlexersLibrary.ATTR_ENABLE`.
  public static let plexerEnable = "enable"
  /// `BitSelector.GROUP_ATTR`.
  public static let bitSelectorGroup = "group"
  /// `BitExtender.ATTR_TYPE`; tokens are `zero` / `one` / `sign` / `input`.
  public static let bitExtenderType = "type"
  /// `Constant.ATTR_VALUE`.
  public static let constantValue = "value"
}

extension AttributeSet {

  /// The width in bits of a `BitWidth`-valued attribute, by `.circ` name.
  ///
  /// Java writes `attrs.getValue(StdAttr.WIDTH).getWidth()` and would throw
  /// `NullPointerException` where the attribute is absent. Every component these generators
  /// serve declares it, so the fallback is unreachable in practice; it is `1` rather than a trap
  /// because a generator is not a place to abort the process (D13).
  func hdlBitWidth(named name: String, default fallback: Int = 1) -> Int {
    guard let attribute = attribute(named: name) else { return fallback }
    if case .bitWidth(let value)? = rawValue(attribute) { return Int(value) }
    return fallback
  }

  /// An integer-valued attribute by `.circ` name, accepting either of the storage forms an
  /// integer attribute can take.
  func hdlInteger(named name: String, default fallback: Int) -> Int {
    guard let attribute = attribute(named: name) else { return fallback }
    switch rawValue(attribute) {
    case .integer(let value): return Int(value)
    case .long(let value): return Int(truncatingIfNeeded: value)
    case .bitWidth(let value): return Int(value)
    default: return fallback
    }
  }

  /// A boolean-valued attribute by `.circ` name.
  func hdlBoolean(named name: String, default fallback: Bool) -> Bool {
    guard let attribute = attribute(named: name) else { return fallback }
    if case .boolean(let value)? = rawValue(attribute) { return value }
    return fallback
  }

  /// The `.circ` token of an `AttributeOption`-valued attribute, or `nil` when the attribute is
  /// absent, which is how `containsAttribute` questions are answered here.
  func hdlOptionToken(named name: String) -> String? {
    guard let attribute = attribute(named: name) else { return nil }
    guard case .option(let option)? = rawValue(attribute) else { return nil }
    return attribute.standardString(for: .option(option))
  }

  /// `attrs.getValue(new NegateAttribute(index, null))`; whether input `index` is inverted.
  func hdlInputIsNegated(_ index: Int) -> Bool {
    hdlBoolean(named: GatesHdlAttributeNames.negate(index), default: false)
  }
}
