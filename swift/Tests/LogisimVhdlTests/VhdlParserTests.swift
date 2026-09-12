// VhdlParserTests: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// Every expectation here is the observed behaviour of the Java `VhdlParser`
// (com.cburch.logisim.vhdl.base.VhdlParser), including cases that are upstream defects;
// see VhdlParser.swift's header for the full list. A "fix" that breaks one of these is a
// fidelity regression, not an improvement.

import Testing

@testable import LogisimVhdl

private func parsed(_ source: String) throws -> VhdlParser {
  let parser = VhdlParser(source: source)
  try parser.parse()
  return parser
}

// MARK: - Happy path

@Test func parsesEntityNamePortsAndGenerics() throws {
  let source = """
    library ieee;
    use ieee.std_logic_1164.all;

    entity adder is
      generic (
        WIDTH : positive := 4
      );
      port (
        a : in std_logic_vector(3 downto 0);
        b : in std_logic_vector(3 downto 0);
        cin : in std_logic;
        sum : out std_logic_vector(3 downto 0);
        cout : out std_logic
      );
    end adder;

    architecture behavioral of adder is
    begin
    end behavioral;
    """
  let parser = try parsed(source)

  #expect(parser.name == "adder")
  #expect(parser.inputs.map(\.name) == ["a", "b", "cin"])
  #expect(parser.outputs.map(\.name) == ["sum", "cout"])
  #expect(parser.inputs[0].width.width == 4)
  #expect(parser.inputs[2].width.width == 1)
  #expect(parser.outputs[0].width.width == 4)
  #expect(parser.generics.count == 1)
  #expect(parser.generics[0].name == "WIDTH")
  #expect(parser.generics[0].type == "positive")
  #expect(parser.generics[0].defaultValue == 4)
  // `architecture` is captured as the *entire* remaining match, including whatever leading
  // whitespace the greedy `architecture .*` pattern absorbed before the keyword: matching
  // Java's `input.match().group()` (group 0), not just the semantic clause text.
  #expect(
    parser.architecture.trimmingCharacters(in: .whitespacesAndNewlines)
      .hasPrefix("architecture behavioral of adder is"))
  #expect(parser.libraries.contains("library ieee;"))
  #expect(parser.libraries.contains("use ieee.std_logic_1164.all;"))
}

@Test func multiNamePortAndGenericDeclarationsExpandPerName() throws {
  let source = """
    entity multi is
      generic (
        A, B : natural := 2
      );
      port (
        x, y, z : in std_logic;
        o : out std_logic
      );
    end multi;
    architecture a of multi is begin end a;
    """
  let parser = try parsed(source)
  #expect(parser.inputs.map(\.name) == ["x", "y", "z"])
  #expect(parser.generics.map(\.name) == ["A", "B"])
  #expect(parser.generics.allSatisfy { $0.defaultValue == 2 && $0.type == "natural" })
}

@Test func commentsAreStrippedToEndOfLine() throws {
  let source = """
    -- a leading file comment
    entity c is -- trailing comment
      port ( -- another comment
        x : in std_logic -- yet another
      );
    end c; -- final comment
    architecture a of c is begin end a; -- last
    """
  let parser = try parsed(source)
  #expect(parser.name == "c")
  #expect(parser.inputs.map(\.name) == ["x"])
}

@Test func endEntityKeywordFormIsAccepted() throws {
  let source = """
    entity e is
      port ( x : in std_logic );
    end entity e;
    architecture a of e is begin end a;
    """
  let parser = try parsed(source)
  #expect(parser.name == "e")
}

@Test func bareEndSemicolonIsAccepted() throws {
  let source = """
    entity e is
      port ( x : in std_logic );
    end;
    architecture a of e is begin end a;
    """
  let parser = try parsed(source)
  #expect(parser.name == "e")
}

// MARK: - Faithfully-preserved bugs (see VhdlParser.swift's header)

@Test func theWordInputIsMisreadAsInoutAndFiledUnderOutputs() throws {
  // The real VHDL keyword `inout` is never produced by `getPortType`: only the mistaken
  // literal token "input" maps to `.inout_`, and Java's `parsePort` files anything that is
  // not exactly `.input` into `outputs`.
  let source = """
    entity e is
      port ( x : input std_logic );
    end e;
    architecture a of e is begin end a;
    """
  let parser = try parsed(source)
  #expect(parser.inputs.isEmpty)
  #expect(parser.outputs.map(\.name) == ["x"])
  #expect(parser.outputs[0].direction == .inout_)
}

@Test func theActualVhdlKeywordInoutIsRejected() {
  let source = """
    entity e is
      port ( x : inout std_logic );
    end e;
    architecture a of e is begin end a;
    """
  #expect(throws: VhdlParserError.self) { try parsed(source) }
}

@Test func unsupportedPortTypeIsRejected() {
  let source = """
    entity e is
      port ( x : in bit );
    end e;
    architecture a of e is begin end a;
    """
  #expect(throws: VhdlParserError.unsupportedPortType("bit")) { try parsed(source) }
}

@Test func unsupportedGenericTypeIsRejected() {
  let source = """
    entity e is
      generic ( x : boolean );
      port ( y : in std_logic );
    end e;
    architecture a of e is begin end a;
    """
  #expect(throws: VhdlParserError.unsupportedGenericType("boolean")) { try parsed(source) }
}

@Test func timeGenericAppliesUnitMultiplier() throws {
  let source = """
    entity e is
      generic ( t : time := 5 ns );
      port ( y : in std_logic );
    end e;
    architecture a of e is begin end a;
    """
  let parser = try parsed(source)
  #expect(parser.generics[0].defaultValue == 5_000_000)
}

@Test func unrecognizedTimeUnitMessageInterpolatesTheNumberNotTheUnit() {
  // Bug-for-bug: Java's message is "Unrecognized time unit: " + dval (the *parsed number*),
  // not the offending unit token: a copy/paste bug preserved deliberately.
  let source = """
    entity e is
      generic ( t : time := 5 xyz );
      port ( y : in std_logic );
    end e;
    architecture a of e is begin end a;
    """
  #expect(throws: VhdlParserError.unrecognizedTimeUnit(5)) { try parsed(source) }
}

@Test func naturalGenericRejectsNegativeDefault() {
  let source = """
    entity e is
      generic ( n : natural := -1 );
      port ( y : in std_logic );
    end e;
    architecture a of e is begin end a;
    """
  // Note: "-1" cannot be captured by DVALUE's `(\w+)` group (`-` is not a word character), so
  // this in fact fails earlier than the natural-range check, at the generic-default parse;
  // both are `unrecognizedGenericDefault` errors, so the observable failure mode matches.
  #expect(throws: VhdlParserError.self) { try parsed(source) }
}

@Test func positiveGenericRejectsZeroDefault() {
  let source = """
    entity e is
      generic ( n : positive := 0 );
      port ( y : in std_logic );
    end e;
    architecture a of e is begin end a;
    """
  #expect(throws: VhdlParserError.unrecognizedGenericDefault("0")) { try parsed(source) }
}

// MARK: - Failure paths

@Test func missingEntityDeclarationIsRejected() {
  #expect(throws: VhdlParserError.cannotFindEntity) {
    try parsed("architecture a of x is begin end a;")
  }
}

@Test func mismatchedEndNameIsRejected() {
  let source = """
    entity foo is
      port ( x : in std_logic );
    end bar;
    architecture a of foo is begin end a;
    """
  #expect(throws: VhdlParserError.cannotFindEntity) { try parsed(source) }
}

@Test func trailingGarbageAfterArchitectureIsAccepted() throws {
  // `ARCHITECTURE` is matched with a greedy `.*` under DOTALL, so it always consumes to the
  // true end of input; there is no observable "trailing garbage after architecture" input;
  // this test documents that the remaining-input check can only ever fire when there is no
  // "architecture" clause at all after a *successful* entity/port parse (`end` matched but no
  // architecture keyword afterwards), because architecture is otherwise absorbing.
  let source = """
    entity foo is
      port ( x : in std_logic );
    end foo;
    -- no architecture keyword follows, just trailing prose
    not architecture syntax at all
    """
  #expect(throws: VhdlParserError.cannotFindEntity) { try parsed(source) }
}

@Test func nullSourceProducesEmptySourceError() {
  #expect(throws: VhdlParserError.emptySource) { try parsed(nil) }
}

private func parsed(_ source: String?) throws -> VhdlParser {
  let parser = VhdlParser(source: source)
  try parser.parse()
  return parser
}

// MARK: - `Integer.decode` reconstruction

@Test func javaIntegerDecodeHandlesEveryRadixPrefix() throws {
  #expect(try javaIntegerDecode("123") == 123)
  #expect(try javaIntegerDecode("0x1A") == 0x1A)
  #expect(try javaIntegerDecode("0X1a") == 0x1A)
  #expect(try javaIntegerDecode("#FF") == 0xFF)
  #expect(try javaIntegerDecode("010") == 8)  // leading zero => octal
  #expect(try javaIntegerDecode("0") == 0)  // a single "0" is decimal, not octal
  #expect(try javaIntegerDecode("-5") == -5)
  #expect(try javaIntegerDecode("+5") == 5)
  #expect(throws: (any Error).self) { try javaIntegerDecode("not-a-number") }
}
