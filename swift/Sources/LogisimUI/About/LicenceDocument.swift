// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md at the repository root.
//
// ============================================================================
// RENDERING 32 KB OF LEGAL TEXT SO IT CAN ACTUALLY BE READ.
//
// GPLv3 §5(d) says the notices must be *displayed*. Dumping the raw file into a
// monospaced `TextEditor` technically satisfies that and in practice guarantees nobody
// reads it, which is not the spirit of a clause whose whole purpose is that recipients
// learn their rights. So the markdown is parsed into blocks and typeset: real headings,
// real hanging-indented lettered clauses, real emphasis on the defined terms the Licence
// italicises (*aggregate*, *Corresponding Source*, *System Libraries*…).
//
// The parse is deliberately tiny and total. It handles exactly the four constructs
// `LICENSE.md` uses, ATX headings, blank-line-separated paragraphs, `- a)` clause lists
// and `1.` sub-lists, and treats anything unrecognised as a paragraph. It cannot fail,
// cannot drop text, and cannot reorder it: every source line ends up in exactly one block,
// which is the only property that matters for a document whose accuracy is a legal
// requirement rather than a nicety.
//
// Note what is NOT done: no rewriting, no reflowing of the substance, no "summary". The
// displayed words are the file's words.
// ============================================================================

import SwiftUI

/// `LICENSE.md`, parsed once into displayable blocks.
struct LicenceDocument: Sendable {

  struct Block: Identifiable, Sendable {
    enum Kind: Sendable {
      case heading(level: Int)
      case paragraph
      case list
    }

    var id: Int
    var kind: Kind
    /// Heading/paragraph text, or the joined item texts for a list.
    var text: String
    /// Populated for `.list` only: one entry per clause, `depth` 0 for `a)`-level items
    /// and 1 for the nested `1.` sub-items.
    var items: [Item] = []
    /// Set on `### N.` headings, so the section menu can offer "6. Conveying Non-Source
    /// Forms" and scroll straight to it.
    var sectionNumber: Int?

    struct Item: Identifiable, Sendable {
      var id: Int
      var depth: Int
      var text: String
    }
  }

  var blocks: [Block]

  /// The shared parse of the embedded licence. Parsing ~600 lines is microseconds, but the
  /// About window is opened and closed repeatedly and there is no reason to redo it.
  static let gplv3 = LicenceDocument(markdown: GPLv3Text.markdown)

  init(markdown: String) {
    var blocks: [Block] = []
    var nextID = 0

    // Blank lines are the block separator throughout the file; nothing in it relies on
    // trailing-space breaks or fenced blocks.
    for chunk in markdown.components(separatedBy: "\n\n") {
      let lines = chunk.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
      guard !lines.isEmpty else { continue }

      let first = lines[0]
      if let (level, title) = Self.heading(first) {
        blocks.append(
          Block(id: nextID, kind: .heading(level: level), text: title,
                sectionNumber: Self.sectionNumber(of: title)))
        nextID += 1
        // A heading chunk is a heading alone in this file; anything following it in the
        // same chunk would still be text, so fold it into a paragraph rather than lose it.
        let rest = lines.dropFirst().joined(separator: " ")
        if !rest.isEmpty {
          blocks.append(Block(id: nextID, kind: .paragraph, text: rest))
          nextID += 1
        }
        continue
      }

      if Self.marker(first) != nil {
        var items: [Block.Item] = []
        for line in lines {
          if let (indent, content) = Self.marker(line) {
            items.append(
              Block.Item(id: items.count, depth: indent >= 2 ? 1 : 0, text: content))
          } else if !items.isEmpty {
            // Continuation of the current clause; the source hard-wraps at ~78 columns
            // and we re-flow to the view's width.
            items[items.count - 1].text += " " + line.trimmingCharacters(in: .whitespaces)
          } else {
            items.append(Block.Item(id: 0, depth: 0, text: line))
          }
        }
        blocks.append(
          Block(id: nextID, kind: .list, text: items.map(\.text).joined(separator: "\n"),
                items: items))
        nextID += 1
        continue
      }

      blocks.append(
        Block(
          id: nextID, kind: .paragraph,
          text: lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")))
      nextID += 1
    }

    self.blocks = blocks
  }

  /// `### 6. Conveying Non-Source Forms.` and friends, for the jump menu.
  var sections: [Block] {
    blocks.filter { $0.sectionNumber != nil }
  }

  // MARK: - Line classification

  private static func heading(_ line: String) -> (level: Int, title: String)? {
    var hashes = 0
    var index = line.startIndex
    while index < line.endIndex, line[index] == "#" {
      hashes += 1
      index = line.index(after: index)
    }
    guard hashes > 0, index < line.endIndex, line[index] == " " else { return nil }
    return (hashes, String(line[index...]).trimmingCharacters(in: .whitespaces))
  }

  /// Returns the leading indent and the clause text with its bullet removed but its own
  /// label, `a)`, `1.`, intact, because the Licence cross-references those labels
  /// ("in accord with subsection 6b") and stripping them would break the text.
  private static func marker(_ line: String) -> (indent: Int, content: String)? {
    let indent = line.prefix { $0 == " " }.count
    var rest = Substring(line.dropFirst(indent))

    if rest.hasPrefix("- ") {
      rest = rest.dropFirst(2)
      return (indent, String(rest).trimmingCharacters(in: .whitespaces))
    }

    // `1. `, `2. ` … keep the number: it is the clause's name.
    let digits = rest.prefix(while: \.isNumber)
    if !digits.isEmpty, rest.dropFirst(digits.count).hasPrefix(". ") {
      return (indent, String(rest).trimmingCharacters(in: .whitespaces))
    }
    return nil
  }

  private static func sectionNumber(of title: String) -> Int? {
    let digits = title.prefix(while: \.isNumber)
    guard !digits.isEmpty, title.dropFirst(digits.count).hasPrefix(".") else { return nil }
    return Int(digits)
  }
}

// MARK: - View

/// The full licence, scrollable, selectable, and navigable.
struct LicenceView: View {
  var document: LicenceDocument = .gplv3

  var body: some View {
    VStack(spacing: 0) {
      integrityBanner
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(document.blocks) { block in
              blockView(block).id(block.id)
            }
          }
          .textSelection(.enabled)
          .frame(maxWidth: 680, alignment: .leading)
          .padding(.horizontal, 28)
          .padding(.vertical, 24)
          .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
          sectionBar(proxy: proxy)
        }
      }
    }
  }

  /// Shown only when the embedded text no longer matches the digest recorded at
  /// generation time; see `AboutFacts.embeddedLicenceIsIntact`. It should never appear;
  /// if it does, what is on screen may not be the licence this build ships under, and
  /// saying so is strictly better than looking authoritative while being wrong.
  @ViewBuilder private var integrityBanner: some View {
    if !AboutFacts.embeddedLicenceIsIntact {
      Label(
        "This copy of the licence text does not match the version recorded at build time. "
          + "Refer to LICENSE.md in the source distribution.",
        systemImage: "exclamationmark.triangle.fill"
      )
      .font(.callout)
      .padding(.horizontal, 20)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.yellow.opacity(0.18))
    }
  }

  private func sectionBar(proxy: ScrollViewProxy) -> some View {
    HStack(spacing: 10) {
      Text("GNU General Public License, version 3")
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
      Spacer(minLength: 8)
      Menu {
        Button("Top") { withAnimation { proxy.scrollTo(0, anchor: .top) } }
        Divider()
        ForEach(document.sections) { section in
          Button(section.text) {
            withAnimation { proxy.scrollTo(section.id, anchor: .top) }
          }
        }
      } label: {
        Label("Jump to Section", systemImage: "list.bullet.indent")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 8)
    .background(.bar)
  }

  @ViewBuilder private func blockView(_ block: LicenceDocument.Block) -> some View {
    switch block.kind {
    case .heading(let level):
      Text(block.text)
        .font(headingFont(level))
        .padding(.top, level <= 2 ? 18 : 10)

    case .paragraph:
      Text(inline(block.text))
        .font(.body)
        .lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)

    case .list:
      VStack(alignment: .leading, spacing: 8) {
        ForEach(block.items) { item in
          Text(inline(item.text))
            .font(.body)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, CGFloat(item.depth) * 22)
        }
      }
      .padding(.leading, 16)
    }
  }

  private func headingFont(_ level: Int) -> Font {
    switch level {
    case 1: .title.weight(.semibold)
    case 2: .title3.weight(.semibold)
    default: .headline
    }
  }

  /// Inline markdown only; the Licence italicises its defined terms and we honour that.
  /// Block syntax is already handled by the parser, and letting the markdown engine see it
  /// would let a leading `1.` silently become a renumbered list item.
  private func inline(_ text: String) -> AttributedString {
    (try? AttributedString(
      markdown: text,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
  }
}
