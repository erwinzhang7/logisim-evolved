// Attributes: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/logisim/data/{Attribute,Attributes,AttributeOption,AttributeOptionInterface}.java
// and the `BitWidth.Attribute` inner class from com/cburch/logisim/data/BitWidth.java.
// Copyright by the Logisim-evolution developers. This translation is a derivative work
// and is therefore licensed GPL-3.0-only. See LICENSE.md.
//
// ── D5: the hybrid attribute model ────────────────────────────────────────────────────────
//
// Java's `Attribute<V>` is a generic used as a heterogeneous map key, which Swift cannot
// express directly. The port splits the two jobs that class was doing:
//
//   * `Attribute<V>` stays generic and is what component code sees, so a call site reads
//     `attrs[Pin.appearance]` and gets a `PinAppearance?` with full static typing.
//   * `AttributeValue` is the *storage* and *codec* representation: a closed enum with one
//     case per concrete kind the Java `Attribute` subclasses actually produce, plus
//     `.opaque(String)`.
//
// The enum exists because `.circ` stores every attribute as `<a name="…" val="…"/>`: plain
// strings, and M2's pass condition is byte-exact round-tripping. A closed enum makes the
// string↔value mapping total and forces the writer's switch to be exhaustive at compile
// time. `.opaque` additionally carries D8: an attribute belonging to a component we cannot
// resolve survives load→save unchanged instead of being dropped.
//
// ── Deliberate omissions ──────────────────────────────────────────────────────────────────
//
// Localisation does not belong in the kernel (D9). Java's `Attribute` carries a
// `StringGetter displayName` and every subclass overrides `toDisplayString` to return
// localised text; none of that comes across. The kernel keeps the raw `name` and the
// standard-string codec only. The UI layer owns display names for both attributes and values.
//
// `getCellEditor` (a `javax.swing.JComponent` factory living on the data type) is likewise
// dropped; that is squarely a UI concern.

import Foundation

// MARK: - Errors

/// Java signals every attribute parse failure with an unchecked `NumberFormatException`
/// (even for non-numeric attributes; `OptionAttribute.parse` throws
/// `new NumberFormatException("value not among choices")`). Swift makes it checked so the
/// `.circ` loader is forced to decide what a bad value means.
public enum AttributeParseError: Error, CustomStringConvertible, Equatable {
  /// Mirrors `java.lang.NumberFormatException`.
  case numberFormat(String)
  /// The attribute has no textual representation at all (`Attributes.forMap()`).
  case notRepresentable(attribute: String)

  public var description: String {
    switch self {
    case .numberFormat(let message): return "NumberFormatException: \(message)"
    case .notRepresentable(let attribute):
      return "attribute '\(attribute)' has no string representation"
    }
  }
}

// MARK: - Storage payload types

/// A font, described structurally. `java.awt.Font` cannot come across, D9 keeps the kernel
/// free of any UI framework, so the kernel stores what the `.circ` file actually contains
/// (family name, style word, point size) and the renderer resolves that to a real font.
///
/// Deviation, deliberate and measured: see `docs/experiments/font-family.md`.
///
/// `FontAttribute.toStandardString` and `SvgCreator.setFontAttribute` both call
/// `font.getFamily()`, which is the family the *graphics environment resolved the request to*,
/// not the name that was asked for. On a JVM, a family that is not installed resolves to
/// `Dialog`, so upstream's save silently rewrites the family and the original name is gone from
/// the file forever. The kernel re-emits the family exactly as parsed, which is what D8 asks of
/// unrecognised content generally.
///
/// The earlier note here said the two agree "for every family Logisim itself writes". That is
/// true and it is not the interesting case: real files carry families from the machine that
/// wrote them, and 13 corpus files diverge on exactly this. Upstream's own output is a function
/// of the host's font set: measured by installing a font mid-experiment and re-running the
/// 4.1.0 jar over unchanged input, which changed its output. So `Dialog` is not a constant to
/// hardcode; it is that machine's answer.
///
/// Pinned by `swift/Tests/LogisimKernelTests/FontSpecFamilyTests.swift`.
public struct FontSpec: Hashable, Sendable {
  public var family: String
  public var style: FontStyle
  public var size: Int32

  public init(family: String, style: FontStyle = .plain, size: Int32 = 12) {
    self.family = family
    self.style = style
    self.size = size
  }

  /// `FontUtil.toStyleStandardString(int)`.
  public var styleStandardString: String { style.standardString }

  /// `FontAttribute.toStandardString`: `"%s %s %s"` of family, style word, size.
  public var standardString: String { "\(family) \(styleStandardString) \(size)" }
}

/// `java.awt.Font`'s style bit set: `PLAIN = 0`, `BOLD = 1`, `ITALIC = 2`.
public struct FontStyle: OptionSet, Hashable, Sendable {
  public let rawValue: Int32
  public init(rawValue: Int32) { self.rawValue = rawValue }

  public static let plain: FontStyle = []
  public static let bold = FontStyle(rawValue: 1)
  public static let italic = FontStyle(rawValue: 2)

  /// `FontUtil.toStyleStandardString`, including its `"??"` fallback for unknown bits.
  public var standardString: String {
    switch rawValue {
    case 0: return "plain"
    case 1: return "bold"
    case 2: return "italic"
    case 3: return "bolditalic"
    default: return "??"
    }
  }
}

/// An sRGB colour with 8-bit channels.
///
/// This is *data*, not a UI type: no `CGColor`, no `NSColor`, no `java.awt.Color`. D9 bans a
/// colour type from the kernel for `Value.getColor()`, which returns a palette entry chosen by
/// the renderer. `Attributes.forColor` is a different thing, a colour the *user typed into a
/// component's attribute table* (LED colour, Tty colours), which has to be stored and
/// re-serialised verbatim, so it is kept as four channel bytes.
public struct ColorSpec: Hashable, Sendable {
  public var red: UInt8
  public var green: UInt8
  public var blue: UInt8
  public var alpha: UInt8

  public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }

  /// `ColorAttribute.hex(int)`: lowercase, always two digits.
  private static func hex(_ component: UInt8) -> String {
    let digits = String(component, radix: 16)
    return component >= 16 ? digits : "0" + digits
  }

  /// `ColorAttribute.toStandardString`: `#rrggbb`, with `aa` appended only when not opaque.
  public var standardString: String {
    let base = "#" + Self.hex(red) + Self.hex(green) + Self.hex(blue)
    return alpha == 255 ? base : base + Self.hex(alpha)
  }

  /// `ColorAttribute.parse`.
  ///
  /// Bug-for-bug: the 9-character branch never checks that the leading character is `#`, so
  /// `"Xff0000ff"` parses. Preserved deliberately; a fidelity port does not tighten inputs.
  public static func parse(_ text: String) throws -> ColorSpec {
    let scalars = Array(text.unicodeScalars)
    if scalars.count == 9 {
      func component(_ range: Range<Int>) throws -> UInt8 {
        let piece = String(String.UnicodeScalarView(scalars[range]))
        let value = try AttributeTextFormat.parseSigned(piece, radix: 16, bits: 32)
        guard (0...255).contains(value) else {
          throw AttributeParseError.numberFormat("Color parameter outside of expected range")
        }
        return UInt8(value)
      }
      return ColorSpec(
        red: try component(1..<3),
        green: try component(3..<5),
        blue: try component(5..<7),
        alpha: try component(7..<9))
    }
    let packed = try AttributeTextFormat.decodeSigned(text, bits: 32)
    return ColorSpec(
      red: UInt8((packed >> 16) & 0xFF),
      green: UInt8((packed >> 8) & 0xFF),
      blue: UInt8(packed & 0xFF),
      alpha: 255)
  }
}

/// `com.cburch.logisim.data.AttributeOption`, minus its `StringGetter desc`.
///
/// Deviation: Java's `AttributeOption` is a class with no `equals`, so options compare by
/// identity and every option in the program is a `static final` singleton. Here it is a value
/// type comparing on `(name, payload)`. Within one attribute the names are distinct, so every
/// comparison the Java performs (`attrs.getValue(X) == SOME_OPTION`) yields the same answer;
/// two same-named options belonging to *different* attributes now compare equal, which no
/// Logisim code path can observe because such a value can never be stored under the wrong
/// attribute.
///
/// For new Swift component ports prefer a native `enum` conforming to `AttributeOptionValue`;
/// this type exists so the 271 Java option declarations can be transcribed mechanically.
public struct AttributeOption: Hashable, Sendable {
  /// Java's `toString()`; this is what `.circ` stores and what `parse` matches against.
  public let name: String
  /// Java's `Object value`, narrowed to the payload kinds actually used upstream.
  public let payload: AttributeOptionPayload

  public init(name: String, payload: AttributeOptionPayload = .none) {
    self.name = name
    self.payload = payload
  }

  /// `new AttributeOption(String value, StringGetter desc)`.
  public init(value: String) {
    self.init(name: value, payload: .string(value))
  }

  /// `new AttributeOption(Integer value, StringGetter desc)`.
  public init(value: Int32) {
    self.init(name: String(value), payload: .integer(value))
  }
}

/// The payload kinds `AttributeOption.value` actually carries upstream. Anything richer
/// (a `Value`, a component-specific enum) belongs in a Swift `enum` conforming to
/// `AttributeOptionValue`, where the payload *is* the case.
public enum AttributeOptionPayload: Hashable, Sendable {
  case none
  case string(String)
  case integer(Int32)
  case boolean(Bool)
}

/// A value we recognised the *attribute name* of but not the attribute itself; D8's
/// unknown-component round-trip. The raw string is preserved byte-for-byte and is deliberately
/// not scrubbed on the way out.
public struct OpaqueAttributeValue: Hashable, Sendable {
  public let raw: String
  public init(_ raw: String) { self.raw = raw }
}

/// Identity box for attribute values that are live objects rather than data: the single
/// upstream case being `Attributes.forMap()`, whose `ComponentMapInformationContainer` is
/// never saved and never parsed (`isToSave() == false`, `parse()` returns null).
public final class AttributeObjectBox: Hashable {
  public let object: AnyObject
  public init(_ object: AnyObject) { self.object = object }

  public static func == (lhs: AttributeObjectBox, rhs: AttributeObjectBox) -> Bool {
    lhs.object === rhs.object
  }
  public func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(object))
  }
}

// MARK: - AttributeValue

/// The closed storage/codec representation of an attribute value (D5).
///
/// One case per concrete kind produced by the Java `Attribute` subclasses, plus `.opaque` for
/// D8. Every `.circ` reader and writer switches over this exhaustively, so adding a new
/// attribute kind is a compile error at every serialisation site rather than a silent drop.
public enum AttributeValue: Hashable {
  /// `Attributes.BooleanAttribute`.
  case boolean(Bool)
  /// `Attributes.IntegerAttribute`, `HexIntegerAttribute`, `IntegerRangeAttribute`,
  /// `NoSaveAttribute`, `DurationAttribute`, `SplitterAttributes.BitOutAttribute`, …
  /// Java `int` is signed 32-bit; the textual form is per-attribute, not per-case.
  case integer(Int32)
  /// `Attributes.HexLongAttribute`. Java `long` is signed 64-bit.
  case long(Int64)
  /// `Attributes.DoubleAttribute`.
  case double(Double)
  /// `Attributes.StringAttribute`, `MultilineStringAttribute`, `HiddenAttribute`,
  /// `ImageSourceAttribute`, and the several component attributes that serialise their
  /// content to a string.
  case string(String)
  /// `BitWidth.Attribute`. Carries the width itself, 0…`Value.MAX_WIDTH`.
  case bitWidth(Int32)
  /// `Attributes.DirectionAttribute`.
  case direction(Direction)
  /// `Attributes.LocationAttribute`.
  case location(x: Int32, y: Int32)
  /// `Attributes.FontAttribute`.
  case font(FontSpec)
  /// `Attributes.ColorAttribute`.
  case color(ColorSpec)
  /// `Attributes.OptionAttribute`; the storage form is the option's name, which is exactly
  /// what `.circ` records.
  case option(AttributeOption)
  /// A live object that is never persisted (`Attributes.forMap()`).
  case object(AttributeObjectBox)
  /// D8: an attribute of an unresolved component. Round-trips verbatim.
  case opaque(String)

  /// Codec-level mirror of `com.cburch.logisim.data.Direction`.
  ///
  /// The full `Direction` value type (rotation, `getLeft`/`getRight`, degrees) is ported
  /// alongside `Location`/`Bounds`; storage only needs the four names the file format uses,
  /// and keeping the enum here means the attribute layer does not depend on that port. The
  /// ported `Direction` bridges in with a four-line `AttributeDirectionRepresentable`
  /// conformance.
  public enum Direction: String, Hashable, CaseIterable, Sendable {
    case east, north, west, south

    /// `Direction.parse(String)`: exact match, no case folding.
    public static func parse(_ text: String) throws -> Direction {
      guard let direction = Direction(rawValue: text) else {
        throw AttributeParseError.numberFormat("illegal direction '\(text)'")
      }
      return direction
    }
  }
}

// MARK: - Bridges to the concrete kernel value types

/// Implemented by the ported `BitWidth` so `Attributes.forBitWidth` can produce a typed
/// `Attribute<BitWidth>` without this file depending on that type.
public protocol AttributeBitWidthRepresentable {
  init?(attributeBitWidth width: Int32)
  var attributeBitWidth: Int32 { get }
}

extension Int32: AttributeBitWidthRepresentable {
  public init?(attributeBitWidth width: Int32) { self = width }
  public var attributeBitWidth: Int32 { self }
}

/// Implemented by the ported `Direction`.
public protocol AttributeDirectionRepresentable {
  init?(attributeDirection: AttributeValue.Direction)
  var attributeDirection: AttributeValue.Direction { get }
}

extension AttributeValue.Direction: AttributeDirectionRepresentable {
  public init?(attributeDirection: AttributeValue.Direction) { self = attributeDirection }
  public var attributeDirection: AttributeValue.Direction { self }
}

/// Implemented by the ported `Location` (see `AttributeBridges.swift`).
///
/// The initialiser is where `Location.create(x, y, hasToSnap: true)`'s half-grid snapping
/// lives, because `Location.parse` always snaps; conformers must apply it.
public protocol AttributeLocationRepresentable {
  init(attributeX: Int32, attributeY: Int32)
  var attributeX: Int32 { get }
  var attributeY: Int32 { get }
}

/// A Swift `enum` standing in for a Java `AttributeOption[]` choice list.
///
/// Conforming types get a total, compiler-checked name↔case mapping for free, which is what
/// D5 asks for: `enum PinAppearance: String, AttributeOptionValue { case dot, plain, … }`.
public protocol AttributeOptionValue: Hashable {
  /// Every legal value, in the order the UI should present them (Java's `vals` array).
  static var attributeOptions: [Self] { get }
  /// The token stored in `.circ`, Java's `AttributeOption.toString()`.
  var attributeOptionName: String { get }
}

extension AttributeOptionValue where Self: RawRepresentable, Self.RawValue == String {
  public var attributeOptionName: String { rawValue }
}

extension AttributeOptionValue where Self: CaseIterable {
  public static var attributeOptions: [Self] { Array(allCases) }
}

// MARK: - Codec

/// The four operations that connect a typed `V` to its storage form and its `.circ` text.
///
/// Java spreads these across `Attribute.parse`, `Attribute.toStandardString` and an implicit
/// `Object` cast in `AttributeSet`. Bundling them makes the storage mapping total by
/// construction: an `Attribute<V>` cannot exist without one.
public struct AttributeCodec<V> {
  /// `Attribute.parse(String)`.
  public let parse: (String) throws -> V
  /// `Attribute.toStandardString(V)`.
  public let toStandardString: (V) -> String
  /// `V` → storage.
  public let encode: (V) -> AttributeValue
  /// storage → `V`, `nil` when the stored value belongs to a different attribute kind.
  public let decode: (AttributeValue) -> V?

  public init(
    parse: @escaping (String) throws -> V,
    toStandardString: @escaping (V) -> String,
    encode: @escaping (V) -> AttributeValue,
    decode: @escaping (AttributeValue) -> V?
  ) {
    self.parse = parse
    self.toStandardString = toStandardString
    self.encode = encode
    self.decode = decode
  }
}

// MARK: - Attribute

/// The non-generic face of `Attribute<V>`: the port's `Attribute<?>`.
///
/// `AttributeSet` keys, the `.circ` reader/writer and the attribute table all work through
/// this. Equality is *identity*, matching Java (`Attribute` overrides neither `equals` nor
/// `hashCode`, and `AttributeSets.FixedSet` keys on `List.indexOf`).
open class AnyAttribute {
  /// Java's `name`: the `<a name="…">` token. Never localised.
  public let name: String

  /// Java's `hidden` flag, which the attribute table consults. Mutable, as upstream's
  /// `setHidden` is called at runtime (gates flip attributes in and out of view).
  public var isHidden: Bool

  /// `Attribute.isToSave()`. False for `Attributes.forNoSave()` and `Attributes.forMap()`.
  public let isToSave: Bool

  fileprivate init(name: String, isHidden: Bool, isToSave: Bool) {
    self.name = name
    self.isHidden = isHidden
    self.isToSave = isToSave
  }

  /// Parse `.circ` text straight into storage form, without the caller knowing `V`.
  open func parseToAttributeValue(_ text: String) throws -> AttributeValue {
    fatalError("AnyAttribute is abstract; use Attribute<V>")
  }

  /// Render a stored value as `.circ` text. `nil` when the stored value does not belong to
  /// this attribute (which the reader treats as a malformed file, not a crash).
  open func standardString(for value: AttributeValue) -> String? {
    fatalError("AnyAttribute is abstract; use Attribute<V>")
  }

  /// Whether `value` is a storage form this attribute can decode.
  open func accepts(_ value: AttributeValue) -> Bool {
    fatalError("AnyAttribute is abstract; use Attribute<V>")
  }
}

extension AnyAttribute: Hashable {
  public static func == (lhs: AnyAttribute, rhs: AnyAttribute) -> Bool { lhs === rhs }
  public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

extension AnyAttribute: CustomStringConvertible {
  /// Java's `Attribute.toString()` returns the name.
  public var description: String { name }
}

/// `com.cburch.logisim.data.Attribute<V>`, minus localisation and cell editors.
public final class Attribute<V>: AnyAttribute {
  public let codec: AttributeCodec<V>

  public init(
    name: String,
    isHidden: Bool = false,
    isToSave: Bool = true,
    codec: AttributeCodec<V>
  ) {
    self.codec = codec
    super.init(name: name, isHidden: isHidden, isToSave: isToSave)
  }

  /// `Attribute.parse(String)`.
  public func parse(_ text: String) throws -> V { try codec.parse(text) }

  /// `Attribute.toStandardString(V)`.
  public func toStandardString(_ value: V) -> String { codec.toStandardString(value) }

  public func encode(_ value: V) -> AttributeValue { codec.encode(value) }

  public func decode(_ value: AttributeValue) -> V? { codec.decode(value) }

  public override func parseToAttributeValue(_ text: String) throws -> AttributeValue {
    codec.encode(try codec.parse(text))
  }

  public override func standardString(for value: AttributeValue) -> String? {
    codec.decode(value).map(codec.toStandardString)
  }

  public override func accepts(_ value: AttributeValue) -> Bool {
    codec.decode(value) != nil
  }
}

// MARK: - Attributes factory

/// `com.cburch.logisim.data.Attributes`: the factory for every stock attribute kind.
///
/// Java's `Attributes.forX(name)` overloads that only differ by supplying a localised display
/// name are collapsed, since the kernel has no display names.
public enum Attributes {

  // MARK: Booleans

  /// `Attributes.forBoolean`.
  ///
  /// `BooleanAttribute.parse` is `Boolean.parseBoolean`, i.e. a case-insensitive comparison
  /// against `"true"`; *everything else is false*, including `"yes"`, `"1"` and garbage. That
  /// silent coercion is preserved.
  public static func forBoolean(_ name: String) -> Attribute<Bool> {
    Attribute(
      name: name,
      codec: AttributeCodec(
        parse: { $0.lowercased() == "true" },
        toStandardString: { AttributeTextFormat.standardScrub($0 ? "true" : "false") },
        encode: { .boolean($0) },
        decode: { if case .boolean(let flag) = $0 { return flag } else { return nil } }))
  }

  // MARK: Integers

  /// `Attributes.forInteger`: `Integer.valueOf(String)`, strict signed 32-bit decimal.
  public static func forInteger(_ name: String) -> Attribute<Int32> {
    Attribute(name: name, codec: decimalIntegerCodec())
  }

  /// `Attributes.forNoSave`; an integer that is never written to `.circ`.
  public static func forNoSave(_ name: String = "dummy") -> Attribute<Int32> {
    Attribute(name: name, isToSave: false, codec: decimalIntegerCodec())
  }

  /// `Attributes.forIntegerRange`.
  ///
  /// `IntegerRangeAttribute.parse` is `(int) Long.parseLong(value)`: parsed as a 64-bit
  /// value and then *narrowed*, so `"4294967297"` becomes `1` and only then gets range
  /// checked. Preserved.
  public static func forIntegerRange(
    _ name: String, start: Int32, end: Int32
  ) -> Attribute<Int32> {
    Attribute(
      name: name,
      codec: AttributeCodec(
        parse: { text in
          let wide = try AttributeTextFormat.parseSigned(text, radix: 10, bits: 64)
          let narrowed = Int32(truncatingIfNeeded: wide)
          if narrowed < start {
            throw AttributeParseError.numberFormat("integer must be at least \(start)")
          }
          if narrowed > end {
            throw AttributeParseError.numberFormat("integer must be at most \(end)")
          }
          return narrowed
        },
        toStandardString: { AttributeTextFormat.standardScrub(String($0)) },
        encode: { .integer($0) },
        decode: { if case .integer(let value) = $0 { return value } else { return nil } }))
  }

  /// `Attributes.forHexInteger`: `0x`/`0b`/leading-`0` octal/decimal in, `0x…` out.
  ///
  /// Bug-for-bug notes, all preserved:
  ///   * the negative branch uses `Integer.parseInt("-" + digits, radix)` (signed range) while
  ///     the positive branch uses `Integer.parseUnsignedInt` (full 32-bit unsigned range), so
  ///     `"0xffffffff"` parses to `-1` but `"-0xffffffff"` throws;
  ///   * the octal branch triggers on a leading `0` only when more characters follow, so
  ///     `"08"` throws while `"0"` parses as decimal;
  ///   * the value is lowercased first, so `"0X10"` is accepted.
  public static func forHexInteger(_ name: String) -> Attribute<Int32> {
    Attribute(
      name: name,
      codec: AttributeCodec(
        parse: { text in
          let bits = try parseJavaRadixPrefixed(text, bits: 32)
          return Int32(truncatingIfNeeded: bits)
        },
        toStandardString: { "0x" + AttributeTextFormat.javaHexString(int32: $0) },
        encode: { .integer($0) },
        decode: { if case .integer(let value) = $0 { return value } else { return nil } }))
  }

  /// `Attributes.forHexLong`: the 64-bit twin of `forHexInteger`, same quirks.
  public static func forHexLong(_ name: String) -> Attribute<Int64> {
    Attribute(
      name: name,
      codec: AttributeCodec(
        parse: { try parseJavaRadixPrefixed($0, bits: 64) },
        toStandardString: { "0x" + AttributeTextFormat.javaHexString(int64: $0) },
        encode: { .long($0) },
        decode: { if case .long(let value) = $0 { return value } else { return nil } }))
  }

  // MARK: Doubles

  /// `Attributes.forDouble`. Output goes through `Double.toString`'s exact layout rules, not
  /// Swift's, because M2 requires byte-exact round-tripping.
  public static func forDouble(_ name: String) -> Attribute<Double> {
    Attribute(
      name: name,
      codec: AttributeCodec(
        parse: { try AttributeTextFormat.parseDouble($0) },
        toStandardString: {
          AttributeTextFormat.standardScrub(AttributeTextFormat.javaDoubleString($0))
        },
        encode: { .double($0) },
        decode: { if case .double(let value) = $0 { return value } else { return nil } }))
  }

  // MARK: Strings

  /// `Attributes.forString`. The default `toStandardString` strips control characters and
  /// `&#…;` runs, so a string attribute is *not* a transparent container.
  public static func forString(_ name: String) -> Attribute<String> {
    Attribute(name: name, codec: stringCodec(scrub: AttributeTextFormat.standardScrub))
  }

  /// `Attributes.forMultilineString`: newlines survive, other control characters do not.
  public static func forMultilineString(_ name: String) -> Attribute<String> {
    Attribute(name: name, codec: stringCodec(scrub: AttributeTextFormat.multilineScrub))
  }

  /// `Attributes.forHidden`: Java's no-arg `Attribute()` constructor: name `"dummy"`,
  /// permanently hidden, still saved.
  public static func forHidden(_ name: String = "dummy") -> Attribute<String> {
    Attribute(
      name: name,
      isHidden: true,
      codec: stringCodec(scrub: AttributeTextFormat.standardScrub))
  }

  /// D8: an attribute belonging to a component we could not resolve. The text is preserved
  /// byte-for-byte in both directions, deliberately *not* scrubbed, so load→save is a
  /// no-op for libraries we cannot load (`jar#…`, per D11).
  public static func forOpaque(_ name: String) -> Attribute<OpaqueAttributeValue> {
    Attribute(
      name: name,
      codec: AttributeCodec(
        parse: { OpaqueAttributeValue($0) },
        toStandardString: { $0.raw },
        encode: { .opaque($0.raw) },
        decode: { if case .opaque(let raw) = $0 { return OpaqueAttributeValue(raw) } else { return nil } }))
  }

  // MARK: Colour and font

  /// `Attributes.forColor`.
  public static func forColor(_ name: String) -> Attribute<ColorSpec> {
    Attribute(
      name: name,
      codec: AttributeCodec(
        parse: { try ColorSpec.parse($0) },
        toStandardString: { $0.standardString },
        encode: { .color($0) },
        decode: { if case .color(let spec) = $0 { return spec } else { return nil } }))
  }

  /// `Attributes.forFont`.
  public static func forFont(_ name: String) -> Attribute<FontSpec> {
    Attribute(
      name: name,
      codec: AttributeCodec(
        parse: { AttributeTextFormat.decodeFont($0) },
        toStandardString: { $0.standardString },
        encode: { .font($0) },
        decode: { if case .font(let spec) = $0 { return spec } else { return nil } }))
  }

  // MARK: Bit widths, directions, locations

  /// `Attributes.forBitWidth`, backed by `BitWidth.Attribute`.
  ///
  /// `parse` is `(int) Long.parseLong(value)`, 64-bit parse then narrowing, followed by the
  /// attribute's own `min`/`max` check and then `BitWidth.create`'s `0 ... MAX_WIDTH` check.
  /// Both checks are kept; with the default bounds the second is unreachable, but a caller
  /// passing `min < 0` can reach it, exactly as upstream.
  public static func forBitWidth<W: AttributeBitWidthRepresentable>(
    _ name: String,
    min: Int32 = Attributes.minimumBitWidth,
    max: Int32 = Attributes.maximumBitWidth
  ) -> Attribute<W> {
    Attribute(
      name: name,
      codec: AttributeCodec(
        parse: { text in
          let wide = try AttributeTextFormat.parseSigned(text, radix: 10, bits: 64)
          let width = Int32(truncatingIfNeeded: wide)
          if width < min {
            throw AttributeParseError.numberFormat("bit width must be at least \(min)")
          }
          if width > max {
            throw AttributeParseError.numberFormat("bit width must be at most \(max)")
          }
          guard let value = W(attributeBitWidth: width), width >= 0, width <= maximumBitWidth
          else {
            throw AttributeParseError.numberFormat(
              "width \(width) must be at most \(maximumBitWidth)")
          }
          return value
        },
        toStandardString: { AttributeTextFormat.standardScrub(String($0.attributeBitWidth)) },
        encode: { .bitWidth($0.attributeBitWidth) },
        decode: {
          if case .bitWidth(let width) = $0 { return W(attributeBitWidth: width) }
          return nil
        }))
  }

  /// `Value.MAX_WIDTH` / `BitWidth.MAXWIDTH`.
  public static let maximumBitWidth: Int32 = 64
  /// `BitWidth.MINWIDTH`.
  public static let minimumBitWidth: Int32 = 1

  /// `Attributes.forDirection`.
  ///
  /// `DirectionAttribute` extends `OptionAttribute` but overrides `parse` with
  /// `Direction.parse`, which is an exact, case-sensitive match on `east`/`north`/`west`/
  /// `south`.
  public static func forDirection<D: AttributeDirectionRepresentable>(
    _ name: String
  ) -> Attribute<D> {
    Attribute(
      name: name,
      codec: AttributeCodec(
        parse: { text in
          let direction = try AttributeValue.Direction.parse(text)
          guard let value = D(attributeDirection: direction) else {
            throw AttributeParseError.numberFormat("illegal direction '\(text)'")
          }
          return value
        },
        toStandardString: {
          AttributeTextFormat.standardScrub($0.attributeDirection.rawValue)
        },
        encode: { .direction($0.attributeDirection) },
        decode: {
          if case .direction(let direction) = $0 { return D(attributeDirection: direction) }
          return nil
        }))
  }

  /// `Attributes.forLocation`. `Location.parse` accepts `(x,y)`, `x,y` and `x y`, trims
  /// liberally, and snaps the result to the half grid.
  public static func forLocation<L: AttributeLocationRepresentable>(
    _ name: String
  ) -> Attribute<L> {
    Attribute(
      name: name,
      codec: AttributeCodec(
        parse: { text in
          let (x, y) = try parseLocationText(text)
          return L(attributeX: x, attributeY: y)
        },
        toStandardString: {
          AttributeTextFormat.standardScrub("(\($0.attributeX),\($0.attributeY))")
        },
        encode: { .location(x: $0.attributeX, y: $0.attributeY) },
        decode: {
          if case .location(let x, let y) = $0 { return L(attributeX: x, attributeY: y) }
          return nil
        }))
  }

  // MARK: Options

  /// `Attributes.forOption(name, disp, vals)` with Java-shaped `AttributeOption` choices.
  ///
  /// `OptionAttribute.parse` scans the choices for one whose `toString()` matches and throws
  /// `NumberFormatException("value not among choices")` otherwise.
  public static func forOption(
    _ name: String, choices: [AttributeOption]
  ) -> Attribute<AttributeOption> {
    Attribute(
      name: name,
      codec: AttributeCodec(
        parse: { text in
          guard let match = choices.first(where: { $0.name == text }) else {
            throw AttributeParseError.numberFormat("value not among choices")
          }
          return match
        },
        toStandardString: { AttributeTextFormat.standardScrub($0.name) },
        encode: { .option($0) },
        decode: { if case .option(let option) = $0 { return option } else { return nil } }))
  }

  /// `Attributes.forOption` over a native Swift enum. Preferred for new component ports: the
  /// name↔case mapping is total and checked by the compiler.
  public static func forOption<V: AttributeOptionValue>(_ name: String) -> Attribute<V> {
    Attribute(
      name: name,
      codec: AttributeCodec(
        parse: { text in
          guard let match = V.attributeOptions.first(where: { $0.attributeOptionName == text })
          else {
            throw AttributeParseError.numberFormat("value not among choices")
          }
          return match
        },
        toStandardString: { AttributeTextFormat.standardScrub($0.attributeOptionName) },
        encode: { .option(AttributeOption(name: $0.attributeOptionName)) },
        decode: { stored in
          guard case .option(let option) = stored else { return nil }
          return V.attributeOptions.first { $0.attributeOptionName == option.name }
        }))
  }

  // MARK: Opaque live objects

  /// `Attributes.forMap()`: the FPGA `ComponentMapInformationContainer` holder. Hidden,
  /// never saved, and `parse` returns null upstream; here it throws, which the loader can
  /// never observe because the attribute is never written in the first place.
  public static func forMap(_ name: String = "dummy") -> Attribute<AttributeObjectBox> {
    Attribute(
      name: name,
      isHidden: true,
      isToSave: false,
      codec: AttributeCodec(
        parse: { _ in throw AttributeParseError.notRepresentable(attribute: name) },
        toStandardString: { _ in "" },
        encode: { .object($0) },
        decode: { if case .object(let box) = $0 { return box } else { return nil } }))
  }

  // MARK: Shared codec pieces

  private static func decimalIntegerCodec() -> AttributeCodec<Int32> {
    AttributeCodec(
      parse: { Int32(try AttributeTextFormat.parseSigned($0, radix: 10, bits: 32)) },
      toStandardString: { AttributeTextFormat.standardScrub(String($0)) },
      encode: { .integer($0) },
      decode: { if case .integer(let value) = $0 { return value } else { return nil } })
  }

  private static func stringCodec(
    scrub: @escaping (String) -> String
  ) -> AttributeCodec<String> {
    AttributeCodec(
      parse: { $0 },
      toStandardString: scrub,
      encode: { .string($0) },
      decode: { if case .string(let text) = $0 { return text } else { return nil } })
  }

  /// The shared body of `HexIntegerAttribute.parse` / `HexLongAttribute.parse`.
  private static func parseJavaRadixPrefixed(_ input: String, bits: Int) throws -> Int64 {
    var text = input.lowercased()
    if text.hasPrefix("-") {
      text = String(text.dropFirst())
      if text.hasPrefix("0x") {
        return try AttributeTextFormat.parseSigned(
          "-" + text.dropFirst(2), radix: 16, bits: bits)
      }
      if text.hasPrefix("0b") {
        return try AttributeTextFormat.parseSigned(
          "-" + text.dropFirst(2), radix: 2, bits: bits)
      }
      if text.hasPrefix("0") && text.count > 1 {
        return try AttributeTextFormat.parseSigned(
          "-" + text.dropFirst(), radix: 8, bits: bits)
      }
      return try AttributeTextFormat.parseSigned("-" + text, radix: 10, bits: bits)
    }
    func unsigned(_ digits: String, radix: Int) throws -> Int64 {
      let magnitude = try AttributeTextFormat.parseUnsigned(
        digits, radix: radix, bits: bits)
      return Int64(bitPattern: magnitude)
    }
    if text.hasPrefix("0x") { return try unsigned(String(text.dropFirst(2)), radix: 16) }
    if text.hasPrefix("0b") { return try unsigned(String(text.dropFirst(2)), radix: 2) }
    if text.hasPrefix("0") && text.count > 1 {
      return try unsigned(String(text.dropFirst()), radix: 8)
    }
    return try unsigned(text, radix: 10)
  }

  /// `Location.parse(String)`.
  private static func parseLocationText(_ input: String) throws -> (Int32, Int32) {
    func javaTrim(_ text: Substring) -> Substring {
      var slice = text
      while let first = slice.unicodeScalars.first, first.value <= 0x20 {
        slice = slice.dropFirst()
      }
      while let last = slice.unicodeScalars.last, last.value <= 0x20 {
        slice = slice.dropLast()
      }
      return slice
    }

    var body = javaTrim(Substring(input))
    guard let first = body.first else {
      throw AttributeParseError.numberFormat("invalid point '\(input)'")
    }
    if first == "(" {
      guard body.last == ")" else {
        throw AttributeParseError.numberFormat("invalid point '\(input)'")
      }
      body = body.dropFirst().dropLast()
    }
    body = javaTrim(body)

    var separator = body.firstIndex(of: ",")
    if separator == nil { separator = body.firstIndex(of: " ") }
    guard let split = separator else {
      throw AttributeParseError.numberFormat("invalid point '\(input)'")
    }
    let xText = String(javaTrim(body[body.startIndex..<split]))
    let yText = String(javaTrim(body[body.index(after: split)...]))
    let x = try AttributeTextFormat.parseSigned(xText, radix: 10, bits: 32)
    let y = try AttributeTextFormat.parseSigned(yText, radix: 10, bits: 32)
    return (Int32(x), Int32(y))
  }
}
