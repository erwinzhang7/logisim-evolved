// SplitterAttributes.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.circuit.SplitterAttributes),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16). See `SplitterParameters.swift`'s header for why
// this file lives under `LogisimStd/Wiring/` rather than mirroring Java's `circuit` package.
//
// ══ WHY THIS FILE IS THE MOST INTRICATE ATTRIBUTE SET IN THE PORT ═══════════════════════════
//
// `SplitterAttributes`'s attribute *list* grows and shrinks at runtime: five fixed attributes
// (`FACING`, `ATTR_FANOUT`, `ATTR_WIDTH`, `ATTR_APPEARANCE`, `ATTR_SPACING`) plus one dynamic
// `bit0`, `bit1`, … attribute per incoming bit. Both the count (driven by `ATTR_WIDTH`) and the
// per-bit *values* (driven by `ATTR_FANOUT` and `ATTR_WIDTH` through `computeDistribution`) are
// serialised, gated `.circ` output: see `decisions.md`'s `WHY THIS FAMILY MATTERS MORE` block.
//
// ── The `Attribute<V>` subclass Java uses does not port directly ────────────────────────────
//
// Java's `BitOutAttribute extends Attribute<Integer>` to carry a `which` index alongside the
// name. D5's `Attribute<V>` is `final` (storage/codec closures replace subclassing), so it
// cannot be subclassed here. Instead every `bitN` attribute shares ONE codec
// (`SplitterAttributes.bitOutCodec`; the parse/format logic does not depend on `which` at all,
// only the `.circ` *name* does), and the index is recovered where Java would read `.which` by
// looking the attribute up in `bitOutAttributes`, a parallel array kept in lockstep with the
// tail of `attrs`. `SplitterFactory.defaultAttributeValue` recovers the same index by parsing
// the attribute's name (`"bit" + which`), which is exactly the string that identity would have
// pointed at anyway.
//
// ── `BitOutOption` / `configureOptions()`; NOT PORTED ──────────────────────────────────────
//
// Java's `BitOutOption[] options` exists only to populate the attribute table's dropdown
// (`BitOutAttribute.getCellEditor`) and its localized display text (`toDisplayString`,
// `sameOptions`). None of that is reachable from `parse`/`toStandardString`, so it carries no
// `.circ`-serialisation weight and is UI surface (D9), deferred to M7 alongside the rest of the
// attribute table. `configureOptions()` is dropped with it.
//
// ── The `which + 1` default is deliberately NOT `computeDistribution`'s answer ──────────────
//
// `BitOutAttribute.getDefault()` always returns `which + 1`, a straight 1:1 bit→end mapping,
// regardless of what `computeDistribution(fanout, bits, 1)` actually assigned as the *initial*
// value for a non-trivial fanout/width combination (e.g. fanout 3, width 6 distributes bits
// unevenly, so `bitEnd[2]` starts at `2`, not `3`). This means a splitter whose initial
// distribution does not happen to equal the identity mapping serialises `<a name="bit2"
// val="1"/>` (0-indexed val) even though nothing was "changed" by a user: preserved exactly as
// Java computes it; see `SplitterFactory.swift`.

import Foundation
import LogisimFile
import LogisimKernel

/// `SplitterAttributes.APPEAR_LEFT` / `_RIGHT` / `_CENTER` / `_LEGACY`, as the native-enum shape
/// D5 prefers for new ports. Declaration order matches Java's `ATTR_APPEARANCE` choices array
/// (`{APPEAR_LEFT, APPEAR_RIGHT, APPEAR_CENTER, APPEAR_LEGACY}`); raw values match each option's
/// `.circ` token exactly ("left", "right", "center", "legacy").
public enum SplitterAppearance: String, AttributeOptionValue, CaseIterable, Sendable {
  case left, right, center, legacy
}

/// `com.cburch.logisim.circuit.SplitterAttributes`.
public final class SplitterAttributes: AbstractAttributeSet {

  // MARK: - Attribute vocabulary

  /// `SplitterAttributes.ATTR_SPACING`.
  public static let attrSpacing: Attribute<Int32> = Attributes.forIntegerRange(
    "spacing", start: 1, end: 9)

  /// `SplitterAttributes.ATTR_APPEARANCE`.
  public static let attrAppearance: Attribute<SplitterAppearance> = Attributes.forOption("appear")

  /// `SplitterAttributes.ATTR_WIDTH`. Java's `.circ` token is `"incoming"`, not `"width"`: a
  /// distinct `Attribute` identity from `StdAttr.WIDTH` even though both carry a `BitWidth`.
  public static let attrWidth: Attribute<BitWidth> = Attributes.forBitWidth("incoming")

  /// `SplitterAttributes.ATTR_FANOUT`.
  public static let attrFanout: Attribute<Int32> = Attributes.forIntegerRange(
    "fanout", start: 1, end: 64)

  /// `SplitterAttributes.INIT_ATTRIBUTES`.
  private static let initAttributes: [AnyAttribute] = [
    StdAttr.facing, attrFanout, attrWidth, attrAppearance, attrSpacing,
  ]

  /// `SplitterAttributes.UNCHOSEN_VAL`.
  private static let unchosenVal = "none"

  /// The codec shared by every `bitN` attribute; see the file header for why one codec (rather
  /// than a `BitOutAttribute` subclass) is correct here. `parse`/`toStandardString` reproduce
  /// `BitOutAttribute.parse`/`toStandardString` verbatim (`SplitterAttributes.java:71-92`).
  private static let bitOutCodec: AttributeCodec<Int32> = AttributeCodec<Int32>(
    parse: { text in
      if text == unchosenVal { return 0 }
      // Java: `1 + Integer.parseInt(value)`: an unchecked `NumberFormatException` on
      // non-numeric text, made a checked throw per D13 (reachable from a malformed `.circ`).
      guard let raw = Int32(text) else {
        throw AttributeParseError.numberFormat("For input string: \"\(text)\"")
      }
      return 1 &+ raw
    },
    toStandardString: { value in
      value == 0 ? unchosenVal : String(value &- 1)
    },
    encode: { .integer($0) },
    decode: { if case .integer(let value) = $0 { return value } else { return nil } })

  /// `SplitterAttributes.computeDistribution(int fanout, int bits, int order)`
  /// (`SplitterAttributes.java:128-174`).
  ///
  /// `order >= 0` walks bits low→high assigning them to ends in round-robin blocks starting at
  /// end 1; `order < 0` walks high→low. Called with `order = 1` from `configureDefaults()`; the
  /// negative branch is exercised only by the (unported, M7) "Distribute" context-menu action;
  /// kept here verbatim since it costs nothing and the byte-visible default depends on the
  /// `order >= 0` half only.
  ///
  /// `fanout` is 1...64 and `bits` is 0...64 (both range-checked at the attribute layer), so the
  /// `Int32` truncation Java's `byte` cast performs can never actually truncate here; kept as
  /// `Int32` to mirror Java's storage type (and because every consumer wants `Int32` back).
  static func computeDistribution(fanout: Int, bits: Int, order: Int) -> [Int32] {
    var result = [Int32](repeating: 0, count: bits)
    if order >= 0 {
      if fanout >= bits {
        for i in 0..<bits { result[i] = Int32(i + 1) }
      } else {
        let threadsPerEnd = bits / fanout
        var endsWithExtra = bits % fanout
        var curEnd = -1  // immediately incremented
        var leftInEnd = 0
        for i in 0..<bits {
          if leftInEnd == 0 {
            curEnd += 1
            leftInEnd = threadsPerEnd
            if endsWithExtra > 0 {
              leftInEnd += 1
              endsWithExtra -= 1
            }
          }
          result[i] = Int32(1 + curEnd)
          leftInEnd -= 1
        }
      }
    } else {
      if fanout >= bits {
        for i in 0..<bits { result[i] = Int32(fanout - i) }
      } else {
        let threadsPerEnd = bits / fanout
        var endsWithExtra = bits % fanout
        var curEnd = -1
        var leftInEnd = 0
        for i in stride(from: bits - 1, through: 0, by: -1) {
          if leftInEnd == 0 {
            curEnd += 1
            leftInEnd = threadsPerEnd
            if endsWithExtra > 0 {
              leftInEnd += 1
              endsWithExtra -= 1
            }
          }
          result[i] = Int32(1 + curEnd)
          leftInEnd -= 1
        }
      }
    }
    return result
  }

  // MARK: - Stored state

  /// `SplitterAttributes.attrs`: `INIT_ATTRIBUTES` plus the current `bitN` tail.
  private var attrs: [AnyAttribute]

  /// The tail of `attrs`, kept as typed `Attribute<Int32>` so `rawValue`/`setRawValue` can match
  /// by reference identity without a `which` field. `bitOutAttributes[i]` is always `attrs[5 + i]`.
  private var bitOutAttributes: [Attribute<Int32>] = []

  private var cachedParameters: SplitterParameters?

  /// `SplitterAttributes.appear`. Default `APPEAR_LEFT`: overridden per-version by
  /// `SplitterFactory.defaultAttributeValue` for files older than 2.6.4.
  var appear: SplitterAppearance = .left

  /// `SplitterAttributes.facing`.
  var facing: Direction = .east

  /// `SplitterAttributes.spacing`.
  var spacing: Int32 = 1

  /// `SplitterAttributes.fanout`; "number of ends this splits into". Java: `byte`, default 2.
  var fanout: Int32 = 2

  /// `SplitterAttributes.bitEnd`: how each bit of end 0 maps to an end (`0` = nowhere,
  /// `1...fanout` otherwise). Java: `byte[]`, default length 2 (which is why a freshly placed
  /// splitter has incoming width 2; `ATTR_WIDTH`'s value is *derived* from this array's length,
  /// not stored independently).
  var bitEnd: [Int32] = [0, 0]

  public override init() {
    attrs = SplitterAttributes.initAttributes
    super.init()
    configureDefaults()
    cachedParameters = SplitterParameters(self)
  }

  /// `SplitterAttributes.isNoConnect(int index)`.
  public func isNoConnect(_ index: Int) -> Bool {
    !bitEnd.contains(Int32(index))
  }

  /// `SplitterAttributes.configureDefaults()` (`SplitterAttributes.java:219-251`).
  ///
  /// Runs on every `ATTR_FANOUT` or `ATTR_WIDTH` write. Note this REPLACES the entire bit
  /// mapping with the canonical order-1 distribution for the current fanout/width whenever it
  /// runs, including on a fanout change that does not alter the bit count at all. That is
  /// Java's behaviour (a fanout edit discards any custom "Distribute" assignment) and is
  /// preserved rather than "fixed" to only touch newly-added bits.
  private func configureDefaults() {
    let offs = SplitterAttributes.initAttributes.count
    var curNum = attrs.count - offs
    let dflt = SplitterAttributes.computeDistribution(
      fanout: Int(fanout), bits: bitEnd.count, order: 1)
    let changed = curNum != bitEnd.count

    // remove excess attributes
    while curNum > bitEnd.count {
      curNum -= 1
      attrs.remove(at: offs + curNum)
      bitOutAttributes.remove(at: curNum)
    }

    // set existing attributes
    for i in 0..<curNum {
      if bitEnd[i] != dflt[i] {
        let attr = bitOutAttributes[i]
        bitEnd[i] = dflt[i]
        fireAttributeValueChanged(attr, value: .integer(bitEnd[i]), oldValue: nil)
      }
    }

    // add new attributes
    for i in curNum..<bitEnd.count {
      let attr = Attribute<Int32>(name: "bit\(i)", codec: SplitterAttributes.bitOutCodec)
      bitEnd[i] = dflt[i]
      attrs.append(attr)
      bitOutAttributes.append(attr)
    }

    if changed { fireAttributeListChanged() }
  }

  /// `SplitterAttributes.getBitOutAttribute(int index)`.
  func bitOutAttribute(at index: Int) -> AnyAttribute { bitOutAttributes[index] }

  /// `SplitterAttributes.getParameters()`: lazily rebuilt whenever a geometry-affecting
  /// attribute write clears the cache (see `setRawValue`).
  func parameters() -> SplitterParameters {
    if let cachedParameters { return cachedParameters }
    let fresh = SplitterParameters(self)
    cachedParameters = fresh
    return fresh
  }

  // MARK: - AbstractAttributeSet

  public override var attributes: [AnyAttribute] { attrs }

  public override func rawValue(_ attribute: AnyAttribute) -> AttributeValue? {
    if attribute === StdAttr.facing { return StdAttr.facing.encode(facing) }
    if attribute === SplitterAttributes.attrFanout { return .integer(fanout) }
    if attribute === SplitterAttributes.attrWidth {
      return SplitterAttributes.attrWidth.encode(BitWidth.known(bitEnd.count))
    }
    if attribute === SplitterAttributes.attrAppearance {
      return SplitterAttributes.attrAppearance.encode(appear)
    }
    if attribute === SplitterAttributes.attrSpacing { return .integer(spacing) }
    if let index = bitOutAttributes.firstIndex(where: { $0 === attribute }) {
      return .integer(bitEnd[index])
    }
    return nil
  }

  /// `SplitterAttributes.setValue(Attribute<V>, V)` (`SplitterAttributes.java:323-368`).
  public override func setRawValue(_ attribute: AnyAttribute, _ newValue: AttributeValue?) throws {
    if attribute === StdAttr.facing {
      guard let decoded = newValue.flatMap(StdAttr.facing.decode) else {
        throw ComponentError.unsupportedAttributeValue(
          factory: Splitter.id, attribute: attribute.name)
      }
      if facing == decoded { return }
      facing = decoded
      cachedParameters = nil
    } else if attribute === SplitterAttributes.attrFanout {
      guard let decoded = newValue.flatMap(SplitterAttributes.attrFanout.decode) else {
        throw ComponentError.unsupportedAttributeValue(
          factory: Splitter.id, attribute: attribute.name)
      }
      // Java clamps every existing bit assignment down to the new fanout BEFORE checking
      // whether the fanout actually changed. `configureDefaults()` below overwrites the whole
      // array again on a genuine change, so this clamp is only ever observable in the identity
      // (no-op) case, where it does nothing, preserved verbatim regardless.
      for i in bitEnd.indices where bitEnd[i] > decoded {
        bitEnd[i] = decoded
      }
      if fanout == decoded { return }
      fanout = decoded
      configureDefaults()
      cachedParameters = nil
    } else if attribute === SplitterAttributes.attrWidth {
      guard let decoded = newValue.flatMap(SplitterAttributes.attrWidth.decode) else {
        throw ComponentError.unsupportedAttributeValue(
          factory: Splitter.id, attribute: attribute.name)
      }
      if bitEnd.count == decoded.width { return }
      bitEnd = [Int32](repeating: 0, count: decoded.width)
      configureDefaults()
    } else if attribute === SplitterAttributes.attrSpacing {
      guard let decoded = newValue.flatMap(SplitterAttributes.attrSpacing.decode) else {
        throw ComponentError.unsupportedAttributeValue(
          factory: Splitter.id, attribute: attribute.name)
      }
      if spacing == decoded { return }
      spacing = decoded
      cachedParameters = nil
    } else if attribute === SplitterAttributes.attrAppearance {
      guard let decoded = newValue.flatMap(SplitterAttributes.attrAppearance.decode) else {
        throw ComponentError.unsupportedAttributeValue(
          factory: Splitter.id, attribute: attribute.name)
      }
      if appear == decoded { return }
      appear = decoded
      cachedParameters = nil
    } else if let index = bitOutAttributes.firstIndex(where: { $0 === attribute }) {
      guard case .integer(let raw)? = newValue else {
        throw ComponentError.unsupportedAttributeValue(
          factory: Splitter.id, attribute: attribute.name)
      }
      // Java: `val >= 0 && val <= fanout`, else the write is silently dropped (no throw, no
      // event): not even an `IllegalArgumentException`. Preserved.
      guard raw >= 0 && raw <= fanout else { return }
      if bitEnd[index] == raw { return }
      bitEnd[index] = raw
    } else {
      // `throw new IllegalArgumentException("unknown attribute " + attr)`.
      throw AttributeSetError.attributeAbsent(name: attribute.name)
    }
    fireAttributeValueChanged(attribute, value: newValue, oldValue: nil)
  }

  /// `SplitterAttributes.attributesMayAlsoBeChanged(Attribute<V>, V)` (`:371-384`).
  public override func attributesMayAlsoBeChanged<V>(
    _ attribute: Attribute<V>, _ value: V?
  ) -> [AnyAttribute]? {
    guard attribute === SplitterAttributes.attrFanout || attribute === SplitterAttributes.attrWidth
    else { return nil }
    if rawValue(attribute) == value.map(attribute.encode) { return nil }
    return bitOutAttributes.map { $0 as AnyAttribute }
  }

  public override func makeCopyInstance() -> AbstractAttributeSet {
    SplitterAttributes()
  }

  /// `SplitterAttributes.copyInto(AbstractAttributeSet)` (`:270-287`).
  ///
  /// Java allocates fresh `BitOutAttribute` copies for the destination (`attr.createCopy()`),
  /// new identity, same name, rather than sharing the source's. Reproduced: the destination
  /// gets its own `Attribute<Int32>` objects, built from `self.bitEnd.count` (the SOURCE's
  /// length) before `bitEnd` itself is copied across.
  public override func copyInto(_ destination: AbstractAttributeSet) {
    guard let destination = destination as? SplitterAttributes else { return }
    destination.attrs = SplitterAttributes.initAttributes
    destination.bitOutAttributes = (0..<bitEnd.count).map { i in
      Attribute<Int32>(name: "bit\(i)", codec: SplitterAttributes.bitOutCodec)
    }
    destination.attrs.append(contentsOf: destination.bitOutAttributes)

    destination.facing = facing
    destination.fanout = fanout
    destination.appear = appear
    destination.spacing = spacing
    destination.bitEnd = bitEnd
    destination.cachedParameters = cachedParameters
  }
}
