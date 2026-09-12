// HexGridView.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.hex.HexEditor.paintComponent, Caret.paintForeground
// and Caret.Listener, Highlighter.paint), https://github.com/logisim-evolution/logisim-evolution.
// Copyright by the Logisim-evolution developers. This translation is a derivative work and is
// therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Why rows and not one Canvas ─────────────────────────────────────────────────────────────
//
// `paintComponent` draws the whole grid in one pass, clipped by Swing to the exposed rectangle.
// A single `Canvas` here would have to be the full content size, and the full content size of a
// 24-bit memory is a million rows; 16.7 million points tall. So the grid is a `LazyVStack` of
// one-row canvases: the lazy stack does the clipping `getClipBounds` was doing, and each row lays
// its own cells out with `HexMeasures.x(of:)`, the same arithmetic upstream uses.
//
// Hit testing goes through `HexMeasures.address(atX:y:)`, upstream's `toAddress`, rather than
// through per-cell tap targets, because that function *is* the spec for which cell a click lands
// in, including its two integer-division fudge factors. Giving each cell its own gesture would
// look identical and quietly be a second, divergent implementation of the same rule.
//
// ── Colours ─────────────────────────────────────────────────────────────────────────────────
//
// Upstream hard-codes white behind the grid and `new Color(192, 192, 255)` behind the selection.
// A hard-coded white background is unreadable in dark mode, so the surfaces here are semantic and
// only the selection keeps upstream's hue, as a tint: the same choice, for the same reason, as
// the #2661 note in `Palette.swift`.

import AppKit
import SwiftUI

extension HexFontMetrics {
  /// `Measures.computeCellSize`'s `fm != null` branch, against a real `NSFont`.
  ///
  /// `charWidth` is the widest of the sixteen hex digits, not the font's average advance; the
  /// grid's columns must not shuffle when a `1` becomes a `0`. For a monospaced font every digit
  /// measures the same and the loop is a formality; it is kept because nothing guarantees the
  /// font stays monospaced.
  @MainActor
  public static func measured(font: NSFont) -> HexFontMetrics {
    var charWidth = 0
    for i in 0..<16 {
      let digit = String(i, radix: 16)
      let width = Int((digit as NSString).size(withAttributes: [.font: font]).width.rounded(.up))
      charWidth = max(charWidth, width)
    }
    let spaceWidth = Int((" " as NSString).size(withAttributes: [.font: font]).width.rounded(.up))
    // `FontMetrics.getHeight()`, ascent + descent + leading.
    let lineHeight = Int((font.ascender - font.descender + font.leading).rounded(.up))
    return HexFontMetrics(
      charWidth: max(1, charWidth),
      spaceWidth: max(1, spaceWidth),
      lineHeight: max(1, lineHeight),
      guessed: false)
  }
}

/// The scrolling hex grid.
public struct HexGridView: View {
  @Bindable private var model: HexEditorModel
  private let pointSize: CGFloat
  private let font: NSFont
  @FocusState private var focused: Bool

  public init(model: HexEditorModel, pointSize: CGFloat = 12) {
    self.model = model
    self.pointSize = pointSize
    self.font = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
  }

  public var body: some View {
    GeometryReader { proxy in
      ScrollViewReader { scroller in
        ScrollView(.vertical) {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(0..<model.rowCount, id: \.self) { row in
              HexRowView(model: model, row: row, pointSize: pointSize)
                .frame(
                  width: CGFloat(model.measures.preferredWidth),
                  height: CGFloat(model.measures.cellHeight))
                .id(row)
            }
          }
        }
        .onChange(of: model.caret.dot) { _, dot in
          // `Caret.expose(loc, scrollTo: true)`, `hex.scrollRectToVisible`.
          guard dot >= 0, model.measures.columnCount > 0 else { return }
          let row = Int((dot - model.measures.baseAddress) / Int64(model.measures.columnCount))
          scroller.scrollTo(row)
        }
      }
      .background(Color(nsColor: .textBackgroundColor))
      .onAppear {
        syncLayout(proxy.size)
        focused = true
      }
      .onChange(of: proxy.size) { _, size in syncLayout(size) }
      .focusable()
      .focused($focused)
      .onKeyPress(phases: .down) { press in handle(press) }
    }
  }

  /// `HexEditor.setBounds` → `measures.widthChanged()`, plus the visible-row count the two paging
  /// motions need (`hex.getVisibleRect().height / measures.getCellHeight()`).
  private func syncLayout(_ size: CGSize) {
    model.updateLayout(
      viewWidth: Int(size.width.rounded(.down)), metrics: .measured(font: font))
    let cellHeight = model.measures.cellHeight
    model.visibleRows = cellHeight > 0 ? max(1, Int(size.height) / cellHeight) : 1
  }

  /// `Caret.Listener.keyPressed` and `keyTyped` together.
  ///
  /// The backspace and forward-delete cases are upstream's, and are surprising on a Mac: the key
  /// labelled Delete sends backspace, which upstream maps to "move left", **not** to clearing the
  /// cell; forward-delete clears. Preserved rather than swapped; the Edit menu's Delete command
  /// is the intended way to clear a selection, and rebinding a key here would be a divergence no
  /// gate could see.
  private func handle(_ press: KeyPress) -> KeyPress.Result {
    let shift = press.modifiers.contains(.shift)
    let control = press.modifiers.contains(.control)

    let motion: HexCaretMotion?
    switch press.key {
    case .upArrow: motion = .up
    case .downArrow: motion = .down
    case .leftArrow: motion = .left
    case .rightArrow: motion = .right
    case .home: motion = .home
    case .end: motion = .end
    case .pageUp: motion = .pageUp
    case .pageDown: motion = .pageDown
    case .space: motion = control ? .pageDown : .right  // keyTyped ' '
    case .return: motion = control ? .up : .down  // keyTyped '\n'
    case .delete: motion = .left  // keyTyped '\u{08}'
    default: motion = nil
    }
    if let motion {
      model.move(motion, extendingSelection: shift)
      return .handled
    }

    if press.key == .deleteForward {  // keyTyped '\u{7f}'
      if control {
        model.move(.pageUp, extendingSelection: shift)
      } else {
        try? model.deleteSelection()
      }
      return .handled
    }

    guard let character = press.characters.first else { return .ignored }
    return (try? model.type(character)) == true ? .handled : .ignored
  }
}

/// One row of the grid: the italic address label, then that row's words.
struct HexRowView: View {
  var model: HexEditorModel
  var row: Int
  var pointSize: CGFloat

  var body: some View {
    // Read the change counter here so this row, and only the visible rows, redraws when a word
    // changes. `MemContents` is not observable and must not become so (D9); the counter is the
    // whole adaptation.
    let generation = model.revision
    let measures = model.measures
    let dot = model.caret.dot
    let selection = model.caret.selection

    Canvas { context, _ in
      _ = generation
      draw(in: &context, measures: measures, dot: dot, selection: selection)
    }
    .contentShape(Rectangle())
    // A press selects; a drag extends. `Caret.Listener.mousePressed` reads the shift modifier for
    // the same purpose, which SwiftUI does not surface on a tap, so it is read from AppKit.
    .onTapGesture { location in
      select(at: location, extending: NSEvent.modifierFlags.contains(.shift))
    }
    .gesture(
      DragGesture(minimumDistance: 1)
        .onChanged { value in select(at: value.location, extending: true) }
        .onEnded { value in select(at: value.location, extending: true) }  // `mouseReleased`
    )
  }

  /// `measures.toAddress(e.getX(), e.getY())`. The row's own `y` is added back because
  /// `toAddress` works in whole-grid coordinates.
  private func select(at point: CGPoint, extending: Bool) {
    let measures = model.measures
    let y = row * measures.cellHeight + Int(point.y.rounded(.down))
    model.selectCell(atX: Int(point.x.rounded(.down)), y: y, extendingSelection: extending)
  }

  private func draw(
    in context: inout GraphicsContext,
    measures: HexMeasures,
    dot: Int64,
    selection: ClosedRange<Int64>?
  ) {
    let rowY = row * measures.cellHeight
    let cellHeight = CGFloat(measures.cellHeight)

    // `Highlighter.paint`, for this row's slice of the one selection range.
    if let selection {
      for column in 0..<measures.columnCount {
        let address = model.address(row: row, column: column)
        guard selection.contains(address) else { continue }
        let x = CGFloat(measures.x(of: address) - measures.baseX)
        context.fill(
          Path(CGRect(x: x, y: 0, width: CGFloat(measures.cellWidth), height: cellHeight)),
          with: .color(Self.selectionColor))
      }
    }

    // `paintComponent`'s italic address label, centred in the label gutter.
    var label = context.resolve(
      Text(model.rowLabel(row)).font(.system(size: pointSize, design: .monospaced).italic()))
    label.shading = .color(.secondary)
    context.draw(
      label, in: CGRect(x: 0, y: 0, width: CGFloat(measures.labelWidth), height: cellHeight))

    for column in 0..<measures.columnCount {
      let address = model.address(row: row, column: column)
      // `if (b >= addr0 && b <= addr1)`; the ragged tail of the last row draws nothing.
      guard let text = model.cellText(at: address) else { continue }
      var word = context.resolve(
        Text(text).font(.system(size: pointSize, design: .monospaced)))
      word.shading = .color(.primary)
      let x = CGFloat(measures.x(of: address) - measures.baseX)
      context.draw(
        word, in: CGRect(x: x, y: 0, width: CGFloat(measures.cellWidth), height: cellHeight))
    }

    // `Caret.paintForeground`: a two-point rectangle around the cursor's cell.
    if dot >= 0, measures.y(of: dot) == rowY {
      let x = CGFloat(measures.x(of: dot) - measures.baseX)
      context.stroke(
        Path(
          CGRect(
            x: x, y: 0,
            width: CGFloat(measures.cellWidth - 1), height: cellHeight - 1)),
        with: .color(.accentColor),
        lineWidth: 2)
    }
  }

  /// `Caret.SELECT_COLOR` = `new Color(192, 192, 255)`, carried as a tint so the text under it
  /// stays legible in the dark appearance.
  private static let selectionColor = Color(
    .sRGB, red: 192.0 / 255.0, green: 192.0 / 255.0, blue: 1.0, opacity: 0.55)
}
