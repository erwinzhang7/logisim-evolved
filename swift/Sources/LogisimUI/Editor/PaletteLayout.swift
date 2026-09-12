// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// HOW MANY PALETTE BUTTONS FIT, AND WHAT HAPPENS TO THE REST.
//
// Split out of `ComponentPalette` as a pure function of (entries, width) so it can be tested
// without a window. The alternative, deciding overflow inside a `GeometryReader` closure, is
// the kind of layout logic that is only ever verified by looking at it, and "looking at it" is
// precisely the verification technique this port does not have for the UI (see objectives.md,
// "Know what changes when the UI starts").
//
// Fixed metrics rather than measured ones: every button is an icon in a 26×22 frame, so the
// widths are known ahead of time and the split is arithmetic. If a button ever gains a text
// label this has to start measuring, and the tests below will not notice; stated here because
// that is exactly the kind of assumption that rots quietly.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import CoreGraphics
import LogisimFile

enum PaletteLayout {

  // MARK: - Presentation order

  /// Move the pointer (Select/Edit) tool immediately in front of Poke, and change nothing else.
  ///
  /// **This is a UI decision, and it is the one place the strip deviates from file order.**
  /// 4.1.0's default template opens its `<toolbar>` with `Poke, Edit, Wiring, Text`, so the
  /// leftmost button is Poke. From the first real use of this app: *"poke does nothing when I
  /// drag."* That is upstream behaving correctly, `PokeTool` pokes values, `SelectTool` drags,
  /// and a Poke drag is meant to be inert, so there is no bug to fix here. What there is, is a
  /// toolbar whose first button is the one that ignores the gesture a new user tries first. Every
  /// other editor on this platform puts the pointer leftmost; doing the same makes the tool that
  /// answers a drag the one the eye lands on.
  ///
  /// Three things keep this honest:
  ///
  ///   * **Presentation only.** The caller is a `body`; nothing writes back. `Options.toolbarData`
  ///     keeps file order, so the saved `.circ` is unchanged and M2's byte-exact round trip does
  ///     not see this at all.
  ///   * **A swap, not a sort.** Only the pointer moves, and only to the slot directly before
  ///     Poke. A user who has dragged their own tools onto their own toolbar keeps that order.
  ///   * **Within one separator-delimited group.** If someone has put Poke and Select in
  ///     different sections of their toolbar, moving one across the divider would be rewriting
  ///     their layout rather than nudging it, so this declines.
  ///
  /// `split` still gets file order for every other purpose; this runs before it, so the button
  /// the overflow boundary falls on is computed against what is actually shown.
  static func presentationOrder(_ entries: [ToolbarEntry]) -> [ToolbarEntry] {
    func isBase(_ entry: ToolbarEntry, _ id: String) -> Bool {
      guard case .tool(let item) = entry else { return false }
      // `ToolSymbols.editingDisplayName` has already turned the `_ID` into the button label by
      // the time a `ToolItem` exists, so match on that; "Poke Tool" reads "Poke" here.
      return item.name == ToolSymbols.editingDisplayName(forToolNamed: id)
    }

    guard let poke = entries.firstIndex(where: { isBase($0, BaseToolIds.poke) }) else {
      return entries
    }
    let pointer = entries.firstIndex {
      isBase($0, BaseToolIds.edit) || isBase($0, BaseToolIds.select)
    }
    guard let pointer, pointer > poke else { return entries }

    // Refuse to cross a divider: everything between the two has to be tools.
    for entry in entries[poke..<pointer] {
      if case .separator = entry { return entries }
    }

    var result = entries
    let moved = result.remove(at: pointer)
    result.insert(moved, at: poke)
    return result
  }

  // MARK: - Overflow

  /// One icon button plus the gap after it.
  static let itemWidth: CGFloat = 28
  /// A `Divider` with 6pt of padding on each side.
  static let separatorWidth: CGFloat = 13
  /// The `⋯` menu at the right end.
  static let overflowWidth: CGFloat = 34
  /// `.padding(.horizontal, 10)` on the row, both sides.
  static let rowInsets: CGFloat = 20

  /// Below this there is no room for even one button beside the overflow menu, so everything
  /// overflows and the strip is just the `⋯`. Reachable for real: a `GeometryReader` reports a
  /// width of 0 on the first layout pass, and during a live window resize.
  static var minimumWidth: CGFloat { rowInsets + overflowWidth + itemWidth }

  struct Split {
    var visible: [ToolbarEntry]
    var overflow: [ToolbarEntry]
    var hasOverflow: Bool { !overflow.isEmpty }
  }

  /// Greedy fit, left to right, in file order.
  ///
  /// File order is not negotiable: the palette is the user's own `<toolbar>`, and a layout that
  /// reordered it to pack better would move buttons around under the cursor as the window
  /// resizes. Overflow takes the tail.
  static func split(_ entries: [ToolbarEntry], availableWidth: CGFloat) -> Split {
    guard !entries.isEmpty else { return Split(visible: [], overflow: []) }

    let total = entries.reduce(CGFloat.zero) { $0 + width(of: $1) } + rowInsets
    if total <= availableWidth {
      return Split(visible: entries, overflow: [])
    }

    // Everything past the fit goes in the menu, so the button is always needed on this path and
    // its width is reserved before the first item rather than discovered after the last.
    var budget = availableWidth - rowInsets - overflowWidth
    var cut = 0
    for entry in entries {
      let w = width(of: entry)
      if budget - w < 0 { break }
      budget -= w
      cut += 1
    }

    // Never end the strip on a divider: a trailing separator reads as "something was cut here",
    // which is true but is what the ⋯ button already says, and it wastes 13 points saying it.
    //
    // MOVE the boundary, do not delete. The first version of this did `visible.removeLast()`,
    // which dropped the separator from the result entirely; `visible + overflow` was no longer
    // the input. It was a separator this time and would have been a tool under a slightly
    // different trim rule, which is the silent-tool-loss this whole strip exists to fix. Caught
    // by the totality sweep rather than by reading it.
    while cut > 0, case .separator = entries[cut - 1] { cut -= 1 }

    return Split(visible: Array(entries.prefix(cut)), overflow: Array(entries.dropFirst(cut)))
  }

  static func width(of entry: ToolbarEntry) -> CGFloat {
    switch entry {
    case .tool: return itemWidth
    case .separator: return separatorWidth
    }
  }
}

// ═════════════════════════════════════════════════════════════════════════════════════════════
// WHAT A HOVER OVER A TOOL *BUTTON* SAYS.
//
// Not to be confused with `Tools/ComponentToolTips.swift`, which answers the same question for a
// component already placed on the canvas. That one is
// `com.cburch.logisim.gui.main.Canvas.getToolTipText(MouseEvent)`. This one is the toolbar:
//
//   `com.cburch.draw.toolbar.ToolbarButton.<init>` calls `setToolTipText("")`, which is how a
//   Swing component registers with `ToolTipManager` at all: and overrides
//   `getToolTipText(MouseEvent)` to `return item.getToolTip()`.
//   `com.cburch.logisim.gui.main.LayoutToolbarModel$ToolItem.getToolTip()` returns
//   `tool.getDescription()`, then appends a shortcut hint (see below).
//
// Measured with `javap -c -p` against the shipping 4.1.0 jar at
// `/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar`, NOT against
// this repository's `src/main/java`, which is upstream *main* and not 4.1.0. (D16.)
//
// ── SO THIS IS A FIDELITY GAP, NOT A NICE-TO-HAVE ───────────────────────────────────────────
//
// Every button in 4.1.0's toolbar has a hover tip. The port's window-toolbar tool row had none,
// see `EditorToolbar.swift` for the mechanism that swallowed it, so five unlabelled glyphs sat
// in the title bar with nothing to say what they were. Reported from real use as exactly that.
//
// ── THE STRINGS ARE UPSTREAM'S, VERBATIM ────────────────────────────────────────────────────
//
// From `resources/logisim/strings/tools/tools.properties` inside the same jar:
//
//     pokeToolDesc   = Change values within circuit
//     editToolDesc   = Edit selection and add wires
//     selectToolDesc = Edit circuit components
//     wiringToolDesc = Add wires to circuit
//     textToolDesc   = Edit text in circuit
//     menuToolDesc   = View component menus
//     addToolText    = Add %s
//
// The port had its own invented sentences here ("Change input values while the simulation runs.",
// "Draw wires between component ports.", …). They were not wrong, but a Logisim user reading the
// manual or coming from 4.1.0 has already learnt upstream's wording, and matching it costs
// nothing. Upstream's are also terser, which is what a tip that has to be read in a hover-delay
// wants to be. So upstream's win and the invented ones are gone.
//
// ── THE ONE THING DELIBERATELY *NOT* COPIED: THE SHORTCUT HINT ──────────────────────────────
//
// 4.1.0 appends a keyboard hint to every tip. Its `makeConcatWithConstants` bootstrap constant
// , readable with `javap -v`, and printed by javap as `\u0001 (\u0001-\u0001)`, spells
// `description + " (" + InputEventUtil.toKeyDisplayString(mask) + "-" + index + ")"`, where
// `index` counts tool items (not separators) from 1, maps 10 to 0, and is omitted past 10.
// On macOS `getMenuShortcutKeyMaskEx()` is `META_DOWN_MASK`, and `util.properties` renders that
// as `metaMod = Meta`, so 4.1.0's first button really does read "Change values within circuit
// (Meta-1)".
//
// It is a true statement upstream, because `KeyboardToolSelection.register` binds ⌘0…⌘9 to the
// toolbar's first ten tools. **This port binds nothing of the kind**; `ToolItem.shortcutCharacter`
// is populated but is only ever *drawn* as a grey hint in the sidebar (`ExplorerSidebar.swift`),
// never turned into a `.keyboardShortcut`. Reproducing the suffix here would put a shortcut in
// front of the user that does nothing when pressed, which is worse than saying nothing. So the
// suffix is omitted until the binding exists; see this branch's report for that follow-up.
// ═════════════════════════════════════════════════════════════════════════════════════════════

/// The string a hover over a tool button shows, as a pure function of the `ToolItem`.
///
/// Pure on purpose, and for the same reason `ComponentToolTips` is: a tool tip is a floating panel
/// AppKit puts up after a delay inside a real window, and the only part of it a test with no window
/// can reach is the function underneath. Every surface that draws a tool button, the window
/// toolbar, the palette strip, calls this, so there is one answer per tool rather than one per
/// view.
enum ToolButtonToolTips {

  /// 4.1.0's `*Desc` strings, keyed on the tool `_ID`.
  ///
  /// Keyed on the `_ID` and not on the button label, because the label is lossy: `EditTool._ID`
  /// and `SelectTool._ID` both render as "Select" (`ToolSymbols.editingDisplayName`) and upstream
  /// gives them *different* sentences. `ToolIcons` hit the same wall and documented the same fix;
  /// `ToolItem` should carry the `_ID` alongside the label. Until it does, the only caller that
  /// can key this correctly is the outline builder, which still has the `_ID` in hand.
  static let upstreamBaseDescriptions: [String: String] = [
    BaseToolIds.poke: "Change values within circuit",
    BaseToolIds.edit: "Edit selection and add wires",
    BaseToolIds.select: "Edit circuit components",
    BaseToolIds.wiring: "Add wires to circuit",
    BaseToolIds.textTool: "Edit text in circuit",
    BaseToolIds.menu: "View component menus",
  ]

  /// `Tool.getDescription()` for `#Base`'s tools. `nil` for anything else; an `AddTool` answers
  /// through `addToolText` instead.
  static func upstreamDescription(forToolNamed id: String) -> String? {
    upstreamBaseDescriptions[id]
  }

  /// `AddTool.getDescription()`'s last resort: `S.get("addToolText", getDisplayName())`, and
  /// `tools.properties` has `addToolText = Add %s`.
  ///
  /// It is the *last* resort upstream too: `AddTool` first tries its `FactoryDescription`'s tool
  /// tip, then the factory's `TOOL_TIP` feature. This port has neither: `Tool.toolDescription` is
  /// declared `open var … { "" }` in `LibraryModel.swift` and is overridden by nothing, so every
  /// library tool falls through to here. That is why a palette gate says "Add AND Gate" and not
  /// something more specific; the specific text is a `FactoryDescription` port that has not
  /// happened. Reported rather than faked.
  static func addToolText(_ displayName: String) -> String { "Add \(displayName)" }

  /// What the button shows.
  ///
  /// Precedence, and why:
  ///
  ///   1. `unavailableReason`; a D11/D8 tool that cannot be placed. The reason is the single most
  ///      useful thing a hover can say about it, and this is the order `ExplorerSidebar` already
  ///      uses for its own rows.
  ///   2. `summary`, which for a `#Base` tool is `ToolSymbols.editingSummary`, i.e. exactly the
  ///      `upstreamBaseDescriptions` entry above, resolved back when the `_ID` was still in hand.
  ///   3. `Add <name>`; upstream's `addToolText` for everything else.
  ///
  /// Note what is *not* in the list: the bare `item.name`. The name is what the button's
  /// accessibility label already says and, for a glyph the user cannot read, repeating it adds
  /// nothing. Every branch here returns a sentence.
  static func text(for item: ToolItem) -> String {
    if let reason = item.unavailableReason, !reason.isEmpty { return reason }
    if let summary = item.summary, !summary.isEmpty { return summary }
    return addToolText(item.name)
  }
}
