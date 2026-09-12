// JavaSplitSemanticsTests: part of logisim-evolved.
//
// Pins `LogisimHdl`'s `javaSplit` to what `java.lang.String.split(String)` actually does.
//
// WHY THIS FILE EXISTS
// --------------------
// Four component families (gates/wiring/plexers, arithmetic, memory, io) were ported in parallel
// against the 4.1.0 jar, and all four independently reported the same framework defect: Java's
// one-argument `split` uses limit 0, which DISCARDS TRAILING EMPTY FIELDS, while Swift's
// `split(separator:omittingEmptySubsequences: false)` keeps them. Every multi-line `add(…)`
// gained a blank line in the emitted HDL.
//
// The first fix for that was WRONG, and this file exists because of how it was wrong. It guarded
// with `count > 1`, on the plausible-sounding theory that "one empty field survives", which
// gives the right answer for `""` and the wrong answer for any input that is entirely
// separators. It was caught only by noticing that the codec's `javaSplitOnLiteral`, being fixed
// for the same Java behaviour at the same time, had arrived at a DIFFERENT shape. Two
// implementations of one semantic disagreeing is this project's signature defect in miniature:
// each half plausible, nothing owning the join.
//
// So the expectations below are not derived from the Java source or from reasoning. They are the
// literal stdout of a probe run against openjdk@21:
//
//     ""           -> len=1  [""]
//     "a,,"        -> len=1  ["a"]
//     ",a"         -> len=2  ["" "a"]
//     ","          -> len=0  []
//     ",,"         -> len=0  []
//     "abc"        -> len=1  ["abc"]
//     "a,b"        -> len=2  ["a" "b"]
//     ""           -> len=1  [""]        (newline separator)
//     "\n"         -> len=0  []
//     "\n\n"       -> len=0  []
//     "a\nb"       -> len=2  ["a" "b"]
//     "a\nb\n"     -> len=2  ["a" "b"]
//     "a\n\n"      -> len=1  ["a"]
//
// The two rows that matter most are `"\n" -> []` and `"" -> [""]`. They look inconsistent and are
// not: Java returns the whole input when the pattern never matches, which is why the empty string
// survives; every other trailing empty is produced by a match and is discarded.

import Testing

@testable import LogisimHdl

@Suite("Java String.split semantics, pinned to observed JVM output")
struct JavaSplitSemanticsTests {

  @Test("the empty input yields one empty field, because no match occurs")
  func emptyInput() {
    // Java: "".split(",") -> len=1 [""]. This is the case that makes `LineBuffer.empty()` work:
    // an empty line must survive as a line. Dropping it unconditionally deletes every `.empty()`
    // in every generator: measured by the memory family as 14 failures becoming 152.
    #expect(javaSplit("", on: ",") == [""])
    #expect(javaSplit("", on: "\n") == [""])
  }

  @Test("an input that is entirely separators yields nothing at all")
  func allSeparators() {
    // Java: ",".split(",") -> len=0, ",,".split(",") -> len=0.
    //
    // THIS is what the first fix got wrong. A `count > 1` guard leaves `[""]` here. Every field
    // is empty, every one of them is trailing, and Java discards all of them.
    #expect(javaSplit(",", on: ",") == [])
    #expect(javaSplit(",,", on: ",") == [])
    #expect(javaSplit("\n", on: "\n") == [])
    #expect(javaSplit("\n\n", on: "\n") == [])
  }

  @Test("trailing empties are discarded, leading and interior ones are kept")
  func trailingVersusLeading() {
    #expect(javaSplit("a,,", on: ",") == ["a"])
    #expect(javaSplit(",a", on: ",") == ["", "a"])
    #expect(javaSplit("a,,b", on: ",") == ["a", "", "b"])
    #expect(javaSplit("a\n\n", on: "\n") == ["a"])
  }

  @Test("no separator present returns the whole input")
  func noMatch() {
    #expect(javaSplit("abc", on: ",") == ["abc"])
    #expect(javaSplit("a,b", on: ",") == ["a", "b"])
    #expect(javaSplit("a\nb", on: "\n") == ["a", "b"])
    #expect(javaSplit("a\nb\n", on: "\n") == ["a", "b"])
  }

  @Test("LineBuffer.empty() survives, and a line ending in a newline gains nothing")
  func lineBufferBehaviour() {
    // The two behaviours the generators actually depend on, asserted through the real buffer
    // rather than through the helper, so a future refactor that stops using `javaSplit` still
    // has to keep them.
    let buffer = LineBuffer.getBuffer()
    buffer.add("a").empty().add("b")
    #expect(buffer.getWithIndent("") == ["a", "", "b"])

    let trailing = LineBuffer.getBuffer()
    trailing.add("a\nb\n")
    #expect(trailing.getWithIndent("") == ["a", "b"])
  }
}
