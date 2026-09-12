// GateAttributes.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.gates.{GateAttributes,
// GateAttributeList}), https://github.com/logisim-evolution/logisim-evolution. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.gates.GateAttributes`; the hand-written attribute set every gate
/// uses, because its attribute *list* grows and shrinks with the input count.
public final class GateAttributes: AbstractAttributeSet {

  /// `GateAttributes.MAX_INPUTS`.
  public static let maxInputs: Int32 = 64
  /// `GateAttributes.DELAY`.
  public static let delay = 1

  // MARK: Attribute identities

  /// `SIZE_NARROW` / `SIZE_MEDIUM` / `SIZE_WIDE`: `new AttributeOption(Integer, …)`, so the
  /// `.circ` token is the number itself.
  public static let sizeNarrow = AttributeOption(value: Int32(30))
  public static let sizeMedium = AttributeOption(value: Int32(50))
  public static let sizeWide = AttributeOption(value: Int32(70))

  /// `GateAttributes.ATTR_SIZE`.
  public static let size: Attribute<AttributeOption> = Attributes.forOption(
    "size", choices: [sizeNarrow, sizeMedium, sizeWide])

  /// `GateAttributes.ATTR_INPUTS`.
  public static let inputs: Attribute<Int32> = Attributes.forIntegerRange(
    "inputs", start: 2, end: GateAttributes.maxInputs)

  /// `XOR_ONE` / `XOR_ODD`.
  public static let xorOne = AttributeOption(value: "1")
  public static let xorOdd = AttributeOption(value: "odd")

  /// `GateAttributes.ATTR_XOR`.
  public static let xor: Attribute<AttributeOption> = Attributes.forOption(
    "xor", choices: [xorOne, xorOdd])

  /// `OUTPUT_01` / `OUTPUT_0Z` / `OUTPUT_Z1`.
  public static let output01 = AttributeOption(value: "01")
  public static let output0Z = AttributeOption(value: "0Z")
  public static let outputZ1 = AttributeOption(value: "Z1")

  /// `GateAttributes.ATTR_OUTPUT`.
  public static let output: Attribute<AttributeOption> = Attributes.forOption(
    "out", choices: [output01, output0Z, outputZ1])

  /// `GateAttributeList.BASE_ATTRIBUTES`.
  private static let baseAttributes: [AnyAttribute] = [
    StdAttr.facing,
    StdAttr.width,
    GateAttributes.size,
    GateAttributes.inputs,
    GateAttributes.output,
    StdAttr.label,
    StdAttr.labelFont,
  ]

  // MARK: Fields — upstream's, verbatim, with upstream's initial values

  public var facing: Direction = .east
  public var width: BitWidth = .one
  public var sizeOption: AttributeOption = GateAttributes.sizeMedium
  public var inputCount: Int32 = 2
  /// Java `long negated`. Bit *i* set means input *i* is negated.
  public var negated: Int64 = 0
  public var outputBehaviour: AttributeOption = GateAttributes.output01
  /// `null` for every gate except XOR/XNOR, which is how `GateAttributeList` decides whether
  /// `ATTR_XOR` appears in the list at all.
  public var xorBehaviour: AttributeOption?
  public var label: String = ""
  public var labelFont: FontSpec = StdAttr.defaultLabelFont

  /// `GateAttributes(boolean isXor)`.
  public init(isXor: Bool) {
    self.xorBehaviour = isXor ? GateAttributes.xorOne : nil
    super.init()
  }

  /// The integer behind `ATTR_SIZE`; upstream's `(Integer) attrs.size.getValue()`.
  ///
  /// The payload is always an integer because all three options are built from `Integer`s; a
  /// value that somehow was not falls back to the medium size rather than trapping.
  public var sizeValue: Int {
    if case .integer(let value) = sizeOption.payload { return Int(value) }
    return 50
  }

  // MARK: Attribute list — `GateAttributeList`

  /// `getAttributes()` → `new GateAttributeList(this)`.
  ///
  /// **Deviation (mechanism).** Upstream returns a live `AbstractList` view that re-reads
  /// `attrs.inputs` and `attrs.facing` on every `get(i)`; this returns a snapshot. Every
  /// upstream consumer iterates the list immediately (the `.circ` writer, the attribute table),
  /// so no consumer can observe the difference, and `fireAttributeListChanged()` still fires
  /// when `inputs` changes, which is what tells them to re-read.
  public override var attributes: [AnyAttribute] {
    var result = GateAttributes.baseAttributes
    if xorBehaviour != nil { result.append(GateAttributes.xor) }
    let count = Int(inputCount)
    for index in 0..<max(count, 0) {
      let side: Direction?
      // `GateAttributeList.get`: first input gets NORTH/WEST, last gets SOUTH/EAST, the rest
      // get none. `index == 0` is tested first, so a one-input gate takes the first branch.
      if index == 0 {
        side = (facing == .east || facing == .west) ? .north : .west
      } else if index == count - 1 {
        side = (facing == .east || facing == .west) ? .south : .east
      } else {
        side = nil
      }
      result.append(NegateAttributes.attribute(index: index, side: side))
    }
    return result
  }

  // MARK: Reading

  /// `getValue(Attribute<V>)`, in storage form (D5).
  public override func rawValue(_ attribute: AnyAttribute) -> AttributeValue? {
    if attribute === StdAttr.facing { return StdAttr.facing.encode(facing) }
    if attribute === StdAttr.width { return StdAttr.width.encode(width) }
    if attribute === StdAttr.label { return StdAttr.label.encode(label) }
    if attribute === StdAttr.labelFont { return StdAttr.labelFont.encode(labelFont) }
    if attribute === GateAttributes.size { return .option(sizeOption) }
    if attribute === GateAttributes.inputs { return .integer(inputCount) }
    if attribute === GateAttributes.output { return .option(outputBehaviour) }
    if attribute === GateAttributes.xor { return xorBehaviour.map { .option($0) } }
    if let info = NegateAttributes.info(of: attribute) {
      // `(int) (negated >> index) & 1`
      return .boolean(javaLongBitAt(negated, info.index) == 1)
    }
    // Upstream returns `null` for anything else.
    return nil
  }

  // MARK: Writing

  /// `setValue(Attribute<V>, V)`.
  ///
  /// Two upstream bugs are preserved here on purpose; see the inline notes.
  public override func setRawValue(
    _ attribute: AnyAttribute, _ newValue: AttributeValue?
  ) throws {
    var oldValue: AttributeValue?

    if attribute === StdAttr.width {
      guard let value = newValue.flatMap(StdAttr.width.decode) else { throw badValue(attribute) }
      width = value
      // ── UPSTREAM BUG, PRESERVED ──────────────────────────────────────────────────────────
      // `int bits = width.getWidth(); long mask = bits >= 64 ? -1L : ((1L << inputs) - 1);`
      // The guard tests the *bit width* but the shift uses the *input count*. Clearing the
      // negation mask against the input count is plausibly what was meant; testing the width
      // is not. Preserved verbatim; changing it silently alters which inputs stay negated
      // when a gate's width is edited.
      //
      // The shift also needs Java's `n & 63` masking: `inputs` reaches 64, and `1L << 64` is
      // 1 in Java but 0 in Swift.
      let bits = width.width
      let mask: Int64 = bits >= 64 ? -1 : (javaLongBit(Int(inputCount)) &- 1)
      negated &= mask
    } else if attribute === StdAttr.facing {
      guard let value = newValue.flatMap(StdAttr.facing.decode) else { throw badValue(attribute) }
      facing = value
    } else if attribute === StdAttr.label {
      guard let value = newValue.flatMap(StdAttr.label.decode) else { throw badValue(attribute) }
      oldValue = StdAttr.label.encode(label)
      label = value
    } else if attribute === StdAttr.labelFont {
      guard let value = newValue.flatMap(StdAttr.labelFont.decode) else {
        throw badValue(attribute)
      }
      labelFont = value
    } else if attribute === GateAttributes.size {
      guard case .option(let value)? = newValue else { throw badValue(attribute) }
      sizeOption = value
    } else if attribute === GateAttributes.inputs {
      guard case .integer(let value)? = newValue else { throw badValue(attribute) }
      inputCount = value
      fireAttributeListChanged()
    } else if attribute === GateAttributes.xor {
      guard case .option(let value)? = newValue else { throw badValue(attribute) }
      xorBehaviour = value
    } else if attribute === GateAttributes.output {
      guard case .option(let value)? = newValue else { throw badValue(attribute) }
      outputBehaviour = value
    } else if let info = NegateAttributes.info(of: attribute) {
      guard case .boolean(let flag)? = newValue else { throw badValue(attribute) }
      // ── UPSTREAM BUG, PRESERVED ──────────────────────────────────────────────────────────
      // `negated |= 1 << index` and `negated &= ~(1 << index)` shift an `int`, not a `long`,
      // even though `negated` is a `long`. Java masks an `int` shift distance by 31, so
      // input 32 toggles bit 0, and input 31 sets bits 31…63 (sign extension on widening) or
      // clears them (`~`). A 64-input gate therefore cannot negate inputs 32…63 independently.
      // Reproduced exactly; "fixing" it would change what an existing `.circ` file simulates.
      if flag {
        negated |= javaIntBitWidened(info.index)
      } else {
        negated &= javaIntBitComplementWidened(info.index)
      }
    } else {
      // `throw new IllegalArgumentException("unrecognized argument")`
      throw AttributeSetError.attributeAbsent(name: attribute.name)
    }

    // `fireAttributeValueChanged(attr, value, attr == StdAttr.LABEL ? oldvalue : null)`
    fireAttributeValueChanged(attribute, value: newValue, oldValue: oldValue)
  }

  private func badValue(_ attribute: AnyAttribute) -> ComponentError {
    .unsupportedAttributeValue(factory: "GateAttributes", attribute: attribute.name)
  }

  // MARK: Copying

  /// **Deviation (mechanism), and it is load-bearing.**
  ///
  /// Java's `AbstractAttributeSet.clone()` calls `Object.clone()`, which copies every field,
  /// and *then* calls `copyInto(dest)`, which is why `GateAttributes.copyInto` can be an empty
  /// method with the comment "nothing to do". Swift has no `Object.clone`, so this has to copy
  /// the fields itself. Leaving `copyInto` empty, as the Java text does, would produce a clone
  /// with default values for every attribute, and `AbstractComponentFactory`'s default-value
  /// cache clones the set, so every gate in every file would compare "at its default".
  public override func makeCopyInstance() -> AbstractAttributeSet {
    GateAttributes(isXor: xorBehaviour != nil)
  }

  public override func copyInto(_ destination: AbstractAttributeSet) {
    guard let destination = destination as? GateAttributes else { return }
    destination.facing = facing
    destination.width = width
    destination.sizeOption = sizeOption
    destination.inputCount = inputCount
    destination.negated = negated
    destination.outputBehaviour = outputBehaviour
    destination.xorBehaviour = xorBehaviour
    destination.label = label
    destination.labelFont = labelFont
  }
}
