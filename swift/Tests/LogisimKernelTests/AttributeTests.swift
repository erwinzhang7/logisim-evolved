// AttributeTests: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// Every expectation here is the observed behaviour of the Java implementation
// (com.cburch.logisim.data.Attributes and the JDK routines it delegates to), including the
// cases that are upstream defects. A "fix" that breaks one of these is a fidelity regression.

import Testing

@testable import LogisimKernel

// MARK: - Java number formatting

@Test func javaDoubleStringMatchesJavaLayout() {
  #expect(AttributeTextFormat.javaDoubleString(0) == "0.0")
  #expect(AttributeTextFormat.javaDoubleString(-0.0) == "-0.0")
  #expect(AttributeTextFormat.javaDoubleString(1) == "1.0")
  #expect(AttributeTextFormat.javaDoubleString(100) == "100.0")
  #expect(AttributeTextFormat.javaDoubleString(123.45) == "123.45")
  #expect(AttributeTextFormat.javaDoubleString(-2.5) == "-2.5")
  #expect(AttributeTextFormat.javaDoubleString(0.001) == "0.001")
  // Below 1e-3 and at/above 1e7 Java switches to scientific notation; Swift would print
  // "1e-04" and "10000000.0".
  #expect(AttributeTextFormat.javaDoubleString(0.0001) == "1.0E-4")
  #expect(AttributeTextFormat.javaDoubleString(1e7) == "1.0E7")
  #expect(AttributeTextFormat.javaDoubleString(1e22) == "1.0E22")
  #expect(AttributeTextFormat.javaDoubleString(1.23e-5) == "1.23E-5")
  #expect(AttributeTextFormat.javaDoubleString(3.0 / 7.0) == "0.42857142857142855")
  #expect(AttributeTextFormat.javaDoubleString(1e-3) == "0.001")
  #expect(AttributeTextFormat.javaDoubleString(.nan) == "NaN")
  #expect(AttributeTextFormat.javaDoubleString(.infinity) == "Infinity")
  #expect(AttributeTextFormat.javaDoubleString(-.infinity) == "-Infinity")
}

@Test func javaIntegerParsingRespectsSignedAndUnsignedRanges() throws {
  #expect(try AttributeTextFormat.parseSigned("-2147483648", bits: 32) == -2_147_483_648)
  #expect(throws: AttributeParseError.self) {
    try AttributeTextFormat.parseSigned("2147483648", bits: 32)
  }
  #expect(try AttributeTextFormat.parseUnsigned("ffffffff", radix: 16, bits: 32) == 0xFFFF_FFFF)
  #expect(throws: AttributeParseError.self) {
    try AttributeTextFormat.parseUnsigned("-1", radix: 10, bits: 32)
  }
  #expect(try AttributeTextFormat.parseSigned("-9223372036854775808", bits: 64) == Int64.min)
}

@Test func javaIntegerDecodeHandlesEveryRadixPrefix() throws {
  #expect(try AttributeTextFormat.decodeSigned("#ff0000") == 0xFF0000)
  #expect(try AttributeTextFormat.decodeSigned("0x10") == 16)
  #expect(try AttributeTextFormat.decodeSigned("010") == 8)
  #expect(try AttributeTextFormat.decodeSigned("10") == 10)
  #expect(try AttributeTextFormat.decodeSigned("-0x10") == -16)
}

// MARK: - String scrubbing

@Test func standardScrubMirrorsTheTwoJavaRegexes() {
  #expect(AttributeTextFormat.standardScrub("a\u{1}b") == "ab")
  #expect(AttributeTextFormat.standardScrub("a&#38;b") == "ab")
  // Reluctant `.*?`: only the first `;` closes the run.
  #expect(AttributeTextFormat.standardScrub("&#1;&#2;tail") == "tail")
  // Control characters go first, so the newline that would have blocked the entity match is
  // already gone by the time the entity pass runs.
  #expect(AttributeTextFormat.standardScrub("&#1\n2;x") == "x")
}

@Test func multilineScrubKeepsNewlinesAndBlocksEntitiesAcrossThem() {
  #expect(AttributeTextFormat.multilineScrub("a\r\nb\rc") == "a\nb\nc")
  #expect(AttributeTextFormat.multilineScrub("a\u{1}b") == "ab")
  // `.` does not match a line terminator, so this `&#…;` run is NOT removed.
  #expect(AttributeTextFormat.multilineScrub("&#1\n2;x") == "&#1\n2;x")
}

// MARK: - Codecs

@Test func booleanAttributeCoercesEverythingElseToFalse() throws {
  let attribute = Attributes.forBoolean("flag")
  #expect(try attribute.parse("true") == true)
  #expect(try attribute.parse("TRUE") == true)
  #expect(try attribute.parse("yes") == false)
  #expect(try attribute.parse("1") == false)
  #expect(attribute.toStandardString(true) == "true")
}

@Test func hexIntegerAttributeRoundTrips() throws {
  let attribute = Attributes.forHexInteger("value")
  #expect(try attribute.parse("0xff") == 255)
  #expect(try attribute.parse("0b1010") == 10)
  #expect(try attribute.parse("010") == 8)
  #expect(try attribute.parse("12") == 12)
  // Unsigned on the positive side...
  #expect(try attribute.parse("0xffffffff") == -1)
  // ...but signed on the negative side, so the mirror image throws.
  #expect(throws: AttributeParseError.self) { try attribute.parse("-0xffffffff") }
  // A lone leading zero is decimal, but "08" takes the octal path and fails.
  #expect(try attribute.parse("0") == 0)
  #expect(throws: AttributeParseError.self) { try attribute.parse("08") }
  #expect(attribute.toStandardString(-1) == "0xffffffff")
  #expect(attribute.toStandardString(255) == "0xff")
}

@Test func hexLongAttributeRoundTrips() throws {
  let attribute = Attributes.forHexLong("value")
  #expect(try attribute.parse("0xffffffffffffffff") == -1)
  #expect(attribute.toStandardString(-1) == "0xffffffffffffffff")
}

@Test func integerRangeNarrowsBeforeCheckingBounds() throws {
  let attribute = Attributes.forIntegerRange("n", start: 0, end: 16)
  #expect(try attribute.parse("8") == 8)
  // (int) Long.parseLong("4294967297") == 1, which is inside the range.
  #expect(try attribute.parse("4294967297") == 1)
  #expect(throws: AttributeParseError.self) { try attribute.parse("17") }
}

@Test func colorAttributeRoundTripsBothSpellings() throws {
  let attribute = Attributes.forColor("color")
  let opaque = try attribute.parse("#ff8000")
  #expect(opaque == ColorSpec(red: 0xFF, green: 0x80, blue: 0x00))
  #expect(attribute.toStandardString(opaque) == "#ff8000")

  let translucent = try attribute.parse("#0a0b0c80")
  #expect(translucent == ColorSpec(red: 0x0A, green: 0x0B, blue: 0x0C, alpha: 0x80))
  #expect(attribute.toStandardString(translucent) == "#0a0b0c80")

  // Color.decode accepts anything Integer.decode does.
  #expect(try attribute.parse("0xff0000") == ColorSpec(red: 255, green: 0, blue: 0))
}

@Test func fontAttributeDecodesJavaFontStrings() throws {
  let attribute = Attributes.forFont("font")
  let spaced = try attribute.parse("SansSerif bold 16")
  #expect(spaced == FontSpec(family: "SansSerif", style: .bold, size: 16))
  #expect(attribute.toStandardString(spaced) == "SansSerif bold 16")

  #expect(try attribute.parse("Monospaced-bolditalic-12")
    == FontSpec(family: "Monospaced", style: [.bold, .italic], size: 12))
  // No size and no style: the whole string is the family, size defaults to 12.
  #expect(try attribute.parse("Serif") == FontSpec(family: "Serif", style: .plain, size: 12))
  // A non-numeric trailing word folds back into the family name.
  #expect(try attribute.parse("Foo bar") == FontSpec(family: "Foo bar", style: .plain, size: 12))
  #expect(try attribute.parse("SansSerif-16")
    == FontSpec(family: "SansSerif", style: .plain, size: 16))
  #expect(try attribute.parse("SansSerif bold")
    == FontSpec(family: "SansSerif", style: .bold, size: 12))
  #expect(try attribute.parse("Times New Roman italic 14")
    == FontSpec(family: "Times New Roman", style: .italic, size: 14))
  #expect(try attribute.parse("") == FontSpec(family: "", style: .plain, size: 12))
}

@Test func opaqueAttributePreservesBytesExactly() throws {
  let attribute = Attributes.forOpaque("mystery")
  let raw = "keep\u{1}me &#38; whole"
  let parsed = try attribute.parse(raw)
  #expect(attribute.toStandardString(parsed) == raw)
  #expect(attribute.encode(parsed) == .opaque(raw))
  // A plain string attribute would have scrubbed both of those.
  #expect(Attributes.forString("s").toStandardString(raw) == "keepme  whole")
}

@Test func directionAndBitWidthUseTheirJavaCodecs() throws {
  let direction: Attribute<AttributeValue.Direction> = Attributes.forDirection("facing")
  #expect(try direction.parse("east") == .east)
  #expect(throws: AttributeParseError.self) { try direction.parse("East") }
  #expect(direction.toStandardString(.south) == "south")

  let width: Attribute<Int32> = Attributes.forBitWidth("width")
  #expect(try width.parse("8") == 8)
  #expect(throws: AttributeParseError.self) { try width.parse("0") }
  #expect(throws: AttributeParseError.self) { try width.parse("65") }
  #expect(width.toStandardString(32) == "32")
}

@Test func locationAttributeSnapsToTheHalfGrid() throws {
  let location: Attribute<Location> = Attributes.forLocation("loc")
  let ten20 = Location.create(10, 20, hasToSnap: true)
  #expect(try location.parse("(10,20)") == ten20)
  #expect(try location.parse(" 10 , 20 ") == ten20)
  #expect(try location.parse("10 20") == ten20)
  // Java's Math.round(x / 5) * 5 truncates rather than rounding.
  #expect(try location.parse("(13,19)") == Location.create(10, 15, hasToSnap: true))
  #expect(location.toStandardString(ten20) == "(10,20)")
}

@Test func bridgedBitWidthAndDirectionAttributesRoundTrip() throws {
  let width: Attribute<BitWidth> = Attributes.forBitWidth("width")
  #expect(try width.parse("8") == BitWidth.known(8))
  #expect(width.encode(BitWidth.known(8)) == .bitWidth(8))
  #expect(width.toStandardString(BitWidth.known(16)) == "16")
  #expect(throws: AttributeParseError.self) { try width.parse("65") }

  let facing: Attribute<Direction> = Attributes.forDirection("facing")
  #expect(try facing.parse("north") == Direction.north)
  #expect(facing.encode(.west) == .direction(.west))
  #expect(facing.toStandardString(.south) == "south")
}

private enum TestAppearance: String, AttributeOptionValue, CaseIterable {
  case classic
  case evolution
}

@Test func nativeEnumOptionsRoundTrip() throws {
  let attribute: Attribute<TestAppearance> = Attributes.forOption("appearance")
  #expect(try attribute.parse("evolution") == .evolution)
  #expect(throws: AttributeParseError.self) { try attribute.parse("nonesuch") }
  #expect(attribute.toStandardString(.classic) == "classic")
  #expect(attribute.decode(attribute.encode(.evolution)) == .evolution)
}

@Test func javaShapedOptionsRoundTrip() throws {
  let choices = [AttributeOption(value: "ignore"), AttributeOption(value: "error")]
  let attribute = Attributes.forOption("undefined", choices: choices)
  #expect(try attribute.parse("error") == choices[1])
  #expect(throws: AttributeParseError.self) { try attribute.parse("shrug") }
  #expect(attribute.toStandardString(choices[0]) == "ignore")
}

// MARK: - Attribute sets

@Test func attributeIdentityIsReferenceIdentity() {
  let a = Attributes.forString("label")
  let b = Attributes.forString("label")
  #expect(a !== b)
  #expect(a != b)
  #expect(a == a)
}

@Test func fixedSetStoresAndReadsTypedValues() throws {
  let label = Attributes.forString("label")
  let width: Attribute<Int32> = Attributes.forBitWidth("width")
  let facing: Attribute<AttributeValue.Direction> = Attributes.forDirection("facing")

  let set = AttributeSets.fixedSet([
    label.binding(""), width.binding(1), facing.binding(.east),
  ])
  #expect(set is FixedAttributeSet)
  #expect(set[label] == "")
  #expect(set[width] == 1)

  try set.setValue(width, 8)
  #expect(set[width] == 8)
  #expect(set.rawValue(width) == .bitWidth(8))

  // A different attribute of the same kind is simply absent.
  let otherWidth: Attribute<Int32> = Attributes.forBitWidth("width")
  #expect(set[otherWidth] == nil)
  #expect(set.containsAttribute(width))
  #expect(!set.containsAttribute(otherWidth))
  #expect(set.attribute(named: "facing") === facing)
}

@Test func singleAttributeSetDegradesToSingletonAndEmptyToEmpty() {
  let label = Attributes.forString("label")
  let single = AttributeSets.fixedSet([label.binding("hi")])
  #expect(single is SingletonAttributeSet)
  #expect(single[label] == "hi")
  #expect(AttributeSets.fixedSet([]) === EmptyAttributeSet.shared)
}

@Test func readOnlyFlagsFollowUpstreamsQuirks() {
  let a = Attributes.forString("a")
  let b = Attributes.forString("b")
  let absent = Attributes.forString("c")
  let set = AttributeSets.fixedSet([a.binding("1"), b.binding("2")])

  #expect(!set.isReadOnly(a))
  set.setReadOnly(a, true)
  #expect(set.isReadOnly(a))
  #expect(!set.isReadOnly(b))
  // Upstream reports an absent attribute as read-only.
  #expect(set.isReadOnly(absent))
}

@Test func copyIsDetachedAndDoesNotCarryListeners() throws {
  let a = Attributes.forString("a")
  let original = AttributeSets.fixedSet([a.binding("1"), Attributes.forString("b").binding("2")])
  var fired = 0
  let token = original.addAttributeListener(onValueChanged: { _ in fired += 1 })

  let clone = original.copy()
  try clone.setValue(a, "changed")
  #expect(original[a] == "1")
  #expect(clone[a] == "changed")
  #expect(fired == 0)

  try original.setValue(a, "also changed")
  #expect(fired == 1)
  token.cancel()
  try original.setValue(a, "again")
  #expect(fired == 1)
}

@Test func droppingTheSubscriptionUnsubscribes() throws {
  let a = Attributes.forString("a")
  let set = AttributeSets.fixedSet([a.binding("1"), Attributes.forString("b").binding("2")])
  var fired = 0
  do {
    let token = set.addAttributeListener(onValueChanged: { _ in fired += 1 })
    try set.setValue(a, "x")
    #expect(fired == 1)
    _ = token
  }
  // The token went out of scope, so the registration is gone with it: no explicit
  // removeAttributeListener call anywhere.
  try set.setValue(a, "y")
  #expect(fired == 1)
}

@Test func eventsCarryTypedOldAndNewValues() throws {
  let width: Attribute<Int32> = Attributes.forBitWidth("width")
  let set = AttributeSets.fixedSet([width.binding(1), Attributes.forString("b").binding("")])
  var seen: (Int32?, Int32?)?
  let token = set.addAttributeListener(onValueChanged: { event in
    seen = (event.oldValue(as: width), event.value(as: width))
  })
  try set.setValue(width, 16)
  #expect(seen?.0 == 1)
  #expect(seen?.1 == 16)
  token.cancel()
}

@Test func attributeSetsCopyTransfersEveryValue() throws {
  let a = Attributes.forString("a")
  let b: Attribute<Int32> = Attributes.forBitWidth("b")
  let source = AttributeSets.fixedSet([a.binding("src"), b.binding(4)])
  let destination = AttributeSets.fixedSet([a.binding(""), b.binding(1)])

  try AttributeSets.copy(from: source, to: destination)
  #expect(destination[a] == "src")
  #expect(destination[b] == 4)
}

@Test func emptySetIsInertButNotFatal() throws {
  let a = Attributes.forString("a")
  let empty = AttributeSets.empty
  try empty.setValue(a, "ignored")
  #expect(empty[a] == nil)
  #expect(empty.attributes.isEmpty)
  #expect(empty.isReadOnly(a))
  #expect(empty.copy() === EmptyAttributeSet.shared)
}

@Test func notSavedAttributesAreExcludedFromTheSaveList() {
  let saved = Attributes.forString("saved")
  let scratch = Attributes.forNoSave("scratch")
  let set = AttributeSets.fixedSet([saved.binding("x"), scratch.binding(0)])
  #expect(set.savedAttributes.map(\.name) == ["saved"])
  #expect(Attributes.forMap("iomap").isHidden)
  #expect(!Attributes.forMap("iomap").isToSave)
}

@Test func erasedCodecPathIsWhatTheCircWriterWillUse() throws {
  let width: Attribute<Int32> = Attributes.forBitWidth("width")
  let erased: AnyAttribute = width
  let stored = try erased.parseToAttributeValue("8")
  #expect(stored == .bitWidth(8))
  #expect(erased.standardString(for: stored) == "8")
  // A value belonging to a different attribute kind is rejected rather than mis-rendered.
  #expect(erased.standardString(for: .string("8")) == nil)
  #expect(!erased.accepts(.string("8")))
}
