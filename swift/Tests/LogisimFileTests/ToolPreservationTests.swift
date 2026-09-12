// ToolPreservationTests.swift: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Pins the boundary of D8's tool-preservation rule, which is narrower than it looks.
//
// A `<toolbar>` or `<lib>` entry naming a tool that resolves but carries no attribute set is a
// real and CORRECT state, not a gap: Java's `PokeTool`, `EditTool`, `MenuTool` and `WiringTool`
// all inherit `Tool.getAttributeSet()`'s `null` (`EditTool` forwards to `SelectTool`, which does
// not override it either), so upstream reads their `<a>` children into nothing and writes them
// back out bare. Only `TextTool` in `#Base` genuinely has a set.
//
// The port keeps the raw element instead, so nothing a user configured is destroyed by a plain
// open-and-save. That is right when the element carries attributes and WRONG when it does not:
// a preserved element is re-emitted verbatim including its `lib=` handle, libraries are
// renumbered from 0 on write, and any migration pass that inserts one, the `<4.0.0` repair adds
// `#FPArithmetic`, shifts every handle above it. Measured before this rule was narrowed: the
// migration gate wrote `<tool lib="8" name="Poke Tool"/>` where the oracle writes `lib="9"`, on
// every toolbar entry of every file, and 79 corpus files differed in nothing else.

import Foundation
import Testing

@testable import LogisimFile

/// A minimal 4.1.0-shaped project. `#Base` is index 1 here so a wrong `lib=` handle is visible
/// as a wrong number rather than as a missing attribute.
private func project(toolbar: String, baseLibTools: String = "") -> Data {
  Data(
    """
    <?xml version="1.0" encoding="UTF-8" standalone="no"?>
    <project source="4.1.0" version="1.0">
      <lib desc="#Wiring" name="0"/>
      <lib desc="#Base" name="1">\(baseLibTools)</lib>
      <main name="main"/>
      <options/>
      <mappings/>
      <toolbar>\(toolbar)</toolbar>
      <circuit name="main"/>
    </project>
    """.utf8)
}

private func loadToolbar(_ data: Data) throws -> [Tool?] {
  let loader = Loader()
  let file = try XmlReader(loader: loader, file: nil).readLibrary(data)
  return file.options.toolbarData.toolbarContents
}

// MARK: - The toolbar

@Test func aToolWithNoAttributesResolvesRatherThanBeingFrozenAsRawXml() throws {
  // `Poke Tool` resolves to `#Base`'s placeholder, whose attribute set is nil: matching Java,
  // where `PokeTool` has none either. With no `<a>` to lose there is nothing to preserve, so the
  // reader must hand the writer the real tool and let it recompute the `lib=` handle.
  let contents = try loadToolbar(project(toolbar: #"<tool lib="1" name="Poke Tool"/>"#))
  #expect(contents.count == 1)
  let tool = try #require(contents.first ?? nil)
  #expect(!(tool is PreservedTool), "a bare <tool> must not be frozen with its stale lib= handle")
  #expect(tool.name == BaseLibrary.pokeToolId)
}

// ── Why these use `Menu Tool` and not `Text Tool` ────────────────────────────────────────────
//
// They used to name `Text Tool`, on the stated ground that "`Text Tool`'s attribute set is still
// a placeholder in this port". That stopped being true when `LogisimStd.registerBase()` started
// vending a real `TextTool(textFactory: Text.factory)`, which **does** have an attribute set,
// so `<a name="font">` is read into it and the element is correctly not preserved.
//
// `BuiltinToolProviders` is a process-global registry and all test targets link into one
// `.xctest` binary, so whether that registration has happened by the time these run depends
// purely on which suite the scheduler starts first. The tests passed for as long as they
// happened to win that race and failed the moment another registering suite was added. That is
// a flake, not a signal.
//
// `Menu Tool` is a `BuiltinPlaceholderTool` in **both** `LogisimFile.BaseLibrary` and
// `LogisimStd.registerBase()`, so its attribute set is nil either way, which is exactly the
// state this rule is about, held fixed. Java agrees: `MenuTool` inherits `Tool.getAttributeSet()`'s
// null, as the file header already says of Poke/Edit/Menu/Wiring.

@Test func aToolWithAttributesButNoAttributeSetIsPreservedVerbatim() throws {
  // The other side of the rule. `Menu Tool` has no attribute set, so reading `font` into it
  // would drop the value on the floor; upstream's own behaviour here is silent data loss, and
  // D8 declines to reproduce it.
  let contents = try loadToolbar(
    project(
      toolbar: """
        <tool lib="1" name="Menu Tool"><a name="font" val="SansSerif plain 12"/></tool>
        """))
  let tool = try #require(contents.first ?? nil)
  #expect(tool is PreservedTool)
}

@Test func separatorsAndOrderSurviveTheMixedCase() throws {
  let contents = try loadToolbar(
    project(
      toolbar: """
        <tool lib="1" name="Poke Tool"/><sep/>\
        <tool lib="1" name="Menu Tool"><a name="font" val="SansSerif plain 12"/></tool>
        """))
  #expect(contents.count == 3)
  #expect(contents[1] == nil)
  #expect(!((contents[0] ?? nil) is PreservedTool))
  #expect((contents[2] ?? nil) is PreservedTool)
}

// MARK: - The `<lib>` element

@Test func aLibraryToolBlockWithNoAttributesIsNotAbsorbed() throws {
  // `XmlWriter.fromLibrary` appends a `<tool>` child only when `addAttributeSetContent` gave it
  // at least one `<a>`, so absorbing an empty one would make the port emit a block the oracle
  // never writes.
  let loader = Loader()
  let file = try XmlReader(loader: loader, file: nil).readLibrary(
    project(toolbar: "", baseLibTools: #"<tool name="Poke Tool"/>"#))
  let base = try #require(file.libraries.first { $0.name == Builtin.baseId })
  #expect(base.unresolvedToolElements.isEmpty)
}

@Test func aLibraryToolBlockWithAttributesIsAbsorbed() throws {
  // `Menu Tool` rather than `Text Tool`, for the reason given above the toolbar cases.
  let loader = Loader()
  let file = try XmlReader(loader: loader, file: nil).readLibrary(
    project(
      toolbar: "",
      baseLibTools: #"<tool name="Menu Tool"><a name="font" val="SansSerif plain 12"/></tool>"#))
  let base = try #require(file.libraries.first { $0.name == Builtin.baseId })
  #expect(base.unresolvedToolElements.count == 1)
}
