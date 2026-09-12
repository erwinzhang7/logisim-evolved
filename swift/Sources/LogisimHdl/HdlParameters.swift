// HdlParameters: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/fpga/hdlgenerator/HdlParameters.java`. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore licensed GPL-3.0-only.
// See LICENSE.md.
//
// The generic-parameter (VHDL `generic`/Verilog `parameter`) list a generator declares: each
// entry maps a component attribute (or a fixed constant, or a combination of several
// attributes) to a value baked into the generated HDL at instantiation time.
//
// ── Adaptations from the Java shape ──────────────────────────────────────────────────────────
//
// 1. **Type-erased attribute reads go through `AttributeValue`, not `instanceof`.** Java reads
//    `attrs.getValue(attr)` as `Object` and dispatches on `instanceof Integer/Long/BitWidth/
//    AttributeOption`. Swift's `Attribute<V>` is statically typed and this code does not know
//    `V` for an arbitrary `AnyAttribute`, but `AttributeSet.rawValue(_:) -> AttributeValue?`
//    (D5) already carries exactly that discrimination in its storage-level enum, so switching
//    on it is a direct, faithful translation of the Java `instanceof` chain.
//
// 2. **One shared `widthAttribute` per `HdlParameters` instance, not `StdAttr.WIDTH` baked
//    into every `ParameterInfo`.** Every Java constructor path that does not take an explicit
//    `checkAttr` hardcodes `StdAttr.WIDTH`: literally the same static field every time, since
//    `Attribute` identity matters (D4). `StdAttr` belongs to a module this task does not touch,
//    so the shared attribute is supplied once, at construction, by whichever component
//    generator builds this `HdlParameters` (`LogisimStd`, later), and it must be *the same
//    object* that generator's own `AttributeSet` uses for width, or `containsAttribute`
//    comparisons (reference identity, D4) will silently fail.
//
// 3. **`MAP_GATE_INPUT_BUBLE` takes its input-count attribute and per-bit inversion query
//    explicitly, instead of hardcoding `GateAttributes.ATTR_INPUTS`/`NegateAttribute`.** Those
//    types belong to `LogisimStd`, which is meant to *depend on* this module for HDL
//    generation; hardcoding a reference back to them here would create a module cycle. The
//    bitmask algorithm itself (including the VHDL/Verilog bit-order swap) is unchanged.
//
// 4. **The nine `MAP_*` integer constants collapse into one `HdlParameterKind` enum** with a
//    case per distinct value-computation formula (several Java constants shared one formula,
//    `MAP_DEFAULT`, `MAP_OFFSET` and the constant-multiplier form of `MAP_MULTIPLY` are all
//    `width * multiplier + offset` with two of the three factors pinned to identity, so the
//    consolidation changes no computed value, only how it is spelled).

import LogisimKernel
#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// A per-bit inversion query for `HdlParameterKind.gateInputBubbleMask`: the Swift stand-in
/// for constructing a Java `NegateAttribute(index, null)` and reading it off `attrs`.
public typealias HdlGateInputInversionQuery = (_ attrs: any AttributeSet, _ index: Int) -> Bool

/// How a generic parameter's value is computed from the component's attributes. See the file
/// header for how this maps onto Java's `MAP_*` constants.
public enum HdlParameterKind {
  /// `MAP_DEFAULT` / `MAP_OFFSET` / `MAP_MULTIPLY`'s single-constant form:
  /// `width(attributeToCheckForBus) * multiplier + offset`.
  case widthFormula(multiplier: Int64 = 1, offset: Int64 = 0)
  /// `MAP_CONSTANT`.
  case constant(Int64)
  /// `MAP_ATTRIBUTE_OPTION`.
  case attributeOption(AnyAttribute, [AttributeOption: Int64])
  /// `MAP_MULTIPLY`'s attribute-list form: the product of every listed attribute's value.
  case productOfAttributes([AnyAttribute])
  /// `MAP_LN2`: `ceil(log2(sum of attributes)) + offset`. `offset` feeds only the value
  /// formula here (unlike `.power2`, where it instead widens the generated vector).
  case log2(attributes: [AnyAttribute], offset: Int64)
  /// `MAP_POW2`: `2 ^ (sum of attributes)`. `offset`, if positive, is *not* part of this
  /// formula: Java only consults it in `getNumberOfVectorBits`, a quirk preserved here.
  case power2(attributes: [AnyAttribute], offset: Int64)
  /// `MAP_INT_ATTRIBUTE`: `value(attribute) + offset`.
  case intAttribute(AnyAttribute, offset: Int64)
  /// `MAP_GATE_INPUT_BUBLE`. See the file header for why this takes its dependencies
  /// explicitly rather than reaching into `LogisimStd`.
  case gateInputBubbleMask(inputsAttribute: AnyAttribute, isInverted: HdlGateInputInversionQuery)
}

/// `com.cburch.logisim.fpga.hdlgenerator.HdlParameters`.
public final class HdlParameters {
  private struct ParameterInfo {
    let isOnlyUsedForBusses: Bool
    var isIntParameter = true
    let parameterName: String
    let parameterId: Int
    let kind: HdlParameterKind
    let attributeToCheckForBus: Attribute<BitWidth>
  }

  private var parameters: [ParameterInfo] = []
  private let widthAttribute: Attribute<BitWidth>

  /// `widthAttribute` plays the role Java hardcodes as `StdAttr.WIDTH`: the attribute
  /// `add`/`addBusOnly` (no explicit `checkAttr`) consult. Pass the *same* `Attribute<BitWidth>`
  /// instance the owning component's `AttributeSet` uses for its width (D4: attribute identity
  /// matters).
  public init(widthAttribute: Attribute<BitWidth>) {
    self.widthAttribute = widthAttribute
  }

  // MARK: - Declaring parameters

  /// `HdlParameters.add(String, int)`: the map-value is `width(widthAttribute)`.
  @discardableResult
  public func add(_ name: String, _ id: Int) -> HdlParameters {
    parameters.append(
      ParameterInfo(
        isOnlyUsedForBusses: false, parameterName: name, parameterId: id,
        kind: .widthFormula(), attributeToCheckForBus: widthAttribute))
    return self
  }

  /// `HdlParameters.add(String, int, int, Object...)`.
  @discardableResult
  public func add(_ name: String, _ id: Int, kind: HdlParameterKind) -> HdlParameters {
    parameters.append(
      ParameterInfo(
        isOnlyUsedForBusses: false, parameterName: name, parameterId: id, kind: kind,
        attributeToCheckForBus: widthAttribute))
    return self
  }

  /// `HdlParameters.addVector(String, int, int, Object...)`: represented as a
  /// `std_logic_vector`/sized literal rather than a plain integer generic.
  @discardableResult
  public func addVector(_ name: String, _ id: Int, kind: HdlParameterKind) -> HdlParameters {
    var info = ParameterInfo(
      isOnlyUsedForBusses: false, parameterName: name, parameterId: id, kind: kind,
      attributeToCheckForBus: widthAttribute)
    info.isIntParameter = false
    parameters.append(info)
    return self
  }

  /// `HdlParameters.addBusOnly(String, int)`: only present when `width(widthAttribute) > 1`.
  @discardableResult
  public func addBusOnly(_ name: String, _ id: Int) -> HdlParameters {
    parameters.append(
      ParameterInfo(
        isOnlyUsedForBusses: true, parameterName: name, parameterId: id, kind: .widthFormula(),
        attributeToCheckForBus: widthAttribute))
    return self
  }

  /// `HdlParameters.addBusOnly(Attribute<BitWidth>, String, int)`: only present when
  /// `width(checkAttr) > 1`.
  @discardableResult
  public func addBusOnly(_ checkAttr: Attribute<BitWidth>, _ name: String, _ id: Int)
    -> HdlParameters
  {
    parameters.append(
      ParameterInfo(
        isOnlyUsedForBusses: true, parameterName: name, parameterId: id, kind: .widthFormula(),
        attributeToCheckForBus: checkAttr))
    return self
  }

  // MARK: - Queries

  public func containsKey(_ id: Int, attrs: any AttributeSet) -> Bool {
    parameters.contains { id == parameterId(for: $0, attrs: attrs) }
  }

  public func get(_ id: Int, attrs: any AttributeSet) -> String? {
    for parameter in parameters where id == parameterId(for: parameter, attrs: attrs) {
      return parameterString(for: parameter, attrs: attrs)
    }
    return nil
  }

  /// A caller asking for a parameter id this `HdlParameters` never declared is a
  /// construction-time bug in the generator, not something a `.circ` file reaches: traps
  /// (D13).
  public func getNumberOfVectorBits(_ id: Int, attrs: any AttributeSet) throws -> Int {
    for parameter in parameters where id == parameterId(for: parameter, attrs: attrs) {
      return try numberOfVectorBits(for: parameter, attrs: attrs)
    }
    throw HdlParameterError.parameterNotFound
  }

  public func isPresentedByInteger(_ id: Int, attrs: any AttributeSet) -> Bool {
    for parameter in parameters where id == parameterId(for: parameter, attrs: attrs) {
      return parameter.isIntParameter
    }
    return true
  }

  public func getMaps(_ attrs: any AttributeSet) throws -> [String: String] {
    var contents: [String: String] = [:]
    for parameter in parameters where isUsed(parameter, attrs: attrs) {
      let value = try parameterValue(for: parameter, attrs: attrs)
      if !value.isEmpty { contents[parameter.parameterName] = value }
    }
    return contents
  }

  public func isEmpty(_ attrs: any AttributeSet) -> Bool {
    !parameters.contains { isUsed($0, attrs: attrs) }
  }

  public func keySet(_ attrs: any AttributeSet) -> [Int] {
    parameters.filter { isUsed($0, attrs: attrs) }.map(\.parameterId)
  }

  public func containsKey(_ id: Int) -> Bool {
    parameters.contains { $0.parameterId == id }
  }

  // MARK: - Per-parameter computation

  private func isUsed(_ parameter: ParameterInfo, attrs: any AttributeSet) -> Bool {
    let nrOfBits =
      attrs.containsAttribute(parameter.attributeToCheckForBus)
      ? (attrs.getValue(parameter.attributeToCheckForBus)?.width ?? 0) : 0
    return !parameter.isOnlyUsedForBusses || nrOfBits > 1
  }

  private func parameterId(for parameter: ParameterInfo, attrs: any AttributeSet) -> Int {
    isUsed(parameter, attrs: attrs) ? parameter.parameterId : 0
  }

  private func parameterString(for parameter: ParameterInfo, attrs: any AttributeSet) -> String? {
    isUsed(parameter, attrs: attrs) ? parameter.parameterName : nil
  }

  /// `ParameterInfo.getParameterValue(AttributeSet)`.
  ///
  /// Every `throw` below mirrors an `UnsupportedOperationException` upstream
  /// (`HdlParameters.java:159-229`) raised when a `HdlParameters` declaration does not match the
  /// attribute set it is handed.
  ///
  /// These used to trap, on the reasoning that a mismatch is a generator-authoring bug no
  /// `.circ` file can reach. **That reasoning was wrong, and the framework itself disproves
  /// it:** `AbstractHdlGeneratorFactory.getComponentMap` has a `componentInfo == nil` branch
  /// that calls `getMaps(AttributeSets.empty)`. An empty attribute set contains nothing, so
  /// *every* attribute-reading parameter kind fails `containsAttribute` and the process died.
  /// That is the framework's own documented code path, not a misuse: it killed a whole gate
  /// run rather than reporting one component. D13: a catchable Java exception becomes a Swift
  /// `throw`.
  private func parameterValue(for parameter: ParameterInfo, attrs: any AttributeSet) throws -> String {
    let selectedValue: Int64
    switch parameter.kind {
    case .widthFormula(let multiplier, let offset):
      guard attrs.containsAttribute(parameter.attributeToCheckForBus) else {
        throw HdlParameterError.missingAttribute
      }
      let width = Int64(attrs.getValue(parameter.attributeToCheckForBus)!.width)
      selectedValue = width * multiplier + offset

    case .constant(let value):
      selectedValue = value

    case .attributeOption(let attribute, let map):
      guard attrs.containsAttribute(attribute) else {
        throw HdlParameterError.missingAttribute
      }
      guard case .option(let option)? = attrs.rawValue(attribute) else {
        throw HdlParameterError.notAnAttributeOption
      }
      guard let value = map[option] else {
        throw HdlParameterError.optionNotInMap
      }
      selectedValue = value

    case .productOfAttributes(let attributes):
      var product: Int64 = 1
      for attribute in attributes where attrs.containsAttribute(attribute) {
        product *= try Self.numericValue(attrs.rawValue(attribute))
      }
      selectedValue = product

    case .log2(let attributes, let offset):
      var total: Int64 = 0
      for attribute in attributes {
        guard attrs.containsAttribute(attribute) else {
          throw HdlParameterError.missingAttribute
        }
        total += try Self.numericValue(attrs.rawValue(attribute))
      }
      let logValue = log2(Double(total))
      selectedValue = Int64(logValue.rounded(.up)) + offset

    case .power2(let attributes, _):
      var total: Int64 = 0
      for attribute in attributes {
        guard attrs.containsAttribute(attribute) else {
          throw HdlParameterError.missingAttribute
        }
        total += try Self.numericValue(attrs.rawValue(attribute))
      }
      selectedValue = Int64(pow(2.0, Double(total)))

    case .intAttribute(let attribute, let offset):
      guard attrs.containsAttribute(attribute) else {
        throw HdlParameterError.missingAttribute
      }
      selectedValue = try Self.numericValue(attrs.rawValue(attribute)) + offset

    case .gateInputBubbleMask(let inputsAttribute, let isInverted):
      guard attrs.containsAttribute(inputsAttribute),
        case .integer(let nInputsRaw)? = attrs.rawValue(inputsAttribute)
      else {
        throw HdlParameterError.missingAttribute
      }
      let nrOfInputs = Int(nInputsRaw)
      var bubbleMask: Int64 = 0
      var mask: Int64 = 1
      for index in 0..<nrOfInputs {
        // VHDL indexes std_logic_vector "downto", so bit order is reversed relative to
        // Verilog: matching upstream's `realIndex` swap exactly.
        let realIndex = Hdl.isVhdl() ? nrOfInputs - index - 1 : index
        if isInverted(attrs, realIndex) { bubbleMask |= mask }
        mask <<= 1
      }
      selectedValue = bubbleMask
    }

    return parameter.isIntParameter
      ? String(selectedValue)
      : Hdl.getConstantVector(
        selectedValue, nrOfBits: try numberOfVectorBits(for: parameter, attrs: attrs))
  }

  /// `ParameterInfo.getNumberOfVectorBits(AttributeSet)`.
  private func numberOfVectorBits(for parameter: ParameterInfo, attrs: any AttributeSet) throws -> Int {
    precondition(!parameter.isIntParameter, "Parameter is not a bit vector!")
    var nrOfVectorBits = -1

    if case .gateInputBubbleMask(let inputsAttribute, _) = parameter.kind {
      guard attrs.containsAttribute(inputsAttribute),
        case .integer(let value)? = attrs.rawValue(inputsAttribute)
      else {
        throw HdlParameterError.missingAttribute
      }
      nrOfVectorBits = Int(value)
    }

    let offset = Self.vectorWidthOverride(parameter.kind)
    if offset > 0 { nrOfVectorBits = Int(offset) }

    if nrOfVectorBits < 0 {
      guard attrs.containsAttribute(parameter.attributeToCheckForBus) else {
        throw HdlParameterError.cannotDetermineVectorBits
      }
      nrOfVectorBits = attrs.getValue(parameter.attributeToCheckForBus)!.width
    }
    return nrOfVectorBits
  }

  /// The `offsetValue` field, exactly as `getNumberOfVectorBits` reads it: only
  /// `.widthFormula`, `.log2`, `.power2` and `.intAttribute` carry one; everything else is 0,
  /// matching the Java field's default.
  private static func vectorWidthOverride(_ kind: HdlParameterKind) -> Int64 {
    switch kind {
    case .widthFormula(_, let offset): return offset
    case .log2(_, let offset): return offset
    case .power2(_, let offset): return offset
    case .intAttribute(_, let offset): return offset
    default: return 0
    }
  }

  /// The `instanceof Integer | Long | BitWidth` dispatch every numeric-accumulation `MAP_*`
  /// branch shares, expressed over `AttributeValue` (see the file header, adaptation 1).
  private static func numericValue(_ value: AttributeValue?) throws -> Int64 {
    switch value {
    case .integer(let v): return Int64(v)
    case .long(let v): return v
    case .bitWidth(let w): return Int64(w)
    default:
      throw HdlParameterError.notAnIntegerOrLong
    }
  }
}

/// The `UnsupportedOperationException`s `HdlParameters.java` raises, as a Swift error (D13).
///
/// Java's messages are reproduced verbatim in `description` so a report generated from either
/// side reads the same. Each case names the *declaration* that did not match the attribute set,
/// which is what a generator author needs; the framework's own `componentInfo == nil` path
/// reaches `missingAttribute` for essentially every parameter kind.
public enum HdlParameterError: Error, CustomStringConvertible {
  /// `HdlParameters.java:159/168/181/194/203/257`; `attrs.containsAttribute(...)` was false.
  case missingAttribute
  /// `HdlParameters.java:161`.
  case notAnAttributeOption
  /// `HdlParameters.java:162`.
  case optionNotInMap
  /// `HdlParameters.java:265`.
  case cannotDetermineVectorBits
  /// `HdlParameters.java:229`, the `instanceof Integer | Long` dispatch fell through.
  case notAnIntegerOrLong
  /// `HdlParameters.java:392`, `getNumberOfVectorBits` for an id this list never declared.
  case parameterNotFound

  public var description: String {
    switch self {
    case .missingAttribute: return "Component has not the required attribute"
    case .notAnAttributeOption: return "Requested attribute is not an attributeOption"
    case .optionNotInMap: return "Map does not contain the requested attributeOption"
    case .cannotDetermineVectorBits:
      return "Cannot determine the number of bits required for the vector"
    case .notAnIntegerOrLong: return "Requested attribute is not an Integer or Long"
    case .parameterNotFound: return "Parameter not found"
    }
  }
}
