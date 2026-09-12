import Testing
@testable import LogisimFile

@Suite("Java String.split literal-character compatibility")
struct JavaSplitOnLiteralTests {
  @Test func emptyInputIsOneEmptyElement() {
    #expect(javaSplitOnLiteral("", separator: ",") == [""])
  }

  @Test func trailingSeparatorsAreRemoved() {
    #expect(javaSplitOnLiteral("a,", separator: ",") == ["a"])
    #expect(javaSplitOnLiteral("a,,", separator: ",") == ["a"])
  }

  @Test func absentSeparatorLeavesInputUnchanged() {
    #expect(javaSplitOnLiteral("a", separator: ",") == ["a"])
  }

  @Test func consecutiveSeparatorsKeepInteriorEmptyElements() {
    #expect(javaSplitOnLiteral("a,,b", separator: ",") == ["a", "", "b"])
  }

  @Test func leadingSeparatorKeepsLeadingEmptyElement() {
    #expect(javaSplitOnLiteral(",a", separator: ",") == ["", "a"])
  }

  @Test func separatorOnlyProducesNoElements() {
    #expect(javaSplitOnLiteral(",", separator: ",").isEmpty)
  }

  @Test func semanticsApplyToUnderscoreCallSite() {
    #expect(javaSplitOnLiteral("1__2_", separator: "_") == ["1", "", "2"])
  }
}
