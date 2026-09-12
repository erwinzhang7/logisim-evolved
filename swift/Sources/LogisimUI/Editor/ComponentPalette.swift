// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE COMPONENT PALETTE.
//
// The document's own `<toolbar>`, `Options.toolbarData`, rendered as a strip under the window
// toolbar, where a drawing app puts its pen tray.
//
// ── WHY THIS EXISTS ─────────────────────────────────────────────────────────────────────────
//
// `ToolbarData` was parsed by the codec, stored on `Options`, round-tripped byte-exactly by the
// M2 gate across 539 canonical files, and **read by no view**. The window rendered
// `ProjectOutline.editingTools`, which is `#Base`'s five canvas tools, so the application showed
// five buttons where the default template declares seventeen entries: the four canvas tools, an
// input and an output Pin, NOT / AND / OR / XOR / NAND / NOR, then D Flip-Flop and Register.
// Reported from the running app as "less tools than logisim-evolution", which is what it was.
//
// Every hop existed and had a plausible name. Only the last one, a view actually reading the
// parsed data, was missing, and the result read as a deliberately minimal design.
//
// ── WHY A SEPARATE STRIP AND NOT MORE NSTOOLBAR ITEMS ───────────────────────────────────────
//
// The window toolbar keeps the *modes* (poke / edit / wire / text): a radio group, four items,
// the shape `NSToolbar` is good at. Placing is a different question and a longer list, it grows
// with the document, since a user can drag any library tool onto their toolbar, and a title bar
// that reflows on every document is worse than a strip that manages its own overflow.
//
// ── OVERFLOW, NOT SCROLL ────────────────────────────────────────────────────────────────────
//
// What does not fit collapses into a `⋯` menu at the right end. A horizontal scroller hides the
// same tools behind a gesture with no affordance saying they exist; the menu says so. The split
// itself is `PaletteLayout.split`, a pure function, tested without a window.
//
// ── THE ICONS ARE 4.1.0'S, NOT THIS PORT'S ──────────────────────────────────────────────────
//
// Every button used to be `Label(item.name, systemImage: item.symbolName)`: an SF Symbol from
// a table hand-written in `ProjectOutlineBuilder`, which gave the gate row a pill (AND), a
// shield (OR) and an ✗-in-a-circle (XOR). It now goes through `ToolIconView`, which draws
// 4.1.0's own ANSI gate geometry where that has been transcribed and falls back to the symbol
// where it has not. See `Icons/ToolIcons.swift` for the provenance of each glyph.
//
// ── SELECT SITS LEFT OF POKE, AND THAT IS A DELIBERATE DEVIATION ────────────────────────────
//
// The default template's `<toolbar>` opens `Poke, Edit, Wiring, Text`, so 4.1.0's leftmost
// button is Poke and this port faithfully reproduced that. It is a bad first button. Reported
// from first use as "poke does nothing when I drag", which is **correct upstream behaviour**,
// not a bug: `PokeTool` pokes values and `SelectTool` drags, and a drag with Poke selected is
// supposed to do nothing. The defect is discoverability. The pointer is what a user reaches for
// first in every other editor on this platform, and putting it first is how a toolbar says so.
//
// So this is a UI decision, not a fidelity fix, and it is confined to *presentation*:
// `PaletteLayout.presentationOrder` reorders the array on its way to the screen and nothing
// writes back, so `Options.toolbarData`, and therefore the saved `.circ`, keeps file order and
// M2's byte-exactness gate is untouched.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import SwiftUI

struct ComponentPalette: View {
  @Bindable var model: EditorModel

  var body: some View {
    if !model.outline.toolbarItems.isEmpty {
      // `GeometryReader` fills its parent, so the height is pinned rather than inherited;
      // otherwise the strip takes half the window.
      GeometryReader { proxy in
        row(fitting: proxy.size.width)
      }
      .frame(height: 32)
      .background(.bar)
      .overlay(alignment: .bottom) { Divider() }
    }
  }

  private func row(fitting width: CGFloat) -> some View {
    let ordered = PaletteLayout.presentationOrder(model.outline.toolbarItems)
    let split = PaletteLayout.split(ordered, availableWidth: width)
    return HStack(spacing: 2) {
      ForEach(split.visible) { entry in
        switch entry {
        case .separator:
          Divider().frame(height: 18).padding(.horizontal, 6)
        case .tool(let item):
          button(for: item)
        }
      }
      if split.hasOverflow {
        Spacer(minLength: 0)
        overflowMenu(split.overflow)
      }
    }
    .padding(.horizontal, 10)
    .frame(height: 32)
  }

  private func button(for item: ToolItem) -> some View {
    Button {
      model.select(tool: item.id)
    } label: {
      ToolIconView(item: item)
        .frame(width: 26, height: 22)
    }
    .buttonStyle(.borderless)
    // The active tool is highlighted here as well as in the window toolbar, because selecting a
    // gate here IS a mode change; it puts the canvas on that `AddTool`.
    .background {
      if model.activeTool == item.id {
        RoundedRectangle(cornerRadius: 5).fill(.selection)
      }
    }
    // `ToolButtonToolTips.text(for:)`, not `item.summary ?? item.name`, which is what this was.
    // The old fallback meant a gate's tip repeated the accessibility label: hovering "AND Gate"
    // said "AND Gate", where 4.1.0's `AddTool.getDescription()` says "Add AND Gate". Same
    // resolver as the window toolbar, so the two rows cannot drift apart. See `PaletteLayout.swift`.
    .help(ToolButtonToolTips.text(for: item))
    .accessibilityLabel(item.name)
  }

  private func overflowMenu(_ entries: [ToolbarEntry]) -> some View {
    // Drop leading separators for DISPLAY only. The split keeps them so `visible + overflow` is
    // the whole list -- deleting one there is the bug the totality test caught -- but a menu that
    // opens with a divider looks broken.
    var body = entries
    while case .separator = body.first { body.removeFirst() }
    return Menu {
      ForEach(body) { entry in
        switch entry {
        case .separator:
          Divider()
        case .tool(let item):
          Button {
            model.select(tool: item.id)
          } label: {
            // A `Menu`'s rows are `NSMenuItem`s, which take an `NSImage`, not an arbitrary
            // `View`; a `Canvas`-drawn glyph would silently render as nothing here. So the
            // overflow list keeps the SF Symbol, and the icon it shows is the same one the
            // catalog would draw for tools that have no upstream glyph.
            Label(item.name, systemImage: ToolIcons.menuSymbol(for: item))
          }
          // A menu row already reads its own name, so this is not the "unlabelled glyph" case the
          // strip has. It is here so the overflow answers the same question the strip does when a
          // window is narrow enough to push a tool into it; a tool must not become *less*
          // described by being hidden.
          .help(ToolButtonToolTips.text(for: item))
        }
      }
    } label: {
      Label("More Tools", systemImage: "ellipsis")
        .labelStyle(.iconOnly)
    }
    .menuIndicator(.hidden)
    .fixedSize()
    // Named for what it holds, so the tools are findable by voice control and by anyone who
    // cannot tell what "⋯" is hiding.
    .help("\(entries.compactMap(\.item).count) more tools")
    .accessibilityLabel("More tools")
  }
}
