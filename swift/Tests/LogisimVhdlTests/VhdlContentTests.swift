// VhdlContentTests: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import Testing

@testable import LogisimKernel
@testable import LogisimVhdl

// MARK: - VhdlContent.create / template

@Test func createBuildsAValidEntityFromTheBuiltInTemplate() {
  let content = VhdlContent.create(name: "MyEntity")
  #expect(content.isValid)
  #expect(content.name == "MyEntity")
  #expect(content.ports.map(\.name) == ["clock", "val", "max", "cpt"])
  #expect(content.ports[0].width.width == 1)
  #expect(content.ports[1].width.width == 4)
  #expect(content.lastValidationError == nil)
}

@Test func parseSurfacesAStructuredErrorInsteadOfADialog() {
  let content = VhdlContent.parse(name: "Broken", vhdl: "not vhdl at all")
  #expect(!content.isValid)
  #expect(content.lastValidationError != nil)
  #expect(content.lastValidationError?.title == "VHDL Parsing Error")
}

@Test func compareIgnoresLineEndingDifferences() {
  let content = VhdlContent.create(name: "E")
  #expect(content.compare(toContent: content.content.replacingOccurrences(of: "\n", with: "\r\n")))
  #expect(!content.compare(toContent: "completely different"))
}

/// Regression test for the missing-trailing-newline defect: Java's `loadTemplate()`
/// (`VhdlContent.java`) appends `System.getProperty("line.separator")` after EVERY line
/// read from `resources/logisim/hdl/vhdl_component.templ`, including the last one, so the
/// resulting `TEMPLATE` constant, and therefore every freshly created component's
/// `<vhdl>` content, ends in a newline. A Swift `"""..."""` literal drops the newline
/// before its closing delimiter unless a blank line is left before it; pin the exact byte
/// count of the upstream resource (1220 bytes) after `%entityname%` substitution so this
/// cannot silently regress by one byte again.
///
/// Byte accounting for `name: "foo"`: the raw resource is 1220 bytes (`wc -c
/// vhdl_component.templ`) and contains three occurrences of the 12-character
/// `%entityname%` placeholder, each replaced by the 3-character name `"foo"`, for a total
/// of 1220 - 3 * (12 - 3) = 1193 bytes.
@Test func createdTemplateMatchesTheUpstreamResourceByteForByteIncludingTheTrailingNewline() {
  let content = VhdlContent.create(name: "foo")
  #expect(content.content.utf8.count == 1193)
  #expect(content.content.hasSuffix("\n"))
}

// MARK: - setName / renaming

@Test func setNameRewritesEntityArchitectureAndEndClauses() {
  let content = VhdlContent.create(name: "Old")
  // "New" is deliberately not used here; it is one of the 96 reserved VHDL keywords
  // (`vhdlKeywords`), so `setName("New")` is *correctly* rejected; see
  // `setNameRejectsReservedKeyword` below for that case.
  #expect(content.setName("Updated"))
  #expect(content.name == "Updated")
  #expect(content.content.range(of: "entity Updated is", options: .caseInsensitive) != nil)
  #expect(content.content.range(of: "end Updated;", options: .caseInsensitive) != nil)
  #expect(content.content.range(of: "of Updated is", options: .caseInsensitive) != nil)
  #expect(content.content.range(of: "Old", options: .caseInsensitive) == nil)
}

@Test func setNameRejectsInvalidSyntax() {
  let content = VhdlContent.create(name: "Old")
  #expect(!content.setName("1bad"))
  #expect(content.name == "Old")
}

@Test func setNameRejectsReservedKeyword() {
  let content = VhdlContent.create(name: "Old")
  #expect(!content.setName("entity"))
  #expect(content.name == "Old")
}

private final class FakeNameCollisionChecker: VhdlNameCollisionChecking {
  var takenNames: Set<String> = []
  func containsFactory(named name: String) -> Bool { takenNames.contains(name) }
}

@Test func setNameChecksCollisionsOnlyWhenTheNameActuallyChanges() {
  let checker = FakeNameCollisionChecker()
  checker.takenNames = ["Old", "Taken"]
  let content = VhdlContent.create(name: "Old", nameCollisionChecker: checker)
  // Java: re-validating the *unchanged* name is checked with a null file, so a component
  // never collides with its own already-registered name.
  #expect(content.isValid)

  #expect(!content.setName("Taken"))
  #expect(content.setName("Free"))
  #expect(content.name == "Free")
}

@Test func isInvalidVhdlLabelMatchesJavaShapeRules() {
  #expect(VhdlContent.isInvalidVhdlLabel("1abc"))  // must start with a letter
  #expect(VhdlContent.isInvalidVhdlLabel("abc_"))  // no trailing underscore
  #expect(VhdlContent.isInvalidVhdlLabel("a__b"))  // no double underscore
  #expect(VhdlContent.isInvalidVhdlLabel("entity"))  // reserved word
  #expect(!VhdlContent.isInvalidVhdlLabel("Adder_4Bit"))
}

// MARK: - Generic identity reuse across re-parse (faithful bug: stale default value)

@Test func unchangedGenericNameAndTypeKeepsTheOldDefaultValueAcrossAReparse() {
  let content = VhdlContent.parse(
    name: "g",
    vhdl: """
      entity g is
        generic ( W : positive := 4 );
        port ( x : in std_logic );
      end g;
      architecture a of g is begin end a;
      """)
  #expect(content.isValid)
  #expect(content.generics.count == 1)
  let originalGeneric = content.generics[0]
  let originalAttribute = content.genericAttributes[0]
  #expect(originalGeneric.defaultValue == 4)

  // Same name, same type, but a different `:=` value in the source.
  #expect(
    content.setContent(
      """
      entity g is
        generic ( W : positive := 9 );
        port ( x : in std_logic );
      end g;
      architecture a of g is begin end a;
      """))

  // Faithful bug (see VhdlContent.setContent's comment): the OLD Generic object, and its OLD
  // default value, is kept because name+type didn't change, even though the source now says
  // 9. The attribute identity is also reused (matters for any UI/state keyed on it).
  #expect(content.generics[0] === originalGeneric)
  #expect(content.generics[0].defaultValue == 4)
  #expect(content.genericAttributes[0].attribute === originalAttribute.attribute)
}

@Test func renamingAGenericAssignsAFreshDefaultValue() {
  let content = VhdlContent.parse(
    name: "g",
    vhdl: """
      entity g is
        generic ( W : positive := 4 );
        port ( x : in std_logic );
      end g;
      architecture a of g is begin end a;
      """)
  #expect(
    content.setContent(
      """
      entity g is
        generic ( W2 : positive := 9 );
        port ( x : in std_logic );
      end g;
      architecture a of g is begin end a;
      """))
  #expect(content.generics[0].name == "W2")
  #expect(content.generics[0].defaultValue == 9)
}

// MARK: - VhdlEntityAttributes

@Test func attributeSetExposesNameLabelAndAppearance() throws {
  let content = VhdlContent.create(name: "E")
  let attrs = VhdlEntityAttributes(content: content)

  #expect(attrs.getValue(VhdlEntityAttributes.nameAttribute) == "E")
  #expect(attrs.getValue(VhdlEntityAttributes.labelAttribute) == "")
  #expect(attrs.getValue(VhdlEntityAttributes.appearanceAttribute) == VhdlAppearanceStyle.evolution)

  try attrs.setValue(VhdlEntityAttributes.labelAttribute, "inst1")
  #expect(attrs.getValue(VhdlEntityAttributes.labelAttribute) == "inst1")

  try attrs.setValue(VhdlEntityAttributes.appearanceAttribute, VhdlAppearanceStyle.classic)
  #expect(content.appearance == VhdlAppearanceStyle.classic)
}

@Test func settingTheNameAttributeRenamesTheUnderlyingContent() throws {
  let content = VhdlContent.create(name: "E")
  let attrs = VhdlEntityAttributes(content: content)
  try attrs.setValue(VhdlEntityAttributes.nameAttribute, "Renamed")
  #expect(content.name == "Renamed")
  #expect(attrs.getValue(VhdlEntityAttributes.nameAttribute) == "Renamed")
}

@Test func simNameAttributeIsHiddenAndExcludedFromSaving() {
  #expect(VhdlEntityAttributes.simNameAttribute.isHidden)
  let content = VhdlContent.create(name: "E")
  let attrs = VhdlEntityAttributes(content: content)
  #expect(!attrs.isToSave(VhdlEntityAttributes.simNameAttribute))
  #expect(attrs.isToSave(VhdlEntityAttributes.labelAttribute))
}

@Test func genericAttributeRoundTripsThroughTheSentinelDefaultValue() throws {
  let content = VhdlContent.parse(
    name: "g",
    vhdl: """
      entity g is
        generic ( W : positive := 4 );
        port ( x : in std_logic );
      end g;
      architecture a of g is begin end a;
      """)
  let attrs = VhdlEntityAttributes(content: content)
  let generic = content.genericAttributes[0].attribute

  // Never explicitly set: reads back nil (Java: `genericValues.containsKey` false).
  #expect(attrs.getValue(generic) == nil)

  try attrs.setValue(generic, 7)
  #expect(attrs.getValue(generic) == 7)

  // Explicitly reset to "use the default": Java's parse() maps "default"/"(default)"/
  // "(default) N" to `null`.
  let parsedDefault = try generic.parse("default")
  #expect(parsedDefault == nil)
  try attrs.setValue(generic, parsedDefault)
  let resolved: Int32?? = attrs.getValue(generic)
  #expect(resolved == Int32??.some(nil))
}

// MARK: - VhdlEntity HDL-name derivation

@Test func hdlNameIsTheLowercasedEntityName() {
  let content = VhdlContent.create(name: "MyEntity")
  #expect(VhdlEntity.hdlName(for: content) == "myentity")
}

@Test func hdlTopNameAppendsTheLowercasedLabelWhenPresent() throws {
  let content = VhdlContent.create(name: "MyEntity")
  let attrs = VhdlEntityAttributes(content: content)
  #expect(VhdlEntity.hdlTopName(using: attrs) == "myentity")

  try attrs.setValue(VhdlEntityAttributes.labelAttribute, "Inst1")
  #expect(VhdlEntity.hdlTopName(using: attrs) == "myentity_inst1")
}

@Test func setSimNameUsesTheLabelWhenPresentOtherwiseTheGivenName() throws {
  let content = VhdlContent.create(name: "MyEntity")
  let attrs = VhdlEntityAttributes(content: content)

  #expect(VhdlEntity.setSimName(attrs, to: "sim0"))
  #expect(VhdlEntity.simName(attrs) == "sim0")

  try attrs.setValue(VhdlEntityAttributes.labelAttribute, "Inst1")
  #expect(VhdlEntity.setSimName(attrs, to: "sim0"))
  #expect(VhdlEntity.simName(attrs) == "myentity_inst1")
}

// MARK: - HdlModelListenerRegistry (D3-style token subscriptions)

private final class RecordingListener: HdlModelListener {
  var contentSetCount = 0
  func contentSet(_ source: HdlModel) { contentSetCount += 1 }
}

@Test func listenerFiresWhileTokenIsRetainedAndStopsAfterCancellation() {
  let content = VhdlContent.create(name: "E")
  let listener = RecordingListener()
  var token: HdlModelSubscription? = content.addHdlModelListener(listener)
  _ = token  // silence "never read" — retained deliberately

  content.setContent(content.content + "\n")  // whitespace-only edit; still calls setContent
  #expect(listener.contentSetCount >= 1)

  let countBeforeCancel = listener.contentSetCount
  token?.cancel()
  token = nil
  content.setContent(content.content + "\n")
  #expect(listener.contentSetCount == countBeforeCancel)
}

@Test func droppingTheTokenWithoutCancellingAlsoUnsubscribes() {
  let content = VhdlContent.create(name: "E")
  let listener = RecordingListener()
  do {
    let token = content.addHdlModelListener(listener)
    _ = token
  }
  // The token has now deinitialised and cancelled itself; no crash, no further delivery.
  content.setContent(content.content + "\n")
  #expect(listener.contentSetCount == 0)
}
