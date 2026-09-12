// RomContentsBindingTests: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ══ THE ONE BINDING WHOSE ABSENCE IS INVISIBLE ══════════════════════════════════════════════
//
// `MemoryHdlGenerators.registrations(romContents:)` defaults its reader to `nil`, and with it
// `nil` a ROM still generates: `RomHdlGeneratorFactory` emits a `with … select` table in which
// every word read zero, so the table is empty and the default covers everything. **That is a
// wrong ROM, not a missing one**: it compiles, it synthesizes, and it silently contains no data.
//
// The four memory oracle suites do not cover it. `MemoryHdlOracleTests` drives
// `MemoryHdlGenerators.registrations()` with no reader at all, and ROM is `isOnlyInlined`, so the
// bridge never calls `getInlinedCode` for it; the 168/168 memory figure says nothing about this
// path.
//
// So this suite drives the reader `BuiltinHdlWiring` installs, over a REAL `Rom` attribute set
// holding a REAL `MemContents`, and asserts the emitted table contains the words that were
// written. It is the check that distinguishes "the ROM binding is faithful" from "a ROM binding
// exists".
//
// ── What it does NOT prove, stated plainly ──────────────────────────────────────────────────
//
// It constructs the same closure `BuiltinHdlWiring.romContents` is; it does not read that
// property, because `LogisimHdlTests` cannot import `LogisimHdlWiring` (no `Package.swift` edge,
// and that file is owned elsewhere). The two are therefore verified-equivalent by eye, not by the
// compiler. The exact `LogisimHdlWiringTests` stanza that would close the gap is in this task's
// report.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd
import Testing

@testable import LogisimHdl

@Suite("The ROM contents binding — a nil reader emits an all-zero image", .serialized)
struct RomContentsBindingTests {

  /// Exactly the closure `BuiltinHdlWiring` passes as `romContents`, and exactly what
  /// `RomHdlGeneratorFactory.java:29,39` does: `attrs.getValue(Rom.CONTENTS_ATTR).get(addr)`.
  static let romContents: MemoryHdlContentsReader = { attrs, address in
    attrs.getValue(Rom.contentsAttr)?.get(address) ?? 0
  }

  /// A ROM whose contents attribute holds a `MemContents` with known non-zero words.
  ///
  /// `Rom.contentsAttr` is the object `Rom`'s own attribute set carries (`Rom.swift:209` reads it
  /// back by the same constant), so the `===` lookup D4 requires does hit. Were the wrong object
  /// bound, `getValue` would answer `nil` and every word would read zero, which is the failure
  /// this suite exists to distinguish from success.
  static func romAttributes(addrBits: Int, dataBits: Int, words: [Int64: Int64]) throws
    -> any AttributeSet
  {
    let attrs = Rom().createAttributeSet()
    let contents = try #require(
      attrs.getValue(Rom.contentsAttr),
      "a fresh Rom's attribute set has no MemContents — the binding could not be exercised")
    for (address, value) in words { contents.set(address, value) }
    return attrs
  }

  @Test("the reader returns the words a real MemContents holds")
  func readerReadsRealContents() throws {
    let words: [Int64: Int64] = [0: 0xA5, 1: 0x00, 2: 0xFF, 7: 0x42]
    let attrs = try Self.romAttributes(addrBits: 3, dataBits: 8, words: words)

    for (address, expected) in words {
      #expect(
        Self.romContents(attrs, address) == expected,
        "word \(address) read back as \(Self.romContents(attrs, address)), not \(expected)")
    }
  }

  /// The reader must answer `0`, not trap, for a component that has no contents attribute.
  ///
  /// D13: a generator is not a place to abort the process. Java would throw
  /// `NullPointerException` here, but the path is unreachable upstream because this generator is
  /// only ever reached through the `Rom` registration.
  @Test("a component with no contents attribute reads zero rather than trapping")
  func readerToleratesAComponentWithNoContents() {
    let attrs = Register().createAttributeSet()
    #expect(Self.romContents(attrs, 0) == 0)
  }

  /// **The distinguishing test**: the same ROM, generated with the reader and without it.
  ///
  /// With `nil` the two outputs would be identical, and the `nil` one is the wrong answer. If this
  /// ever starts passing with `romContents: nil`, the reader has stopped being consulted.
  @Test("a ROM generated with the reader differs from one generated without it")
  func theReaderChangesWhatIsEmitted() throws {
    try withHdlGlobals {
      HdlSettings.language = .vhdl
      let attrs = try Self.romAttributes(
        addrBits: 3, dataBits: 8, words: [0: 0xA5, 2: 0xFF, 7: 0x42])

      let withReader = try Self.inlinedRomCode(attrs: attrs, reader: Self.romContents)
      let withoutReader = try Self.inlinedRomCode(attrs: attrs, reader: nil)

      #expect(
        withReader != withoutReader,
        "the ROM emits the same code with and without a contents reader — the reader is not being consulted, and every ROM would ship as an all-zero image")

      // And the emitted table must carry the actual words, not merely differ.
      //
      // `Hdl.getConstantVector` renders a byte as a VHDL hex literal, so the words appear as
      // `X"A5" WHEN X"00"`: one `WHEN` arm per non-zero address, zero being the table's default
      // and therefore deliberately absent.
      for arm in [#"X"A5" WHEN X"00""#, #"X"FF" WHEN X"02""#, #"X"42" WHEN X"07""#] {
        #expect(
          withReader.contains(arm),
          "the generated lookup table has no arm `\(arm)`:\n\(withReader)")
      }
      #expect(
        !withoutReader.contains(#"X"A5""#),
        "the no-reader baseline already contains ROM data, so the comparison above proves nothing")
      #expect(
        withoutReader.contains(#"X"00" WHEN OTHERS"#),
        "the no-reader baseline is not the all-zero image it is supposed to be")
    }
  }

  /// Runs `MemoryRomHdlGeneratorFactory.getInlinedCode` through the registration, the way
  /// `Netlist` would.
  private static func inlinedRomCode(attrs: any AttributeSet, reader: MemoryHdlContentsReader?)
    throws -> String
  {
    let registration = try #require(
      MemoryHdlGenerators.registrations(romContents: reader)[MemoryHdlGenerators.FactoryName.rom],
      "ROM has no registration")
    let generator = try #require(
      registration.generator(attrs),
      "ROM has no generator; a single-line ROM is the synthesizable case and this attribute set should be one")

    let factory = Rom()
    let origin = Location.create(0, 0, hasToSnap: true)
    let ends = try factory.ports(attrs).map { port -> MemoryHdlOracleTests.UnconnectedPlacement.End in
      let end = try port.toEnd(location: origin, attributes: attrs)
      return MemoryHdlOracleTests.UnconnectedPlacement.End(nrOfBits: end.width.width, isOutputEnd: end.isOutput)
    }
    let placement = MemoryHdlOracleTests.UnconnectedPlacement(
      ends: ends, attributeSet: attrs, hdlName: "ROM", displayName: "ROM")

    let inlined = try #require(
      generator as? InlinedHdlGeneratorFactory, "ROM's generator is not inlined any more")
    return inlined.getInlinedCode(
      netlist: MemoryHdlOracleTests.ProjectNameOnlyNetlist(), componentId: 1, componentInfo: placement,
      circuitName: "main"
    ).get().joined(separator: "\n")
  }
}
