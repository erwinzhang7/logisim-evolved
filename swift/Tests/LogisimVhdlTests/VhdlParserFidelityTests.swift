// VhdlParserFidelityTests: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// These tests exist for one property: **a source upstream rejects must be rejected here.**
// Every case below was accepted by the port and rejected by Java before the character-class
// and `Integer.parseInt` fixes, i.e. each is a regression test for a real divergence, not a
// hypothetical.
//
// Java's side is **measured, not inferred.** Each expectation below was run through
// `com.cburch.logisim.vhdl.base.VhdlParser` in the real 4.1.0 jar
// (`/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar`, JDK 21),
// and this is what it printed:
//
//     ascii            -> ACCEPT name=foo inputs[x=1]
//     accented-entity  -> REJECT IllegalVhdlContentException: The entity declaration cannot be found
//     accented-port    -> REJECT IllegalVhdlContentException: Illegal port syntax
//     nbsp             -> REJECT IllegalVhdlContentException: The entity declaration cannot be found
//     vt-ff            -> ACCEPT name=foo inputs[x=1]
//     range-ascii      -> ACCEPT name=foo inputs[bus=8]
//     range-arabic     -> REJECT IllegalVhdlContentException: Illegal port syntax
//     range-overflow   -> REJECT NumberFormatException: For input string: "3000000000"
//     range-intmax     -> REJECT IllegalArgumentException: width -2147483648 must be positive
//     range-reversed   -> REJECT IllegalArgumentException: width -6 must be positive
//     bad-port-type    -> REJECT IllegalVhdlContentException: Unsupported port type: “integer”…
//     bad-direction    -> REJECT IllegalVhdlContentException: Invalid port type: buffer
//     empty            -> REJECT IllegalVhdlContentException: The entity declaration cannot be found
//     no-entity        -> REJECT IllegalVhdlContentException: The entity declaration cannot be found
//
// Note `range-intmax`: `width -2147483648` is the 32-bit wrap of `2147483647 - 0 + 1` observed
// in the running JVM, which is the direct evidence for doing that subtraction in `Int32` with
// `&-`/`&+` rather than in `Int`.

import Foundation
import Testing

@testable import LogisimKernel
@testable import LogisimVhdl

/// The minimal source shape this parser accepts, with a substitutable body.
private func source(entity: String = "foo", ports: String = "a : in std_logic") -> String {
  """
  entity \(entity) is
    port (
      \(ports)
      );
  end \(entity);
  """
}

private func parses(_ text: String) -> Bool {
  let parser = VhdlParser(source: text)
  do {
    try parser.parse()
    return true
  } catch {
    return false
  }
}

/// The rejection message, or nil if the source parsed. Any error type; the point is what the
/// user is shown, and `VhdlContent.setContent`'s `catch (Exception ex)` erases the type anyway.
private func rejection(_ text: String) -> String? {
  do {
    try VhdlParser(source: text).parse()
    return nil
  } catch let error as VhdlParserError {
    return error.message
  } catch let error as BitWidthParseError {
    return error.description
  } catch {
    return String(describing: error)
  }
}

// MARK: - ASCII \w: entity and port names

@Test func aPlainAsciiEntityStillParses() {
  #expect(parses(source()))
}

@Test func anEntityNameWithANonAsciiLetterIsRejectedAsJavaRejectsIt() {
  // ICU's `\w` matches every alphabetic scalar, so `caf\u{e9}` used to parse. Java's `\w+`
  // stops at `caf`, then requires `\s+is` and sees `\u{e9}`, so `ENTITY` never matches and
  // upstream throws `CannotFindEntityException`.
  #expect(rejection(source(entity: "caf\u{e9}")) == "The entity declaration cannot be found")
}

@Test func aPortNameWithANonAsciiLetterIsRejected() {
  #expect(rejection(source(ports: "\u{e9}tat : in std_logic")) == "Illegal port syntax")
}

// MARK: - ASCII \s: what counts as the whitespace between tokens

@Test func aNonBreakingSpaceIsNotWhitespaceToJavaAndSoIsRejectedHere() {
  // Very reachable: U+00A0 is what a copy-paste out of a rendered web page or a PDF leaves
  // behind. ICU's `\s` includes `\p{Z}` and matched it; Java's does not.
  #expect(
    rejection("entity\u{00A0}foo is\n  port (\n    a : in std_logic\n    );\nend foo;")
      == "The entity declaration cannot be found")
}

@Test func verticalTabAndFormFeedAreWhitespaceToBothEngines() {
  // The two characters Java's `\s` has that are easy to forget; `\x0B` in particular is not in
  // Foundation's `.whitespacesAndNewlines`, which is why `javaTrim` is used instead.
  #expect(parses("entity\u{0B}foo\u{0C}is\n  port (\n    a : in std_logic\n    );\nend foo;"))
}

// MARK: - ASCII \d: the bus range

@Test func anAsciiBusRangeGivesTheExpectedWidth() throws {
  let parser = VhdlParser(source: source(ports: "bus : in std_logic_vector(7 downto 0)"))
  try parser.parse()
  #expect(parser.inputs.first?.width.width == 8)
}

@Test func aBusRangeInArabicIndicDigitsIsRejected() {
  // ICU's `\d` is `\p{Nd}`, so U+0663/U+0660 matched `RANGE` and then `Integer.parseInt` had
  // never been reached. Java's `\d` is `[0-9]`, so `RANGE` does not match and `parsePort`
  // throws `portDeclarationException`.
  #expect(
    rejection(source(ports: "bus : in std_logic_vector(\u{0663} downto \u{0660})"))
      == "Illegal port syntax")
}

// MARK: - Integer.parseInt is 32-bit and throws

@Test func aBusRangeBeyondIntMaxIsRejectedWithJavasNumberFormatMessage() {
  let parser = VhdlParser(source: source(ports: "bus : in std_logic_vector(3000000000 downto 0)"))
  #expect(throws: VhdlParserError.numberFormat("3000000000")) { try parser.parse() }
}

@Test func aBusRangeThatOverflowsTheWidthSubtractionIsRejected() {
  // Java computes `upper - lower + 1` in 32-bit `int`: 2147483647 - 0 + 1 wraps to
  // Integer.MIN_VALUE, and `BitWidth.create` rejects it. With 64-bit arithmetic the width
  // would instead be 2147483648, which `BitWidth.create` also rejects: same verdict, but by
  // accident. The wrap is reproduced so the verdict is by construction.
  #expect(
    rejection(source(ports: "bus : in std_logic_vector(2147483647 downto 0)"))
      == "width -2147483648 must be positive")
}

@Test func aReversedRangeGivesANonPositiveWidthAndIsRejected() {
  // `(0 downto 7)` → width -6. Java's `BitWidth.create` throws `IllegalArgumentException`,
  // which `VhdlContent.setContent` catches; D13 says throw rather than trap.
  #expect(rejection(source(ports: "bus : in std_logic_vector(0 downto 7)")) == "width -6 must be positive")
}

// MARK: - The messages upstream shows, verbatim

@Test func parseErrorsCarryUpstreamsEnglishStrings() {
  let message = rejection
  #expect(message("no entity here") == "The entity declaration cannot be found")
  #expect(
    message(source(ports: "a : in integer"))
      == "Unsupported port type: \u{201C}integer\u{201D}. Please only use "
        + "\u{201C}std_logic\u{201D} and \u{201C}std_logic_vector\u{201D}.")
  #expect(message(source(ports: "a : buffer std_logic")) == "Invalid port type: buffer")
}

@Test func aNilSourceIsTheOnlyPathToTheEmptySourceMessage() {
  // Java reaches `emptySourceException` only from `new StringBuilder(null)`'s NPE; an empty
  // *string* falls through to `CannotFindEntityException`.
  #expect(throws: VhdlParserError.emptySource) { try VhdlParser(source: nil).parse() }
  #expect(throws: VhdlParserError.cannotFindEntity) { try VhdlParser(source: "").parse() }
}

// MARK: - VhdlEntity's simulation-source transform

@Test func simulationSourceRewritesEveryOccurrenceOfTheEntityNameNotJustTheDeclaration() {
  // Upstream's `content.replaceAll("(?i)" + getHDLName(attrs), getSimName(attrs))` has no word
  // boundary, so an identifier that merely *contains* the entity name is rewritten too. That is
  // a bug, and it is reproduced because it decides the bytes handed to an external compiler.
  let content = VhdlContent.parse(
    name: "foo",
    vhdl: """
      entity foo is
        port (
          food : in std_logic
          );
      end foo;
      architecture a of foo is begin end a;
      """)
  #expect(content.isValid)
  let rewritten = VhdlEntity.simulationSource(content: content, simulationName: "SimComp_0")
  #expect(rewritten.contains("entity SimComp_0 is"))
  #expect(rewritten.contains("SimComp_0d : in std_logic"))
  #expect(!rewritten.lowercased().contains("foo"))
}

@Test func theFactoryNameFallsBackToTheLiteralVhdlEntity() {
  #expect(VhdlEntity.name(for: nil) == "VHDL Entity")
  #expect(VhdlEntity.name(for: VhdlContent.create(name: "Adder")) == "Adder")
}
