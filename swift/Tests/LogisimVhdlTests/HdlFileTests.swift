// HdlFileTests: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// `HdlFile.load` is a `BufferedReader.readLine()` loop that appends a line separator after
// EVERY line, including the last. That makes loading lossy and normalising, and it is the same
// trap that already cost `VhdlContent.template` a byte. These tests pin the behaviour directly
// (through `normalizeLines`, the pure half) and end to end (through a real temporary file).

import Foundation
import Testing

@testable import LogisimVhdl

// MARK: - normalizeLines: the readLine loop

@Test func emptyInputProducesNoLinesAtAll() {
  // `readLine()` returns null immediately, so the loop never appends a separator.
  #expect(HdlFile.normalizeLines("") == "")
}

@Test func aFinalLineWithoutATerminatorStillGainsOne() {
  #expect(HdlFile.normalizeLines("entity foo is") == "entity foo is\n")
}

@Test func aSingleTrailingNewlineIsIndistinguishableFromNone() {
  #expect(HdlFile.normalizeLines("a\n") == "a\n")
  #expect(HdlFile.normalizeLines("a") == "a\n")
}

@Test func interiorAndTrailingBlankLinesSurvive() {
  #expect(HdlFile.normalizeLines("a\n\nb\n\n") == "a\n\nb\n\n")
}

@Test func crlfBecomesOneSeparatorNotTwo() {
  // The reason `normalizeLines` walks unicode scalars: Swift treats "\r\n" as a single
  // `Character` equal to neither "\r" nor "\n", so a `Character`-based scan would pass every
  // CRLF straight through and this expectation would read `"a\r\nb\r\n"`.
  #expect(HdlFile.normalizeLines("a\r\nb\r\n") == "a\nb\n")
}

@Test func aLoneCarriageReturnIsAlsoATerminator() {
  #expect(HdlFile.normalizeLines("a\rb\rc") == "a\nb\nc\n")
}

@Test func mixedTerminatorsAreAllNormalized() {
  #expect(HdlFile.normalizeLines("a\r\nb\nc\rd") == "a\nb\nc\nd\n")
}

@Test func unicodeLineSeparatorsJavaDoesNotRecogniseArePreserved() {
  // Java's `BufferedReader.readLine` knows only \n, \r and \r\n. U+2028, U+0085 and U+000B are
  // line breaks to Foundation's `.newlines` character set and to `components(separatedBy:)`,
  // which is exactly why neither is used here; splitting on them would inject newlines into
  // VHDL source that merely contained one.
  let source = "a\u{2028}b\u{0085}c\u{000B}d"
  #expect(HdlFile.normalizeLines(source) == source + "\n")
}

// MARK: - load / save round trip

@Test func loadNormalizesLineEndingsAndAddsAFinalNewline() throws {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("hdlfile-load-\(UUID().uuidString).vhdl")
  defer { try? FileManager.default.removeItem(at: url) }

  try Data("library ieee;\r\nentity foo is\r\nend foo;".utf8).write(to: url)
  #expect(try HdlFile.load(contentsOf: url) == "library ieee;\nentity foo is\nend foo;\n")
}

@Test func saveWritesTheTextVerbatimWithNoLineSeparatorRewriting() throws {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("hdlfile-save-\(UUID().uuidString).vhdl")
  defer { try? FileManager.default.removeItem(at: url) }

  // Java's `save` is a plain `out.write(text, 0, text.length())`: asymmetric with `load`,
  // which is why a load/save round trip is not the identity.
  try HdlFile.save("a\r\nb", to: url)
  #expect(try Data(contentsOf: url) == Data("a\r\nb".utf8))
}

@Test func loadingAMissingFileThrowsRatherThanTrapping() {
  // D13: everything reachable from a bad path throws.
  let url = URL(fileURLWithPath: "/nonexistent/logisim-evolved/does-not-exist.vhdl")
  #expect(throws: HdlFileError.self) { try HdlFile.load(contentsOf: url) }
  do {
    _ = try HdlFile.load(contentsOf: url)
  } catch let error as HdlFileError {
    #expect(error.message == "Error reading file.")
    // Java discards the cause; the port keeps it (see the file header).
    #expect(error.underlying != nil)
  } catch {
    Issue.record("expected HdlFileError, got \(error)")
  }
}

@Test func savingIntoAMissingDirectoryThrowsRatherThanTrapping() {
  let url = URL(fileURLWithPath: "/nonexistent/logisim-evolved/out.vhdl")
  do {
    try HdlFile.save("x", to: url)
    Issue.record("expected a write failure")
  } catch let error as HdlFileError {
    #expect(error.message == "Error writing file.")
  } catch {
    Issue.record("expected HdlFileError, got \(error)")
  }
}
