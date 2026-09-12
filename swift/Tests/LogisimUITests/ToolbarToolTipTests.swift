// ToolbarToolTipTests.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.draw.toolbar.ToolbarButton,
// com.cburch.logisim.gui.main.LayoutToolbarModel, com.cburch.logisim.tools.*.getDescription),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: the shipping 4.1.0 jar at /Applications/Logisim-evolution.app/Contents/app/
// logisim-evolution-4.1.0-all.jar, read with `javap -c -p -v` and `unzip -p`. NOT this
// repository's `src/main/java`, which is upstream *main* and not 4.1.0. (D16.)
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE TOP TOOLBAR'S FIVE GLYPHS, AND WHAT EACH ONE SAYS WHEN YOU HOVER IT.
//
// The report, verbatim: *"hover i meant the top tool bar."* The row is `#Base`'s five tools in
// the window title bar, a hand, an arrow, a diagonal line, `Aa` and `⋯`, and it had no tool
// tips at all. It was a `Picker(.segmented)` with `.labelsHidden()`, and a `.help` written on a
// picker row is discarded: SwiftUI takes the row's `Text`/`Image`/`tag` to build
// `NSSegmentedControl` segments and drops the rest. So the modifier was there, in the source,
// doing nothing, which is precisely the false green this project keeps catching, one layer down.
//
// 4.1.0 has the feature. `ToolbarButton.<init>` calls `setToolTipText("")` (the Swing idiom for
// "register me with ToolTipManager") and overrides `getToolTipText(MouseEvent)` to return
// `item.getToolTip()`; `LayoutToolbarModel$ToolItem.getToolTip()` returns
// `tool.getDescription()`. So this is a fidelity gap, not an embellishment.
//
// ── WHAT IS ASSERTED HERE ───────────────────────────────────────────────────────────────────
//
//   * The STRING. `ToolButtonToolTips.text(for:)` is a pure function of a `ToolItem`, and every
//     test below calls it with an item taken from a real `ProjectOutline` built by the real
//     host, not a hand-made fixture, so a break anywhere from `#Base.getTools()` through
//     `ProjectOutlineBuilder` to the resolver reddens it.
//   * That the strings are 4.1.0's, spelled exactly, for all six `#Base` tools.
//   * That the two surfaces that draw tool buttons both go through that one function, and that
//     the window-toolbar row is no longer a picker. Those are facts about files, asserted by a
//     source scan, for the same reason `AppearancePlacementTests` and `PreferenceConsumerTests`
//     scan: SwiftUI offers no runtime handle on "is this modifier attached to this control".
//
// ── WHAT IS *NOT* ASSERTED, STATED PLAINLY RATHER THAN IMPLIED ──────────────────────────────
//
//   * **That AppKit ever shows the panel.** A tool tip is a floating window put up after a hover
//     delay by a real `NSWindow` in a real app. Nothing here creates one.
//   * **That `.help` on a `Button` works and `.help` on a `Picker` row does not.** That is the
//     diagnosis this change rests on, and it is not directly testable from here. It could only
//     be observed by rendering the view and reading the resulting `NSView.toolTip`, and the
//     view in question is `ToolbarContent`, which materialises only inside a real `WindowGroup`
//     scene, so not even an `NSHostingView` reaches it. **This is a missing test seam**: it would
//     need `EditorToolbar`'s row extracted into a plain `View` that an `NSHostingView` could
//     instantiate and whose AppKit subtree could then be walked for `toolTip`. That refactor is
//     not in this change; see the report.
//   * The hover delay, the panel's placement and its appearance: all system behaviour.
//
// So: this file gates the content and the wiring, and says out loud that the pixels are ungated.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimFile
import LogisimStd
import Testing

@testable import LogisimUI

@Suite("Toolbar tool tips", .serialized)
struct ToolbarToolTipTests {

  @MainActor
  private func makeHost() throws -> LogisimFileProjectHost {
    StdLibraries.registerAll()
    return try #require(
      try LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
  }

  // MARK: - The reported row

  /// The five buttons in the title bar, in the order they are drawn, each with 4.1.0's sentence.
  ///
  /// Order matters and is asserted: `EditorToolbar` iterates `outline.editingTools` *without*
  /// `PaletteLayout.presentationOrder`, so this row opens with Poke where the palette strip below
  /// opens with Select. That difference is how the reported row was identified in the first place
  /// : the report described a hand first.
  ///
  /// Spelled out one string at a time rather than compared to a table built from the same
  /// constants the code uses. A test that says `text(for: tool) == upstreamBaseDescriptions[id]`
  /// passes for any six strings at all, including the six this change deleted.
  @Test("every button in the window toolbar's tool row names its tool, in 4.1.0's words")
  @MainActor
  func editingToolsCarryUpstreamDescriptions() throws {
    let host = try makeHost()
    let tools = host.outline.editingTools

    #expect(tools.count == 5, "#Base publishes \(tools.count) tools; the row expects 5")
    #expect(tools.map(\.name) == ["Poke", "Select", "Wire", "Text", "Menu"])

    let tips = tools.map { ToolButtonToolTips.text(for: $0) }
    #expect(
      tips == [
        "Change values within circuit",  // pokeToolDesc
        "Edit selection and add wires",  // editToolDesc
        "Add wires to circuit",  // wiringToolDesc
        "Edit text in circuit",  // textToolDesc
        "View component menus",  // menuToolDesc
      ],
      """
      The window toolbar's tips are \(tips). They must be 4.1.0's `*Desc` strings from \
      `resources/logisim/strings/tools/tools.properties` in the shipping jar.
      """)
  }

  /// The one `#Base` tool the row does not show, kept honest anyway.
  ///
  /// `SelectTool._ID` is not published by `getTools()`; a pre-2.3.0 `<toolbar>` can still name
  /// it, and upstream gives it a *different* sentence from `EditTool`. This is why the table is
  /// keyed on the `_ID` and resolved in `ProjectOutlineBuilder`, where the `_ID` still exists,
  /// rather than on the button label, where "Select" would mean either one.
  @Test("EditTool and SelectTool keep 4.1.0's two different sentences")
  func editAndSelectAreNotConflated() {
    #expect(
      ToolButtonToolTips.upstreamDescription(forToolNamed: BaseToolIds.edit)
        == "Edit selection and add wires")
    #expect(
      ToolButtonToolTips.upstreamDescription(forToolNamed: BaseToolIds.select)
        == "Edit circuit components")
    #expect(
      ToolButtonToolTips.upstreamDescription(forToolNamed: BaseToolIds.edit)
        != ToolButtonToolTips.upstreamDescription(forToolNamed: BaseToolIds.select),
      "the two are distinct upstream; collapsing them loses one of 4.1.0's strings")
  }

  /// Nothing outside `#Base` is in the table; a gate must fall through to `addToolText`.
  @Test("the base table answers for #Base and for nothing else")
  func upstreamTableIsScopedToBase() {
    #expect(ToolButtonToolTips.upstreamBaseDescriptions.count == 6)
    #expect(ToolButtonToolTips.upstreamDescription(forToolNamed: "AND Gate") == nil)
    #expect(ToolButtonToolTips.upstreamDescription(forToolNamed: "Pin") == nil)
  }

  // MARK: - The palette strip

  /// Every entry of the document's own `<toolbar>` resolves to a sentence, and no entry's tip is
  /// just the label repeated.
  ///
  /// The old code was `.help(item.summary ?? item.name)`, and `summary` is nil for every library
  /// tool; `Tool.toolDescription` is `open var … { "" }` in `LibraryModel.swift` and nothing
  /// overrides it. So hovering the AND gate said "AND Gate", which is what the button's
  /// accessibility label already said. 4.1.0's `AddTool.getDescription()` falls through to
  /// `S.get("addToolText", displayName)` and `tools.properties` has `addToolText = Add %s`.
  @Test("no palette tip is the bare button label, and the gates read 4.1.0's `Add %s`")
  @MainActor
  func paletteTipsAreSentencesNotLabels() throws {
    let host = try makeHost()
    let items = host.outline.toolbarItems.compactMap(\.item)

    #expect(items.count == 14, "the default template's <toolbar> has 14 tools; got \(items.count)")

    for item in items {
      let tip = ToolButtonToolTips.text(for: item)
      #expect(!tip.isEmpty, "\(item.name) has an empty tip")
      #expect(
        tip != item.name,
        "hovering \(item.name) says \"\(tip)\" — the label repeated, which tells the user nothing")
    }

    func tip(_ name: String) throws -> String {
      ToolButtonToolTips.text(for: try #require(items.first { $0.name == name }))
    }
    #expect(try tip("AND Gate") == "Add AND Gate")
    #expect(try tip("NOT Gate") == "Add NOT Gate")
    #expect(try tip("D Flip-Flop") == "Add D Flip-Flop")
    #expect(try tip("Pin") == "Add Pin")

    // The four canvas tools the template also puts on the strip keep the `#Base` sentences,
    // not `Add Poke`: the two branches of the resolver, both exercised on real data.
    #expect(try tip("Poke") == "Change values within circuit")
    #expect(try tip("Select") == "Edit selection and add wires")
    #expect(try tip("Wire") == "Add wires to circuit")
    #expect(try tip("Text") == "Edit text in circuit")
  }

  /// `addToolText` is upstream's format, not a coincidence of the fixture.
  @Test("addToolText is 4.1.0's `Add %s`")
  func addToolTextMatchesUpstreamFormat() {
    #expect(ToolButtonToolTips.addToolText("Register") == "Add Register")
    #expect(ToolButtonToolTips.addToolText("7408: quad 2-input AND gate")
      == "Add 7408: quad 2-input AND gate")
  }

  /// A tool that cannot be placed says *why*, ahead of everything else: the D11/D8 rule, and the
  /// precedence `ExplorerSidebar` already uses for its own rows.
  @Test("an unavailable tool's tip is the reason it is unavailable")
  func unavailableReasonOutranksEverything() {
    let item = ToolItem(
      id: ToolID(rawValue: 1), name: "AND Gate", symbolName: "capsule",
      summary: "a summary that must not win",
      unavailableReason: "‘#Foo’ is not a built-in library in this build.")
    #expect(
      ToolButtonToolTips.text(for: item) == "‘#Foo’ is not a built-in library in this build.")

    // Empty strings are not answers. An item carrying `""` must fall through, not show a blank
    // tip, which is how a tool tip disappears without anyone noticing.
    let blank = ToolItem(
      id: ToolID(rawValue: 2), name: "AND Gate", symbolName: "capsule", summary: "",
      unavailableReason: "")
    #expect(ToolButtonToolTips.text(for: blank) == "Add AND Gate")
  }

  // MARK: - The wiring, as a fact about files
  //
  // See the header for why this is a source scan and not a runtime assertion.

  static var sourcesRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // LogisimUITests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // swift
      .appendingPathComponent("Sources")
  }

  static func read(_ relativePath: String) throws -> String {
    let url = Self.sourcesRoot.appendingPathComponent(relativePath)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
      Issue.record("could not read \(url.path) — the scan below would pass vacuously")
      throw CocoaError(.fileNoSuchFile)
    }
    return text
  }

  /// Every surface that draws a tool as a bare glyph.
  static let toolButtonFiles = [
    "LogisimUI/Editor/EditorToolbar.swift",
    "LogisimUI/Editor/ComponentPalette.swift",
  ]

  /// **Comments are stripped first, and that is not tidiness; it is the bug this test had.**
  ///
  /// The first version scanned the raw file. It passed with the call site deleted, because both
  /// of these files carry a *comment* explaining the change ("`ToolButtonToolTips.text(for:)`,
  /// not `item.summary ?? item.name` …") and the needle matched the prose. A red probe that
  /// removed `.help(ToolButtonToolTips.text(for: item))` from both of `ComponentPalette`'s call
  /// sites reddened nothing at all; a source scan that greps its own documentation is exactly
  /// the false green this project keeps catching.
  @Test("both tool-button surfaces resolve their tip through the one function")
  func bothSurfacesUseTheSharedResolver() throws {
    for path in Self.toolButtonFiles {
      let code = Self.strippingComments(try Self.read(path))
      #expect(
        code.contains("ToolButtonToolTips.text(for:"),
        """
        \(path) draws tool buttons but does not call `ToolButtonToolTips.text(for:)` in its \
        code — a mention in a comment does not count. Two surfaces describing the same tool two \
        different ways is how the palette and the toolbar drift apart; there is one resolver on \
        purpose.
        """)
      #expect(
        code.contains(".help("),
        "\(path) draws tool buttons with no `.help` on them at all")
    }
  }

  // ── A TEST WAS DELETED HERE, AND THIS RECORDS WHY ─────────────────────────────────────────
  //
  // `toolRowIsNotAPicker` asserted that the tool row is NOT a segmented `Picker`; pinning the
  // very rewrite that produced it. The rewrite replaced the segmented control with an `HStack` of
  // fixed 26x22 `Button`s in order to carry `.help`, and that **broke the toolbar's layout**: the
  // cells no longer fitted the capsule, which the owner reported the same day it shipped.
  //
  // The control has been reverted. This test would have failed on that revert and demanded the
  // regression back, which is what a change detector does: it defends the implementation its
  // author chose rather than a property a user cares about. The property that IS worth pinning,
  // that every tool resolves a tooltip STRING, from one shared table, is asserted by the tests
  // above and is unaffected by which control renders the row.
  //
  // The underlying trade is real and unresolved, and it is recorded at `EditorToolbar
  // .toolPalette`: SwiftUI's segmented picker discards per-segment `.help`, so top-bar tooltips
  // need a custom control sized to the toolbar. That is deliberate design work, not a side effect
  // of a tooltip task, and it is not scheduled.

  /// The centre-view picker is still a picker, and legitimately so; it is a three-way *mode*
  /// switch, not a row of anonymous glyphs, and nothing was reported about it. Asserted so the
  /// scan above is understood as being about the tool row and cannot be satisfied by removing
  /// every picker in the file.
  @Test("the Layout/Appearance/HDL picker is left alone")
  func centreViewPickerSurvives() throws {
    let code = Self.strippingComments(try Self.read("LogisimUI/Editor/EditorToolbar.swift"))
    #expect(code.contains("Picker(\"View\""))
    #expect(code.contains("pickerStyle(.segmented)"))
  }

  /// `toolPalette` and `toolButton` — from the first to the `// MARK:` that ends the section.
  ///
  /// Sliced on markers that are already in the file for their own reasons rather than on markers
  /// planted for the test, so there is nothing here for a future edit to remove without also
  /// moving the code this is about.
  static func toolRowSource() throws -> String {
    let text = try Self.read("LogisimUI/Editor/EditorToolbar.swift")
    guard let start = text.range(of: "// MARK: Tools"),
      let end = text.range(of: "// MARK: Simulation")
    else {
      Issue.record("EditorToolbar.swift no longer has the Tools/Simulation MARKs to slice on")
      throw CocoaError(.formatting)
    }
    return String(text[start.upperBound..<end.lowerBound])
  }

  /// Line comments only. Enough for this file, whose quoted picker lives in a `///` block, and
  /// deliberately not a Swift parser; a scan that pretended to be one would be trusted further
  /// than it deserves.
  static func strippingComments(_ text: String) -> String {
    text
      .split(separator: "\n", omittingEmptySubsequences: false)
      .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
      .joined(separator: "\n")
  }
}
