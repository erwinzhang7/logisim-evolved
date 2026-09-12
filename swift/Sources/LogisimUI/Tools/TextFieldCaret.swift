// TextFieldCaret.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.comp.TextFieldCaret and the
// com.cburch.logisim.util.GraphicsUtil text-cursor helpers it calls),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── THE CARET HALF OF `comp.TextField*`, AND WHY IT IS UP HERE ──────────────────────────────
//
// `LogisimStd/Instance/TextField.swift` carries the model half and states the split in full. The
// short version: `TextFieldCaret` implements `com.cburch.logisim.tools.Caret` and it *draws*:
// a yellow edit box, a dark-grey border, a blue selection band and a cursor rule
// (`TextFieldCaret.java:80-113`). `Caret`, `ToolMouseEvent`, `ToolKeyEvent` and `RenderScene` are
// all declared in this module, and D9 forbids dragging them down into `LogisimStd` to keep a
// Java package together. So the caret lives here and holds a `LogisimStd.TextField`.
//
// ── DELIBERATE macOS DIVERGENCES FROM AWT, EACH ONE FORCED ──────────────────────────────────
//
// Upstream's `keyPressed` opens with
//
//     final var ign = InputEvent.ALT_DOWN_MASK | InputEvent.META_DOWN_MASK;
//     if ((e.getModifiersEx() & ign) != 0) return;
//
// i.e. **any** Alt or Meta chord is ignored outright, and every editing chord below it is spelled
// with Control (Ctrl-A select all, Ctrl-C/X/V clipboard, Ctrl-arrow word movement). Transcribing
// that literally would produce an editor in which ⌘A, ⌘C, ⌘V and ⌥-arrow all do nothing, and in
// which Control-C, which macOS does not use for copy anywhere, is the only way to copy. That
// is not a port of the behaviour, it is a port of the key codes. The objectives call for
// "deliberate macOS modifier conventions, not literal AWT translation", so:
//
//   * **Command replaces Control** for `A` / `C` / `X` / `V`. Same actions, platform chord.
//   * **Option replaces Control** for word-wise arrow movement. ⌥← / ⌥→ is the macOS idiom;
//     Control-arrow is taken by Mission Control.
//   * **⌘← / ⌘→ are Home / End.** AWT reads the literal Home and End keys, which Mac keyboards
//     mostly do not have, and which `CanvasToolController.command(for:)` does not map, so
//     `rawKeyCode` for them is 0 and the AWT arm would be unreachable even if it were written.
//     ⌘←/⌘→ is what every macOS text field does. The literal Home/End key codes are accepted too
//     when the shell ever starts sending them; that arm is written and currently unreachable.
//   * **Return commits.** AWT sees `VK_ENTER` in `keyPressed` *and* `'\n'` in `keyTyped`; this
//     port's key path delivers neither (`AwtKeyCodes.virtualKeyCode` has no Return entry, and
//     `canvasHandleKey` deliberately suppresses `keyTyped` for a newline). The commit is driven
//     off the character being a newline, which is the one signal that does arrive.
//   * **Option no longer suppresses typing.** AWT ignores Alt in `keyTyped`; on macOS Option is
//     a character-composition modifier (⌥5 is ∞, ⌥e is an acute accent), so suppressing it would
//     make a whole layer of the keyboard untypeable. Command and Control still suppress, because
//     those really are command chords here.
//
// Everything else is transcribed: `moveCaret`'s selection collapse, the word-boundary walk,
// `normalizeSelection`, the backspace/delete asymmetry, Escape-cancels, and the `findCaret`
// midpoint rule.
//
// ── ONE MORE, AND IT IS NOT A MODIFIER ──────────────────────────────────────────────────────
//
// `pos` and `end` are **Character offsets**, where Java's are UTF-16 code-unit offsets. A caret
// stepping through `"👍"` in AWT lands between the two surrogates and can delete half a
// character; here it steps over the whole grapheme. That is the correct behaviour on this
// platform and it is observable, so it is written down rather than left to be discovered.

import AppKit
import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimRenderBackend
import LogisimStd

/// `com.cburch.logisim.comp.TextFieldCaret`: the in-place text editing session.
///
/// `@preconcurrency` on the `TextFieldListener` conformance, and it is the honest annotation
/// rather than a silencer. `TextFieldListener` is declared in `LogisimStd`, which builds in the
/// Swift 5 language mode with no Swift Concurrency at all (D1; a component's `propagate` runs on
/// the simulation thread), so the protocol carries no isolation. This caret is `@MainActor`
/// because every `Caret` is. The two meet on a callback that upstream fires **synchronously**
/// inside `field.setText` and whose ordering `stopEditing` depends on, so hopping it to the main
/// actor (the `CircuitListener` treatment, see `TextCaretListener`) would reorder the commit
/// against the listeners that read it. `@preconcurrency` keeps the call synchronous and turns the
/// crossing into a runtime isolation check; every caller is a tool on the main actor.
@MainActor
public final class TextFieldCaret: AbstractCaret, @preconcurrency TextFieldListener {

  /// `EDIT_BACKGROUND`: `new Color(0xff, 0xff, 0x99)`.
  ///
  /// `LogisimRender.RGBA` spelled in full: this module declares an `RGBA` of its own and the
  /// bare name resolves to that one.
  public static let editBackground = SceneColor.rgba(
    LogisimRender.RGBA(r: 0xFF, g: 0xFF, b: 0x99))
  /// `EDIT_BORDER`: `Color.DARK_GRAY`, which AWT defines as `(64, 64, 64)`.
  public static let editBorder = SceneColor.rgba(LogisimRender.RGBA(r: 0x40, g: 0x40, b: 0x40))
  /// `SELECTION_BACKGROUND`: `new Color(0x99, 0xcc, 0xff)`.
  public static let selectionBackground = SceneColor.rgba(
    LogisimRender.RGBA(r: 0x99, g: 0xCC, b: 0xFF))

  /// `field`.
  public let field: TextField

  /// The `InstanceTextField` that produced this caret, held **strongly**.
  ///
  /// Load-bearing, not bookkeeping. `TextField.listeners` is weak (D3: see its header), and the
  /// `InstanceTextField` is the listener that writes the committed string back into the
  /// component's attribute set. Nothing else refers to it, so without this field it would be
  /// collected the instant `textCaret(_:)` returned and the commit would silently write nothing.
  private let owner: (any TextFieldListener)?

  /// Upstream reaches its `FontMetrics` through the `Graphics` it was constructed with. There is
  /// no `Graphics` in this port (D6), so the metrics source is injected and is the same one the
  /// canvas renders with, which is what makes `bounds` the box the user actually sees.
  private let measurer: any TextMeasurer

  private var oldText: String
  private var characters: [Character]
  /// `pos`: the moving end of the selection, and the insertion point when `pos == end`.
  private var pos: Int
  /// `end`: the anchored end of the selection.
  private var end: Int

  /// `getText()`.
  public override var text: String { String(characters) }

  /// `TextFieldCaret(TextField, Graphics, int pos)`.
  public init(
    field: TextField, owner: (any TextFieldListener)?, measurer: any TextMeasurer, position: Int
  ) {
    self.field = field
    self.owner = owner
    self.measurer = measurer
    self.oldText = field.text
    self.characters = Array(field.text)
    let clamped = min(max(position, 0), field.text.count)
    self.pos = clamped
    self.end = clamped
    super.init()
    field.addTextFieldListener(self)
    syncBounds()
  }

  /// `TextFieldCaret(TextField, Graphics, int x, int y)`, which delegates to the `pos` form and
  /// then overwrites `pos`/`end` from `findCaret`.
  public convenience init(
    field: TextField, owner: (any TextFieldListener)?, measurer: any TextMeasurer, x: Int, y: Int
  ) {
    self.init(field: field, owner: owner, measurer: measurer, position: 0)
    let hit = findCaret(x: x, y: y)
    pos = hit
    end = hit
  }

  // MARK: - Geometry

  private func sceneFont() -> SceneFont { field.sceneFont() }

  private func width(upTo index: Int) -> Int {
    guard index > 0 else { return 0 }
    let prefix = String(characters.prefix(index))
    guard !prefix.isEmpty else { return 0 }
    return measurer.width(of: prefix, font: sceneFont())
  }

  /// `GraphicsUtil.getTextBounds(g, text, x, y, halign, valign)` for the *current* text;
  /// `TextLayout.textBox` is that function, transcribed in `LogisimRender`.
  private func textBox() -> (x: Int, y: Int, width: Int, height: Int) {
    let font = sceneFont()
    let string = text
    return TextLayout.textBox(
      width: string.isEmpty ? 0 : measurer.width(of: string, font: font),
      metrics: measurer.metrics(for: font),
      x: field.x, y: field.y, halign: field.halign, valign: field.valign)
  }

  /// `GraphicsUtil.getTextCursor(g, text, x, y, pos, halign, valign)`: the box narrowed to a
  /// one-pixel rule, shifted right by the advance of the prefix.
  private func cursorRect(at index: Int) -> (x: Int, y: Int, height: Int) {
    let box = textBox()
    return (x: box.x + width(upTo: index), y: box.y, height: box.height)
  }

  /// `TextFieldCaret.getBounds(Graphics)` (`:126-134`).
  ///
  /// The union of two *different* boxes, `GraphicsUtil.getTextBounds` of the text being typed
  /// and `TextField.getBounds` of the text the field still holds, expanded by 3. The union is
  /// what keeps the caret alive when the typed string is shorter than the committed one, and the
  /// expansion is the slop that makes a click on the border count as inside.
  private func syncBounds() {
    let box = textBox()
    setBounds(
      Bounds.create(box.x, box.y, box.width, box.height)
        .add(field.bounds(measurer: measurer))
        .expand(3))
  }

  /// `findCaret(int x, int y)` → `GraphicsUtil.getTextPosition`.
  ///
  /// Upstream measures the box at the origin, subtracts its `x`, and then walks the string
  /// comparing against the **midpoint** between successive prefix widths, so a click lands on
  /// whichever character boundary is nearer. Transcribed, including the `(last + cur) / 2`
  /// truncation.
  private func findCaret(x: Int, y: Int) -> Int {
    let font = sceneFont()
    let string = text
    let box = TextLayout.textBox(
      width: string.isEmpty ? 0 : measurer.width(of: string, font: font),
      metrics: measurer.metrics(for: font),
      x: 0, y: 0, halign: field.halign, valign: field.valign)
    var localX = x - field.x - box.x
    // `findCaret` subtracts the field origin before calling `getTextPosition`, which then
    // subtracts the box origin. Both are folded into `localX` above; `y` is read by neither
    // (the field is a single line), which is why upstream's `y -= field.getY()` has no effect.
    _ = y

    var last = 0
    for index in characters.indices {
      let cur = width(upTo: index + 1)
      if localX <= (last + cur) / 2 { return index }
      last = cur
    }
    localX = 0
    return characters.count
  }

  // MARK: - Editing primitives

  /// `wordBoundary(int pos)`.
  private func wordBoundary(_ index: Int) -> Bool {
    if index <= 0 || index >= characters.count { return true }
    return characters[index - 1].isWhitespace != characters[index].isWhitespace
  }

  /// `allowedCharacter(char c)`; `c != CHAR_UNDEFINED && !Character.isISOControl(c)`.
  ///
  /// `isISOControl` is `c <= 0x1F || (0x7F...0x9F).contains(c)`. Applied to the first scalar,
  /// because a Swift `Character` that is a control code is exactly one scalar.
  private static func allowedCharacter(_ character: Character) -> Bool {
    guard let scalar = character.unicodeScalars.first,
      character.unicodeScalars.count == 1 || scalar.value > 0x9F
    else { return false }
    if scalar.value <= 0x1F { return false }
    if (0x7F...0x9F).contains(scalar.value) { return false }
    return true
  }

  /// `normalizeSelection()`.
  private func normalizeSelection() {
    if pos > end { swap(&pos, &end) }
  }

  /// `moveCaret(int dx, int dy, boolean shift, boolean ctrl)`, with `ctrl` renamed to what it
  /// means: walk to the next word boundary. See the header for the modifier remap.
  private func moveCaret(dx: Int, dy: Int, shift: Bool, byWord: Bool) {
    if !shift { normalizeSelection() }

    if dy < 0 {
      pos = 0
    } else if dy > 0 {
      pos = characters.count
    } else if pos + dx >= 0 && pos + dx <= characters.count {
      if !shift && pos != end {
        // Collapse an existing selection to the side the arrow points at, without moving.
        if dx < 0 { end = pos } else { pos = end }
      } else {
        pos += dx
      }
      while byWord && !wordBoundary(pos) { pos += dx }
    }

    if !shift { end = pos }
  }

  private func replaceSelection(with inserted: [Character]) {
    normalizeSelection()
    let tail = end < characters.count ? Array(characters[end...]) : []
    characters = Array(characters[..<pos]) + inserted + tail
    pos += inserted.count
    end = pos
  }

  // MARK: - Keys

  public override func keyPressed(_ event: inout ToolKeyEvent) {
    let shift = event.modifiers.contains(.shift)
    let command = event.modifiers.contains(.command)
    let byWord = event.modifiers.contains(.option)

    if arrowKeyMaybePressed(&event, shift: shift, command: command, byWord: byWord) {
      syncBounds()
      return
    }
    if command {
      commandKeyPressed(&event, shift: shift)
    } else {
      normalKeyPressed(&event)
    }
    syncBounds()
  }

  /// `arrowKeyMaybePressed(KeyEvent, boolean, boolean)`, plus the ⌘←/⌘→ Home/End remap.
  ///
  /// Returns whether the event was handled, which is upstream's `if (e.isConsumed()) return`.
  private func arrowKeyMaybePressed(
    _ event: inout ToolKeyEvent, shift: Bool, command: Bool, byWord: Bool
  ) -> Bool {
    switch event.rawKeyCode {
    case AwtVirtualKey.left:
      if command {
        moveToLineStart(shift: shift)
      } else {
        moveCaret(dx: -1, dy: 0, shift: shift, byWord: byWord)
      }
    case AwtVirtualKey.right:
      if command {
        moveToLineEnd(shift: shift)
      } else {
        moveCaret(dx: 1, dy: 0, shift: shift, byWord: byWord)
      }
    case AwtVirtualKey.up:
      moveCaret(dx: 0, dy: -1, shift: shift, byWord: byWord)
    case AwtVirtualKey.down:
      moveCaret(dx: 0, dy: 1, shift: shift, byWord: byWord)
    case AwtVirtualKey.home:
      moveToLineStart(shift: shift)
    case AwtVirtualKey.end:
      moveToLineEnd(shift: shift)
    default:
      return false
    }
    event.consume()
    return true
  }

  /// `case KeyEvent.VK_HOME`: `pos = 0; if (!shift) end = pos;`.
  private func moveToLineStart(shift: Bool) {
    pos = 0
    if !shift { end = pos }
  }

  /// `case KeyEvent.VK_END`.
  private func moveToLineEnd(shift: Bool) {
    pos = characters.count
    if !shift { end = pos }
  }

  /// `controlKeyPressed(KeyEvent, boolean)`, on Command rather than Control.
  private func commandKeyPressed(_ event: inout ToolKeyEvent, shift: Bool) {
    switch event.rawKeyCode {
    case AwtVirtualKey.a:
      pos = 0
      end = characters.count
      event.consume()
    case AwtVirtualKey.x, AwtVirtualKey.c:
      copySelection(cut: event.rawKeyCode == AwtVirtualKey.x)
      event.consume()
    case AwtVirtualKey.v:
      paste()
      event.consume()
    default:
      break
    }
  }

  private func copySelection(cut: Bool) {
    guard pos != end else { return }
    let lower = min(pos, end)
    let upper = max(pos, end)
    let selected = String(characters[lower..<upper])
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(selected, forType: .string)
    if cut {
      normalizeSelection()
      let tail = end < characters.count ? Array(characters[end...]) : []
      characters = Array(characters[..<pos]) + tail
      end = pos
    }
  }

  /// `case VK_INSERT, VK_PASTE, VK_V`: with upstream's whitespace collapse preserved.
  ///
  /// Upstream walks the clipboard string one character at a time, substituting a space for any
  /// disallowed character and **skipping** it if the previous character was already a space. So a
  /// pasted `"a\n\n\tb"` arrives as `"a b"`, not `"a   b"`. Transcribed rather than simplified:
  /// a label is a single line and this is what stops a multi-line paste from becoming a run of
  /// blanks.
  private func paste() {
    guard let string = NSPasteboard.general.string(forType: .string) else { return }
    var lastWasSpace = false
    for character in string {
      var toInsert = character
      if !TextFieldCaret.allowedCharacter(toInsert) {
        if lastWasSpace { continue }
        toInsert = " "
      }
      lastWasSpace = (toInsert == " ")
      replaceSelection(with: [toInsert])
    }
  }

  /// `normalKeyPressed(KeyEvent, boolean)`.
  ///
  /// `VK_CLEAR` and `VK_CANCEL` are not reproduced: neither exists on a Mac keyboard, and
  /// `CanvasToolController` maps nothing to them, so an arm for either would be unreachable code
  /// rather than behaviour.
  private func normalKeyPressed(_ event: inout ToolKeyEvent) {
    // Return commits. See the header for why this reads the character rather than `VK_ENTER`.
    if event.character?.isNewline == true {
      stopEditing()
      event.consume()
      return
    }

    switch event.rawKeyCode {
    case AwtVirtualKey.escape:
      cancelEditing()
      event.consume()
    case AwtVirtualKey.backSpace:
      normalizeSelection()
      if pos != end {
        characters = Array(characters[..<pos]) + Array(characters[end...])
        end = pos
      } else if pos > 0 {
        characters.remove(at: pos - 1)
        pos -= 1
        end = pos
      }
      event.consume()
    case AwtVirtualKey.delete:
      normalizeSelection()
      if pos != end {
        let tail = end < characters.count ? Array(characters[end...]) : []
        characters = Array(characters[..<pos]) + tail
        end = pos
      } else if pos < characters.count {
        characters.remove(at: pos)
      }
      event.consume()
    default:
      // Upstream's `default -> { /* ignore */ }`. Not consumed, so the tool sees it.
      break
    }
  }

  /// `keyTyped(KeyEvent)`.
  ///
  /// The AWT guard is `ALT | CTRL | META`; here it is Command and Control only; Option is a
  /// character-composition modifier on macOS. See the header.
  public override func keyTyped(_ event: inout ToolKeyEvent) {
    guard !event.modifiers.contains(.command), !event.modifiers.contains(.control) else { return }
    guard let character = event.character else { return }

    if TextFieldCaret.allowedCharacter(character) {
      replaceSelection(with: [character])
      event.consume()
    } else if character.isNewline {
      stopEditing()
      event.consume()
    }
    syncBounds()
  }

  // MARK: - Mouse

  public override func mousePressed(_ event: inout ToolMouseEvent) {
    let hit = findCaret(x: event.x, y: event.y)
    pos = hit
    end = hit
  }

  public override func mouseDragged(_ event: inout ToolMouseEvent) {
    end = findCaret(x: event.x, y: event.y)
  }

  public override func mouseReleased(_ event: inout ToolMouseEvent) {
    end = findCaret(x: event.x, y: event.y)
  }

  // MARK: - Lifecycle

  /// `cancelEditing()`.
  public override func cancelEditing() {
    let event = CaretEvent(caret: self, oldText: oldText, text: oldText)
    characters = Array(oldText)
    pos = characters.count
    end = pos
    for listener in caretListeners() { listener.editingCanceled(event) }
    field.removeTextFieldListener(self)
  }

  /// `stopEditing()`.
  ///
  /// The order matters and is upstream's: the `CaretEvent` is built from `oldText` **before**
  /// `field.setText` fires `textChanged` back into this caret and overwrites it.
  public override func stopEditing() {
    let event = CaretEvent(caret: self, oldText: oldText, text: text)
    field.setText(text)
    for listener in caretListeners() { listener.editingStopped(event) }
    field.removeTextFieldListener(self)
  }

  /// `commitText(String)`.
  public override func commitText(_ value: String) {
    characters = Array(value)
    pos = characters.count
    end = pos
    field.setText(value)
    syncBounds()
  }

  /// `TextFieldCaret.textChanged(TextFieldEvent)`; somebody else wrote the field, so the
  /// session restarts from the new string.
  public func textChanged(_ event: TextFieldEvent) {
    characters = Array(field.text)
    oldText = field.text
    pos = characters.count
    end = pos
    syncBounds()
  }

  // MARK: - Drawing

  /// `TextFieldCaret.draw(Graphics)` (`:80-113`), as a scene.
  ///
  /// D6: a caret contributes geometry, not pixels. This is the same vehicle
  /// `InstancePokerCaret.overlayScene` uses, and for the same reason: the four shapes below
  /// (filled box, border, selection band, cursor rule) plus a text run are not expressible as
  /// `ToolOverlayItem`, which is a closed `Hashable` enum of the nine fixed shapes a *tool*
  /// draws.
  ///
  /// **Not yet reaching the canvas, and that is one line elsewhere.** `TextTool.overlay(for:)` is
  /// `ToolOverlay(items: caret?.overlayItems ?? [])`; it never reads `scene`, where `PokeTool`
  /// does. Until that call site passes this through, an open text caret is invisible even though
  /// it is fully live: typing, selection, commit and undo all work. Recorded in the task report;
  /// the fix belongs in `TextTool.swift`, which this slice does not own.
  public override func overlayScene(context: any PaintContext) -> RenderScene? {
    let builder = SceneBuilder(measurer: measurer)
    builder.font = sceneFont()

    let box = bounds
    builder.withColor(TextFieldCaret.editBackground) {
      builder.fillRect(box.x, box.y, box.width, box.height)
    }
    builder.withColor(TextFieldCaret.editBorder) {
      builder.drawRect(box.x, box.y, box.width, box.height)
    }

    if pos != end {
      let lower = cursorRect(at: min(pos, end))
      let upper = cursorRect(at: max(pos, end))
      builder.withColor(TextFieldCaret.selectionBackground) {
        builder.fillRect(lower.x, lower.y - 1, upper.x - lower.x + 1, lower.height + 2)
      }
    }

    builder.withColor(.black) {
      builder.drawText(
        text, x: field.x, y: field.y, halign: field.halign, valign: field.valign)
      if pos == end {
        let cursor = cursorRect(at: pos)
        builder.drawLine(cursor.x, cursor.y, cursor.x, cursor.y + cursor.height)
      }
    }

    let scene = builder.finish()
    return scene.isEmpty ? nil : scene
  }
}

// MARK: - AWT virtual key codes this caret compares against

/// The `KeyEvent.VK_*` values `TextFieldCaret` switches on.
///
/// `ToolKeyEvent.rawKeyCode` carries AWT codes by design (see `AwtKeyCodes` in
/// `CanvasToolController.swift`), so the caret can be transcribed against the same constants the
/// Java does rather than against AppKit scan codes. Spelled out here rather than inlined because
/// a bare `8` in a `switch` next to a bare `127` is exactly the pair a reader gets backwards.
enum AwtVirtualKey {
  static let backSpace = 8
  static let escape = 27
  static let end = 35
  static let home = 36
  static let left = 37
  static let up = 38
  static let right = 39
  static let down = 40
  static let a = 65
  static let c = 67
  static let v = 86
  static let x = 88
  static let delete = 127
}
